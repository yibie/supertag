#!/usr/bin/env bash
# Compile only a disposable copy; never leave .elc/.eln in the checkout.
set -euo pipefail
cd "$(dirname "$0")/.."
source test/deps-loadpath.sh
root=$(mktemp -d "${TMPDIR:-/tmp}/supertag-compile.XXXXXX")
export SUPERTAG_COMPILE_ROOT="$root"
cp supertag*.el "$root/"
# package-vc scans subdirectories too. Include published development files,
# using working-tree content rather than committed versions of those files.
while IFS= read -r file; do
  mkdir -p "$root/$(dirname "$file")"
  cp "$file" "$root/$file"
done < <({ git ls-files -- 'test/*.el' 'scripts/*.el';
           printf '%s\n' test/compiler-regression-test.el; } | sort -u)
cp test/.dir-locals.el "$root/test/"
cp scripts/.dir-locals.el "$root/scripts/"
cp .elpaignore "$root/"
args=()
for directory in "${SUPERTAG_DEPS_DIRS[@]}"; do args+=(-L "$directory"); done
cat > "$root/check.el" <<'ELISP'
;;; check.el -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'bytecomp)
(setq user-emacs-directory (expand-file-name "runtime/" (getenv "SUPERTAG_COMPILE_ROOT"))
      supertag-data-directory (expand-file-name "data/" user-emacs-directory))
(let* ((root (getenv "SUPERTAG_COMPILE_ROOT"))
       (files (append (directory-files root t "^supertag.*\\.el$")
                      (directory-files-recursively (expand-file-name "test" root) "\\.el$")
                      (directory-files-recursively (expand-file-name "scripts" root) "\\.el$")))
       (native (equal (getenv "SUPERTAG_COMPILE_KIND") "native"))
       (compiled 0) (skipped 0))
  (when native
    (require 'comp)
    (unless (native-comp-available-p) (error "Native compilation is unavailable"))
    (startup-redirect-eln-cache (expand-file-name "eln/" user-emacs-directory)))
  (dolist (file files)
    (let ((result (if native (native-compile file) (byte-compile-file file))))
      (cond
       ((or (eq result 'no-byte-compile) (and native (null result)))
        (unless (or (equal (file-name-nondirectory file) "supertag-view-tag-cards.el")
                    (file-in-directory-p file (expand-file-name "test/" root))
                    (file-in-directory-p file (expand-file-name "scripts/" root)))
          (error "Unexpected compilation skip: %s" file))
        (cl-incf skipped))
       (result (cl-incf compiled))
       (t (error "Compilation failed: %s" file)))))
  (unless (and (= compiled 33) (= skipped (- (length files) 33)))
    (error "Unexpected compiled/skipped module counts"))
  (princ (format "%s: %d compiled, %d experimental/development files skipped\n"
                 (if native "Native" "Byte") compiled skipped)))
ELISP
for kind in byte native; do
  export SUPERTAG_COMPILE_KIND="$kind"
  echo "Checking $kind compilation; log: $root/$kind.log"
  if ! "${EMACS_BIN:-emacs}" -Q --batch "${args[@]}" -L "$root" -l "$root/check.el" > "$root/$kind.log" 2>&1; then
    cat "$root/$kind.log"
    exit 1
  fi
  if grep -E 'Warning[: ]|Error:|COMPILE ERROR' "$root/$kind.log"; then
    echo "Compilation diagnostics found; see $root/$kind.log" >&2
    exit 1
  fi
  tail -1 "$root/$kind.log"
  # Native checking starts fresh and must not hide warnings behind bytecode.
  find "$root" -maxdepth 1 -name '*.elc' -delete
done
