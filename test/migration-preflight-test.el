;;; migration-preflight-test.el --- Read-only preflight tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(when load-file-name
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))
(require 'supertag-migration-preflight)

(defun migration-preflight-test--table (&rest pairs)
  (let ((table (make-hash-table :test 'equal)))
    (while pairs
      (puthash (pop pairs) (pop pairs) table))
    table))

(defmacro migration-preflight-test--fixture (&rest body)
  (declare (indent 0))
  `(let* ((file (make-temp-file "supertag-preflight-" nil ".org"
                                "* Note\n:PROPERTIES:\n:ID: n1\n:AUTHOR: Alice\n:TITLE: Old\n:SUPERTAG_CONCEPT: t\n:END:\nBody\n"))
          (store (migration-preflight-test--table
                  :nodes (migration-preflight-test--table "n1" (list :id "n1" :file file)))))
     (unwind-protect (progn ,@body)
       (when-let* ((buffer (find-buffer-visiting file)))
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (delete-file file))))

(ert-deftest migration-preflight-property-statuses-and-concept ()
  (migration-preflight-test--fixture
    (puthash :field-values
             (migration-preflight-test--table
              "n1" (migration-preflight-test--table
                    "author" "Alice" "title" "New" "year" 2026)) store)
    (let* ((report (supertag-migration-preflight store))
           (fields (plist-get report :fields)))
      (should (equal (mapcar (lambda (entry) (plist-get entry :status)) fields)
                     '(equal conflicting missing)))
      (should (equal (plist-get (car (plist-get report :concept-markers)) :node) "n1"))
      (should-not (plist-get report :issues)))))

(ert-deftest migration-preflight-prefers-live-text-without-state-changes ()
  (migration-preflight-test--fixture
    (let ((buffer (find-file-noselect file)))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "Alice")
        (replace-match "Unsaved")
        (narrow-to-region (line-beginning-position) (line-end-position))
        (puthash :field-values
                 (migration-preflight-test--table
                  "n1" (migration-preflight-test--table "author" "Unsaved")) store)
        (let ((text (buffer-string)) (pos (point)) (lo (point-min))
              (hi (point-max)) (tick (buffer-chars-modified-tick))
              (before (prin1-to-string store)))
          (should (eq (plist-get (car (plist-get (supertag-migration-preflight store)
                                                :fields)) :status) 'equal))
          (should (equal before (prin1-to-string store)))
          (should (equal text (buffer-string)))
          (should (= pos (point)))
          (should (= lo (point-min)))
          (should (= hi (point-max)))
          (should (= tick (buffer-chars-modified-tick)))
          (should (buffer-modified-p)))))
    (with-temp-buffer
      (insert-file-contents file)
      (should (search-forward "Alice" nil t)))))

(ert-deftest migration-preflight-clean-buffer-stays-clean ()
  (migration-preflight-test--fixture
    (let ((buffer (find-file-noselect file)))
      (supertag-migration-preflight store)
      (should-not (buffer-modified-p buffer)))))

(ert-deftest migration-preflight-collisions-reserved-and-unsupported ()
  (migration-preflight-test--fixture
    (puthash :fields (migration-preflight-test--table "old" 1) store)
    (puthash :field-values
             (migration-preflight-test--table
              "n1" (migration-preflight-test--table
                    "a-b" "x" "a b" "y" "id" "different"
                    "reference" '("n2") "weird" [1 2])) store)
    (puthash :field-definitions
             (migration-preflight-test--table "reference" '(:type :node-reference)) store)
    (let ((issues (mapcar #'car (plist-get (supertag-migration-preflight store) :issues))))
      (should (memq :unsupported-legacy-fields issues))
      (should (memq :property-name-collision issues))
      (should (memq :reserved-property issues))
      (should (= 2 (cl-count :unsupported-field-value issues))))))

(ert-deftest migration-preflight-missing-malformed-and-duplicate-id ()
  (migration-preflight-test--fixture
    (puthash "absent" (list :file (concat file ".missing")) (gethash :nodes store))
    (puthash "broken" '(bad . data) (gethash :nodes store))
    (puthash :field-values (migration-preflight-test--table "n1" '(wrong)) store)
    (puthash :relations (migration-preflight-test--table "broken" '(wrong)) store)
    (let ((issues (mapcar #'car (plist-get (supertag-migration-preflight store) :issues))))
      (should (= 2 (cl-count :source-unavailable issues)))
      (should (memq :malformed-field-values issues))
      (should (memq :malformed-relation issues)))
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (insert "* Duplicate\n:PROPERTIES:\n:ID: n1\n:END:\n"))
    (should (= 3 (cl-count :source-unavailable
                          (mapcar #'car (plist-get (supertag-migration-preflight store) :issues)))))))

(ert-deftest migration-preflight-tags-rules-edges-and-determinism ()
  (migration-preflight-test--fixture
    (puthash :tags (migration-preflight-test--table
                    "c" '(:name "book" :extends ("p") :aliases ("books"))
                    "p" '(:name "media")) store)
    (puthash :automations (migration-preflight-test--table "rule" '(:name "Rule")) store)
    (puthash :relations (migration-preflight-test--table
                         "r" '(:type :supports :from "n1" :to "n2" :origin :semantic)
                         "doc" '(:type :reference :origin :org :from "n1" :to "n2")) store)
    (let ((report (supertag-migration-preflight store))
          (reverse-store (make-hash-table :test 'equal)))
      (dolist (pair (reverse (supertag-migration-preflight--entries store)))
        (let ((copy (make-hash-table :test 'equal)))
          (dolist (entry (reverse (supertag-migration-preflight--entries (cdr pair))))
            (puthash (car entry) (cdr entry) copy))
          (puthash (car pair) copy reverse-store)))
      (should (equal report (supertag-migration-preflight reverse-store)))
      (should (equal "media/book" (plist-get (car (plist-get report :tags)) :path)))
      (should (= 1 (length (plist-get report :semantic-edges))))
      (should (plist-get (car (plist-get report :automations)) :requires-durable-configuration)))))

(ert-deftest migration-preflight-rejects-cyclic-tag-path-and-remote-source ()
  (let ((store (migration-preflight-test--table
                :nodes (migration-preflight-test--table
                        "n" '(:file "/ssh:example:/notes.org"))
                :tags (migration-preflight-test--table
                       "t" '(:name "tag" :extends ("t"))))))
    (let ((issues (mapcar #'car (plist-get (supertag-migration-preflight store) :issues))))
      (should (memq :source-unavailable issues))
      (should (memq :tag-mapping-unavailable issues)))))

(ert-deftest migration-preflight-empty-store-does-not-initialize ()
  (let ((store (make-hash-table :test 'equal)))
    (should-not (plist-get (supertag-migration-preflight store) :issues))
    (should (= 0 (hash-table-count store)))
    (should-not (commandp #'supertag-migration-preflight)))
  (should-error (supertag-migration-preflight nil)))

(ert-deftest migration-preflight-unknown-relation-ownership-is-explicit ()
  (let* ((store (migration-preflight-test--table
                 :relations (migration-preflight-test--table
                             "unknown" '(:kind :future-kind :origin :future-origin
                                         :type :supports :from "n1" :to "n2"))))
         (report (supertag-migration-preflight store)))
    (should-not (plist-get report :semantic-edges))
    (should (equal '((:unsupported-relation-ownership "unknown"
                     :future-kind :future-origin))
                   (plist-get report :issues)))))

(ert-deftest migration-preflight-inconsistent-relations-are-explicit ()
  (let* ((store (migration-preflight-test--table
                 :relations (migration-preflight-test--table
                             "conflict" '(:kind :document-link :origin :semantic
                                          :type :reference :from "n1" :to "n2")
                             "missing" '(:kind :semantic-edge :origin :semantic
                                         :type :supports :from "n1"))))
         (report (supertag-migration-preflight store)))
    (should-not (plist-get report :semantic-edges))
    (should (equal '(:unsupported-relation-ownership :invalid-relation-endpoints)
                   (mapcar #'car (plist-get report :issues))))))

(ert-deftest migration-preflight-legacy-property-is-not-silently-missing ()
  (migration-preflight-test--fixture
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (search-forward ":AUTHOR: Alice")
      (replace-match ":ST_AUTHOR: Bob"))
    (puthash :field-values (migration-preflight-test--table
                           "n1" (migration-preflight-test--table "author" "Alice")) store)
    (should (equal '((:unsupported-legacy-property "n1" "author" "ST_AUTHOR"))
                   (plist-get (supertag-migration-preflight store) :issues)))))

(ert-deftest migration-preflight-malformed-collections-and-orphan-values ()
  (let* ((store (migration-preflight-test--table
                 :nodes '(bad) :tags "bad" :field-definitions [bad]
                 :field-values (migration-preflight-test--table
                                "orphan" (migration-preflight-test--table "key" "value"))))
         (before (prin1-to-string store))
         (report (supertag-migration-preflight store))
         (kinds (mapcar #'car (plist-get report :issues))))
    (should (= 3 (cl-count :malformed-collection kinds)))
    (should (memq :field-source-unavailable kinds))
    (should (eq 'unavailable (plist-get (car (plist-get report :fields)) :status)))
    (should (equal before (prin1-to-string store)))))

(ert-deftest migration-preflight-typed-values-are-conservative ()
  (migration-preflight-test--fixture
    (puthash :field-values
             (migration-preflight-test--table
              "n1" (migration-preflight-test--table "flag" nil "unknown" "value"
                                                    "malformed" "value")) store)
    (puthash :field-definitions
             (migration-preflight-test--table
              "flag" '(:type :boolean) "unknown" '(:type :future-type)
              "malformed" '(bad . definition)) store)
    (let* ((report (supertag-migration-preflight store))
           (fields (plist-get report :fields)))
      (should (equal "false" (plist-get (car fields) :proposed)))
      (should (= 2 (cl-count 'unsupported fields :key (lambda (field) (plist-get field :status)))))
      (should (memq :malformed-field-definition (mapcar #'car (plist-get report :issues)))))))

(provide 'migration-preflight-test)
;;; migration-preflight-test.el ends here
