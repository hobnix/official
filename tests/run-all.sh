#!/usr/bin/env bash
# Runs every test of this repository (HS_CORE: the checkout of hobnix/core). The tests of recipes, extensions and
# capabilities live side by side in tests/, so there is one runner: run-tests.sh.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
exec bash "$here/run-tests.sh" "$@"
