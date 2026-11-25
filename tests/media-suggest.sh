#!/usr/bin/env bash
# media-suggest.sh runs as root in the state folder of the media-hub service, which runs as its own user (hobnix/core#1134): after a confirmed move the
# rewritten watched.tsv goes back to the owner of the folder, and no link planted there is read or written through. A fake file manager and chown.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
SUG=$HERE/extensions/media-hub/media-suggest.sh
export HS_MEDIA_STATE_DIR=$WORK/state HS_MEDIA_FM=$WORK/fm.sh
mkdir -p "$HS_MEDIA_STATE_DIR" "$WORK/bin"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "status\\tdone\\n"\n' > "$WORK/fm.sh"; chmod +x "$WORK/fm.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$WORK/chown.log" > "$WORK/bin/chown"; chmod +x "$WORK/bin/chown"
W=$HS_MEDIA_STATE_DIR/watched.tsv
seed() { rm -rf "$W" "$W.new" "$WORK/chown.log"; printf '1\tmovie\t/films\n2\tother\t/films\n' > "$W"; }
move() { rc=0; out=$(PATH=$WORK/bin:$PATH timeout 60 bash "$SUG" start move-watched movie pool:small pool:large /films </dev/null 2>&1) || rc=$?; }

echo "-- a confirmed move rewrites the list"
seed; move
check_eq "exit 0" 0 "$rc"
check_eq "the moved entry is gone, the other stays" "$(printf '2\tother\t/films')" "$(cat "$W")"
check_eq "chown -h with the folder as the reference, once" "1" "$(grep -c -- "^-h --reference=$HS_MEDIA_STATE_DIR $HS_MEDIA_STATE_DIR/.watched\." "$WORK/chown.log")"
check_eq "no temporary file stays" "watched.tsv" "$(ls -A "$HS_MEDIA_STATE_DIR")"

echo "-- links planted by the service"
seed; echo keep > "$WORK/victim"; ln -s "$WORK/victim" "$W.new"; move
check_eq "a link at the old temporary name is not written through" "0 keep" "$rc $(cat "$WORK/victim")"
seed; printf '1\tmovie\t/films\n' > "$WORK/victim"; rm "$W"; ln -s "$WORK/victim" "$W"; move
check_eq "a list that is a link is refused" 1 "$rc"
check_eq "and the file it names is unchanged" "$(printf '1\tmovie\t/films')" "$(cat "$WORK/victim")"
rc=0; out=$(timeout 60 bash "$SUG" list </dev/null) || rc=$?
check_eq "list reads nothing through it" "0 " "$rc $out"
finish
