#!/usr/bin/env bash
# Runs the tests of the three repositories this one was merged from (HS_CORE: the checkout of hobnix/core).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rc=0
bash "$here/run-recipes.sh" || rc=1
bash "$here/run-extensions.sh" || rc=1
bash "$here/run-capabilities.sh" || rc=1
exit "$rc"
