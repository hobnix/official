#!/usr/bin/env bash
# Runs every tests/*.sh of this repository against a checkout of the core: HS_CORE=<folder of hobnix/core> bash tests/run-all.sh [name...]
# (CI checks the core out into ./core). A test that exits 77 counts as skipped (a tool is missing); inside a test, HS_TEST_CI=1 makes a missing
# Python module or tool a failure. Each test gets no stdin and at most HS_TEST_TIMEOUT seconds (default 600); progress is printed live.
here=$(cd "$(dirname "$0")" && pwd)
limit=${HS_TEST_TIMEOUT:-600}
bad=0
if [ $# -gt 0 ]; then set -- "${@/%/.sh}"; else set -- $(cd "$here" && ls *.sh | grep -v '^run-'); fi
for t in "$@"; do
  n=${t%.sh}
  echo "start $n"
  t0=$SECONDS
  out=$(HS_CORE="${HS_CORE:-}" REQUIRE_ALL=${HS_TEST_CI:+1} timeout "$limit" bash "$here/$t" 2>&1 </dev/null); rc=$?
  s=$((SECONDS - t0))
  case $rc in
    0) echo "ok    $n  ${s}s" ;;
    77) echo "skip  $n  ${s}s" ;;
    124) echo "FAIL  $n  ${s}s"; echo "timed out after $limit s"; bad=1 ;;
    *) echo "FAIL  $n  ${s}s"; printf '%s\n' "$out" | grep -E 'FAIL|no core' | head -20; bad=1 ;;
  esac
done
exit $bad
