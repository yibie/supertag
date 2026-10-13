;;; property-link-test.el --- Links written in property values -*- lexical-binding: t; -*-
(require 'add-link-workflow-test)
(require 'supertag-query)

(defun supertag-property-link-test--write (file id title drawer &optional body)
  "Write and project node ID in FILE with the property lines DRAWER."
  (when-let* ((visiting (find-buffer-visiting file)))
    (kill-buffer visiting))
  (with-temp-file file
    (insert (format "* %s\n:PROPERTIES:\n:ID: %s\n%s:END:\n%s\n"
                    title id drawer (or body ""))))
  (with-current-buffer (find-file-noselect file)
    (org-mode) (goto-char (point-min)) (supertag-node-sync-at-point)))

(defmacro supertag-property-link-test--vault (types &rest body)
  (declare (indent 1))
  `(supertag-add-link-test--isolated
     (let ((supertag-property-link-types ,types))
       (supertag-add-link-test--write-node
        (expand-file-name "target.org" tmp) "target" "Target")
       (supertag-property-link-test--write
        (expand-file-name "note.org" tmp) "note" "Note"
        (concat ":REFERENCE: [[chai:book-a][First]] [[chai:book-b::12][Second]]\n"
                ":SEE: [[id:target][Target]]\n"
                ":SITE: [[https://example.org/x][Site]]\n"))
       ,@body)))

(ert-deftest supertag-property-link-node-link-is-a-reference ()
  (supertag-property-link-test--vault nil
    (should (equal '("target") (plist-get (supertag-node-get "note") :ref-to)))
    (should (equal '("note") (supertag-property-links-to "id:target")))
    (should (equal '("note") (supertag-query-node-ids '(links-to "id:target"))))))

(ert-deftest supertag-property-link-unlisted-type-is-not-kept ()
  (supertag-property-link-test--vault nil
    (should-not (plist-get (supertag-node-get "note") :property-links))
    (should-not (supertag-property-links-to "chai:book-a"))))

(ert-deftest supertag-property-link-listed-type-is-kept ()
  (supertag-property-link-test--vault '("chai")
    (should (equal '((:key "REFERENCE" :type "chai" :path "book-a"
                      :description "First")
                     (:key "REFERENCE" :type "chai" :path "book-b::12"
                      :description "Second"))
                   (plist-get (supertag-node-get "note") :property-links)))
    (should (equal '("note") (supertag-query-node-ids '(links-to "chai:book-a"))))
    (should (equal '("note") (supertag-query-node-ids '(links-to "chai:book-b"))))
    (should-not (supertag-query-node-ids '(links-to "chai:book")))
    (should-not (supertag-query-node-ids '(links-to "https://example.org/x")))))

(ert-deftest supertag-property-link-removed-link-is-forgotten ()
  (supertag-property-link-test--vault '("chai")
    (supertag-property-link-test--write
     (expand-file-name "note.org" tmp) "note" "Note" ":REFERENCE: none\n")
    (let ((node (supertag-node-get "note")))
      (should-not (plist-get node :property-links))
      (should-not (plist-get node :ref-to)))
    (should-not (supertag-query-node-ids '(links-to "chai:book-a")))))

;;; The creation time a node gets from its CREATED property.

(defun supertag-property-link-test--created (id)
  "Return the creation time of node ID as text."
  (format-time-string "%Y-%m-%d %H:%M" (plist-get (supertag-node-get id) :created-at)))

(ert-deftest supertag-property-link-created-property-dates-the-node ()
  (supertag-add-link-test--isolated
    (let ((file (expand-file-name "note.org" tmp)))
      (supertag-property-link-test--write
       file "plain" "Plain" ":CREATED: 2026-10-05 21:10\n")
      (should (equal "2026-10-05 21:10"
                     (supertag-property-link-test--created "plain")))
      ;; Editing the property moves the node.
      (supertag-property-link-test--write
       file "plain" "Plain" ":CREATED: [2026-10-07 Wed 08:30]\n")
      (should (equal "2026-10-07 08:30"
                     (supertag-property-link-test--created "plain")))
      (supertag-property-link-test--write
       file "plain" "Plain" ":CREATED: 2026-10-08\n")
      (should (equal "2026-10-08 00:00"
                     (supertag-property-link-test--created "plain"))))))

(ert-deftest supertag-property-link-node-without-created-keeps-its-time ()
  (supertag-add-link-test--isolated
    (let ((file (expand-file-name "note.org" tmp)))
      (supertag-property-link-test--write file "bare" "Bare" "")
      (let ((first (plist-get (supertag-node-get "bare") :created-at)))
        (should first)
        (supertag-property-link-test--write
         file "bare" "Bare" ":CREATED: someday\n" "Body.")
        (should (equal first
                       (plist-get (supertag-node-get "bare") :created-at)))))))

(ert-deftest supertag-property-link-query-rejects-a-bare-word ()
  (should-error (supertag-query--parse-sexp '(links-to "book")))
  (should-error (supertag-query--parse-sexp '(links-to))))

(provide 'property-link-test)
;;; property-link-test.el ends here
