#!/usr/bin/env bash
# The recipes portainer and arcane (hobnix/core#1079): they run in the container docker, are never public, pin their image, take over an
# install of the old Docker setting in /opt/<name> and keep the Arcane keys. No incus, no docker, no root.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
R=$HERE/recipes

echo "-- both recipes"
for n in portainer arcane; do
  f=$R/$n/run.sh; m=$R/$n/package.toml
  check "$n: runs only in docker, needs docker, provides docker-manager" bash -c 'grep -q "^runs = \[\"docker\"\]" "$1" && grep -q "^needs = \[\"docker\"\]" "$1" && grep -q "provides = \[\"docker-manager\"\]" "$1"' _ "$m"
  check "$n: the route is an admin page and never public" bash -c 'grep -q "never-public" "$1" && grep -q "admin = true" "$1"' _ "$m"
  check "$n: the service is declared never-public" grep -qE "^declare_service \"\\\$app\" .* never-public Administration" "$f"
  check "$n: the image is pinned (no :latest)" bash -c 'grep -qE "^IMAGE=[^ ]+:[0-9v][0-9.]+" "$1" && ! grep -q ":latest\|:lts" "$1"' _ "$f"
  check "$n: the old install in /opt/<name> is adopted in place" grep -q 'APP_DIR=/opt/\$app' "$f"
  check "$n: the old compose file is kept once" grep -q 'docker-compose.yml.before-recipe' "$f"
  check "$n: the legacy note is removed after a successful run" grep -q 'rm -f "\$state/docker-manager-legacy"' "$f"
  check "$n: ends with docs_hint" grep -q '^\$(docs_hint '"$n"')$' "$f"
  check "$n: has a guide that says what was not tested" grep -q 'Not tested on hardware yet' "$R/$n/guide.md"
  check "$n: no secret on the command line" bash -c '! grep -qiE "(password|secret|token)=" <(grep -v "^#" "$1" | grep -v "JWT_SECRET\|ENCRYPTION_KEY")' _ "$f"
  check "$n: bash -n" bash -n "$f"
done
check "portainer: default port 9000, HTTP enabled, a data volume" bash -c 'grep -q "^DEFAULT_PORT=9000" "$1" && grep -q -- "--http-enabled" "$1" && grep -q "portainer-data:/data" "$1"' _ "$R/portainer/run.sh"
check "arcane: default port 3552 and a data volume" bash -c 'grep -q "^DEFAULT_PORT=3552" "$1" && grep -q "arcane-data:/app/data" "$1"' _ "$R/arcane/run.sh"
check "arcane: a fresh install is refused and points to portainer" bash -c 'grep -q "fail_fix .*no longer maintained" "$1" && grep -q "hs recipe portainer" "$1"' _ "$R/arcane/run.sh"
check "arcane: says it is deprecated in the manifest" grep -q '^title = "deprecated' "$R/arcane/package.toml"

echo "-- the port of an old install is read from its compose file"
for line in '      - "80:9000"' '    ports: ["80:9000"]' '      - 80:9000' '      - "0.0.0.0:80:9000"'; do
  got=$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*-?[[:space:]]*"?([0-9.]+:)?([0-9]+):9000"?[[:space:]]*$/\2/p')
  case "$line" in *'ports:'*) want="" ;; *) want=80 ;; esac
  check_eq "portainer: $line" "$want" "$got"
done

