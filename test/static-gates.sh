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
if grep -nE '^\s+\(require ' ./*.el >/tmp/supertag-static-requires.$$ 2>/dev/null; then
  cat /tmp/supertag-static-requires.$$ >&2; rm -f /tmp/supertag-static-requires.$$; exit 1
fi
rm -f /tmp/supertag-static-requires.$$
static_tmp=$(mktemp -d "${TMPDIR:-/tmp}/supertag-static-cold.XXXXXX")
dep_args=()
if [ -n "${SUPERTAG_DEPS_LOADPATH:-}" ]; then
  IFS=: read -r -a dep_dirs <<< "$SUPERTAG_DEPS_LOADPATH"
else
  dep_dirs=()
  for name in ht dash; do
    pat=$(ls -d "$HOME"/.emacs.d/elpa/${name}-* 2>/dev/null | sort -V | tail -1 || true)
    [ -n "$pat" ] && dep_dirs+=("$pat")
  done
fi
if [ "${#dep_dirs[@]}" -eq 0 ]; then echo 'No ht/dash dependency directories found; set SUPERTAG_DEPS_LOADPATH' >&2; exit 1; fi
for d in "${dep_dirs[@]}"; do [ -d "$d" ] || { echo "Dependency directory not found: $d" >&2; exit 1; }; dep_args+=( -L "$d" ); done
if ! emacs --batch -Q "${dep_args[@]}" -L . -L test -L tests --eval "
(progn
(setq user-emacs-directory (file-name-as-directory \"$static_tmp\")
      supertag-data-directory (expand-file-name \"data/\" user-emacs-directory)
      repo-root (file-truename \"$(pwd)\")
      dep-roots '($(printf '"%s" ' "${dep_dirs[@]}")))
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
