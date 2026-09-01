#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMACS_BIN="${EMACS:-emacs}"
if ! command -v "$EMACS_BIN" >/dev/null 2>&1 && [[ ! -x "$EMACS_BIN" ]]; then
  printf 'Emacs executable not found: %s\n' "$EMACS_BIN" >&2
  exit 127
fi
ARGS=( -Q --batch -L "$ROOT" -L "$ROOT/tests" )
[[ -n "${SUPERTAG_HT_DIR:-}" ]] && ARGS+=( -L "$SUPERTAG_HT_DIR" )
exec "$EMACS_BIN" "${ARGS[@]}" \
  -l ert \
  -l "$ROOT/tests/supertag-ontology-test.el" \
  -l "$ROOT/tests/supertag-ontology-control-plane-test.el" \
  -l "$ROOT/tests/supertag-link-test.el" \
  -l "$ROOT/tests/supertag-link-workflow-test.el" \
  -l "$ROOT/tests/supertag-reference-workflow-test.el" \
  -l "$ROOT/tests/supertag-unlinked-mention-test.el" \
  -l "$ROOT/tests/supertag-ontology-migration-test.el" \
  -f ert-run-tests-batch-and-exit
