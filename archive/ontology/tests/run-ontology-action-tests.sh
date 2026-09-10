#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMACS_BIN="${EMACS:-emacs}"
ARGS=( -Q --batch -L "$ROOT" -L "$ROOT/tests" )
if [[ -n "${SUPERTAG_HT_DIR:-}" ]]; then
  ARGS+=( -L "$SUPERTAG_HT_DIR" )
fi
exec "$EMACS_BIN" "${ARGS[@]}" \
  -l ert \
  -l "$ROOT/tests/supertag-ontology-action-test.el" \
  -f ert-run-tests-batch-and-exit
