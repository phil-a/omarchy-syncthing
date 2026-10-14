#!/usr/bin/env python3
"""Syncthing helper for the Omarchy bar widget.

    syncthing.py [--config PATH] [--unit UNIT] status
    syncthing.py [--config PATH] scan [FOLDER_ID]

`status` prints one JSON object describing the service, folders, and devices.
`scan` asks Syncthing to rescan one folder, or every folder when none is given.

The API key and GUI address come from Syncthing's own config.xml, so there is
nothing to configure for a standard install. Only the standard library is used.

The key is only ever sent over a connection whose server end is owned by this
user on this machine (checked in /proc/net/tcp after connecting), never
through a proxy, and never along a redirect.
"""

import http.client
import ipaddress
import json
import os
import re
import signal
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor

CONFIG_CANDIDATES = [
    "$XDG_STATE_HOME/syncthing/config.xml",
    "~/.local/state/syncthing/config.xml",
    "$XDG_CONFIG_HOME/syncthing/config.xml",
    "~/.config/syncthing/config.xml",
]
TIMEOUT = 3
# Whole-run limit: TIMEOUT is per socket operation, so a server that trickles
# bytes could otherwise keep one poll (and the widget) waiting indefinitely.
DEADLINE = 20
MAX_RESPONSE = 16 * 1024 * 1024
MAX_ERROR_BODY = 4096
# systemd unit names: no leading dash, so a name can never be read as an option.
UNIT_RE = re.compile(r"[A-Za-z0-9_@][A-Za-z0-9_.@:-]*\.service")


class ApiError(Exception):
    pass


def obj(value):
    return value if isinstance(value, dict) else {}


def arr(value):
    return value if isinstance(value, list) else []


def num(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def text(value):
    return value if isinstance(value, str) else ""


def find_config(explicit):
    if explicit:
        path = os.path.expanduser(os.path.expandvars(explicit))
        return path if os.path.isfile(path) else None
    for candidate in CONFIG_CANDIDATES:
        if "$" in candidate and not os.environ.get(candidate[1:].split("/")[0]):
            continue
        path = os.path.expanduser(os.path.expandvars(candidate))
        if os.path.isfile(path):
            return path
    return None


def read_gui(config_path):
    root = ET.parse(config_path).getroot()
    gui = root.find("gui")
    if gui is None:
        raise ApiError("No <gui> section in " + config_path)
    api_key = (gui.findtext("apikey") or "").strip()
    address = (gui.findtext("address") or "127.0.0.1:8384").strip()
    tls = gui.get("tls", "false").lower() == "true"
    if gui.get("enabled", "true").lower() == "false":
        raise ApiError("Syncthing's GUI and REST API are disabled in its config")
    if not api_key:
        raise ApiError("Syncthing has no API key yet")
    if address.startswith("/") or address.startswith("unix"):
        raise ApiError("Syncthing GUI listens on a Unix socket; set a TCP address")
    host, _, port = address.rpartition(":")
    if host in ("", "0.0.0.0", "[::]", "::"):
        host = "127.0.0.1"
    scheme = "https" if tls else "http"
    return api_key, "%s://%s:%s" % (scheme, host, port)


def _proc_endpoint(hex_addr):
    host_hex, port_hex = hex_addr.split(":")
    raw = bytes.fromhex(host_hex)
    if len(raw) == 4:
        ip = ipaddress.IPv4Address(raw[::-1])
    else:
        # /proc/net/tcp6 prints the address as four host-order 32-bit words.
        ip = ipaddress.IPv6Address(b"".join(raw[i:i + 4][::-1] for i in range(0, 16, 4)))
        ip = ip.ipv4_mapped or ip
    return ip, int(port_hex, 16)


def _endpoint(addr):
    ip = ipaddress.ip_address(addr[0].split("%")[0])
    if ip.version == 6:
        ip = ip.ipv4_mapped or ip
    return ip, addr[1]


def server_uid(sock):
    """uid owning the server end of a connected TCP socket, or None.

    The kernel lists both ends of a local connection in /proc/net/tcp{,6};
    the server's row has our address as its remote end. A server on another
    machine has no row, so it is never trusted.
    """
    ours = _endpoint(sock.getsockname())
    theirs = _endpoint(sock.getpeername())
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(table) as f:
                next(f, None)
                for line in f:
                    fields = line.split()
                    if len(fields) < 8:
                        continue
                    if _proc_endpoint(fields[1]) == theirs and _proc_endpoint(fields[2]) == ours:
                        return int(fields[7])
        except (OSError, ValueError):
            continue
    return None


def verify_server(sock):
    uid = server_uid(sock)
    if uid != os.getuid():
        sock.close()
        who = "not on this machine" if uid is None else "owned by uid %d" % uid
        raise ApiError("Refusing to send the API key: the server on the GUI port is %s" % who)


class VerifiedHTTPConnection(http.client.HTTPConnection):
    def connect(self):
        super().connect()
        verify_server(self.sock)


class VerifiedHTTPSConnection(http.client.HTTPSConnection):
    def connect(self):
        super().connect()
        verify_server(self.sock)


class VerifiedHTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        return self.do_open(VerifiedHTTPConnection, req)


class VerifiedHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(VerifiedHTTPSConnection, req, context=self._context)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    # urllib copies request headers onto the redirected request, which would
    # hand the API key to wherever a redirect points. Syncthing never
    # redirects its REST API, so treat any redirect as an error.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Api:
    def __init__(self, base, api_key):
        self.base = base
        self.headers = {"X-API-Key": api_key}
        # The GUI's TLS certificate is self-signed, so it is not verified;
        # verify_server() establishes who is listening instead.
        context = ssl._create_unverified_context()
        # An empty ProxyHandler ignores http_proxy/https_proxy: the API key
        # must go straight to Syncthing, never through a proxy.
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            VerifiedHTTPHandler(),
            VerifiedHTTPSHandler(context=context),
            NoRedirect(),
        )

    def request(self, path, method="GET", **params):
        query = urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
        url = self.base + path + ("?" + query if query else "")
        req = urllib.request.Request(url, method=method, headers=self.headers)
        try:
            with self.opener.open(req, timeout=TIMEOUT) as resp:
                body = resp.read(MAX_RESPONSE + 1)
                if len(body) > MAX_RESPONSE:
                    raise ApiError("Response from %s is too large" % path)
        except urllib.error.HTTPError as e:
            detail = e.read(MAX_ERROR_BODY).decode("utf-8", "replace").strip()
            raise ApiError("%s %s: %s" % (e.code, path, detail or e.reason))
        except (urllib.error.URLError, OSError) as e:
            reason = getattr(e, "reason", e)
            if isinstance(reason, ApiError):
                raise reason
            raise ApiError("Cannot reach Syncthing at %s (%s)" % (self.base, reason))
        except http.client.HTTPException as e:
            raise ApiError("Bad response from Syncthing for %s (%s)" % (path, type(e).__name__))
        try:
            return json.loads(body) if body.strip() else None
        except ValueError:
            raise ApiError("Syncthing returned something other than JSON for %s" % path)

    def get(self, path, **params):
        return self.request(path, **params)

    def post(self, path, **params):
        return self.request(path, method="POST", **params)


