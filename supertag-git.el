;;; supertag-git.el --- Org text Git synchronization -*- lexical-binding: t; -*-
;; Commands: supertag-git-setup, supertag-git-clone, supertag-git-sync-now,
;; supertag-git-sync-mode.
;; Dependencies: cl-lib, subr-x, smerge-mode, supertag-core-persistence,
;; supertag-services-sync.
;;; Commentary:
;; Git transports Org files.  Store is a local projection, never a merge input.
;; One configured root, scoped staging, serialized async transport, explicit
;; conflict resolution through smerge-mode and sync-now.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'smerge-mode)
(require 'supertag-core-persistence)
(require 'supertag-services-sync)
(defvar supertag--config-guard-allow)
(declare-function supertag-config-guard--capture "supertag-vault" ())
(defgroup supertag-git nil "Org text synchronization." :group 'supertag)
(defgroup supertag-git-sync nil "Automatic Org Git transport." :group 'supertag-git)
(defun supertag-git--executable ()
  "Return the git executable path, or nil if not found on `exec-path'."
  (executable-find "git"))

(defun supertag-git--run (dir &rest args)
  "Run Git ARGS in DIR; return (EXIT . OUTPUT)."
  (let ((git (supertag-git--executable)))
    (unless git
      (error "supertag-git: `git' executable not found on `exec-path' -- install git first"))
    (with-temp-buffer
      (let ((exit (apply #'call-process git nil t nil "-C" (expand-file-name dir) args)))
        (cons exit (if (member "-z" args) (buffer-string)
                     (string-trim (buffer-string))))))))

(defun supertag-git--ok-p (result)
  "Return non-nil if RESULT (an (EXIT . OUTPUT) cons from `supertag-git--run')
succeeded."
  (eq 0 (car result)))

(defun supertag-git--repo-toplevel (dir)
  "Return the git worktree toplevel containing DIR, or nil if DIR is not
inside any git worktree (or git is unavailable, or DIR does not exist)."
  (when (and (supertag-git--executable) (file-directory-p dir))
    (let ((result (supertag-git--run dir "rev-parse" "--show-toplevel")))
      (when (supertag-git--ok-p result)
        (file-name-as-directory (expand-file-name (cdr result)))))))

(defun supertag-git--truename-dir (dir)
  "Return DIR as an absolute, trailing-slash-terminated truename.
Using `file-truename' (not just `expand-file-name') matters on macOS in
particular, where temp directories often live under a `/var' that is
itself a symlink to `/private/var' -- a plain string-prefix ancestor check
without resolving that symlink would spuriously fail."
  (file-name-as-directory (file-truename (expand-file-name dir))))

(defun supertag-git--ancestor-p (root path)
  "Return non-nil if ROOT is PATH itself, or an ancestor directory of PATH."
  (let ((r (supertag-git--truename-dir root))
        (p (supertag-git--truename-dir path)))
    (string-prefix-p r p)))

(defun supertag-git--set-config (dir key value)
  "Set git config KEY to VALUE in DIR's repository (local, i.e. `.git/config' —
never `--global'). Signals an error on failure."
  (let ((result (supertag-git--run dir "config" key value)))
    (unless (supertag-git--ok-p result)
      (error "supertag-git: `git config %s' in %s failed: %s" key dir (cdr result)))))

(defun supertag-git--get-config (dir key)
  "Return git config KEY's value in DIR's repository, or nil if unset/on error."
  (let ((result (supertag-git--run dir "config" "--get" key)))
    (when (supertag-git--ok-p result) (cdr result))))

(defun supertag-git--init-repo (root)
  "Run `git init' at ROOT (creating ROOT first if needed). Signals on failure."
  (unless (file-directory-p root)
    (make-directory root t))
  (let ((result (supertag-git--run root "init")))
    (unless (supertag-git--ok-p result)
      (error "supertag-git: `git init' at %s failed: %s" root (cdr result)))))

(defun supertag-git--sync-roots ()
  "Return the configured, non-empty `supertag-sync-directories' entries.
Returns nil when the variable is unbound, nil, or contains no usable
strings -- all treated the same as \"no configured root\"."
  (when (and (boundp 'supertag-sync-directories)
             (listp supertag-sync-directories))
    (delq nil (mapcar (lambda (d) (and (stringp d) (> (length d) 0) d))
                       supertag-sync-directories))))

(defun supertag-git--multiple-sync-roots-p ()
  "Return non-nil if more than one sync root is configured.
This is the V1-unsupported case."
  (> (length (supertag-git--sync-roots)) 1))

(defun supertag-git--file-lines (file)
  "Return FILE's contents as a list of lines, or nil if FILE does not exist."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (split-string (buffer-string) "\n" t))))

(defun supertag-git--ensure-lines (file lines)
  "Ensure each of LINES appears verbatim somewhere in FILE, appending any
that are missing (creating FILE, and its parent directory, if absent).
Returns the sublist of LINES that were newly appended -- empty when FILE
already contained all of them, so repeated setup never duplicates a line."
  (let* ((existing (supertag-git--file-lines file))
         (missing (cl-remove-if (lambda (l) (member l existing)) lines)))
    (when missing
      (let ((dir (file-name-directory file)))
        (unless (file-directory-p dir) (make-directory dir t)))
      (with-temp-buffer
        (when (file-exists-p file)
          (insert-file-contents file))
        (goto-char (point-max))
        (unless (or (= (point-min) (point-max)) (bolp))
          (insert "\n"))
        (dolist (l missing) (insert l "\n"))
        (write-region (point-min) (point-max) file nil 'silent)))
    missing))

(defun supertag-git-setup--existing-origin-url (root)
  "Return ROOT's configured `remote.origin.url', or nil if `origin' is not
configured at all."
  (supertag-git--get-config root "remote.origin.url"))

(defun supertag-git-setup--remote-add (root url)
  "Run `git remote add origin URL' in ROOT. Signals a clear error on failure."
  (let ((result (supertag-git--run root "remote" "add" "origin" url)))
    (unless (supertag-git--ok-p result)
      (error "supertag-git-setup: `git remote add origin %s' failed: %s" url (cdr result)))))

(defun supertag-git-setup--remote-set-url (root url)
  "Run `git remote set-url origin URL' in ROOT. Signals a clear error on
failure."
  (let ((result (supertag-git--run root "remote" "set-url" "origin" url)))
    (unless (supertag-git--ok-p result)
      (error "supertag-git-setup: `git remote set-url origin %s' failed: %s" url (cdr result)))))

(defun supertag-git-setup--configure-remote (root)
  "Prompt for an optional origin URL; an empty answer keeps the vault local."
  (let* ((existing (supertag-git-setup--existing-origin-url root))
         (input (string-trim
                 (read-string "Git remote URL for `origin' (empty = local-only, skip for now): "
                              existing))))
    (cond
     ((zerop (length input)) nil)
     ((not existing)
      (supertag-git-setup--remote-add root input)
      input)
     ((equal input existing) existing)
     (t
      (if (y-or-n-p (format "supertag-git-setup: `origin' is already set to %s -- change it to %s? "
                            existing input))
          (progn (supertag-git-setup--remote-set-url root input) input)
        existing)))))

(defun supertag-git-setup--current-branch (root)
  "Return ROOT's current branch name (`git rev-parse --abbrev-ref HEAD'),
or nil on failure. Works even before ROOT's first commit -- HEAD is a
symbolic ref to the branch name from `git init'/`symbolic-ref' onward,
resolvable without any commit existing yet."
  (let ((result (supertag-git--run root "rev-parse" "--abbrev-ref" "HEAD")))
    (when (supertag-git--ok-p result) (cdr result))))

(defun supertag-git-setup--push (root)
  "Push ROOT's current branch to `origin' with `-u' (so it starts tracking
it), per the plan's machine-1 journey. On success, returns
`(:status :ok :branch BRANCH)'. On failure (most commonly auth/network:
no ssh-agent, no credential helper configured, remote unreachable, ...),
returns `(:status :failed :branch BRANCH :error STRING)' -- this function
deliberately does NOT retry; a one-shot setup command retrying a push
that failed for a persistent reason (bad credentials, unreachable host)
would just hang or spam identically-failing attempts. `supertag-git-setup'
turns the `:failed' case into a diagnostic message pointing at manual
`git push' / ssh-agent / credential-helper troubleshooting; automatic
retry-on-reconnect is `supertag-git-sync-mode''s job, not this command's."
  (let ((branch (supertag-git-setup--current-branch root)))
    (unless branch
      (error "supertag-git-setup: could not determine the current branch to push"))
    (let ((result (supertag-git--run root "push" "-u" "origin" branch)))
      (if (supertag-git--ok-p result)
          (list :status :ok :branch branch)
        (list :status :failed :branch branch :error (cdr result))))))

(defun supertag-git--run-clone (remote-url local-dir)
  "Run `git clone REMOTE-URL LOCAL-DIR'. Signals an error including git's
own stderr/stdout on failure -- never silently continues past a failed
clone into configuring a nonexistent repository."
  (unless (supertag-git--executable)
    (error "supertag-git-clone: `git' executable not found; install git first"))
  (let ((parent (file-name-directory (directory-file-name (expand-file-name local-dir)))))
    (when (and parent (not (file-directory-p parent)))
      (make-directory parent t)))
  (with-temp-buffer
    (let ((exit (call-process (supertag-git--executable) nil t nil
                               "clone" remote-url (directory-file-name (expand-file-name local-dir)))))
      (unless (= exit 0)
        (error "supertag-git-clone: `git clone %s %s' failed: %s"
               remote-url local-dir (string-trim (buffer-string)))))))

(defun supertag-git--reindex-org-files ()
  "Rebuild Org projections from the configured root.
Return a complete report, or nil when rebuilding cannot finish."
  (when (fboundp 'supertag-reindex-org)
    (let ((report (funcall #'supertag-reindex-org)))
      (and (eq (plist-get report :status) 'complete) report))))

(defun supertag-git--current-node-tag-counts ()
  "Return (NODE-COUNT . TAG-COUNT) from the live in-memory store, or (0 . 0)
if the relevant collections are not (yet) hash tables."
  (let* ((nodes (ignore-errors (supertag-store-get-collection :nodes)))
         (tags (ignore-errors (supertag-store-get-collection :tags))))
    (cons (if (hash-table-p nodes) (hash-table-count nodes) 0)
          (if (hash-table-p tags) (hash-table-count tags) 0))))

(defcustom supertag-git-sync-pull-interval 300
  "Seconds between automatic background `git fetch' (+ merge if behind)
attempts while `supertag-git-sync-mode' is enabled. Also triggered (at
most once every `supertag-git-sync-focus-pull-min-interval' seconds) when
Emacs regains focus."
  :type 'integer
  :group 'supertag-git-sync)

(defcustom supertag-git-sync-commit-debounce 30
  "Seconds of quiet after the LAST detected change before
`supertag-git-sync-mode' auto-commits. A single timer that restarts on
every new change (never accumulates multiple pending timers) -- see
`supertag-git-sync--schedule-commit'."
  :type 'integer
  :group 'supertag-git-sync)

(defcustom supertag-git-sync-focus-pull-min-interval 60
  "Minimum seconds between two focus-triggered pulls (rate limit)."
  :type 'integer
  :group 'supertag-git-sync)

(defvar supertag-git-sync--synchronous nil
  "When non-nil, `supertag-git-sync--run-git' runs git synchronously
\(`call-process') instead of asynchronously (`make-process'). See this
section's Commentary for why batch ERT tests need this; production code
must never set it globally (tests `let'-bind it for the duration of one
test only).")

(defvar supertag-git-sync--vault-root nil
  "Repo root this session's `supertag-git-sync-mode' operates on, captured
via `supertag-git-check' when the mode is enabled. Nil when the mode is
off.")

(defvar supertag-git-sync--commit-timer nil
  "The single pending debounce timer for the next auto-commit, or nil.")

(defvar supertag-git-sync--pull-timer nil
  "The repeating timer for periodic fetch(+merge), or nil.")

(defvar supertag-git-sync--exit-wait-timer nil
  "One-shot timer waiting to exit after an asynchronous sync, or nil.")

(defvar supertag-git-sync--last-focus-pull-time nil
  "`float-time' of the last focus-triggered pull attempt, or nil.")

(defvar supertag-git-sync--in-flight nil
  "Non-nil while a git operation chain is already running for this vault.
Guards ENTRY only -- see this section's Commentary on serialization.")

(defvar supertag-git-sync--pending-push-count 0
  "DISPLAY CACHE ONLY, shown in the modeline lighter (e.g. \" STG\\u21913\").
Not a source of truth: it is refreshed from git's own ahead-of-upstream
commit count (`git rev-list --count @{upstream}..HEAD') every pull cycle
\(`supertag-git-sync--refresh-pending-count', called from
`supertag-git-sync--pull' and once immediately when the mode is enabled)
-- 0 when there is no upstream configured at all (a local-only vault,
which also means no push is ever attempted). An earlier version of this
variable was instead incremented by hand on every local commit and reset
on every successful push, which meant it always LIED as 0 immediately
after any Emacs restart regardless of how many real unpushed commits
existed -- see this section's Commentary and P1-7 in the review.")

(defvar supertag-git--conflicted-files nil
  "Absolute Org paths paused for explicit conflict resolution.")

(defvar supertag-git-sync--offline-warned nil
  "Non-nil once a fetch/push failure has been reported for the CURRENT
offline episode. Reset to nil the next time an operation succeeds, so
degrading offline and recovering are each reported exactly once (never
once per retry) -- see `supertag-git-sync--note-offline'.")

(defvar supertag-git-sync-mode nil)

(defun supertag-git-sync--run-git (dir args callback)
  "Run `git -C DIR ARGS' and call CALLBACK with (EXIT-CODE . OUTPUT).
Asynchronous (`make-process', never blocking) unless
`supertag-git-sync--synchronous' is non-nil, in which case it blocks via
`call-process' and calls CALLBACK before returning -- see this section's
Commentary. For the async path CALLBACK runs once, from the process
sentinel, after the process has fully exited."
  (let ((git (supertag-git--executable)))
    (unless git
      (funcall callback (cons 1 "git executable not found")))
    (if supertag-git-sync--synchronous
        (let ((result (with-temp-buffer
                        (let ((exit (apply #'call-process git nil t nil "-C" dir args)))
                          (cons exit (buffer-string))))))
          (funcall callback result))
      (let ((buf (generate-new-buffer " *supertag-git-sync*")))
        (make-process
         :name "supertag-git-sync"
         :buffer buf
         :command (append (list git "-C" dir) args)
         :noquery t
         :sentinel
         (lambda (proc _event)
           (unless (process-live-p proc)
             (let* ((exit (process-exit-status proc))
                    (output (with-current-buffer (process-buffer proc) (buffer-string))))
               (when (buffer-live-p (process-buffer proc))
                 (kill-buffer (process-buffer proc)))
               (funcall callback (cons exit output))))))))))

(defun supertag-git-sync--note-offline (op &optional root)
  "Report an OP (\"fetch\" or \"push\") failure exactly once per offline
episode, not once per retry.  ROOT is used only for local safety status."
  (unless supertag-git-sync--offline-warned
    (setq supertag-git-sync--offline-warned t)
    (message
     (concat "supertag-git-sync: %s failed. %s. No local data was discarded. "
             "Automatic retry remains enabled; run M-x supertag-git-sync-now to retry now.")
     op (supertag-git-sync--local-safety-summary root))))

(defun supertag-git-sync--clear-offline-warning ()
  "Report recovery exactly once, the first time an operation succeeds
again after `supertag-git-sync--note-offline' fired."
  (when supertag-git-sync--offline-warned
    (setq supertag-git-sync--offline-warned nil)
    (message "supertag-git-sync: back online.")))

(defun supertag-git-sync--report-failure (op result)
  "Report a non-offline-looking git failure (e.g. `git add'/`git commit'
themselves failing, which is unusual and worth a message every time,
unlike the expected/common fetch-push offline case)."
  (message
   (concat "supertag-git-sync: %s failed: %s. %s. No local data was discarded. "
           "Fix the reported Git error, then run M-x supertag-git-sync-now.")
   op (string-trim (cdr result))
   (supertag-git-sync--local-safety-summary)))

(defun supertag-git-sync--unmerged-paths (root)
  "Read unresolved paths from the current Git index in ROOT."
  (let ((result (supertag-git--run root "diff" "--name-only" "-z" "--diff-filter=U")))
    (when (supertag-git--ok-p result)
      (split-string (cdr result) "\0" t))))

(defun supertag-git-sync--file-has-conflict-markers-p (file)
  "Return non-nil if FILE contains literal, unresolved git conflict
markers. Reuses `supertag--persistence--buffer-has-conflict-markers-p'
\(already proven correct for the DB loader's own guard -- see
supertag-core-persistence.el) rather than re-implementing the same
three-line-prefix scan; that function only looks at buffer text, so it
works identically for an org file as for the database file."
  (with-temp-buffer
    (insert-file-contents file)
    (supertag--persistence--buffer-has-conflict-markers-p)))

(defun supertag-git-sync--live-conflicted-org-files (root)
  "Return `.org' files under ROOT that are still unmerged (per
`supertag-git-sync--unmerged-paths'), computed FRESH from git's current
index state every time this is called.  Text markers are not required:
modify/delete and rename/delete conflicts have unmerged index entries but
may contain no marker text at all.  Callable at any time (right after a
merge, from `supertag-git-sync--fire-commit', or from `supertag-doctor'
in a session that never even turned `supertag-git-sync-mode' on), unlike
the session-local `supertag-git--conflicted-files' cache, which only
is populated by mode enable and `supertag-git-sync--after-merge'.
The cache alone cannot describe conflicts before mode enable after a restart."
  (let ((true-root (supertag-git--truename-dir root))
        conflicted)
    (dolist (rel (supertag-git-sync--unmerged-paths root))
      (when (string-match-p "\\.org\\'" rel)
        (push (file-truename (expand-file-name rel true-root)) conflicted)))
    (nreverse conflicted)))

(defvar supertag-git-sync--conflict-commit-warned nil
  "Non-nil once `supertag-git-sync--fire-commit' has already reported a
refusal to auto-commit for the CURRENT unresolved-conflict episode (either
an unmerged path found before staging, or a literal conflict marker found
in staged content after it). Reset to nil once no unmerged paths remain,
so the refusal is reported once per episode, not once per debounce retry
-- the same one-message-per-state-change pattern as
`supertag-git-sync--offline-warned'.")

(defun supertag-git-sync--note-commit-refused (reason)
  "Report REASON (a human-readable string) for refusing to auto-commit,
exactly once per unresolved-conflict episode."
  (unless supertag-git-sync--conflict-commit-warned
    (setq supertag-git-sync--conflict-commit-warned t)
    (message "supertag-git-sync: refusing to auto-commit -- %s" reason)))

(defun supertag-git-sync--clear-commit-conflict-warning ()
  "Clear the one-shot refusal warning once the conflict episode is over."
  (when supertag-git-sync--conflict-commit-warned
    (setq supertag-git-sync--conflict-commit-warned nil)))

(defun supertag-git-sync--schedule-commit ()
  "(Re)start the single debounce timer for the next auto-commit. Any
already-pending timer is cancelled first, so the commit fires
`supertag-git-sync-commit-debounce' seconds after the LAST change, never
the first -- per the plan's \"debounce 30s\"."
  (when (and supertag-git-sync--vault-root (not supertag-git--conflicted-files))
    (when supertag-git-sync--commit-timer
      (cancel-timer supertag-git-sync--commit-timer))
    (setq supertag-git-sync--commit-timer
          (run-with-timer supertag-git-sync-commit-debounce nil
                           #'supertag-git-sync--fire-commit))))

(defun supertag-git-sync--staged-conflict-markers-p (root)
  "Return non-nil if the content just staged in ROOT's index
\(`git diff --cached') introduces literal git conflict markers. A
belt-and-suspenders check run AFTER staging, in case something slipped
past the pre-stage `supertag-git-sync--unmerged-paths' guard in
`supertag-git-sync--fire-commit' (e.g. conflict-marker-shaped text
introduced some other way, not by an actual in-progress git merge). Only
lines the diff ADDS (a leading `+') count, so a marker that already existed
in a previous commit's context lines is not a false positive."
  (let ((result (supertag-git--run root "diff" "--cached")))
    (unless (supertag-git--ok-p result)
      (error "could not inspect staged content: %s" (string-trim (cdr result))))
    (string-match-p "^\\+<<<<<<< \\|^\\+=======$\\|^\\+>>>>>>> "
                    (cdr result))))

(defun supertag-git-sync--commit-pathspecs (root)
  "Return literal pathspecs for existing owned files in ROOT."
  (let ((result (apply #'supertag-git--run root
                       "ls-files" "-z" "--cached" "--others" "--deleted"
                       "--exclude-standard" "--"
                       (supertag-git-sync--commit-candidate-pathspecs root))))
    (unless (supertag-git--ok-p result) (user-error "%s" (cdr result)))
    (mapcar (lambda (path) (concat ":(literal)" path))
            (cl-remove-if-not
             (lambda (path) (supertag-git-sync--auto-commit-path-p root path))
             (delete-dups (split-string (cdr result) "\0" t))))))

(defun supertag-git-sync--owned-changes-p (root)
  "Return non-nil when auto-commit-owned paths have changes in ROOT."
  (when-let* ((paths (supertag-git-sync--commit-pathspecs root)))
    (let ((result (apply #'supertag-git--run root
                         "status" "--porcelain=v1" "-z" "--untracked-files=all" "--" paths)))
      (unless (supertag-git--ok-p result) (user-error "%s" (cdr result)))
      (> (length (cdr result)) 0))))

(defun supertag-git-sync--auto-commit-path-p (root path)
  "Return non-nil when PATH is owned Org text, excluding local data."
  (and (not (supertag-git--local-data-path-p root path))
       (or (string-suffix-p ".org" path) (equal path ".gitignore"))))

(defun supertag-git--assert-no-staged-markers (root)
  "Refuse ROOT's staged conflict markers without changing the index."
  (when (supertag-git-sync--staged-conflict-markers-p root)
    (user-error "Staged conflict markers; resolve before sync: %s"
                (string-join
                 (split-string (cdr (supertag-git--run root "diff" "--cached" "--name-only" "-z"))
                               "\0" t) ", "))))

(defun supertag-git--stage-checked (root paths callback &optional extra)
  "Stage literal PATHS in ROOT, then call CALLBACK with the Git result.
Verify the index again after add, restoring its exact pre-add state on
refusal.  EXTRA names explicitly confirmed local-data removals in setup."
  (supertag-git--assert-index-scope root extra)
  (supertag-git--assert-no-staged-markers root)
  (let* ((location (supertag-git--run root "rev-parse" "--git-path" "index"))
         (index (expand-file-name (cdr location) root))
         (existed (file-exists-p index))
         (backup (make-temp-file "supertag-git-index-")))
    (unless (supertag-git--ok-p location)
      (delete-file backup) (user-error "%s" (cdr location)))
    (when existed (copy-file index backup t))
    (supertag-git-sync--run-git
     root (append '("add" "-A" "--") paths)
     (lambda (result)
       (unwind-protect
           (progn
             (setq result
                   (condition-case err
                       (progn
                         (unless (supertag-git--ok-p result) (error "%s" (cdr result)))
                         (supertag-git--assert-index-scope root extra)
                         (supertag-git--assert-no-staged-markers root)
                         result)
                     (error
                      (if existed (copy-file backup index t)
                        (when (file-exists-p index) (delete-file index)))
                      (cons 1 (error-message-string err)))))
             (funcall callback result))
         (delete-file backup))))))

(defun supertag-git-sync--fire-commit ()
  "Stage owned Org text with index guards, then commit and push asynchronously."
  (setq supertag-git-sync--commit-timer nil)
  (when (and supertag-git-sync--vault-root (not supertag-git--conflicted-files)
             (not supertag-git-sync--in-flight))
    (let ((root supertag-git-sync--vault-root))
      (condition-case err
          (progn
            (when-let* ((unmerged (supertag-git-sync--unmerged-paths root)))
              (user-error "Unresolved merge paths: %s" (string-join unmerged ", ")))
            (supertag-git--assert-index-scope root)
            (when-let* ((paths (supertag-git-sync--commit-pathspecs root)))
              (setq supertag-git-sync--in-flight t)
              (supertag-git--stage-checked
               root paths
               (lambda (result)
                 (if (not (supertag-git--ok-p result))
                     (progn
                       (setq supertag-git-sync--in-flight nil)
                       (supertag-git-sync--note-commit-refused (cdr result)))
                   (let ((diff (supertag-git--run root "diff" "--cached" "--quiet")))
                     (cond
                      ((supertag-git--ok-p diff)
                       (setq supertag-git-sync--in-flight nil)
                       (supertag-git-sync--clear-commit-conflict-warning))
                      ((/= 1 (car diff))
                       (setq supertag-git-sync--in-flight nil)
                       (supertag-git-sync--report-failure "inspect staged diff" diff))
                      (t
                       (supertag-git-sync--clear-commit-conflict-warning)
                       (supertag-git-sync--run-git
                        root (list "commit" "-q" "-m"
                                   (format "supertag-sync: %s %s" (system-name)
                                           (format-time-string "%Y-%m-%dT%H:%M:%S%z")))
                        (lambda (commit)
                          (if (not (supertag-git--ok-p commit))
                              (progn (setq supertag-git-sync--in-flight nil)
                                     (supertag-git-sync--report-failure "git commit" commit))
                            (supertag-git-sync--refresh-pending-count root)
                            (supertag-git-sync--push root))))))))))))
        (error
         (setq supertag-git-sync--in-flight nil)
         (supertag-git-sync--note-commit-refused (error-message-string err)))))))

(defun supertag-git-sync--rejected-p (result)
  "Return non-nil if RESULT (from a `git push') looks like an ordinary
non-fast-forward rejection (remote advanced -- retry via fetch+merge+push
makes sense), as opposed to a network/auth failure (retrying the exact
same push would just fail again the same way)."
  (and (not (supertag-git--ok-p result))
       (string-match-p "rejected\\|non-fast-forward\\|fetch first\\|fetch-first"
                       (cdr result))))

(defun supertag-git-sync--push (root)
  "Push ROOT's current branch. Called with `supertag-git-sync--in-flight'
already t. On success: reset the pending-push counter and clear any
offline warning. On an ordinary rejection (remote advanced): fetch, merge
\(never rebase, per the plan), and retry the push exactly ONCE; if that
retry still fails, give up silently for this cycle -- the pending count
display cache is left as whatever it was most recently refreshed to
\(still accurate: nothing here changed how many commits are actually
ahead), shown in the modeline, and the next pull cycle's own
ahead/behind refresh (`supertag-git-sync--refresh-pending-count', see
`supertag-git-sync--maybe-push-after-cycle') will both correct the
display and retry the push. On anything else (network/auth failure):
treat as offline degradation. Always clears
`supertag-git-sync--in-flight' exactly once, on every branch."
  (supertag-git-sync--run-git
   root (list "push")
   (lambda (push-result)
     (cond
      ((supertag-git--ok-p push-result)
       (setq supertag-git-sync--pending-push-count 0)
       (supertag-git-sync--clear-offline-warning)
       (setq supertag-git-sync--in-flight nil))
      ((supertag-git-sync--rejected-p push-result)
       (supertag-git-sync--run-git
        root (list "fetch")
        (lambda (fetch-result)
          (if (not (supertag-git--ok-p fetch-result))
              (progn (supertag-git-sync--note-offline
                      "push (fetch during retry)" root)
                     (setq supertag-git-sync--in-flight nil))
            (supertag-git-sync--run-git
             root (list "merge" "--no-edit" "@{upstream}")
             (lambda (merge-result)
               (supertag-git-sync--after-merge merge-result root)
               (if (not (supertag-git--ok-p merge-result))
                   (setq supertag-git-sync--in-flight nil)
                 (supertag-git-sync--run-git
                  root (list "push")
                  (lambda (retry-result)
                    (if (supertag-git--ok-p retry-result)
                        (progn (setq supertag-git-sync--pending-push-count 0)
                               (supertag-git-sync--clear-offline-warning))
                      (supertag-git-sync--note-offline "push retry" root))
                    (setq supertag-git-sync--in-flight nil))))))))))
      (t
       (supertag-git-sync--note-offline "push" root)
       (setq supertag-git-sync--in-flight nil))))))

(defun supertag-git-sync--rev-count (root range)
  "Return the integer count from `git rev-list --count RANGE' in ROOT, or
nil if the command fails -- in particular when RANGE references
`@{upstream}' and the current branch has no upstream configured at all
\(a local-only vault: this is the signal every caller below uses to mean
\"no push is ever attempted, and the lighter shows nothing pending\")."
  (let ((result (supertag-git--run root "rev-list" "--count" range)))
    (and (supertag-git--ok-p result) (string-to-number (string-trim (cdr result))))))

(defun supertag-git-sync--behind-p (root)
  "Return non-nil if ROOT's HEAD is behind its upstream, immediately after
a fetch."
  (let ((n (supertag-git-sync--rev-count root "HEAD..@{upstream}")))
    (and n (> n 0))))

(defun supertag-git-sync--refresh-pending-count (root)
  "Recompute ROOT's ahead-of-upstream commit count via git and refresh the
DISPLAY CACHE `supertag-git-sync--pending-push-count' from it (0 when
there is no upstream configured at all). Returns the ahead count (an
integer), or nil when there is no upstream."
  (let ((ahead (supertag-git-sync--rev-count root "@{upstream}..HEAD")))
    (setq supertag-git-sync--pending-push-count (or ahead 0))
    ahead))

(defun supertag-git-sync--maybe-push-after-cycle (root)
  "End-of-cycle step: refresh the ahead-count display cache and push when
ahead > 0. Shared by `supertag-git-sync--pull' (both its \"nothing to
merge\" and \"just merged\" paths) and `supertag-git-sync--enable' (an
immediate catch-up check right when the mode turns on) -- this is what
lets commits accumulated while offline, or a commit whose OWN push never
finished before a previous Emacs session ended, get pushed on the very
next cycle once connectivity/an upstream returns, rather than silently
sitting local until some unrelated new edit happens to trigger
`supertag-git-sync--fire-commit''s own push. Always clears
`supertag-git-sync--in-flight' exactly once (`supertag-git-sync--push'
does so itself on every branch when it runs; this function does so
directly on the no-push branch)."
  (let ((ahead (supertag-git-sync--refresh-pending-count root)))
    (if (and (not supertag-git--conflicted-files) ahead (> ahead 0))
        (supertag-git-sync--push root)
      (setq supertag-git-sync--in-flight nil))))

(defun supertag-git-sync--pull ()
  "One fetch (+ merge if behind, + push if ahead) cycle. A no-op when no
vault is active or another git op is already in flight.

The trailing \"+ push if ahead\" step (P1-7) is what covers OFFLINE
RECOVERY: a run of local commits made while the remote was unreachable
(each individual push attempt having failed and degraded silently, per
this mode's offline handling) are not orphaned forever waiting for a new
edit -- reconnecting means the very next timer tick's fetch succeeds,
and `supertag-git-sync--maybe-push-after-cycle' then pushes everything
that piled up, whether or not anything was behind to merge first."
  (when (and supertag-git-sync--vault-root (not supertag-git--conflicted-files)
             (not supertag-git-sync--in-flight))
    (setq supertag-git-sync--in-flight t)
    (let ((root supertag-git-sync--vault-root))
      (supertag-git-sync--run-git
       root (list "fetch")
       (lambda (fetch-result)
         (if (not (supertag-git--ok-p fetch-result))
             (progn (supertag-git-sync--note-offline "fetch" root)
                    (setq supertag-git-sync--in-flight nil))
           (supertag-git-sync--clear-offline-warning)
           (if (supertag-git-sync--behind-p root)
               (supertag-git-sync--run-git
                root (list "merge" "--no-edit" "@{upstream}")
                (lambda (merge-result)
                  (supertag-git-sync--after-merge merge-result root)
                  (supertag-git-sync--maybe-push-after-cycle root)))
             (supertag-git-sync--maybe-push-after-cycle root))))))))

(defun supertag-git-sync--maybe-focus-pull ()
  "Run one pull cycle on regaining focus, rate-limited to at most once per
`supertag-git-sync-focus-pull-min-interval' seconds."
  (when (and (bound-and-true-p supertag-git-sync-mode) supertag-git-sync--vault-root)
    (let ((now (float-time)))
      (when (or (null supertag-git-sync--last-focus-pull-time)
                (>= (- now supertag-git-sync--last-focus-pull-time)
                    supertag-git-sync-focus-pull-min-interval))
        (setq supertag-git-sync--last-focus-pull-time now)
        (supertag-git-sync--pull)))))

(defun supertag-git-sync--schedule-exit-after-sync ()
  "Wait for the active Git chain, then exit only if no local work remains."
  (when supertag-git-sync--exit-wait-timer
    (cancel-timer supertag-git-sync--exit-wait-timer))
  (setq supertag-git-sync--exit-wait-timer
        (run-with-timer 0.25 nil #'supertag-git-sync--exit-after-sync)))

(defun supertag-git-sync--exit-after-sync ()
  "Continue or finish an exit requested during asynchronous Git sync."
  (setq supertag-git-sync--exit-wait-timer nil)
  (cond
   ((not (and (bound-and-true-p supertag-git-sync-mode)
              supertag-git-sync--vault-root))
    (message "supertag-git-sync: automatic exit cancelled because sync mode was disabled"))
   (supertag-git-sync--in-flight
    (supertag-git-sync--schedule-exit-after-sync))
   ((supertag-git-sync--pending-p)
    (message "supertag-git-sync: automatic exit cancelled; synchronization failed or new local changes remain"))
   (t
    (message "supertag-git-sync: synchronization complete; exiting Emacs")
    (save-buffers-kill-emacs))))

(defun supertag-git-sync--skip-conflicted-file-advice (orig-fn file &rest args)
  "Keep unresolved Org text out of the existing sync processor."
  (if (member (file-truename (expand-file-name file))
              supertag-git--conflicted-files)
      (progn
        (message "supertag-git-sync: skipping import of %s -- unresolved merge conflict; resolve with smerge-mode, save, then run supertag-git-sync-now."
                 file)
        nil)
    (apply orig-fn file args)))

(defun supertag-git-sync--on-file-saved ()
  "`after-save-hook' function, vault-scoped: only schedules a commit when
the just-saved buffer's file is inside this session's git-sync vault
root -- saves anywhere else in Emacs must never trigger a vault commit."
  (when (and (bound-and-true-p supertag-git-sync-mode)
             supertag-git-sync--vault-root
             buffer-file-name
             (string-suffix-p ".org" buffer-file-name)
             (supertag-git--ancestor-p supertag-git-sync--vault-root buffer-file-name))
    (supertag-git-sync--schedule-commit)))

(defun supertag-git-setup--pick-root (&optional _ignored)
  "Return the sole configured Org root, independent of Store location."
  (let ((roots (supertag-git--sync-roots)))
    (unless (= (length roots) 1)
      (user-error "Configure exactly one supertag-sync-directories root"))
    (supertag-git--truename-dir (car roots))))

(defun supertag-git--tracked-files (root)
  "Return ROOT's tracked paths without Git filename quoting."
  (let ((result (supertag-git--run root "ls-files" "-z")))
    (unless (supertag-git--ok-p result) (error "%s" (cdr result)))
    (split-string (cdr result) "\0" t)))

(defun supertag-git--local-data-path-p (root path)
  "Return non-nil for local data PATH, resolving directory and file aliases.
Configured data/backup directories and state/presence files remain
local, as do conventional .supertag and backups directories."
  (let* ((file (file-truename (expand-file-name path root)))
         (relative (file-relative-name file (supertag-git--truename-dir root)))
         (directories (delq nil (list supertag-data-directory
                                      supertag-db-backup-directory
                                      (expand-file-name ".supertag/" root))))
         (files (delq nil (list supertag-db-file supertag-sync-state-file
                                (supertag--presence-file)))))
    (or (cl-some (lambda (dir) (supertag-git--ancestor-p dir file)) directories)
        (cl-some (lambda (entry) (equal file (file-truename entry))) files)
        (member "backups" (split-string relative "/" t))
        (member ".supertag" (split-string relative "/" t))
        (member (file-name-nondirectory file)
                '("supertag-db.el" "sync-state.el" "presence.json"
                  "supertag-presence.json" ".gitattributes")))))

(defun supertag-git--retired-tracked (root)
  "Return tracked local data requiring explicit setup confirmation."
  (cl-remove-if-not (lambda (path) (supertag-git--local-data-path-p root path))
                    (supertag-git--tracked-files root)))

(defun supertag-git-check (&optional _file)
  "Describe the configured Org repository and retired tracked cache paths."
  (let* ((roots (supertag-git--sync-roots))
         (root (and (= (length roots) 1) (supertag-git--truename-dir (car roots))))
         (repo (and root (supertag-git--repo-toplevel root)))
         (valid (and repo (equal root (supertag-git--truename-dir repo)))))
    (list :in-repo-p valid :repo-root (and valid root)
          :multiple-sync-roots-p (> (length roots) 1)
          :retired-tracked (and valid (supertag-git--retired-tracked root))
          :org-only-p (and valid (cl-every (lambda (f) (supertag-git-sync--auto-commit-path-p root f))
                                          (supertag-git--tracked-files root)))
          :remote-configured-p (and valid (supertag-git-setup--existing-origin-url root)))))

(defun supertag-git-sync--commit-candidate-pathspecs (_root)
  "Allow only Org text recursively and the root ignore file."
  '("*.org" ":(top,literal).gitignore"))

(defun supertag-git--ignore-literal (path)
  "Quote dynamic PATH as one literal Git ignore pattern, or return nil.
Line separators and NUL cannot safely be written as a single rule."
  (if (string-match-p "[\n\r\0]" path)
      (progn (message "Supertag Git: skipped unrepresentable ignore path %S" path) nil)
    (mapconcat (lambda (char)
                 (let ((text (char-to-string char)))
                   (if (memq char '(?\\ ?* ?? ?\[ ?\] ?\s ?# ?!))
                       (concat "\\" text)
                     text)))
               path "")))

(defun supertag-git--prepare-ignore (root &optional retired)
  "Write the same local-cache ignore policy for setup and clone in ROOT.
RETIRED paths have separately been confirmed for removal from tracking."
  (let ((lines '("**/.supertag/" "/.gitattributes" "**/supertag-db.el"
                 "**/sync-state.el" "**/backups/" "**/presence.json"
                 "**/supertag-presence.json")))
    (dolist (path (append (list supertag-data-directory supertag-db-backup-directory
                                supertag-db-file supertag-sync-state-file
                                (supertag--presence-file))
                         (mapcar (lambda (p) (expand-file-name p root)) retired)))
      (when (and path (supertag-git--ancestor-p root path))
        (let ((relative (file-relative-name (file-truename path) root)))
          (unless (equal relative "./")
            (when-let* ((literal (supertag-git--ignore-literal relative)))
              (push (concat "/" literal) lines))))))
    (supertag-git--ensure-lines (expand-file-name ".gitignore" root) lines)))

(defun supertag-git--assert-index-scope (root &optional extra)
  "Reject pre-staged changes outside Org/ignore and authorized EXTRA paths."
  (let ((result (supertag-git--run root "diff" "--cached" "--name-only" "-z")))
    (unless (supertag-git--ok-p result) (user-error "%s" (cdr result)))
    (dolist (path (split-string (cdr result) "\0" t))
      (unless (or (supertag-git-sync--auto-commit-path-p root path) (member path extra))
        (user-error "Git index contains out-of-scope path %s; leave it untouched" path)))))

;;;###autoload
(defun supertag-git-setup ()
  "Configure the sole Org root for text-only Git synchronization."
  (interactive)
  (let* ((root (supertag-git-setup--pick-root))
         (repo (supertag-git--repo-toplevel root)))
    (when (and repo (not (equal root (supertag-git--truename-dir repo))))
      (user-error "Org root must be the Git toplevel, not inside another repository"))
    (unless repo (supertag-git--init-repo root))
    (when (supertag-git-sync--unmerged-paths root) (user-error "Resolve the current merge first"))
    (supertag-git--assert-index-scope root)
    (let ((retired (supertag-git--retired-tracked root)))
      (when retired
        (unless (yes-or-no-p (format "Stop tracking local data/attributes (keep files): %s? "
                                    (string-join retired ", ")))
          (user-error "Setup cancelled; tracked paths unchanged"))
        (let ((result (apply #'supertag-git--run root "rm" "--cached" "--"
                              (mapcar (lambda (p) (concat ":(literal)" p)) retired))))
          (unless (supertag-git--ok-p result) (user-error "%s" (cdr result)))))
      (supertag-git--prepare-ignore root retired)
      (let ((paths (supertag-git-sync--commit-pathspecs root)))
        (when paths
          (let ((supertag-git-sync--synchronous t))
            (supertag-git--stage-checked
             root paths (lambda (result)
                          (unless (supertag-git--ok-p result) (user-error "%s" (cdr result))))
             retired)))
        (when (supertag-git-sync--staged-conflict-markers-p root)
          (user-error "Resolve conflict markers before committing"))
        (when (= 1 (car (supertag-git--run root "diff" "--cached" "--quiet")))
          (let ((result (supertag-git--run root "commit" "-m" "Supertag: sync Org text only")))
            (unless (supertag-git--ok-p result) (user-error "%s" (cdr result))))))
      (when (supertag-git-setup--configure-remote root)
        (let ((result (supertag-git-setup--push root)))
          (unless (eq (plist-get result :status) :ok)
            (message "Git push deferred: %s" (plist-get result :error)))))
      (message "Supertag Git: Org root %s; Store remains local at %s" root supertag-db-file)
      (supertag-git-check))))

;;;###autoload
(defun supertag-git-clone (remote-url local-directory)
  "Clone REMOTE-URL into LOCAL-DIRECTORY and rebuild the local Org projection."
  (interactive (list (read-string "Git remote URL: ")
                     (read-directory-name "Clone into directory: ")))
  (when (and (file-directory-p local-directory)
             (directory-files local-directory nil directory-files-no-dot-files-regexp))
    (user-error "Clone destination must be empty"))
  (supertag-git--run-clone remote-url local-directory)
  (supertag-git--prepare-ignore local-directory)
  (let ((supertag--config-guard-allow t))
    (setq supertag-sync-directories (list (supertag-git--truename-dir local-directory))))
  (when (fboundp 'supertag-config-guard--capture) (supertag-config-guard--capture))
  (unless (supertag-git--reindex-org-files)
    (user-error "Org reindex incomplete; run supertag-sync-full-rescan after fixing the source"))
  (supertag-save-store)
  (when (or (supertag-dirty-p) (not (file-exists-p supertag-db-file)))
    (user-error "Org rebuilt but local Store save is pending; resolve the persistence guard"))
  (list :repo-root (car supertag-sync-directories) :rebuilt t :loaded nil
        :db-file supertag-db-file))

(defun supertag-git--cancel-timers ()
  "Cancel this vault's transport timers while retaining enabled mode."
  (dolist (symbol '(supertag-git-sync--pull-timer supertag-git-sync--commit-timer))
    (when (timerp (symbol-value symbol)) (cancel-timer (symbol-value symbol)))
    (set symbol nil)))

(defun supertag-git--resume-timers ()
  "Restore periodic transport after an explicit conflict resolution."
  (when (and supertag-git-sync-mode (not supertag-git--conflicted-files)
             (not supertag-git-sync--pull-timer))
    (setq supertag-git-sync--pull-timer
          (run-with-timer supertag-git-sync-pull-interval supertag-git-sync-pull-interval
                          #'supertag-git-sync--pull))))

(defun supertag-git--pause (files)
  "Pause this vault for FILES and open its first conflict in smerge-mode."
  (setq supertag-git--conflicted-files (delete-dups (append files supertag-git--conflicted-files)))
  (supertag-git--cancel-timers)
  (force-mode-line-update t)
  (message "Supertag Git paused: %s; resolve with smerge-mode, save, then supertag-git-sync-now"
           (string-join supertag-git--conflicted-files ", "))
  (when (car files)
    (find-file (car files))
    (smerge-mode 1)))

(defun supertag-git--project-files (root changed deleted)
  "Queue CHANGED Org paths and orphan nodes from DELETED paths under ROOT."
  (dolist (rel changed)
    (let ((file (file-truename (expand-file-name rel root))))
      (when (and (supertag-git--ancestor-p root file) (file-exists-p file)
                 (not (member file supertag-git--conflicted-files)))
        (when-let* ((buffer (get-file-buffer file)))
          (with-current-buffer buffer
            (unless (buffer-modified-p) (revert-buffer t t t))))
        (supertag-async-enqueue file))))
  (when deleted
    (supertag-sync--snapshot-set (supertag-sync--snapshot-build))
    (dolist (rel deleted)
      (let ((file (file-truename (expand-file-name rel root))))
        (when (and (supertag-git--ancestor-p root file) (not (file-exists-p file)))
          (supertag-sync--verify-file-nodes file (list :nodes-deleted 0))
          (remhash file (supertag-sync--get-state-table)))))
    (supertag-sync-save-state)))

(defun supertag-git--projection-delta (root)
  "Return (CHANGED . DELETED) Org paths from the last merge in ROOT.
Disable rename detection so an old path always reaches orphan verification."
  (let ((result (supertag-git--run root "diff" "--name-status" "-z" "--no-renames"
                                 "ORIG_HEAD" "HEAD" "--" "*.org"))
        changed deleted)
    (unless (supertag-git--ok-p result) (error "%s" (cdr result)))
    (let ((fields (split-string (cdr result) "\0" t)))
      (while fields
        (let ((status (pop fields)) (path (pop fields)))
          (unless path (error "Incomplete Git name-status delta"))
          (cond ((equal status "D") (push path deleted))
                ((member status '("A" "M" "T")) (push path changed))))))
    (cons (nreverse changed) (nreverse deleted))))

(defun supertag-git-sync--after-merge (result root)
  "Pause for unresolved Org conflicts or queue the successful merge's exact delta."
  (let ((conflicts (supertag-git-sync--live-conflicted-org-files root)))
    (cond (conflicts (supertag-git--pause conflicts))
          ((supertag-git--ok-p result)
           (condition-case err
               (let ((delta (supertag-git--projection-delta root)))
                 (supertag-git--project-files root (car delta) (cdr delta)))
             (error (message "Git projection deferred to periodic sync: %s" (error-message-string err))))))))

(defun supertag-git--continue-merge (root)
  "Finish a saved conflict resolution in ROOT.
Return nil while unsaved drafts or conflict markers remain."
  (let* ((files (delete-dups (append supertag-git--conflicted-files
                                    (supertag-git-sync--live-conflicted-org-files root))))
         (remaining
          (cl-remove-if-not
           (lambda (file)
             (or (when-let* ((buffer (get-file-buffer file)))
                   (buffer-modified-p buffer))
                 (and (file-exists-p file) (supertag-git-sync--file-has-conflict-markers-p file)))) files)))
    (if remaining (progn (supertag-git--pause remaining) nil)
      (supertag-git--assert-index-scope root)
      (when (cl-some (lambda (p) (not (supertag-git-sync--auto-commit-path-p root p)))
                     (supertag-git-sync--unmerged-paths root))
        (user-error "Resolve out-of-scope merge paths manually first"))
      (dolist (file files)
        (unless (supertag-git-sync--auto-commit-path-p root (file-relative-name file root))
          (user-error "Local data cannot be staged; run supertag-git-setup: %s" file)))
      (let ((supertag-git-sync--synchronous t))
        (supertag-git--stage-checked
         root (mapcar (lambda (f) (concat ":(literal)" (file-relative-name f root))) files)
         (lambda (result)
           (unless (supertag-git--ok-p result) (user-error "%s" (cdr result))))))
      (when (supertag-git-sync--unmerged-paths root) (user-error "Unresolved merge paths remain"))
      (let ((result (supertag-git--run root "commit" "--no-edit")))
        (unless (supertag-git--ok-p result) (user-error "%s" (cdr result))))
      (setq supertag-git--conflicted-files nil)
      (supertag-git-sync--after-merge '(0 . "") root)
      ;; Choosing the local text may leave no ORIG_HEAD delta, but its
      ;; projection was paused and still needs to be reconciled.
      (supertag-git--project-files
       root (mapcar (lambda (f) (file-relative-name f root))
                    (cl-remove-if-not #'file-exists-p files))
       (mapcar (lambda (f) (file-relative-name f root))
               (cl-remove-if #'file-exists-p files)))
      (supertag-git--resume-timers)
      (setq supertag-git-sync--in-flight t)
      (supertag-git-sync--maybe-push-after-cycle root)
      t)))

;;;###autoload
(defun supertag-git-sync-now ()
  "Synchronize Org text, or continue a saved and explicitly resolved merge."
  (interactive)
  (unless (and supertag-git-sync-mode supertag-git-sync--vault-root)
    (user-error "Enable supertag-git-sync-mode first"))
  (let ((root supertag-git-sync--vault-root))
    (when (supertag-git--retired-tracked root)
      (message "Tracked local data/attributes remain; run supertag-git-setup to stop tracking them"))
    (cond (supertag-git-sync--in-flight (message "Git synchronization already running") nil)
          ((or supertag-git--conflicted-files (supertag-git-sync--live-conflicted-org-files root))
           (supertag-git--continue-merge root))
          (t
           (when (timerp supertag-git-sync--commit-timer) (cancel-timer supertag-git-sync--commit-timer))
           (setq supertag-git-sync--commit-timer nil)
           (if (supertag-git-sync--owned-changes-p root)
               (supertag-git-sync--fire-commit)
             (supertag-git-sync--pull))
           t))))

(defun supertag-git-sync--local-safety-summary (&optional root)
  "Describe Org transport's local pending changes in ROOT."
  (format "Local Org changes: %s; pending commits: %d"
          (if (supertag-git-sync--owned-changes-p (or root supertag-git-sync--vault-root)) "yes" "no")
          supertag-git-sync--pending-push-count))

(defun supertag-git-sync--pending-p ()
  "Return whether the active Org vault has pending text or transport work."
  (and supertag-git-sync--vault-root
       (or supertag-git--conflicted-files
           (supertag-git-sync--owned-changes-p supertag-git-sync--vault-root)
           (> (or (supertag-git-sync--rev-count supertag-git-sync--vault-root "@{upstream}..HEAD") 0) 0))))

(defun supertag-git-sync--query-exit ()
  "Query before normal Emacs exit when Org transport is unfinished."
  (if (not (and (bound-and-true-p supertag-git-sync-mode)
                supertag-git-sync--vault-root))
      t
    (cond
     (supertag-git-sync--in-flight
      (supertag-git-sync--schedule-exit-after-sync)
      (message "supertag-git-sync: waiting for the running synchronization, then Emacs will exit")
      nil)
     ((not (supertag-git-sync--pending-p)) t)
     ((y-or-n-p "Supertag Git sync is unfinished. Sync now before exiting? ")
      (let ((started
             (condition-case err
                 (supertag-git-sync-now)
               (error
                (message "supertag-git-sync: could not start final sync: %s"
                         (error-message-string err))
                nil))))
        (when started
          (supertag-git-sync--schedule-exit-after-sync)
          (message "supertag-git-sync: synchronizing, then Emacs will exit automatically")))
      nil)
     (t
      (yes-or-no-p
       "Exit now with Supertag changes kept only in the local Git vault? ")))))


(defun supertag-git-sync--lighter ()
  "Show pending commits and the conflict pause flag."
  (concat " STG" (when supertag-git--conflicted-files "!")
          (when (> supertag-git-sync--pending-push-count 0)
            (format "↑%d" supertag-git-sync--pending-push-count))))

(defun supertag-git-sync--enable ()
  "Enable transport only for the configured Git root; pause pre-existing conflicts."
  (let ((status (supertag-git-check)))
    (unless (plist-get status :in-repo-p)
      (setq supertag-git-sync-mode nil)
      (user-error "Configure one Git root with supertag-git-setup first"))
    (setq supertag-git-sync--vault-root (plist-get status :repo-root)
          supertag-git-sync--offline-warned nil supertag-git--conflicted-files nil)
    (add-hook 'after-save-hook #'supertag-git-sync--on-file-saved)
    (add-hook 'kill-emacs-query-functions #'supertag-git-sync--query-exit)
    (advice-add 'supertag-sync--process-single-file :around #'supertag-git-sync--skip-conflicted-file-advice)
    (add-function :after after-focus-change-function #'supertag-git-sync--maybe-focus-pull)
    (let ((files (supertag-git-sync--live-conflicted-org-files supertag-git-sync--vault-root)))
      (if files (supertag-git--pause files)
        (supertag-git--resume-timers)
        (unless supertag-git-sync--in-flight
          (setq supertag-git-sync--in-flight t)
          (supertag-git-sync--maybe-push-after-cycle supertag-git-sync--vault-root))))))

(defun supertag-git-sync--disable ()
  "Flush a pending Org commit, remove hooks and cancel transport timers."
  (when supertag-git-sync--commit-timer
    (cancel-timer supertag-git-sync--commit-timer)
    (setq supertag-git-sync--commit-timer nil)
    (supertag-git-sync--fire-commit))
  (supertag-git--cancel-timers)
  (when (timerp supertag-git-sync--exit-wait-timer) (cancel-timer supertag-git-sync--exit-wait-timer))
  (setq supertag-git-sync--exit-wait-timer nil)
  (remove-hook 'after-save-hook #'supertag-git-sync--on-file-saved)
  (remove-hook 'kill-emacs-query-functions #'supertag-git-sync--query-exit)
  (remove-function after-focus-change-function #'supertag-git-sync--maybe-focus-pull)
  (advice-remove 'supertag-sync--process-single-file #'supertag-git-sync--skip-conflicted-file-advice)
  (setq supertag-git-sync--vault-root nil supertag-git--conflicted-files nil))

;;;###autoload
(define-minor-mode supertag-git-sync-mode
  "Synchronize the sole Org Git root; resolve conflicts with smerge then sync-now.
Only Org files and the root ignore file are staged.  Store remains local.
Transport is asynchronous, serialized, and retries a rejected push once."
  :global t :lighter (:eval (supertag-git-sync--lighter)) :group 'supertag-git-sync
  (if supertag-git-sync-mode (supertag-git-sync--enable) (supertag-git-sync--disable)))
(provide 'supertag-git)
;;; supertag-git.el ends here
