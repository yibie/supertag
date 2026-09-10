;;; query-model-test.el --- Concrete Query Model contracts -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with: ./test/run-tests.sh query-model

;;; Code:

(require 'ert)

(when load-file-name
  (add-to-list 'load-path (file-name-directory load-file-name))
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))

(require 'ownership-fixture)
(require 'supertag-query)
(progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener))
(require 'supertag-tag)

(defun supertag-query-model-test--relation-ids (relations)
  "Return sorted IDs from RELATIONS."
  (sort (mapcar (lambda (relation) (plist-get relation :id)) relations)
        #'string<))

(ert-deftest supertag-query-model-exposes-concrete-node-and-tag-reads ()
  "Concrete node and Tag reads preserve the View API contract."
  (supertag-ownership-test-with-vault
    (let ((paths (supertag-query-tag-paths)))
      (should (equal '("Project" "Reference")
                     (mapcar (lambda (entry) (plist-get entry :display-path))
                             paths)))
      (should (equal (mapcar (lambda (entry) (plist-get entry :name)) paths)
                     (supertag-view-api-list-tags)))
      (should (equal (sort (mapcar (lambda (entry) (plist-get entry :id)) paths)
                           #'string<)
                     (supertag-view-api-list-tag-ids))))
    (let ((node-ids (supertag-query-node-ids-by-tag "project")))
      (should (equal (list supertag-ownership-test-node-a) node-ids))
      (should (equal node-ids (supertag-view-api-nodes-by-tag "project")))
      (should (equal node-ids
                     (supertag-view-api-list-entity-ids
                      '(:type :tag :value "project")))))))

(ert-deftest supertag-query-model-resolves-fields-and-values ()
  "Projected properties and values have View API parity."
  (supertag-ownership-test-with-vault
    (supertag-store-put-entity :nodes supertag-ownership-test-node-a
      (plist-put (copy-tree (supertag-node-get supertag-ownership-test-node-a))
                 :properties '(:STATUS "active")))
    (should (equal '(:STATUS)
                   (mapcar (lambda (property) (plist-get property :key))
                           (supertag-query-resolved-fields supertag-ownership-test-node-a))))
    (should (equal "active"
                   (supertag-query-field-value
                    supertag-ownership-test-node-a "project" "Status")))
    (should (equal
             (supertag-query-field-value
              supertag-ownership-test-node-a "project" "Status")
             (supertag-view-api-node-field-in-tag
              supertag-ownership-test-node-a "project" "Status")))))

(ert-deftest supertag-query-model-queries-relations-without-raw-collection-access ()
  "Relation reads cover outgoing, incoming, and induced subgraphs."
  (supertag-ownership-test-with-vault
    (should (equal (list supertag-ownership-test-document-link)
                   (supertag-query-model-test--relation-ids
                    (supertag-query-relations-from
                     supertag-ownership-test-node-a :reference))))
    (should (equal (list supertag-ownership-test-semantic-edge)
                   (supertag-query-model-test--relation-ids
                    (supertag-query-relations-to
                     supertag-ownership-test-node-a :supports))))
    (should (equal (sort (list supertag-ownership-test-document-link
                               supertag-ownership-test-semantic-edge)
                         #'string<)
                   (supertag-query-model-test--relation-ids
                    (supertag-query-relations-among
                     (list supertag-ownership-test-node-a
                           supertag-ownership-test-node-b)))))
    (should (equal (list supertag-ownership-test-semantic-edge)
                   (supertag-query-model-test--relation-ids
                    (supertag-query-relations-among
                     (list supertag-ownership-test-node-a
                           supertag-ownership-test-node-b)
                     nil :semantic-edge))))))

;; Node/property assertions now live in document-query-contract and public
;; node-view-properties. Historical field/Board tests below remain archive-only.

(ert-deftest supertag-query-model-builds-board-detail-for-the-serializer ()
  "Board detail composes placements, nodes, and their induced relations."
  (require 'supertag-board)
  (supertag-ownership-test-with-vault
    (supertag-board-add-node "ownership-board"
                             supertag-ownership-test-node-b 30 40 200 100)
    (let* ((detail (supertag-query-board-detail "ownership-board"))
           (nodes (plist-get detail :nodes))
           sent-type
           sent-data)
      (should (equal "ownership-board"
                     (plist-get (plist-get detail :board) :id)))
      (should (equal (sort (list supertag-ownership-test-node-a
                                 supertag-ownership-test-node-b)
                           #'string<)
                     (sort (mapcar (lambda (entry) (plist-get entry :id)) nodes)
                           #'string<)))
      (should (cl-every (lambda (entry) (plist-get entry :detail)) nodes))
      (should (equal (sort (list supertag-ownership-test-document-link
                                 supertag-ownership-test-semantic-edge)
                           #'string<)
                     (supertag-query-model-test--relation-ids
                      (plist-get detail :relations))))
      (cl-letf (((symbol-function 'supertag-board--ws-send)
                 (lambda (type data)
                   (setq sent-type type
                         sent-data data))))
        (supertag-board--send-board-data
         (supertag-board-get "ownership-board")))
      (should (equal "board-data" sent-type))
      (should (= 2 (length (alist-get 'nodes sent-data))))
      (should (= 2 (cl-count-if
                    (lambda (edge) (eq t (alist-get 'isGlobal edge)))
                    (append (alist-get 'edges sent-data) nil)))))))

(ert-deftest supertag-query-model-completion-consumes-concrete-reads ()
  "Completion helpers consume Tag paths and occurrence projections."
  (supertag-ownership-test-with-vault
    (should (equal (supertag-completion--get-all-tags)
                   (cl-remove-if-not
                    #'supertag-transform-inline-tag-name-p
                    (mapcar (lambda (entry) (plist-get entry :id))
                            (supertag-query-tag-paths)))))
    (should (equal (supertag-completion--get-all-tag-occurrences)
                   (cl-remove-if-not
                    #'supertag-transform-inline-tag-name-p
                    (supertag-query-tag-occurrences))))
    (should (equal (supertag-completion--get-node-tags
                    supertag-ownership-test-node-a)
                   (supertag-query-node-tags
                    supertag-ownership-test-node-a)))))

(ert-deftest supertag-query-model-executes-node-query-with-compatibility-parity ()
  "The public node-query shape preserves the S-expression entry point."
  (supertag-ownership-test-with-vault
    (supertag-store-put-entity :nodes supertag-ownership-test-node-a
      (plist-put (copy-tree (supertag-node-get supertag-ownership-test-node-a))
                 :properties '(:STATUS "active")))
    (let ((query '(and (tag "project") (property "Status" "active"))))
      (should (equal (list supertag-ownership-test-node-a)
                     (supertag-query-node-ids query)))
      (should (equal (supertag-query-node-ids query)
                     (supertag-query-sexp query))))))

(provide 'query-model-test)

;;; query-model-test.el ends here
