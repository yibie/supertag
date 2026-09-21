#!/usr/bin/env bash
# Historical pathname, same current executor and static suite names.
set -euo pipefail
cd "$(dirname "$0")/.."
exec bash test/run-tests.sh "$@"
