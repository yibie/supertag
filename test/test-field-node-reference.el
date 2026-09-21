;;; test-field-node-reference.el --- ERT tests for node-reference projections -*- lexical-binding: t -*-

;;; Commentary:

;; `supertag-field-set' maintains :reference relations for fields of type
;; :node-reference without writing relation data into Org documents.

;;; Code:

(require 'ert)
(require 'cl-lib)

(when load-file-name
  ;; This file lives in test/; add the project root (its parent) to
  ;; load-path so the `require' calls below can find sibling modules
  ;; even when invoked without an explicit `-L .' flag.
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)
(require 'supertag-node)
(require 'supertag-tag)
(require 'supertag-link)
(require 'supertag-ops-field)
(require 'supertag-services-sync)

(defmacro field-node-reference-test--with-env (&rest body)
  "Run BODY with a clean store and two synced nodes in a temp Org file."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "supertag-field-ref-test" t))
          (supertag-data-directory tmp)
          (supertag-db-file (expand-file-name "supertag-db.el" tmp))
          (supertag-db-backup-directory (expand-file-name "backups" tmp))
          (supertag--store nil)
          (supertag--store-origin nil)
          (org-id-locations nil)
          (org-id-files nil)
          (test-file (expand-file-name "test.org" tmp)))
     (unwind-protect
         (progn
           (supertag--ensure-store)
           (with-temp-file test-file
             (org-mode)
             (insert "* Source\n:PROPERTIES:\n:ID: source-id\n:END:\n\nSource content.\n\n* Target\n:PROPERTIES:\n:ID: target-id\n:END:\n\nTarget content.\n"))
           (with-current-buffer (find-file-noselect test-file)
             (org-mode)
             (org-id-update-id-locations nil t)
             (goto-char (point-min))
             (org-back-to-heading t)
             (supertag-node-sync-at-point)
             (org-next-visible-heading 1)
             (supertag-node-sync-at-point)
             (set-buffer-modified-p nil))
           (let ((source-id "source-id")
                 (target-id "target-id"))
             ,@body))
       (ignore-errors
         (delete-directory tmp t)))))

(defun field-node-reference-test--tag-with-ref-field ()
  "Create and return a tag with a :node-reference field."
  (supertag-tag-create '(:id "ref-tag" :name "Reference Tag"))
  (supertag-tag-add-field
   "ref-tag" '(:name "ref" :type :node-reference :required nil)))

(defun field-node-reference-test--file-hash (file)
  "Return FILE's SHA-256 hash."
  (with-temp-buffer
    (insert-file-contents file)
    (secure-hash 'sha256 (current-buffer))))

(ert-deftest field-set-node-reference-creates-derived-relation-only ()
  "Setting a :node-reference field creates a relation without changing Org."
  (field-node-reference-test--with-env
    (field-node-reference-test--tag-with-ref-field)
    (supertag-node-add-tag source-id "ref-tag")
    (let ((file-hash (field-node-reference-test--file-hash test-file)))
      (supertag-field-set source-id "ref-tag" "ref" target-id)
      (let ((rels (supertag-relation-find-between source-id target-id :reference)))
        (should (= 1 (length rels)))
        (should (eq :field-reference (plist-get (car rels) :kind)))
        (should (equal "ref" (plist-get (car rels) :field-id))))
      (should (equal '("source-id")
                     (mapcar (lambda (rel) (plist-get rel :from))
                             (supertag-relation-find-by-to target-id :reference))))
      (should (string= file-hash
                       (field-node-reference-test--file-hash test-file))))))

(ert-deftest field-set-node-reference-removes-relation-without-org-write ()
  "Clearing a :node-reference field removes its relation without changing Org."
  (field-node-reference-test--with-env
    (field-node-reference-test--tag-with-ref-field)
    (supertag-node-add-tag source-id "ref-tag")
    (let ((file-hash (field-node-reference-test--file-hash test-file)))
      (supertag-field-set source-id "ref-tag" "ref" target-id)
      (supertag-field-set source-id "ref-tag" "ref" nil)
      (should (null (supertag-relation-find-between source-id target-id :reference)))
      (should (string= file-hash
                       (field-node-reference-test--file-hash test-file))))))

(ert-deftest field-set-node-reference-swap-target ()
  "Changing a target updates relations without writing Org links."
  (field-node-reference-test--with-env
    (field-node-reference-test--tag-with-ref-field)
    ;; Create a second target in the same file.
    (with-current-buffer (find-file-noselect test-file)
      (goto-char (point-max))
      (insert "\n* Target2\n:PROPERTIES:\n:ID: target2-id\n:END:\n\nTarget2 content.\n")
      (save-buffer)
      (org-id-update-id-locations nil t)
      (goto-char (point-min))
      (re-search-forward "target2-id" nil t)
      (org-back-to-heading t)
      (supertag-node-sync-at-point))
    (supertag-node-add-tag source-id "ref-tag")
    (let ((file-hash (field-node-reference-test--file-hash test-file)))
      (supertag-field-set source-id "ref-tag" "ref" target-id)
      (supertag-field-set source-id "ref-tag" "ref" "target2-id")
      (should (null (supertag-relation-find-between source-id target-id :reference)))
      (should (= 1 (length (supertag-relation-find-between
                            source-id "target2-id" :reference))))
      (should (string= file-hash
                       (field-node-reference-test--file-hash test-file))))))

(ert-deftest field-set-string-does-not-touch-relations ()
  "Setting a non-:node-reference field does not create or delete relations."
  (field-node-reference-test--with-env
    (supertag-tag-create '(:id "string-tag" :name "String Tag"))
    (supertag-tag-add-field
     "string-tag" '(:name "note" :type :string :required nil))
    (supertag-node-add-tag source-id "string-tag")
    (supertag-field-set source-id "string-tag" "note" "hello")
    (should (null (supertag-relation-find-between source-id target-id :reference)))))

(ert-deftest field-set-node-reference-equal-value-skips-side-effects ()
  "Setting the same :node-reference value twice does not duplicate relations."
  (field-node-reference-test--with-env
    (field-node-reference-test--tag-with-ref-field)
    (supertag-node-add-tag source-id "ref-tag")
    (supertag-field-set source-id "ref-tag" "ref" target-id)
    (supertag-field-set source-id "ref-tag" "ref" target-id)
    (let ((rels (supertag-relation-find-between source-id target-id :reference)))
      (should (= 1 (length rels))))))

(ert-deftest field-set-node-reference-global-field ()
  "Global :node-reference fields sync relations without Org writes."
  (field-node-reference-test--with-env
    (require 'supertag-ops-global-field)
    (let ((file-hash (field-node-reference-test--file-hash test-file)))
      (supertag-global-field-create
       (list :id "ref" :name "Reference" :type :node-reference :required nil))
      (supertag-field-set source-id "any-tag" "ref" target-id)
      (let ((rels (supertag-relation-find-between source-id target-id :reference)))
        (should (= 1 (length rels))))
      (supertag-field-set source-id "any-tag" "ref" nil)
      (should (null (supertag-relation-find-between source-id target-id :reference)))
      (should (string= file-hash
                       (field-node-reference-test--file-hash test-file))))))

(ert-deftest field-reference-projection-is-owned-by-field-value ()
  "Field and document projections rebuild without touching Semantic Edges."
  (field-node-reference-test--with-env
    (field-node-reference-test--tag-with-ref-field)
    (supertag-node-add-tag source-id "ref-tag")
    (supertag-store-put-entity
     :nodes source-id
     (plist-put (copy-sequence (supertag-node-get source-id))
                :ref-to (list target-id)))
    (let* ((document-link
            (supertag-relation-project-document-link source-id target-id))
           (semantic-edge
            (supertag-relation-create
             (list :type :supports :from source-id :to target-id))))
      (supertag-field-set source-id "ref-tag" "ref" target-id)
      (let ((field-reference
             (car (supertag-relation-find-between
                   source-id target-id :reference :field-reference))))
        (should field-reference)
        (should (equal "ref" (plist-get field-reference :field-id)))
        (should (eq :field-value (plist-get field-reference :origin)))
        (should (eq :semantic-edge (plist-get semantic-edge :kind)))
        (should (= 3 (length (supertag-relation-find-between
                              source-id target-id))))
        ;; Projection deletion cannot delete or rewrite its authoritative facts.
        (supertag-relation-delete (plist-get document-link :id))
        (supertag-relation-delete (plist-get field-reference :id))
        (should (equal target-id
                       (supertag-node-get-global-field source-id "ref")))
        (should (supertag-relation-get (plist-get semantic-edge :id)))
        ;; One projection reconciliation restores both rebuildable relation kinds.
        (supertag-sync--reconcile-all-projected-relations
         '(:references-created 0 :references-deleted 0))
        (should (supertag-relation-find-between
                 source-id target-id :reference :document-link))
        (should (supertag-relation-find-between
                 source-id target-id :reference :field-reference))
        (should (supertag-relation-get (plist-get semantic-edge :id)))
        ;; Changing the owner converges only its field-reference projection.
        (supertag-field-set source-id "ref-tag" "ref" nil)
        (should-not (supertag-relation-find-between
                     source-id target-id :reference :field-reference))
        (should (supertag-relation-find-between
                 source-id target-id :reference :document-link))
        (should (supertag-relation-get (plist-get semantic-edge :id)))))))

(provide 'test-field-node-reference)
;;; test-field-node-reference.el ends here
