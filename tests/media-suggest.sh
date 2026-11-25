#!/usr/bin/env bash
# media-suggest.sh runs as root in the state folder of the media-hub service, which runs as its own user (hobnix/core#1134): after a confirmed move the
# rewritten watched.tsv goes back to the owner of the folder, and no link planted there is read or written through. A fake file manager.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
SUG=$HERE/extensions/media-hub/media-suggest.sh
export HS_MEDIA_STATE_DIR=$WORK/state HS_MEDIA_FM=$WORK/fm.sh
mkdir -p "$HS_MEDIA_STATE_DIR"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "status\\tdone\\n"\n' > "$WORK/fm.sh"; chmod +x "$WORK/fm.sh"
W=$HS_MEDIA_STATE_DIR/watched.tsv
seed() { rm -rf "$W" "$W.new"; printf '1\tmovie\t/films\n2\tother\t/films\n' > "$W"; }
move() { rc=0; out=$(timeout 60 bash "$SUG" start move-watched movie pool:small pool:large /films </dev/null 2>&1) || rc=$?; }

echo "-- a confirmed move rewrites the list"
seed; move
check_eq "exit 0" 0 "$rc"
check_eq "the moved entry is gone, the other stays" "$(printf '2\tother\t/films')" "$(cat "$W")"
check_eq "the file belongs to the owner of the folder" "$(stat -c %u "$HS_MEDIA_STATE_DIR")" "$(stat -c %u "$W")"
check_eq "no temporary file stays" "watched.tsv" "$(ls -A "$HS_MEDIA_STATE_DIR")"

echo "-- links planted by the service"
seed; echo keep > "$WORK/victim"; ln -s "$WORK/victim" "$W.new"; move
check_eq "a link at the old temporary name is not written through" "0 keep" "$rc $(cat "$WORK/victim")"
seed; printf '1\tmovie\t/films\n' > "$WORK/victim"; rm "$W"; ln -s "$WORK/victim" "$W"; move
check_eq "a list that is a link is refused" 1 "$rc"
check_eq "and the file it names is unchanged" "$(printf '1\tmovie\t/films')" "$(cat "$WORK/victim")"
rc=0; out=$(timeout 60 bash "$SUG" list </dev/null) || rc=$?
check_eq "list reads nothing through it" "0 " "$rc $out"

echo "-- the service swaps the list for a link while the move runs (after the first check)"
# the fake file manager plays the service: it replaces watched.tsv by a link to a secret and plants links where a temporary file could be
echo TOPSECRET > "$WORK/secret"; echo keep > "$WORK/victim2"
cat > "$WORK/fm-swap.sh" <<SWAP
#!/usr/bin/env bash
cat >/dev/null
rm -f "$W"; ln -s "$WORK/secret" "$W"
for n in "$HS_MEDIA_STATE_DIR"/.watched.XXXXXX "$WORK"/tmp.* "$WORK"/.watched.*; do ln -sf "$WORK/victim2" "\$n"; done
printf 'status\tdone\n'
SWAP
chmod +x "$WORK/fm-swap.sh"
seed; HS_MEDIA_FM=$WORK/fm-swap.sh move; swapout=$out
check_eq "no content of the named file leaks" 0 "$(printf '%s\n' "$swapout" | grep -c TOPSECRET || true)"
check_eq "the named file is unchanged" "TOPSECRET" "$(cat "$WORK/secret")"
check_eq "nothing is written through a planted link" "keep" "$(cat "$WORK/victim2")"
check_eq "no copy of the secret in the folder" 0 "$(grep -rl TOPSECRET "$HS_MEDIA_STATE_DIR" 2>/dev/null | grep -c . || true)"
finish
