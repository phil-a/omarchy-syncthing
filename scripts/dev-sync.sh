#!/bin/bash
# Copy this checkout into the user plugin directory the way
# `omarchy plugin add` would, validate it, and hot-reload the shell.
#
#   scripts/dev-sync.sh                       # sync + validate + rescan
#   scripts/dev-sync.sh --restart             # ...then restart the shell
#   scripts/dev-sync.sh --enable [placement]  # ...and put the widget on the
#                                             # bar, e.g. --section right
#
# The shell refuses symlinked plugins, so this copies rather than links.
# Panel.qml is loaded through the bar widget's Loader and can keep serving a
# cached copy until the shell restarts, hence --restart.

set -euo pipefail

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

restart=0
enable=0
placement=()
while (( $# > 0 )); do
  case "$1" in
    --restart) restart=1; shift ;;
    --enable) enable=1; shift; placement=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) echo "dev-sync: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
omarchy plugin validate "$here"
id=$(jq -r '.id // empty' "$here/manifest.json")
# rsync --delete below must only ever touch this plugin's own directory.
if [[ ! $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || $id == *..* ]]; then
  echo "dev-sync: refusing to sync, unexpected plugin id '$id'" >&2
  exit 1
fi
dest="$HOME/.config/omarchy/plugins/$id"

mkdir -p "$dest"
rsync -a --delete --exclude '.git' --exclude 'test' --exclude 'scripts' "$here/" "$dest/"
omarchy plugin validate "$dest"
# The shell must know about the plugin before it can be enabled.
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

if (( enable )); then
  omarchy plugin enable "$id" "${placement[@]}"
fi

if (( restart )); then
  omarchy restart shell
fi

echo "synced $id -> $dest"
