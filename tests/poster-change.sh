#!/usr/bin/env bash
# hs sys ext posters list|plan|start (poster-change.sh): draw, list and delete the posters. The web API test stays in the core.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/extensions
export HS_PACKAGES_DIR=$PKGS   # the core finds the extensions here (it has none of its own)
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
T=$'\t'
export HS_POSTER_DIR=$WORK/posters
cat > "$WORK/gen-stub.sh" <<'STUB'
#!/usr/bin/env bash
# a stand-in for generate-poster.sh: writes the picture into --out and reports like the real one
out=""; seed=7; color=teal; title=x
while [ $# -gt 0 ]; do case "$1" in --out) out=$2; shift 2 ;; --seed) seed=$2; shift 2 ;; --color) color=$2; shift 2 ;; --title) title=$2; shift 2 ;; *) shift ;; esac; done
f=$out/poster-$(printf '%s' "$title" | tr 'A-Z ' 'a-z-')-$seed.png
printf 'PNG-stand-in' > "$f"
printf 'status\tok\nfile\t%s\ncolor\t%s\nseed\t%s\nsize\t1600x900\n' "$f" "$color" "$seed"
STUB
export HS_POSTER_GEN=$WORK/gen-stub.sh
run() { rc=0; out=$(timeout 60 bash "$PKGS/posters/poster-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- plan"
run plan generate --eyebrow "Movie night" --title "Dune"; check_eq "plan: exit 0" 0 "$rc"
has "Movie night" && pass "names the texts" || fail "$out"
run plan generate --eyebrow "x";                          check_eq "a title is needed" 1 "$rc"
long=$(printf 'x%.0s' $(seq 1 81))
run plan generate --eyebrow "$long" --title t;            check_eq "81 characters is too long" 1 "$rc"
run plan generate --eyebrow a --title b --color "not a colour"; check_eq "a bad colour is refused" 1 "$rc"
run plan generate --eyebrow a --title b --color '#12ab9f'; check_eq "a hex colour is fine" 0 "$rc"
run plan generate --eyebrow a --title b --seed 12x;       check_eq "a bad seed is refused" 1 "$rc"
run plan generate --eyebrow a --title b --case shout;     check_eq "a bad case is refused" 1 "$rc"
run plan generate --eyebrow a --title b --bogus;          check_eq "an unknown option is refused" 1 "$rc"

echo "-- start and list"
run start generate --eyebrow "Movie night" --title "Dune" --seed 42 --color teal; check_eq "start: exit 0" 0 "$rc"
has "^status${T}done" && pass "done" || fail "$out"
has "^file${T}poster-dune-42.png$" && pass "the file name only, no path" || fail "$out"
has "^seed${T}42" && has "^color${T}teal" && pass "seed and colour are reported" || fail "$out"
check "the picture is in the folder" test -s "$HS_POSTER_DIR/poster-dune-42.png"
run list; has "^poster-dune-42.png${T}12${T}[0-9]" && pass "the list names it with its size" || fail "$out"
echo x > "$HS_POSTER_DIR/notes.txt"; run list; check_eq "only posters are listed" 1 "$(grep -c . <<<"$out")"

echo "-- owners (hobnix/core#1134): the new picture goes to the owner of the folder, never through a link"
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$WORK/chown.log" > "$WORK/bin/chown"; chmod +x "$WORK/bin/chown"
rc=0; out=$(PATH=$WORK/bin:$PATH timeout 60 bash "$PKGS/posters/poster-change.sh" start generate --eyebrow a --title Own --seed 1 </dev/null 2>/dev/null) || rc=$?
check_eq "start with a recorded chown: exit 0" 0 "$rc"
check_eq "chown -h with the folder as the reference" "-h --reference=$HS_POSTER_DIR $HS_POSTER_DIR/poster-own-1.png" "$(cat "$WORK/chown.log")"
rm -f "$HS_POSTER_DIR/poster-own-1.png"

echo "-- delete"
run plan delete poster-dune-42.png; check_eq "delete plan: exit 0" 0 "$rc"
run plan delete ../x.png;           check_eq "a path is refused" 1 "$rc"
run plan delete poster-nothere.png; check_eq "a missing file is refused" 1 "$rc"
run start delete poster-dune-42.png; check_eq "delete start: exit 0" 0 "$rc"
check "it is gone" test ! -e "$HS_POSTER_DIR/poster-dune-42.png"

echo "-- the real drawing (Pillow)"
if python3 -c "import PIL" 2>/dev/null; then
  export HS_POSTER_GEN=$PKGS/posters/generate-poster.sh
  run start generate --eyebrow "Test" --title "Real" --seed 5
  check_eq "drawn: exit 0" 0 "$rc"
  has "^file${T}poster-real-5.png$" && pass "the real file name" || fail "$out"
  check "a PNG was written" test "$(head -c 4 "$HS_POSTER_DIR/poster-real-5.png" | tail -c 3)" = PNG
  # a link planted where the poster goes: the file it names is not written
  echo keep > "$WORK/victim"; ln -sf "$WORK/victim" "$HS_POSTER_DIR/poster-real-6.png"
  run start generate --eyebrow "Test" --title "Real" --seed 6
  check_eq "drawn over a planted link: exit 0" 0 "$rc"
  check_eq "the file the link named is unchanged" keep "$(cat "$WORK/victim")"
  check "the link was replaced by the picture" test ! -L "$HS_POSTER_DIR/poster-real-6.png"
else
  skip "Pillow is not installed"
fi
echo "-- the state folder: \$STATE_DIRECTORY in the unit, never /var/lib/hs"
SD=$WORK/unit/posters; mkdir -p "$SD"
rc=0; out=$(env -u HS_POSTER_DIR STATE_DIRECTORY="$SD" HS_STATE_DIR="$WORK/nowhere" timeout 60 bash "$PKGS/posters/poster-change.sh" start generate --eyebrow a --title Unit --seed 3 </dev/null 2>/dev/null) || rc=$?
check_eq "start in the unit: exit 0" 0 "$rc"
check "the picture is in STATE_DIRECTORY" test -s "$SD/poster-unit-3.png"
check "nothing was made under HS_STATE_DIR" test ! -e "$WORK/nowhere"
rc=0; out=$(env -u HS_POSTER_DIR STATE_DIRECTORY="$SD:/other" timeout 60 bash "$PKGS/posters/poster-change.sh" list </dev/null 2>/dev/null) || rc=$?
check_eq "list reads STATE_DIRECTORY (first entry)" "poster-unit-3.png" "$(cut -f1 <<<"$out")"
mkdir -p "$WORK/ext/posters"; echo PNG > "$WORK/ext/posters/poster-root-1.png"
rc=0; out=$(env -u HS_POSTER_DIR -u STATE_DIRECTORY HS_EXT_DIR="$WORK/ext" HS_STATE_DIR="$WORK/nowhere" timeout 60 bash "$PKGS/posters/poster-change.sh" list </dev/null 2>/dev/null) || rc=$?
check_eq "a root tool finds the folder through hs-ext" "poster-root-1.png" "$(cut -f1 <<<"$out")"
rc=0; out=$(env -u HS_POSTER_DIR -u STATE_DIRECTORY HS_EXT_DIR="$WORK/none" HS_STATE_DIR="$WORK/none" timeout 60 bash "$PKGS/posters/poster-change.sh" start generate --eyebrow a --title No --seed 4 </dev/null 2>/dev/null) || rc=$?
check_eq "no folder known: refused, exit 1" 1 "$rc"
grep -q 'STATE_DIRECTORY is not set' <<<"$out" && pass "the refusal names STATE_DIRECTORY" || fail "$out"

finish
