;;; persistence-hardening-test.el --- ERT tests for persistence-hardening features -*- lexical-binding: t; -*-

;;; Commentary:
;; Regression tests for the persistence-hardening work on the
;; hardening/p0-p2 branch:
;;   1. Atomic DB save (temp file + verify + rename).
;;   2. Multi-instance advisory locking.
;;   3. Auto-migration on load, with pre-migration snapshots.
;;   4. `supertag-doctor' batch report rendering.
;;
;; Every test runs inside an isolated temp directory; none of them
;; ever touch the user's real `~/.emacs.d'.
;;
;; Run:
;;   ./test/run-tests.sh persist
;;   emacs -batch -L . --eval "(package-initialize)" \
;;     -l test/persistence-hardening-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'ht)
(require 'cl-lib)

(when load-file-name
  (add-to-list 'load-path (file-name-directory load-file-name))
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)
(require 'supertag-core-persistence)
(require 'supertag-doctor)
(require 'ownership-fixture)

;;; --- Shared helpers ---

(defun supertag-hardening-test--make-store (ids &optional version)
  "Return a minimal store hash table with IDS inserted into :nodes.
When VERSION is non-nil, also stamp the store's :version key with it
so migration tests can seed an out-of-date store."
  (let ((store (ht-create))
        (nodes (ht-create)))
    (dolist (id ids)
      (puthash id (list :id id :type :node :title "t" :file "/tmp/f") nodes))
    (puthash :nodes nodes store)
    (when version
      (puthash :version version store))
    store))

(defun supertag-hardening-test--write-store-file (file store)
  "Write STORE into FILE using the same print settings as persistence."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (let ((print-escape-nonascii t)
          (print-length nil)
          (print-level nil)
          (print-circle t))
      (prin1 store (current-buffer)))))

(defun supertag-hardening-test--read-file-bytes (file)
  "Return the literal contents of FILE as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun supertag-hardening-test--tmp-residues (dir)
  "Return files under DIR whose name still looks like a save temp file."
  (directory-files dir nil "\\.tmp"))

(defmacro supertag-hardening-test--with-temp-env (&rest body)
  "Run BODY with persistence state redirected into an isolated temp dir.
Rebinds `supertag-data-directory', `supertag-db-file',
`supertag-db-backup-directory', and the relevant persistence defcustoms
and internal state variables, so tests never touch the real
`~/.emacs.d'. The temp directory is removed afterwards."
  (declare (indent 0))
  `(let* ((tmp (file-name-as-directory (make-temp-file "supertag-hardening-test" t)))
          (supertag-data-directory tmp)
          (supertag-db-file (expand-file-name "supertag-db.el" tmp))
          (supertag-db-backup-directory (expand-file-name "backups" tmp))
          (supertag-db-verify-after-save t)
          (supertag-db-lock t)
          (supertag-db-auto-migrate t)
          (supertag--store nil)
          (supertag--store-origin nil)
          (supertag--db-lock-conflict nil)
          (supertag--db-locked-file nil))
     (unwind-protect
         (progn ,@body)
       (supertag--db-release-lock)
       (ignore-errors (delete-directory tmp t)))))

(defmacro supertag-hardening-test--with-temp-user-directory (&rest body)
  "Run BODY with an isolated `user-emacs-directory'."
  (declare (indent 0))
  `(let* ((tmp (file-name-as-directory
                (make-temp-file "supertag-rename-test" t)))
          (user-emacs-directory tmp)
          (supertag-data-directory (expand-file-name "supertag" tmp))
          (supertag-db-file
           (expand-file-name "supertag-db.el" supertag-data-directory))
          (supertag-db-backup-directory
           (expand-file-name "backups" supertag-data-directory)))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-directory tmp t)))))

(defun supertag-hardening-test--write-root-store (directory ids)
  "Write a test database containing IDS under DIRECTORY."
  (let ((file (expand-file-name "supertag-db.el" directory)))
    (supertag-hardening-test--write-store-file
     file (supertag-hardening-test--make-store ids supertag-data-version))
    file))

(defun supertag-hardening-test--retired-directories (name)
  "Return retired directories for NAME under `user-emacs-directory'."
  (directory-files
   user-emacs-directory t
   (format "\\`%s-retired-[0-9]\\{8\\}\\(?:-[0-9]+\\)?\\'"
           (regexp-quote name))))

;;; --- Breaking rename data-root guard ---

(ert-deftest supertag-hardening-test-legacy-data-root-fails-before-creation ()
  "An unmigrated legacy root fails instead of creating an empty new root."
  (supertag-hardening-test--with-temp-user-directory
    (let ((legacy (expand-file-name "org-supertag" user-emacs-directory))
          (current (expand-file-name "supertag" user-emacs-directory)))
      (make-directory legacy t)
      (should-error (supertag-persistence-check-legacy-data-directory)
                    :type 'user-error)
      (should-not (file-exists-p current)))))

(ert-deftest supertag-hardening-test-two-default-data-roots-are-ambiguous ()
  "Supertag refuses to guess when both default data roots exist."
  (supertag-hardening-test--with-temp-user-directory
    (make-directory (expand-file-name "org-supertag" user-emacs-directory) t)
    (make-directory (expand-file-name "supertag" user-emacs-directory) t)
    (should-error (supertag-persistence-check-legacy-data-directory)
                  :type 'user-error)))

(ert-deftest supertag-hardening-test-data-root-guard-explains-comparison-and-recovery ()
  "The startup guard answers what happened, data safety, and next action."
  (supertag-hardening-test--with-temp-user-directory
    (let* ((legacy (expand-file-name "org-supertag" user-emacs-directory))
           (current (expand-file-name "supertag" user-emacs-directory))
           (legacy-db (supertag-hardening-test--write-root-store
                       legacy '("OLD")))
           (current-db (supertag-hardening-test--write-root-store
                        current '("NEW-1" "NEW-2")))
           message)
      (set-file-times legacy-db (encode-time 0 0 12 1 8 2026))
      (set-file-times current-db (encode-time 0 0 12 2 8 2026))
      (setq message
            (condition-case err
                (progn
                  (supertag-persistence-check-legacy-data-directory)
                  nil)
              (user-error (error-message-string err))))
      (should message)
      (should (string-match-p (regexp-quote legacy) message))
      (should (string-match-p (regexp-quote current) message))
      (should (string-match-p "Modified:" message))
      (should (string-match-p "Size: [0-9]+ bytes" message))
      (should (string-match-p "Nodes: 1" message))
      (should (string-match-p "Nodes: 2" message))
      (should (string-match-p "data.*safe" message))
      (should (string-match-p "M-x supertag-resolve-data-directories"
                              message)))))

(ert-deftest supertag-hardening-test-data-root-summary-marks-unreadable-db ()
  "A corrupt candidate is described as unreadable without hiding its metadata."
  (supertag-hardening-test--with-temp-user-directory
    (let ((legacy (expand-file-name "org-supertag" user-emacs-directory))
          (current (expand-file-name "supertag" user-emacs-directory)))
      (make-directory legacy t)
      (with-temp-file (expand-file-name "supertag-db.el" legacy)
        (insert "<<<<<<< unresolved\n"))
      (supertag-hardening-test--write-root-store current '("NEW"))
      (let ((summary
             (supertag-persistence-format-data-directory-comparison)))
        (should (string-match-p "Nodes: unreadable" summary))
        (should (string-match-p "Size: [0-9]+ bytes" summary))))))

(ert-deftest supertag-hardening-test-data-root-summary-reads-legacy-db-name ()
  "The comparison recognizes the older supertag-db.db filename."
  (supertag-hardening-test--with-temp-user-directory
    (let ((legacy (expand-file-name "org-supertag" user-emacs-directory))
          (current (expand-file-name "supertag" user-emacs-directory)))
      (supertag-hardening-test--write-store-file
       (expand-file-name "supertag-db.db" legacy)
       (supertag-hardening-test--make-store '("OLD-1" "OLD-2" "OLD-3")
                                             supertag-data-version))
      (supertag-hardening-test--write-root-store current '("NEW"))
      (let ((summary
             (supertag-persistence-format-data-directory-comparison)))
        (should (string-match-p
                 (regexp-quote (expand-file-name "supertag-db.db" legacy))
                 summary))
        (should (string-match-p "Nodes: 3" summary))))))

(ert-deftest supertag-hardening-test-doctor-reports-data-directory-recovery ()
  "Doctor reports the dual-root guard and names its guided recovery command."
  (supertag-hardening-test--with-temp-user-directory
    (let ((legacy (expand-file-name "org-supertag" user-emacs-directory))
          (current (expand-file-name "supertag" user-emacs-directory))
          (supertag--store-origin nil))
      (supertag-hardening-test--write-root-store legacy '("OLD"))
      (supertag-hardening-test--write-root-store current '("NEW"))
      (let* ((buffer (supertag-doctor t))
             (text (with-current-buffer buffer (buffer-string))))
        (should (string-match-p "2b\\. Recovery needed" text))
        (should (string-match-p "Data directory" text))
        (should (string-match-p (regexp-quote legacy) text))
        (should (string-match-p (regexp-quote current) text))
        (should (string-match-p "supertag-resolve-data-directories" text))))))

(ert-deftest supertag-hardening-test-resolve-data-roots-keeps-current-and-retires-legacy ()
  "Keeping current archives the legacy directory without deleting either DB."
  (supertag-hardening-test--with-temp-user-directory
    (let* ((legacy (expand-file-name "org-supertag" user-emacs-directory))
           (current (expand-file-name "supertag" user-emacs-directory))
           (legacy-db (supertag-hardening-test--write-root-store legacy '("OLD")))
           (current-db (supertag-hardening-test--write-root-store current '("NEW")))
           (answers '(t nil))
           result)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "Keep current data directory"))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _)
                   (prog1 (car answers) (setq answers (cdr answers))))))
        (setq result (supertag-resolve-data-directories)))
      (should (eq :resolved (plist-get result :status)))
      (should (eq :current (plist-get result :kept)))
      (should (file-exists-p current-db))
      (should-not (file-exists-p legacy))
      (let ((retired (supertag-hardening-test--retired-directories
                      "org-supertag")))
        (should (= 1 (length retired)))
        (should (file-exists-p
                 (expand-file-name "supertag-db.el" (car retired))))
        (should-not (file-exists-p legacy-db))))))

(ert-deftest supertag-hardening-test-resolve-data-roots-keeps-legacy-and-retires-current ()
  "Keeping legacy archives current, then moves legacy into the current slot."
  (supertag-hardening-test--with-temp-user-directory
    (let* ((legacy (expand-file-name "org-supertag" user-emacs-directory))
           (current (expand-file-name "supertag" user-emacs-directory))
           (legacy-db (supertag-hardening-test--write-root-store legacy '("OLD")))
           (current-db (supertag-hardening-test--write-root-store current '("NEW")))
           (answers '(t nil))
           result)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "Keep legacy data directory"))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _)
                   (prog1 (car answers) (setq answers (cdr answers))))))
        (setq result (supertag-resolve-data-directories)))
      (should (eq :legacy (plist-get result :kept)))
      (should-not (file-exists-p legacy))
      (should (file-exists-p current-db))
      (let* ((loaded (supertag--persistence--try-read-store
                      current-db))
             (nodes (gethash :nodes loaded))
             (retired (supertag-hardening-test--retired-directories
                       "supertag"))
             retired-loaded
             retired-nodes)
        (should (gethash "OLD" nodes))
        (should-not (gethash "NEW" nodes))
        (should (= 1 (length retired)))
        (should (file-exists-p
                 (expand-file-name "supertag-db.el" (car retired))))
        (setq retired-loaded
              (supertag--persistence--try-read-store
               (expand-file-name "supertag-db.el" (car retired)))
              retired-nodes (gethash :nodes retired-loaded))
        (should (gethash "NEW" retired-nodes))
        (should-not (gethash "OLD" retired-nodes)))
      (should-not (file-exists-p legacy-db)))))

(ert-deftest supertag-hardening-test-resolve-legacy-only-moves-it-into-current-slot ()
  "A legacy-only upgrade moves that root into the current default path."
  (supertag-hardening-test--with-temp-user-directory
    (let* ((legacy (expand-file-name "org-supertag" user-emacs-directory))
           (current (expand-file-name "supertag" user-emacs-directory))
           (answers '(t nil))
           result)
      (supertag-hardening-test--write-root-store legacy '("OLD"))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "Keep legacy data directory"))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _)
                   (prog1 (car answers) (setq answers (cdr answers))))))
        (setq result (supertag-resolve-data-directories)))
      (should (eq :resolved (plist-get result :status)))
      (should (eq :legacy (plist-get result :kept)))
      (should-not (file-exists-p legacy))
      (let* ((loaded (supertag--persistence--try-read-store
                      (expand-file-name "supertag-db.el" current)))
             (nodes (gethash :nodes loaded)))
        (should (gethash "OLD" nodes)))
      (should-not (supertag-hardening-test--retired-directories
                   "supertag")))))

(ert-deftest supertag-hardening-test-resolve-data-roots-cancel-changes-nothing ()
  "Choosing Cancel performs no rename and asks for no confirmation."
  (supertag-hardening-test--with-temp-user-directory
    (let* ((legacy (expand-file-name "org-supertag" user-emacs-directory))
           (current (expand-file-name "supertag" user-emacs-directory)))
      (supertag-hardening-test--write-root-store legacy '("OLD"))
      (supertag-hardening-test--write-root-store current '("NEW"))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "Cancel"))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (ert-fail "Cancel must not confirm"))))
        (let ((result (supertag-resolve-data-directories)))
          (should (eq :cancelled (plist-get result :status)))))
      (should (file-directory-p legacy))
      (should (file-directory-p current))
      (should-not (supertag-hardening-test--retired-directories
                   "org-supertag"))
      (should-not (supertag-hardening-test--retired-directories
                   "supertag")))))

(ert-deftest supertag-hardening-test-resolve-data-roots-declined-preview-is-safe ()
  "Declining the rename preview leaves both original directories untouched."
  (supertag-hardening-test--with-temp-user-directory
    (let ((legacy (expand-file-name "org-supertag" user-emacs-directory))
          (current (expand-file-name "supertag" user-emacs-directory))
          confirmation-prompt)
      (supertag-hardening-test--write-root-store legacy '("OLD"))
      (supertag-hardening-test--write-root-store current '("NEW"))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "Keep current data directory"))
                ((symbol-function 'y-or-n-p)
                 (lambda (prompt)
                   (setq confirmation-prompt prompt)
                   nil)))
        (let ((result (supertag-resolve-data-directories)))
          (should (eq :cancelled (plist-get result :status)))
          (should (eq :confirmation-declined
                      (plist-get result :reason)))))
      (should (string-match-p (regexp-quote legacy) confirmation-prompt))
      (should (string-match-p
               (regexp-quote
                (expand-file-name
                 (format "org-supertag-retired-%s"
                         (format-time-string "%Y%m%d"))
                 user-emacs-directory))
               confirmation-prompt))
      (should (file-directory-p legacy))
      (should (file-directory-p current)))))

(ert-deftest supertag-hardening-test-resolve-data-roots-avoids-retired-name-collision ()
  "An existing dated archive causes the next safe archive name to gain a suffix."
  (supertag-hardening-test--with-temp-user-directory
    (let* ((legacy (expand-file-name "org-supertag" user-emacs-directory))
           (current (expand-file-name "supertag" user-emacs-directory))
           (base (expand-file-name
                  (format "org-supertag-retired-%s"
                          (format-time-string "%Y%m%d"))
                  user-emacs-directory))
           (answers '(t nil)))
      (supertag-hardening-test--write-root-store legacy '("OLD"))
      (supertag-hardening-test--write-root-store current '("NEW"))
      (make-directory base t)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "Keep current data directory"))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _)
                   (prog1 (car answers) (setq answers (cdr answers))))))
        (supertag-resolve-data-directories))
      (should (file-directory-p base))
      (should (file-directory-p (concat base "-2"))))))

(ert-deftest supertag-hardening-test-resolve-data-roots-rolls-back-partial-rename ()
  "A failed second rename restores the first one and preserves both stores."
  (supertag-hardening-test--with-temp-user-directory
    (let* ((legacy (expand-file-name "org-supertag" user-emacs-directory))
           (current (expand-file-name "supertag" user-emacs-directory))
           (legacy-db (supertag-hardening-test--write-root-store legacy '("OLD")))
           (current-db (supertag-hardening-test--write-root-store current '("NEW")))
           (real-rename (symbol-function 'rename-file))
           (rename-count 0))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "Keep legacy data directory"))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                ((symbol-function 'rename-file)
                 (lambda (source target &optional ok-if-already-exists)
                   (cl-incf rename-count)
                   (if (= rename-count 2)
                       (signal 'file-error '("simulated second rename failure"))
                     (funcall real-rename source target
                              ok-if-already-exists)))))
        (should-error (supertag-resolve-data-directories)
                      :type 'file-error))
      (should (file-exists-p legacy-db))
      (should (file-exists-p current-db))
      (should-not (supertag-hardening-test--retired-directories
                   "supertag")))))

(ert-deftest supertag-hardening-test-resolve-data-roots-can-load-selected-db ()
  "After renaming, the wizard can trigger a direct load of the selected DB."
  (supertag-hardening-test--with-temp-user-directory
    (let* ((legacy (expand-file-name "org-supertag" user-emacs-directory))
           (current (expand-file-name "supertag" user-emacs-directory))
           (answers '(t t))
           loaded-file)
      (supertag-hardening-test--write-root-store legacy '("OLD"))
      (supertag-hardening-test--write-root-store current '("NEW"))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "Keep legacy data directory"))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _)
                   (prog1 (car answers) (setq answers (cdr answers)))))
                ((symbol-function 'supertag-load-store)
                 (lambda (&optional file &rest _)
                   (setq loaded-file file))))
        (let ((result (supertag-resolve-data-directories)))
          (should (plist-get result :loaded))))
      (should (equal (expand-file-name "supertag-db.el" current)
                     loaded-file)))))

(ert-deftest supertag-hardening-test-custom-data-root-skips-default-root-guard ()
  "An explicit custom data root is not coupled to either default root."
  (supertag-hardening-test--with-temp-user-directory
    (let ((supertag-data-directory
           (expand-file-name "custom-supertag" user-emacs-directory)))
      (make-directory (expand-file-name "org-supertag" user-emacs-directory) t)
      (should (supertag-persistence-check-legacy-data-directory)))))

;;; --- 1. Atomic save ---

(ert-deftest supertag-hardening-test-atomic-save-leaves-no-temp-residue ()
  "A successful atomic save leaves the DB file in place and no .tmp litter."
  (supertag-hardening-test--with-temp-env
    (supertag-persistence-ensure-data-directory)
    (setq supertag--store (supertag-hardening-test--make-store '("A" "B" "C")))
    (supertag--persistence-write-store-atomically supertag-db-file)
    (should (file-exists-p supertag-db-file))
    (should (file-readable-p supertag-db-file))
    (let* ((loaded (supertag--persistence--try-read-store supertag-db-file))
           (nodes (gethash :nodes loaded)))
      (should (hash-table-p nodes))
      (should (= 3 (hash-table-count nodes))))
    (should (null (supertag-hardening-test--tmp-residues
                   (file-name-directory supertag-db-file))))))

(ert-deftest supertag-hardening-test-atomic-save-failure-preserves-old-db ()
  "If `rename-file' fails, the previous DB file is left untouched."
  (supertag-hardening-test--with-temp-env
    (supertag-persistence-ensure-data-directory)
    (supertag-hardening-test--write-store-file
     supertag-db-file (supertag-hardening-test--make-store '("OLD")))
    (let ((original-bytes (supertag-hardening-test--read-file-bytes supertag-db-file)))
      (setq supertag--store (supertag-hardening-test--make-store '("OLD" "NEW" "NEWER")))
      (should-error
       (cl-letf (((symbol-function 'rename-file)
                  (lambda (&rest _args) (error "simulated rename failure"))))
         (supertag--persistence-write-store-atomically supertag-db-file)))
      (should (equal original-bytes
                     (supertag-hardening-test--read-file-bytes supertag-db-file)))
      (should (null (supertag-hardening-test--tmp-residues
                     (file-name-directory supertag-db-file)))))))

(ert-deftest supertag-hardening-test-verify-mismatch-aborts-save ()
  "A post-write verification mismatch aborts the save and keeps the old DB."
  (supertag-hardening-test--with-temp-env
    (supertag-persistence-ensure-data-directory)
    (supertag-hardening-test--write-store-file
     supertag-db-file (supertag-hardening-test--make-store '("OLD")))
    (let ((original-bytes (supertag-hardening-test--read-file-bytes supertag-db-file)))
      (setq supertag--store (supertag-hardening-test--make-store '("OLD" "NEW")))
      (let ((real-read (symbol-function 'supertag--persistence--try-read-store)))
        ;; Simulate a readable temp file that silently lost its node collection.
        (should-error
         (cl-letf (((symbol-function 'supertag--persistence--try-read-store)
                    (lambda (file)
                      (let ((loaded (funcall real-read file)))
                        (remhash :nodes loaded)
                        loaded))))
           (supertag--persistence-write-store-atomically supertag-db-file))))
      (should (equal original-bytes
                     (supertag-hardening-test--read-file-bytes supertag-db-file)))
      (should (null (supertag-hardening-test--tmp-residues
                     (file-name-directory supertag-db-file)))))))

(ert-deftest supertag-hardening-test-durable-roots-are-declared ()
  "Every currently persisted root is created by the Store contract."
  (dolist (collection '(:automations :sync-conflicts))
    (should (memq collection supertag--store-collections)))
  (let ((supertag--store nil))
    (supertag--ensure-store)
    (dolist (collection supertag--store-collections)
      (should (hash-table-p (gethash collection supertag--store))))))

(ert-deftest supertag-hardening-test-verify-detects-durable-collection-loss ()
  "Save verification rejects loss of any populated durable collection."
  (supertag-hardening-test--with-temp-env
    (supertag-persistence-ensure-data-directory)
    (let* ((vault (expand-file-name "vault" supertag-data-directory))
           (files (supertag-ownership-test-create-vault vault))
           (real-read (symbol-function 'supertag--persistence--try-read-store)))
      (dolist (collection '(:tags
                            :relations
                            :field-definitions
                            :tag-field-associations
                            :field-values
                            :boards
                            :automations
                            :sync-conflicts))
        (supertag-hardening-test--write-store-file
         supertag-db-file (supertag-hardening-test--make-store '("OLD")))
        (let ((original-bytes
               (supertag-hardening-test--read-file-bytes supertag-db-file)))
          (supertag-ownership-test-populate-store files)
          (supertag-store-put-entity
           :sync-conflicts "ownership-conflict"
           '(:id "ownership-conflict" :collection :tags :entity-id "project"
             :kind :field-conflict :key :name
             :ours "Project" :theirs "Projects"))
          (should-error
           (cl-letf (((symbol-function 'supertag--persistence--try-read-store)
                      (lambda (file)
                        (let ((loaded (funcall real-read file)))
                          (remhash collection loaded)
                          loaded))))
             (supertag--persistence-write-store-atomically supertag-db-file)))
          (should (equal original-bytes
                         (supertag-hardening-test--read-file-bytes
                          supertag-db-file))))))))

(ert-deftest supertag-hardening-test-durable-roundtrip-preserves-all-collections ()
  "A normal save/read round trip preserves every declared durable root."
  (supertag-hardening-test--with-temp-env
    (supertag-persistence-ensure-data-directory)
    (let* ((vault (expand-file-name "vault" supertag-data-directory))
           (files (supertag-ownership-test-create-vault vault)))
      (supertag-ownership-test-populate-store files)
      (supertag-store-put-entity
       :sync-conflicts "ownership-conflict"
       '(:id "ownership-conflict" :collection :tags :entity-id "project"
         :kind :field-conflict :key :name :ours "Project" :theirs "Projects"))
      (supertag--persistence-write-store-atomically supertag-db-file)
      (let ((loaded (supertag--persistence--try-read-store supertag-db-file)))
        (should-not
         (supertag--persistence--mismatched-durable-collections
          supertag--store loaded))))))

(ert-deftest supertag-hardening-test-verify-detects-same-count-content-change ()
  "Durable verification compares entity content, not only collection counts."
  (supertag-hardening-test--with-temp-env
    (supertag-persistence-ensure-data-directory)
    (let* ((vault (expand-file-name "vault" supertag-data-directory))
           (files (supertag-ownership-test-create-vault vault)))
      (supertag-ownership-test-populate-store files)
      (supertag--persistence-write-store-atomically supertag-db-file)
      (let* ((loaded (supertag--persistence--try-read-store supertag-db-file))
             (boards (gethash :boards loaded))
             (board (copy-sequence (gethash "ownership-board" boards))))
        (puthash "ownership-board" (plist-put board :title "Changed") boards)
        (should (equal '(:boards)
                       (supertag--persistence--mismatched-durable-collections
                        supertag--store loaded)))))))

;;; --- 2. Multi-instance locking ---

(ert-deftest supertag-hardening-test-lock-conflict-blocks-save ()
  "A foreign lock artifact is detected as a conflict and blocks saving."
  (supertag-hardening-test--with-temp-env
    (supertag-persistence-ensure-data-directory)
    (supertag-hardening-test--write-store-file
     supertag-db-file (supertag-hardening-test--make-store '("A")))
    (let* ((lock-file (supertag--db-lock-file-name supertag-db-file)))
      ;; Emacs advisory lock artifacts are dangling symlinks whose target
      ;; encodes "user@host.pid[:boot]"; not every filesystem supports
      ;; symlinks, so skip rather than fail when this one doesn't.
      (skip-unless
       (ignore-errors
         (make-symbolic-link "otheruser@otherhost.999999:12345" lock-file)
         t))
      (unwind-protect
          (progn
            (let ((owner (supertag--db-lock-status supertag-db-file)))
              (should (stringp owner))
              (supertag--db-acquire-lock)
              (should (equal supertag--db-lock-conflict owner))
              (let ((reasons (supertag--persistence-guard-violations)))
                (should (cl-find-if
                         (lambda (r)
                           (string-match-p "locked by another Emacs instance" r))
                         reasons)))))
        (ignore-errors (delete-file lock-file))))))

(ert-deftest supertag-hardening-test-lock-acquire-and-release-roundtrip ()
  "With no conflicting lock, acquire takes the lock and release frees it."
  (supertag-hardening-test--with-temp-env
    (supertag-persistence-ensure-data-directory)
    (supertag-hardening-test--write-store-file
     supertag-db-file (supertag-hardening-test--make-store '("A")))
    (should (null (supertag--db-lock-status supertag-db-file)))
    (supertag--db-acquire-lock)
    (should (null supertag--db-lock-conflict))
    (should (eq t (supertag--db-lock-status supertag-db-file)))
    (supertag--db-release-lock)
    (should (null (supertag--db-lock-status supertag-db-file)))
    (should (null supertag--db-locked-file))))

(ert-deftest supertag-hardening-test-network-lock-artifact-does-not-block-save ()
  "A stale DB-adjacent lock from a sync folder does not block local saves."
  (supertag-hardening-test--with-temp-env
    (supertag-persistence-ensure-data-directory)
    (supertag-hardening-test--write-store-file
     supertag-db-file
     (supertag-hardening-test--make-store '("A") supertag-data-version))
    (let ((stale-lock (expand-file-name
                       (concat ".#" (file-name-nondirectory supertag-db-file))
                       (file-name-directory supertag-db-file))))
      (skip-unless
       (ignore-errors
         (make-symbolic-link "otheruser@otherhost.999999:12345" stale-lock)
         t))
      (unwind-protect
          (cl-letf (((symbol-function 'supertag--persistence--expected-sync-state-file)
                     (lambda () nil)))
            (supertag-load-store)
            (should-not supertag--db-lock-conflict)
            (should-not (equal stale-lock
                                (supertag--db-lock-file-name supertag-db-file)))
            (let* ((nodes (supertag-store-get-collection :nodes))
                   (node (gethash "A" nodes)))
              (puthash "A" (plist-put node :title "new") nodes))
            (supertag-mark-dirty)
            (supertag-save-store)
            (should-not (supertag-dirty-p))
            (let* ((on-disk (supertag--persistence--try-read-store supertag-db-file))
                   (node (gethash "A" (gethash :nodes on-disk))))
              (should (equal "new" (plist-get node :title))))
            (should (file-symlink-p stale-lock))
            (should (eq t (supertag--db-lock-status supertag-db-file))))
        (ignore-errors (delete-file stale-lock))))))

;;; --- 3. Auto-migration ---

(ert-deftest supertag-hardening-test-auto-migrate-stamps-version-and-snapshots-once ()
  "Loading a stale store auto-migrates it once and snapshots exactly once."
  (supertag-hardening-test--with-temp-env
    (supertag-hardening-test--write-store-file
     supertag-db-file
     (supertag-hardening-test--make-store '("A") "4.0.0"))
    ;; The generic save guard also refuses to save when it thinks the
    ;; sync-state layer hasn't been loaded for this vault (a check that is
    ;; unrelated to migration itself, and always fires in an isolated test
    ;; that never loads the sync module). Neutralize just that unrelated
    ;; guard so this test can observe auto-migration's own behavior: that
    ;; the migrated store is actually persisted to disk.
    (cl-letf (((symbol-function 'supertag--persistence--expected-sync-state-file)
               (lambda () nil)))
      (supertag-load-store)
      (should (equal (gethash :version supertag--store) supertag-data-version))
      (let ((snapshots (directory-files supertag-db-backup-directory nil "premigrate")))
        (should (= 1 (length snapshots))))
      ;; The migrated version must actually have been persisted to disk,
      ;; otherwise every subsequent load would re-run the migration.
      (let* ((on-disk (supertag--persistence--try-read-store supertag-db-file)))
        (should (equal (gethash :version on-disk) supertag-data-version)))
      (supertag-load-store)
      (should (equal (gethash :version supertag--store) supertag-data-version))
      (let ((snapshots (directory-files supertag-db-backup-directory nil "premigrate")))
        (should (= 1 (length snapshots)))))))

(ert-deftest supertag-hardening-test-auto-migrate-disabled-leaves-version ()
  "With auto-migrate disabled, the stale version is left as-is on load."
  (supertag-hardening-test--with-temp-env
    (let ((supertag-db-auto-migrate nil))
      (supertag-hardening-test--write-store-file
       supertag-db-file
       (supertag-hardening-test--make-store '("A") "4.0.0"))
      (supertag-load-store)
      (should (equal (gethash :version supertag--store) "4.0.0"))
      (let ((snapshots (and (file-directory-p supertag-db-backup-directory)
                             (directory-files supertag-db-backup-directory nil "premigrate"))))
        (should (= 0 (length snapshots)))))))

;;; --- 4. Doctor ---

(ert-deftest supertag-hardening-test-doctor-batch-report-renders-sections ()
  "`supertag-doctor' in report-only mode renders all seven report sections."
  (supertag-hardening-test--with-temp-env
    (setq supertag--store (supertag-hardening-test--make-store '("A")))
    (let* ((buf (supertag-doctor t))
           (text (with-current-buffer buf (buffer-string))))
      (should (string-match-p "1\\. Database Files" text))
      (should (string-match-p "2\\. Guards" text))
      (should (string-match-p "3\\. Lock" text))
      (should (string-match-p "4\\. Version" text))
      (should (string-match-p "5\\. Integrity" text))
      (should (string-match-p "6\\. Backups" text))
      (should (string-match-p "7\\. Presence" text)))))

;;; --- 5. Cross-machine presence (advisory) ---

(defun supertag-hardening-test--write-presence-file (host seconds-ago &optional pid)
  "Write a presence JSON file for HOST whose `updatedAt' is SECONDS-AGO in the past.
Mirrors the on-disk shape written by `supertag--presence-write', without
depending on it, so these tests can independently pin down the exact
timestamp under test. Returns the presence file path."
  (let* ((file (supertag--presence-file))
         (ts (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                                  (time-subtract (current-time) (seconds-to-time seconds-ago))
                                  t)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (json-encode (list (cons 'host host)
                                  (cons 'updatedAt ts)
                                  (cons 'pid (or pid 12345))))))
    file))

(ert-deftest supertag-hardening-test-presence-foreign-fresh-is-active ()
  "A foreign host's presence written moments ago is reported as active."
  (supertag-hardening-test--with-temp-env
    (supertag-hardening-test--write-presence-file "other-machine" 5)
    (let ((foreign (supertag--presence-foreign-active-p)))
      (should (equal foreign "other-machine")))
    ;; Guard-style check: callers branch on truthiness of the return value.
    (should (if (supertag--presence-foreign-active-p) t nil))))

(ert-deftest supertag-hardening-test-presence-foreign-stale-is-nil ()
  "A foreign host's presence written 10 minutes ago is stale, not active."
  (supertag-hardening-test--with-temp-env
    (supertag-hardening-test--write-presence-file "other-machine" 600)
    (should (null (supertag--presence-foreign-active-p)))))

(ert-deftest supertag-hardening-test-presence-own-host-is-nil ()
  "This host's own (fresh) presence claim never counts as foreign."
  (supertag-hardening-test--with-temp-env
    (supertag-hardening-test--write-presence-file (system-name) 5)
    (should (null (supertag--presence-foreign-active-p)))))

(ert-deftest supertag-hardening-test-presence-write-creates-valid-json ()
  "`supertag--presence-write' produces a parseable file naming this host."
  (supertag-hardening-test--with-temp-env
    (supertag-persistence-ensure-data-directory)
    (supertag--presence-write)
    (let ((file (supertag--presence-file)))
      (should (file-exists-p file))
      (let* ((data (json-read-file file))
             (host (cdr (assq 'host data)))
             (updated-at (cdr (assq 'updatedAt data))))
        (should (equal host (system-name)))
        (should (stringp updated-at))
        (should (ignore-errors (parse-iso8601-time-string updated-at)))))))

(ert-deftest supertag-hardening-test-presence-write-is-atomic ()
  "`supertag--presence-write' leaves no `.tmp' residue next to the DB file."
  (supertag-hardening-test--with-temp-env
    (supertag-persistence-ensure-data-directory)
    (supertag--presence-write)
    (should (null (supertag-hardening-test--tmp-residues
                   (file-name-directory (supertag--presence-file)))))))

;;; --- Missing database with surviving backups ---

(defvar supertag-sync--state-source)
(defvar supertag-sync-state-file)

(defun supertag-hardening-test--seed-backup-snapshot ()
  "Write one valid daily snapshot into the backup directory.
Returns the snapshot's file name."
  (let ((snapshot (expand-file-name "supertag-db-2026-08-30.el"
                                    supertag-db-backup-directory)))
    (supertag-hardening-test--write-store-file
     snapshot (supertag-hardening-test--make-store '("REAL")))
    snapshot))

(ert-deftest supertag-hardening-test-missing-db-with-backups-blocks-save ()
  "A missing DB with surviving backups must not run as a fresh vault."
  (supertag-hardening-test--with-temp-env
    (supertag-hardening-test--seed-backup-snapshot)
    (supertag-load-store)
    (should (eq (plist-get supertag--store-origin :status)
                :missing-with-backups))
    ;; Even after the user creates new content, saving stays blocked so
    ;; the deleted database cannot be replaced by this empty store.
    ;; Interactive saves refuse loudly; timer-driven saves skip silently.
    (setq supertag--store (supertag-hardening-test--make-store '("NEW")))
    (should-error (call-interactively #'supertag-save-store)
                  :type 'user-error)
    (supertag-save-store)
    (should-not (file-exists-p supertag-db-file))))

(ert-deftest supertag-hardening-test-accept-fresh-store-unblocks-save ()
  "Explicitly accepting a fresh store lifts the missing-DB guard."
  (supertag-hardening-test--with-temp-env
    ;; The sync-state guard is out of scope here; satisfy it the way a
    ;; fully initialized session would.  Bind the sync vars around the
    ;; WHOLE flow so the origin recorded at accept time matches the
    ;; values seen at save time, whether or not the sync module happens
    ;; to be loaded by other test files in the same batch.
    (let* ((state (supertag--persistence--expected-sync-state-file))
           (supertag-sync-state-file state)
           (supertag-sync--state-source state)
           (snapshot (supertag-hardening-test--seed-backup-snapshot)))
      (supertag-load-store)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (supertag-accept-fresh-store))
      (should (eq (plist-get supertag--store-origin :status) :new))
      (setq supertag--store (supertag-hardening-test--make-store '("NEW")))
      (supertag-mark-dirty)
      (supertag-save-store)
      (should (file-exists-p supertag-db-file))
      ;; Accepting a fresh start never touches the snapshots themselves.
      (should (file-exists-p snapshot)))))

(ert-deftest supertag-hardening-test-accept-fresh-store-requires-guard ()
  "The accept command refuses to run when nothing is blocked."
  (supertag-hardening-test--with-temp-env
    (supertag-load-store)
    (should (eq (plist-get supertag--store-origin :status) :new))
    (should-error (supertag-accept-fresh-store) :type 'user-error)))

(ert-deftest supertag-hardening-test-fresh-vault-without-backups-stays-new ()
  "A genuinely fresh vault still loads and saves without friction."
  (supertag-hardening-test--with-temp-env
    (supertag-load-store)
    (should (eq (plist-get supertag--store-origin :status) :new))
    (should-not (cl-find-if (lambda (reason)
                              (string-match-p "last load status" reason))
                            (supertag--persistence-guard-violations)))))

(ert-deftest supertag-hardening-test-recovery-state-blocks-backup-rotation ()
  "Backup rotation must not shrink the recovery window while blocked."
  (supertag-hardening-test--with-temp-env
    (let ((snapshot (supertag-hardening-test--seed-backup-snapshot))
          (supertag-db-backup-keep-days 1)
          (old-time (time-subtract (current-time) (days-to-time 30))))
      ;; Make the only snapshot old enough that rotation would delete it.
      (set-file-times snapshot old-time)
      (supertag-load-store)
      (should (eq (plist-get supertag--store-origin :status)
                  :missing-with-backups))
      (supertag-cleanup-old-backups)
      (should (file-exists-p snapshot))
      ;; After explicitly accepting a fresh store, rotation resumes.
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (supertag-accept-fresh-store))
      (supertag-cleanup-old-backups)
      (should-not (file-exists-p snapshot)))))

(ert-deftest supertag-hardening-test-accept-fresh-refuses-reappeared-db ()
  "A database restored behind our back must be loaded, not overwritten."
  (supertag-hardening-test--with-temp-env
    (supertag-hardening-test--seed-backup-snapshot)
    (supertag-load-store)
    (should (eq (plist-get supertag--store-origin :status)
                :missing-with-backups))
    ;; A file sync or git checkout brings the database back.
    (supertag-hardening-test--write-store-file
     supertag-db-file (supertag-hardening-test--make-store '("RESTORED")))
    (should-error (supertag-accept-fresh-store) :type 'user-error)))

(ert-deftest supertag-hardening-test-unreadable-db-degrades-to-failed ()
  "An existing but unreadable database is broken, not a fresh vault."
  (skip-unless (not (zerop (user-uid)))) ; root ignores file modes
  (supertag-hardening-test--with-temp-env
    (supertag-hardening-test--write-store-file
     supertag-db-file (supertag-hardening-test--make-store '("REAL")))
    (set-file-modes supertag-db-file 0)
    (unwind-protect
        (progn
          (supertag-load-store)
          (should (eq (plist-get supertag--store-origin :status) :failed)))
      (set-file-modes supertag-db-file #o600))))

(ert-deftest supertag-hardening-test-doctor-reports-recovery-section ()
  "The doctor report explains recovery when the database is missing."
  (supertag-hardening-test--with-temp-env
    (supertag-hardening-test--seed-backup-snapshot)
    (supertag-load-store)
    (let ((buf (supertag-doctor t)))
      (with-current-buffer buf
        (should (string-match-p "Recovery needed" (buffer-string)))
        (should (string-match-p "supertag-restore" (buffer-string)))
        (should (string-match-p "supertag-accept-fresh-store"
                                (buffer-string)))))))

(provide 'persistence-hardening-test)

;;; persistence-hardening-test.el ends here
