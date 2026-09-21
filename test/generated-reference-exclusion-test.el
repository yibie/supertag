;;; generated-reference-exclusion-test.el --- Generated view reference tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Machine-generated Org views are projections, not Document Link assertions.

;;; Code:

(require 'ert)

(when load-file-name
  (add-to-list 'load-path (file-name-directory load-file-name))
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'ownership-fixture)
(require 'supertag-services-sync)

(defun supertag-generated-reference-test--headline (text)
  "Parse TEXT and return its first Org headline."
  (with-temp-buffer
    (org-mode)
    (insert text)
    (car (org-element-map (org-element-parse-buffer) 'headline #'identity))))

(defun supertag-generated-reference-test--parse-nodes (text)
  "Project Org TEXT through the production parser and return its nodes."
  (with-temp-buffer
    (insert text)
    (supertag--parse-org-nodes-from-current-buffer
     "/tmp/generated-reference-test.org")))

(defun supertag-generated-reference-test--node (id nodes)
  "Return node ID from NODES."
  (cl-find id nodes :key (lambda (node) (plist-get node :id)) :test #'equal))

(ert-deftest supertag-closed-embed-excludes-inner-reference ()
  "A closed embed hides its links while surrounding prose remains authoritative."
  (let* ((nodes
          (supertag-generated-reference-test--parse-nodes
           (concat
            "* Source\n:PROPERTIES:\n:ID: source-id\n:END:\n"
            "Before [[id:before-id][Before]].\n"
            "#+begin_embed: target-id [Target]\n"
            "Generated [[id:hidden-id][Hidden]].\n"
            "#+end_embed\n"
            "After [[id:after-id][After]].\n")))
         (source (supertag-generated-reference-test--node "source-id" nodes)))
    (should (equal '("before-id" "after-id")
                   (plist-get source :ref-to)))))

(ert-deftest supertag-unclosed-embed-excludes-inner-reference ()
  "A damaged embed hides links through its entry end, not later headings."
  (let* ((nodes
          (supertag-generated-reference-test--parse-nodes
           (concat
            "* Broken\n:PROPERTIES:\n:ID: broken-id\n:END:\n"
            "Before [[id:before-id][Before]].\n"
            "#+begin_embed: target-id [Target]\n"
            "Generated [[id:leaked-id][Leaked]].\n"
            "* Following\n:PROPERTIES:\n:ID: following-id\n:END:\n"
            "Normal [[id:normal-id][Normal]].\n"
            "#+begin_embed: later-id [Later]\n"
            "Generated [[id:later-hidden-id][Later hidden]].\n"
            "#+end_embed\n"
            "After [[id:after-id][After]].\n")))
         (broken (supertag-generated-reference-test--node "broken-id" nodes))
         (following (supertag-generated-reference-test--node
                     "following-id" nodes)))
    (should (equal '("before-id") (plist-get broken :ref-to)))
    (should (equal '("normal-id" "after-id")
                   (plist-get following :ref-to)))))

(ert-deftest supertag-reference-outside-embed-remains-authoritative ()
  "An ordinary body link outside embed syntax remains a Document Link."
  (let* ((nodes
          (supertag-generated-reference-test--parse-nodes
           (concat
            "* Source\n:PROPERTIES:\n:ID: source-id\n:END:\n"
            "Normal [[id:normal-id][Normal]].\n")))
         (source (supertag-generated-reference-test--node "source-id" nodes)))
    (should (equal '("normal-id") (plist-get source :ref-to)))))

(ert-deftest supertag-reference-extractor-skips-generated-regions ()
  "Dynamic blocks and Babel results do not create Document Link facts."
  (let* ((headline
          (supertag-generated-reference-test--headline
           (concat
            "* Source\n"
            "Outside [[id:outside-id][Outside]].\n"
            "| [[id:manual-table-id][Manual table]] |\n\n"
            "#+BEGIN: supertag-query :query \"(tag \\\"project\\\")\"\n"
            "| [[id:dynamic-id][Dynamic]] |\n"
            "#+END:\n\n"
            "#+BEGIN_SRC supertag-query-block :results raw\n"
            "(tag \"project\")\n"
            "#+END_SRC\n\n"
            "#+RESULTS:\n"
            "| [[id:babel-table-id][Babel table]] |\n\n"
            "#+BEGIN_SRC emacs-lisp :results drawer\n"
            "\"[[id:babel-drawer-id][Babel drawer]]\"\n"
            "#+END_SRC\n\n"
            "#+RESULTS:\n"
            ":RESULTS:\n"
            "[[id:babel-drawer-id][Babel drawer]]\n"
            ":END:\n")))
         (refs (plist-get
                (supertag-extractor--refs headline nil nil)
                :ref-to)))
    (should (equal '("outside-id" "manual-table-id") refs))))

(ert-deftest supertag-file-reference-extraction-skips-generated-regions ()
  "File-level extraction applies the same generated-view boundary."
  (with-temp-buffer
    (org-mode)
    (insert
     "Outside [[id:file-outside-id][Outside]].\n\n"
     "#+BEGIN: supertag-query :query \"(tag \\\"project\\\")\"\n"
     "| [[id:file-dynamic-id][Dynamic]] |\n"
     "#+END:\n\n"
     "#+RESULTS:\n"
     "| [[id:file-result-id][Result]] |\n")
    (should
     (equal '("file-outside-id")
            (supertag--extract-refs
             (org-element-contents (org-element-parse-buffer)))))))

(ert-deftest supertag-reprojection-cleans-generated-document-link ()
  "Reprojection removes an old relation sourced only from generated output."
  (supertag-ownership-test-with-vault
    (let* ((project-file (car files))
           (supertag-sync--state
            (list :sync-state (make-hash-table :test 'equal)))
           (supertag-sync--deferred-files (make-hash-table :test 'equal))
           (supertag-sync--is-full-rescan-p t)
           (counters '(:nodes-created 0 :nodes-updated 0 :nodes-deleted 0
                       :references-created 0 :references-deleted 0)))
      (with-temp-file project-file
        (insert
         "* Project Alpha #project\n"
         ":PROPERTIES:\n"
         ":ID:       ownership-node-a\n"
         ":CREATED:  [2026-08-12 Wed 09:00]\n"
         ":END:\n"
         "#+BEGIN: supertag-query :query \"(tag \\\"reference\\\")\"\n"
         "| [[id:ownership-node-b][Reference Beta]] |\n"
         "#+END:\n"))
      (supertag-index-rebuild-relations)
      (should
       (supertag-relation-get supertag-ownership-test-document-link))
      (cl-letf (((symbol-function 'supertag-sync--allow-destructive-p)
                 (lambda () t)))
        (supertag-sync--process-single-file project-file counters))
      (should-not
       (supertag-relation-get supertag-ownership-test-document-link))
      (should-not
       (plist-get
        (supertag-node-get supertag-ownership-test-node-a)
        :ref-to))
      (should (= 1 (plist-get counters :references-deleted)))
      (should (= 0 (plist-get counters :references-created)))
      (should
       (supertag-relation-get supertag-ownership-test-semantic-edge)))))

(provide 'generated-reference-exclusion-test)

;;; generated-reference-exclusion-test.el ends here
