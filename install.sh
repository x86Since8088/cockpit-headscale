#!/usr/bin/env bash
#
# install.sh - install the cockpit-headscale plugin.
#
# Usage:
#   sudo ./install.sh                 # install to /usr/share/cockpit/headscale
#   sudo ./install.sh --uninstall     # remove it again
#   ./install.sh --user               # install for the current user only,
#                                     #   into ~/.local/share/cockpit/headscale
#   DESTDIR=/tmp/stage ./install.sh   # stage into a package build root
#
# The plugin is plain HTML/CSS/JS. There is no build step and no dependency
# on node, npm or a bundler.

set -Eeuo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NAME="headscale"
MODE="system"
ACTION="install"

PAYLOAD=(manifest.json index.html headscale.js headscale.css)

usage() { sed -n '2,17p' "$0" | sed 's/^# \?//'; exit "${1:-0}"; }

while (($#)); do
    case "$1" in
        --user)      MODE="user"; shift ;;
        --system)    MODE="system"; shift ;;
        --uninstall) ACTION="uninstall"; shift ;;
        -h|--help)   usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

if [[ "$MODE" == "user" ]]; then
    BASE="${XDG_DATA_HOME:-$HOME/.local/share}/cockpit"
else
    BASE="${DESTDIR:-}/usr/share/cockpit"
fi
TARGET="$BASE/$NAME"

if [[ "$ACTION" == "uninstall" ]]; then
    if [[ -d "$TARGET" ]]; then
        rm -rf -- "$TARGET"
        echo "removed $TARGET"
    else
        echo "nothing to remove at $TARGET"
    fi
    exit 0
fi

# --- pre-flight -----------------------------------------------------------

for f in "${PAYLOAD[@]}"; do
    [[ -f "$SRC/$f" ]] || { echo "missing source file: $SRC/$f" >&2; exit 1; }
done

# A malformed manifest makes Cockpit drop the package silently, which is a
# miserable thing to debug. Fail here instead.
if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SRC/manifest.json" \
        || { echo "manifest.json is not valid JSON" >&2; exit 1; }
elif command -v jq >/dev/null 2>&1; then
    jq -e . "$SRC/manifest.json" >/dev/null \
        || { echo "manifest.json is not valid JSON" >&2; exit 1; }
else
    echo "note: no python3 or jq available, skipping manifest validation" >&2
fi

if [[ "$MODE" == "system" && -z "${DESTDIR:-}" && "$(id -u)" != "0" ]]; then
    echo "a system-wide install needs root; re-run with sudo, or use --user" >&2
    exit 1
fi

# --- install --------------------------------------------------------------

install -d -m 0755 "$TARGET"
for f in "${PAYLOAD[@]}"; do
    install -m 0644 "$SRC/$f" "$TARGET/$f"
done

# Remove files from older versions that are no longer part of the payload.
while IFS= read -r -d '' stale; do
    base="$(basename "$stale")"
    keep=0
    for f in "${PAYLOAD[@]}"; do
        [[ "$base" == "$f" ]] && keep=1 && break
    done
    ((keep)) || { rm -f -- "$stale"; echo "removed stale file $base"; }
done < <(find "$TARGET" -maxdepth 1 -type f -print0)

echo "installed to $TARGET"
ls -l "$TARGET"

cat <<'NOTE'

Cockpit picks the package up on the next page load; a hard reload
(Ctrl-Shift-R) clears the browser's cached manifest list. Restarting
cockpit.service is not required.

The page appears in the Cockpit navigation as "Headscale".
NOTE

# --with-policy: install the subnet-router policy, its reconciler, the watch
# unit and the ACL policy. These are HOST files, not Cockpit package files, and
# the reconciler changes firewall/sysctl state - so they are opt-in rather than
# part of a plain UI install.
if [ "${WITH_POLICY:-0}" = "1" ] || [ "${1:-}" = "--with-policy" ]; then
    SRCDIR="$(cd -- "$(dirname -- "$0")" && pwd)"
    for f in routing-policy.json hs-policy hs-policy-watch.service acl-policy.hujson; do
        [ -f "$SRCDIR/$f" ] || { echo "install.sh: missing $SRCDIR/$f" >&2; exit 1; }
    done
    install -D -m 0644 "$SRCDIR/routing-policy.json"    "${DESTDIR:-}/etc/headscale/routing-policy.json"
    install -D -m 0755 "$SRCDIR/hs-policy"              "${DESTDIR:-}/usr/local/sbin/hs-policy"
    install -D -m 0644 "$SRCDIR/hs-policy-watch.service" "${DESTDIR:-}/etc/systemd/system/hs-policy-watch.service"
    # The ACL policy goes to headscale's own writable area (the snap cannot read
    # /etc). Never overwrite an existing one - it is operator-edited.
    ACL="${DESTDIR:-}/var/snap/headscale/common/acl-policy.hujson"
    if [ -e "$ACL" ]; then
        echo "  ACL policy already present, left untouched: $ACL"
    else
        install -D -m 0644 "$SRCDIR/acl-policy.hujson" "$ACL"
        echo "  installed ACL policy: $ACL"
        echo "  point config.yaml policy.path at it, then restart headscale"
    fi
    echo "  installed subnet-router policy + reconciler"
    if [ -z "${DESTDIR:-}" ]; then
        systemctl daemon-reload
        echo "  run: systemctl enable --now hs-policy-watch.service"
        echo "  check drift any time with: hs-policy check"
    fi
fi
