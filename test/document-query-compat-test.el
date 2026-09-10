;;; document-query-compat-test.el --- Historical fact protection -*- lexical-binding: t; -*-
(require 'legacy-field-fixture)
(require 'ert)
(require 'document-fixture)
(require 'supertag-query)

(ert-deftest supertag-document-query-compat-preserves-historical-facts ()
  "Conflicting old fields, edges, boards and configuration survive reads."
  (supertag-document-test-with-vault
    (supertag-test-legacy-definition
     "alpha" '(:id "alpha" :name "ALPHA" :type :text :default "legacy-default"))
    (supertag-test-legacy-value "document-node" "alpha" "legacy-value")
    (dolist (collection '(:fields :tag-field-associations :relations :boards
                         :automations :sync-conflicts :ontology-modules))
      (supertag-store-put-entity collection "historical"
                                 '(:id "historical" :kind :semantic-edge
                                   :payload ("preserve" "exactly"))))
    (let ((before (prin1-to-string supertag--store))
          (disk (supertag-document-test-disk file)))
      (dolist (read (list (supertag-note-query-read-node "document-node")
                         (supertag-query-node-detail "document-node")))
        (should (equal '("first" "" "last")
                       (mapcar (lambda (e) (plist-get e :value))
                               (plist-get read :properties)))))
      (should (equal (plist-get (supertag-note-query-read-node "document-node") :properties)
                     (supertag-query-node-properties "document-node")))
      (should (eq :ALPHA (supertag-query-normalize-property-key "aLpHa")))
      (should (equal before (prin1-to-string supertag--store)))
      (should (equal disk (supertag-document-test-disk file)))
      ;; Exercise the existing canonical disk format on synthetic history only.
      (let* ((snapshot-file (expand-file-name "historical-roundtrip.el" tmp))
             (snapshot (with-temp-buffer
                         (supertag--persistence--write-canonical-store
                          supertag--store (current-buffer))
                         (buffer-string))))
        (with-temp-file snapshot-file (insert snapshot))
        (let ((restored (supertag--persistence--try-read-store snapshot-file)))
          (should (equal snapshot
                         (with-temp-buffer
                           (supertag--persistence--write-canonical-store
                            restored (current-buffer))
                           (buffer-string)))))))))

(provide 'document-query-compat-test)
