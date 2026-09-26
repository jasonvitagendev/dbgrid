#!/usr/bin/env bash
# Run the headless test-suite. Set DBGRID_TEST_URL to also run the Postgres integration tests.
set -euo pipefail
cd "$(dirname "$0")/.."
NVIM="${NVIM:-nvim}"
exec "$NVIM" --headless --clean -u tests/minimal_init.lua -l tests/run.lua "$@"
