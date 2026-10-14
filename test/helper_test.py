"""Tests for syncthing.py against a fake Syncthing REST API.

Run with: python3 -m unittest discover -s test -p 'helper_test.py'
"""

import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "syncthing.py")
API_KEY = "test-key-123"


class FakeSyncthing(http.server.BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *args):
        pass

    def reply(self, body, code=200, headers=None):
        data = json.dumps(body).encode()
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        FakeSyncthing.seen.append((self.command, self.path, self.headers.get("X-API-Key")))
        if self.headers.get("X-API-Key") != API_KEY:
            return self.reply({"error": "forbidden"}, 403)
        path = self.path.split("?")[0]
        if path == "/rest/system/status":
            if self.server.redirect:
                return self.reply({}, 302, {"Location": "http://127.0.0.1:%d/rest/system/status" % self.server.redirect})
            return self.reply({"myID": "ME", "uptime": 5})
        if path == "/rest/config/devices" and self.server.malformed:
            return self.reply_raw(b"<html>not json</html>")
        if path == "/rest/config/folders":
            return self.reply([{"id": "--config", "label": "Weird", "path": "/tmp/x", "devices": []}])
        if path == "/rest/db/status":
            return self.reply({"state": "idle", "globalBytes": 10, "needBytes": 0})
        return self.reply({} if not path.endswith("folders") else [])

    def reply_raw(self, data):
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        FakeSyncthing.seen.append((self.command, self.path, self.headers.get("X-API-Key")))
        self.reply({})


class Recorder(http.server.BaseHTTPRequestHandler):
    """Stands in for a proxy or a redirect target; records what reaches it."""
    seen = []

    def log_message(self, *args):
        pass

    def do_GET(self):
        Recorder.seen.append((self.path, self.headers.get("X-API-Key")))
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    do_POST = do_GET


def serve(handler, **attrs):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    for k, v in attrs.items():
        setattr(server, k, v)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class HelperTest(unittest.TestCase):
    def setUp(self):
        FakeSyncthing.seen.clear()
        Recorder.seen.clear()
        self.recorder = serve(Recorder)
        self.api = serve(FakeSyncthing, redirect=None, malformed=False)
        self.tmp = tempfile.TemporaryDirectory()
        self.config = os.path.join(self.tmp.name, "config.xml")
        self.write_config()

    def write_config(self, enabled="true"):
        with open(self.config, "w") as f:
            f.write('<configuration><gui enabled="%s" tls="false">'
                    "<address>127.0.0.1:%d</address><apikey>%s</apikey></gui></configuration>"
                    % (enabled, self.api.server_port, API_KEY))

    def tearDown(self):
        for server in (self.api, self.recorder):
            server.shutdown()
            server.server_close()
        self.tmp.cleanup()

    def run_helper(self, *args, env=None):
        full_env = dict(os.environ)
        full_env.update(env or {})
        out = subprocess.run([sys.executable, "-I", HELPER, "--config", self.config] + list(args),
                             capture_output=True, text=True, env=full_env, timeout=30)
        return out

    def test_status_reads_api(self):
        out = self.run_helper("--unit", "syncthing.service", "status")
        status = json.loads(out.stdout)
        self.assertTrue(status["reachable"])
        self.assertEqual(status["folders"][0]["id"], "--config")

    def test_proxy_environment_is_ignored(self):
        proxy = "http://127.0.0.1:%d" % self.recorder.server_port
        out = self.run_helper("status", env={"http_proxy": proxy, "HTTP_PROXY": proxy, "no_proxy": ""})
        self.assertTrue(json.loads(out.stdout)["reachable"])
        self.assertEqual(Recorder.seen, [], "API key was sent through the proxy")

    def test_redirects_are_not_followed(self):
        self.api.redirect = self.recorder.server_port
        out = self.run_helper("status")
        self.assertFalse(json.loads(out.stdout)["reachable"])
        self.assertEqual(Recorder.seen, [], "API key followed a redirect")

    def test_option_like_folder_id_stays_positional(self):
        out = self.run_helper("scan", "--config")
        self.assertEqual(out.returncode, 0, out.stderr)
        posts = [p for (m, p, _) in FakeSyncthing.seen if m == "POST"]
        self.assertEqual(posts, ["/rest/db/scan?folder=--config"])

    def test_invalid_unit_is_not_passed_to_systemctl(self):
        out = self.run_helper("--unit", "--host=evil.service", "status")
        self.assertEqual(json.loads(out.stdout)["unitState"], "unknown")

    def test_key_only_goes_to_servers_owned_by_this_user(self):
        sys.path.insert(0, os.path.dirname(HELPER))
        import syncthing
        import socket
        with socket.create_connection(("127.0.0.1", self.api.server_port)) as sock:
            self.assertEqual(syncthing.server_uid(sock), os.getuid())

    def test_no_api_calls_while_unit_is_stopped(self):
        out = self.run_helper("--unit", "no-such-unit-for-tests.service", "status")
        status = json.loads(out.stdout)
        self.assertIn(status["unitState"], ("inactive", "unknown"))
        if status["unitState"] == "inactive":
            self.assertEqual(FakeSyncthing.seen, [], "API key offered while the unit is stopped")

    def test_disabled_gui_is_not_contacted(self):
        self.write_config(enabled="false")
        out = self.run_helper("status")
        self.assertFalse(json.loads(out.stdout)["reachable"])
        self.assertEqual(FakeSyncthing.seen, [])

    def test_malformed_responses_do_not_crash(self):
        self.api.malformed = True
        out = self.run_helper("status")
        self.assertEqual(out.returncode, 0, out.stderr)
        status = json.loads(out.stdout)
        self.assertTrue(status["reachable"])
        self.assertEqual(status["devices"], [])

    def test_unknown_option_is_rejected(self):
        out = self.run_helper("--bogus", "x", "status")
        self.assertEqual(out.returncode, 2)


if __name__ == "__main__":
    unittest.main()
