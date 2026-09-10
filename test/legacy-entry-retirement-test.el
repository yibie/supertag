;;; legacy-entry-retirement-test.el --- Consolidated legacy entry exit -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'archived-view-entrypoints-test)

(defconst supertag-legacy-entry-test--retired-commands
  '(supertag-capture supertag-edit-fields supertag-ui-quick-edit-field
    supertag-edit-field supertag-insert-embed
    supertag-convert-link-to-embed
    supertag-capture-with-template
    supertag-capture-finalize-node-at-point))

(defconst supertag-legacy-entry-test--embed-features
  '(supertag-ops-embed supertag-services-embed supertag-ui-embed
    supertag-virtual-column))

(ert-deftest supertag-default-init-retires-legacy-commands-and-embed-hooks ()
  "Actual init exposes retained Capture only and never activates preloaded Embed."
  (let ((output
         (supertag-archived-entry-test--emacs
          (supertag-archived-entry-test--isolated-form
           "supertag-legacy-entry-"
           '(require 'cl-lib)
           '(require 'supertag-services-embed)
           '(setq after-save-hook
                  (delq #'supertag-services-embed-on-source-save
                        after-save-hook)
                  after-init-time t
                  supertag-sync-auto-start nil)
           '(require 'supertag-core-persistence)
           '(require 'supertag-services-sync)
           '(require 'supertag-services-scheduler)
           '(require 'supertag-tag)
           '(cl-letf (((symbol-function 'supertag-persistence-check-legacy-data-directory)
                       #'ignore)
                      ((symbol-function 'supertag-persistence-ensure-data-directory)
                       #'ignore)
                      ((symbol-function 'supertag-sync-load-state) #'ignore)
                      ((symbol-function 'supertag-load-store) #'ignore)
                      ((symbol-function 'supertag-setup-all-timers) #'ignore)
                      ((symbol-function 'supertag-scheduler-start) #'ignore)
                      ((symbol-function 'global-supertag-ui-completion-mode)
                       #'ignore))
              (require 'supertag))
           `(dolist (command ',supertag-legacy-entry-test--retired-commands)
              (when (commandp command)
                (error "Default source exposed retired command: %S" command)))
           '(unless (fboundp 'supertag-capture-finalize-node-at-point)
              (error "Internal Org Capture finalizer is unavailable"))
           '(unless (fboundp 'supertag-global-field-edit-interactive)
              (error "Retained field editor body is unavailable"))
           '(when (commandp 'supertag-global-field-edit-interactive)
              (error "Retained field editor remains a default command"))
           '(when (memq #'supertag-services-embed-on-source-save
                        after-save-hook)
              (error "Normal init activated preloaded Embed service"))
           '(princ "LEGACY-ENTRY-OK")))))
    (should (string-match-p "LEGACY-ENTRY-OK" output))))

(ert-deftest supertag-default-source-does-not-load-embed-or-virtual-modules ()
  "A clean default source load omits Embed and virtual-column features."
  (let ((output
         (supertag-archived-entry-test--emacs
          (supertag-archived-entry-test--isolated-form
           "supertag-legacy-load-"
           '(setq after-init-time nil)
           '(require 'supertag)
           `(dolist (feature ',supertag-legacy-entry-test--embed-features)
              (when (featurep feature)
                (error "Default source loaded retired feature: %S" feature)))
           '(princ "LEGACY-LOAD-OK")))))
    (should (string-match-p "LEGACY-LOAD-OK" output))))

(ert-deftest supertag-explicit-schema-embed-and-virtual-archives-load ()
  "Explicit archive loading retains Schema, Embed and virtual operations."
  (let ((output
         (supertag-archived-entry-test--emacs
          (supertag-archived-entry-test--isolated-form
           "supertag-legacy-archive-"
           '(require 'supertag-view-schema)
           '(require 'supertag-services-embed)
           '(require 'supertag-ui-embed)
           '(require 'supertag-virtual-column)
           '(dolist (function '(supertag-global-field-edit-interactive
                                supertag-services-embed-init
                                supertag-services-embed-cleanup
                                supertag-ui-embed--insert-block
                                supertag-virtual-column-create))
              (unless (fboundp function)
                (error "Explicit archive function unavailable: %S" function)))
           '(setq supertag--store nil
                  supertag--transaction-active nil
                  supertag--transaction-log nil
                  supertag--transaction-seen nil)
           '(supertag--ensure-store)
           '(supertag-global-field-create
             '(:id "archive-field" :name "Before" :type :string))
           '(cl-letf (((symbol-function 'supertag-schema--get-context-at-point)
                       (lambda () '(:type :field :tag-id "archive-tag"
                                    :field-name "Before")))
                      ((symbol-function 'supertag-tag-get-field)
                       (lambda (&rest _)
                         (supertag-global-field-get "archive-field")))
                      ((symbol-function 'read-string)
                       (lambda (prompt &rest _)
                         (if (string-prefix-p "Field name:" prompt)
                             "After"
                           "")))
                      ((symbol-function 'completing-read)
                       (lambda (&rest _) "string")))
              (supertag-schema--edit-field-definition-at-point))
           '(let ((definition (supertag-global-field-get "archive-field")))
              (unless (and (equal "After" (plist-get definition :name))
                           (eq :string (plist-get definition :type)))
                (error "Schema archive did not update by field ID: %S"
                       definition)))
           '(princ "LEGACY-ARCHIVE-OK")))))
    (should (string-match-p "LEGACY-ARCHIVE-OK" output))))

(ert-deftest supertag-org-capture-finalize-retains-old-field-specs ()
  "A real saved Org Capture entry still applies legacy field specs internally."
  (let* ((tmp (make-temp-file "supertag-capture-finalize-" t))
         (file (expand-file-name "capture.org" tmp))
         (supertag-data-directory tmp)
         (supertag-db-file (expand-file-name "store.el" tmp))
         (supertag-db-backup-directory (expand-file-name "backups" tmp))
         (supertag--store nil)
         (org-id-locations nil)
         (org-id-locations-file (expand-file-name "org-id-locations" tmp))
         buffer marker)
    (unwind-protect
        (progn
          (require 'supertag-node)
          (supertag--ensure-store)
          (supertag-store-put-entity
           :tags "capture-tag"
           '(:id "capture-tag" :type :tag :name "Capture"))
          (supertag-store-put-entity
           :field-definitions "summary"
           '(:id "summary" :name "Summary" :type :string))
          (supertag-store-put-entity
           :tag-field-associations "capture-tag"
           '((:field-id "summary" :order 0)))
          (with-temp-file file
            (insert "* Captured\n:PROPERTIES:\n:ID: capture-node\n:END:\n"))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (org-mode)
            (goto-char (point-min))
            (setq marker (point-marker))
            (let ((org-capture-plist
                   '(:supertag t
                     :supertag-template
                     ((:tag "capture-tag" :field "Summary"
                       :value "retained"))))
                  (org-capture-last-stored-marker marker))
              (supertag-org-capture-after-finalize)))
          (should (equal "retained"
                         (supertag-field-get
                          "capture-node" "capture-tag" "Summary"))))
      (when (markerp marker) (set-marker marker nil))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (ignore-errors (delete-directory tmp t)))))

(ert-deftest supertag-node-view-field-interaction-helpers-are-retired ()
  "Node View retains property reading without callable old field editors."
  (dolist (function '(supertag-view-node-confirm-field-at-point
                      supertag-view-node-reject-field-at-point
                      supertag-view-node-review-ai-fields
                      supertag-view-node-edit-at-point
                      supertag-view-node--edit-field-value
                      supertag-view-node--ai-provenance-fields
                      supertag-view-node--reject-ai-field
                      supertag-view-node--goto-field
                      supertag-view-node--goto-first-field
                      supertag-view-node--format-display-value
                      supertag-view-node--provenance-badge
                      supertag-view-node--insert-tag-block))
    (should-not (fboundp function))))

(provide 'legacy-entry-retirement-test)
;;; legacy-entry-retirement-test.el ends here