def unit_state(unit):
    if not UNIT_RE.fullmatch(unit):
        return "unknown"
    try:
        out = subprocess.run(
            ["systemctl", "--user", "is-active", "--", unit],
            capture_output=True, text=True, timeout=TIMEOUT,
        )
        return out.stdout.strip() or "unknown"
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"


def safe(fn, fallback=None):
    try:
        return fn()
    except ApiError:
        return fallback


def folder_entry(api, cfg, stats):
    fid = text(cfg.get("id"))
    entry = {
        "id": fid,
        "label": text(cfg.get("label")) or fid,
        "path": os.path.expanduser(text(cfg.get("path"))),
        "paused": bool(cfg.get("paused")),
        "type": text(cfg.get("type")) or "sendreceive",
        "sharedWith": max(0, len(arr(cfg.get("devices"))) - 1),
        "state": "paused" if cfg.get("paused") else "unknown",
        "error": "",
        "globalBytes": 0,
        "globalFiles": 0,
        "needBytes": 0,
        "needFiles": 0,
        "pullErrors": 0,
        "lastScan": "",
        "lastFile": "",
        "lastFileAt": "",
    }
    if not entry["paused"]:
        try:
            st = obj(api.get("/rest/db/status", folder=fid))
            entry.update({
                "state": text(st.get("state")) or "unknown",
                "error": text(st.get("error")),
                "globalBytes": num(st.get("globalBytes")),
                "globalFiles": num(st.get("globalFiles")),
                "needBytes": num(st.get("needBytes")),
                "needFiles": num(st.get("needFiles")) + num(st.get("needDeletes")),
                "pullErrors": num(st.get("pullErrors")),
            })
        except ApiError as e:
            entry.update({"state": "error", "error": str(e)})
    folder_stats = obj(stats.get(fid))
    last_file = obj(folder_stats.get("lastFile"))
    entry["lastScan"] = text(folder_stats.get("lastScan"))
    entry["lastFile"] = text(last_file.get("filename"))
    entry["lastFileAt"] = text(last_file.get("at"))
    return entry


