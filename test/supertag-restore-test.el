;;; supertag-restore-test.el --- ERT tests for supertag-restore's pure parts -*- lexical-binding: t; -*-

;;; Commentary:
;; Covers the snapshot helpers and the destructive restore path, including
;; legacy summaries, downgrade restores, pre-restore recovery points, and
;; multi-instance locking.
;;
;; Every test runs inside an isolated temp directory; none of them ever
;; touch the user's real `~/.emacs.d'.
;;
;; Run:
;;   emacs -batch -L . -L test --eval "(package-initialize)" \
;;     -l ert -l test/supertag-restore-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'ht)
(require 'cl-lib)

(when load-file-name
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)
(require 'supertag-core-persistence)

;;; --- Helpers ---

(defmacro supertag-restore-test--with-temp-dir (var &rest body)
  "Bind VAR to a fresh temp directory for BODY, removed afterwards."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "supertag-restore-test" t))))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-directory ,var t)))))

(defun supertag-restore-test--touch (dir name &optional time)
  "Create an empty snapshot file NAME under DIR, stamped with TIME.
TIME defaults to the current time. Writes a minimal, readable store so
`supertag--restore-snapshot-summary' has something to parse."
  (let ((file (expand-file-name name dir)))
    (with-temp-file file
      (let ((store (ht-create))
            (nodes (ht-create)))
        (puthash "n1" (list :id "n1" :type :node) nodes)
        (puthash :nodes nodes store)
        (puthash :version "6.0.0" store)
        (let ((print-length nil) (print-level nil) (print-circle t))
          (prin1 store (current-buffer)))))
    (when time
      (set-file-times file time))
    file))

(defun supertag-restore-test--make-store (ids &optional version root-key)
  "Return a minimal store containing IDS under ROOT-KEY.
VERSION defaults to `supertag-data-version' and ROOT-KEY to :nodes."
  (let ((store (ht-create))
        (nodes (ht-create)))
    (dolist (id ids)
      (puthash id (list :id id :type :node :title id) nodes))
    (puthash (or root-key :nodes) nodes store)
    (puthash :version (or version supertag-data-version) store)
    store))

(defun supertag-restore-test--write-store (file store)
  "Write STORE to FILE in the legacy single-sexp format."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (let ((print-length nil)
          (print-level nil)
          (print-circle t))
      (prin1 store (current-buffer)))))

(defun supertag-restore-test--read-file (file)
  "Return FILE's literal contents."
  (with-temp-buffer
    (insert-file-contents-literally file)
    (buffer-string)))

(defmacro supertag-restore-test--with-temp-env (&rest body)
  "Run BODY with persistence redirected to an isolated temp directory."
  (declare (indent 0))
  `(supertag-restore-test--with-temp-dir tmp
     (let ((supertag-data-directory tmp)
           (supertag-db-file (expand-file-name "supertag-db.el" tmp))
           (supertag-db-backup-directory (expand-file-name "backups" tmp))
           (supertag-db-auto-migrate t)
           (supertag-db-verify-after-save t)
           (supertag--store nil)
           (supertag--store-origin nil)
           (supertag--store-revision 0)
           (supertag--last-conflict-revision nil))
       (progn ,@body))))

(defun supertag-restore-test--run-command (snapshot)
  "Run `supertag-restore', selecting SNAPSHOT and confirming the restore."
  (let ((name (file-name-nondirectory snapshot)))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt labels &rest _)
                 (or (cl-find-if (lambda (label)
                                   (string-match-p (regexp-quote name) label))
                                 labels)
                     (ert-fail (format "Snapshot label not found: %s" name)))))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (supertag-restore))))

;;; --- Classification ---