echo "-- the arcane keys: made once, carried over from an older install, never new ones over stored data"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
# a stand-in: `docker volume ls -q` lists what DOCKER_VOLUMES says
[ "$1 $2" = "volume ls" ] && printf '%s\n' ${DOCKER_VOLUMES:-}
exit 0
EOF
chmod +x "$WORK/bin/docker"
snippet=$(sed -n '/^keys_script() {/,/^}/p' "$R/arcane/run.sh")
[ -n "$snippet" ] || { echo "FAIL: keys_script not found in the recipe"; exit 1; }
keys=$(bash -c "$snippet; keys_script")
prep() {   # prep <dir>: the key script of the recipe in that directory (as inside the container: bash, set -euo pipefail)
  ARCANE_DIR=$1 PROJECTS_DIR=$1/projects PATH="$WORK/bin:$PATH" bash -c "set -euo pipefail; $keys" 2>&1
}
d=$WORK/a1; mkdir -p "$d"; prep "$d" >/dev/null
check_eq "a fresh install gets two new keys (64 hex characters each)" "2" "$(grep -cE '^(ENCRYPTION_KEY|JWT_SECRET)=[0-9a-f]{64}$' "$d/.env")"
cp "$d/.env" "$d/.env.first"; prep "$d" >/dev/null
check "and a second run leaves the .env alone" cmp -s "$d/.env" "$d/.env.first"

d=$WORK/a2; mkdir -p "$d"
printf 'services:\n  arcane:\n    image: x\n    environment:\n      - ENCRYPTION_KEY=oldkey1111\n      - JWT_SECRET=oldjwt2222\n      - APP_URL=http://x\n' > "$d/docker-compose.yml"
DOCKER_VOLUMES="arcane_arcane-data" prep "$d" >/dev/null
check_eq "the keys of an older compose file (list form) are carried over" "ENCRYPTION_KEY=oldkey1111 JWT_SECRET=oldjwt2222" "$(tr '\n' ' ' < "$d/.env" | sed 's/ $//')"
check "and that compose file is kept once (it is not the recipe's)" test -e "$d/docker-compose.yml.before-recipe"

d=$WORK/a3; mkdir -p "$d"
printf 'services:\n  arcane:\n    environment:\n      - APP_URL=http://x\n      - ENCRYPTION_KEY=onlykey3333\n' > "$d/docker-compose.yml"
DOCKER_VOLUMES="arcane_arcane-data" prep "$d" >/dev/null
check_eq "an older install with only an ENCRYPTION_KEY keeps it" "ENCRYPTION_KEY=onlykey3333" "$(grep '^ENCRYPTION_KEY=' "$d/.env")"
check_eq "and gets a new JWT_SECRET (it only signs logins)" "1" "$(grep -cE '^JWT_SECRET=[0-9a-f]{64}$' "$d/.env")"

d=$WORK/a4; mkdir -p "$d"
printf 'services:\n  arcane:\n    environment:\n      - ENCRYPTION_KEY=${ENCRYPTION_KEY}\n      - JWT_SECRET=${JWT_SECRET}\n' > "$d/docker-compose.yml"
out=$(DOCKER_VOLUMES="arcane_arcane-data" prep "$d" || true)
check_out "placeholders are no keys: with stored data it refuses, and says why" "lock you out" echo "$out"
check "and writes no .env" test ! -e "$d/.env"
check_eq "and exits 1" "1" "$(DOCKER_VOLUMES=arcane_arcane-data prep "$d" >/dev/null; echo $?)"

d=$WORK/a5; mkdir -p "$d"; printf 'ENCRYPTION_KEY=mine\nJWT_SECRET=mine2\n' > "$d/.env"
printf 'services:\n  arcane:\n    environment:\n      - ENCRYPTION_KEY=other\n      - JWT_SECRET=other2\n' > "$d/docker-compose.yml"
prep "$d" >/dev/null
check_eq "an existing .env wins: it is never replaced" "ENCRYPTION_KEY=mine JWT_SECRET=mine2" "$(tr '\n' ' ' < "$d/.env" | sed 's/ $//')"

d=$WORK/a6; mkdir -p "$d"; printf '# Written by "hs recipe arcane". Run it again after changes; edits here are overwritten.\nservices: {}\n' > "$d/docker-compose.yml"
prep "$d" >/dev/null
check "a compose file the recipe wrote is not kept (nothing of an older install in it)" test ! -e "$d/docker-compose.yml.before-recipe"

finish