def device_entry(api, cfg, connections, stats):
    did = text(cfg.get("deviceID"))
    conn = obj(connections.get(did))
    entry = {
        "id": did,
        "shortId": did.split("-")[0],
        "name": text(cfg.get("name")) or did.split("-")[0],
        "paused": bool(cfg.get("paused")) or bool(conn.get("paused")),
        "connected": bool(conn.get("connected")),
        "address": text(conn.get("address")),
        "connectionType": text(conn.get("type")),
        "clientVersion": text(conn.get("clientVersion")),
        "lastSeen": text(obj(stats.get(did)).get("lastSeen")),
        "completion": None,
        "needBytes": 0,
    }
    if entry["connected"]:
        comp = obj(safe(lambda: api.get("/rest/db/completion", device=did)))
        if "completion" in comp:
            entry["completion"] = num(comp.get("completion"))
            entry["needBytes"] = num(comp.get("needBytes"))
    return entry


def status(api, unit):
    result = {
        "ok": True,
        "unit": unit,
        "unitState": unit_state(unit) if unit else "unknown",
        "reachable": False,
        "guiUrl": api.base if api else "",
        "myId": "",
        "version": "",
        "uptime": 0,
        "folders": [],
        "devices": [],
        "systemErrors": [],
        "lastError": "",
    }
    if api is None:
        return result
    # While the unit is down nothing legitimate listens on the GUI port, so
    # don't offer the API key to whatever might.
    if result["unitState"] in ("inactive", "failed", "deactivating"):
        return result
    try:
        system = obj(api.get("/rest/system/status"))
    except ApiError as e:
        result["lastError"] = str(e)
        return result

    result["reachable"] = True
    my_id = text(system.get("myID"))
    result["myId"] = my_id
    result["uptime"] = num(system.get("uptime"))

    with ThreadPoolExecutor(max_workers=8) as pool:
        f_version = pool.submit(safe, lambda: api.get("/rest/system/version"), {})
        f_folders = pool.submit(safe, lambda: api.get("/rest/config/folders"), [])
        f_devices = pool.submit(safe, lambda: api.get("/rest/config/devices"), [])
        f_conns = pool.submit(safe, lambda: api.get("/rest/system/connections"), {})
        f_fstats = pool.submit(safe, lambda: api.get("/rest/stats/folder"), {})
        f_dstats = pool.submit(safe, lambda: api.get("/rest/stats/device"), {})
        f_errors = pool.submit(safe, lambda: api.get("/rest/system/error"), {})

        result["version"] = text(obj(f_version.result()).get("version"))
        folder_cfgs = [c for c in arr(f_folders.result()) if isinstance(c, dict)]
        device_cfgs = [d for d in arr(f_devices.result())
                       if isinstance(d, dict) and d.get("deviceID") != my_id]
        connections = obj(obj(f_conns.result()).get("connections"))
        fstats = obj(f_fstats.result())
        dstats = obj(f_dstats.result())

        folders = list(pool.map(lambda c: folder_entry(api, c, fstats), folder_cfgs))
        devices = list(pool.map(lambda c: device_entry(api, c, connections, dstats), device_cfgs))

    folders.sort(key=lambda f: f["label"].lower())
    devices.sort(key=lambda d: (not d["connected"], d["name"].lower()))
    result["folders"] = folders
    result["devices"] = devices
    errors = [e for e in arr(obj(f_errors.result()).get("errors")) if isinstance(e, dict)]
    result["systemErrors"] = [
        {"when": text(e.get("when")), "message": text(e.get("message"))} for e in errors[-5:]
    ]
    return result


def on_deadline(signum, frame):
    sys.stderr.write("Timed out talking to Syncthing\n")
    sys.stderr.flush()
    os._exit(1)


def main(argv):
    signal.signal(signal.SIGALRM, on_deadline)
    signal.alarm(DEADLINE)
    # Options come before the command; everything after it is positional, so
    # a folder ID that looks like an option (peers can pick folder IDs) is
    # never parsed as one.
    args = list(argv)
    config = None
    unit = "syncthing.service"
    while args and args[0].startswith("--"):
        option = args.pop(0)
        if option == "--":
            break
        if not args:
            print("missing value for " + option, file=sys.stderr)
            return 2
        value = args.pop(0)
        if option == "--config":
            config = value
        elif option == "--unit":
            unit = value
        else:
            print("unknown option: " + option, file=sys.stderr)
            return 2
    command = args[0] if args else "status"

    config_path = find_config(config)
    api = None
    config_error = ""
    if config_path is None:
        config_error = "Syncthing config.xml not found"
    else:
        try:
            api_key, base = read_gui(config_path)
            api = Api(base, api_key)
        except (ApiError, ET.ParseError, OSError) as e:
            config_error = str(e)

    if command == "status":
        result = status(api, unit)
        if config_error:
            result["lastError"] = config_error
        print(json.dumps(result))
        return 0

    if command == "scan":
        if api is None:
            print(config_error, file=sys.stderr)
            return 1
        folder = args[1] if len(args) > 1 else None
        try:
            api.post("/rest/db/scan", folder=folder)
        except ApiError as e:
            print(str(e), file=sys.stderr)
            return 1
        return 0

    print("unknown command: " + command, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
