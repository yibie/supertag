;;; supertag-doctor.el --- Health check and repair for Supertag -*- lexical-binding: t; -*-

;; Keywords: convenience

;;; Commentary:

;; `supertag-doctor' is a health-check function for the
;; Supertag persistence layer.  It inspects the on-disk database
;; file(s), in-memory store guards, revision/presence state, data version, and
;; referential integrity, then renders a report to the
;; "*Supertag Doctor*" buffer.
;;
;; Unless called with non-nil REPORT-ONLY (or running in batch mode via
;; `noninteractive'), it will additionally offer to run a series of
;; known-safe repair commands, prompting with `y-or-n-p' before each
;; one, and appending what was run to the report buffer.
;;
;; Every check is written to degrade gracefully: if a given helper
;; function or variable is not available (e.g. because a module has
;; not been loaded, or was renamed upstream), the corresponding line
;; reports "n/a (helper not available)" instead of erroring, so the
;; command is always safe to run.


;; Commands: none; Lisp entrypoint: supertag-doctor (&optional report-only).
;; Dependencies: supertag-git, cl-lib, supertag-core-persistence, supertag-core-store. Guarded
;; repair capability: supertag-sync-cleanup-database from supertag-services-sync.
;;; Code:

(require 'supertag-git)
(require 'cl-lib)
(require 'supertag-core-persistence)
(require 'supertag-core-store)

;; Sync-layer repair helper. Not hard-required so this file keeps a
;; minimal dependency footprint; guarded with `fboundp' at call time.
(declare-function supertag-sync-cleanup-database "supertag-services-sync")

;; Git diagnostics are required above, so a cold doctor invocation can
;; inspect conflicts left by an earlier session.
(declare-function supertag-git-check "supertag-git")
(declare-function supertag-git-sync--live-conflicted-org-files "supertag-git")