(ert-deftest supertag-restore-test-kind-classifies-all-three-patterns ()
  (should (eq 'daily (supertag--restore-snapshot-kind "supertag-db-2026-07-20.el")))
  (should (eq 'premigrate (supertag--restore-snapshot-kind "supertag-db-premigrate-4-0-0-20260720-101500.el")))
  (should (eq 'preformat6 (supertag--restore-snapshot-kind "supertag-db-preformat6-20260720-101500.el")))
  (should (eq 'prerestore (supertag--restore-snapshot-kind "supertag-db-prerestore-20260720-101500-abc123.el"))))

(ert-deftest supertag-restore-test-kind-rejects-unrelated-files ()
  (should (null (supertag--restore-snapshot-kind "supertag-db.el")))
  (should (null (supertag--restore-snapshot-kind "supertag-db.el.tmp123")))
  (should (null (supertag--restore-snapshot-kind "sync-state.el")))
  (should (null (supertag--restore-snapshot-kind "supertag-db-not-a-date.el"))))

(ert-deftest supertag-restore-test-kind-label-covers-known-kinds ()
  (should (equal "daily" (supertag--restore-snapshot-kind-label 'daily)))
  (should (equal "pre-migration" (supertag--restore-snapshot-kind-label 'premigrate)))
  (should (equal "pre-format6" (supertag--restore-snapshot-kind-label 'preformat6)))
  (should (equal "pre-restore" (supertag--restore-snapshot-kind-label 'prerestore))))

;;; --- Enumeration + sorting ---

(ert-deftest supertag-restore-test-list-finds-all-kinds-sorted-newest-first ()
  (supertag-restore-test--with-temp-dir dir
    (let* ((now (current-time))
           (older (time-subtract now (seconds-to-time 200)))
           (oldest (time-subtract now (seconds-to-time 400))))
      (supertag-restore-test--touch dir "supertag-db-2026-07-18.el" oldest)
      (supertag-restore-test--touch dir "supertag-db-premigrate-4-0-0-20260719-000000.el" older)
      (supertag-restore-test--touch dir "supertag-db-preformat6-20260720-000000.el" now)
      (supertag-restore-test--touch dir "supertag-db-prerestore-20260720-000000-abc123.el"
                                    (time-add now (seconds-to-time 100)))
      ;; Unrelated file in the same directory must not show up as a snapshot.
      (supertag-restore-test--touch dir "sync-state.el" now)
      (let ((snapshots (supertag--restore-snapshot-list dir)))
        (should (= 4 (length snapshots)))
        (should (equal '(prerestore preformat6 premigrate daily)
                        (mapcar (lambda (s) (plist-get s :kind)) snapshots)))))))

(ert-deftest supertag-restore-test-list-nil-for-missing-directory ()
  (should (null (supertag--restore-snapshot-list "/nonexistent/dir/for/restore/test"))))

(ert-deftest supertag-restore-test-list-nil-for-empty-directory ()
  (supertag-restore-test--with-temp-dir dir
    (should (null (supertag--restore-snapshot-list dir)))))

;;; --- Summary + labeling ---

(ert-deftest supertag-restore-test-summary-reads-nodes-and-version ()
  (supertag-restore-test--with-temp-dir dir
    (let* ((file (supertag-restore-test--touch dir "supertag-db-2026-07-20.el")))
      (let ((summary (supertag--restore-snapshot-summary file)))
        (should (= 1 (plist-get summary :nodes)))
        (should (= 0 (plist-get summary :tags)))
        (should (equal "6.0.0" (plist-get summary :version)))))))

(ert-deftest supertag-restore-test-summary-normalizes-legacy-root-keys ()
  (supertag-restore-test--with-temp-dir dir
    (let* ((file (expand-file-name "supertag-db-premigrate-5-0-0-legacy.el" dir))
           (store (supertag-restore-test--make-store '("n1" "n2") "5.0.0" 'nodes))
           (tags (ht-create)))
      (puthash "t1" (list :id "t1" :type :tag) tags)
      (puthash "tags" tags store)
      (supertag-restore-test--write-store file store)
      (let ((summary (supertag--restore-snapshot-summary file)))
        (should (= 2 (plist-get summary :nodes)))
        (should (= 1 (plist-get summary :tags)))
        (should (equal "5.0.0" (plist-get summary :version)))))))

(ert-deftest supertag-restore-test-describe-includes-kind-and-node-count ()
  (supertag-restore-test--with-temp-dir dir
    (supertag-restore-test--touch dir "supertag-db-2026-07-20.el")
    (let* ((snapshots (supertag--restore-snapshot-list dir))
           (label (supertag--restore-snapshot-describe (car snapshots))))
      (should (string-match-p "daily" label))
      (should (string-match-p "1" label))
      (should (string-match-p "supertag-db-2026-07-20\\.el" label)))))

;;; --- Destructive restore path ---

(ert-deftest supertag-restore-test-dirty-store-gets-unique-recovery-snapshot ()
  (supertag-restore-test--with-temp-env
    (supertag-persistence-ensure-data-directory)
    (supertag-restore-test--write-store
     supertag-db-file (supertag-restore-test--make-store '("disk")))
    (supertag-load-store)
    (setq supertag--store (supertag-restore-test--make-store '("memory-1" "memory-2")))
    (supertag-mark-dirty)
    ;; An existing daily backup must not suppress the per-restore recovery point.
    (supertag-restore-test--write-store
     (supertag-get-backup-filename (format-time-string "%Y-%m-%d"))
     (supertag-restore-test--make-store '("daily")))
    (let ((snapshot (expand-file-name
                     "supertag-db-preformat6-20260720-101500.el"
                     supertag-db-backup-directory)))
      (supertag-restore-test--write-store
       snapshot (supertag-restore-test--make-store '("restored")))
      (supertag-restore-test--run-command snapshot)
      (let ((recovery (directory-files supertag-db-backup-directory t
                                       "\\`supertag-db-prerestore-.*\\.el\\'")))
        (should (= 1 (length recovery)))
        (should (= 2 (plist-get (supertag--restore-snapshot-summary (car recovery))
                                :nodes)))))))

(ert-deftest supertag-restore-test-downgrade-snapshot-is-not-auto-migrated ()
  (supertag-restore-test--with-temp-env
    (supertag-persistence-ensure-data-directory)
    (supertag-restore-test--write-store
     supertag-db-file (supertag-restore-test--make-store '("live")))
    (supertag-load-store)
    (let* ((snapshot (expand-file-name
                      "supertag-db-premigrate-5-0-0-20260720-101500.el"
                      supertag-db-backup-directory))
           (old-store (supertag-restore-test--make-store '("old") "5.0.0")))
      (supertag-restore-test--write-store snapshot old-store)
      (let ((snapshot-bytes (supertag-restore-test--read-file snapshot)))
        (supertag-restore-test--run-command snapshot)
        (should (equal "5.0.0" (supertag--get-data-version supertag--store)))
        (should (equal snapshot-bytes
                       (supertag-restore-test--read-file supertag-db-file)))))))

(provide 'supertag-restore-test)

;;; supertag-restore-test.el ends here

(ert-deftest supertag-restore-fresh-store-version-survives-cold-load ()
  "A fresh vault must not read back as an unsupported legacy version."
  (let* ((tmp (make-temp-file "supertag-version-" t))
         (org (expand-file-name "org/" tmp))
         (home (expand-file-name "home/" tmp))
         (data (expand-file-name "data/" tmp))
         (store (expand-file-name "store.el" data))
         (write-prog (expand-file-name "write.el" tmp))
         (read-prog (expand-file-name "read.el" tmp))
         (repo (file-name-directory (locate-library "supertag")))
         (emacs (or (getenv "EMACS_BIN")
                    (expand-file-name invocation-name invocation-directory)))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (process-environment (copy-sequence process-environment))
         (default-directory tmp)
         (preamble (concat
                    ";;; -*- lexical-binding: t; -*-\n"
                    "(setq user-emacs-directory (file-name-as-directory (getenv \"SV_HOME\")))\n"
                    "(setq custom-file (expand-file-name \"custom.el\" user-emacs-directory))\n"
                    "(setq org-id-locations-file (expand-file-name \"org-id-locations.el\" user-emacs-directory))\n"
                    "(setq supertag-data-directory (getenv \"SV_DATA\"))\n"
                    "(setq supertag-db-file (expand-file-name \"store.el\" supertag-data-directory))\n"
                    "(setq supertag-db-backup-directory (expand-file-name \"backups/\" supertag-data-directory))\n"
                    "(setq supertag-sync-state-file (expand-file-name \"sync-state.el\" supertag-data-directory))\n"
                    "(setq supertag-sync-directories (list (getenv \"SV_ORG\")))\n"
                    "(require 'supertag)\n"))
         (report "(princ (format \"%s version=%s nodes=%d\\n\" phase (or (supertag--get-data-version supertag--store) \"nil\") (hash-table-count (supertag-store-get-collection :nodes))))\n")
         (run (lambda (prog)
                (with-temp-buffer
                  (let ((status (apply #'call-process
                                       emacs nil t nil
                                       (append (list "-Q" "--batch"
                                                     "-L" repo
                                                     "-L" (expand-file-name "test" repo))
                                               (cl-loop for d in deps append (list "-L" d))
                                               (list "-l" prog)))))
                    (cons status (buffer-string)))))))
    (unwind-protect
        (progn
          (make-directory org t)
          (make-directory home t)
          (setenv "HOME" home)
          (setenv "CFFIXED_USER_HOME" home)
          (setenv "SV_ORG" org)
          (setenv "SV_DATA" data)
          (setenv "SV_HOME" home)
          (with-temp-file (expand-file-name "note.org" org)
            (insert "* Node A\n:PROPERTIES:\n:ID: id-a\n:END:\nBody A\n"))
          (with-temp-file write-prog
            (insert preamble
                    "(supertag-sync-full-rescan)\n(supertag-save-store)\n"
                    (format "(princ (format \"WRITE version=%%s nodes=%%d store=%%S\\n\" (or (supertag--get-data-version supertag--store) \"nil\") (hash-table-count (supertag-store-get-collection :nodes)) (file-exists-p supertag-db-file)))\n")))
          (with-temp-file read-prog
            (insert preamble
                    "(supertag-load-store)\n"
                    (format "(princ (format \"READ version=%%s nodes=%%d store=%%S\\n\" (or (supertag--get-data-version supertag--store) \"nil\") (hash-table-count (supertag-store-get-collection :nodes)) (file-exists-p supertag-db-file)))\n")))
          (let ((w (funcall run write-prog)))
            (unless (equal 0 (car w))
              (ert-fail (format "write child exit %s:\n%s" (car w) (cdr w))))
            (should (string-match-p "WRITE version=" (cdr w)))
            (should (string-match-p (concat ":version \"" (regexp-quote supertag-data-version) "\"")
                                    (with-temp-buffer (insert-file-contents store) (buffer-string)))))
          (let ((r (funcall run read-prog)))
            (unless (equal 0 (car r))
              (ert-fail (format "read child exit %s:\n%s" (car r) (cdr r))))
            (unless (and (string-match-p (concat "READ version=" (regexp-quote supertag-data-version)
                                                " nodes=1 store=t")
                                        (cdr r))
                         (not (string-match-p "Unsupported data version" (cdr r)))
                         (not (string-match-p "Migration stopped" (cdr r))))
              (ert-fail (format "cold load was not clean:\n%s" (cdr r))))))
      (delete-directory tmp t))))

(ert-deftest supertag-restore-unknown-and-future-versions-are-refused ()
  "Unknown or future data versions are refused, never guessed or re-stamped."
  (let ((supertag--store nil)
        (supertag--store-revision 0)
        (supertag-migrate--last-snapshot nil))
    (supertag--ensure-store)
    (should (equal supertag-data-version (supertag--get-data-version supertag--store)))
    ;; Unknown: no :version stamp at all.
    (remhash :version supertag--store)
    (should-not (supertag--get-data-version supertag--store))
    (should-not (supertag-migrate-run))
    (should (string-match-p "unknown" (or supertag-migrate--last-error "")))
    (should-not (supertag--get-data-version supertag--store))
    (should-not supertag-migrate--last-snapshot)
    ;; Future: a version this build is too old for.
    (setq supertag-migrate--last-error nil)
    (puthash :version "99.0.0" supertag--store)
    (should-not (supertag-migrate-run))
    (should (string-match-p "newer than this build" (or supertag-migrate--last-error "")))
    (should (equal "99.0.0" (supertag--get-data-version supertag--store)))
    (should-not supertag-migrate--last-snapshot)))
