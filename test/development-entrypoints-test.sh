#!/usr/bin/env bash
# Real negative executions in a disposable source copy; no production mutation.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ${1-} == --guidance ]]; then
  bash test/static-gates.sh
  python3 - <<'PY'
from pathlib import Path
import re
for name in ('README.md', 'README_CN.md', 'test/README.md', 'test/refactor-batch1-manifest.md'):
    path = Path(name)
    text = path.read_text()
    section = text.split('<!-- P1 development -->', 1)[1].split('<!-- /P1 development -->', 1)[0]
    assert 'bash test/run-tests.sh' in section, name
    for target in re.findall(r'\]\(([^)]+)\)', section):
        if '://' not in target:
            assert (path.parent / target.split('#')[0]).exists(), (name, target)
contributing = Path('.github/CONTRIBUTING.org').read_text()
assert 'bash test/run-tests.sh' in contributing
for target in re.findall(r'\[\[file:([^]]+)\]', contributing):
    assert (Path('.github') / target).exists(), target
workflow = Path('.github/workflows/test.yml').read_text()
assert 'run: bash test/run-tests.sh' in workflow
assert 'run: bash test/run-tests.sh --guidance' in workflow
assert 'archive_board' in workflow and 'gitignore:' in workflow
print('P1 guidance links, commands and CI entrypoints: PASS')
PY
  exit
fi
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/supertag-entrypoints.XXXXXX")"
echo "Runner counterexamples: $probe_root"
mkdir -p "$probe_root/tree/test"
cp ./*.el "$probe_root/tree/"
cp test/run-tests.sh "$probe_root/tree/test/"
cat > "$probe_root/tree/test/probe.el" <<'ELISP'
(require 'ert)
(ert-deftest probe-pass () (should t))
ELISP
manifest() {
  cat > "$probe_root/tree/test/renovation-suites.el" <<ELISP
(defconst supertag-renovation-default '("probe"))
(defconst supertag-renovation-suites '(("probe" ("test/probe.el" . $1))))
ELISP
}
reject() {
  local label="$1" expected="$2" result
  shift 2
  set +e
  bash "$probe_root/tree/test/run-tests.sh" "$@" > "$probe_root/$label.log" 2>&1
  result=$?
  set -e
  echo "$label exit=$result" | tee -a "$probe_root/exit-codes.txt"
  [[ $result -ne 0 ]] || { echo "Expected failure: $label" >&2; exit 1; }
  grep -q "$expected" "$probe_root/$label.log"
}
manifest t
bash "$probe_root/tree/test/run-tests.sh" probe > "$probe_root/control.log" 2>&1
echo 'control exit=0' | tee -a "$probe_root/exit-codes.txt"
reject unknown 'Unknown suite' not-a-suite
reject empty 'Empty suite selection' ''
mv "$probe_root/tree/test/probe.el" "$probe_root/tree/test/probe.saved"
reject missing 'Missing required test' probe
printf '(require '\''ert)\n' > "$probe_root/tree/test/probe.el"
reject zero-ert 'Zero ERT' probe
mv "$probe_root/tree/test/probe.saved" "$probe_root/tree/test/probe.el"
manifest '"does-not-match"'
reject no-match 'Zero ERT' probe
manifest '(unknown-selector)'
reject unknown-selector 'selector' probe
manifest '""'
reject empty-selector 'Zero ERT/empty selector' probe
manifest nil
reject nil-selector 'Zero ERT/empty selector' probe
cat > "$probe_root/tree/test/renovation-suites.el" <<'ELISP'
(defconst supertag-renovation-default '("probe"))
(defconst supertag-renovation-suites '(("probe")))
ELISP
reject empty-set 'Empty or unknown suite' probe
manifest t
cat > "$probe_root/tree/test/probe.el" <<'ELISP'
(require 'ert)
(ert-deftest probe-failure () (should nil))
ELISP
reject tee-failure '1 unexpected' probe
mkdir -p "$probe_root/outside/archive"
archive_probe_file="$(cd "$probe_root/outside/archive" && pwd -P)/query-a-probe.el"
cat > "$archive_probe_file" <<'ELISP'
(provide 'supertag-query-a-archive-probe)
ELISP
cat > "$probe_root/tree/test/probe.el" <<ELISP
(require 'ert)
(ert-deftest probe-runtime-archive ()
  (load "$archive_probe_file" nil nil t)
  (should (featurep 'supertag-query-a-archive-probe))
  (princ "QUERY-A-ARCHIVE-LOADED\n"))
ELISP
reject runtime-archive 'Default suite loaded archived code' probe
grep -Fq 'QUERY-A-ARCHIVE-LOADED' "$probe_root/runtime-archive.log"
grep -Fq 'Ran 1 tests, 1 results as expected, 0 unexpected' "$probe_root/runtime-archive.log"
echo 'Runner counterexamples: PASS'
