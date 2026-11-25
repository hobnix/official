#!/usr/bin/env bash
# help: storage suggestions of the media hub: watched media that could move from the small pool to the large one (a person confirms, nothing runs alone)
# help.de: Speichervorschläge des Medien-Hubs: gesehene Medien, die vom kleinen Pool auf den großen wandern könnten (eine Person bestätigt, nichts läuft von allein)
# args: list | plan|start move-watched <name> <from> <to> <path>
# System command (hs sys ext media-hub suggestions | plan | start): for the interface and tests. It never asks. The service (media-svc.py) keeps
# watched.tsv (epoch TAB name TAB folder) of what was watched; this script only SUGGESTS. A suggestion becomes a file-manager job (`fm.sh start move`) only
# through the plan and start of the web dialog, i.e. after the person saw the plan and confirmed; nothing here starts a job on its own.
#   list          one row per suggestion: name, from, to, path, days since it was watched. Empty when there is only one writable pool, or nothing
#                 was watched more than HS_MEDIA_SUGGEST_DAYS (default 30) ago. HEURISTIC, unverified: from = the smallest writable pool, to = the largest;
#                 the folder is the one the app reported and is assumed to exist at the same place in both pools (the file manager's plan refuses if not).
#   plan|start    the file manager's plan / start for `move`, only for a row of watched.tsv. exit 0 = ok, 1 = refused.
# Test knobs: HS_MEDIA_STATE_DIR, HS_MEDIA_FM (a program called like fm.sh), HS_MEDIA_NOW (epoch), HS_MEDIA_SUGGEST_DAYS.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scripts=${HS_SCRIPTS:-$here/../../scripts}
dir=${HS_MEDIA_STATE_DIR:-/var/lib/hs/media-hub}
now=${HS_MEDIA_NOW:-$(date +%s)}
days=${HS_MEDIA_SUGGEST_DAYS:-30}
fm() { if [ -n "${HS_MEDIA_FM:-}" ]; then "$HS_MEDIA_FM" "$@"; else bash "$scripts/fm.sh" "$@"; fi; }

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }
# the service owns the folder (it runs as its own user, hobnix/core#1134) and this script runs as root: a link there could name any file, and the service
# can swap the file for a link at any moment. So no root step opens or writes a path of that folder by name: wl (python3 -I) opens the folder, then the
# file relative to it with O_NOFOLLOW, accepts only a regular file, and a rewrite is made in a folder only root can enter and renamed into place with a
# final lchown to the owner of the folder (the file itself, never what a link names). A link anywhere: nothing is read, nothing is written.
wl() { python3 -I -c '
import os, stat, sys, tempfile
d, mode = sys.argv[1], sys.argv[2]
dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
fd = os.open("watched.tsv", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
if not stat.S_ISREG(os.fstat(fd).st_mode):
    sys.exit(3)
data = os.fdopen(fd, "rb").read()
if mode == "read":
    sys.stdout.buffer.write(data); sys.exit(0)
name, path = sys.argv[3].encode(), sys.argv[4].encode()
keep = []
for l in data.splitlines(keepends=True):
    f = l.rstrip(b"\n").split(b"\t")
    if not (len(f) == 3 and f[1] == name and f[2] == path):
        keep.append(l)
owner = os.fstat(dfd)
t = tempfile.mkdtemp(dir=os.path.dirname(os.path.abspath(d)))   # mode 0700, root only
try:
    tf = os.path.join(t, "w")
    with open(tf, "wb") as o:
        o.write(b"".join(keep))
    os.lchown(tf, owner.st_uid, owner.st_gid)
    tfd = os.open(t, os.O_RDONLY | os.O_DIRECTORY)
    os.rename("w", "watched.tsv", src_dir_fd=tfd, dst_dir_fd=dfd)
finally:
    for x in os.listdir(t):
        os.unlink(os.path.join(t, x))
    os.rmdir(t)
' "$dir" "$@" 2>/dev/null; }

if [ "${1:-}" = list ]; then
  rows=$(wl read) || exit 0   # a link, or no file: nothing is read
  [ -n "$rows" ] || exit 0
  [[ "$days" =~ ^[0-9]{1,4}$ ]] || exit 0
  pools=$(fm locations 2>/dev/null | awk -F'\t' '$1 == "loc" && $3 == "pool" && $8 == "yes" { print $6 "\t" $2 }' | sort -n)
  [ "$(printf '%s\n' "$pools" | grep -c .)" -ge 2 ] || exit 0
  from=$(sed -n 1p <<<"$pools" | cut -f2); to=$(tail -n1 <<<"$pools" | cut -f2)
  awk -F'\t' -v now="$now" -v days="$days" -v from="$from" -v to="$to" \
    'NF == 3 && now - $1 >= days * 86400 { printf "%s\t%s\t%s\t%s\t%d\n", $2, from, to, $3, (now - $1) / 86400 }' <<<"$rows" | sort -t$'\t' -k5,5nr
  exit 0
fi

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: media-suggest.sh list | plan|start move-watched <name> <from> <to> <path>" >&2; exit 1 ;; esac
[ "$action" = move-watched ] || refuse "unknown action (move-watched)"
[ $# -eq 6 ] || refuse "move-watched needs a name, two places and a folder"
name=$3; from=$4; to=$5; path=$6
[[ "$name" != */* && "$name" != *..* && "$name" != *[[:cntrl:]]* && -n "$name" ]] || refuse "The name is a file name without a slash."
[[ "$from" =~ ^(pool|disk):[a-z0-9-]{1,32}$ && "$to" =~ ^pool:[a-z0-9-]{1,32}$ ]] || refuse "The places are pool:<name> or disk:<name>."
[ "$from" != "$to" ] || refuse "The two places are the same."
[[ "$path" == /* && "$path" != *..* && "$path" != *[[:cntrl:]]* ]] || refuse "The folder is a path that starts with a slash, without ..."
rows=$(wl read) || refuse "The list of what was watched is missing or a link; nothing was read."
awk -F'\t' -v n="$name" -v p="$path" 'NF == 3 && $2 == n && $3 == p { f = 1 } END { exit !f }' <<<"$rows" || refuse "$name is not in the list of what was watched."

selection() { printf '%s\0' "$name"; }
if [ "$verb" = plan ]; then
  out=$(selection | fm plan move --from "$from" --path "$path" --to "$to" --to-path "$path" 2>&1) && rc=0 || rc=$?
  printf '%s\n' "$out"
  exit "$rc"
fi
out=$(selection | fm start move --from "$from" --path "$path" --to "$to" --to-path "$path" 2>&1) && rc=0 || rc=$?
printf '%s\n' "$out"
if [ "$rc" -eq 0 ] && grep -q '^status.done' <<<"$out"; then   # it is moved: the entry is no suggestion any more
  wl remove "$name" "$path" || true   # a link planted meanwhile: nothing is written, the next call refuses
fi
exit "$rc"
