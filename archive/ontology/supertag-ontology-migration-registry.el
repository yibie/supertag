;;; supertag-ontology-migration-registry.el --- Migration declaration registry -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Loading migration source only registers declarations in memory.  Registry
;; identity is the stable module/migration/name logical ID, not the short name;
;; different ontology modules may therefore use the same human-facing name.

;;; Code:

(require 'cl-lib)
(require 'supertag-ontology-registry)
(require 'supertag-ontology-migration-model)

(defcustom supertag-ontology-migration-files nil
  "Files containing `supertag-defmigration' declarations."
  :type '(repeat file)
  :group 'supertag-ontology)

(defvar supertag-ontology-migration-registry--raw
  (make-hash-table :test #'equal))

(defun supertag-ontology-migration-registry-clear ()
  "Clear registered migration declarations without touching the Store."
  (interactive)
  (clrhash supertag-ontology-migration-registry--raw))

(defun supertag-ontology-migration-registry-register (name raw-body source)
  "Register migration NAME RAW-BODY from SOURCE."
  (let* ((migration
          (supertag-ontology-migration-model-normalize
           name (copy-tree raw-body) (copy-tree source)))
         (logical-id (plist-get migration :logical-id))
         (record
          (list :logical-id logical-id
                :name name
                :module (plist-get migration :module)
                :raw-body raw-body
                :source source)))
    (puthash logical-id record supertag-ontology-migration-registry--raw)
    record))

(defmacro supertag-defmigration (name &rest body)
  "Declare migration NAME using BODY.
Loading the declaration never mutates the Store."
  (declare (indent 1) (debug (symbolp body)))
  `(supertag-ontology-migration-registry-register
    ',name ',body
    (list :file (or load-file-name buffer-file-name)
          :line (line-number-at-pos))))

(defun supertag-ontology-migration-registry-ids ()
  "Return registered logical IDs in stable order."
  (let (result)
    (maphash
     (lambda (logical-id _record)
       (push logical-id result))
     supertag-ontology-migration-registry--raw)
    (sort result #'string<)))

(defun supertag-ontology-migration-registry--matches (reference)
  "Return records matching short-name REFERENCE."
  (let (matches)
    (maphash
     (lambda (_logical-id record)
       (let ((name (plist-get record :name)))
         (when (or (equal reference name)
                   (and (stringp reference)
                        (symbolp name)
                        (string-equal reference (symbol-name name))))
           (push record matches))))
     supertag-ontology-migration-registry--raw)
    (nreverse matches)))

(defun supertag-ontology-migration-registry--resolve-record (reference)
  "Resolve logical ID or unique short-name REFERENCE to a raw record."
  (or (and (stringp reference)
           (gethash reference supertag-ontology-migration-registry--raw))
      (let ((matches
             (supertag-ontology-migration-registry--matches reference)))
        (pcase (length matches)
          (0 nil)
          (1 (car matches))
          (_
           (user-error
            "Migration name %s is ambiguous; use one of: %s"
            reference
            (mapconcat
             (lambda (record) (plist-get record :logical-id))
             matches ", ")))))))

(defun supertag-ontology-migration-registry-get (reference)
  "Return normalized migration identified by REFERENCE, or nil.

REFERENCE may be a full logical ID string or a globally unique short name."
  (when-let ((record
              (supertag-ontology-migration-registry--resolve-record reference)))
    (supertag-ontology-migration-model-normalize
     (plist-get record :name)
     (copy-tree (plist-get record :raw-body))
     (copy-tree (plist-get record :source)))))

(defun supertag-ontology-migration-registry-names ()
  "Return registered short names in logical-ID order.

This compatibility helper may contain duplicate names across modules.  User
interfaces should prefer `supertag-ontology-migration-registry-ids'."
  (mapcar
   (lambda (logical-id)
     (plist-get
      (gethash logical-id supertag-ontology-migration-registry--raw)
      :name))
   (supertag-ontology-migration-registry-ids)))

(defun supertag-ontology-migration-registry-list (&optional module)
  "Return registered migrations, optionally restricted to MODULE."
  (cl-remove-if-not
   (lambda (migration)
     (or (null module)
         (eq module (plist-get migration :module))))
   (mapcar #'supertag-ontology-migration-registry-get
           (supertag-ontology-migration-registry-ids))))

(defun supertag-ontology-migration-registry-find
    (module from-version to-version)
  "Return migration matching MODULE FROM-VERSION and TO-VERSION.
Signal when more than one declaration matches."
  (let ((matches
         (cl-remove-if-not
          (lambda (migration)
            (and (eq module (plist-get migration :module))
                 (equal from-version (plist-get migration :from-version))
                 (equal to-version (plist-get migration :to-version))))
          (supertag-ontology-migration-registry-list module))))
    (pcase (length matches)
      (0 nil)
      (1 (car matches))
      (_
       (user-error
        "Multiple migrations cover %s %s -> %s: %s"
        module from-version to-version
        (mapconcat
         (lambda (migration) (plist-get migration :logical-id))
         matches ", "))))))

(defun supertag-ontology-migration-load-files (&optional files)
  "Load migration FILES without mutating the Supertag Store."
  (interactive)
  (dolist (file (or files supertag-ontology-migration-files))
    (load (expand-file-name file) nil 'nomessage))
  (supertag-ontology-migration-registry-list))

(provide 'supertag-ontology-migration-registry)
;;; supertag-ontology-migration-registry.el ends here
