#!/usr/bin/env bash
# recipe: Arcane: deprecated, a web page for your Docker projects; it only takes over an Arcane that already runs (use portainer for a new one)
# recipe.de: Arcane: veraltet, eine Webseite für deine Docker-Projekte; übernimmt nur ein laufendes Arcane (für ein neues: portainer)
# kind: generic
# needs: docker
# uses: -
# runs: docker
set -euo pipefail

# What it does: takes over an Arcane that the Docker setting installed before (/opt/arcane in the container docker, port 80) and keeps it
# running as a compose project of the recipe: same folder, same volume, same keys (.env), same port. Arcane is no longer maintained
# upstream, so a fresh install is refused: the offered manager is the recipe portainer.
#   port 3552  the default port of a re-install that has its own folder (an adopted install keeps the port it has, usually 80)
#   keys       ENCRYPTION_KEY and JWT_SECRET in .env, made once and never replaced (Arcane cannot read its stored data with new ones)
# The old compose file is kept once as docker-compose.yml.before-recipe; the recipe owns the project from then on.
# An admin page for the home network: never a Zoraxy rule.
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-arcane}; app=$ct
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
IMAGE=ghcr.io/getarcaneapp/arcane:v2.17.3   # what the tag latest was on 2026-11-24 (the same digest; github.com/getarcaneapp/arcane/releases). v3 is not published under a version tag on ghcr.io yet.
DEFAULT_PORT=3552

# The keys are made ONCE: with new ones Arcane cannot read what it stored (the login fails with a server error, then 401).
# Shell lines run inside the container docker; $1 is the folder (ARCANE_DIR and PROJECTS_DIR are for the tests).
keys_script() {
  cat <<'SH'
dir=${ARCANE_DIR:-$1}; projects=${PROJECTS_DIR:-/opt/projects}
mkdir -p "$dir" "$projects" && cd "$dir"
# A compose file this recipe did not write belongs to an older install (by hand, or the Docker setting): keep it once. Its keys may be in it.
if [ -f docker-compose.yml ] && ! grep -q 'Written by "hs recipe arcane"' docker-compose.yml && [ ! -e docker-compose.yml.before-recipe ]; then
  cp -p docker-compose.yml docker-compose.yml.before-recipe
fi
if [ ! -s .env ]; then
  # an older install has them in its compose file (ENCRYPTION_KEY=... or ENCRYPTION_KEY: ...): carry them over, never a ${placeholder}
  carry=$(cat docker-compose.yml.before-recipe docker-compose.yml 2>/dev/null |
    sed -nE 's/^[[:space:]]*-?[[:space:]]*(ENCRYPTION_KEY|JWT_SECRET)[[:space:]]*[=:][[:space:]]*"?([^"[:space:]$]+)"?[[:space:]]*$/\1=\2/p' | awk -F= '!seen[$1]++' || true)
  # the ENCRYPTION_KEY protects what Arcane stored: it must be carried over. The JWT_SECRET only signs logins: a new one just logs people out.
  if printf '%s\n' "$carry" | grep -q '^ENCRYPTION_KEY='; then
    printf '%s\n' "$carry" | grep -q '^JWT_SECRET=' || carry=$(printf '%s\nJWT_SECRET=%s' "$carry" "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n")")
    ( umask 077; printf '%s\n' "$carry" > .env )
  elif command -v docker >/dev/null 2>&1 && docker volume ls -q 2>/dev/null | grep -qi arcane; then
    echo "Arcane has stored data here (a docker volume) but no ENCRYPTION_KEY could be found to carry over: new keys would lock you out of it. Restore the old compose file (from a snapshot: incus snapshot list) and run again, or, for a fresh Arcane, run 'docker compose down -v' in $dir first." >&2
    exit 1
  else
    ( umask 077; printf "ENCRYPTION_KEY=%s\nJWT_SECRET=%s\n" "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n")" "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n")" > .env )
  fi
fi
SH
}

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  say "  take over an existing /opt/arcane in the container docker (same data, keys and port), keeping its compose file once as docker-compose.yml.before-recipe"
  say "  refuse a fresh install: Arcane is no longer maintained upstream (use: hs recipe portainer)"
  say "  declare the service never-public (an admin page: no Zoraxy rule)"
  exit 0
fi

recipe_runtime docker
# An install of the old Docker setting lives in /opt/<name> of the container docker: use it in place (unless the recipe has its own folder already)
legacy_port=$DEFAULT_PORT
if ! $existed && incus exec docker -- test -f "/opt/$app/docker-compose.yml" </dev/null 2>/dev/null; then
  existed=true; APP_DIR=/opt/$app
  legacy_port=$(incus exec docker -- cat "$APP_DIR/docker-compose.yml" </dev/null 2>/dev/null |
    sed -nE 's/^[[:space:]]*-?[[:space:]]*"?([0-9.]+:)?([0-9]+):3552"?[[:space:]]*$/\2/p' | head -n1 || true)
  legacy_port=${legacy_port:-$DEFAULT_PORT}
  note "$(t "An install of the Docker setting is in %s: it is taken over as it is (port %s, same data and keys)." "$APP_DIR" "$legacy_port")"
fi
$existed || fail_fix "$(t 'Arcane is no longer maintained upstream, so a new install is refused. Use Portainer.')" "hs recipe portainer"
port_setting Arcane "$legacy_port" "$DEFAULT_PORT"
child_port_free "$PORT" "$app"
wait_internet "$ct"

step "Arcane"
dir=$APP_DIR
in_ct "Preparing the folders and the keys" "$(keys_script)" "$dir"
child_compose "$app" <<YML
# Written by "hs recipe $app". Run it again after changes; edits here are overwritten.
services:
  arcane:
    image: $IMAGE
    container_name: arcane
    restart: unless-stopped
    ports:
      - "$PORT:3552"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - arcane-data:/app/data
      - /opt/projects:/app/data/projects
    env_file: .env
    environment:
      - APP_URL=$(web)

volumes:
  arcane-data:
YML

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Arcane not started"
else
  in_ct "Downloading Arcane" 'cd "$2" && docker compose -p "$1" pull -q' "$app" "$dir"
  spin "Starting Arcane" child_up "$app"
  wait_page Arcane "docker logs --tail 30 arcane" --plain --tries 60
fi
# the install of the Docker setting is the recipe's now: forget the note that it runs from the old setup
if [ "$(cat "$state/docker-manager-legacy" 2>/dev/null || true)" = arcane ]; then rm -f "$state/docker-manager-legacy"; fi

declare_service "$app" Arcane arcane never-public Administration "Docker stacks"

recipe_facts web
box <<DONE
$(say "Login as before. A first login (an install without one): user arcane, password arcane-admin; Arcane asks for a new one right away.")
$(say "Arcane is no longer maintained upstream: for a new setup use hs recipe portainer.")
$(say "Arcane itself never gets a Zoraxy rule.")
$(docs_hint arcane)
DONE
