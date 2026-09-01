#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMACS_BIN="${EMACS:-emacs}"
if ! command -v "$EMACS_BIN" >/dev/null 2>&1 && [[ ! -x "$EMACS_BIN" ]]; then
  printf 'Emacs executable not found: %s\n' "$EMACS_BIN" >&2
  exit 127
fi
ARGS=( -Q --batch -L "$ROOT" -L "$ROOT/tests" )
if [[ -n "${SUPERTAG_HT_DIR:-}" ]]; then
  ARGS+=( -L "$SUPERTAG_HT_DIR" )
fi
exec "$EMACS_BIN" "${ARGS[@]}" \
  -l ert \
  -l "$ROOT/tests/supertag-ontology-action-test.el" \
  -l "$ROOT/tests/supertag-ontology-policy-test.el" \
  -f ert-run-tests-batch-and-exit
