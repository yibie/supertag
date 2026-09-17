#!/usr/bin/env bash
# One isolated executor for current contracts and named historical transitions.
set -euo pipefail
cd "$(dirname "$0")/.."
export SUPERTAG_TEST_TMP
SUPERTAG_TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/supertag-tests.XXXXXX")"
echo "Logs and isolated data: $SUPERTAG_TEST_TMP"
emacs_bin="${EMACS_BIN:-emacs}"
if [[ ${1-} == --guidance ]]; then
  exec bash test/development-entrypoints-test.sh --guidance
fi
# Every spawned test child reads its package load path from
# SUPERTAG_DEPS_LOADPATH and nothing else, so derive and export it once here;
# a machine without ht/dash stops now instead of reporting phantom failures.
source test/deps-loadpath.sh
# The static manifest is authoritative; this first process only expands names.
export SUPERTAG_TEST_SELECTION="$*"
for argument in "$@"; do
  if [[ -z "$argument" ]]; then
    echo 'Empty suite selection' >&2; exit 2
  fi
done
"$emacs_bin" -Q --batch -l test/renovation-suites.el --eval '
(let* ((input (getenv "SUPERTAG_TEST_SELECTION"))
       (names (if (equal input "") supertag-renovation-default
                (split-string input " " t))) resolved)
  (dolist (name names)
    (cond ((equal name "transition")
           (setq resolved (append resolved (cddr supertag-renovation-default))))
          ((assoc name supertag-renovation-suites)
           (setq resolved (append resolved (list name))))
          (t (error "Unknown suite: %s" name))))
  (unless resolved (error "Empty suite set"))
  (dolist (name (delete-dups resolved)) (princ (concat name "\n"))))' \
  > "$SUPERTAG_TEST_TMP/suites.txt"
while IFS= read -r suite; do
  export SUPERTAG_TEST_SUITE="$suite"
  echo "Suite: $suite"
  "$emacs_bin" -Q --batch -L . -L test -L tests --eval '
(progn
  (require (quote package))
  (package-initialize)
  (setq user-emacs-directory (file-name-as-directory (getenv "SUPERTAG_TEST_TMP"))
        supertag-data-directory (expand-file-name "data/" user-emacs-directory)
        supertag--base-data-directory supertag-data-directory
        supertag-db-file (expand-file-name "store.el" user-emacs-directory)
        supertag-db-backup-directory (expand-file-name "backups/" user-emacs-directory)
        supertag-sync-state-file (expand-file-name "sync-state.el" user-emacs-directory)
        org-id-locations-file (expand-file-name "ids" user-emacs-directory)
        load-prefer-newer t)
  (dolist (dir (list "tests" "test" "."))
    (let ((path (expand-file-name dir)))
      (setq load-path (cons path (delete path load-path)))))
  (when (equal (getenv "SUPERTAG_TEST_SUITE") "archive")
    (dolist (directory (directory-files (expand-file-name "archive") t "^[^.].*"))
      (when (and (file-directory-p directory)
                 (not (equal (file-name-nondirectory directory) "legacy-v2")))
        (add-to-list (quote load-path) directory))))
  (require (quote ert))
  ;; Explicit source-first candidate loads, even beside newer installed .elc.
  (load (expand-file-name "supertag-query.el") nil nil t)
  (load (expand-file-name "supertag-node.el") nil nil t)
  (require (quote supertag-tag))
  (require (quote supertag-services-sync))
  (supertag-node--prepare-cache-listener t)
  (load (expand-file-name "test/renovation-suites.el") nil nil t)
  (let* ((name (getenv "SUPERTAG_TEST_SUITE"))
         (entries (cdr (assoc name supertag-renovation-suites))) selected)
    (unless entries (error "Empty or unknown suite: %s" name))
    (dolist (entry entries)
      (unless (file-regular-p (car entry))
        (error "Missing required test: %s" (car entry)))
      ;; Validate each file/selector on tests defined by that file, not a
      ;; previously loaded suite. This rejects zero ERT even for selector t.
      (let ((before (ert-select-tests t t)))
        (load (expand-file-name (car entry)) nil nil t)
        (let* ((owned (cl-set-difference (ert-select-tests t t) before))
               (selector (cdr entry))
               (matches (and selector
                             (not (equal selector ""))
                             (ert-select-tests selector owned))))
          (unless matches (error "Zero ERT/empty selector: %S" entry))
          (setq selected (append selected matches)))))
    (let ((stats (ert-run-tests-batch
                  (cons (quote member) (mapcar (function ert-test-name) selected)))))
      ;; Check after execution too: a test can load archived code at runtime,
      ;; including an absolute path outside a disposable runner fixture.
      (unless (equal name "archive")
        (dolist (loaded load-history)
          (when (and (stringp (car loaded))
                     (string-match-p "/archive/" (car loaded)))
            (error "Default suite loaded archived code: %s" (car loaded)))))
      (kill-emacs (if (zerop (ert-stats-completed-unexpected stats)) 0 1)))))' \
    2>&1 | tee "$SUPERTAG_TEST_TMP/$suite.log"
  if [[ "$suite" == contract ]]; then
    bash test/development-entrypoints-test.sh 2>&1 | tee "$SUPERTAG_TEST_TMP/entrypoints.log"
  fi
done < "$SUPERTAG_TEST_TMP/suites.txt"
