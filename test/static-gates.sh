#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if compgen -G '*.elc' >/dev/null; then echo 'root .elc files are forbidden' >&2; exit 1; fi
if grep -R -nE '^\s*\(def(alias|varalias)\b' --include='*.el' --exclude-dir=archive --exclude-dir=.claude --exclude-dir=.worktrees . >/tmp/supertag-static-aliases.$$ 2>/dev/null; then
  cat /tmp/supertag-static-aliases.$$ >&2; rm -f /tmp/supertag-static-aliases.$$; exit 1
fi
rm -f /tmp/supertag-static-aliases.$$
for f in ./*.el; do
  grep -q '^;; Commands:' "$f"
  grep -q '^;; Dependencies:' "$f"
done
# An indented `(require ...)' is allowed only as an explicitly justified lazy
# load, marked on the immediately preceding line:
#
#   ;; lazy-require: <why this load has to wait>
#
# Anything else is a careless require that hides a load-order or cycle problem.
unmarked_requires=$(awk '
  FNR == 1 { previous = "" }
  /^[[:space:]]+\(require / {
    if (previous !~ /^[[:space:]]*;;[[:space:]]*lazy-require:/)
      printf "%s:%d:%s\n", FILENAME, FNR, $0
  }
  { previous = $0 }
' ./*.el)
if [ -n "$unmarked_requires" ]; then
  printf '%s\n' "$unmarked_requires" >&2
  printf 'Unmarked indented (require ...): mark it with ";; lazy-require: <why>", or lift it to the top level.\n' >&2
  exit 1
fi
static_tmp=$(mktemp -d "${TMPDIR:-/tmp}/supertag-static-cold.XXXXXX")
# The dependency load path is shared with test/run-tests.sh so the two scripts
# can never disagree about where ht/dash live.
source test/deps-loadpath.sh
dep_args=()
for d in "${SUPERTAG_DEPS_DIRS[@]}"; do dep_args+=( -L "$d" ); done
if ! emacs --batch -Q "${dep_args[@]}" -L . -L test -L tests --eval "
(progn
(setq user-emacs-directory (file-name-as-directory \"$static_tmp\")
      supertag-data-directory (expand-file-name \"data/\" user-emacs-directory)
      repo-root (file-truename \"$(pwd)\")
      dep-roots '($(printf '"%s" ' "${SUPERTAG_DEPS_DIRS[@]}")))
(condition-case err
    (progn
      (require 'supertag)
      (dolist (loaded load-history)
        (when (stringp (car loaded))
          (let ((f (file-truename (car loaded))))
            (when (and (file-in-directory-p f repo-root)
                       (string-match-p \"/archive/\" f))
              (princ (format \"archive load: %s\\n\" f)) (kill-emacs 1))
            (unless (or (file-in-directory-p f repo-root)
                        (file-in-directory-p f (file-truename (expand-file-name \"..\" data-directory)))
                        (cl-some (lambda (d) (and (file-in-directory-p f (file-truename d))
                                                   (member (file-name-base f) '(\"ht\" \"dash\")))) dep-roots))
              (princ (format \"unexpected load: %s\\n\" f)) (kill-emacs 1))))))
  (error (princ err) (kill-emacs 1))))" >/tmp/supertag-static-cold-load.$$ 2>&1; then
  cat /tmp/supertag-static-cold-load.$$ >&2
  rm -f /tmp/supertag-static-cold-load.$$; exit 1
fi
rm -rf "$static_tmp"
rm -f /tmp/supertag-static-cold-load.$$
echo 'Static O gates: PASS'
