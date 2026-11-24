#!/usr/bin/env bash
# recipe: Zoraxy: the reverse proxy that sends each public name to the right container
# recipe.de: Zoraxy: der Reverse-Proxy, der jeden öffentlichen Namen zum richtigen Container schickt
# kind: personal
# needs: -
# uses: -
set -euo pipefail

# What it does: creates the container "zoraxy" and installs Zoraxy (one
# program from its GitHub releases, pinned below and checked with its checksum, started by systemd).
#   port 80     what the Cloudflare tunnel sends its traffic to
#   port 8000   the admin page, for the home network only
# Encryption ends at Cloudflare, so Zoraxy speaks plain HTTP.
# Updates: raise the two pins below (the checksum is the one GitHub shows for the file zoraxy_linux_amd64 of that release). A run
# installs only when the stamp of the last run differs (hs recipe zoraxy --check says what would change). A Zoraxy installed
# earlier has no stamp, so the next run replaces its program by the pinned, checked one; its folder with the rules stays.
ZORAXY_VERSION=v3.3.5
ZORAXY_SHA256=41b066f6f521a7b991af87dbdda41f6c5dae9708015f77e3d0db95787ec0f24e
ZORAXY_URL=https://github.com/tobychui/zoraxy/releases/download/$ZORAXY_VERSION/zoraxy_linux_amd64
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-zoraxy}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  printf '%s\n' "$(t "  create the container '%s' (2048 MB RAM limit) unless it exists, with a fixed address (.10 to .19) if UniFi is connected (hs net setup)" "$ct")"
  say "  install Zoraxy $ZORAXY_VERSION inside (/opt/zoraxy; downloaded once, checksum checked), started by systemd; another version is replaced, its rules are kept"
  exit 0
fi

# --check: what would change, nothing is done (stamps are only read)
if $CHECK; then
  if incus info "$ct" >/dev/null 2>&1; then say "current        container $ct"; else say "would create   container $ct"; CHECK_STALE=true; fi
  piece zoraxy-release "$ZORAXY_VERSION" "Zoraxy" || true
  check_done
fi
[ "$(uname -m)" = x86_64 ] || fail "$(t 'The pinned Zoraxy binary is for x86_64; this machine is %s.' "$(uname -m)")"

# not 80: that is where the proxy itself listens
setting PORT "$(_tr "Port of Zoraxy's admin page (not 80, the proxy itself listens there)")" 8000 8000 "$a_port" 80
ensure_container "$ct" 2048
fixed_address "$ct" 10 19
wait_internet "$ct"

step "Install Zoraxy"
in_ct "Installing curl" 'command -v curl >/dev/null || { $1 update -qq; $1 install -y -qq curl ca-certificates; }' "$apt_quick"
# the program is replaced, its folder with the rules (conf, sys.db) stays. The download is checked on this machine BEFORE it
# goes into the container; the running program is stopped only after it started once.
if piece zoraxy-release "$ZORAXY_VERSION" "Zoraxy" && incus exec "$ct" -- test -x /opt/zoraxy/zoraxy </dev/null; then
  ok "$(t 'Zoraxy is current (%s)' "$ZORAXY_VERSION")"
else
  cache=$state/zoraxy
  mkdir -p "$cache"
  find "$cache" -name 'zoraxy-*' ! -name "zoraxy-$ZORAXY_VERSION" -delete 2>/dev/null || true
  fetch_pinned zoraxy-download "$ZORAXY_URL" "$ZORAXY_SHA256" "$cache/zoraxy-$ZORAXY_VERSION" "$ZORAXY_VERSION"
  incus exec "$ct" -- mkdir -p /opt/zoraxy </dev/null
  incus file push --mode 0755 "$cache/zoraxy-$ZORAXY_VERSION" "$ct/opt/zoraxy/zoraxy.new" >/dev/null
  in_ct "Installing Zoraxy $ZORAXY_VERSION" '
    cd /opt/zoraxy
    ./zoraxy.new -version >/dev/null
    systemctl stop zoraxy 2>/dev/null || true
    mv zoraxy.new zoraxy'
  piece_done zoraxy-release "$ZORAXY_VERSION"
fi
in_ct "Starting it with the system" '
  cat > /etc/systemd/system/zoraxy.service <<UNIT
[Unit]
Description=General purpose request proxy and forwarding tool
After=syslog.target network-online.target

[Service]
ExecStart=/opt/zoraxy/./zoraxy -port=:$1
WorkingDirectory=/opt/zoraxy/
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable -q zoraxy
  systemctl restart zoraxy' "$PORT"
note "$(incus exec "$ct" -- /opt/zoraxy/zoraxy -version </dev/null 2>/dev/null | head -n1)"
wait_page Zoraxy 'journalctl -u zoraxy -n 30' --plain --tries 30 --every 1

declare_service zoraxy Zoraxy zoraxy never-public Administration "Reverse proxy: which address goes where"
box <<DONE
$(t 'Done. Open in the browser:   %s' "$(web)")
$(say "  1. The first visit creates the admin account.")
$(say "  2. HTTP Proxy -> New Proxy Rule, one per service you want reachable from outside (matching name, target address:port).")
$(say "Every rule here is reachable from the whole internet. Never add one for an admin page")
$(say "(Incus, this page, Arcane, Grafana, Uptime Kuma).")
$(docs_hint containers-and-apps)
DONE
