;;; supertag-core-persistence.el --- Data persistence for Supertag -*- lexical-binding: t; -*-

;;; Commentary:
;; This file provides functions for persisting the Supertag
;; in-memory store to a file and loading it back.


;; Commands: none; Lisp entrypoints: supertag-load-store, supertag-save-store,
;; supertag-persistence-check-legacy-data-directory, supertag-resolve-data-directories,
;; supertag-restore, supertag-accept-fresh-store; timer lifecycle: supertag-setup-all-timers,
;; supertag-cleanup-all-timers.
;; Dependencies: cl-lib, ht, json, parse-time, supertag-core-store. Lazy migration command:
;; supertag-migrate-run from supertag-migrate.
;;; Code:

(require 'cl-lib)
(require 'ht)
(require 'json) ; For presence-file encode/decode
(require 'parse-time) ; For parse-iso8601-time-string, used by presence
(require 'supertag-core-store) ; For Store, shared state and event notifications

;;; --- Persistence Configuration ---
;; Note: supertag-data-directory is customized in supertag-vault.el
;; This is a fallback definition in case this module is loaded independently
(defvar supertag-data-directory
  (expand-file-name "supertag/" user-emacs-directory)
  "Directory for storing Supertag data.
This is a fallback definition.
The primary customization is in supertag-vault.el.")

(defvar supertag--config-guard-allow)

(defconst supertag-data-version "7.1.0"
  "Current data format version.
Used for data format compatibility checks and automatic migration.

Bumped 7.0.0 -> 7.1.0: `supertag-migrate--apply-legacy-extends' now resolves
`:legacy-extends' records directly into `:extends' on Tag entities (DB-only,
idempotent) instead of leaving them for an interactive path-rename step.
Records that cannot be resolved (missing child/parent, a cycle, or a
conflicting existing `:extends') remain in `:legacy-extends' and are reported
by `supertag-migrate-status' under `:unresolved-extends'.

7.0.0 preserves retired field data as pending migration records.
The verified migration chain stamps this version only after DB steps succeed.

Bumped 6.0.0 -> 6.1.0 to retire the duplicate `:node-tag' relation
projection.  Node `:tags' remains the authoritative membership projection.

Bumped 5.0.0 -> 6.0.0 (P1-8, see
archive/legacy-v2/2026-08-25-phrase/phases/phase-git-sync-20260713/PLAN.md
\"S2 规范化序列化\", 修订 2026-07-13): the S2 canonical, line-per-entity
serialization is NOT actually readable by pre-6.0 (<= 5.9.x) builds the way
the original S2 writeup assumed. Those builds'
`supertag--persistence--try-read-store'
does exactly ONE `read' of the file and returns whatever single form that
call happens to consume; against the canonical format's line-per-entity
layout, that first `read' only ever sees the root scalar line (e.g.
`(:version \"6.0.0\" ...)') and never reaches any of the following
`(:collection ...)' entity lines -- so an old build loads what LOOKS like a
valid, merely-empty store, not a parse error. Bumping the data version at
least makes `supertag--maybe-auto-migrate' fire (with its own pre-migration
snapshot) the first time a pre-6.0 database is loaded by THIS (>= 6.0)
build, and keeps `supertag--get-data-version'/`supertag-migrate-run'
honest about the fact that the format actually changed here. See
`supertag--persistence--write-canonical-store' for the belt-and-suspenders
`supertag-db-preformat6-*' snapshot, which covers the case this version
bump alone does not: a database already stamped `:version \"6.0.0\"' (or
any version equal to `supertag-data-version') by a subsequent save, so
`supertag--maybe-auto-migrate' sees no version mismatch and never runs,
yet the on-disk file might still be the pre-canonical (legacy single-`prin1')
format if it was never resaved since upgrading this package.")

;; Time validation remains with persistence after schema retirement.
(defun supertag--validate-optional-time (time-value)
  "Return non-nil when TIME-VALUE is nil or a valid Emacs time value."
  (or (null time-value)
      (supertag--validate-time time-value)))

(defun supertag--validate-time (time-value)
  "Return non-nil when TIME-VALUE is a four-element (HIGH LOW USEC PSEC) list.
Production code obtains such values from `supertag-current-time' in
supertag-core-store.el; on Emacs 32 `current-time' itself returns
\(TICKS . HZ) and would fail this check."
  (and (listp time-value)
       (= (length time-value) 4)
       (cl-every #'integerp time-value)))

(defun supertag-data-file (filename)
  "Get full path for data file.
FILENAME is relative to `supertag-data-directory`."
  (expand-file-name filename supertag-data-directory))

(defconst supertag-persistence--legacy-data-directory-name "org-supertag"
  "Retired name of the default Supertag data directory.")

(defconst supertag-persistence--current-data-directory-name "supertag"
  "Current name of the default Supertag data directory.")

(defconst supertag-persistence--data-directory-recovery-buffer
  "*Supertag Data Directory Recovery*"
  "Buffer used by `supertag-resolve-data-directories`.")

(defun supertag-persistence-data-directory-state ()
  "Return the state of the retired and current default data directories.
The returned plist contains `:configured`, `:current`, `:legacy`, their
existence flags, and `:issue`.  `:issue` is `:both` when both default roots
exist, `:legacy-only` when only the retired root exists, and nil otherwise.
An explicit non-default `supertag-data-directory` makes `:applicable` nil and
never produces an issue."
  (let* ((configured (file-name-as-directory
                      (expand-file-name supertag-data-directory)))
         (current (file-name-as-directory
                   (expand-file-name
                    supertag-persistence--current-data-directory-name
                    user-emacs-directory)))
         (legacy (file-name-as-directory
                  (expand-file-name
                   supertag-persistence--legacy-data-directory-name
                   user-emacs-directory)))
         (applicable (string= configured current))
         (current-exists (file-exists-p current))
         (legacy-exists (file-exists-p legacy)))
    (list :configured configured
          :current current
          :legacy legacy
          :applicable applicable
          :current-exists current-exists
          :legacy-exists legacy-exists
          :issue (and applicable legacy-exists
                      (if current-exists :both :legacy-only)))))

(defun supertag-persistence-data-directory-recovery-needed-p ()
  "Return non-nil when default data directories require user resolution.
The return value is the issue symbol from
`supertag-persistence-data-directory-state`."
  (plist-get (supertag-persistence-data-directory-state) :issue))

(defun supertag-persistence--database-in-directory (directory)
  "Return the main database candidate to summarize under DIRECTORY.
Prefer an existing configured-name database, then the current `.el` name, then
the older `.db` name.  When none exists, return the current `.el` path so the
comparison can identify the missing candidate precisely."
  (let* ((configured-name
          (and (boundp 'supertag-db-file)
               (stringp supertag-db-file)
               (file-name-nondirectory supertag-db-file)))
         (names (cl-delete-duplicates
                 (delq nil (list configured-name
                                 "supertag-db.el"
                                 "supertag-db.db"))
                 :test #'string=))
         (candidates
          (mapcar (lambda (name) (expand-file-name name directory)) names)))
    (or (cl-find-if #'file-exists-p candidates)
        (expand-file-name "supertag-db.el" directory))))

(defun supertag-persistence--data-directory-db-summary (directory)
  "Return a best-effort database summary for DIRECTORY.
Reading or parsing failures are captured in the returned plist instead of
being signaled, because this summary is diagnostic and must remain usable for
damaged databases."
  (let* ((database (supertag-persistence--database-in-directory directory))
         (attributes (ignore-errors (file-attributes database 'string)))
         (modified (and attributes
                        (file-attribute-modification-time attributes)))
         (size (and attributes (file-attribute-size attributes)))
         (status (if attributes :ok :missing))
         node-count
         read-error)
    (when attributes
      (condition-case err
          (let* ((store (supertag--persistence--try-read-store database))
                 (nodes (and (hash-table-p store)
                             (or (gethash :nodes store)
                                 (gethash 'nodes store)
                                 (gethash "nodes" store)))))
            (unless (hash-table-p store)
              (error "database root is not a hash table"))
            (setq node-count (if (hash-table-p nodes)
                                 (hash-table-count nodes)
                               0)))
        (error
         (setq status :unreadable
               read-error (error-message-string err)))))
    (list :directory directory
          :database database
          :status status
          :modified modified
          :size size
          :node-count node-count
          :read-error read-error)))

(defun supertag-persistence--format-data-directory-summary (label summary)
  "Format LABEL and database SUMMARY for a recovery comparison."
  (let ((status (plist-get summary :status)))
    (format "%s: %s\n  DB: %s\n  Modified: %s\n  Size: %s\n  Nodes: %s%s"
            label
            (abbreviate-file-name (plist-get summary :directory))
            (abbreviate-file-name (plist-get summary :database))
            (if-let* ((modified (plist-get summary :modified)))
                (format-time-string "%Y-%m-%d %H:%M:%S %z" modified)
              "missing")
            (if-let* ((size (plist-get summary :size)))
                (format "%d bytes" size)
              "missing")
            (pcase status
              (:missing "missing")
              (:unreadable "unreadable")
              (_ (number-to-string (or (plist-get summary :node-count) 0))))
            (if (eq status :unreadable)
                (format " (%s)" (plist-get summary :read-error))
              ""))))

(defun supertag-persistence-format-data-directory-comparison (&optional state)
  "Return a human-readable comparison of default data directories.
STATE defaults to `supertag-persistence-data-directory-state`.  Database
metadata and node counts are best effort; an unreadable database is reported
as such rather than aborting the comparison."
  (let* ((state (or state (supertag-persistence-data-directory-state)))
         (legacy (supertag-persistence--data-directory-db-summary
                  (plist-get state :legacy)))
         (current (supertag-persistence--data-directory-db-summary
                   (plist-get state :current))))
    (concat
     (supertag-persistence--format-data-directory-summary
      "Legacy (retired name)" legacy)
     "\n\n"
     (supertag-persistence--format-data-directory-summary
      "Current" current))))

(defun supertag-persistence-check-legacy-data-directory ()
  "Pause startup when retired and current default data roots need resolution.
The error compares both database candidates, states that nothing was changed,
and points to `supertag-resolve-data-directories`.  This check never creates,
moves, or deletes data.  Return t when initialization may continue."
  (let* ((state (supertag-persistence-data-directory-state))
         (issue (plist-get state :issue)))
    (when issue
      (user-error
       (concat
        "Supertag paused startup because %s.\n\n%s\n\n"
        "Data safety: both directories and all database files are unchanged; all data remain safe.\n"
        "Next step: evaluate (supertag-resolve-data-directories) to choose which directory to keep active; the other directory will only be renamed, never deleted")
       (if (eq issue :both)
           "the retired and current data directories both exist"
         "the retired data directory exists but the current directory does not")
       (supertag-persistence-format-data-directory-comparison state)))
    t))

(defun supertag-persistence--retired-data-directory (directory)
  "Return an unused dated retirement path for DIRECTORY.
The first candidate is NAME-retired-YYYYMMDD.  Existing candidates are never
overwritten; suffixes starting with -2 are tried until an unused path exists."
  (let* ((directory (directory-file-name (expand-file-name directory)))
         (parent (file-name-directory directory))
         (name (file-name-nondirectory directory))
         (base (expand-file-name
                (format "%s-retired-%s" name (format-time-string "%Y%m%d"))
                parent))
         (candidate base)
         (suffix 2))
    (while (file-exists-p candidate)
      (setq candidate (format "%s-%d" base suffix)
            suffix (1+ suffix)))
    candidate))

(defun supertag-persistence--format-rename-preview (operations)
  "Format directory rename OPERATIONS for confirmation."
  (mapconcat
   (lambda (operation)
     (format "  %s\n    -> %s"
             (abbreviate-file-name (car operation))
             (abbreviate-file-name (cdr operation))))
   operations "\n"))

(defun supertag-persistence--run-directory-renames (operations)
  "Run directory rename OPERATIONS, rolling back completed steps on error.
Each operation is a cons cell (SOURCE . TARGET).  No target is overwritten and
no data is deleted."
  (let (completed)
    (condition-case err
        (progn
          (dolist (operation operations)
            (rename-file (car operation) (cdr operation) nil)
            (push operation completed))
          t)
      (error
       (let (rollback-errors)
         (dolist (operation completed)
           (condition-case rollback-error
               (when (file-exists-p (cdr operation))
                 (rename-file (cdr operation) (car operation) nil))
             (error
              (push (error-message-string rollback-error) rollback-errors))))
         (if rollback-errors
             (error
              "Data-directory rename failed: %s; rollback was incomplete: %s. No data was deleted; inspect the paths shown in the recovery buffer"
              (error-message-string err)
              (mapconcat #'identity (nreverse rollback-errors) "; "))
           (signal (car err) (cdr err))))))))

(defun supertag-persistence--display-data-directory-recovery (state)
  "Display the recovery comparison and choices described by STATE."
  (let ((buffer
         (get-buffer-create
          supertag-persistence--data-directory-recovery-buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Supertag data directory recovery\n"
                "================================\n\n"
                "Startup found a retired data directory that needs an explicit choice.\n"
                "Compare modification time, byte size, and best-effort node count below.\n\n"
                (supertag-persistence-format-data-directory-comparison state)
                "\n\nNo directory will be deleted. The unselected directory will be renamed "
                "to a dated -retired- archive.\n")
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buffer)))

(defun supertag-resolve-data-directories ()
  "Resolve retired/current default data directories without deleting data.
Show a comparison, let the user keep the current or legacy directory, and
require confirmation of the exact rename operations.  The unselected root is
renamed to a dated `-retired-` archive; name collisions gain a numeric suffix.
When the legacy root is selected it is moved into the current default path.
Afterward, offer to load the selected database immediately."
  (let* ((state (supertag-persistence-data-directory-state))
         (issue (plist-get state :issue))
         (legacy (directory-file-name (plist-get state :legacy)))
         (current (directory-file-name (plist-get state :current))))
    (unless issue
      (user-error
       "No default data-directory conflict needs recovery; %s"
       (if (plist-get state :applicable)
           "the retired directory is absent"
         "supertag-data-directory is explicitly set to a non-default path")))
    (supertag-persistence--display-data-directory-recovery state)
    (let* ((keep-current "Keep current data directory")
           (keep-legacy "Keep legacy data directory")
           (cancel "Cancel")
           (choices (append (when (plist-get state :current-exists)
                              (list keep-current))
                            (list keep-legacy cancel)))
           (choice (completing-read
                    "Data directory recovery choice: " choices nil t nil nil
                    (car choices))))
      (if (string= choice cancel)
          (progn
            (message "Supertag data-directory recovery cancelled; no files were changed")
            (list :status :cancelled :reason :user-cancelled))
        (let* ((kept (if (string= choice keep-current) :current :legacy))
               (operations
                (if (eq kept :current)
                    (list (cons legacy
                                (supertag-persistence--retired-data-directory
                                 legacy)))
                  (append
                   (when (file-exists-p current)
                     (list
                      (cons current
                            (supertag-persistence--retired-data-directory
                             current))))
                   (list (cons legacy current)))))
               (preview (supertag-persistence--format-rename-preview
                         operations)))
          (if (not
               (y-or-n-p
                (format
                 "Perform these renames? No data will be deleted.\n%s\nProceed? "
                 preview)))
              (progn
                (message "Supertag data-directory recovery declined; no files were changed")
                (list :status :cancelled :reason :confirmation-declined))
            (supertag-persistence--run-directory-renames operations)
            (let* ((database (expand-file-name "supertag-db.el" current))
                   (load-now
                    (y-or-n-p
                     "Directories resolved. Load the selected database now (otherwise restart Emacs)? "))
                   load-error)
              (when load-now
                (condition-case err
                    (supertag-load-store database)
                  (error
                   (setq load-now nil
                         load-error (error-message-string err)))))
              (if load-now
                  (message
                   "Supertag data directories resolved; no data was deleted. Selected database loaded from %s"
                   (abbreviate-file-name database))
                (message
                 "Supertag data directories resolved; no data was deleted.%s Restart Emacs to load %s"
                 (if load-error (format " Direct load failed: %s." load-error) "")
                 (abbreviate-file-name database)))
              (list :status :resolved
                    :kept kept
                    :renamed operations
                    :loaded load-now
                    :load-error load-error))))))))

(defcustom supertag-db-file
  (supertag-data-file "supertag-db.el")
  "Database file path."
  :type 'file
  :group 'supertag)

(defcustom supertag-db-backup-directory
  (supertag-data-file "backups")
  "Directory for database backups."
  :type 'directory
  :group 'supertag)

(defcustom supertag-db-auto-save-interval 300
  "Auto-save interval in seconds.
Set to nil to disable auto-save."
  :type '(choice (const :tag "Disable" nil)
                (integer :tag "Interval (seconds)"))
  :group 'supertag)

(defcustom supertag-db-backup-interval 86400
  "Daily backup interval in seconds (default: 24 hours).
Set to nil to disable daily backups."
  :type '(choice (const :tag "Disable" nil)
                (integer :tag "Interval (seconds)"))
  :group 'supertag)

(defcustom supertag-db-backup-keep-days 3
  "Number of days to keep daily backups.
Older backups will be automatically cleaned up."
  :type 'integer
  :group 'supertag)

(defcustom supertag-db-verify-after-save t
  "When non-nil, verify the database file after saving.
The freshly written file is re-read and every durable collection declared
by `supertag--store-collections' is compared with the in-memory Store before
the previous database file is replaced. On mismatch or read error, the write
is aborted and the previous database file is left untouched."
  :type 'boolean
  :group 'supertag)

(defcustom supertag-db-lock t
  "When non-nil, protect the database from concurrent multi-instance access.
Uses Emacs' built-in advisory file locking (`lock-file', `unlock-file',
`file-locked-p') for `supertag-db-file'. By default, local database files use
`supertag-db-lock-directory' so the lock stays on this host instead of a
network or sync filesystem. When another Emacs instance already holds the
lock, this session records the conflict in
`supertag--db-lock-conflict' and refuses to save the database until the
other instance releases the lock (or `supertag-db-retry-lock' is used once
it has exited)."
  :type 'boolean
  :group 'supertag)

(defcustom supertag-db-lock-directory
  (expand-file-name "supertag-locks/" temporary-file-directory)
  "Directory for local database advisory lock files.
When non-nil, local `supertag-db-file' paths are mapped to deterministic
SHA-256 lock names in this directory. This keeps same-host locking out of
network/sync folders, where stale lock artifacts can survive a disconnected
session. Remote/TRAMP database paths and a nil value retain Emacs' native
database-adjacent lock behavior. If this directory cannot be created, the
native behavior is used as a safe fallback."
  :type '(choice (const :tag "Use database directory" nil) directory)
  :group 'supertag)

(defcustom supertag-db-auto-migrate t
  "When non-nil, automatically migrate an out-of-date database after load.
After `supertag-load-store' successfully loads `supertag-db-file', if the
loaded store's :version does not match `supertag-data-version', this session
runs `supertag-migrate-run' automatically instead of requiring
the user to invoke it by hand (see `supertag--maybe-auto-migrate').

A timestamped pre-migration snapshot of the database file is written to
`supertag-db-backup-directory' before migrating. When nil, out-of-date
databases are left as-is after loading; migrate manually with
\\[supertag-migrate-run]."
  :type 'boolean
  :group 'supertag)

(defcustom supertag-presence-enable t
  "When non-nil, write and check an advisory presence file for cross-machine
awareness.

Supertag's database is a single serialized file. Users who sync it via
Dropbox/iCloud/etc. get that sync service's \"whole file, last writer wins,
no warning\" semantics — running Emacs against the same synced database on
two machines at once can silently discard one side's edits. This is NOT a
lock (a sync service's minutes-scale propagation delay means it cannot
physically be one); it is a best-effort, advisory heads-up: a small JSON
file recording which host last touched the database, and when, is written
next to `supertag-db-file' on load and periodically while this session
runs. When another host's presence looks recently active, loading warns
loudly. See README \"Syncing across machines\" for the supported
single-writer workflow this is meant to nudge users toward."
  :type 'boolean
  :group 'supertag)

(defcustom supertag-presence-stale-seconds 300
  "Age in seconds beyond which a foreign presence record is ignored.
A presence record written by another host more than this many seconds ago
is treated as stale — that machine is presumed no longer actively editing —
and `supertag--presence-foreign-active-p' returns nil for it."
  :type 'integer
  :group 'supertag)

(defvar supertag-db--auto-save-timer nil
  "Timer for auto-save.")

(defvar supertag-db--backup-timer nil
  "Timer for daily backup.")

(defvar supertag-db--dirty nil
  "Flag indicating if database has unsaved changes.")

(defvar supertag-db--last-backup-date nil
  "Date of last backup in YYYY-MM-DD format.")

(defvar supertag--store-origin nil
  "Metadata about the loaded store and its originating persistence state.")

(defvar supertag-persistence-after-save-hook nil
  "Normal hook run after `supertag-save-store' successfully writes a
non-empty, actually-dirty store to disk (i.e. after the atomic write, the
dirty flag has been cleared, and the daily-backup check has run -- NOT on
every timer tick, and NOT when a persistence guard skipped or refused the
save). The one clean seam that fires exactly when `supertag-db-file' just
changed
on disk, regardless of whether the save was triggered by the auto-save
timer, an explicit \\[supertag-save-store], or `kill-emacs-hook'. Functions
on this hook take no arguments and must not signal (an error here would
otherwise interrupt whatever just successfully saved the database).")

(defvar supertag-persistence-after-load-hook nil
  "Normal hook run after `supertag-load-store' successfully loads a store
from disk (the branch that sets `supertag--store' from a readable file and
acquires the lock/presence claim -- NOT the fresh-empty-store branch, and
NOT a failed/corrupt-file load). Symmetric to
`supertag-persistence-after-save-hook' and meant for the same purpose:
letting an optional module react to a persistence lifecycle event without
this file requiring that module back (avoiding load-order coupling).
Functions on
this hook take no arguments and must not signal.")

(defvar supertag--db-lock-conflict nil
  "Non-nil when another Emacs instance holds the DB lock.
Holds the owner description string returned by `file-locked-p' (for example
\"user@host.12345:1698765432\") for whichever file `supertag--db-acquire-lock'
last checked. While non-nil, this session refuses to save the database (see
`supertag--persistence-guard-violations'). Cleared automatically once the
lock is acquired or the other instance's lock is found to be gone.")

(defvar supertag--db-locked-file nil
  "File path this Emacs instance currently holds the advisory lock for, or nil.
Tracked separately from `supertag-db-file' so that switching vaults (which
reassigns `supertag-db-file' before the old lock is released) still releases
the correct file's lock.")

;;; --- Multi-instance DB Locking ---

(defun supertag--db-lock-file-transforms (file)
  "Return the local lock transform for FILE, or nil when unavailable.
Only local paths are transformed; a failed directory creation deliberately
falls back to Emacs' native database-adjacent lock behavior."
  (when (and (stringp supertag-db-lock-directory)
             (> (length supertag-db-lock-directory) 0)
             (stringp file)
             (not (file-remote-p supertag-db-lock-directory))
             (not (file-remote-p file)))
    (let ((directory (file-name-as-directory
                      (expand-file-name supertag-db-lock-directory))))
      (when (condition-case nil
                (progn (make-directory directory t) t)
              (error nil))
        (list (list (concat "\\`" (regexp-quote (expand-file-name file)) "\\'")
                    directory
                    'sha256))))))

(defun supertag--db-lock-status (file)
  "Return Emacs' lock status for FILE using SuperTag's lock location."
  (let ((lock-file-name-transforms
         (append (supertag--db-lock-file-transforms file)
                 lock-file-name-transforms)))
    (file-locked-p file)))

(defun supertag--db-lock-file-name (file)
  "Return the actual lock path Emacs uses for FILE."
  (let ((lock-file-name-transforms
         (append (supertag--db-lock-file-transforms file)
                 lock-file-name-transforms)))
    (make-lock-file-name file)))

(defun supertag--db-acquire-lock ()
  "Acquire the advisory lock on `supertag-db-file' for this Emacs instance.
When `supertag-db-lock' is enabled and `supertag-db-file' is set, checks
`file-locked-p' on it: if another Emacs instance already holds the lock
\(i.e. `file-locked-p' returns a string, not t), records the owner in
`supertag--db-lock-conflict' and warns that this session will not save the
database until the conflict clears. Otherwise, clears any previous conflict
and calls `lock-file' — locally binding `create-lockfiles' to t, since
`lock-file' is a no-op when that variable is nil. Any error signaled while
locking is caught and reported via `message' but never propagated, so a
locking problem can never break DB loading."
  (when (and supertag-db-lock
             (stringp supertag-db-file)
             (> (length supertag-db-file) 0))
    (let ((owner (supertag--db-lock-status supertag-db-file)))
      (if (stringp owner)
          (progn
            (setq supertag--db-lock-conflict owner)
            (message "Supertag: database %s is locked by another Emacs instance (%s); this session will NOT save until the lock is released. Restart Emacs once the other instance has exited, or evaluate (supertag-db-retry-lock)."
                     (abbreviate-file-name supertag-db-file) owner))
        (setq supertag--db-lock-conflict nil)
        (condition-case err
            (let ((create-lockfiles t))
              (let ((lock-file-name-transforms
                     (append (supertag--db-lock-file-transforms supertag-db-file)
                             lock-file-name-transforms)))
                (lock-file supertag-db-file))
              (setq supertag--db-locked-file supertag-db-file))
          (error
           (message "Supertag: failed to acquire lock on %s: %s (continuing without a lock)"
                    (abbreviate-file-name supertag-db-file)
                    (error-message-string err))))))))

(defun supertag--db-release-lock ()
  "Release the advisory DB lock held by this Emacs instance, if any.
Safe no-op when no lock is currently held (`supertag--db-locked-file' is
nil). Any error from `unlock-file' is ignored, since a failed unlock must
never interrupt shutdown or vault switching."
  (when supertag--db-locked-file
    (ignore-errors
      (let ((lock-file-name-transforms
             (append (supertag--db-lock-file-transforms supertag--db-locked-file)
                     lock-file-name-transforms)))
        (unlock-file supertag--db-locked-file)))
    (setq supertag--db-locked-file nil))
  (setq supertag--db-lock-conflict nil))

(defun supertag-db-retry-lock ()
  "Retry acquiring the DB lock after a previously detected conflict.
Useful once the other Emacs instance holding the lock on `supertag-db-file'
has exited: re-checks `file-locked-p' and, if the lock is now free (or
already held by this instance), calls `supertag--db-acquire-lock' to take
it over so saves can resume."
  (supertag--db-acquire-lock)
  (if supertag--db-lock-conflict
      (message "Supertag: database %s is still locked by another Emacs instance (%s)."
               (abbreviate-file-name supertag-db-file) supertag--db-lock-conflict)
    (message "Supertag: database lock acquired for %s."
             (abbreviate-file-name supertag-db-file))))

;;; --- Cross-machine Presence (advisory; S0 of the git-sync hardening plan) ---
;;
;; `supertag--db-acquire-lock' above only ever sees *this machine's* other
;; Emacs instances (`lock-file' writes a host-local symlink, using the
;; configured transform above for local databases). It cannot detect a second
;; machine editing the same Dropbox/iCloud-synced database. Presence closes
;; that visibility gap with
;; an ordinary, sync-friendly JSON file instead of a lock primitive: it is
;; written periodically and read on load, purely advisory, and never blocks
;; a save the way a lock conflict does.

(defvar supertag--presence-write-failed nil
  "Non-nil once a presence-file write has failed and been warned about.
Keeps `supertag--presence-write' from spamming a `display-warning' on every
auto-save timer tick after the first failure — the underlying condition
(for example an unwritable data directory) is unlikely to resolve itself
between ticks, so warn once per session and go quiet.")

(defun supertag--presence-file ()
  "Return the path of the advisory cross-machine presence file, or nil.
The file lives NEXT TO `supertag-db-file' (same directory) rather than in a
dedicated state directory, because that shared directory is exactly what
sync services like Dropbox/iCloud propagate for the users this feature is
for. For local-only users, an extra small file there is harmless.
Returns nil when `supertag-db-file' is unset or empty."
  (when (and (stringp supertag-db-file) (> (length supertag-db-file) 0))
    (expand-file-name "supertag-presence.json"
                       (file-name-directory supertag-db-file))))

(defun supertag--presence-write ()
  "Best-effort, atomic write of this session's presence claim.
Writes `{\"host\": ..., \"updatedAt\": ..., \"pid\": ...}' (via
`json-encode') to `supertag--presence-file', using the same temp-file +
`rename-file' pattern as `supertag--persistence-write-store-atomically' so a
concurrent reader never observes a half-written file. `updatedAt' is an
ISO 8601 UTC timestamp.

Never signals: `supertag-presence-enable' nil is a no-op, a nil
`supertag--presence-file' (unset `supertag-db-file') is a no-op, and any
other error is caught and reported via `display-warning' at most once per
session (see `supertag--presence-write-failed') rather than propagated —
a presence-file problem must never break a save or a load."
  (when supertag-presence-enable
    (condition-case err
        (let ((file (supertag--presence-file)))
          (when file
            (let* ((dir (file-name-directory file))
                   (payload (json-encode
                             (list (cons 'host (system-name))
                                   (cons 'updatedAt
                                         (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                                                              nil t))
                                   (cons 'pid (emacs-pid)))))
                   (temp-file (make-temp-file (concat file ".tmp")))
                   (success nil))
              (unless (file-exists-p dir)
                (make-directory dir t))
              (unwind-protect
                  (progn
                    (with-temp-buffer
                      (set-buffer-file-coding-system 'utf-8-unix)
                      (insert payload)
                      (write-region (point-min) (point-max) temp-file nil 'silent))
                    (rename-file temp-file file t)
                    (setq success t))
                (unless success
                  (ignore-errors (delete-file temp-file)))))))
      (error
       (unless supertag--presence-write-failed
         (setq supertag--presence-write-failed t)
         (display-warning
          'supertag
          (format "Supertag: failed to write cross-machine presence file: %s"
                  (error-message-string err))
          :warning))))))

(defun supertag--presence-read ()
  "Return the parsed presence file as an alist, or nil on any error.
Parses `supertag--presence-file' via `json-read-file'. Returns nil when
`supertag-db-file' is unset, the presence file does not exist, or it fails
to parse as JSON — callers must treat nil as \"no usable presence
information\", never as an error."
  (let ((file (supertag--presence-file)))
    (when (and file (file-exists-p file))
      (condition-case nil
          (json-read-file file)
        (error nil)))))

(defun supertag--presence-foreign-active-p ()
  "Return the foreign host string when another machine's presence is active.
Non-nil only when all of the following hold: the presence file exists and
parses, its recorded `host' differs from `(system-name)', its `updatedAt'
parses as ISO 8601 (via `parse-iso8601-time-string'), and that timestamp is
within `supertag-presence-stale-seconds' of now. Returns nil when the file
is missing/unparseable, records this host, or is stale (older than the
threshold)."
  (let* ((data (supertag--presence-read))
         (host (and data (cdr (assq 'host data))))
         (updated-at (and data (cdr (assq 'updatedAt data)))))
    (when (and (stringp host)
               (not (string= host (system-name)))
               (stringp updated-at))
      (let ((parsed (ignore-errors (parse-iso8601-time-string updated-at))))
        (when parsed
          (let ((age (float-time (time-subtract (current-time) parsed))))
            (when (< age supertag-presence-stale-seconds)
              host)))))))

(defun supertag--presence-check-and-claim ()
  "Warn about a recently-active foreign presence, then claim this host's.
Meant to run right after a successful `supertag-load-store'. When
`supertag--presence-foreign-active-p' reports another host was recently
active on this database, shows a loud, actionable `display-warning' (not a
`message': a status-bar message is too easy to miss at exactly the moment
this matters, right after opening a database another machine may still be
writing to). Afterwards — whether or not a warning was shown — writes this
session's own presence via `supertag--presence-write', claiming the
database for this host going forward."
  (when supertag-presence-enable
    (let ((foreign-host (supertag--presence-foreign-active-p)))
      (when foreign-host
        (let* ((data (supertag--presence-read))
               (updated-at (and data (cdr (assq 'updatedAt data))))
               (parsed (and (stringp updated-at)
                            (ignore-errors (parse-iso8601-time-string updated-at))))
               (age (and parsed (round (float-time (time-subtract (current-time) parsed))))))
          (display-warning
           'supertag
           (format "SUPERTAG: ANOTHER MACHINE MAY STILL BE EDITING THIS DATABASE.

Host %s was active on this database %s ago (%s).

This database file has no merge support: if you keep editing on both
machines at the same time, whichever one saves LAST WINS and the other
machine's changes are silently discarded — there will be no error, no
conflict marker, just quietly lost work.

If you are done editing on %s, this warning is safe to ignore.
Otherwise, quit Emacs there before continuing to edit here.

See README \"Syncing across machines\" for the supported workflow."
                   foreign-host
                   (if age (format "%d second%s" age (if (= age 1) "" "s")) "recently")
                   (abbreviate-file-name supertag-db-file)
                   foreign-host)
           :warning))))
    (supertag--presence-write)))

(defun supertag--presence-release ()
  "Best-effort delete of this host's own presence claim.
Meant to run on `kill-emacs-hook'. Deletes `supertag--presence-file' ONLY
when it still names this host (`(system-name)') — if another, newer machine
has since overwritten it with its own claim, that claim is left alone,
since deleting it would erase real presence information that other host's
own load-time check depends on. Any error is ignored: a failed delete must
never interrupt shutdown."
  (when supertag-presence-enable
    (ignore-errors
      (let* ((file (supertag--presence-file))
             (data (and file (file-exists-p file) (supertag--presence-read)))
             (host (and data (cdr (assq 'host data)))))
        (when (and file (stringp host) (string= host (system-name)))
          (delete-file file))))))

;;; --- Backup Functions ---

(defun supertag-get-backup-filename (date-str)
  "Generate backup filename for given DATE-STR in YYYY-MM-DD format."
  (expand-file-name
   (format "supertag-db-%s.el" date-str)
   supertag-db-backup-directory))

(defun supertag-create-daily-backup ()
  "Create a daily backup of the database if needed.
Returns t if backup was created, nil if not needed."
  (let* ((today (format-time-string "%Y-%m-%d"))
         (backup-file (supertag-get-backup-filename today)))
    (if (file-exists-p backup-file)
        nil
      (when (file-exists-p supertag-db-file)
        (supertag-persistence-ensure-data-directory)
        (copy-file supertag-db-file backup-file)
        (setq supertag-db--last-backup-date today)
        (message "Daily backup created: %s" backup-file)
        t))))

(defun supertag--persistence-recovery-pending-p ()
  "Return non-nil while the store is blocked awaiting recovery.
True when the last load left the origin `:failed' (unreadable database)
or `:missing-with-backups' (database gone, snapshots survive).  While
this holds, nothing may rotate, delete, or commit over the surviving
on-disk evidence."
  (memq (plist-get supertag--store-origin :status)
        '(:failed :missing-with-backups)))

(defun supertag-cleanup-old-backups ()
  "Remove backup files older than `supertag-db-backup-keep-days` days.
Does nothing while recovery is pending: when the live database is
missing or unreadable, the old snapshots ARE the data, and rotation
must not shrink the recovery window."
  (if (supertag--persistence-recovery-pending-p)
      (message "Supertag: backup rotation skipped while the database awaits recovery.")
    (when (file-exists-p supertag-db-backup-directory)
    (let* ((cutoff-time (time-subtract (current-time)
                                      (days-to-time supertag-db-backup-keep-days)))
           (backup-files (directory-files supertag-db-backup-directory t
                                         "^supertag-db-[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\.el$"))
           (removed-count 0))
      (dolist (backup-file backup-files)
        (let ((file-time (nth 5 (file-attributes backup-file))))
          (when (time-less-p file-time cutoff-time)
            (delete-file backup-file)
            (cl-incf removed-count)
            (message "Removed old backup: %s" backup-file))))
      (when (> removed-count 0)
        (message "Cleaned up %d old backup files" removed-count))))))

(defun supertag-backup-database-now ()
  "Force create a backup immediately and clean up old backups."
  (supertag-create-daily-backup)
  (supertag-cleanup-old-backups))

(defun supertag-check-daily-backup ()
  "Check if daily backup is needed and create one if necessary."
  (let ((today (format-time-string "%Y-%m-%d")))
    (unless (string= today supertag-db--last-backup-date)
      (when (supertag-create-daily-backup)
        (supertag-cleanup-old-backups)))))

;;; --- Persistence Functions ---

(defun supertag-mark-dirty ()
  "Mark database as having unsaved changes."
  (setq supertag-db--dirty t))

(defun supertag-clear-dirty ()
  "Clear database unsaved changes flag."
  (setq supertag-db--dirty nil))

(defun supertag-dirty-p ()
  "Check if database has unsaved changes."
  supertag-db--dirty)

(defun supertag--count-nodes ()
  "Return the number of node entries in the store."
  (let ((nodes-table (supertag-store-get-collection :nodes)))
    (if (hash-table-p nodes-table)
        (hash-table-count nodes-table)
      0)))

(defun supertag--persistence--normalize-path (path)
  "Normalize PATH for comparison, or nil when PATH is invalid."
  (when (and (stringp path) (> (length path) 0))
    (expand-file-name path)))

(defun supertag--persistence--expected-sync-state-file ()
  "Return expected sync-state path derived from current data directory."
  (when (and (boundp 'supertag-data-directory)
             (stringp supertag-data-directory)
             (> (length supertag-data-directory) 0))
    (expand-file-name "sync-state.el"
                      (file-name-as-directory
                       (expand-file-name supertag-data-directory)))))

(defun supertag--persistence--data-dir ()
  "Return normalized `supertag-data-directory`, or nil when unset."
  (when (and (boundp 'supertag-data-directory)
             (stringp supertag-data-directory)
             (> (length supertag-data-directory) 0))
    (file-name-as-directory
     (expand-file-name supertag-data-directory))))

(defun supertag--persistence--default-db-file ()
  "Return the default DB file path derived from `supertag-data-directory`."
  (let ((dir (supertag--persistence--data-dir)))
    (when dir
      (expand-file-name "supertag-db.el" dir))))

(defun supertag--persistence--newest-db-snapshot (&optional dir)
  "Return newest DB snapshot file under DIR (or `supertag-data-directory`).

This is a best-effort fallback for legacy filenames like
`supertag-db-YYYY-MM-DD.el`
or files with a `.db` extension that still contain an Emacs-lisp printed store."
  (let* ((dir (or dir (supertag--persistence--data-dir))))
    (when (and dir (file-directory-p dir))
      (let* ((candidates (directory-files dir t "^supertag-db-.*\\.\\(el\\|db\\)$" t))
             (dated (delq nil
                          (mapcar (lambda (path)
                                    (let ((attrs (ignore-errors (file-attributes path))))
                                      (when attrs
                                        (cons path (nth 5 attrs)))))
                                  candidates)))
             (sorted (sort dated (lambda (a b) (time-less-p (cdr b) (cdr a))))))
        (car (car sorted))))))

(defun supertag--persistence--db-file-candidates (&optional file)
  "Return a de-duplicated list of DB file candidates for FILE/current config."
  (let* ((explicit (supertag--persistence--normalize-path file))
         (configured (supertag--persistence--normalize-path supertag-db-file))
         (default (supertag--persistence--default-db-file))
         (legacy (let ((dir (supertag--persistence--data-dir)))
                   (when dir
                     (expand-file-name "supertag-db.db" dir))))
         (snapshot (supertag--persistence--newest-db-snapshot)))
    (cl-delete-duplicates (delq nil (list explicit configured default legacy snapshot))
                          :test #'string=
                          :from-end t)))

(defun supertag--persistence--pick-readable-file (paths)
  "Return the first readable regular file in PATHS, or nil."
  (cl-loop for path in paths
           for expanded = (and (stringp path)
                               (> (length path) 0)
                               (ignore-errors (expand-file-name path)))
           when (and expanded
                     (file-exists-p expanded)
                     (not (file-directory-p expanded))
                     (file-readable-p expanded))
           return expanded))

(defun supertag--persistence--set-db-file (path)
  "Set `supertag-db-file` to PATH, respecting config guard when available."
  (when (and (stringp path) (> (length path) 0))
    (let ((supertag--config-guard-allow t))
      (setq supertag-db-file path))))

;;; --- S2: Canonical, deterministic, line-per-entity serialization ---
;;
;; Design goal (see archive/legacy-v2/2026-08-25-phrase/phases/phase-git-sync-20260713/PLAN.md "S2 规范化
;; 序列化"): same logical store content must produce byte-identical output on
;; any machine, and a single-field change on one entity must show up as a
;; single-line `git diff'. This is a hard prerequisite for S3's git merge
;; driver, which parses this exact line format.
;;
;; FORMAT (frozen once tests pass — S3 depends on it):
;;
;;   ;; -*- mode: lisp-data; coding: utf-8-unix -*-
;;   ;; supertag-db canonical format 1
;;   (:version "5.0.0")                              <- root scalars, one line
;;   (:collection :nodes :id "node-a" :data (...))    <- one line per entity
;;   (:collection :nodes :id "node-b" :data (...))
;;   (:collection :tags :id "tag-x" :data (...))
;;
;; - Root keys of the store are split into "collections" (hash-table valued
;;   — printed one entity per line, collections ordered alphabetically by
;;   keyword name, entities within a collection ordered by `string<' of their
;;   id's string form) and "scalars" (everything else, e.g. :version —
;;   merged into a single sorted plist line).
;; - Every plist appearing inside entity :data is printed with its keys
;;   sorted alphabetically, RECURSIVELY into nested plists. Ordinary
;;   (non-plist) lists are walked but never reordered — only their elements
;;   are recursively canonicalized, preserving original element order.
;; - PRE-CHECK FINDING (hash tables nested in entity data): the store is NOT
;;   uniformly plists-all-the-way-down. `supertag-store-get-collection
;;   :fields' (legacy three-level node -> tag -> field nesting, see
;;   the legacy migration reader) and `:field-values'
;;   (two-level node -> field nesting, see the legacy migration reader
;;   in supertag-core-store.el) are populated by direct hash-table puts that
;;   bypass `supertag-store-put-entity'/`supertag--normalize-entity', so the
;;   ENTITY VALUE for those two collections is itself a hash table, not a
;;   plist. Rather than assert "always a plist" and error on this (as a
;;   naive first cut might), `supertag--persistence--canonicalize-value'
;;   below handles hash tables found ANYWHERE in entity data generically: it
;;   freezes them into a sorted, re-readable `(:supertag-hash-table ...)'
;;   marker form (see that function and `supertag--persistence--thaw-value'
;;   for the inverse). This also means no assumption is silently made about
;;   which collections may contain nested hash tables — any hash table
;;   anywhere in the tree is handled the same way.
;; - PRE-CHECK FINDING (cross-entity shared structure): a probe over the
;;   10k-node fixture in test/perf-benchmark.el found ~20,000 `eq'-shared
;;   cons cells — but ALL of it traced back to that fixture building a
;;   single `field-defs' list once and reusing the SAME object across all 50
;;   synthetic tags' :fields slot (the fixture docstring says outright it
;;   "bypass[es] the ops/commit layer entirely"). Real write paths
;;   (e.g. `supertag-tag-create' in supertag-tag.el) go through
;;   `supertag--deep-copy-plist' specifically to avoid this kind of aliasing.
;;   Regardless of which case applies, per-entity independent `prin1' (no
;;   `print-circle' spanning multiple lines) makes cross-entity sharing a
;;   pure non-issue for correctness: each entity's data is fully
;;   materialized on its own line, so shared structure just gets printed
;;   (and, after a load, held) as separate `equal'-but-not-`eq' copies. No
;;   coercion-layer surgery was needed in supertag-core-store.el.
;; - `print-circle' is still bound around each per-line `prin1' call, which
;;   protects against a genuinely self-referential value WITHIN one entity's
;;   own data (distinct from cross-entity sharing above); Emacs builds a
;;   fresh circular-reference table for every top-level `prin1' call, so
;;   binding it once around the whole write (rather than re-binding inside
;;   the loop) still gives each line independent, correct handling.

(defun supertag--persistence-canonical-format-header ()
  "Return the two-line header written at the top of every canonical DB file.
The second line embeds the CURRENT `supertag-data-version' (computed at
call time, not baked into a `defconst', so it always reflects whatever
this build's version actually is) alongside the canonical format-generation
number -- see P1-8 /
archive/legacy-v2/2026-08-25-phrase/phases/phase-git-sync-20260713/PLAN.md \"S2
规范化序列化\", 修订 2026-07-13. This is a `;'-comment, skipped by
`supertag--persistence--skip-leading-comments-and-whitespace' before any
`read', so it carries no parsing weight -- it exists purely so a human (or
a pre-6.0 build's `supertag-db-inspect-file', which still does its own raw
`read' + `hash-table-p' check on whatever the first form turns out to be)
has a fighting chance of noticing the format at a glance. The load-bearing
machine-readable sentinel is the root scalar line printed by
`supertag--persistence--write-canonical-store' below (`:supertag-format' /
`:incompatible-notice'), not this comment."
  (format ";; -*- mode: lisp-data; coding: utf-8-unix -*-\n;; supertag-db canonical format 1, data version %s\n"
          supertag-data-version))

(defconst supertag--persistence--hash-marker :supertag-hash-table
  "Marker keyword identifying a frozen hash table in canonical output.
See `supertag--persistence--canonicalize-value' and
`supertag--persistence--thaw-value'.")

(defconst supertag--persistence-format-marker 1
  "Canonical on-disk format generation number.
Distinct from `supertag-data-version' (the application-level data-shape
version): this tracks the S2 line-per-entity FILE FORMAT itself, which has
not changed since its introduction (git-sync S2) even though the data
version has been bumped (P1-8). Embedded, unconditionally, into every
canonical save's root scalar line via `:supertag-format' -- see
`supertag--persistence--write-canonical-store'.")

(defconst supertag--persistence-incompatible-notice
  "This DB uses org-supertag >= 6.0 canonical format. An org-supertag < 6.0 (e.g. 5.9.x) session reads only this single header form as its ENTIRE database via one `read' call and will show zero nodes/tags -- your data is NOT lost, it is still in this file below this line, but do not keep editing or saving from that old session. To downgrade, restore the newest backups/supertag-db-preformat6-*.el snapshot over this file (see supertag--persistence--write-store-atomically / README \"Syncing across machines\")."
  "Sentinel text embedded, verbatim, into every canonical save's root scalar
line under the `:incompatible-notice' key (P1-8). Deliberately kept on a
SINGLE physical line (no embedded newlines): the canonical writer does not
bind `print-escape-newlines', so a literal newline inside this string would
print as an actual line break and break the \"one line per top-level form\"
property the whole S2 format depends on for clean `git diff' output and
for `supertag--persistence--read-canonical-forms' treating each buffer
line as one `read'. This cannot retroactively fix a pre-6.0 reader (which
never gets far enough to see this key at all -- its one `read' call
returns before this string would even be reached if it did), but it
means ANY code path that DOES surface the raw first form of a >= 6.0
canonical file (an old build's `supertag-db-inspect-file', `find-file' +
manual `read', etc.) has a chance of showing the user something
actionable instead of an inert, silently-empty-looking plist.")

(defun supertag--persistence--sort-key (key)
  "Return a string used to order KEY (an entity id or hash-table key).
Coerces KEY to a string form equivalent to `format \"%s\"' so ids/keys of
different Lisp types (strings, keywords, numbers, symbols) still sort
consistently and deterministically against each other. Special-cased for
the two overwhelmingly common cases — a plain string (most entity ids)
returned as-is, and a symbol/keyword (all plist keys) via `symbol-name'
— to skip `format''s general parsing machinery, since this runs on every
entity id and every plist key in the whole store."
  (cond
   ((stringp key) key)
   ((symbolp key) (symbol-name key))
   (t (format "%s" key))))

(defun supertag--persistence--sort-pairs-by-key (pairs)
  "Return PAIRS (each a cons `(KEY . VALUE)') sorted by KEY's sort key.
A Schwartzian transform: `supertag--persistence--sort-key' is computed
exactly ONCE per pair up front, rather than repeatedly inside the sort
comparator. This matters at the DB's real scale — computing it inside the
comparator costs O(n log n) `format' calls (one measured run over 5k
entities alone made the canonical writer ~14x slower than a plain
`prin1' dump, almost entirely `format' overhead in comparators; this
transform brought it back under the 2x perf-guard budget in
test/canonical-serialization-test.el)."
  (mapcar #'cdr
          (sort (mapcar (lambda (pair)
                          (cons (supertag--persistence--sort-key (car pair)) pair))
                        pairs)
                (lambda (a b) (string< (car a) (car b))))))

(defun supertag--persistence--plist-p (value)
  "Conservatively detect whether VALUE looks like a plist.
Returns non-nil only for a proper, non-empty, even-length list whose
element at every even (0-based) index is a keyword. This deliberately
excludes nil/empty lists, improper (dotted) lists, and lists of
non-keyword-prefixed items — e.g. `:tag-field-associations' values (an
ordinary list of association plists) do not themselves satisfy this
predicate, so they are walked element-by-element but never key-sorted or
reordered as a whole.

This predicate alone is used only by callers outside the hot
canonicalization path (e.g. the canonical-format reader, which calls it
at most once per line); `supertag--persistence--canonicalize-value' below
uses the fused `supertag--persistence--plist-pairs-or-nil' instead, which
detects AND collects in one pass — see that function's docstring for why."
  (let ((len (proper-list-p value)))
    (and len
         (> len 0)
         (cl-evenp len)
         (cl-loop for cell on value by #'cddr
                  always (keywordp (car cell))))))

(defun supertag--persistence--plist-pairs-or-nil (value)
  "Return VALUE's `(SORT-KEY KEY . RAW-VALUE)' triples if it is a plist,
else nil.
A fused, single-pass replacement for calling
`supertag--persistence--plist-p' (itself a full traversal) and THEN
separately collecting key/value pairs (a second full traversal): this
walks VALUE exactly once, bailing out immediately on the first sign it
is not a plist (an odd remaining length, or a non-keyword key), and
precomputes each key's `supertag--persistence--sort-key' along the way so
the caller's `sort' never needs to recompute it. This is on the hottest
path in the file — `supertag--persistence--canonicalize-value' runs it on
every cons it visits — and collapsing several O(n) passes into one made a
measurable difference on the 5k-node perf-guard benchmark in
test/canonical-serialization-test.el (originally ~14x the cost of a
plain `prin1' dump; the budget is 2x)."
  (let ((cursor value) (pairs nil) (ok t))
    (while (and ok (consp cursor))
      (let ((k (car cursor)))
        (if (and (keywordp k) (consp (cdr cursor)))
            (progn
              (push (cons (supertag--persistence--sort-key k) (cons k (cadr cursor))) pairs)
              (setq cursor (cddr cursor)))
          (setq ok nil))))
    (and ok (null cursor) pairs)))

(defsubst supertag--persistence--canonicalize-maybe-atom (value)
  "Like `supertag--persistence--canonicalize-value', but inlined and with a
fast exit for anything that cannot possibly need canonicalizing: only
conses, hash tables, and vectors are ever restructured, so the
overwhelmingly common case of a plain leaf value (string/number/keyword/
symbol/nil — most values in most plists) skips the real function call
entirely. Being a `defsubst', this check itself is inlined at every call
site rather than adding another call frame. This one change measurably
mattered on the 10k-node fixture used by the perf-guard test."
  (if (or (consp value) (hash-table-p value) (vectorp value))
      (supertag--persistence--canonicalize-value value)
    value))

(defun supertag--persistence--rebuild-sorted-plist (pairs)
  "Rebuild a flat, sorted, canonicalized plist from PAIRS.
PAIRS is the `(SORT-KEY KEY . RAW-VALUE)' triple list returned by
`supertag--persistence--plist-pairs-or-nil'.

Builds one small `(KEY VALUE)' list per pair and splices them together
with `nconc' (each pair still in its own freshly-consed 2-element list,
so this is safe) rather than a single shared `push'/`nreverse'
accumulator — pushing both KEY and VALUE onto one accumulator and
reversing once at the end does NOT recover the right order: reversing
the whole flat sequence also swaps each pair's internal key/value
positions, not just the pairs' relative order. (Caught by
test/canonical-serialization-test.el's sorted-invariants test.)"
  (setq pairs (sort pairs (lambda (a b) (string< (car a) (car b)))))
  (apply #'nconc
         (mapcar (lambda (p)
                   (list (cadr p) (supertag--persistence--canonicalize-maybe-atom (cddr p))))
                 pairs)))

(defun supertag--persistence--freeze-hash-table (table)
  "Return a canonical, sorted, re-readable form of hash table TABLE.
The result is `(:supertag-hash-table ((KEY . VALUE) ...))' with entries
sorted by `supertag--persistence--sort-key' on KEY and VALUE canonicalized
recursively. `supertag--persistence--thaw-value' reverses this back into an
actual (`equal'-test) hash table on load. Sorting a hash table's entries
for deterministic output is NOT the same thing as reordering an ordinary
list's elements (which `supertag--persistence--plist-p'/canonicalize-value
never do) — a hash table has no inherent element order to preserve in the
first place."
  (let (pairs)
    (maphash (lambda (k v) (push (cons (supertag--persistence--sort-key k) (cons k v)) pairs))
             table)
    (setq pairs (sort pairs (lambda (a b) (string< (car a) (car b)))))
    (list supertag--persistence--hash-marker
          (mapcar (lambda (p) (cons (cadr p) (supertag--persistence--canonicalize-maybe-atom (cddr p))))
                  pairs))))

(defun supertag--persistence--canonicalize-value (value)
  "Return VALUE with nested hash tables frozen and plist keys sorted.
Recurses into plists (sorting keys), ordinary lists (preserving element
order), improper/dotted conses, and vectors. Atoms are returned unchanged.
See the commentary above `supertag--persistence-canonical-format-header'
for why this is safe with respect to cross-entity shared structure."
  (cond
   ((hash-table-p value)
    (supertag--persistence--freeze-hash-table value))
   ((consp value)
    (let ((plist-pairs (supertag--persistence--plist-pairs-or-nil value)))
      (if plist-pairs
          (supertag--persistence--rebuild-sorted-plist plist-pairs)
        (let ((len (proper-list-p value)))
          (if len
              (mapcar #'supertag--persistence--canonicalize-maybe-atom value)
            (cons (supertag--persistence--canonicalize-maybe-atom (car value))
                  (supertag--persistence--canonicalize-maybe-atom (cdr value))))))))
   ((vectorp value)
    (apply #'vector
           (mapcar #'supertag--persistence--canonicalize-maybe-atom (append value nil))))
   (t value)))

(defun supertag--persistence--empty-collection-p (value)
  "Return non-nil when VALUE is a missing or empty Store collection."
  (or (eq value supertag--not-found)
      (and (hash-table-p value) (= 0 (hash-table-count value)))))

(defun supertag--persistence--collection-roundtrip-equal-p (left right collection)
  "Return non-nil when COLLECTION has equal contents in LEFT and RIGHT.
Missing and empty collections are equivalent because the canonical writer
does not emit lines for an empty hash table."
  (let ((left-table (if (hash-table-p left)
                        (gethash collection left supertag--not-found)
                      supertag--not-found))
        (right-table (if (hash-table-p right)
                         (gethash collection right supertag--not-found)
                       supertag--not-found)))
    (cond
     ((and (supertag--persistence--empty-collection-p left-table)
           (supertag--persistence--empty-collection-p right-table))
      t)
     ((and (hash-table-p left-table) (hash-table-p right-table)
           (= (hash-table-count left-table) (hash-table-count right-table)))
      (catch 'mismatch
        (maphash
         (lambda (id value)
           (let ((other (gethash id right-table supertag--not-found)))
             (when (or (eq other supertag--not-found)
                       (not (equal
                             (supertag--persistence--canonicalize-value value)
                             (supertag--persistence--canonicalize-value other))))
               (throw 'mismatch nil))))
         left-table)
        t))
     (t nil))))

(defun supertag--persistence--mismatched-durable-collections (left right)
  "Return durable collections or pending migration roots lost on roundtrip."
  (append
   (cl-loop for collection in supertag--store-collections
            unless (supertag--persistence--collection-roundtrip-equal-p
                    left right collection)
            collect collection)
   ;; These are migration records, not initialized entity collections.
   (cl-loop for key in '(:legacy-fields :legacy-extends :version)
            unless (equal (supertag--persistence--canonicalize-value
                           (gethash key left supertag--not-found))
                          (supertag--persistence--canonicalize-value
                           (gethash key right supertag--not-found)))
            collect key)))

(defun supertag--persistence--thaw-value (value)
  "Inverse of `supertag--persistence--canonicalize-value'.
Rebuilds an `equal'-test hash table from any
`(:supertag-hash-table ((KEY . VALUE) ...))' marker found anywhere in
VALUE (at any nesting depth), recursing into plists/lists/vectors exactly
like the canonicalizer. Everything else is returned unchanged."
  (cond
   ((and (consp value)
         (eq (car value) supertag--persistence--hash-marker)
         (consp (cdr value))
         (null (cddr value)))
    (let ((table (ht-create)))
      (dolist (pair (cadr value))
        (puthash (car pair) (supertag--persistence--thaw-value (cdr pair)) table))
      table))
   ((null value) nil)
   ((vectorp value)
    (apply #'vector (mapcar #'supertag--persistence--thaw-value (append value nil))))
   ((consp value)
    (let ((len (proper-list-p value)))
      (if len
          (mapcar #'supertag--persistence--thaw-value value)
        (cons (supertag--persistence--thaw-value (car value))
              (supertag--persistence--thaw-value (cdr value))))))
   (t value)))

(defun supertag--persistence--write-canonical-store (store buffer)
  "Insert the canonical, deterministic serialization of STORE into BUFFER.
STORE must be a hash table (the shape `supertag--store' always has after
`supertag--ensure-store'). See the format commentary above
`supertag--persistence-canonical-format-header'.

The root scalar line ALWAYS carries `:supertag-format' and
`:incompatible-notice' (P1-8), overriding any value STORE itself happens to
have under those two keys -- so the embedded notice never goes stale even
if it were somehow carried forward from an older save, and the root scalar
line is therefore never empty even for an otherwise all-default store."
  (unless (hash-table-p store)
    (error "supertag--persistence--write-canonical-store: STORE must be a hash table, got: %S"
           store))
  (let (collections scalars)
    (maphash (lambda (k v)
               (when (eq k :collection)
                 (error "supertag--persistence--write-canonical-store: store has a root key literally named :collection, which collides with the canonical entity-line marker"))
               (if (hash-table-p v)
                   (push (cons k v) collections)
                 (push (cons k v) scalars)))
             store)
    ;; Force the P1-8 sentinel keys onto the root scalar line unconditionally
    ;; -- see this function's docstring above.
    (setq scalars (cl-remove-if (lambda (pair)
                                   (memq (car pair) '(:supertag-format :incompatible-notice)))
                                 scalars))
    (push (cons :incompatible-notice supertag--persistence-incompatible-notice) scalars)
    (push (cons :supertag-format supertag--persistence-format-marker) scalars)
    (with-current-buffer buffer
      (insert (supertag--persistence-canonical-format-header))
      (let ((print-escape-nonascii t)
            (print-length nil)
            (print-level nil)
            (print-circle t))
        ;; --- Root scalars: one sorted plist line ---
        (when scalars
          (setq scalars (supertag--persistence--sort-pairs-by-key scalars))
          (prin1 (apply #'append
                        (mapcar (lambda (pair)
                                  (list (car pair)
                                        (supertag--persistence--canonicalize-value (cdr pair))))
                                scalars))
                 buffer)
          (insert "\n"))
        ;; --- Collections, alphabetical order; entities sorted by id ---
        (setq collections (supertag--persistence--sort-pairs-by-key collections))
        (dolist (coll collections)
          (let ((coll-key (car coll))
                entries)
            ;; Precompute each id's sort key inline during the `maphash' walk
            ;; (rather than a separate pass afterward) — this list is
            ;; potentially the largest in the whole store (e.g. :nodes), so
            ;; folding pair-collection and sort-key computation into one
            ;; pass matters here more than anywhere else in this file.
            (maphash (lambda (id data)
                       (push (cons (supertag--persistence--sort-key id) (cons id data)) entries))
                     (cdr coll))
            (setq entries (sort entries (lambda (a b) (string< (car a) (car b)))))
            (setq entries (mapcar #'cdr entries))
            (dolist (entry entries)
              ;; The entity's own :id field is very often `eq' to the id used
              ;; as its collection key (both usually trace back to the same
              ;; string object a caller built once and reused for both the
              ;; hash key and the `:id' plist slot). Printed with a shared
              ;; `print-circle' scope across the WHOLE envelope form below,
              ;; that would emit `#1="node-a" ... :id #1#' instead of the
              ;; plain `"node-a"' the format spec shows — still perfectly
              ;; readable, but needlessly noisy and an unnecessary deviation
              ;; from the frozen example. A cheap defensive copy of the
              ;; envelope id (strings only; other id types such as keywords
              ;; or fixnums are immutable/interned and print-circle does not
              ;; number them anyway) sidesteps this without touching
              ;; `:data' itself or giving up `print-circle' as a guard
              ;; against genuine self-reference elsewhere in the entity.
              (let ((envelope-id (if (stringp (car entry))
                                     (copy-sequence (car entry))
                                   (car entry))))
                (prin1 (list :collection coll-key
                             :id envelope-id
                             :data (supertag--persistence--canonicalize-value (cdr entry)))
                       buffer))
              (insert "\n"))))))))

(defun supertag--persistence--read-canonical-forms ()
  "Read a canonical-format DB from the current buffer.
Point must be at (or before) the first non-comment sexp. Returns a fresh
hash table shaped like `supertag--coerce-store-table' would produce:
collection keywords mapped to hash tables of id -> data, plus any root
scalar keys (e.g. :version) merged in directly."
  (let ((store (ht-create))
        (read-circle t)
        (keep-reading t))
    (while keep-reading
      (let ((form (condition-case nil
                      (read (current-buffer))
                    (end-of-file (setq keep-reading nil) nil))))
        (when keep-reading
          (cond
           ((and (consp form) (eq (car form) :collection))
            (let* ((coll (plist-get form :collection))
                   (id (plist-get form :id))
                   (data (supertag--persistence--thaw-value (plist-get form :data)))
                   (bucket (or (gethash coll store)
                               (let ((ht (ht-create)))
                                 (puthash coll ht store)
                                 ht))))
              (puthash id data bucket)))
           ((supertag--persistence--plist-p form)
            (cl-loop for (k v) on form by #'cddr
                     do (puthash k (supertag--persistence--thaw-value v) store)))
           (t
            (error "supertag-db canonical format: unrecognized top-level form: %S" form))))))
    store))

(defun supertag--persistence--skip-leading-comments-and-whitespace ()
  "Move point in the current buffer past leading whitespace/`;'-comment lines."
  (goto-char (point-min))
  (while (progn
           (skip-chars-forward " \t\r\n")
           (looking-at-p ";"))
    (forward-line 1)))

(define-error 'supertag-persistence-conflict-markers-error
  "Supertag: file contains unresolved git merge conflict markers")

(defun supertag--persistence--buffer-has-conflict-markers-p ()
  "Return non-nil if the current buffer contains unresolved git conflict
markers.
Looks for a line beginning with any of the three literal git conflict
marker prefixes (`<<<<<<<', `=======', `>>>>>>>') -- the shape git itself
leaves behind in a file when a merge (or the S2-format degradation path:
git's own default line-oriented text merge, run because no semantic merge
driver was configured for this clone -- see `supertag-git-check' and the
Commentary in supertag-git.el) collides on the very same line/entity.
Checked BEFORE any attempt to `read' the buffer as Lisp, since a
conflict-marked file is not valid Lisp in either on-disk format and would
otherwise merely surface as an opaque `read' error indistinguishable from
any other corruption."
  (save-excursion
    (goto-char (point-min))
    (or (re-search-forward "^<<<<<<< " nil t)
        (progn (goto-char (point-min)) (re-search-forward "^=======$" nil t))
        (progn (goto-char (point-min)) (re-search-forward "^>>>>>>> " nil t)))))

(defun supertag--persistence--try-read-store (path)
  "Return store data read from PATH.

Detects which of the two on-disk formats PATH uses by looking at the
first non-comment, non-whitespace character: `(' means the S2 canonical,
line-per-entity format (see `supertag--persistence-canonical-format-header'
commentary); anything else (in practice always `#', from the legacy
`prin1' of the store hash table directly) falls back to the original
single-sexp read. This build reads either format with zero migration
step required: old on-disk databases keep loading exactly as before, and
the very next save always writes canonical format from then on.

Before attempting either read, refuses PATH outright (signaling
`supertag-persistence-conflict-markers-error', a distinguishable
condition rather than a bare `error') if it contains unresolved git merge
conflict markers -- see
`supertag--persistence--buffer-has-conflict-markers-p'. This is
deliberately checked ahead of parsing rather than left to surface as a
generic `read' failure, so the message can name the actual fix
(`supertag-git-setup' / `git checkout --merge') instead of an opaque
\"end of file during parsing\". Callers (`supertag-load-store') treat this
exactly like any other unreadable candidate -- pushed onto that
function's per-candidate failures list, never silently swallowed into an
apparently-successful empty read -- see that function's commentary for
why this specific failure mode cannot lead to a destructive save later.

Signals an error if the file cannot be read or parsed."
  (with-temp-buffer
    (insert-file-contents path)
    (when (supertag--persistence--buffer-has-conflict-markers-p)
      (signal 'supertag-persistence-conflict-markers-error
              (list (format "%s contains unresolved git merge conflict markers (<<<<<<< / ======= / >>>>>>>) and cannot be loaded as a database. This almost always means a merge ran without the semantic merge driver configured for THIS clone -- run `M-x supertag-git-setup' to configure it (see supertag-git.el), then resolve this file with `git checkout --merge %s' (re-triggering the driver) or by hand, before reloading."
                            (abbreviate-file-name path) path))))
    (supertag--persistence--skip-leading-comments-and-whitespace)
    (if (eq (char-after) ?\()
        (supertag--persistence--read-canonical-forms)
      (progn
        (goto-char (point-min))
        (let ((read-circle t))
          (read (current-buffer)))))))

(defun supertag--persistence--canonicalize-store-root (store)
  "Normalize STORE root keys to canonical keyword collections."
  (when (hash-table-p store)
    (dolist (spec '((:nodes nodes "nodes")
                    (:tags tags "tags")
                    (:relations relations "relations")
                    (:link-definitions link-definitions "link-definitions")
                    (:ontology-bindings ontology-bindings "ontology-bindings")
                    (:ontology-modules ontology-modules "ontology-modules")
                    (:ontology-migrations ontology-migrations "ontology-migrations")
                    (:ontology-functions ontology-functions "ontology-functions")
                    (:ontology-actions ontology-actions "ontology-actions")
                    (:ontology-policies ontology-policies "ontology-policies")
                    (:ontology-action-executions ontology-action-executions
                     "ontology-action-executions")
                    (:embeds embeds "embeds")
                    (:fields fields "fields")
                    (:field-definitions field-definitions "field-definitions")
                    (:tag-field-associations tag-field-associations "tag-field-associations")
                    (:field-values field-values "field-values")
                    (:field-provenance field-provenance "field-provenance")
                    (:boards boards "boards")
                    (:automations automations "automations")
                    (:sync-conflicts sync-conflicts "sync-conflicts")
                    (:meta meta "meta")))
      (let ((canonical (car spec))
            (aliases (cdr spec)))
        (when (and (not (ht-contains? store canonical)))
          (catch 'moved
            (dolist (alias aliases)
              (when (ht-contains? store alias)
                (puthash canonical (gethash alias store) store)
                (remhash alias store)
                (throw 'moved t))))))))
  ;; Retired :queries (MODEL_CN:302, PLAN_CN decision 14/4b): discard
  ;; this literal root on load so the next save omits it.  The writer
  ;; still serializes the in-memory Store; other undeclared roots stay.
  (when (hash-table-p store)
    (remhash :queries store))
  store)

(defun supertag--record-store-origin (status &optional context)
  "Record metadata about the current in-memory store origin."
  (setq supertag--store-origin
        (append
         (list :status status
               :db-file supertag-db-file
               :data-directory supertag-data-directory
               :sync-state-file (when (boundp 'supertag-sync-state-file)
                                  supertag-sync-state-file)
               :sync-state-source (when (boundp 'supertag-sync--state-source)
                                    supertag-sync--state-source)
               :sync-directories (when (boundp 'supertag-sync-directories)
                                   supertag-sync-directories)
               :active-sync-directory (when (boundp 'supertag-active-sync-directory)
                                        supertag-active-sync-directory)
               :nodes-count (supertag--count-nodes)
               :captured-at (supertag-current-time))
         context)))

(defun supertag--persistence-guard-violations (&optional file)
  "Return a list of reasons to refuse saving the store."
  (let* ((origin supertag--store-origin)
         (db-file (or file supertag-db-file))
         (state-file (supertag--persistence--expected-sync-state-file))
         (state-source (when (boundp 'supertag-sync--state-source)
                         supertag-sync--state-source))
         (origin-status (plist-get origin :status))
         (origin-db (plist-get origin :db-file))
         (origin-state (plist-get origin :sync-state-file))
         (reasons '()))
    (unless origin
      (push "store origin missing (store not loaded)" reasons))
    (let ((db-now (supertag--persistence--normalize-path db-file))
          (db-origin (supertag--persistence--normalize-path origin-db)))
      (when (and db-now db-origin (not (string= db-now db-origin)))
        (push "db-file mismatch (manual switch detected)" reasons)))
    (let ((state-now (supertag--persistence--normalize-path state-file))
          (state-origin (supertag--persistence--normalize-path origin-state)))
      (when (and state-now state-origin (not (string= state-now state-origin)))
        (push "sync-state file mismatch (manual switch detected)" reasons)))
    (let ((source-now (supertag--persistence--normalize-path state-file))
          (source-loaded (supertag--persistence--normalize-path state-source)))
      (cond
       ((and source-now (not source-loaded))
        (push "sync-state not loaded for current vault" reasons))
       ((and source-now source-loaded (not (string= source-now source-loaded)))
        (push "sync-state not loaded for current vault" reasons))))
    (when (memq origin-status '(:failed :empty-file :missing-with-backups))
      (push (format "last load status %s" origin-status) reasons))
    (when supertag-db-lock
      (let ((live-owner (supertag--db-lock-status db-file)))
        (cond
         ((stringp live-owner)
          (setq supertag--db-lock-conflict live-owner)
          (push (format "database locked by another Emacs instance (%s)" live-owner) reasons))
         (supertag--db-lock-conflict
          ;; We previously recorded a conflict, but `file-locked-p' no longer
          ;; reports another owner for this file — the other instance likely
          ;; exited. Retry taking over the lock for this session.
          (supertag--db-acquire-lock)
          (when supertag--db-lock-conflict
            (push (format "database locked by another Emacs instance (%s)" supertag--db-lock-conflict) reasons))))))
    (nreverse reasons)))

(defun supertag--persistence-refuse-save (reasons)
  "Refuse saving and explain the recovery flow for the current situation.
The guidance depends on why the store is untrusted: a missing database
with surviving backups needs restore-or-accept, a parse failure needs
doctor-driven recovery, and everything else is a vault switch problem."
  (let ((flow
         (pcase (plist-get supertag--store-origin :status)
           (:missing-with-backups
            "Your database file is missing but backup snapshots survive. Your notes are safe on disk. Evaluate (supertag-restore) to recover a snapshot, or (supertag-accept-fresh-store) to intentionally start over empty.")
           (:failed
            "The database file exists but could not be read; it has NOT been modified. Evaluate (supertag-doctor) for details, then (supertag-restore) to recover from a snapshot.")
           (_
            "Proper flow: use M-x supertag-vault-activate to switch vaults and reload state/store before saving."))))
    (user-error "Supertag refused to save: %s. %s"
                (mapconcat #'identity reasons "; ") flow)))

(defun supertag-persistence-ensure-data-directory ()
  "Ensure database and backup directories exist."
  (let ((db-dir (file-name-directory supertag-db-file)))
    ;; 1. Ensure database directory exists
    (unless (file-exists-p db-dir)
      (make-directory db-dir t))
    ;; 2. Ensure backup directory exists
    (unless (file-exists-p supertag-db-backup-directory)
      (make-directory supertag-db-backup-directory t))
    ;; 3. Verify directory creation
    (unless (and (file-exists-p db-dir)
                 (file-exists-p supertag-db-backup-directory))
      (error "Failed to create required directories: %s or %s"
             db-dir supertag-db-backup-directory))))

;;; --- Persistence Functions ---

(defun supertag--persistence--legacy-format-file-p (file)
  "Return non-nil if FILE exists and is NOT in S2 canonical format.
Uses the identical format sniffer `supertag--persistence--try-read-store'
uses to dispatch between readers -- the first non-comment, non-whitespace
character is `(' for canonical, anything else (in practice always `#', from
the legacy single-`prin1'-of-a-hash-table format) for legacy -- but never
actually `read's the content, only peeks at that one character, so a
truncated or otherwise corrupt FILE cannot make this signal an error.

Returns nil (never legacy) when FILE does not exist, is a directory, or
cannot be read for any reason -- this predicate must never itself block a
save; on doubt, it says \"not legacy\" and the P1-8 preformat6 snapshot below
is simply skipped, same as if FILE had already been canonical."
  (and (stringp file)
       (file-exists-p file)
       (not (file-directory-p file))
       (condition-case nil
           (with-temp-buffer
             (insert-file-contents file)
             (supertag--persistence--skip-leading-comments-and-whitespace)
             (not (eq (char-after) ?\()))
         (error nil))))

(defun supertag--persistence--snapshot-preformat6 (file)
  "Copy legacy-format FILE to a never-auto-deleted `preformat6' backup.
Part of P1-8
(archive/legacy-v2/2026-08-25-phrase/phases/phase-git-sync-20260713/PLAN.md
\"S2 规范化序列化\", 修订 2026-07-13): the FIRST time a canonical save is about to
overwrite an on-disk database still in the legacy (pre-6.0) format, this
preserves that legacy file as
`supertag-db-backup-directory'/supertag-db-preformat6-<TIMESTAMP>.el --
the downgrade escape hatch back to org-supertag < 6.0, which cannot read
entities out of the canonical format at all (see `supertag-data-version').

This is independent of, and a superset of, the pre-migration snapshot
`supertag--maybe-auto-migrate' takes: that one only fires when the STORED
`:version' differs from `supertag-data-version', which does not cover a
database already stamped at the current data version by an intervening
save whose on-disk FORMAT is nonetheless still legacy (the exact S2 gap
this task starts from -- format changed without a version bump). Runs
exactly once per legacy-to-canonical transition: after this save succeeds
the on-disk file is canonical, so the next call's
`supertag--persistence--legacy-format-file-p' check on FILE is false and no
further snapshot is taken -- no timestamp-collision bookkeeping needed.

The `preformat6' name deliberately does NOT match
`supertag-cleanup-old-backups''s daily-backup regex
\(\"^supertag-db-[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\.el$\"), for the same
reason `premigrate' snapshots don't: this file must never be automatically
deleted by daily-backup retention.

Never signals: any error is caught, reported via `message', and treated as
\"proceed with the save anyway\" -- a failed snapshot must not block a
legitimate save, though it does mean this particular downgrade escape
hatch was not created for this transition."
  (condition-case err
      (progn
        (supertag-persistence-ensure-data-directory)
        (let ((snapshot-file
               (expand-file-name
                (format "supertag-db-preformat6-%s.el" (format-time-string "%Y%m%d-%H%M%S"))
                supertag-db-backup-directory)))
          ;; Sub-second re-entrancy within the same save call is not a
          ;; realistic concern, but a cheap guard against clobbering an
          ;; existing same-second snapshot costs nothing.
          (when (file-exists-p snapshot-file)
            (setq snapshot-file
                  (make-temp-file
                   (expand-file-name "supertag-db-preformat6-" supertag-db-backup-directory)
                   nil ".el")))
          (copy-file file snapshot-file t)
          (message "Supertag: legacy-format database detected; saved a pre-6.0-format downgrade snapshot to %s (restore this file over %s to go back to org-supertag < 6.0)."
                   (abbreviate-file-name snapshot-file) (abbreviate-file-name file))
          snapshot-file))
    (error
     (message "Supertag: failed to create pre-format-6 downgrade snapshot before canonical save (%s); proceeding with the save anyway."
              (error-message-string err))
     nil)))

(defun supertag--persistence-write-store-atomically (file)
  "Write `supertag--store' to FILE atomically.

A temporary file is created in the same directory as FILE (so the
final `rename-file' is atomic on the same filesystem), the in-memory
store is serialized into it using the S2 canonical, deterministic,
line-per-entity format (see `supertag--persistence--write-canonical-store'
and the format commentary above
`supertag--persistence-canonical-format-header'), and — when
`supertag-db-verify-after-save' is non-nil — the temp file is re-read the
same way the loader does (`supertag--persistence--try-read-store', which
understands both the canonical and legacy formats). Every durable collection
declared by `supertag--store-collections' is then compared by entity ID and
canonicalized value before the temp file replaces FILE.

Immediately before the atomic rename -- i.e. only once the new canonical
content is fully written and verified, and FILE (still holding whatever
was there before) is about to be replaced -- if FILE currently exists and
is still in the legacy (pre-6.0) format,
`supertag--persistence--snapshot-preformat6'
preserves it as a downgrade escape hatch (P1-8). This is a one-time event
per database: once FILE itself becomes canonical, the check is false on
every subsequent save.

On any failure, including a verification mismatch or read error, the
temp file is removed, an error is signaled, and FILE is left
untouched."
  (let ((temp-file (make-temp-file (concat file ".tmp")))
        (success nil))
    (unwind-protect
        (progn
          (with-temp-buffer
            (set-buffer-file-coding-system 'utf-8-unix) ; Ensure UTF-8 encoding
            (supertag--persistence--write-canonical-store supertag--store (current-buffer))
            (let ((write-region-inhibit-fsync nil))
              (write-region (point-min) (point-max) temp-file nil 'silent)))
          (when supertag-db-verify-after-save
            (let (verify-data)
              (condition-case err
                  (setq verify-data
                        (supertag--persistence--try-read-store temp-file))
                (error
                 (error "Supertag save verification failed to read %s: %s"
                        temp-file (error-message-string err))))
              (unless (hash-table-p verify-data)
                (error "Supertag save verification returned an invalid Store root for %s"
                       file))
              (let ((mismatches
                     (supertag--persistence--mismatched-durable-collections
                      supertag--store verify-data)))
                (when mismatches
                  (error
                   (concat "Supertag save verification mismatch for %s: "
                           "durable collection(s) changed after write/read: %s")
                   file
                   (mapconcat (lambda (collection)
                                (format "%S" collection))
                              mismatches ", "))))))
          (when (file-exists-p file)
            (set-file-modes temp-file (file-modes file)))
          (when (supertag--persistence--legacy-format-file-p file)
            (supertag--persistence--snapshot-preformat6 file))
          (rename-file temp-file file t)
          (setq success t))
      (unless success
        (ignore-errors (delete-file temp-file))))))

(defun supertag-save-store (&optional file)
  "Save the current `supertag--store` to a file.
FILE is the optional file path. Defaults to `supertag-db-file`.

This is also the function `supertag-setup-auto-save' and
`supertag-schedule-save' hand to their timers, so it doubles as the
presence heartbeat: `supertag--presence-write' below runs unconditionally
on every call — including timer ticks where the store turns out not to be
dirty and nothing else in this function does any work — so a foreign
machine's `supertag--presence-foreign-active-p' check sees this host as
recently active for as long as this session keeps running."
  (supertag--presence-write)
  (let* ((file-to-save (or file supertag-db-file))
         (reasons (supertag--persistence-guard-violations file-to-save)))
    (cond
     (reasons
      (message "Supertag auto-save skipped: %s"
               (mapconcat #'identity reasons "; ")))
     (t
    (supertag-persistence-ensure-data-directory) ; Ensure directory exists before saving
    (when (supertag-dirty-p) ; Only save if dirty
      ;; Safety guard: avoid overwriting a non-trivial on-disk DB with an empty in-memory store
      (let* ((nodes-table (ignore-errors (supertag-store-get-collection :nodes)))
             (live-node-count (and (hash-table-p nodes-table)
                                   (hash-table-count nodes-table)))
             (existing-file-p (file-exists-p file-to-save))
             (existing-size (when existing-file-p (file-attribute-size (file-attributes file-to-save))))
             ;; Treat DB file larger than 1KB as "non-trivial" by default
             (non-trivial-file (and existing-size (> existing-size 1024))))
        (if (and non-trivial-file
                 (numberp live-node-count)
                 (= live-node-count 0))
            (message "Protective skip: Live DB has 0 nodes while on-disk DB looks non-trivial (%s bytes). Skipping save to avoid data loss."
                     existing-size)
          (supertag--persistence-write-store-atomically file-to-save)
          (supertag-clear-dirty)
          (supertag--record-store-origin :ok)
          ;; Re-claim presence after a successful save too, not just on the
          ;; unconditional heartbeat write above — keeps the recorded
          ;; `updatedAt' as fresh as possible right when real writes happen.
          (supertag--presence-write)
          ;; Check if daily backup is needed after successful save
          (supertag-check-daily-backup)
          ;; S4 git-sync-mode commit trigger seam — see
          ;; `supertag-persistence-after-save-hook''s docstring.
          (run-hook-wrapped
           'supertag-persistence-after-save-hook
           (lambda (subscriber)
             (condition-case err
                 (funcall subscriber)
               (error
                (message "Supertag after-save subscriber %S failed: %s"
                         subscriber (error-message-string err))))
             ;; Never let a subscriber's return value stop delivery.
             nil))
          t)))))))

(autoload 'supertag-migrate-run "supertag-migrate" "Run verified data migration." t)

(defun supertag--maybe-auto-migrate ()
  "Run the verified version chain when automatic migration is enabled."
  (when (and supertag-db-auto-migrate (hash-table-p supertag--store)
             (not (equal (supertag--get-data-version supertag--store) supertag-data-version)))
    (supertag-migrate-run)))

(defun supertag-load-store (&optional file preserve-lock)
  "Load data into supertag--store from a file.
This function loads and coerces the persisted store data.  When automatic
migration is enabled, the version-gated DB migration may run during loading;
otherwise use `supertag-migrate-run` after loading for an explicit migration.
FILE is the optional file path. Defaults to supertag-db-file.
When PRESERVE-LOCK is non-nil, load only FILE while retaining the advisory
lock already held for it; this is reserved for the restore critical section."
  (let* ((locked-file (or file supertag-db-file))
         (candidates (if preserve-lock
                         (list (supertag--persistence--normalize-path locked-file))
                       (supertag--persistence--db-file-candidates file)))
         (file-to-load nil)
         (load-status nil)
         (failures '()))
    (when (and preserve-lock
               supertag-db-lock
               (or (not (equal supertag--db-locked-file locked-file))
                   (not (eq t (supertag--db-lock-status locked-file)))))
      (user-error "Cannot preserve a database lock not held by this Emacs"))
    ;; Release any lock held for a previously loaded DB file (e.g. when
    ;; switching vaults) before possibly loading a different one below.
    (unless preserve-lock
      (supertag--db-release-lock))
    ;; Ensure directory exists before loading (best-effort; does not depend on DB presence).
    (ignore-errors (supertag-persistence-ensure-data-directory))

    ;; Do not rely on a pre-check alone: try reading candidates until one succeeds.
    (dolist (candidate candidates)
      (let ((expanded (and (stringp candidate)
                           (> (length candidate) 0)
                           (ignore-errors (expand-file-name candidate)))))
        (when (and expanded
                   (file-exists-p expanded)
                   (not (file-directory-p expanded)))
          (cond
           ((not (file-readable-p expanded))
            ;; An existing but unreadable database is a broken database,
            ;; not a fresh vault: record the failure so the load degrades
            ;; to :failed (which blocks saving) instead of :new.
            (push (cons expanded "file exists but is not readable") failures))
           ((null file-to-load)
            (condition-case err
                (let* ((loaded-data (supertag--persistence--try-read-store expanded))
                       (coerced (supertag--coerce-store-table loaded-data)))
                  (setq file-to-load expanded)
                  (setq supertag--store (supertag--persistence--canonicalize-store-root coerced))
                  (supertag--ensure-store)
                  (setq load-status :ok))
              (error
               (push (cons expanded (error-message-string err)) failures))))))))

    (if (and file-to-load (eq load-status :ok))
        (progn
          (supertag--persistence--set-db-file file-to-load)
          (supertag-clear-dirty)
          (supertag--record-store-origin :ok
                                         (list :loaded-from file-to-load
                                               :load-candidates candidates
                                               :load-failures (nreverse failures)))
          (message "Database loaded from %s." (abbreviate-file-name file-to-load))
          (unless preserve-lock
            (supertag--db-acquire-lock))
          (supertag--presence-check-and-claim)
          (supertag--maybe-auto-migrate)
          (supertag-index-rebuild-all)
          ;; See `supertag-persistence-after-load-hook''s docstring: this is
          ;; the one seam that fires exactly when a store was just
          ;; successfully loaded, without this file knowing (or requiring)
          ;; anything about who is listening.
          (run-hooks 'supertag-persistence-after-load-hook))
      (setq supertag--store (ht-create))
      (setq failures (nreverse failures))
      ;; `failures' is only ever non-nil here when at least one candidate
      ;; FILE EXISTED and failed to parse (the dolist above only attempts a
      ;; read, and thus only ever pushes onto `failures', when
      ;; `file-exists-p' held -- see the loop's `when' guard above) -- as
      ;; opposed to the genuinely-fresh-vault case where no candidate file
      ;; exists at all. That distinction matters: a parse failure (in
      ;; particular the git-conflict-markers case detected by
      ;; `supertag--persistence--try-read-store') must never be reported or
      ;; recorded the same way as an intentionally-new, empty vault, because
      ;; `supertag--persistence-guard-violations' -- consulted by every
      ;; subsequent `supertag-save-store' call, interactive or timer-driven
      ;; -- already refuses to save whenever the recorded origin `:status'
      ;; is `:failed' (that check has existed since this function's
      ;; :status-plist convention was introduced, but nothing previously
      ;; ever actually produced `:failed'). Recording `:failed' here means
      ;; that even after the user later creates brand-new nodes in this
      ;; now-"empty" in-memory store (which would otherwise defeat the
      ;; separate byte-size-based "Protective skip" guard in
      ;; `supertag-save-store', since that guard only fires when the live
      ;; node count is still exactly 0), any save is blocked at the
      ;; `supertag--persistence-guard-violations' check -- run BEFORE that
      ;; node-count guard is ever reached -- until the user goes through
      ;; the proper recovery flow this module's `supertag--persistence-refuse-save'
      ;; message already points at. The on-disk file (still containing the
      ;; real, conflict-marked or otherwise corrupt data) is therefore never
      ;; at risk of being silently overwritten by this fresh empty store.
      ;; No candidate file loaded. Distinguish three very different
      ;; situations before touching the origin record:
      ;;   :failed               -- a file existed but could not be parsed;
      ;;   :missing-with-backups -- no file exists, yet snapshots in the
      ;;                            backup directory prove a database used
      ;;                            to live here (deleted or lost file);
      ;;   :new                  -- a genuinely fresh vault.
      ;; The first two BLOCK saving (see
      ;; `supertag--persistence-guard-violations'): a deleted database must
      ;; never be silently replaced by this empty in-memory store, because
      ;; the next save would rotate real data out of the backups within
      ;; `supertag-db-backup-keep-days'.
      (let ((snapshots (and (null failures)
                            (supertag--restore-snapshot-list))))
        (setq load-status (cond (failures :failed)
                                (snapshots :missing-with-backups)
                                (t :new)))
        (supertag-clear-dirty)
        (supertag--record-store-origin
         load-status
         (list :loaded-from nil
               :load-candidates candidates
               :load-failures failures
               :backup-snapshots (length snapshots)))
        (cond
         (failures
          (message "Supertag: FAILED to load the database -- %d candidate(s) existed but could not be parsed (%s). Initialized an EMPTY in-memory store as a placeholder; saving is BLOCKED (see M-: (supertag-doctor) / M-x supertag-git-setup) until this is resolved and the store is reloaded -- your on-disk data has NOT been modified. candidates=%S"
                   (length failures)
                   (mapconcat (lambda (f) (format "%s: %s" (abbreviate-file-name (car f)) (cdr f)))
                              failures "; ")
                   (mapcar #'abbreviate-file-name candidates)))
         (snapshots
          (message "Supertag: database file is MISSING but %d backup snapshot(s) exist (newest: %s). Saving is BLOCKED so the backups stay safe. Evaluate (supertag-restore) to recover, or (supertag-accept-fresh-store) to intentionally start empty."
                   (length snapshots)
                   (format-time-string "%Y-%m-%d %H:%M"
                                       (plist-get (car snapshots) :mtime))))
         (t
          (message "Initialized empty Supertag store (no readable DB found; candidates=%S)."
                   (mapcar #'abbreviate-file-name candidates))))))
        (supertag-index-rebuild-all)))

(defun supertag-schedule-save ()
  "Schedule a delayed save.
Waits for 2 seconds of idle time before saving to avoid frequent saves."
  (when supertag-db--auto-save-timer
    (cancel-timer supertag-db--auto-save-timer))
  (setq supertag-db--auto-save-timer
        (run-with-idle-timer 2 nil #'supertag-save-store)))

(defun supertag-setup-auto-save ()
  "Set up auto-save timer."
  (when (and supertag-db-auto-save-interval
             (null supertag-db--auto-save-timer))
    (setq supertag-db--auto-save-timer
          (run-with-timer supertag-db-auto-save-interval
                         supertag-db-auto-save-interval
                         #'supertag-save-store))))

(defun supertag-setup-daily-backup ()
  "Set up daily backup timer."
  (when (and supertag-db-backup-interval
             (null supertag-db--backup-timer))
    (setq supertag-db--backup-timer
          (run-with-timer supertag-db-backup-interval
                         supertag-db-backup-interval
                         #'supertag-backup-database-now))))

(defun supertag-cleanup-auto-save ()
  "Clean up auto-save timer."
  (when supertag-db--auto-save-timer
    (cancel-timer supertag-db--auto-save-timer)
    (setq supertag-db--auto-save-timer nil)))

(defun supertag-cleanup-daily-backup ()
  "Clean up daily backup timer."
  (when supertag-db--backup-timer
    (cancel-timer supertag-db--backup-timer)
    (setq supertag-db--backup-timer nil)))

(defun supertag-setup-all-timers ()
  "Set up both auto-save and daily backup timers."
  (supertag-setup-auto-save)
  (supertag-setup-daily-backup))

(defun supertag-cleanup-all-timers ()
  "Clean up all persistence-related timers."
  (supertag-cleanup-auto-save)
  (supertag-cleanup-daily-backup))

;;; --- Event Subscription ---

(defun supertag-persistence--handle-store-changed (_path _old-value _new-value)
  "Handle store-changed events.
This function is called when the store is updated.
PATH, OLD-VALUE, and NEW-VALUE describe the change."
  (supertag-mark-dirty) ; Mark database as dirty
  (supertag-schedule-save)) ; Schedule a delayed save

;; Subscribe to store-changed events
(supertag-subscribe :store-changed #'supertag-persistence--handle-store-changed)

(defun supertag-db-inspect-file ()
  "Inspect the database file and report its structure.
Useful for diagnosing why nodes aren't loading properly."
  (let* ((candidates (supertag--persistence--db-file-candidates nil))
         (file-to-inspect (or (supertag--persistence--pick-readable-file candidates)
                              supertag-db-file)))
    (if (not (and file-to-inspect (file-exists-p file-to-inspect)))
        (message "Database file does not exist. Candidates: %S"
                 (mapcar #'abbreviate-file-name candidates))
      (with-temp-buffer
        (insert-file-contents file-to-inspect)
      (goto-char (point-min))
      (condition-case err
          (let* ((read-circle t)
                 (data (read (current-buffer)))
                 (is-hash (hash-table-p data))
                 (nodes-key (if is-hash (gethash :nodes data) nil))
                 (nodes-count (if (hash-table-p nodes-key)
                                  (hash-table-count nodes-key)
                                0))
                 (sample-nodes '())
                 (nodes-without-type 0)
                 (nodes-with-type 0))

            (with-output-to-temp-buffer "*Supertag DB Inspection*"
              (princ "=== Database File Inspection ===\n\n")
              (princ (format "File: %s\n" file-to-inspect))
              (princ (format "File size: %d bytes\n"
                             (file-attribute-size (file-attributes file-to-inspect))))
              (princ (format "Data is hash-table: %s\n" is-hash))
              (princ (format "Nodes collection exists: %s\n" (if nodes-key "YES" "NO")))
              (princ (format "Nodes collection is hash-table: %s\n" (hash-table-p nodes-key)))
              (princ (format "Node count in file: %d\n\n" nodes-count))

              (when (hash-table-p nodes-key)
                (princ "=== Node Analysis ===\n")
                (maphash (lambda (id node-data)
                           (if (plist-get node-data :type)
                               (cl-incf nodes-with-type)
                             (cl-incf nodes-without-type))
                           (when (< (length sample-nodes) 3)
                             (push (cons id node-data) sample-nodes)))
                         nodes-key)

                (princ (format "Nodes with :type property: %d\n" nodes-with-type))
                (princ (format "Nodes WITHOUT :type property: %d\n\n" nodes-without-type))

                (when sample-nodes
                  (princ "=== Sample Nodes ===\n")
                  (dolist (sample (reverse sample-nodes))
                    (let ((id (car sample))
                          (data (cdr sample)))
                      (princ (format "\nNode ID: %s\n" id))
                      (princ (format "Has :type: %s\n" (if (plist-get data :type) "YES" "NO")))
                      (princ (format "Has :title: %s\n" (if (plist-get data :title) "YES" "NO")))
                      (princ (format "Has :file: %s\n" (if (plist-get data :file) "YES" "NO")))
                      (princ (format "Properties: %S\n" (let ((props '()))
                                                           (cl-loop for (k _v) on data by #'cddr
                                                                    do (push k props))
                                                           (nreverse props)))))))

                (when (> nodes-without-type 0)
                  (princ "\n=== WARNING ===\n")
                  (princ (format "%d nodes are missing the :type property!\n" nodes-without-type))
                  (princ "These nodes will be automatically purged during load.\n")
                  (princ "This may be why your database appears empty after loading.\n\n")
                  (princ "Possible causes:\n")
                  (princ "1. Data was created with an older version\n")
                  (princ "2. Manual editing of the database file\n")
                  (princ "3. Incomplete migration\n\n")
                  (princ "Solution: Run M-x supertag-sync-full-rescan to rebuild Org projections; restore Semantic Facts from backup.\n")))))
        (error
         (message "Error reading database file: %s" (error-message-string err))))))))

;;; --- Time comparison ---

(defun supertag-time-equal (time1 time2)
  "Safe time comparison function.
TIME1 and TIME2 should be in Emacs time format.
Returns t if times are equal, otherwise returns nil."
  (and (supertag--validate-time time1)
       (supertag--validate-time time2)
       (equal time1 time2)))

;;; --- Data Version Management ---

(defun supertag--get-data-version (data)
  "Extract version information from the data store.
DATA should be the main data storage hash table.
Returns the version string, or a default old version if not found."
  (if (hash-table-p data)
      (or (gethash :version data) "4.0.0")  ; Default old version
    "4.0.0"))

(defun supertag--set-data-version (data version)
  "Set version information in the data store.
DATA should be the main data storage hash table.
VERSION is the version string to set."
  (when (hash-table-p data)
    (puthash :version version data)))

(defun supertag--retire-node-tag-projection (data)
  "Remove every legacy `:node-tag' relation projection from DATA.
Return the number removed.  Node `:tags' values are left unchanged."
  (let ((relations (and (hash-table-p data) (gethash :relations data)))
        relation-ids)
    (when (hash-table-p relations)
      (maphash
       (lambda (relation-id relation)
         (when (eq (plist-get relation :type) :node-tag)
           (push relation-id relation-ids)))
       relations)
      (dolist (relation-id relation-ids)
        (remhash relation-id relations)))
    (message "Retired %d legacy node-tag projection relation(s)."
             (length relation-ids))
    (length relation-ids)))

(defun supertag--migrate-4x-to-5x (data)
  "Migrate from version 4.x to 5.0.0.
Main changes include data format standardization and field name normalization."
  ;; Specific migration steps can be added here
  ;; For example, field renaming, data format conversion, etc.

  ;; Example: Ensure all time fields use standard format
  (let ((nodes-table (gethash :nodes data)))
    (when (hash-table-p nodes-table)
      (maphash (lambda (node-id node-data)
                 (when (plist-get node-data :type)
                   ;; Ensure time fields exist and are correctly formatted
                   (unless (plist-get node-data :created-at)
                     (setq node-data (plist-put node-data :created-at (supertag-current-time))))
                   (unless (plist-get node-data :modified-at)
                     (setq node-data (plist-put node-data :modified-at (supertag-current-time))))

                   ;; Update node data
                   (puthash node-id node-data nodes-table)))
               nodes-table))))

;;; --- Data Backup and Transaction Safety Mechanisms ---

(defun supertag-backup-store ()
  "Create a deep backup of the data store.
Returns a complete copy of the current supertag--store."
  (when (hash-table-p supertag--store)
    (let ((backup (make-hash-table :test (hash-table-test supertag--store)
                                   :size (hash-table-size supertag--store))))
      (maphash (lambda (key value)
                 (puthash key
                         (if (hash-table-p value)
                             ;; Deep copy nested hash tables
                             (let ((nested-copy (make-hash-table :test (hash-table-test value)
                                                               :size (hash-table-size value))))
                               (maphash (lambda (k v) (puthash k v nested-copy)) value)
                               nested-copy)
                           ;; For other types, copy directly (plists, etc.)
                           (copy-sequence value))
                         backup))
               supertag--store)
      backup)))

(defun supertag-restore-store (backup-data)
  "Restore data store from backup.
BACKUP-DATA should be a backup created by `supertag-backup-store'."
  (when (and backup-data (hash-table-p backup-data))
    (setq supertag--store backup-data)
    (supertag-clear-dirty)
    (message "Data store restored from backup")))

;; `supertag--with-transaction' used to be a *real* transaction (unlike the
;; formerly-fake `supertag-with-transaction' in supertag-core-transform.el)
;; but paid for correctness with a full-store deep copy on every use — too
;; heavy for routine mutations. Now that `supertag-with-transaction' does
;; real per-entity rollback (see `supertag--transaction-record-old-value')
;; at a fraction of the cost, this macro is a thin obsolete alias so existing
;; callers (e.g. `supertag-migrate-tag-ids') keep working unchanged.
;; `supertag-backup-store'/`supertag-restore-store' are kept as standalone
;; utilities (doctor/migration full-snapshot use), just no longer wired into
;; the routine transaction path.
(define-obsolete-function-alias 'supertag--with-transaction
  'supertag-with-transaction
  "org-supertag 5.10 (S1 transaction hardening)")

(defun supertag--validate-tag-references ()
  "Validate tag reference consistency.
Check that all tags referenced by nodes exist in the tag collection.
Returns t if all references are valid, otherwise returns nil."
  (let ((tags-table (supertag-store-get-collection :tags))
        (nodes-table (supertag-store-get-collection :nodes))
        (valid-p t)
        (error-count 0))

    (when (and (hash-table-p tags-table) (hash-table-p nodes-table))
      (maphash (lambda (node-id node-data)
                 (when (eq (plist-get node-data :type) :node)
                   (let ((node-tags (plist-get node-data :tags)))
                     (when node-tags
                       (dolist (tag-id node-tags)
                         (unless (gethash tag-id tags-table)
                           (setq valid-p nil)
                           (cl-incf error-count)
                           (message "Invalid tag reference: node %s references non-existent tag %s"
                                   node-id tag-id)))))))
               nodes-table))

    (if valid-p
        (message "Tag reference validation passed")
      (message "Tag reference validation failed with %d errors" error-count))

    valid-p))

;;; --- Interactive Snapshot Restore ---
;;
;; `supertag-restore' turns the backup story that already exists (daily
;; backups from `supertag-create-daily-backup', the never-cleaned migration
;; snapshots, and the unique `supertag-db-prerestore-*' recovery points)
;; into something a user can act on without quitting Emacs and copying files
;; by hand. All four kinds live in `supertag-db-backup-directory', so
;; enumeration is a single directory scan.

(defun supertag--restore-snapshot-kind (filename)
  "Classify snapshot FILENAME (a nondirectory name) as a restore source.
Returns `prerestore', `premigrate', `preformat6', `daily', or nil when
FILENAME does not match a supported snapshot naming convention."
  (cond
   ((string-prefix-p "supertag-db-prerestore-" filename) 'prerestore)
   ((string-prefix-p "supertag-db-premigrate-" filename) 'premigrate)
   ((string-prefix-p "supertag-db-preformat6-" filename) 'preformat6)
   ((string-match-p "\\`supertag-db-[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\.el\\'" filename) 'daily)))

(defun supertag--restore-snapshot-kind-label (kind)
  "Human-readable label for restore snapshot KIND."
  (pcase kind
    ('daily "daily")
    ('prerestore "pre-restore")
    ('premigrate "pre-migration")
    ('preformat6 "pre-format6")
    (_ (symbol-name kind))))

(defun supertag--restore-snapshot-list (&optional dir)
  "Return every restorable snapshot under DIR, newest first.
DIR defaults to `supertag-db-backup-directory'. Each entry is a plist
\(:file FILE :kind KIND :mtime MTIME :size SIZE)."
  (let ((dir (or dir supertag-db-backup-directory)))
    (when (file-directory-p dir)
      (let ((entries
             (delq nil
                   (mapcar
                    (lambda (file)
                      (let ((kind (supertag--restore-snapshot-kind (file-name-nondirectory file)))
                            (attrs (file-attributes file)))
                        (when kind
                          (list :file file :kind kind
                                :mtime (nth 5 attrs) :size (nth 7 attrs)))))
                    (directory-files dir t "\\`supertag-db-.*\\.el\\'")))))
        (sort entries (lambda (a b)
                        (time-less-p (plist-get b :mtime) (plist-get a :mtime))))))))

(defun supertag--restore-snapshot-summary (file)
  "Return a plist (:nodes N :tags N :version V) describing snapshot FILE.
Reads FILE the same way `supertag-load-store' reads a candidate
\(`supertag--persistence--try-read-store', so both the canonical and legacy
on-disk formats are understood) without touching the live in-memory store."
  (let* ((data (supertag--persistence--try-read-store file))
         (store (supertag--persistence--canonicalize-store-root
                 (supertag--coerce-store-table data))))
    (list :nodes (let ((tbl (gethash :nodes store)))
                   (if (hash-table-p tbl) (hash-table-count tbl) 0))
          :tags (let ((tbl (gethash :tags store)))
                  (if (hash-table-p tbl) (hash-table-count tbl) 0))
          :version (supertag--get-data-version store))))

(defun supertag--restore-snapshot-describe (snapshot)
  "Return a `completing-read' label for SNAPSHOT (a plist from
`supertag--restore-snapshot-list').
Reads SNAPSHOT's file to report its node count; a snapshot that fails to
parse is still listed, with its node count shown as \"?\" rather than
dropped from the picker, since a stale/corrupt entry is still a legitimate
restore target for the doctor-style recovery this command exists for."
  (let* ((file (plist-get snapshot :file))
         (kind (plist-get snapshot :kind))
         (nodes (condition-case nil
                    (plist-get (supertag--restore-snapshot-summary file) :nodes)
                  (error "?"))))
    (format "%s  [%-13s]  %8s  %5s nodes  %s"
            (format-time-string "%Y-%m-%d %H:%M:%S" (plist-get snapshot :mtime))
            (supertag--restore-snapshot-kind-label kind)
            (file-size-human-readable (plist-get snapshot :size))
            nodes
            (file-name-nondirectory file))))

(defun supertag--restore-create-recovery-snapshot ()
  "Save the current state to a unique pre-restore snapshot.
Unsaved in-memory changes are serialized; otherwise the live database file
is copied byte-for-byte. Returns the snapshot path, or signals before the
live database is touched."
  (supertag-persistence-ensure-data-directory)
  (let* ((prefix (expand-file-name
                  (format "supertag-db-prerestore-%s-"
                          (format-time-string "%Y%m%d-%H%M%S"))
                  supertag-db-backup-directory))
         (snapshot (make-temp-file prefix nil ".el"))
         (success nil))
    ;; Reserve a collision-free name without making the atomic writer treat
    ;; the newly-created empty file as a legacy database.
    (delete-file snapshot)
    (unwind-protect
        (progn
          (if (or (supertag-dirty-p)
                  (not (file-exists-p supertag-db-file)))
              (supertag--persistence-write-store-atomically snapshot)
            (copy-file supertag-db-file snapshot nil t))
          (setq success t)
          snapshot)
      (unless success
        (ignore-errors (delete-file snapshot))))))

(defun supertag-restore ()
  "Restore the Supertag database from a snapshot.
Offers every daily, pre-restore, pre-migration, and pre-format6 snapshot in
`supertag-db-backup-directory' (see `supertag--restore-snapshot-list'), newest
first, via `completing-read'. Shows a preview comparing the chosen snapshot
against the live store, asks for explicit confirmation naming the snapshot,
then takes the database lock and creates a unique
`supertag-db-prerestore-*' recovery point before replacing
`supertag-db-file'. Daily snapshots reload normally. Pre-migration and
pre-format6 snapshots reload with auto-migration disabled so they remain
readable by pre-6.0 builds; quit Emacs immediately after restoring one for
downgrade."
  (let ((snapshots (supertag--restore-snapshot-list)))
    (unless snapshots
      (user-error "No snapshots found in %s"
                  (abbreviate-file-name supertag-db-backup-directory)))
    (let* ((labels (mapcar #'supertag--restore-snapshot-describe snapshots))
           (choice (completing-read "Restore Supertag database from snapshot: "
                                    labels nil t))
           (snapshot (nth (cl-position choice labels :test #'string=) snapshots))
           (file (plist-get snapshot :file))
           (summary (supertag--restore-snapshot-summary file))
           (current-nodes (supertag--count-nodes))
           (current-tags (hash-table-count (supertag-store-get-collection :tags))))
      (with-output-to-temp-buffer "*Supertag Restore Preview*"
        (princ (format "Snapshot to restore: %s\n\n" file))
        (princ (format "  format version : %s\n" (plist-get summary :version)))
        (princ (format "  nodes          : %d\n" (plist-get summary :nodes)))
        (princ (format "  tags           : %d\n\n" (plist-get summary :tags)))
        (princ (format "Current live store:\n\n"))
        (princ (format "  format version : %s\n" supertag-data-version))
        (princ (format "  nodes          : %d\n" current-nodes))
        (princ (format "  tags           : %d\n" current-tags)))
      (if (not (yes-or-no-p
                (format "Restore %s -- this REPLACES the current database (%d nodes) with the snapshot's %d nodes? "
                        (file-name-nondirectory file) current-nodes (plist-get summary :nodes))))
          (message "Restore cancelled.")
        (supertag-persistence-ensure-data-directory)
        (supertag--db-acquire-lock)
        (when (and supertag-db-lock
                   (or supertag--db-lock-conflict
                       (not (eq t (supertag--db-lock-status supertag-db-file)))
                       (not (equal supertag--db-locked-file supertag-db-file))))
          (user-error "Cannot restore while the database lock is unavailable%s"
                      (if supertag--db-lock-conflict
                          (format " (%s)" supertag--db-lock-conflict)
                        "")))
        (let* ((kind (plist-get snapshot :kind))
               (downgrade-p (memq kind '(premigrate preformat6)))
               (recovery-file (supertag--restore-create-recovery-snapshot)))
          (copy-file file supertag-db-file t)
          (let ((supertag-db-auto-migrate
                 (and supertag-db-auto-migrate (not downgrade-p))))
            (supertag-load-store supertag-db-file t))
          (message "Restored Supertag database from %s (%d nodes). Recovery point: %s.%s"
                   (file-name-nondirectory file)
                   (supertag--count-nodes)
                   (abbreviate-file-name recovery-file)
                   (if downgrade-p
                       " Quit Emacs now and reopen with the older build"
                     "")))))))

(defun supertag-accept-fresh-store ()
  "Explicitly start over with an empty store despite surviving backups.

When the database file is missing but backup snapshots exist,
`supertag-load-store' blocks saving so a deleted database cannot be
silently replaced by an empty one.  This function lifts that block after
showing what would be left behind and asking for confirmation.  It never
touches the backup snapshots themselves.

A store whose on-disk file exists but failed to parse (`:failed') cannot
be accepted this way: the unreadable file would be overwritten on the
next save.  Recover it with `supertag-restore', or move the file away
manually first."
  (let ((status (plist-get supertag--store-origin :status)))
    (unless (eq status :missing-with-backups)
      (user-error
       (if (eq status :failed)
           "The database file still exists but could not be read; accepting an empty store would overwrite it. Evaluate (supertag-restore), or move the file away manually first"
         "Saving is not blocked by a missing-database guard (store status: %s)")
       status))
    ;; The database may have reappeared since the blocked load -- a file
    ;; sync or git checkout can restore it at any time.  Accepting a
    ;; fresh store then would overwrite it on the next save.
    (let ((reappeared
           (cl-find-if (lambda (candidate)
                         (and (stringp candidate)
                              (file-exists-p candidate)
                              (not (file-directory-p candidate))))
                       (supertag--persistence--db-file-candidates))))
      (when reappeared
        (user-error "A database file has appeared at %s since the blocked load. Restart Emacs to load it instead"
                    (abbreviate-file-name reappeared))))
    (let* ((snapshots (supertag--restore-snapshot-list))
           (newest (car snapshots))
           (summary (and newest
                         (condition-case nil
                             (supertag--restore-snapshot-summary
                              (plist-get newest :file))
                           (error nil)))))
      (if (not (yes-or-no-p
                (format "Start over with an EMPTY store? %d backup snapshot(s) survive for now%s, but routine rotation deletes daily snapshots after %d day(s) -- copy them elsewhere for a permanent archive. Proceed? "
                        (length snapshots)
                        (if summary
                            (format " (newest holds %s nodes, from %s)"
                                    (plist-get summary :nodes)
                                    (format-time-string
                                     "%Y-%m-%d %H:%M"
                                     (plist-get newest :mtime)))
                          "")
                        supertag-db-backup-keep-days)))
          (message "Kept the recovery guard; evaluate (supertag-restore) to recover instead.")
        (supertag--record-store-origin :new '(:accepted-fresh t))
        (message "Fresh empty store accepted; saving is unblocked. Snapshots remain in %s until routine rotation; copy them elsewhere to keep them permanently."
                 (abbreviate-file-name supertag-db-backup-directory))))))

(provide 'supertag-core-persistence)

;;; supertag-core-persistence.el ends here
