;;; ownership-separation-test.el --- Ownership phase safety tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with: ./test/run-tests.sh ownership

;;; Code:

(require 'ert)

(when load-file-name
  (add-to-list 'load-path (file-name-directory load-file-name))
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))

(require 'ownership-fixture)
(require 'supertag-automation)
(require 'supertag-automation-sync)
(require 'supertag-core-scan)
(require 'supertag-migration)
(require 'supertag-services-query)
(require 'supertag-services-sync)
(require 'supertag-view-kanban)
(require 'supertag-view-node)
(require 'supertag-view-table)

(defun supertag-ownership-test--prepare-derived-index-fixture ()
  "Add inheritance and rule data needed to exercise every derived index."
  (let ((project (copy-tree (supertag-tag-get "project"))))
    (supertag-store-put-entity
     :tags "project"
     (plist-put project :aliases '("project" "old-project" "Project"))))
  (supertag-store-put-entity
   :tags "child"
   '(:id "child" :type :tag :name "Child" :aliases ("child")
     :extends "project"))
  (let ((node (copy-tree (supertag-node-get supertag-ownership-test-node-b))))
    (supertag-store-put-entity
     :nodes supertag-ownership-test-node-b
     (plist-put node :tags '("child"))))
  (supertag-store-put-entity
   :automations "derived-rule"
   '(:id "derived-rule" :name "Derived rule" :trigger :on-change
     :condition (has-tag "project") :actions nil :enabled t))
  (supertag-index-rebuild-all))

(defun supertag-ownership-test--derived-index-snapshot ()
  "Return public query results backed by every task018 derived index."
  (list
   :relations-from
   (sort (mapcar (lambda (relation) (plist-get relation :id))
                 (supertag-relation-find-by-from
                  supertag-ownership-test-node-a))
         #'string<)
   :relations-to
   (sort (mapcar (lambda (relation) (plist-get relation :id))
                 (supertag-relation-find-by-to
                  supertag-ownership-test-node-a))
         #'string<)
   :tag-owner (supertag-tag-resolve-occurrence "old-project")
   :tag-path (supertag-tag-display-path "child")
   :tag-descendants (sort (supertag-find-tag-descendants "project") #'string<)
   :nodes-by-tag
   (sort (supertag-index-get-nodes-by-tag "project" t) #'string<)
   :resolved-fields
   (mapcar (lambda (field) (plist-get field :id))
           (plist-get (supertag-ops-schema-get-resolved-tag "child") :fields))
   :rule-ids (sort (copy-sequence (gethash "project" supertag--rule-index))
                   #'string<)))

(defun supertag-ownership-test--derived-index-counts ()
  "Return raw counts proving each derived index is materialized."
  (list
   (hash-table-count supertag--index-relations-by-from)
   (hash-table-count supertag--index-relations-by-to)
   (hash-table-count supertag--index-nodes-by-tag)
   (hash-table-count supertag-tag--token-index)
   (hash-table-count supertag-tag--display-path-index)
   (hash-table-count supertag-tag--descendants-index)
   (hash-table-count supertag--global-field-cache)
   (hash-table-count supertag--tag-field-order-cache)
   (hash-table-count supertag-ops-schema--resolved-cache)
   (hash-table-count supertag--rule-index)))

(ert-deftest supertag-derived-index-cold-rebuild-has-query-parity ()
  "One clear/rebuild contract restores every derived query result."
  (supertag-ownership-test-with-vault
    (supertag-ownership-test--prepare-derived-index-fixture)
    (let ((before (supertag-ownership-test--derived-index-snapshot))
          (semantic-before (supertag-ownership-test-semantic-fingerprint)))
      (should (cl-every (lambda (count) (> count 0))
                        (supertag-ownership-test--derived-index-counts)))
      (supertag-index-clear-all)
      (should (equal (make-list 10 0)
                     (supertag-ownership-test--derived-index-counts)))
      (supertag-index-rebuild-all)
      (should (equal before
                     (supertag-ownership-test--derived-index-snapshot)))
      (should (equal semantic-before
                     (supertag-ownership-test-semantic-fingerprint))))))

(ert-deftest supertag-derived-relation-index-follows-canonical-store-writes ()
  "Canonical Store writes invalidate the relation index in place."
  (supertag-ownership-test-with-vault
    (supertag-index-rebuild-all)
    (let ((relation-id "late-relation"))
      (supertag-store-put-entity
       :relations relation-id
       `(:id ,relation-id :type :reference :kind :semantic-edge
         :from ,supertag-ownership-test-node-b
         :to ,supertag-ownership-test-node-a))
      (should (member relation-id
                      (mapcar (lambda (relation) (plist-get relation :id))
                              (supertag-relation-find-by-from
                               supertag-ownership-test-node-b))))
      (supertag-store-remove-entity :relations relation-id)
      (should-not (member relation-id
                          (mapcar (lambda (relation) (plist-get relation :id))
                                  (supertag-relation-find-by-from
                                   supertag-ownership-test-node-b)))))))

(ert-deftest supertag-derived-index-rebuild-failure-clears-mixed-generation ()
  "A failed builder leaves every cache empty, never partly rebuilt."
  (supertag-ownership-test-with-vault
    (supertag-ownership-test--prepare-derived-index-fixture)
    (cl-letf (((symbol-function 'supertag-rebuild-rule-index)
               (lambda () (error "Injected rule rebuild failure"))))
      (should-error (supertag-index-rebuild-all))
      (should (equal (make-list 10 0)
                     (supertag-ownership-test--derived-index-counts))))))

(ert-deftest supertag-derived-index-load-cold-rebuilds-every-cache ()
  "A Store load replaces every cache generation before returning."
  (supertag-ownership-test-with-vault
    (let ((supertag-db-auto-migrate nil)
          (supertag-db-lock nil))
      (supertag-ownership-test--prepare-derived-index-fixture)
      (let ((before (supertag-ownership-test--derived-index-snapshot))
            (counts-before (supertag-ownership-test--derived-index-counts)))
        (make-directory supertag-data-directory t)
        (supertag--persistence-write-store-atomically supertag-db-file)
        (supertag-index-clear-all)
        (supertag-load-store supertag-db-file)
        (should (equal counts-before
                       (supertag-ownership-test--derived-index-counts)))
        (should (equal before
                       (supertag-ownership-test--derived-index-snapshot)))))))

(ert-deftest supertag-derived-index-rollback-cold-rebuilds-every-cache ()
  "Rollback restores Store first, then rebuilds all derived indexes once."
  (supertag-ownership-test-with-vault
    (supertag-ownership-test--prepare-derived-index-fixture)
    (let ((before (supertag-ownership-test--derived-index-snapshot)))
      (should-error
       (supertag-with-transaction
         (supertag-store-remove-entity
          :relations supertag-ownership-test-document-link)
         (let ((node (copy-tree (supertag-node-get
                                 supertag-ownership-test-node-a))))
           (supertag-store-put-entity
            :nodes supertag-ownership-test-node-a
            (plist-put node :tags nil)))
         (let ((child (copy-tree (supertag-tag-get "child"))))
           (supertag-store-put-entity
            :tags "child" (plist-put child :extends nil)))
         (supertag-store-remove-entity :tag-field-associations "project")
         (let ((rule (copy-tree (supertag-automation-get "derived-rule"))))
           (supertag-store-put-entity
            :automations "derived-rule"
            (plist-put rule :condition '(has-tag "child"))))
         (supertag-index-rebuild-all)
         (should-not (equal before
                            (supertag-ownership-test--derived-index-snapshot)))
         (error "Injected transaction failure")))
      (should (equal before
                     (supertag-ownership-test--derived-index-snapshot))))))

(ert-deftest supertag-ownership-test-fixture-is-repeatable-and-complete ()
  "The two-file fixture recreates the same files and every required fact."
  (supertag-ownership-test-with-vault
    (let ((first-files (mapcar (lambda (file)
                                 (with-temp-buffer
                                   (insert-file-contents-literally file)
                                   (buffer-string)))
                               files))
          (first-snapshot (supertag-ownership-test-semantic-snapshot)))
      (should (= 2 (length (directory-files vault nil "\\.org\\'"))))
      (should (string-match-p "#project" (car first-files)))
      (should (string-match-p "id:ownership-node-b" (car first-files)))
      (should (= 2 (hash-table-count (supertag-store-get-collection :nodes))))
      (should (member "project" (plist-get
                                  (supertag-store-get-entity
                                   :nodes supertag-ownership-test-node-a)
                                  :tags)))
      (should (supertag-store-get-field-definition "status"))
      (should (equal '((:field-id "status" :order 0))
                     (supertag-store-get-tag-field-associations "project")))
      (should (equal "active"
                     (supertag-store-get-field-value
                      supertag-ownership-test-node-a "status")))
      (should (eq :document-link
                  (plist-get (supertag-store-get-entity
                              :relations supertag-ownership-test-document-link)
                             :kind)))
      (should (eq :semantic-edge
                  (plist-get (supertag-store-get-entity
                              :relations supertag-ownership-test-semantic-edge)
                             :kind)))
      (should (supertag-store-get-entity :boards "ownership-board"))
      (should (supertag-store-get-entity :automations "ownership-automation"))
      (should (assoc "active-projects" supertag-query-saved))
      (should (equal files (supertag-ownership-test-create-vault vault)))
      (supertag-ownership-test-populate-store files)
      (should (equal first-files
                     (mapcar (lambda (file)
                               (with-temp-buffer
                                 (insert-file-contents-literally file)
                                 (buffer-string)))
                             files)))
      (should (equal first-snapshot
                     (supertag-ownership-test-semantic-snapshot))))))

(ert-deftest supertag-ownership-test-fingerprint-covers-every-semantic-source ()
  "Changing or losing any Semantic Fact source changes its fingerprint."
  (supertag-ownership-test-with-vault
    (dolist (collection supertag-ownership-test-semantic-collections)
      (supertag-ownership-test-populate-store files)
      (let ((before (supertag-ownership-test-semantic-fingerprint)))
        (puthash "fingerprint-change" '(:id "fingerprint-change")
                 (supertag-store-get-collection collection))
        (should-not (equal before (supertag-ownership-test-semantic-fingerprint))))
      (supertag-ownership-test-populate-store files)
      (let ((before (supertag-ownership-test-semantic-fingerprint)))
        (remhash collection supertag--store)
        (should-not (equal before (supertag-ownership-test-semantic-fingerprint)))))
    (supertag-ownership-test-populate-store files)
    (let ((before (supertag-ownership-test-semantic-fingerprint)))
      (remhash supertag-ownership-test-semantic-edge
               (supertag-store-get-collection :relations))
      (should-not (equal before (supertag-ownership-test-semantic-fingerprint))))
    (supertag-ownership-test-populate-store files)
    (let ((before (supertag-ownership-test-semantic-fingerprint)))
      (setq supertag-query-saved nil)
      (should-not (equal before (supertag-ownership-test-semantic-fingerprint))))))

(ert-deftest supertag-ownership-test-fingerprint-excludes-document-projection ()
  "A Document Projection change alone does not change Semantic Facts."
  (supertag-ownership-test-with-vault
    (let ((before (supertag-ownership-test-semantic-fingerprint)))
      (supertag-store-put-entity
       :nodes supertag-ownership-test-node-a
       (plist-put (copy-sequence
                   (supertag-store-get-entity :nodes supertag-ownership-test-node-a))
                  :title "Project Alpha rescanned"))
      (supertag-store-remove-entity
       :relations supertag-ownership-test-document-link)
      (should (equal before (supertag-ownership-test-semantic-fingerprint))))))

(ert-deftest supertag-reindex-keeps-unknown-tag-occurrence-out-of-semantic-store ()
  "Reindex records unknown Org tokens without creating Semantic Tags."
  (supertag-ownership-test-with-vault
    (let* ((file (cadr files))
           (before (supertag-ownership-test-semantic-fingerprint))
           (supertag-sync--state
            (list :sync-state (make-hash-table :test 'equal)))
           (supertag-sync--deferred-files (make-hash-table :test 'equal))
           (counters (list :nodes-created 0 :nodes-updated 0 :nodes-deleted 0
                           :references-created 0 :references-deleted 0)))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (end-of-line)
        (insert " #emerging")
        (write-region nil nil file nil 'silent))
      (cl-letf (((symbol-function 'supertag-sync--allow-destructive-p)
                 (lambda () t)))
        (supertag-sync--process-single-file file counters))
      (let ((node (supertag-node-get supertag-ownership-test-node-b)))
        (should (equal '("reference" "emerging")
                       (plist-get node :tag-occurrences)))
        (should (equal '("reference") (plist-get node :tags)))
        (should (equal '("emerging") (plist-get node :unresolved-tags))))
      (should-not (supertag-tag-get "emerging"))
      (should-not
       (supertag-relation-find-between
        supertag-ownership-test-node-b "emerging" :node-tag))
      (should (equal (list supertag-ownership-test-node-b)
                     (supertag-index-get-nodes-by-tag "emerging")))
      (should (equal (list supertag-ownership-test-node-b)
                     (supertag-query-sexp '(tag "emerging"))))
      (should (equal before (supertag-ownership-test-semantic-fingerprint))))))

(ert-deftest supertag-reindex-projects-document-links-without-writing-org ()
  "Reindex projects Org links without inserting reciprocal file links."
  (supertag-ownership-test-with-vault
    (let* ((project-file (car files))
           (reference-file (cadr files))
           (supertag-sync--state
            (list :sync-state (make-hash-table :test 'equal)))
           (supertag-sync--deferred-files (make-hash-table :test 'equal))
           (supertag-sync--is-full-rescan-p t)
           (counters (list :nodes-created 0 :nodes-updated 0 :nodes-deleted 0
                           :references-created 0 :references-deleted 0))
           (target-buffer (find-file-noselect reference-file))
           before relation)
      (supertag-index-rebuild-relations)
      (supertag-relation-delete supertag-ownership-test-document-link)
      (supertag-store-put-entity
       :nodes supertag-ownership-test-node-a
       (plist-put (copy-sequence
                   (supertag-node-get supertag-ownership-test-node-a))
                  :hash "stale"))
      (setq before
            (mapcar (lambda (file)
                      (with-temp-buffer
                        (insert-file-contents-literally file)
                        (secure-hash 'sha256 (current-buffer))))
                    files))
      (unwind-protect
          (cl-letf (((symbol-function 'supertag-sync--allow-destructive-p)
                     (lambda () t))
                    ((symbol-function 'supertag-ui--find-node-marker)
                     (lambda (_node-id)
                       (with-current-buffer target-buffer
                         (copy-marker (point-min)))))
                    ((symbol-function 'supertag-ui--file-node-p)
                     (lambda (_node-id) nil)))
            (supertag-sync--process-single-file project-file counters)
            (should
             (equal before
                    (mapcar (lambda (file)
                              (with-temp-buffer
                                (insert-file-contents-literally file)
                                (secure-hash 'sha256 (current-buffer))))
                            files)))
            (setq relation
                  (car (supertag-relation-find-between
                        supertag-ownership-test-node-a
                        supertag-ownership-test-node-b :reference)))
            (should relation)
            (should (eq :document-link (plist-get relation :kind)))
            (should (eq :org (plist-get relation :origin)))
            (should (= 1 (length (supertag-relation-find-by-from
                                  supertag-ownership-test-node-a :reference))))
            (should (= 1 (length (supertag-relation-find-by-to
                                  supertag-ownership-test-node-b :reference))))
            (should (= 1 (plist-get counters :references-created)))
            ;; A partially classified projection is completed in place.
            (supertag-store-put-entity
             :relations (plist-get relation :id)
             (plist-put (plist-put (copy-sequence relation)
                                   :kind :document-link)
                        :origin nil))
            (supertag-store-put-entity
             :nodes supertag-ownership-test-node-a
             (plist-put (copy-sequence
                         (supertag-node-get supertag-ownership-test-node-a))
                        :hash "stale"))
            (supertag-sync--process-single-file project-file counters)
            (setq relation
                  (car (supertag-relation-find-between
                        supertag-ownership-test-node-a
                        supertag-ownership-test-node-b :reference)))
            (should (eq :document-link (plist-get relation :kind)))
            (should (eq :org (plist-get relation :origin)))
            (should (= 1 (plist-get counters :references-created)))
            ;; The authoritative Org occurrence classifies an unowned legacy
            ;; reference as a Document Link during reconciliation.
            (supertag-store-put-entity
             :relations (plist-get relation :id)
             (plist-put (plist-put (copy-sequence relation) :kind nil)
                        :origin nil))
            (supertag-store-put-entity
             :nodes supertag-ownership-test-node-a
             (plist-put (copy-sequence
                         (supertag-node-get supertag-ownership-test-node-a))
                        :hash "stale"))
            (supertag-sync--process-single-file project-file counters)
            (setq relation
                  (car (supertag-relation-find-between
                        supertag-ownership-test-node-a
                        supertag-ownership-test-node-b :reference)))
            (should (eq :document-link (plist-get relation :kind)))
            (should (eq :org (plist-get relation :origin)))
            (should (= 2 (plist-get counters :references-created)))
            (should
             (equal before
                    (mapcar (lambda (file)
                              (with-temp-buffer
                                (insert-file-contents-literally file)
                                (secure-hash 'sha256 (current-buffer))))
                            files))))
        (kill-buffer target-buffer)))))

(ert-deftest supertag-document-link-cleanup-preserves-field-references ()
  "Removing an Org link does not delete a database-owned field reference."
  (supertag-ownership-test-with-vault
    (let* ((field-target "ownership-field-target")
           (counters '(:references-created 0 :references-deleted 0))
           field-reference)
      (supertag-store-put-entity
       :nodes field-target
       (list :id field-target :type :node :title "Field Target"))
      (supertag-store-put-field-definition
       "refs" '(:id "refs" :name "Refs" :type :node-reference))
      (supertag-store-put-field-value
       supertag-ownership-test-node-a "refs" field-target)
      (supertag-index-rebuild-relations)
      (setq field-reference
            (supertag-relation-create
             (list :type :reference
                   :from supertag-ownership-test-node-a
                   :to field-target
                   :kind :field-reference
                   :origin :field-value
                   :field-id "refs")))
      (supertag--cleanup-orphaned-references
       supertag-ownership-test-node-a nil counters)
      (should-not
       (supertag-relation-get supertag-ownership-test-document-link))
      (should (supertag-relation-get (plist-get field-reference :id)))
      (should (= 1 (plist-get counters :references-deleted))))))

(ert-deftest supertag-reindex-org-cold-rebuilds-document-projection ()
  "The public reindex command rebuilds projections, not Semantic Facts."
  (supertag-ownership-test-with-vault
    (let* ((before-semantic (supertag-ownership-test-semantic-fingerprint))
           (before-files
            (mapcar (lambda (file)
                      (with-temp-buffer
                        (insert-file-contents-literally file)
                        (secure-hash 'sha256 (current-buffer))))
                    files))
           (supertag-sync--state
            (list :sync-state (make-hash-table :test 'equal)))
           (supertag-sync--deferred-files (make-hash-table :test 'equal))
           projection-relation-ids report)
      (maphash
       (lambda (id relation)
         (when (supertag-relation-document-link-p relation)
           (push id projection-relation-ids)))
       (supertag-store-get-collection :relations))
      (dolist (id projection-relation-ids)
        (supertag-store-remove-entity :relations id))
      (clrhash (supertag-store-get-collection :nodes))
      (supertag-index-rebuild-relations)
      (cl-letf (((symbol-function 'supertag-sync--ensure-state-source) #'ignore)
                ((symbol-function 'supertag-sync--snapshot-build)
                 (lambda ()
                   (list :status 'complete :files files :scope (list vault)
                         :errors nil :observed-at (current-time))))
                ((symbol-function 'supertag-scan-sync-directories)
                 (lambda (&rest _)
                   (ert-fail "reindex rescanned past its authoritative snapshot")))
                ((symbol-function 'supertag-sync-save-state) #'ignore))
        (setq report (supertag-reindex-org)))
      (should (eq 'complete (plist-get report :status)))
      (should (eq 'complete (plist-get report :snapshot-status)))
      (should (= 2 (plist-get report :files-discovered)))
      (should (= 2 (plist-get report :files-processed)))
      (should (= 2 (hash-table-count
                    (supertag-store-get-collection :nodes))))
      (should-not
       (supertag-relation-find-by-from
        supertag-ownership-test-node-a :node-tag))
      (should-not
       (supertag-relation-find-by-from
        supertag-ownership-test-node-b :node-tag))
      (let ((document-link
             (car (supertag-relation-find-between
                   supertag-ownership-test-node-a
                   supertag-ownership-test-node-b :reference))))
        (should (supertag-relation-document-link-p document-link)))
      (should (equal (list supertag-ownership-test-node-b)
                     (plist-get
                      (supertag-node-get supertag-ownership-test-node-a)
                      :ref-to)))
      (should (equal (list supertag-ownership-test-node-a)
                     (plist-get
                      (supertag-node-get supertag-ownership-test-node-b)
                      :ref-from)))
      (should (= 1 (plist-get
                    (supertag-node-get supertag-ownership-test-node-b)
                    :ref-count)))
      (should (supertag-relation-get
               supertag-ownership-test-semantic-edge))
      (should (equal before-semantic
                     (supertag-ownership-test-semantic-fingerprint)))
      (should
       (equal before-files
              (mapcar (lambda (file)
                        (with-temp-buffer
                          (insert-file-contents-literally file)
                          (secure-hash 'sha256 (current-buffer))))
                      files))))))

(ert-deftest supertag-global-field-audit-is-repeatable-and-read-only ()
  "A complete legacy/global mapping is deterministic and never mutates Store."
  (supertag-ownership-test-with-vault
    (let* ((legacy-definition
            '(:name "Status" :type :enum
              :options ("active" "done") :default "active"))
           (project (copy-tree (supertag-store-get-entity :tags "project")))
           (reference (copy-tree (supertag-store-get-entity :tags "reference")))
           report first-store database-sha)
      (supertag-store-put-entity
       :tags "project" (plist-put project :fields (list legacy-definition)))
      (supertag-store-put-entity
       :tags "reference" (plist-put reference :extends "project"))
      (supertag-store-put-legacy-field
       supertag-ownership-test-node-a "project" "Status" "active")
      ;; Legacy values are stored under the node's selected tag even when the
      ;; field itself is inherited from that tag's parent.
      (supertag-store-put-legacy-field
       supertag-ownership-test-node-b "reference" "Status" "done")
      (make-directory (file-name-directory supertag-db-file) t)
      (with-temp-file supertag-db-file (insert "audit-must-not-write\n"))
      (setq first-store
            (supertag--persistence--canonicalize-value supertag--store)
            database-sha (with-temp-buffer
                           (insert-file-contents-literally supertag-db-file)
                           (secure-hash 'sha256 (current-buffer)))
            report (supertag-migration-audit-global-fields))
      ;; Reinsert every audited collection in reverse key order.  The report
      ;; must describe facts, not hash-table insertion order.
      (dolist (collection supertag-migration--global-field-backup-collections)
        (let ((replacement (make-hash-table :test 'equal)))
          (dolist (entry
                   (reverse
                    (supertag-migration--sorted-table-entries
                     (supertag-store-get-collection collection))))
            (puthash (car entry) (cdr entry) replacement))
          (puthash collection replacement supertag--store)))
      (should (equal report (supertag-migration-audit-global-fields)))
      (should (equal first-store
                     (supertag--persistence--canonicalize-value supertag--store)))
      (should (equal database-sha
                     (with-temp-buffer
                       (insert-file-contents-literally supertag-db-file)
                       (secure-hash 'sha256 (current-buffer)))))
      (should (plist-get report :safe-to-apply))
      (should-not (plist-get report :conflicts))
      (should-not (plist-get report :orphans))
      (should (equal :equal
                     (plist-get (car (plist-get report :definition-mappings))
                                :status)))
      (should (equal :equal
                     (plist-get (car (plist-get report :association-mappings))
                                :status)))
      (should (equal '(:equal :would-create)
                     (mapcar (lambda (item) (plist-get item :status))
                             (plist-get report :value-parity))))
      (should (= 2 (plist-get (plist-get report :coverage)
                              :legacy-values)))
      (should (eq :full-database
                  (plist-get (plist-get report :backup) :scope)))
      (should (equal supertag--store-collections
                     (plist-get (plist-get report :backup) :collections)))
      (should (stringp
               (plist-get (plist-get report :backup) :store-sha256))))))

(ert-deftest supertag-stable-tag-audit-is-complete-repeatable-and-read-only ()
  "Stable Tag preflight maps every owner without changing live state."
  (supertag-ownership-test-with-vault
    (let* ((reference
            (copy-tree (supertag-store-get-entity :tags "reference")))
           (project
            (copy-tree (supertag-store-get-entity :tags "project")))
           (node-a
            (copy-tree (supertag-node-get supertag-ownership-test-node-a)))
           (node-b
            (copy-tree (supertag-node-get supertag-ownership-test-node-b)))
           (views (make-hash-table :test 'eq))
           report before-store before-query before-views database-sha)
      (supertag-store-put-entity
       :tags "reference" (plist-put reference :extends "project"))
      (supertag-store-put-entity
       :tags "project"
       (plist-put project :fields
                  '((:name "Legacy Related" :type :tag
                     :default "reference"))))
      (supertag-store-put-entity
       :nodes supertag-ownership-test-node-a
       (plist-put node-a :tag-occurrences '("project")))
      (supertag-store-put-entity
       :nodes supertag-ownership-test-node-b
       (plist-put node-b :tag-occurrences '("project/reference")))
      (supertag-store-put-field-definition
       "related-tag" '(:id "related-tag" :name "Related Tag" :type :tag
                        :default "project"))
      (supertag-store-put-field-value
       supertag-ownership-test-node-a "related-tag" "reference")
      (supertag-store-put-legacy-field
       supertag-ownership-test-node-a "project" "Legacy" "kept")
      (supertag-store-put-entity
       :relations "ownership-tag-edge"
       '(:id "ownership-tag-edge" :type :categorizes
         :from "project" :to "ownership-node-a"
         :kind :semantic-edge :origin :semantic))
      (supertag-store-put-entity
       :boards "ownership-board"
       (plist-put (copy-tree (supertag-store-get-entity
                              :boards "ownership-board"))
                  :filter '(:tag "project")))
      (puthash 'ownership-view
               '(:id ownership-view :name "Ownership View"
                 :query (:type :tag :value "reference"))
               views)
      (make-directory (file-name-directory supertag-db-file) t)
      (with-temp-file supertag-db-file (insert "stable-tag-audit-must-not-write\n"))
      (setq before-store
            (supertag--persistence--canonicalize-value supertag--store)
            before-query (copy-tree supertag-query-saved)
            before-views (supertag--persistence--canonicalize-value views)
            database-sha (supertag-migration--file-sha256 supertag-db-file))
      (let ((supertag--view-configs views))
        (setq report (supertag-migration-audit-stable-tags))
        (should (equal report (supertag-migration-audit-stable-tags))))
      (should (equal "tag-f54e0c3adb0620477fe62b580bc9c188"
                     (supertag-migration--proposed-stable-tag-id "日记")))
      (should (plist-get report :safe-to-apply))
      (should (= 2 (length (plist-get report :tag-mappings))))
      (dolist (mapping (plist-get report :tag-mappings))
        (should (string-match-p
                 "\\`tag-[0-9a-f]\\{32\\}\\'"
                 (plist-get mapping :stable-id)))
        (should (member (plist-get mapping :old-id)
                        (plist-get mapping :aliases))))
      (should (equal "project"
                     (plist-get
                      (car (plist-get report :inheritance-mappings))
                      :old-parent-id)))
      (should (cl-find :schema (plist-get report :reference-mappings)
                       :key (lambda (item) (plist-get item :kind))))
      (dolist (kind '(:legacy-field-bucket :legacy-tag-field-default
                      :node-membership :tag-occurrence :relation
                      :tag-field-default :tag-field-value :automation
                      :board :saved-query :view))
        (should (cl-find kind (plist-get report :reference-mappings)
                         :key (lambda (item) (plist-get item :kind)))))
      (should-not (plist-get report :conflicts))
      (should-not (plist-get report :unresolved-occurrences))
      (should (plist-get (plist-get report :backup) :required-before-apply))
      (should (equal supertag-migration--stable-tag-collections
                     (plist-get (plist-get report :backup)
                                :migration-collections)))
      (should (equal before-store
                     (supertag--persistence--canonicalize-value supertag--store)))
      (should (equal before-query supertag-query-saved))
      (should (equal before-views
                     (supertag--persistence--canonicalize-value views)))
      (should (equal database-sha
                     (supertag-migration--file-sha256 supertag-db-file))))))

(ert-deftest supertag-stable-tag-audit-fails-closed-on-identity-problems ()
  "Alias ambiguity, inheritance cycles, and unknown tokens block migration."
  (supertag-ownership-test-with-vault
    (let* ((project (copy-tree (supertag-tag-get "project")))
           (reference (copy-tree (supertag-tag-get "reference")))
           (node (copy-tree (supertag-node-get supertag-ownership-test-node-a)))
           before report reasons)
      (setq project (plist-put project :extends "reference")
            project (plist-put project :aliases '("shared"))
            reference (plist-put reference :extends "project")
            reference (plist-put reference :aliases '("shared")))
      (supertag-store-put-entity :tags "project" project)
      (supertag-store-put-entity :tags "reference" reference)
      (supertag-store-put-entity
       :nodes supertag-ownership-test-node-a
       (plist-put node :tag-occurrences '("project" "unknown-token")))
      (setq before (supertag--persistence--canonicalize-value supertag--store)
            report (supertag-migration-audit-stable-tags)
            reasons (mapcar (lambda (item) (plist-get item :reason))
                            (plist-get report :conflicts)))
      (should-not (plist-get report :safe-to-apply))
      (should (memq :alias-conflict reasons))
      (should (memq :inheritance-cycle reasons))
      (should (equal '("unknown-token")
                     (mapcar (lambda (item) (plist-get item :token))
                             (plist-get report :unresolved-occurrences))))
      (should (equal before
                     (supertag--persistence--canonicalize-value supertag--store))))))

(ert-deftest supertag-stable-tag-migration-applies-with-backup-and-no-org-rewrite ()
  "The task017 cutover rekeys semantic facts while Org keeps its tokens."
  (supertag-ownership-test-with-vault
    (let* ((project-id
            (supertag-migration--proposed-stable-tag-id "project"))
           (reference-id
            (supertag-migration--proposed-stable-tag-id "reference"))
           (views (make-hash-table :test 'eq))
           before-files result)
      (dolist (entry `((,supertag-ownership-test-node-a . "project")
                       (,supertag-ownership-test-node-b . "reference")))
        (let ((node (copy-tree (supertag-node-get (car entry)))))
          (setq node (plist-put node :tag-occurrences (list (cdr entry))))
          (setq node (plist-put node :unresolved-tags nil))
          (supertag-store-put-entity :nodes (car entry) node)))
      (let ((reference (copy-tree (supertag-tag-get "reference")))
            (project (copy-tree (supertag-tag-get "project"))))
        (supertag-store-put-entity
         :tags "reference" (plist-put reference :extends "project"))
        (supertag-store-put-entity
         :tags "project"
         (plist-put
          project :fields
          '((:name "Legacy related" :type :tag :default "reference")))))
      (supertag-store-put-legacy-field
       supertag-ownership-test-node-a "project" "Legacy related" "reference")
      (supertag-store-put-field-definition
       "related-tag" '(:id "related-tag" :name "Related" :type :tag
                       :default "reference"))
      (supertag-store-put-field-value
       supertag-ownership-test-node-a "related-tag" "project")
      (supertag-store-put-entity
       :relations "semantic-tag-owner"
       '(:id "semantic-tag-owner" :type :categorizes
         :from "project" :to "ownership-node-a"
         :kind :semantic-edge :origin :semantic))
      (supertag-store-put-entity
       :boards "ownership-board"
       (plist-put (copy-tree (supertag-store-get-entity
                              :boards "ownership-board"))
                  :filter '(:type :tag :value "project")))
      (puthash 'ownership-view
               '(:id ownership-view :query (:type :tag :value "reference"))
               views)
      (setq before-files
            (mapcar (lambda (file)
                      (with-temp-buffer
                        (insert-file-contents-literally file)
                        (buffer-string)))
                    files))
      (let ((supertag--view-configs views))
        (setq result (supertag-migration-run-stable-tags t)))
      (should (eq :migrated (plist-get result :status)))
      (should (file-exists-p (plist-get (plist-get result :backup) :store)))
      (should (file-exists-p (plist-get (plist-get result :backup) :configs)))
      (should-not (supertag-tag-get "project"))
      (should-not (supertag-tag-get "reference"))
      (should (equal project-id (supertag-tag-resolve-occurrence "project")))
      (should (equal reference-id
                     (supertag-tag-resolve-occurrence "Project/Reference")))
      (should (member "project"
                      (plist-get (supertag-tag-get project-id) :aliases)))
      (should (equal project-id
                     (plist-get (supertag-tag-get reference-id) :extends)))
      (should (equal '("project")
                     (plist-get
                      (supertag-node-get supertag-ownership-test-node-a)
                      :tag-occurrences)))
      (should (equal (list project-id)
                     (plist-get
                      (supertag-node-get supertag-ownership-test-node-a) :tags)))
      (should-not (plist-get
                   (supertag-node-get supertag-ownership-test-node-a)
                   :unresolved-tags))
      (should (supertag-store-get-tag-field-associations project-id))
      (should-not (supertag-store-get-tag-field-associations "project"))
      (should (equal "reference"
                     (supertag-get
                      (list :fields supertag-ownership-test-node-a
                            project-id "Legacy related"))))
      (should (equal reference-id
                     (plist-get
                      (supertag-store-get-field-definition "related-tag")
                      :default)))
      (should (equal project-id
                     (supertag-store-get-field-value
                      supertag-ownership-test-node-a "related-tag")))
      (should
       (cl-some
        (lambda (relation)
          (and (equal project-id (plist-get relation :from))
               (equal supertag-ownership-test-node-a
                      (plist-get relation :to))))
        (supertag-relation-find-by-from project-id :categorizes)))
      (should (equal project-id
                     (plist-get
                      (plist-get (supertag-store-get-entity
                                  :boards "ownership-board") :filter)
                      :value)))
      (should (equal project-id
                     (plist-get
                      (plist-get (supertag-store-get-entity
                                  :automations "ownership-automation")
                                 :condition)
                      :tag)))
      (should (string-match-p (regexp-quote project-id)
                              (cdr (assoc "active-projects"
                                          supertag-query-saved))))
      (should (equal reference-id
                     (plist-get (plist-get (gethash 'ownership-view views) :query)
                                :value)))
      (should (equal before-files
                     (mapcar (lambda (file)
                               (with-temp-buffer
                                 (insert-file-contents-literally file)
                                 (buffer-string)))
                             files)))
      (let ((backup-store
             (supertag--persistence--try-read-store
              (plist-get (plist-get result :backup) :store))))
        (should (gethash "project" (gethash :tags backup-store)))))))

(ert-deftest supertag-semantic-tag-rename-keeps-identity-references-and-org ()
  "Canonical rename changes only Tag name/aliases, never owned references."
  (supertag-ownership-test-with-vault
    (dolist (entry `((,supertag-ownership-test-node-a . "project")
                     (,supertag-ownership-test-node-b . "reference")))
      (supertag-store-put-entity
       :nodes (car entry)
       (plist-put (copy-tree (supertag-node-get (car entry)))
                  :tag-occurrences (list (cdr entry)))))
    (let* ((result (supertag-migration-run-stable-tags t))
           (tag-id (cdr (assoc "project" (plist-get result :mapping))))
           (collections '(:nodes :relations :fields :field-definitions
                          :tag-field-associations :field-values :boards
                          :automations))
           (before-store
            (mapcar
             (lambda (collection)
               (cons collection
                     (supertag--persistence--canonicalize-value
                      (supertag-store-get-collection collection))))
             collections))
           (before-query (copy-tree supertag-query-saved))
           (before-files
            (mapcar (lambda (file)
                      (with-temp-buffer
                        (insert-file-contents-literally file)
                        (buffer-string)))
                    files)))
      (should (equal tag-id (supertag-tag-rename tag-id "initiative")))
      (should (equal "initiative" (plist-get (supertag-tag-get tag-id) :name)))
      (should (equal tag-id (supertag-tag-resolve-occurrence "initiative")))
      (should (equal tag-id (supertag-tag-resolve-occurrence "project")))
      (should (equal (list supertag-ownership-test-node-a)
                     (supertag-query-sexp '(tag "project"))))
      (should
       (supertag-automation--evaluate-condition
        '(tag "project")
        supertag-ownership-test-node-a))
      (should (equal before-store
                     (mapcar
                      (lambda (collection)
                        (cons collection
                              (supertag--persistence--canonicalize-value
                               (supertag-store-get-collection collection))))
                      collections)))
      (should (equal before-query supertag-query-saved))
      (should (equal before-files
                     (mapcar (lambda (file)
                               (with-temp-buffer
                                 (insert-file-contents-literally file)
                                 (buffer-string)))
                             files))))))

(ert-deftest supertag-org-tag-token-rewrite-is-explicit-and-recoverable ()
  "An explicit migration rewrites Org tokens after a semantic rename."
  (supertag-ownership-test-with-vault
    (dolist (entry `((,supertag-ownership-test-node-a . "project")
                     (,supertag-ownership-test-node-b . "reference")))
      (supertag-store-put-entity
       :nodes (car entry)
       (plist-put (copy-tree (supertag-node-get (car entry)))
                  :tag-occurrences (list (cdr entry)))))
    (let* ((project-file (car files))
           (supertag-sync--state
            (list :sync-state (make-hash-table :test 'equal)))
           (supertag-sync--state-source
            (expand-file-name "sync-state.el" supertag-data-directory))
           (supertag-sync--deferred-files (make-hash-table :test 'equal))
           (supertag-sync--internal-modifications (make-hash-table :test 'equal))
           (result (supertag-migration-run-stable-tags t))
           (tag-id (cdr (assoc "project" (plist-get result :mapping)))))
      (with-temp-buffer
        (insert-file-contents project-file)
        (goto-char (point-min))
        (insert "#+FILETAGS: :project:other:\n")
        (write-region nil nil project-file nil 'silent))
      (supertag-tag-rename tag-id "initiative")
      (let* ((before-semantic (supertag-ownership-test-semantic-fingerprint))
             (audit
              (supertag-migration-audit-tag-token-rewrite
               "project" "initiative"))
             applied)
        (should (plist-get audit :safe-to-apply))
        (should (= 2 (plist-get audit :occurrences)))
        (should (= 1 (length (plist-get audit :files))))
        (setq applied
              (cl-letf (((symbol-function 'supertag-sync-save-state) #'ignore))
                (supertag-migration-rewrite-tag-token
                 "project" "initiative" t)))
        (should (eq :rewritten (plist-get applied :status)))
        (should (= 2 (plist-get applied :occurrences)))
        (with-temp-buffer
          (insert-file-contents project-file)
          (should-not (search-forward "#project" nil t))
          (goto-char (point-min))
          (should-not (search-forward ":project:" nil t))
          (goto-char (point-min))
          (should (search-forward "#+FILETAGS: :initiative:other:" nil t))
          (should (search-forward "#initiative" nil t)))
        (should (equal tag-id
                       (supertag-tag-resolve-occurrence "project")))
        (should (equal tag-id
                       (supertag-tag-resolve-occurrence "initiative")))
        (should (equal '("initiative")
                       (plist-get
                        (supertag-node-get supertag-ownership-test-node-a)
                        :tag-occurrences)))
        (should (equal (list tag-id)
                       (plist-get
                        (supertag-node-get supertag-ownership-test-node-a)
                        :tags)))
        (should (equal before-semantic
                       (supertag-ownership-test-semantic-fingerprint)))))))

(ert-deftest supertag-stable-tag-apply-reruns-audit-and-fails-closed ()
  "An alias conflict prevents both mutation and backup creation."
  (supertag-ownership-test-with-vault
    (dolist (id '("project" "reference"))
      (let ((tag (copy-tree (supertag-tag-get id))))
        (supertag-store-put-entity
         :tags id (plist-put tag :aliases '("shared")))))
    (let ((before (supertag--persistence--canonicalize-value supertag--store)))
      (should-error (supertag-migration-run-stable-tags t) :type 'user-error)
      (should (equal before
                     (supertag--persistence--canonicalize-value supertag--store)))
      (should-not (file-directory-p supertag-db-backup-directory)))))

(ert-deftest supertag-stable-tag-apply-rolls-back-after-backup ()
  "A post-write failure restores Store and loaded configuration."
  (supertag-ownership-test-with-vault
    (dolist (entry `((,supertag-ownership-test-node-a . "project")
                     (,supertag-ownership-test-node-b . "reference")))
      (supertag-store-put-entity
       :nodes (car entry)
       (plist-put (copy-tree (supertag-node-get (car entry)))
                  :tag-occurrences (list (cdr entry)))))
    (let* ((views (make-hash-table :test 'eq))
           (supertag--view-configs views)
           before-store before-query before-views)
      (puthash 'ownership-view
               '(:id ownership-view :query (:type :tag :value "project"))
               views)
      (setq before-store (supertag--persistence--canonicalize-value supertag--store)
            before-query (copy-tree supertag-query-saved)
            before-views (supertag--persistence--canonicalize-value views))
      (cl-letf (((symbol-function 'supertag-tag-merge--rebuild-derived-state)
                 (lambda () (error "Injected rebuild failure"))))
        (should-error (supertag-migration-run-stable-tags t)))
      (should (equal before-store
                     (supertag--persistence--canonicalize-value supertag--store)))
      (should (equal before-query supertag-query-saved))
      (should (equal before-views
                     (supertag--persistence--canonicalize-value
                      supertag--view-configs)))
      (should (directory-files supertag-db-backup-directory nil
                               "supertag-prestable-tags-")))))

(ert-deftest supertag-global-field-audit-conflicts-fail-closed ()
  "Definition/value mismatches block the existing force-write entry point."
  (supertag-ownership-test-with-vault
    (let* ((supertag-use-global-fields t)
           (project (copy-tree (supertag-store-get-entity :tags "project")))
           (reference (copy-tree (supertag-store-get-entity :tags "reference")))
           report before reasons)
      (supertag-store-put-entity
       :tags "project"
       (plist-put project :fields '((:name "Status" :type :string)
                                    (:name "Priority" :type :string))))
      (supertag-store-put-entity
       :tags "reference"
       (plist-put reference :fields '((:name " priority "))))
      ;; A malformed target must become a report conflict, not abort audit.
      (puthash "status" :malformed
               (supertag-store-get-collection :field-definitions))
      ;; Matching IDs are not enough to overwrite extra association semantics.
      (supertag-store-put-tag-field-associations
       "project" '((:field-id "status" :order 0 :required t)))
      (supertag-store-put-legacy-field
       supertag-ownership-test-node-a "project" "Status" "legacy")
      (setq report (supertag-migration-audit-global-fields)
            before (supertag--persistence--canonicalize-value supertag--store)
            reasons (mapcar (lambda (item) (plist-get item :reason))
                            (plist-get report :conflicts)))
      (should-not (plist-get report :safe-to-apply))
      (should (memq :definition-target-mismatch reasons))
      (should (memq :invalid-field-definition reasons))
      (should (memq :display-name-collision reasons))
      (should (memq :association-target-mismatch reasons))
      (should (memq :global-value-mismatch reasons))
      (should-error (supertag-migration-run-global-fields t)
                    :type 'user-error)
      (should (equal before
                     (supertag--persistence--canonicalize-value supertag--store))))))

(ert-deftest supertag-global-field-audit-allows-clean-existing-migration ()
  "The audit gate preserves the existing conflict-free apply path."
  (supertag-ownership-test-with-vault
    (let* ((supertag-use-global-fields t)
           (project (copy-tree (supertag-store-get-entity :tags "project"))))
      (clrhash (supertag-store-get-collection :field-definitions))
      (clrhash (supertag-store-get-collection :tag-field-associations))
      (clrhash (supertag-store-get-collection :field-values))
      (supertag-store-put-entity
       :tags "project"
       (plist-put project :fields '((:name "Status" :type :string))))
      (supertag-store-put-legacy-field
       supertag-ownership-test-node-a "project" "Status" "ready")
      (should (plist-get (supertag-migration-audit-global-fields)
                         :safe-to-apply))
      (supertag-migration-run-global-fields t)
      (should (eq :string
                  (plist-get (supertag-store-get-field-definition "status")
                             :type)))
      (should (equal '((:field-id "status" :order 0))
                     (supertag-store-get-tag-field-associations "project")))
      (should (equal "ready"
                     (supertag-store-get-field-value
                      supertag-ownership-test-node-a "status"))))))

(ert-deftest supertag-global-field-audit-reports-orphans ()
  "Legacy and global values without owners are reported and block migration."
  (supertag-ownership-test-with-vault
    (let ((reference
           (copy-tree (supertag-store-get-entity :tags "reference"))))
      (supertag-store-put-entity
       :tags "reference"
       (plist-put reference :fields '((:name "Ghost" :type :string))))
      (supertag-store-put-legacy-field
       supertag-ownership-test-node-a "reference" "Ghost" "stale")
      (supertag-store-put-legacy-field
       "missing-node" "missing-tag" "Ghost" "legacy")
      (supertag-store-put-field-value "missing-node" "missing-field" "global")
      (supertag-store-put-tag-field-associations
       "missing-tag" '((:field-id "missing-field" :order 0))))
    (let* ((report (supertag-migration-audit-global-fields))
           (orphans (plist-get report :orphans))
           (kinds (mapcar (lambda (item) (plist-get item :kind)) orphans))
           (reasons (apply #'append
                           (mapcar (lambda (item) (plist-get item :reasons))
                                   orphans))))
      (should-not (plist-get report :safe-to-apply))
      (should (memq :legacy-value kinds))
      (should (memq :global-value kinds))
      (should (memq :global-association kinds))
      (should (memq :missing-node reasons))
      (should (memq :missing-tag reasons))
      (should (memq :tag-not-on-node reasons))
      (should (memq :undeclared-field reasons))
      (should (memq :missing-field-definition reasons)))))

(ert-deftest supertag-global-fields-are-the-only-production-write-path ()
  "Legacy configuration cannot make production field APIs write legacy data."
  (supertag-ownership-test-with-vault
    ;; Existing user configs may still set this obsolete option to nil.  The
    ;; cutover must ignore it instead of reopening the legacy writer.
    (let ((supertag-use-global-fields nil))
      (clrhash (supertag-store-get-collection :field-definitions))
      (clrhash (supertag-store-get-collection :tag-field-associations))
      (clrhash (supertag-store-get-collection :field-values))
      (supertag-tag-add-field
       "project" '(:name "Status" :type :string))
      (supertag-tag-add-field
       "project" '(:name "Priority" :type :integer))
      (supertag-field-set
       supertag-ownership-test-node-a "project" "Status" "active")
      (supertag-field-set-many
       supertag-ownership-test-node-a
       '((:tag "project" :field "Status" :value "done")
         (:tag "project" :field "Priority" :value 2)))
      (supertag-tag-move-field-up "project" "priority")
      (should (equal '("priority" "status")
                     (mapcar #'supertag--assoc-entry-field-id
                             (supertag-store-get-tag-field-associations
                              "project"))))
      (should (= 2 (supertag-field-remove
                    supertag-ownership-test-node-a
                    "project" "Priority")))
      (supertag-tag-remove-field "project" "Priority")
      (should (supertag-store-get-field-definition "status"))
      (should (supertag-store-get-field-definition "priority"))
      (should (equal '("status")
                     (mapcar #'supertag--assoc-entry-field-id
                             (supertag-store-get-tag-field-associations
                              "project"))))
      (should (equal "done"
                     (supertag-store-get-field-value
                      supertag-ownership-test-node-a "status")))
      (supertag-tag-rename-field "project" "Status" "State")
      (should (equal "done"
                     (supertag-field-get
                      supertag-ownership-test-node-a "project" "State")))
      (should (equal (list supertag-ownership-test-node-a)
                     (supertag-query--find-nodes-by-field-indexed
                      "State" "done")))
      (should (member "status"
                      (supertag--extract-trigger-sources
                       '(field-changed "State"))))
      (should
       (eq :unknown
           (supertag-automation--event-type
            (list :path
                  (list :fields supertag-ownership-test-node-a
                        "project" "Status")))))
      (should-not
       (supertag-automation--trigger-match-p
        :on-field-change
        (list :path
              (list :fields supertag-ownership-test-node-a
                    "project" "Status"))))
      (let ((supertag-automation--current-event
             (list :path
                   (list :field-values
                         supertag-ownership-test-node-a "status"))))
        (should
         (supertag-automation--eval-single-condition
          '(field-changed "State")
          (supertag-store-get-entity
           :nodes supertag-ownership-test-node-a))))
      (should-not (fboundp 'supertag-automation-sync--update-node-field))
      (should (equal "done"
                     (supertag-store-get-field-value
                      supertag-ownership-test-node-a "status")))
      (should (eq :missing
                  (supertag-store-get-field-value
                   supertag-ownership-test-node-a "state" :missing)))
      (should (eq :missing
                  (supertag-store-get-field-value
                   supertag-ownership-test-node-a "priority" :missing)))
      (should-not (plist-get (supertag-store-get-entity :tags "project")
                             :fields))
      (should (zerop (hash-table-count
                      (supertag-store-get-collection :fields)))))))

(ert-deftest supertag-global-field-cutover-preserves-consumer-parity ()
  "Migration preserves Table/Node/Kanban/Automation output without legacy reads."
  (supertag-ownership-test-with-vault
    (let* ((supertag-use-global-fields nil)
           (node-id supertag-ownership-test-node-a)
           (tag-id "project")
           (node (supertag-store-get-entity :nodes node-id))
           backup-files
           legacy-snapshot)
      (clrhash (supertag-store-get-collection :field-definitions))
      (clrhash (supertag-store-get-collection :tag-field-associations))
      (clrhash (supertag-store-get-collection :field-values))
      (supertag-store-put-entity
       :tags tag-id
       (plist-put (copy-tree (supertag-store-get-entity :tags tag-id))
                  :fields '((:name "Status" :type :string))))
      (supertag-store-put-legacy-field node-id tag-id "Status" "active")
      (setq legacy-snapshot
            (supertag--persistence--canonicalize-value
             (list :definitions
                   (plist-get (supertag-store-get-entity :tags tag-id) :fields)
                   :values (supertag-store-get-collection :fields))))
      (supertag-migration-run-global-fields t)
      (setq backup-files
            (directory-files
             supertag-db-backup-directory t
             "\\`supertag-db-preglobal-fields-.*\\.el\\'"))
      (should (= 1 (length backup-files)))
      (let* ((backup-store
              (supertag--persistence--try-read-store
               (car backup-files)))
             (backup-tag
              (gethash tag-id (gethash :tags backup-store))))
        (should
         (equal legacy-snapshot
                (supertag--persistence--canonicalize-value
                 (list :definitions (plist-get backup-tag :fields)
                       :values (gethash :fields backup-store))))))
      (supertag-ops-schema-rebuild-cache)
      (cl-labels
          ((consumer-snapshot ()
             (let* ((column '(:name "Status" :key status
                              :field-id "status" :type :string))
                    (grouped
                     (supertag-view-kanban--group-nodes-by-field
                      (list (cons node-id node)) tag-id "Status")))
               (list
                (cl-letf (((symbol-function
                            'supertag-view-table--get-current-query-obj)
                           (lambda () '(:type :tag)))
                          ((symbol-function
                            'supertag-view-table--get-current-tag-id)
                           (lambda () tag-id)))
                  (substring-no-properties
                   (supertag-view-table--get-cell-value
                    node 'status column)))
                (length (gethash "active" grouped))
                (supertag-automation--get-field-value
                 node-id (list tag-id) "Status")))))
        (should (equal '("active" 1 "active")
                       (consumer-snapshot)))
        (supertag-field-set node-id tag-id "Status" "done")
        (should (equal '("done" 0 "done")
                       (consumer-snapshot))))
      (should
       (equal legacy-snapshot
              (supertag--persistence--canonicalize-value
               (list :definitions
                     (plist-get (supertag-store-get-entity :tags tag-id)
                                :fields)
                     :values (supertag-store-get-collection :fields))))))))

(ert-deftest supertag-global-field-cutover-rolls-back-on-error ()
  "A failed cutover restores global collections and retains its backup."
  (supertag-ownership-test-with-vault
    (let* ((node-id supertag-ownership-test-node-a)
           (tag-id "project")
           before
           backup-files)
      (clrhash (supertag-store-get-collection :field-definitions))
      (clrhash (supertag-store-get-collection :tag-field-associations))
      (clrhash (supertag-store-get-collection :field-values))
      (supertag-store-put-entity
       :tags tag-id
       (plist-put (copy-tree (supertag-store-get-entity :tags tag-id))
                  :fields '((:name "Status" :type :string))))
      (supertag-store-put-legacy-field node-id tag-id "Status" "active")
      (setq before
            (supertag--persistence--canonicalize-value
             (list (supertag-store-get-collection :field-definitions)
                   (supertag-store-get-collection :tag-field-associations)
                   (supertag-store-get-collection :field-values))))
      (cl-letf (((symbol-function
                  'supertag-migration--migrate-field-values)
                 (lambda (&rest _)
                   (error "forced cutover failure"))))
        (should-error (supertag-migration-run-global-fields t)
                      :type 'error))
      (should
       (equal before
              (supertag--persistence--canonicalize-value
               (list (supertag-store-get-collection :field-definitions)
                     (supertag-store-get-collection
                      :tag-field-associations)
                     (supertag-store-get-collection :field-values)))))
      (setq backup-files
            (directory-files
             supertag-db-backup-directory t
             "\\`supertag-db-preglobal-fields-.*\\.el\\'"))
      (should (= 1 (length backup-files)))
      (let ((backup-store
             (supertag--persistence--try-read-store
              (car backup-files))))
        (dolist (collection '(:field-definitions
                              :tag-field-associations
                              :field-values))
          (let ((table (gethash collection backup-store)))
            (should (zerop (if (hash-table-p table)
                               (hash-table-count table)
                             0)))))
        (should
         (equal "active"
                (gethash "Status"
                         (gethash tag-id
                                  (gethash node-id
                                           (gethash :fields backup-store))))))))))

(provide 'ownership-separation-test)

;;; ownership-separation-test.el ends here
