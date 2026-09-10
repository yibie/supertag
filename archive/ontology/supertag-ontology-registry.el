;;; supertag-ontology-registry.el --- Registration and loading of ontology source modules. -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Registration and loading of ontology source modules.

;;; Code:

(require 'cl-lib)
(require 'supertag-ontology-model)

(defgroup supertag-ontology nil
  "Ontology-as-code control plane for org-supertag."
  :group 'org-supertag)

(defcustom supertag-ontology-files nil
  "Files containing `supertag-defontology' declarations."
  :type '(repeat file))

(defcustom supertag-ontology-auto-apply nil
  "Whether to apply safe ontology plans after loading.
Nil never applies.  The value `safe' applies only plans without errors or
potentially destructive operations."
  :type '(choice (const :tag "Never" nil)
                 (const :tag "Safe plans only" safe)))

(defvar supertag-ontology-registry--raw (make-hash-table :test #'equal))

(defun supertag-ontology-registry-clear ()
  "Clear declarations from memory without mutating the Supertag Store."
  (interactive)
  (clrhash supertag-ontology-registry--raw))

(defun supertag-ontology-registry-register (module raw-body source)
  "Register MODULE RAW-BODY from SOURCE without changing runtime state."
  (let ((record (list :module module :raw-body raw-body :source source)))
    (puthash module record supertag-ontology-registry--raw)
    record))

(defmacro supertag-defontology (module &rest body)
  "Declare ontology MODULE using BODY.
Loading a declaration only registers source data; it never writes the Store."
  (declare (indent 1) (debug (symbolp body)))
  `(supertag-ontology-registry-register
    ',module ',body
    (list :file (or load-file-name buffer-file-name)
          :line (line-number-at-pos))))

(defun supertag-ontology-registry-get (module)
  "Return normalized model for MODULE, or nil."
  (when-let ((record (gethash module supertag-ontology-registry--raw)))
    (supertag-ontology-model-normalize
     module (copy-tree (plist-get record :raw-body))
     (copy-tree (plist-get record :source)))))

(defun supertag-ontology-registry-modules ()
  "Return registered module names in stable order."
  (let (result)
    (maphash (lambda (key _value) (push key result))
             supertag-ontology-registry--raw)
    (sort result (lambda (a b) (string< (format "%s" a)
                                        (format "%s" b))))))

(defun supertag-ontology-registry-models ()
  "Return all normalized registered models."
  (mapcar #'supertag-ontology-registry-get
          (supertag-ontology-registry-modules)))

(defun supertag-ontology-load-files (&optional files)
  "Load ontology FILES, defaulting to `supertag-ontology-files'.
This operation only updates the in-memory declaration registry."
  (interactive)
  (dolist (file (or files supertag-ontology-files))
    (load (expand-file-name file) nil 'nomessage))
  (supertag-ontology-registry-models))

(provide 'supertag-ontology-registry)
;;; supertag-ontology-registry.el ends here
