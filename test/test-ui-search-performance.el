;;; test-ui-search-performance.el --- Search hot-path tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'ht)
(require 'supertag-core-store)
(require 'supertag-ui-search)

(defmacro supertag-search-perf-test--isolated (&rest body)
  (declare (indent 0) (debug t))
  `(let ((supertag--store (ht-create))
         (supertag--index-source-revisions (make-hash-table :test #'eq))
         (case-fold-search t))
     (supertag--ensure-store)
     ,@body))

(defun supertag-search-perf-test--put-node (id title content)
  (supertag-store-put-entity
   :nodes id
   (list :id id :type :node :title title :content content
         :file (format "/tmp/%s.org" id)
         :tags '("notes")
         :properties '(:Owner "active" :State "open"))))

(defun supertag-search-perf-test--legacy-find (keywords)
  "Frozen pre-optimization search used as a result/context oracle."
  (let (results)
    (dolist (pair (supertag-query-nodes (lambda (_id data) data)))
      (let* ((node-data (cdr pair))
             (title (plist-get node-data :title))
             (content (plist-get node-data :content))
             (tags (plist-get node-data :tags))
             (properties (plist-get node-data :properties))
             (match-context nil)
             (all-match t))
        (dolist (keyword keywords)
          (let* ((keyword-re (regexp-quote keyword))
                 (title-match (and title (string-match-p keyword-re title)))
                 (tag-match
                  (and tags
                       (cl-some
                        (lambda (tag) (string-match-p keyword-re tag)) tags)))
                 (content-match
                  (and content (string-match keyword-re content)))
                 (field-match
                  (and properties
                       (cl-some
                        (lambda (prop)
                          (and (stringp prop)
                               (string-match-p keyword-re prop)))
                        (let (prop-values (props properties))
                          (while props
                            (push (cadr props) prop-values)
                            (setq props (cddr props)))
                          prop-values)))))
            (unless (or title-match tag-match content-match field-match)
              (setq all-match nil))
            (when (and content-match (not match-context))
              (let* ((match-start (match-beginning 0))
                     (context-start (max 0 (- match-start 40)))
                     (context-end
                      (min (length content) (+ (match-end 0) 40)))
                     (prefix (if (> context-start 0) "..." ""))
                     (suffix (if (< context-end (length content)) "..." "")))
                (setq match-context
                      (concat prefix
                              (substring content context-start context-end)
                              suffix))))))
        (when all-match
          (push (cons node-data match-context) results))))
    (nreverse results)))

(ert-deftest supertag-search-compiles-each-keyword-once-per-query ()
  "Literal regex preparation must not be repeated for every node."
  (supertag-search-perf-test--isolated
    (supertag-search-perf-test--put-node "one" "Node one" "Shared body")
    (supertag-search-perf-test--put-node "two" "Node two" "Shared body")
    (let ((quote-count 0)
          (original (symbol-function 'regexp-quote)))
      (cl-letf (((symbol-function 'regexp-quote)
                 (lambda (string)
                   (cl-incf quote-count)
                   (funcall original string))))
        (should (= 2 (length
                      (supertag-search-find-nodes
                       '("Node" "Shared" "active")))))
        (should (= 3 quote-count))))))

(ert-deftest supertag-search-sees-store-mutation-without-stale-results ()
  "A later search must observe node data changed through the Store API."
  (supertag-search-perf-test--isolated
    (supertag-search-perf-test--put-node "one" "Before" "No match")
    (should-not (supertag-search-find-nodes '("Needle")))
    (supertag-search-perf-test--put-node "one" "Needle" "Now matches")
    (should (equal "one"
                   (plist-get (caar (supertag-search-find-nodes '("Needle")))
                              :id)))))

(ert-deftest supertag-search-optimized-loop-matches-legacy-results-and-context ()
  "Hoisting and short-circuiting must preserve matches, order, and snippets."
  (supertag-search-perf-test--isolated
    (supertag-search-perf-test--put-node
     "one" "Node Needle" "prefix Shared body Needle suffix")
    (supertag-search-perf-test--put-node
     "two" "Other" "Shared body without the title word")
    (dolist (keywords '(() ("Node") ("Shared" "active")
                        ("Needle" "Shared" "open") ("missing" "Shared")))
      (should (equal (supertag-search-perf-test--legacy-find keywords)
                     (supertag-search-find-nodes keywords))))))

(provide 'test-ui-search-performance)
;;; test-ui-search-performance.el ends here
