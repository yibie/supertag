;;; supertag-query-link.el --- Composable typed Link query operators. -*- lexical-binding: t; -*-

;;; Commentary:
;; Operators:
;;   (link REF QUERY)          source nodes linked to matching targets
;;   (exists-link REF QUERY)   alias of link
;;   (reverse-link REF QUERY)  target nodes linked from matching sources
;;   (has-link REF)            source nodes with any instance
;;   (has-reverse-link REF)    target nodes with any instance

;;; Code:

(require 'cl-lib)
(require 'supertag-query-operator)
(require 'supertag-ops-link-definition)
(require 'supertag-ops-relation)

(defun supertag-query-link--parse-binary (type args recursive-parser)
  (unless (= (length args) 2)
    (error "'%s' expects a Link reference and one nested query, got %S"
           type args))
  (list :type type :reference (car args)
        :child (funcall recursive-parser (cadr args))))

(defun supertag-query-link--parse-unary (type args _recursive-parser)
  (unless (= (length args) 1)
    (error "'%s' expects exactly one Link reference, got %S" type args))
  (list :type type :reference (car args)))

(defun supertag-query-link--definition-id (ast)
  (plist-get
   (supertag-link-definition-resolve (plist-get ast :reference))
   :id))

(defun supertag-query-link--unique (ids)
  (cl-delete-duplicates (delq nil ids) :test #'equal))

(defun supertag-query-link--execute-forward (ast recursive-executor)
  (let ((definition-id (supertag-query-link--definition-id ast)) result)
    (dolist (target-id (funcall recursive-executor (plist-get ast :child)))
      (setq result (nconc (supertag-link-sources definition-id target-id) result)))
    (supertag-query-link--unique result)))

(defun supertag-query-link--execute-reverse (ast recursive-executor)
  (let ((definition-id (supertag-query-link--definition-id ast)) result)
    (dolist (source-id (funcall recursive-executor (plist-get ast :child)))
      (setq result (nconc (supertag-link-targets definition-id source-id) result)))
    (supertag-query-link--unique result)))

(defun supertag-query-link--execute-has-out (ast _recursive-executor)
  (supertag-query-link--unique
   (mapcar (lambda (relation) (plist-get relation :from))
           (supertag-link-find (supertag-query-link--definition-id ast)))))

(defun supertag-query-link--execute-has-in (ast _recursive-executor)
  (supertag-query-link--unique
   (mapcar (lambda (relation) (plist-get relation :to))
           (supertag-link-find (supertag-query-link--definition-id ast)))))

(supertag-query-register-operator
 'link 'link
 (lambda (args recurse) (supertag-query-link--parse-binary 'link args recurse))
 #'supertag-query-link--execute-forward)
(supertag-query-register-operator
 'exists-link 'link
 (lambda (args recurse) (supertag-query-link--parse-binary 'link args recurse))
 #'supertag-query-link--execute-forward)
(supertag-query-register-operator
 'reverse-link 'reverse-link
 (lambda (args recurse)
   (supertag-query-link--parse-binary 'reverse-link args recurse))
 #'supertag-query-link--execute-reverse)
(supertag-query-register-operator
 'has-link 'has-link
 (lambda (args recurse) (supertag-query-link--parse-unary 'has-link args recurse))
 #'supertag-query-link--execute-has-out)
(supertag-query-register-operator
 'has-reverse-link 'has-reverse-link
 (lambda (args recurse)
   (supertag-query-link--parse-unary 'has-reverse-link args recurse))
 #'supertag-query-link--execute-has-in)

(provide 'supertag-query-link)
;;; supertag-query-link.el ends here
