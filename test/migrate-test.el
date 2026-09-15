;;; migrate-test.el --- Version gated migration contracts -*- lexical-binding: t; -*-
(require 'document-fixture)
(require 'supertag-core-persistence)
(require 'supertag-migrate nil t)

(ert-deftest supertag-migrate-seven-gate-and-commands ()
  (should (equal supertag-data-version "7.2.0"))
  (dolist (f '(supertag-migrate-run supertag-migrate-status supertag-migrate-preview supertag-migrate-apply))
    (should (commandp f))))

(defun supertag-migrate-test-old-store (file)
  "Build a synthetic 6.1 Store with all retired source shapes."
  (let ((store (make-hash-table :test 'equal)))
    (dolist (key '(:nodes :tags :relations :fields :field-values :field-definitions :field-provenance :tag-field-associations))
      (puthash key (make-hash-table :test 'equal) store))
    (puthash :version "6.1.0" store)
    (puthash :unknown-root '(:sentinel "retained") store)
    (puthash "document-node" (list :id "document-node" :type :node :title "Node" :level 1
                                   :file-path file :pos 1 :fields '("embedded" 11)
                                   :field-values '("embedded-new" 12)) (gethash :nodes store))
    (puthash "invalid" '(:id "invalid" :type :node) (gethash :nodes store))
    (dolist (tag '(("parent" . (:id "parent" :name "Parent"))
                   ("child" . (:id "child" :name "Child" :extends "parent"))
                   ("missing" . (:id "missing" :name "Missing" :extends "absent"))
                   ("cycle-a" . (:id "cycle-a" :name "A" :extends "cycle-b"))
                   ("cycle-b" . (:id "cycle-b" :name "B" :extends "cycle-a"))
                   ("dup1" . (:id "dup1" :name "Duplicate")) ("dup2" . (:id "dup2" :name "Duplicate"))
                   ("ghost" . nil)))
      (puthash (car tag) (cdr tag) (gethash :tags store)))
    (puthash "document-node" '("child" ("legacy" "nested value")) (gethash :fields store))
    (puthash "status" '(:name "STATUS" :type :text) (gethash :field-definitions store))
    (puthash "document-node" '("status" "ready") (gethash :field-values store))
    (puthash "document-node" '("status" (:origin :human)) (gethash :field-provenance store))
    (puthash "document-node" '(("status" (:origin :human))
                                ("missing-value-field" (:origin :human)))
             (gethash :field-provenance store))
    (puthash "child" '((:field-id "status")) (gethash :tag-field-associations store))
    (puthash "nt" '(:type :node-tag :from "document-node" :to "child") (gethash :relations store))
    store))

(defun supertag-migrate-test-write-old (store)
  (make-directory (file-name-directory supertag-db-file) t)
  (with-temp-file supertag-db-file
    (let ((print-circle t) (print-length nil) (print-level nil)) (prin1 store (current-buffer)))))

(ert-deftest supertag-migrate-normalizes-string-extends-idempotently ()
  (let ((store (make-hash-table :test 'equal)))
    (puthash :tags (make-hash-table :test 'equal) store)
    (puthash "parent" '(:id "parent" :name "Parent") (gethash :tags store))
    (puthash "child" '(:id "child" :name "Child" :extends "parent") (gethash :tags store))
    (puthash "root" '(:id "root" :name "Root") (gethash :tags store))
    (puthash "multi" '(:id "multi" :name "Multi" :extends ("parent" "root"))
             (gethash :tags store))
    (should (supertag-migrate--normalize-extends-lists store))
    (should (equal '("parent") (plist-get (gethash "child" (gethash :tags store)) :extends)))
    (should-not (plist-get (gethash "root" (gethash :tags store)) :extends))
    (should (equal '("parent" "root")
                   (plist-get (gethash "multi" (gethash :tags store)) :extends)))
    ;; One-element lists stay one-element lists: the step is idempotent.
    (should-not (supertag-migrate--normalize-extends-lists store))
    (should (equal '("parent") (plist-get (gethash "child" (gethash :tags store)) :extends)))))

(ert-deftest supertag-migrate-load-extracts-before-retiring-and-exports ()
  (supertag-document-test-with-vault
    (let* ((supertag-db-auto-migrate t)
           (old (supertag-migrate-test-old-store file))
           (step (symbol-function 'supertag-migrate--db-steps))
           (supertag-migrate--last-snapshot nil))
      (supertag-migrate-test-write-old old)
      (let ((bytes (supertag-migrate--bytes supertag-db-file)))
        (cl-letf (((symbol-function 'supertag-migrate--db-steps)
                   (lambda (store)
                     (should (equal "6.1.0" (gethash :version store)))
                     (should (equal bytes (supertag-migrate--bytes supertag-migrate--last-snapshot)))
                     (funcall step store)
                     (should (equal "6.1.0" (gethash :version store))))))
          (supertag-load-store))
        (should (equal "7.2.0" (gethash :version supertag--store)))
        (should-not (equal bytes (supertag-migrate--bytes supertag-db-file))))
      (dolist (key supertag-migrate--field-roots)
        (should (eq 'absent (gethash key supertag--store 'absent))))
      (should (equal (gethash :unknown-root supertag--store) '(:sentinel "retained")))
      (should (eq 'absent (gethash "ghost" (gethash :tags supertag--store) 'absent)))
      (should-not (gethash "nt" (gethash :relations supertag--store)))
      (let ((entries (gethash :legacy-fields supertag--store)))
        (should (= 6 (length entries)))
        (let ((missing (cl-find-if
                        (lambda (e) (and (equal (plist-get e :node) "document-node")
                                         (equal (plist-get e :name) "missing-value-field")
                                         (eq (plist-get e :kind) :provenance)))
                        entries)))
          (should missing)
          (should (equal (car (plist-get missing :raw)) '(:origin :human))))
        (should (equal '(association embedded embedded global global root)
                       (sort (mapcar (lambda (e) (plist-get e :source)) entries)
                             (lambda (a b) (string< (symbol-name a) (symbol-name b)))))))
      ;; "child" already carried `:extends "parent"' directly (pre-S1-style
      ;; fixture data): `supertag-migrate--apply-legacy-extends' recognizes
      ;; that as already-applied and drops the bookkeeping record without
      ;; rewriting anything.
      (should (equal (list "parent") (plist-get (supertag-tag-get "child") :extends)))
      (let ((paths (gethash :legacy-extends supertag--store)))
        (should-not (gethash "child" paths))
        (dolist (id '("missing" "cycle-a" "cycle-b"))
          (should (plist-get (gethash id paths) :conflict))))
      (let ((report (supertag-migrate-status)))
        (should (assoc "Duplicate" (plist-get report :duplicates)))
        (should (member "invalid" (plist-get report :invalid-nodes))))
      (let ((report (supertag-migrate-preview)))
        (should (= 4 (plist-get report :write-count)))
        (with-current-buffer "*Supertag Field Migration*"
          (dolist (source '("root node=" "global node=" "embedded node="))
            (should (string-match-p source (buffer-string))))))
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-max)) (insert "UNSAVED DRAFT\n"))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (supertag-migrate-apply))
      (with-temp-buffer
        (insert-file-contents file) (org-mode) (goto-char (point-min))
        (should (equal "nested value" (org-entry-get nil "LEGACY")))
        (should (equal "ready" (org-entry-get nil "STATUS")))
        (should (equal "11" (org-entry-get nil "EMBEDDED")))
        (should (search-forward "UNSAVED DRAFT" nil t)))
      ;; Association metadata has no node value to export and remains explicit.
      (should (= 2 (length (gethash :legacy-fields supertag--store))))
      (should (= 0 (plist-get (supertag-migrate-preview) :write-count)))
      (let ((bytes (supertag-migrate--bytes supertag-db-file)))
        (supertag-load-store)
        (should (equal bytes (supertag-migrate--bytes supertag-db-file)))))))

(ert-deftest supertag-migrate-failure-matrix-preserves-original ()
  (dolist (failure '(snapshot-copy snapshot-bytes middle save disabled unsupported))
    (supertag-document-test-with-vault
      (let* ((supertag-db-auto-migrate (not (eq failure 'disabled)))
             (old (supertag-migrate-test-old-store file))
             (copy (symbol-function 'copy-file))
             (step (symbol-function 'supertag-migrate--db-steps))
             (save (symbol-function 'supertag-save-store))
             (supertag-migrate--last-error nil))
        (when (eq failure 'unsupported) (puthash :version "4.0.0" old))
        (supertag-migrate-test-write-old old)
        (let ((bytes (supertag-migrate--bytes supertag-db-file)))
          (cl-letf (((symbol-function 'copy-file)
                     (lambda (from to &rest args)
                       (cond ((eq failure 'snapshot-copy) (error "Injected copy failure"))
                             ((eq failure 'snapshot-bytes) (with-temp-file to (insert "wrong")))
                             (t (apply copy from to args)))))
                    ((symbol-function 'supertag-migrate--db-steps)
                     (lambda (store) (funcall step store)
                       (when (eq failure 'middle) (error "Injected mid migration"))))
                    ((symbol-function 'supertag-save-store)
                     (lambda (&rest args)
                       (if (eq failure 'save) nil (apply save args)))))
            (supertag-load-store))
          (should (equal bytes (supertag-migrate--bytes supertag-db-file)))
          (should (equal (gethash :version old) (gethash :version supertag--store)))
          (should-not (supertag-dirty-p))
          (should (gethash :fields supertag--store))
          (should (gethash "nt" (gethash :relations supertag--store)))
          (let ((expected (let ((supertag--store (supertag--coerce-store-table
                                                (supertag--persistence--try-read-store supertag-db-file))))
                            (supertag--ensure-store) supertag--store)))
            (should (equal (with-temp-buffer
                             (supertag--persistence--write-canonical-store expected (current-buffer))
                             (buffer-string))
                           (with-temp-buffer
                             (supertag--persistence--write-canonical-store supertag--store (current-buffer))
                             (buffer-string)))))
          (unless (eq failure 'disabled) (should supertag-migrate--last-error)))))))

(ert-deftest supertag-migrate-snapshot-reuse-compares-bytes ()
  (supertag-document-test-with-vault
    (supertag-migrate-test-write-old (supertag-migrate-test-old-store file))
    (let* ((first (supertag-migrate--snapshot "6.1.0"))
           (bytes (supertag-migrate--bytes first)))
      (should (equal first (supertag-migrate--snapshot "6.1.0")))
      (with-temp-file supertag-db-file (insert bytes "\n"))
      (let ((second (supertag-migrate--snapshot "6.1.0")))
        (should-not (equal first second))
        (should (equal bytes (supertag-migrate--bytes first)))
        (should (equal (supertag-migrate--bytes supertag-db-file) (supertag-migrate--bytes second)))))))

(ert-deftest supertag-migrate-unknown-field-value-remains-raw ()
  (supertag-document-test-with-vault
    (let* ((old (supertag-migrate-test-old-store file))
           (raw (make-hash-table :test 'equal)))
      (puthash "x" [1 2 3] raw)
      (puthash "document-node" (list "opaque" raw) (gethash :field-values old))
      (supertag-migrate--extract-fields old)
      (let ((entry (cl-find-if (lambda (e) (equal "opaque" (plist-get e :name)))
                               (gethash :legacy-fields old))))
        (should (eq raw (plist-get entry :raw)))
        (should-not (plist-member entry :value))))))

(ert-deftest supertag-migrate-save-verifies-pending-records-and-version ()
  (dolist (key '(:legacy-fields :legacy-extends :version))
    (supertag-document-test-with-vault
      (let ((supertag-db-auto-migrate t)
            (reader (symbol-function 'supertag--persistence--try-read-store)))
        (supertag-migrate-test-write-old (supertag-migrate-test-old-store file))
        (let ((bytes (supertag-migrate--bytes supertag-db-file)))
          (cl-letf (((symbol-function 'supertag--persistence--try-read-store)
                     (lambda (path)
                       (let ((store (funcall reader path)))
                         (when (equal (gethash :version store) "7.2.0") (remhash key store))
                         store))))
            (supertag-load-store))
          (should (equal bytes (supertag-migrate--bytes supertag-db-file)))
          (should (equal "6.1.0" (gethash :version supertag--store)))
          (should-not (supertag-dirty-p)))))))
(provide 'migrate-test)



(ert-deftest supertag-migrate-pending-fields-protect-tag-from-orphan-cleanup ()
  (supertag-document-test-with-vault
    (puthash "pending" '(:id "pending" :name "Pending") (gethash :tags supertag--store))
    (puthash :legacy-fields '((:tag "pending" :source association :raw unknown)) supertag--store)
    (should-not (member "pending" (supertag-tag-orphaned-ids)))
    (should-error (supertag-tag-delete-orphans '("pending")) :type 'user-error)))

(ert-deftest supertag-migrate-notice-only-on-successful-version-transition ()
  (supertag-document-test-with-vault
    (let ((supertag-db-auto-migrate t) messages)
      (supertag-migrate-test-write-old (supertag-migrate-test-old-store file))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (supertag-load-store)
        (supertag-load-store)
        (supertag-migrate-run))
      (should (= 1 (cl-count-if (lambda (s) (string-match-p "项旧字段/.*个子标签待导出" s)) messages))))))

(defun supertag-migrate-test-hierarchy-store (file)
  "Build a synthetic 6.1 Store whose `:legacy-extends' covers every
disposition `supertag-migrate--apply-legacy-extends' must handle: a name
key, a stable-ID key, a multi-level chain (parents appearing after their
children), a missing parent, a self cycle, and a child that already carries
the identical `:extends'.  FILE anchors one live node so the post-migration
save is not treated as an empty-store protective skip."
  (let ((store (make-hash-table :test 'equal)))
    (dolist (key '(:nodes :tags :relations :fields :field-values :field-definitions
                   :field-provenance :tag-field-associations))
      (puthash key (make-hash-table :test 'equal) store))
    (puthash :version "6.1.0" store)
    (puthash "document-node" (list :id "document-node" :type :node :title "Node" :level 1
                                   :file-path file :pos 1) (gethash :nodes store))
    (dolist (tag '(("media" . (:id "media" :name "Media"))
                   ("book" . (:id "book" :name "Book"))
                   ("tag-a141a8e8edfa4ecc9b10c8cf5f48422c" .
                    (:id "tag-a141a8e8edfa4ecc9b10c8cf5f48422c" :name "Textbook"))
                   ("prj" . (:id "prj" :name "Prj"))
                   ("task" . (:id "task" :name "Task"))
                   ("issue" . (:id "issue" :name "Issue"))
                   ("orphan" . (:id "orphan" :name "Orphan"))
                   ("cycle-x" . (:id "cycle-x" :name "Loop"))
                   ("ready" . (:id "ready" :name "Ready" :extends "media"))))
      (puthash (car tag) (cdr tag) (gethash :tags store)))
    (let ((pending (make-hash-table :test 'equal)))
      ;; A name key, resolved against an existing root.
      (puthash "book" '(:parent "media" :path "media/book") pending)
      ;; A stable-ID key, resolved by direct entity ID.
      (puthash "tag-a141a8e8edfa4ecc9b10c8cf5f48422c"
               '(:parent "book" :path "media/book/Textbook") pending)
      ;; A three-level chain; "task"'s own record appears before "prj"'s in
      ;; the hash, but resolution must not depend on hash iteration order.
      (puthash "task" '(:parent "prj" :path "media/prj/task") pending)
      (puthash "issue" '(:parent "task" :path "media/prj/task/issue") pending)
      (puthash "prj" '(:parent "media" :path "media/prj") pending)
      ;; A parent that does not exist.
      (puthash "orphan" '(:parent "ghost-parent" :path "ghost-parent/orphan") pending)
      ;; A self cycle.
      (puthash "cycle-x" '(:parent "Loop" :path "Loop/Loop") pending)
      ;; A child whose Tag entity already carries the identical `:extends'.
      (puthash "ready" '(:parent "media" :path "media/ready") pending)
      (puthash :legacy-extends pending store))
    store))

(ert-deftest supertag-migrate-run-resolves-legacy-extends-hierarchy ()
  (supertag-document-test-with-vault
    (let ((supertag-db-auto-migrate t) (disk (supertag-document-test-disk file)))
      (supertag-migrate-test-write-old (supertag-migrate-test-hierarchy-store file))
      (supertag-load-store)
      (should (equal "7.2.0" (gethash :version supertag--store)))
      (should (equal disk (supertag-document-test-disk file)))
      ;; Every resolvable record is written straight onto the Tag entity.
      (should (equal (list "media") (plist-get (supertag-tag-get "book") :extends)))
      (should (equal (list "book")
                     (plist-get
                      (supertag-tag-get "tag-a141a8e8edfa4ecc9b10c8cf5f48422c") :extends)))
      (should (equal (list "media") (plist-get (supertag-tag-get "prj") :extends)))
      (should (equal (list "prj") (plist-get (supertag-tag-get "task") :extends)))
      (should (equal (list "task") (plist-get (supertag-tag-get "issue") :extends)))
      (should (equal (list "media") (plist-get (supertag-tag-get "ready") :extends)))
      (let ((pending (gethash :legacy-extends supertag--store)))
        (should (= 2 (hash-table-count pending)))
        (should (equal "Missing parent tag" (plist-get (gethash "orphan" pending) :conflict)))
        (should (equal "Would create an :extends cycle"
                       (plist-get (gethash "cycle-x" pending) :conflict))))
      (let ((report (supertag-migrate-status)))
        (should (= 2 (hash-table-count (plist-get report :unresolved-extends)))))
      (should (equal (sort (list "book" "tag-a141a8e8edfa4ecc9b10c8cf5f48422c" "prj" "task" "issue" "ready")
                           #'string<)
                     (sort (supertag-tag-descendants "media") #'string<)))
      ;; Re-running is a no-op: `supertag-migrate-run' short-circuits once at
      ;; the target version, and a direct re-application of the resolver
      ;; changes nothing (the two remaining records recompute the identical
      ;; conflict reason), so neither writes to disk.
      (let ((bytes (supertag-migrate--bytes supertag-db-file)))
        (should (supertag-migrate-run))
        (should (equal bytes (supertag-migrate--bytes supertag-db-file)))
        (should-not (supertag-migrate--apply-legacy-extends supertag--store))
        (should (equal bytes (supertag-migrate--bytes supertag-db-file)))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (supertag-migrate-apply))
        (should (equal bytes (supertag-migrate--bytes supertag-db-file)))))))

;;; V2-ORG-A: independent source/compiled loading and shared writer controls.
(defconst supertag-migrate-test--orga-root
  (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))
(defconst supertag-migrate-test--orga-program ";;; -*- lexical-binding: t; -*-\n(require 'ert)\n(require 'cl-lib)\n(require 'subr-x)\n(setq user-emacs-directory (file-name-as-directory (getenv \"OA_TMP\"))\n      default-directory user-emacs-directory after-init-time nil\n      supertag-data-directory (expand-file-name \"data/\" user-emacs-directory)\n      supertag--base-data-directory supertag-data-directory\n      supertag-db-file (expand-file-name \"store.el\" supertag-data-directory)\n      supertag-db-backup-directory (expand-file-name \"backups/\" supertag-data-directory)\n      supertag-sync-state-file (expand-file-name \"sync.el\" user-emacs-directory)\n      supertag-sync--state-source supertag-sync-state-file\n      supertag-sync-directories (list user-emacs-directory)\n      supertag-active-sync-directory user-emacs-directory\n      supertag-file-id-source 'org-roam\n      org-id-locations-file (expand-file-name \"ids\" user-emacs-directory)\n      org-id-track-globally nil make-backup-files nil auto-save-default nil\n      supertag-view-style-auto-enable nil supertag-svg-tag-enable nil)\n(defun oa-before () (equal (getenv \"SUPERTAG_ORGA_STAGE\") \"before\"))\n(defun oa-file () (expand-file-name \"nodes.org\" user-emacs-directory))\n(defun oa-disk (file) (with-temp-buffer (insert-file-contents-literally file) (buffer-string)))\n(defun oa-sync-ready ()\n  (should (featurep 'supertag-services-sync))\n  (should (boundp 'supertag-sync--is-full-rescan-p))\n  (should (equal \"supertag-services-sync\" (file-name-base (symbol-file 'supertag-node-sync-current-buffer)))))\n(defun oa-load-org ()\n  (if (string-prefix-p \"elc-\" (getenv \"OA_CASE\"))\n      (progn\n        (load (expand-file-name \"supertag-service-org.elc\" (getenv \"OA_TREE\")) nil t t)\n        (should (string-suffix-p \".elc\" (symbol-file 'supertag-service-org--update-buffer-and-resync))))\n    (require 'supertag-service-org)))\n(defun oa-prepare ()\n  (require 'supertag-services-sync)\n  (supertag--ensure-store)\n  (supertag-tag-create '(:id \"base\" :name \"base\" :aliases (\"alias-base\")))\n  (with-temp-file (oa-file)\n    (insert \":PROPERTIES:\\n:ID: file-node\\n:END:\\n#+FILETAGS: :base:\\n* Alpha #base\\n:PROPERTIES:\\n:ID: oa-a\\n:AUTHOR: Ada\\n:END:\\nText.\\n* Beta #base\\n:PROPERTIES:\\n:ID: oa-b\\n:END:\\nOther.\\n\"))\n  (with-temp-file (expand-file-name \"plain.org\" user-emacs-directory) (insert \"* Plain\\nBody.\\n\"))\n  (should (eq 'complete (plist-get (supertag-reindex-org) :status)))\n  (dolist (id '(\"file-node\" \"oa-a\" \"oa-b\")) (should (supertag-node-get id)))\n  (with-temp-file (expand-file-name \"seed.el\" user-emacs-directory)\n    (let ((print-circle t) (print-length nil) (print-level nil)) (prin1 supertag--store (current-buffer))))\n  (princ \"ORGA-PREPARE real-reindex-three-nodes\\n\"))\n(defun oa-entry ()\n  (should-not (boundp 'supertag-sync--is-full-rescan-p))\n  (when (getenv \"OA_PRESET_NIL\") (setq supertag-org-id-find-auto-enable nil))\n  (oa-load-org)\n  (princ \"ORGA-ENTRY actual-ServiceOrg\\n\")\n  (should-not (featurep 'supertag))\n  (dolist (feature '(supertag-node supertag-tag supertag-services-sync supertag-query))\n    (should (eq (and (oa-before) (not (getenv \"OA_ENTRY_RED\"))) (not (null (featurep feature))))))\n  (if (oa-before) (should (boundp 'supertag-sync--is-full-rescan-p))\n    (should-not (boundp 'supertag-sync--is-full-rescan-p))\n    (dolist (row '((supertag-node-get \"supertag-node\") (supertag-node-delete \"supertag-node\")\n                   (supertag-service-org-follow-id \"supertag-node\")\n                   (supertag--mark-internal-modification \"supertag-services-sync\")\n                   (supertag--clear-internal-modification \"supertag-services-sync\")\n                   (supertag--render-org-headline \"supertag-services-sync\")\n                   (supertag-node-sync-current-buffer \"supertag-services-sync\")))\n      (let ((cell (symbol-function (car row))))\n        (should (autoloadp cell)) (should (equal (cadr cell) (cadr row))) (should-not (nth 4 cell)))))\n  (princ (format \"ORGA-ORG-ID-host=%S preset=%S\\n\" (fboundp 'org-id-find) supertag-org-id-find-auto-enable))\n  (should (fboundp 'org-id-find))\n  (should (eq (not (null supertag-org-id-find-auto-enable))\n              (not (null (advice-member-p #'supertag-service-org--org-id-find-advice 'org-id-find)))))\n  (supertag-enable-org-id-find-integration)\n  (should supertag-org-id-find-auto-enable)\n  (setq supertag--initialized t)\n  (let ((marker (org-id-find \"oa-a\" 'marker)))\n    (should (markerp marker))\n    (should (equal (buffer-file-name (marker-buffer marker)) (oa-file)))\n    (with-current-buffer (marker-buffer marker)\n      (save-excursion (goto-char marker) (should (equal \"oa-a\" (org-entry-get nil \"ID\"))))))\n  (supertag-disable-org-id-find-integration)\n  (should-not supertag-org-id-find-auto-enable)\n  (should-not (advice-member-p #'supertag-service-org--org-id-find-advice 'org-id-find))\n  ;; Real native advice on an existing service, no fabricated Org host.\n  (let ((calls 0))\n    (let ((watch (lambda (&rest _) (cl-incf calls))))\n      (advice-add 'supertag-service-org--with-node-buffer :before watch)\n      (unwind-protect\n          (let ((cell (symbol-function 'supertag-service-org--with-node-buffer)))\n            (require 'supertag-service-org)\n            (should (eq cell (symbol-function 'supertag-service-org--with-node-buffer)))\n            (supertag-service-org--with-node-buffer \"oa-a\" (lambda () (oa-sync-ready)))\n            (should (= calls 1)))\n        (advice-remove 'supertag-service-org--with-node-buffer watch)))))\n\n(defun oa-wrapper ()\n  (oa-load-org)\n  (let ((sync-before (featurep 'supertag-services-sync))\n        (facts (prin1-to-string supertag--store)) (disk (oa-disk (oa-file))) called)\n    (dolist (row '((\"absent\" nil) (\"no-file\" (:id \"no-file\" :level 1 :file \"/nonexistent/orga-source\"))\n                   (\"bad-location\" (:id \"bad-location\" :level 1))))\n      (when (cadr row)\n        (let ((node (copy-tree (cadr row))))\n          (unless (plist-get node :file) (setq node (plist-put node :file (oa-file))))\n          (puthash (car row) node (gethash :nodes supertag--store)))))\n    (dolist (id '(\"absent\" \"no-file\" \"bad-location\"))\n      (should-error (supertag-service-org--with-node-buffer id (lambda () (setq called t))) :type 'user-error))\n    (should-not called) (should (eq sync-before (featurep 'supertag-services-sync)))\n    (remhash \"no-file\" (gethash :nodes supertag--store)) (remhash \"bad-location\" (gethash :nodes supertag--store))\n    (supertag-service-org--with-node-buffer \"oa-a\"\n      (lambda ()\n        (princ \"ORGA-WRAPPER-CALLBACK no-parser\\n\") (oa-sync-ready)\n        (should-not supertag-sync--is-full-rescan-p)\n        (should (equal \"oa-a\" (org-entry-get nil \"ID\"))) (setq called (point))))\n    (should (integerp called))\n    (let ((value (supertag-service-org--with-node-buffer \"file-node\" (lambda () (point)))))\n      (princ (format \"ORGA-ACTUAL file-position=%s\\n\" value))\n      (should (= value (if (getenv \"OA_OUTPUT_RED\") 999 1))))\n    (should (equal facts (prin1-to-string supertag--store))) (should (equal disk (oa-disk (oa-file))))))\n(defun oa-repair (dirty)\n  (should-not (boundp 'supertag-sync--is-full-rescan-p))\n  ;; Separate preset cases; the four default cases never initialize this flag.\n  (when (string-suffix-p \"preset\" (getenv \"OA_CASE\"))\n    (set 'supertag-sync--is-full-rescan-p 'preset))\n  (oa-load-org)\n  (princ (format \"ORGA-ENTRY repair dirty=%S provider=%s\\n\" dirty (symbol-file 'supertag-service-org--update-buffer-and-resync)))\n  (let ((file (oa-file)) (save-count 0) (project-count 0) (sync-flags nil) (editor-flags nil))\n    (with-current-buffer (find-file-noselect file)\n      (when dirty (goto-char (point-max)) (insert \"Unsaved draft.\\n\")))\n    (let ((watch-save (lambda (&rest _) (when (equal (buffer-file-name) file) (cl-incf save-count))))\n          (watch-project (lambda (&rest _)\n                           (oa-sync-ready) (push supertag-sync--is-full-rescan-p sync-flags)\n                           (cl-incf project-count))))\n      (advice-add 'save-buffer :before watch-save)\n      (advice-add 'supertag-service-org--project-current-node :before watch-project)\n      (unwind-protect\n          (supertag-service-org--update-buffer-and-resync\n           \"oa-a\" (lambda ()\n                     (princ \"ORGA-REPAIR-EDITOR before-let\\n\") (oa-sync-ready)\n                     (push supertag-sync--is-full-rescan-p editor-flags)) t)\n        (advice-remove 'save-buffer watch-save)\n        (advice-remove 'supertag-service-org--project-current-node watch-project)))\n    (should (equal editor-flags\n                   (list (and (string-suffix-p \"preset\" (getenv \"OA_CASE\")) 'preset))))\n    (should (equal sync-flags '(t)))\n    (should (= project-count 1)) (should (= save-count (if dirty 1 0)))\n    (should (boundp 'supertag-sync--is-full-rescan-p))\n    (should (eq supertag-sync--is-full-rescan-p\n                (and (string-suffix-p \"preset\" (getenv \"OA_CASE\")) 'preset)))\n    ;; A subsequent actual parser/reconcile read observes the outer binding.\n    (with-current-buffer (find-file-noselect file)\n      (goto-char (point-min)) (search-forward \":ID: oa-a\") (org-back-to-heading t)\n      (supertag-node-sync-at-point)\n      (should (equal \"Ada\" (plist-get (plist-get (supertag-node-get \"oa-a\") :properties) :AUTHOR)))\n      (should-not (buffer-modified-p)))\n    (should (eq dirty (not (null (string-match-p \"Unsaved draft\" (oa-disk file))))))))\n(defun oa-tags ()\n  (require 'supertag-tag)\n  (unless (oa-before) (should-not (featurep 'supertag-services-sync)))\n  (let ((file (oa-file)))\n    (dolist (id '(\"oa-a\" \"file-node\"))\n      (supertag-service-org-add-tag id \"base\")\n      (oa-sync-ready)\n      (supertag-service-org-remove-tag id \"base\")\n      (supertag-service-org-add-tag id \"base\"))\n    (supertag-tag-create '(:id \"other\" :name \"other\"))\n    (supertag-service-org-replace-tag \"oa-b\" \"base\" \"other\")\n    (should (member \"other\" (plist-get (supertag-node-get \"oa-b\") :tags)))\n    (should (string-match-p \"#other\" (oa-disk file)))\n    (let* ((disk (oa-disk file)) (store (prin1-to-string supertag--store))\n           (rows (supertag-tag-change--collect \"other\")))\n      (should rows) (should (equal disk (oa-disk file))) (should (equal store (prin1-to-string supertag--store))))))\n(defun oa-bulk ()\n  (require 'supertag-tag)\n  (should-not (featurep 'supertag-services-sync))\n  (let ((file (oa-file)) (saves 0) (projects 0) (mutations 0) (parses 0) (resolved nil) new-id)\n    (let ((watch-create (lambda (&rest _)\n                          (princ \"ORGA-BULK-MUTATION before-tag-create\\n\")\n                          (oa-sync-ready) (should resolved) (cl-incf mutations)))\n          (watch-save (lambda (&rest _) (when (equal (buffer-file-name) file) (cl-incf saves)))))\n      (advice-add 'supertag-tag-create :before watch-create)\n      (advice-add 'save-buffer :before watch-save)\n      ;; Transparent loader advice observes real completion, not fboundp.\n      (cl-letf* ((original-load (symbol-function 'autoload-do-load))\n                 ((symbol-function 'autoload-do-load)\n                  (lambda (definition &rest rest)\n                    (prog1 (apply original-load definition rest)\n                      (when (and (featurep 'supertag-services-sync) (not resolved))\n                        (setq resolved t)\n                        (should (= parses 0)))))))\n        (let ((watch-project (lambda (&rest _) (cl-incf projects)))\n              (watch-parse (lambda (&rest _) (cl-incf parses))))\n          (advice-add 'supertag-service-org--project-current-node :before watch-project)\n          (advice-add 'supertag-sync--parse-file-header :before watch-parse)\n          (unwind-protect\n              (let ((ids (supertag-capture-add-tags-to-nodes '(\"oa-a\" \"oa-b\") '(\"alias-base\" \"new/path\"))))\n                (should (equal (car ids) \"base\"))\n                (setq new-id (cadr ids))\n                (should (supertag-tag-stable-id-p new-id))\n                (should (equal \"path\" (plist-get (supertag-tag-get new-id) :name)))\n                (should (equal (list (supertag-tag-resolve-occurrence \"new\"))\n                               (supertag-tag-parents new-id))))\n            (advice-remove 'supertag-service-org--project-current-node watch-project)\n            (advice-remove 'supertag-sync--parse-file-header watch-parse)\n            (advice-remove 'supertag-tag-create watch-create)\n            (advice-remove 'save-buffer watch-save)))))\n    (should resolved) (should (= mutations 2)) (should (= saves 2)) (should (= projects 2))\n    (dolist (id '(\"oa-a\" \"oa-b\")) (should (member new-id (plist-get (supertag-node-get id) :tags))))\n    (should (string-match-p \"#path\" (oa-disk file)))\n    (should-not (string-match-p \"#new/path\" (oa-disk file)))))\n(defun oa-load-failure (bypass)\n  (let ((disk (oa-disk (oa-file))) (facts (prin1-to-string supertag--store)))\n    (if (oa-before)\n        (progn (should (equal '(error \"ORGA injected Sync load failure\")\n                               (should-error (oa-load-org) :type 'error)))\n               (should-not (featurep 'supertag-service-org))\n               (princ \"ORGA-FAILURE before-require\\n\"))\n      (oa-load-org) (princ \"ORGA-ENTRY failure-current\\n\")\n      (if bypass\n          (let ((file (expand-file-name \"plain.org\" user-emacs-directory)))\n            (with-current-buffer (find-file-noselect file)\n              (goto-char (point-min))\n              (should (equal '(error \"ORGA injected Sync load failure\")\n                             (should-error (supertag-service-org-create-node-at-point) :type 'error)))\n              (let ((id (org-entry-get nil \"ID\")))\n                (should (stringp id)) (should-not (supertag-node-get id)))\n              (should (buffer-modified-p))\n              (should-not (string-match-p \":ID:\" (oa-disk file)))\n              (princ \"ORGA-FAILURE bypass-retained-ID-draft\\n\")))\n        (let (called)\n          (should-error (supertag-service-org--with-node-buffer \"missing\" (lambda () (setq called t))) :type 'user-error)\n          (should (equal '(error \"ORGA injected Sync load failure\")\n                         (should-error (supertag-service-org--with-node-buffer \"oa-a\" (lambda () (setq called t))) :type 'error)))\n          (should-not called) (princ \"ORGA-FAILURE current-after-valid-location\\n\"))))\n    (should (equal disk (oa-disk (oa-file)))) (should (equal facts (prin1-to-string supertag--store)))) )\n(defun oa-migrate ()\n  (should-not (featurep 'supertag-tag))\n  (require 'supertag-migrate)\n  (princ \"ORGA-ENTRY migrate\\n\")\n  ;; Direct fixture facts, no Tag creation before the first real status read.\n  (puthash \"bad id\" '(:id \"bad id\" :name \"Unstable\") (gethash :tags supertag--store))\n  (puthash \"tag-00000000000000000000000000000000\"\n           '(:id \"tag-00000000000000000000000000000000\" :name \"Stable\") (gethash :tags supertag--store))\n  (puthash \"conflict-tag\" '(:id \"conflict-tag\" :name \"different\" :aliases (\"new/conflict\")) (gethash :tags supertag--store))\n  (let ((pending (make-hash-table :test 'equal)))\n    (puthash \"base\" '(:parent \"different\" :path \"different/base\") pending)\n    (puthash :legacy-extends pending supertag--store))\n  (let* ((facts (prin1-to-string supertag--store)) (disk (oa-disk (oa-file)))\n         (status (supertag-migrate-status)))\n    (princ (format \"ORGA-MIGRATE-ACTUAL unstable=%S\\n\" (plist-get status :unstable-tags)))\n    (should (member \"bad id\" (plist-get status :unstable-tags)))\n    (should (member \"base\" (plist-get status :unstable-tags)))\n    (should-not (member \"tag-00000000000000000000000000000000\" (plist-get status :unstable-tags)))\n    (should (plist-get status :unresolved-extends))\n    (supertag-migrate-preview)\n    (with-current-buffer \"*Supertag Field Migration*\"\n      (should (string-match-p \"different\" (buffer-string))))\n    (should (equal facts (prin1-to-string supertag--store)))\n    (should (equal disk (oa-disk (oa-file))))\n    (should (supertag-migrate--apply-legacy-extends supertag--store))\n    (should (equal (list \"conflict-tag\") (plist-get (supertag-tag-get \"base\") :extends)))\n    (should-not (gethash :legacy-extends supertag--store))\n    (puthash \"base\" (plist-put (copy-sequence (supertag-tag-get \"base\")) :extends nil) (gethash :tags supertag--store))\n    (let ((pending (make-hash-table :test 'equal)))\n      (puthash \"base\" '(:parent \"absent\" :path \"absent/base\") pending)\n      (puthash :legacy-extends pending supertag--store))\n    (should (supertag-migrate--apply-legacy-extends supertag--store))\n    (should (equal \"Missing parent tag\"\n                   (plist-get (gethash \"base\" (gethash :legacy-extends supertag--store)) :conflict)))\n    (should-not (supertag-migrate--apply-legacy-extends supertag--store))))\n(let ((case (getenv \"OA_CASE\")))\n  (unwind-protect\n      (progn\n        (unless (member case '(\"prepare\" \"compile\"))\n          (setq supertag--store (with-temp-buffer\n                                 (insert-file-contents (expand-file-name \"seed.el\" user-emacs-directory))\n                                 (read (current-buffer)))))\n        (princ (format \"ORGA-CASE %s\\n\" case))\n        (pcase case\n          (\"prepare\" (oa-prepare))\n          (\"compile\" (require 'bytecomp)\n           (should (byte-compile-file (expand-file-name \"supertag-service-org.el\" (getenv \"OA_TREE\"))))\n           (should (file-exists-p (expand-file-name \"supertag-service-org.elc\" (getenv \"OA_TREE\")))))\n          (\"entry\" (oa-entry)) (\"entry-preset\" (setenv \"OA_PRESET_NIL\" \"1\") (oa-entry))\n          (\"wrapper\" (oa-wrapper))\n          ((or \"repair-clean\" \"elc-clean\" \"repair-preset\" \"elc-preset\") (oa-repair nil))\n          ((or \"repair-dirty\" \"elc-dirty\") (oa-repair t))\n          (\"tags\" (oa-tags)) (\"bulk\" (oa-bulk))\n          (\"load-failure\" (oa-load-failure nil)) (\"bypass-failure\" (oa-load-failure t))\n          (\"migrate\" (oa-migrate))\n          (_ (error \"Unknown case %s\" case)))\n        (princ (format \"ORGA-DONE %s\\n\" case)))\n    (setq kill-emacs-hook nil emacs-startup-hook nil after-init-hook nil\n          org-mode-hook nil enable-theme-functions nil disable-theme-functions nil)\n    (dolist (timer (append timer-list timer-idle-list)) (when (timerp timer) (cancel-timer timer)))))\n")
(defun supertag-migrate-test--orga-child (case)
  "Execute CASE in a fresh isolated process after separate real projection."
  (let* ((tmp (make-temp-file "supertag-orga-" t))
         (tree (expand-file-name "tree/" tmp))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (process-environment (copy-sequence process-environment))
         (default-directory tmp) (evidence (getenv "SUPERTAG_ORGA_EVIDENCE"))
         (script (expand-file-name "child.el" tmp)))
    (unwind-protect
        (progn
          (make-directory tree)
          (dolist (f (directory-files supertag-migrate-test--orga-root t "\\.el\\'"))
            (copy-file f (expand-file-name (file-name-nondirectory f) tree)))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (setenv "OA_TMP" tmp) (setenv "OA_TREE" tree)
          (with-temp-file script (insert supertag-migrate-test--orga-program))
          (cl-labels ((run (phase)
                        (setenv "OA_CASE" phase)
                        (with-temp-buffer
                          (let ((status (apply #'call-process program nil t nil
                                               (append '("-Q" "--batch")
                                                       (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                                       (list "-L" tree "-l" script)))))
                            (when evidence
                              (let ((out (expand-file-name (concat case "/") evidence)))
                                (make-directory out t)
                                (copy-file script (expand-file-name "child.el" out) t)
                                (write-region (point-min) (point-max) (expand-file-name (concat phase ".log") out) nil 'silent)
                                (with-temp-file (expand-file-name (concat phase ".exit") out) (insert (format "%s\n" status)))
                                (when (equal phase "compile")
                                  (dolist (suffix '(".el" ".elc"))
                                    (let ((f (expand-file-name (concat "supertag-service-org" suffix) tree)))
                                      (when (file-exists-p f) (copy-file f (expand-file-name (file-name-nondirectory f) out) t)))))))
                            (princ (buffer-string))
                            (should (equal 0 status))
                            (should (string-match-p (format "ORGA-DONE %s" phase) (buffer-string)))))))
            (run "prepare")
            ;; Test-only copied-provider failure/omission; never modify main.
            (when (member case '("load-failure" "bypass-failure"))
              (let ((f (expand-file-name "supertag-services-sync.el" tree)))
                (with-temp-buffer
                  (insert-file-contents f) (goto-char (point-min)) (forward-line 1)
                  (insert "(error \"ORGA injected Sync load failure\")\n")
                  (write-region (point-min) (point-max) f nil 'silent))))
            (when (getenv "OA_OMIT")
              (let* ((kind (getenv "OA_OMIT"))
                     (name (pcase kind ("wrapper" "supertag-service-org.el") ("bulk" "supertag-tag.el") ("migrate" "supertag-migrate.el")))
                     (needle (pcase kind
                               ("wrapper" "            ;; Resolve Sync before the callback can edit or bind rescan state.\n            (let ((definition\n                   (symbol-function 'supertag-node-sync-current-buffer)))\n              (when (autoloadp definition)\n                (autoload-do-load definition 'supertag-node-sync-current-buffer)))\n")
                               ("bulk" "        ;; Complete Sync loading before mutation or saver capture.\n        (let ((definition (symbol-function 'supertag-sync--parse-file-header)))\n          (when (autoloadp definition)\n            (autoload-do-load definition 'supertag-sync--parse-file-header)))\n")
                               ("migrate" "(require 'supertag-tag)\n")))
                     (f (expand-file-name name tree)))
                (with-temp-buffer
                  (insert-file-contents f) (goto-char (point-min))
                  (should (search-forward needle nil t))
                  (replace-match "" t t)
                  (should-not (search-forward needle nil t))
                  (write-region (point-min) (point-max) f nil 'silent))))
            (when (string-prefix-p "elc-" case) (run "compile"))
            (run case)))
      (delete-directory tmp t))))

(ert-deftest supertag-migrate-orga-migrate ()
  (supertag-migrate-test--orga-child "migrate"))