(defgroup supertag-doctor nil
  "Health check and repair tools for Supertag."
  :group 'supertag)

(defconst supertag-doctor--buffer-name "*Supertag Doctor*"
  "Name of the buffer used to render the doctor report.")

;;; --- Small helpers ---

(defun supertag-doctor--insert-header (title)
  "Insert a section header for TITLE into the current buffer."
  (insert "\n" title "\n")
  (insert (make-string (string-width title) ?=) "\n"))

(defun supertag-doctor--na ()
  "Standard text used when a helper/variable is not available."
  "n/a (helper not available)")

(defun supertag-doctor--format-time (time)
  "Format TIME (an Emacs time value) as a human readable string."
  (if time
      (condition-case nil
          (format-time-string "%Y-%m-%d %H:%M:%S" time)
        (error "n/a (unparseable time)"))
    "n/a"))

(defun supertag-doctor--file-size (file)
  "Return size in bytes of FILE, or nil if it does not exist."
  (when (and (stringp file) (file-exists-p file) (not (file-directory-p file)))
    (file-attribute-size (file-attributes file))))

;;; --- Report sections ---

(defun supertag-doctor--section-database-files ()
  "Insert the \"Database Files\" section into the current buffer."
  (supertag-doctor--insert-header "1. Database Files")
  (if (not (fboundp 'supertag--persistence--db-file-candidates))
      (insert (supertag-doctor--na) "\n")
    (let ((candidates (supertag--persistence--db-file-candidates)))
      (insert (format "Candidate DB files (%d):\n" (length candidates)))
      (dolist (c candidates)
        (let ((size (supertag-doctor--file-size c)))
          (insert (format "  - %s%s\n" c
                          (if size (format " (%d bytes)" size) " (missing)")))))))
  (insert "\n")
  (let* ((active (and (boundp 'supertag-db-file) supertag-db-file))
         (active-size (and active (supertag-doctor--file-size active)))
         (in-memory-count (and (fboundp 'supertag--count-nodes)
                                (supertag--count-nodes))))
    (insert (format "Active supertag-db-file: %s\n" (or active (supertag-doctor--na))))
    (insert (format "  Size: %s\n"
                    (cond ((null active) (supertag-doctor--na))
                          (active-size (format "%d bytes" active-size))
                          (t "n/a (file missing)"))))
    (if (and active (fboundp 'supertag--persistence--try-read-store)
             (file-exists-p active) (not (file-directory-p active)))
        (condition-case err
            (let* ((data (supertag--persistence--try-read-store active))
                   (nodes-key (and (hash-table-p data) (gethash :nodes data)))
                   (on-disk-count (if (hash-table-p nodes-key) (hash-table-count nodes-key) 0)))
              (insert "  Parse check: OK (readable Lisp data)\n")
              (insert (format "  On-disk node count: %d\n" on-disk-count)))
          (error
           (insert (format "  Parse check: FAILED (%s)\n" (error-message-string err)))
           (insert (format "  On-disk node count: %s\n" (supertag-doctor--na)))))
      (insert (format "  Parse check: %s\n"
                      (if (fboundp 'supertag--persistence--try-read-store)
                          "n/a (no readable file)"
                        (supertag-doctor--na))))
      (insert (format "  On-disk node count: %s\n" (supertag-doctor--na))))
    (insert (format "  In-memory node count: %s\n"
                    (if in-memory-count in-memory-count (supertag-doctor--na))))))

(defun supertag-doctor--section-guards ()
  "Insert the \"Guards\" section into the current buffer."
  (supertag-doctor--insert-header "2. Guards")
  (insert (format "Guard violations: %s\n"
                  (if (fboundp 'supertag--persistence-guard-violations)
                      (let ((reasons (supertag--persistence-guard-violations)))
                        (if reasons (mapconcat #'identity reasons "; ") "none"))
                    (supertag-doctor--na))))
  (insert (format "Store origin: %s\n"
                  (if (boundp 'supertag--store-origin)
                      (format "%S" supertag--store-origin)
                    (supertag-doctor--na))))
  (insert (format "Dirty flag: %s\n"
                  (cond ((fboundp 'supertag-dirty-p) (if (supertag-dirty-p) "dirty" "clean"))
                        ((boundp 'supertag-db--dirty) (if supertag-db--dirty "dirty" "clean"))
                        (t (supertag-doctor--na))))))

(defun supertag-doctor--section-recovery ()
  "Insert the \"Recovery\" section when the store or data roots need help.
Silent when the last load succeeded normally and the default roots are clear."
  (let ((status (and (boundp 'supertag--store-origin)
                     (plist-get supertag--store-origin :status)))
        (directory-issue
         (and (fboundp 'supertag-persistence-data-directory-recovery-needed-p)
              (supertag-persistence-data-directory-recovery-needed-p))))
    (when (or directory-issue
              (memq status '(:failed :missing-with-backups)))
      (supertag-doctor--insert-header "2b. Recovery needed")
      (when directory-issue
        (insert "Data directory recovery is required: a retired default root is still present.\n\n")
        (insert (supertag-persistence-format-data-directory-comparison) "\n\n")
        (insert "All directories and database files remain safe and unchanged.\n")
        (insert "  - (supertag-resolve-data-directories) choose the active root and safely retire the other\n")
        (when (memq status '(:failed :missing-with-backups))
          (insert "\n")))
      (when (memq status '(:failed :missing-with-backups))
        (pcase status
          (:missing-with-backups
           (insert "The database file is MISSING, but backup snapshots survive.\n")
           (insert "Your notes are safe; saving is blocked so the backups stay intact.\n")
           (insert "  - (supertag-restore)              recover from a snapshot\n")
           (insert "  - (supertag-accept-fresh-store)   intentionally start over empty\n"))
          (:failed
           (insert "The database file exists but could NOT be read.\n")
           (insert "It has not been modified; saving is blocked to protect it.\n")
           (insert "  - (supertag-restore)              recover from a snapshot\n")
           (insert "  - M-x supertag-sync-full-rescan   rebuild projections from Org files after restoring\n")))
        (let ((snapshots (when (fboundp 'supertag--restore-snapshot-list)
                           (supertag--restore-snapshot-list))))
          (insert (format "Snapshots available: %s\n"
                          (if snapshots
                              (format "%d (newest: %s)"
                                      (length snapshots)
                                      (format-time-string
                                       "%Y-%m-%d %H:%M"
                                       (plist-get (car snapshots) :mtime)))
                            "none found"))))))))

(defun supertag-doctor--section-revision-presence ()
  "Insert the revision-follow and presence summary into the current buffer."
  (supertag-doctor--insert-header "3. Revision & Presence")
  (let* ((own (if (boundp 'supertag--store-revision)
                  supertag--store-revision
                (supertag-doctor--na)))
         (disk-info (when (fboundp 'supertag--disk-revision-info)
                      (ignore-errors (supertag--disk-revision-info))))
         (disk (if disk-info (car disk-info) (supertag-doctor--na)))
         (writer (and disk-info (cadr disk-info)))
         (dirty (cond ((fboundp 'supertag-dirty-p)
                       (if (supertag-dirty-p) "dirty" "clean"))
                      (t (supertag-doctor--na)))))
    (insert (format "In-memory revision: %s\n" own))
    (insert (format "On-disk revision: %s%s\n" disk
                    (if writer (format " (writer %s)" writer) "")))
    (insert (format "Dirty: %s\n" dirty))
    (insert (format "Follow interval: %s\n"
                    (if (boundp 'supertag-db-follow-interval)
                        (or supertag-db-follow-interval "disabled")
                      (supertag-doctor--na))))
    (insert (format "Follow timer: %s\n"
                    (if (boundp 'supertag-db--follow-timer)
                        (if (timerp supertag-db--follow-timer) "active" "inactive")
                      (supertag-doctor--na))))
    (insert (format "Presence: %s\n"
                    (cond
                     ((not (boundp 'supertag-presence-enable))
                      (supertag-doctor--na))
                     ((not supertag-presence-enable) "disabled")
                     ((and (fboundp 'supertag--presence-foreign-active-p)
                           (supertag--presence-foreign-active-p))
                      (format "foreign host active (%s)"
                              (supertag--presence-foreign-active-p)))
                     (t "enabled"))))))

(defun supertag-doctor--section-version ()
  "Insert the \"Version\" section into the current buffer."
  (supertag-doctor--insert-header "4. Version")
  (let* ((target (and (boundp 'supertag-data-version) supertag-data-version))
         (store-loaded (and (boundp 'supertag--store) (hash-table-p supertag--store)))
         (current (cond
                   ((and (fboundp 'supertag--get-data-version) store-loaded)
                    (or (supertag--get-data-version supertag--store)
                        "unknown (no :version stamp)"))
                   ((not store-loaded) "n/a (store not loaded)")
                   (t (supertag-doctor--na)))))
    (insert (format "Target version (supertag-data-version): %s\n" (or target (supertag-doctor--na))))
    (insert (format "Store version: %s\n" current))
    (when (and target store-loaded (stringp current))
      (insert (format "Match: %s\n" (if (string= target current) "yes" "NO - mismatch")))))
  ;; P1-8 (archive/legacy-v2/2026-08-25-phrase/phases/phase-git-sync-20260713/PLAN.md "S2 Canonical Serialization",
  ;; revised 2026-07-13): the on-disk FILE FORMAT (legacy single-`prin1' vs. S2
  ;; canonical line-per-entity) is a separate axis from the data VERSION
  ;; above -- a database can be stamped at the current `supertag-data-version'
  ;; and still be sitting on disk in the legacy format if it has not been
  ;; saved since upgrading. Surfaced here because a pre-6.0 (<= 5.9.x) build
  ;; cannot read entities out of the canonical format at all (see
  ;; `supertag-data-version''s docstring) -- this line is the first place a
  ;; user checking `supertag-doctor' before downgrading would see that.
  (let ((active (and (boundp 'supertag-db-file) supertag-db-file)))
    (insert (format "On-disk format: %s\n"
                    (cond
                     ((not (fboundp 'supertag--persistence--legacy-format-file-p))
                      (supertag-doctor--na))
                     ((not (and active (file-exists-p active) (not (file-directory-p active))))
                      "n/a (no on-disk file)")
                     ((supertag--persistence--legacy-format-file-p active)
                      "legacy (single prin1 of a hash table -- pre-6.0)")
                     (t "canonical (S2 line-per-entity, >= 6.0)"))))))

(defun supertag-doctor--section-integrity ()
  "Insert the \"Integrity\" section into the current buffer."
  (supertag-doctor--insert-header "5. Integrity")
  (insert (format "Tag reference validation: %s\n"
                  (if (fboundp 'supertag--validate-tag-references)
                      (if (supertag--validate-tag-references) "PASSED" "FAILED (see *Messages*)")
                    (supertag-doctor--na))))
  (if (not (fboundp 'supertag-store-get-collection))
      (insert (format "Nodes missing :type: %s\n" (supertag-doctor--na)))
    (let ((nodes-table (supertag-store-get-collection :nodes))
          (missing 0)
          (total 0))
      (if (not (hash-table-p nodes-table))
          (insert "Nodes missing :type: n/a (nodes collection unavailable)\n")
        (maphash (lambda (_id data)
                   (cl-incf total)
                   (unless (and data (plist-get data :type))
                     (cl-incf missing)))
                 nodes-table)
        (insert (format "Nodes missing :type: %d of %d\n" missing total))))))

(defun supertag-doctor--section-backups ()
  "Insert the \"Backups\" section into the current buffer."
  (supertag-doctor--insert-header "6. Backups")
  (let ((dir (and (boundp 'supertag-db-backup-directory) supertag-db-backup-directory)))
    (insert (format "Backup directory: %s\n" (or dir (supertag-doctor--na))))
    (if (not (and dir (file-directory-p dir)))
        (insert "  (directory does not exist)\n")
      (let* ((files (directory-files dir t "^supertag-db-[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\.el$"))
             (dated (delq nil
                          (mapcar (lambda (f)
                                    (let ((attrs (ignore-errors (file-attributes f))))
                                      (when attrs (cons f (nth 5 attrs)))))
                                  files)))
             (sorted (sort dated (lambda (a b) (time-less-p (cdr b) (cdr a)))))
             (newest (car sorted)))
        (insert (format "  Backup count: %d\n" (length dated)))
        (if newest
            (insert (format "  Newest backup: %s (%s)\n"
                            (car newest)
                            (supertag-doctor--format-time (cdr newest))))
          (insert "  Newest backup: none found\n"))))
    (insert (format "Retention (supertag-db-backup-keep-days): %s\n"
                    (if (boundp 'supertag-db-backup-keep-days)
                        (format "%s days" supertag-db-backup-keep-days)
                      (supertag-doctor--na))))
    ;; Downgrade escape-hatch snapshots -- both kinds are deliberately never
    ;; touched by the daily-backup retention above (different filename
    ;; pattern), so they are worth surfacing separately: `premigrate' is
    ;; written by `supertag--maybe-auto-migrate' on a stale :version; the
    ;; newer `preformat6' (P1-8) is written by
    ;; `supertag--persistence--snapshot-preformat6' the first time a
    ;; canonical save is about to overwrite a still-legacy-format on-disk
    ;; file -- the case a version-only check misses (format changed without
    ;; the stored :version being stale). See `supertag-data-version'.
    (if (not (and dir (file-directory-p dir)))
        (insert "Downgrade snapshots (never auto-deleted): n/a (no backup directory)\n")
      (let ((premigrate (directory-files dir nil "\\`supertag-db-premigrate-.*\\.el\\'"))
            (preformat6 (directory-files dir nil "\\`supertag-db-preformat6-.*\\.el\\'")))
        (insert (format "Downgrade snapshots (never auto-deleted): %d premigrate, %d preformat6\n"
                        (length premigrate) (length preformat6)))))))

(defun supertag-doctor--section-presence ()
  "Insert the \"Presence\" section into the current buffer.
Reports the advisory cross-machine presence file (see
`supertag--presence-file' in supertag-core-persistence.el): its path,
whether it exists, the host and age of the last claim, and a verdict of
own / foreign-active / foreign-stale / unavailable."
  (supertag-doctor--insert-header "7. Presence")
  (if (not (fboundp 'supertag--presence-file))
      (insert (supertag-doctor--na) "\n")
    (let ((file (supertag--presence-file))
          (enabled (if (boundp 'supertag-presence-enable) supertag-presence-enable t)))
      (insert (format "Presence enabled (supertag-presence-enable): %s\n"
                      (if enabled "yes" "no")))
      (insert (format "Presence file: %s\n" (or file (supertag-doctor--na))))
      (cond
       ((not file)
        (insert "  Exists: n/a (supertag-db-file unset)\n"))
       ((not (file-exists-p file))
        (insert "  Exists: no\n"))
       (t
        (insert "  Exists: yes\n")
        (let* ((data (and (fboundp 'supertag--presence-read)
                          (ignore-errors (supertag--presence-read))))
               (host (and data (cdr (assq 'host data))))
               (updated-at (and data (cdr (assq 'updatedAt data))))
               (parsed (and (stringp updated-at)
                           (fboundp 'parse-iso8601-time-string)
                           (ignore-errors (parse-iso8601-time-string updated-at))))
               (age (and parsed (round (float-time (time-subtract (current-time) parsed))))))
          (insert (format "  Host: %s\n" (or host (supertag-doctor--na))))
          (insert (format "  Updated at: %s\n" (or updated-at (supertag-doctor--na))))
          (insert (format "  Age: %s\n" (if age (format "%d seconds" age) (supertag-doctor--na))))
          (insert
           (format
            "  Verdict: %s\n"
            (cond
             ((not (stringp host)) "n/a (unparseable presence file)")
             ((string= host (system-name)) "own (claimed by this host)")
             ((null age) "n/a (unparseable updatedAt timestamp)")
             ((and (boundp 'supertag-presence-stale-seconds)
                   (< age supertag-presence-stale-seconds))
              (format "FOREIGN, ACTIVE (%s, %ds ago; stale threshold %ds)"
                      host age supertag-presence-stale-seconds))
             (t
              (format "foreign, stale (%s, %ds ago)" host age)))))))))))

(defun supertag-doctor--section-git-sync ()
  "Report the Org Git root, tracked local caches, and unresolved text conflicts."
  (supertag-doctor--insert-header "8. Git Sync")
  (let* ((status (supertag-git-check))
         (root (plist-get status :repo-root))
         (conflicts (and root (supertag-git-sync--live-conflicted-org-files root))))
    (insert (format "Org Git root: %s\n" (or root "not configured")))
    (insert (format "Only Org and root .gitignore tracked: %s\n"
                    (if (plist-get status :org-only-p) "yes" "no")))
    (insert (format "Tracked DB/attributes: %s\n"
                    (or (plist-get status :retired-tracked) "none")))
    (when (plist-get status :retired-tracked)
      (insert "Run supertag-git-setup to stop tracking local caches.\n"))
    (insert (format "Conflict pause: %s\n"
                    (if (or conflicts (bound-and-true-p supertag-git--conflicted-files)) "yes" "no")))
    (dolist (file (delete-dups (append conflicts (bound-and-true-p supertag-git--conflicted-files))))
      (insert (format "  %s\n" file)))
    (when conflicts (insert "Resolve in smerge-mode, save, then supertag-git-sync-now.\n"))))

(defun supertag-doctor--build-report ()
  "Erase the current buffer and insert the full doctor report."
  (erase-buffer)
  (insert (format "Supertag Doctor Report - %s\n"
                  (format-time-string "%Y-%m-%d %H:%M:%S")))
  (insert (make-string 72 ?-) "\n")
  (supertag-doctor--section-database-files)
  (supertag-doctor--section-guards)
  (supertag-doctor--section-recovery)
  (supertag-doctor--section-revision-presence)
  (supertag-doctor--section-version)
  (supertag-doctor--section-integrity)
  (supertag-doctor--section-backups)
  (supertag-doctor--section-presence)
  (supertag-doctor--section-git-sync)
  (insert "\n"))

;;; --- Repairs ---

(defconst supertag-doctor--repair-commands
  '((supertag-migrate-run . "Run verified data migration")
    (supertag-migrate-status . "Report pending migration and identity conflicts")
    (supertag-sync-cleanup-database
     . "Validate nodes and garbage-collect orphans (supertag-sync-cleanup-database)")
    (supertag-sync-full-rescan
     . "Rebuild document projections from Org files (supertag-sync-full-rescan)"))
  "Repair commands offered by `supertag-doctor', in run order.")

(defun supertag-doctor--offer-recovery ()
  "Offer data-root and store recovery actions before generic repairs."
  (let ((status (and (boundp 'supertag--store-origin)
                     (plist-get supertag--store-origin :status)))
        (directory-issue
         (and (fboundp 'supertag-persistence-data-directory-recovery-needed-p)
              (supertag-persistence-data-directory-recovery-needed-p))))
    (when directory-issue
      (let ((desc "Resolve retired/current data directories (supertag-resolve-data-directories)"))
        (cond
         ((not (fboundp 'supertag-resolve-data-directories))
          (insert (format "- SKIPPED (unavailable): %s\n" desc)))
         ((y-or-n-p (format "Recovery: %s? " desc))
          (insert (format "- RUNNING: %s\n" desc))
          (condition-case err
              (progn
                (supertag-resolve-data-directories)
                (insert "  -> done\n"))
            (error
             (insert (format "  -> ERROR: %s\n" (error-message-string err))))))
         (t
          (insert (format "- SKIPPED (declined): %s\n" desc))))))
    (when (memq status '(:failed :missing-with-backups))
      (dolist (entry
               (append
                (list (cons 'supertag-restore
                            "Restore the database from a backup snapshot (supertag-restore)"))
                (when (eq status :missing-with-backups)
                  (list (cons 'supertag-accept-fresh-store
                              "Accept starting over with an EMPTY store (supertag-accept-fresh-store)")))))
        (let ((fn (car entry))
              (desc (cdr entry)))
          (cond
           ((not (fboundp fn))
            (insert (format "- SKIPPED (unavailable): %s\n" desc)))
           ((y-or-n-p (format "Recovery: %s? " desc))
            (insert (format "- RUNNING: %s\n" desc))
            (condition-case err
                (progn (funcall fn)
                       (insert "  -> done\n"))
              (error
               (insert (format "  -> ERROR: %s\n" (error-message-string err))))))
           (t
            (insert (format "- SKIPPED (declined): %s\n" desc)))))))))

(defun supertag-doctor--run-repairs ()
  "Offer to run each available repair command, appending results to the buffer."
  (supertag-doctor--insert-header "Repairs")
  (supertag-doctor--offer-recovery)
  (dolist (entry supertag-doctor--repair-commands)
    (let ((fn (car entry))
          (desc (cdr entry)))
      (cond
       ((not (fboundp fn))
        (insert (format "- SKIPPED (unavailable): %s\n" desc)))
       ((y-or-n-p (format "Run repair: %s? " desc))
        (insert (format "- RUNNING: %s\n" desc))
        (condition-case err
            (progn (funcall fn)
                   (insert "  -> done\n"))
          (error
           (insert (format "  -> ERROR: %s\n" (error-message-string err))))))
       (t
        (insert (format "- SKIPPED (declined): %s\n" desc))))))
  (cond
   ((not (fboundp 'supertag-save-store))
    (insert "- SKIPPED (unavailable): Save store (supertag-save-store)\n"))
   ((y-or-n-p "Save store now (supertag-save-store)? ")
    (insert "- RUNNING: Save store (supertag-save-store)\n")
    (condition-case err
        (progn (supertag-save-store)
               (insert "  -> done\n"))
      (error
       (insert (format "  -> ERROR: %s\n" (error-message-string err))))))
   (t
    (insert "- SKIPPED (declined): Save store (supertag-save-store)\n"))))

;;; --- Entry point ---

(defun supertag-doctor (&optional report-only)
  "Run health checks on the Supertag database and report to a buffer.

Produces a report in the \"*Supertag Doctor*\" buffer covering
database files, guards, revision/presence state, data version, integrity,
and backups.

With non-nil REPORT-ONLY (or when running in batch mode,
see `noninteractive'), only the report is produced and no repairs are
offered. Otherwise, after the report, a series of known-safe repair
commands are offered one at a time via `y-or-n-p', skipping any that
are not currently available (not `fboundp')."
  (let* ((report-only (or report-only noninteractive))
         (buf (get-buffer-create supertag-doctor--buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (supertag-doctor--build-report)
        (unless report-only
          (supertag-doctor--run-repairs)))
      (goto-char (point-min)))
    (unless noninteractive
      (display-buffer buf))
    buf))

(provide 'supertag-doctor)

;;; supertag-doctor.el ends here
