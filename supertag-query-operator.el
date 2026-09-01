;;; supertag-query-operator.el --- Small extension registry for query operators. -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)

(defconst supertag-query-operator-unhandled
  (make-symbol "supertag-query-operator-unhandled"))
(defvar supertag-query-operator--parsers (make-hash-table :test #'eq))
(defvar supertag-query-operator--executors (make-hash-table :test #'eq))

(defun supertag-query-register-operator (operator ast-type parser executor)
  "Register OPERATOR parser and AST-TYPE executor."
  (unless (and (symbolp operator) (symbolp ast-type)
               (functionp parser) (functionp executor))
    (error "Invalid query operator registration"))
  (puthash operator parser supertag-query-operator--parsers)
  (puthash ast-type executor supertag-query-operator--executors)
  operator)

(defun supertag-query-operator-parse (operator args recursive-parser)
  "Parse OPERATOR ARGS through a registered extension."
  (if-let ((parser (gethash operator supertag-query-operator--parsers)))
      (funcall parser args recursive-parser)
    supertag-query-operator-unhandled))

(defun supertag-query-operator-execute (ast recursive-executor)
  "Execute AST through a registered extension."
  (if-let ((executor (gethash (plist-get ast :type)
                              supertag-query-operator--executors)))
      (funcall executor ast recursive-executor)
    supertag-query-operator-unhandled))

(provide 'supertag-query-operator)
;;; supertag-query-operator.el ends here
