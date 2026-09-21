;;; architecture-boundary-test.el --- Source-level architecture guards -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst supertag-architecture-test--root
  (expand-file-name ".." (file-name-directory load-file-name))
  "Repository root used by architecture source guards.")

(defconst supertag-architecture-test--legacy-allowlist
  '(("supertag-automation.el" raw-store-write
     "supertag-store-put-entity" 2)
    ("supertag-automation.el" raw-store-write
     "supertag-store-remove-entity" 1)
    ("supertag-ui-commands.el" raw-store-write
     "supertag-store-remove-entity" 1)
    ("supertag-view-framework.el" raw-store-write
     "supertag-store-put-entity" 1)
    ("supertag-view-schema.el" raw-store-write
     "supertag-store-put-tag-field-associations" 1)
    ("supertag-ops-field.el" automation-private-call
     "supertag-automation-sync--process-global-field-change" 1)
    ("supertag-ui-query-block.el" query-private-call
     "supertag-query--numeric" 1)
    ("supertag-ui-query-block.el" query-private-call
     "supertag-query--sort-value" 1)
    ("supertag-ui-query-block.el" query-private-call
     "supertag-query--value<" 1))
  "Exact legacy boundary violations allowed during incremental migration.")

(defun supertag-architecture-test--scoped-file-p (file rule)
  "Return non-nil when FILE is in RULE's production source scope."
  (pcase rule
    ('raw-store-write
     (string-match-p
      "\\`supertag-\\(?:ui-\\|view-\\|automation\\)" file))
    ('automation-private-call
     (string-match-p "\\`supertag-ops-" file))
    ('query-private-call
     (string-match-p "\\`supertag-\\(?:ui-\\|view-\\)" file))))

(defun supertag-architecture-test--rule-regexp (rule)
  "Return the call regexp for RULE."
  (pcase rule
    ('raw-store-write
     "(\\(supertag-store-\\(?:put\\|remove\\|set\\|update\\)[^()[:space:]]*\\)")
    ('automation-private-call
     "(\\(supertag-automation-sync--[^()[:space:]]+\\)")
    ('query-private-call
     "(\\(supertag-\\(?:services-query\\|query\\)--[^()[:space:]]+\\)")))

(defun supertag-architecture-test--scan-content (file content rule)
  "Return normalized RULE violations found in FILE CONTENT."
  (when (supertag-architecture-test--scoped-file-p file rule)
    (let ((regexp (supertag-architecture-test--rule-regexp rule))
          counts)
      (with-temp-buffer
        (insert content)
        (goto-char (point-min))
        (while (re-search-forward regexp nil t)
          (let ((symbol (match-string-no-properties 1)))
            (setf (alist-get symbol counts nil nil #'equal)
                  (1+ (or (alist-get symbol counts nil nil #'equal) 0))))))
      (mapcar (lambda (entry)
                (list file rule (car entry) (cdr entry)))
              counts))))

(defun supertag-architecture-test--production-files ()
  "Return top-level production Elisp filenames in deterministic order."
  (sort
   (mapcar #'file-name-nondirectory
           (directory-files supertag-architecture-test--root t
                            "\\`supertag-.*\\.el\\'"))
   #'string<))

(defun supertag-architecture-test--current-violations ()
  "Return all guarded production violations in normalized order."
  (let (violations)
    (dolist (file (supertag-architecture-test--production-files))
      (let ((content
             (with-temp-buffer
               (insert-file-contents
                (expand-file-name file supertag-architecture-test--root))
               (buffer-string))))
        (dolist (rule '(raw-store-write
                        automation-private-call
                        query-private-call))
          (setq violations
                (nconc violations
                       (supertag-architecture-test--scan-content
                        file content rule))))))
    (sort violations
          (lambda (left right)
            (string< (prin1-to-string left) (prin1-to-string right))))))

(ert-deftest supertag-architecture-boundary-legacy-allowlist-is-exact ()
  "New violations fail, and removed violations require allowlist shrinkage."
  (should
   (equal
    (sort (copy-tree supertag-architecture-test--legacy-allowlist)
          (lambda (left right)
            (string< (prin1-to-string left) (prin1-to-string right))))
    (supertag-architecture-test--current-violations))))

(ert-deftest supertag-architecture-boundary-detects-synthetic-write ()
  "The production scanner rejects a synthetic raw UI Store write."
  (should
   (equal
    '(("supertag-ui-fake.el" raw-store-write
       "supertag-store-put-entity" 1))
    (supertag-architecture-test--scan-content
     "supertag-ui-fake.el"
     "(supertag-store-put-entity :nodes id value)"
     'raw-store-write))))

(ert-deftest supertag-architecture-boundary-allows-reads-and-query-model ()
  "Stable Store reads and concrete Query Model calls are not writes."
  (should-not
   (supertag-architecture-test--scan-content
    "supertag-ui-fake.el"
    "(supertag-store-get-entity :nodes id)\n(supertag-query-node id)"
    'raw-store-write))
  (should-not
   (supertag-architecture-test--scan-content
    "supertag-view-fake.el"
    "(supertag-query-node-detail id)"
    'query-private-call)))

(provide 'architecture-boundary-test)
;;; architecture-boundary-test.el ends here
