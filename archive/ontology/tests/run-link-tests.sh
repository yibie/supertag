#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMACS_BIN="${EMACS:-emacs}"

if ! command -v "$EMACS_BIN" >/dev/null 2>&1 && [[ ! -x "$EMACS_BIN" ]]; then
  printf 'Emacs executable not found: %s\n' "$EMACS_BIN" >&2
  printf 'Set EMACS=/absolute/path/to/Emacs when necessary.\n' >&2
  exit 127
fi

args=(
  -Q --batch
  -L "$ROOT"
  -L "$ROOT/tests"
)

if [[ -n "${SUPERTAG_HT_DIR:-}" ]]; then
  args+=( -L "$SUPERTAG_HT_DIR" )
fi

if [[ -n "${SUPERTAG_EXTRA_LOAD_PATH:-}" ]]; then
  IFS=':' read -r -a extra_paths <<< "$SUPERTAG_EXTRA_LOAD_PATH"
  for path in "${extra_paths[@]}"; do
    [[ -n "$path" ]] && args+=( -L "$path" )
  done
fi

exec "$EMACS_BIN" "${args[@]}" \
  -l ert \
  -l "$ROOT/tests/supertag-ontology-test.el" \
  -l "$ROOT/tests/supertag-link-test.el" \
  -f ert-run-tests-batch-and-exit
