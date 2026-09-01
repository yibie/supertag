;;; supertag-view-link-definition.el --- Link Definition schema projection. -*- lexical-binding: t; -*-

;;; Code:

(require 'supertag-ops-link-definition)
(require 'supertag-schema-authority)

(defun supertag-view-link-definition-insert-section ()
  "Insert all Link Definitions into the current Schema buffer."
  (let ((definitions (supertag-link-definition-list)))
    (insert "\nLink Definitions:\n")
    (if (null definitions)
        (insert "  (none)\n")
      (dolist (definition definitions)
        (let* ((start (point))
               (authority
                (supertag-schema-authority-get
                 :link (plist-get definition :id)))
               (managed (or authority
                            (eq (plist-get definition :managed-by) :ontology)))
               (module (or (plist-get authority :module)
                           (plist-get definition :ontology-module)))
               (key (or (plist-get authority :key)
                        (plist-get definition :ontology-key)))
               (suffix
                (if managed
                    (format "  [ontology %s/%s]" module key)
                  "  [interactive]")))
          (insert (format "  %s%s\n"
                          (supertag-link-definition-format definition)
                          suffix))
          (add-text-properties
           start (1- (point))
           `(supertag-context
             (:type :link-definition
              :link-definition-id ,(plist-get definition :id)))))))))

(provide 'supertag-view-link-definition)
;;; supertag-view-link-definition.el ends here
