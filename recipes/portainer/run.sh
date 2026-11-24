#!/usr/bin/env bash
# recipe: Portainer: a web page to look after your Docker containers, images and stacks (admin page, never public)
# recipe.de: Portainer: eine Webseite für deine Docker-Container, Images und Stacks (Verwaltungsseite, nie öffentlich)
# kind: generic
# needs: docker
# uses: -
# runs: docker
set -euo pipefail

# What it does: runs Portainer CE as a compose project inside the container docker (hs docker enable). Portainer is the offered manager of
# Docker: containers, images, stacks. The Docker page of the web interface does not need it.
#   port 9000  its web page, for the home network only (it controls Docker: an admin page, never a Zoraxy rule)
#   data       the volume portainer-data; /opt/projects of the container is reachable inside Portainer
# A Portainer that the Docker setting installed before (/opt/portainer in the container docker, port 80) is taken over where it is: same
# folder, same volume, same port. The old compose file is kept once as docker-compose.yml.before-recipe; the recipe owns the project from then on.
# Portainer serves HTTPS on 9443 and, only with --http-enabled, HTTP on 9000; the plain port is published (home network, behind nothing).
# Test knobs: RECIPE_NAME=<throwaway name> HS_STATE_DIR=/tmp/<dir> RECIPE_SKIP_PULL=1
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
state=${HS_STATE_DIR:-/var/lib/hs}
ct=${RECIPE_NAME:-portainer}; app=$ct
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"
IMAGE=portainer/portainer-ce:2.45.4   # the current LTS release (github.com/portainer/portainer/releases: "Release 2.45.4 LTS", 2026-11-18; the tag exists on Docker Hub)
DEFAULT_PORT=9000

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  say "  run Portainer CE as a compose project in the container docker (which must be on: hs docker enable), page on port 9000"
  say "  take over an existing /opt/portainer there as it is (same data and port), keeping its compose file once as docker-compose.yml.before-recipe"
  say "  declare the service never-public (an admin page: no Zoraxy rule)"
  exit 0
fi

recipe_runtime docker
# An install of the old Docker setting lives in /opt/<name> of the container docker: use it in place (unless the recipe has its own folder already)
adopted=false; legacy_port=$DEFAULT_PORT
if ! $existed && incus exec docker -- test -f "/opt/$app/docker-compose.yml" </dev/null 2>/dev/null; then
  adopted=true; existed=true; APP_DIR=/opt/$app
  legacy_port=$(incus exec docker -- cat "$APP_DIR/docker-compose.yml" </dev/null 2>/dev/null |
    sed -nE 's/^[[:space:]]*-?[[:space:]]*"?([0-9.]+:)?([0-9]+):9000"?[[:space:]]*$/\2/p' | head -n1 || true)
  legacy_port=${legacy_port:-$DEFAULT_PORT}
  note "$(t "An install of the Docker setting is in %s: it is taken over as it is (port %s, same data)." "$APP_DIR" "$legacy_port")"
fi
port_setting Portainer "$legacy_port" "$DEFAULT_PORT"
child_port_free "$PORT" "$app"
wait_internet "$ct"

step "Portainer"
dir=$APP_DIR
in_ct "Preparing the folders" 'mkdir -p "$1" /opt/projects && cd "$1" &&
  if [ -f docker-compose.yml ] && ! grep -q "^# Written by \"hs recipe $2\"" docker-compose.yml && [ ! -e docker-compose.yml.before-recipe ]; then cp -p docker-compose.yml docker-compose.yml.before-recipe; fi' "$dir" "$app"
child_compose "$app" <<YML
# Written by "hs recipe $app". Run it again after changes; edits here are overwritten.
services:
  portainer:
    image: $IMAGE
    container_name: portainer
    restart: unless-stopped
    command: --http-enabled
    ports:
      - "$PORT:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer-data:/data
      - /opt/projects:/opt/projects

volumes:
  portainer-data:
YML

if [ -n "${RECIPE_SKIP_PULL:-}" ]; then
  note "skipped (RECIPE_SKIP_PULL): nothing downloaded, Portainer not started"
else
  in_ct "Downloading Portainer" 'cd "$2" && docker compose -p "$1" pull -q' "$app" "$dir"
  spin "Starting Portainer" child_up "$app"
  wait_page Portainer "docker logs --tail 30 portainer" --plain --tries 60
fi
# the install of the Docker setting is the recipe's now: forget the note that it runs from the old setup
if [ "$(cat "$state/docker-manager-legacy" 2>/dev/null || true)" = portainer ]; then rm -f "$state/docker-manager-legacy"; fi

declare_service "$app" Portainer portainer never-public Administration "Docker containers and stacks"

recipe_facts web
box <<DONE
$(say "First visit: Portainer asks for the admin account right away. It waits only about 5 minutes after it starts;")
$(say "if the page says it timed out: incus exec docker -- docker restart portainer, then open it again.")
$(say "Portainer itself never gets a Zoraxy rule.")
$(docs_hint portainer)
DONE
