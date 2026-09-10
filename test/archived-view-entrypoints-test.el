;;; archived-view-entrypoints-test.el --- Default archive entry retirement -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'subr-x)

(defconst supertag-archived-entry-test--root
  (expand-file-name ".." (file-name-directory load-file-name)))

(defconst supertag-archived-entry-test--features
  '(supertag-view-schema supertag-view-table supertag-view-kanban
    supertag-board supertag-graph-ui supertag-ontology
    supertag-view-ontology supertag-view-ontology-migration
    supertag-ui-tool))

(defconst supertag-archived-entry-test--capability-features
  '(supertag-ontology-function supertag-ontology-action
    supertag-ontology-policy supertag-ui-action))

(defun supertag-archived-entry-test--isolated-form (prefix &rest body)
  "Wrap BODY in a fresh process bootstrap using temp paths named by PREFIX."
  `(progn
     (require 'package)
     (let* ((test-root (make-temp-file ,prefix t))
            (test-data (expand-file-name "data" test-root)))
       (unwind-protect
           (progn
             (setq user-emacs-directory test-root
                   supertag-data-directory test-data
                   supertag--base-data-directory
                   (file-name-as-directory test-data)
                   supertag-db-file (expand-file-name "store.el" test-data)
                   supertag-db-backup-directory
                   (expand-file-name "backups" test-data)
                   supertag-sync--state-source
                   (expand-file-name "sync-state.el" test-data)
                   supertag-sync-directories nil
                   supertag-active-sync-directory nil
                   org-id-locations-file
                   (expand-file-name "org-id-locations" test-root)
                   emacs-startup-hook nil
                   kill-emacs-hook nil
                   org-mode-hook nil)
             (package-initialize)
             (add-to-list 'load-path ,supertag-archived-entry-test--root)
             (unless (file-equal-p
                      (locate-library "supertag")
                      (expand-file-name
                       "supertag.el" ,supertag-archived-entry-test--root))
               (error "Fresh process did not select source supertag.el"))
             ,@body)
         (when (fboundp 'supertag-cleanup-all-timers)
           (ignore-errors (supertag-cleanup-all-timers)))
         (setq emacs-startup-hook nil
               kill-emacs-hook nil
               org-mode-hook nil)
         (ignore-errors (delete-directory test-root t))))))

(defun supertag-archived-entry-test--emacs (form)
  "Run FORM in a fresh isolated Emacs and return its output."
  (let ((program (expand-file-name invocation-name invocation-directory)))
    (with-temp-buffer
      (let ((code (call-process program nil t nil
                                "-Q" "--batch"
                                "-L" supertag-archived-entry-test--root
                                "--eval" (format "%S" form))))
        (unless (zerop code)
          (ert-fail (buffer-string)))
        (buffer-string)))))

(ert-deftest supertag-default-load-and-controlled-init-skip-archived-uis ()
  "A fresh default load and an actual controlled init omit archived UIs."
  (let ((output
         (supertag-archived-entry-test--emacs
          (supertag-archived-entry-test--isolated-form
           "supertag-entry-"
           '(require 'cl-lib)
           '(setq after-init-time nil)
           '(require 'supertag)
           `(dolist (feature ',supertag-archived-entry-test--features)
              (when (featurep feature)
                (error "Archived feature loaded: %S" feature)))
           '(dolist (feature '(supertag-view-node supertag-view-stream
                               supertag-ui-search supertag-ui-query-block
                               supertag-automation supertag-services-scheduler
                               supertag-core-schema supertag-board-ops))
              (unless (featurep feature)
                (error "Retained feature missing: %S" feature)))
           '(let (calls)
              (cl-letf (((symbol-function 'supertag-persistence-check-legacy-data-directory)
                         (lambda () (push :legacy calls)))
                        ((symbol-function 'supertag-vault--select-startup-default)
                         (lambda () (push :vault calls)))
                        ((symbol-function 'supertag-persistence-ensure-data-directory)
                         (lambda () (push :directory calls)))
                        ((symbol-function 'supertag--check-critical-config)
                         (lambda () (push :config calls)))
                        ((symbol-function 'supertag-sync-load-state)
                         (lambda () (push :sync-state calls)))
                        ((symbol-function 'supertag-load-store)
                         (lambda (&rest _) (push :store calls)))
                        ((symbol-function 'supertag--validate-initialization)
                         (lambda () (push :validate calls)))
                        ((symbol-function 'supertag-schema-apply-registrations)
                         (lambda () (push :schema calls)))
                        ((symbol-function 'supertag-setup-all-timers)
                         (lambda () (push :timers calls)))
                        ((symbol-function 'supertag-scheduler-start)
                         (lambda () (push :scheduler calls)))
                        ((symbol-function 'global-supertag-ui-completion-mode)
                         (lambda (&rest _) (push :completion calls)))
                        ((symbol-function 'supertag-config-guard-enable)
                         (lambda () (push :guard calls))))
                (setq supertag-sync-auto-start nil)
                (supertag-init))
              (dolist (expected '(:legacy :vault :directory :config
                                  :sync-state :store :validate :schema
                                  :timers :scheduler :completion :guard))
                (unless (memq expected calls)
                  (error "Controlled init skipped %S" expected))))
           `(dolist (feature ',supertag-archived-entry-test--features)
              (when (featurep feature)
                (error "Init loaded archived feature: %S" feature)))
           `(dolist (feature ',supertag-archived-entry-test--capability-features)
              (when (featurep feature)
                (error "Init loaded Node capability: %S" feature)))
           '(princ "DEFAULT-OK")))))
    (should (string-match-p "DEFAULT-OK" output))))

(ert-deftest supertag-explicit-archive-load-remains-available ()
  "Archived source features still load explicitly in a separate process."
  (let ((output
         (supertag-archived-entry-test--emacs
          (supertag-archived-entry-test--isolated-form
           "supertag-archive-"
           `(dolist (feature ',supertag-archived-entry-test--features)
              (require feature))
           '(dolist (command '(supertag-view-schema supertag-view-table
                               supertag-view-kanban supertag-board-mode
                               supertag-graph-ui-open
                               supertag-ontology-migration-preview
                               supertag-ui-tool-list))
              (unless (fboundp command)
                (error "Explicit archive command missing: %S" command)))
           '(princ "ARCHIVE-OK")))))
    (should (string-match-p "ARCHIVE-OK" output))))

(ert-deftest supertag-explicit-kanban-load-owns-its-table-helper-dependency ()
  "Loading only Kanban provides the Tag lookup used by its wrapper."
  (let ((output
         (supertag-archived-entry-test--emacs
          (supertag-archived-entry-test--isolated-form
           "supertag-kanban-"
           '(require 'cl-lib)
           '(require 'supertag-view-kanban)
           '(setq supertag--store nil)
           '(supertag--ensure-store)
           '(supertag-tag-create '(:id "kanban-tag" :name "task"))
           '(supertag-tag-add-field
             "kanban-tag" '(:id "status" :name "Status" :type :string))
           '(let (opened-config opened-name)
              (cl-letf (((symbol-function 'supertag-ui-read-tag)
                         (lambda (&rest _) "task"))
                        ((symbol-function 'completing-read)
                         (lambda (&rest _) "Status"))
                        ((symbol-function 'supertag-view-kanban-open)
                         (lambda (config name)
                           (setq opened-config config
                                 opened-name name))))
                (supertag-view-kanban))
              (unless (equal (supertag-tag-get-id-by-name "task")
                             "kanban-tag")
                (error "Kanban Tag lookup did not use the stored Tag"))
              (unless (and (equal (plist-get opened-config :base-tag)
                                  "kanban-tag")
                           (equal (plist-get opened-config :group-field)
                                  "Status")
                           (equal opened-name "task"))
                (error "Kanban wrapper opened the wrong target: %S %S"
                       opened-config opened-name)))
           '(princ "KANBAN-OK")))))
    (should (string-match-p "KANBAN-OK" output))))

(ert-deftest supertag-direct-node-view-load-and-render-skip-capabilities ()
  "Direct Node View loading and rendering omit archived capabilities."
  (let ((output
         (supertag-archived-entry-test--emacs
          (supertag-archived-entry-test--isolated-form
           "supertag-node-capability-"
           '(require 'supertag-view-node)
           `(dolist (feature ',supertag-archived-entry-test--capability-features)
              (when (featurep feature)
                (error "Node View loaded capability: %S" feature)))
           '(setq supertag--store nil)
           '(supertag--ensure-store)
           '(with-temp-buffer
              (supertag-view-node-mode)
              (supertag-view-node--render-from-state
               '(:id "fresh-node" :node (:id "fresh-node" :title "Fresh Node")
                 :properties nil :property-count 0 :tags nil)))
           `(dolist (feature ',supertag-archived-entry-test--capability-features)
              (when (featurep feature)
                (error "Node render loaded capability: %S" feature)))
           '(princ "NODE-CAPABILITY-OK")))))
    (should (string-match-p "NODE-CAPABILITY-OK" output))))

(ert-deftest supertag-direct-stream-load-skips-node-capabilities ()
  "Direct Stream loading does not pull archived Node View capabilities."
  (let ((output
         (supertag-archived-entry-test--emacs
          (supertag-archived-entry-test--isolated-form
           "supertag-stream-capability-"
           '(require 'supertag-view-stream)
           `(dolist (feature ',supertag-archived-entry-test--capability-features)
              (when (featurep feature)
                (error "Stream loaded Node capability: %S" feature)))
           '(princ "STREAM-CAPABILITY-OK")))))
    (should (string-match-p "STREAM-CAPABILITY-OK" output))))

(ert-deftest supertag-post-startup-require-runs-isolated-init-without-archives ()
  "Post-startup require performs normal temp-root init without archived UIs."
  (let ((output
         (supertag-archived-entry-test--emacs
          (supertag-archived-entry-test--isolated-form
           "supertag-post-init-"
           '(require 'cl-lib)
           '(setq after-init-time t supertag-sync-auto-start nil)
           '(require 'supertag-core-persistence)
           '(require 'supertag-services-sync)
           '(require 'supertag-services-embed)
           '(require 'supertag-services-scheduler)
           '(require 'supertag-tag)
           '(let (calls)
              (cl-letf (((symbol-function 'supertag-persistence-check-legacy-data-directory)
                         (lambda () (push :legacy calls)))
                        ((symbol-function 'supertag-persistence-ensure-data-directory)
                         (lambda () (push :directory calls)))
                        ((symbol-function 'supertag-sync-load-state)
                         (lambda () (push :sync-state calls)))
                        ((symbol-function 'supertag-load-store)
                         (lambda (&rest _) (push :store calls)))
                        ((symbol-function 'supertag-setup-all-timers)
                         (lambda () (push :timers calls)))
                        ((symbol-function 'supertag-scheduler-start)
                         (lambda () (push :scheduler calls)))
                        ((symbol-function 'global-supertag-ui-completion-mode)
                         (lambda (&rest _) (push :completion calls))))
                (require 'supertag))
              (dolist (expected '(:legacy :directory :sync-state :store
                                  :timers :scheduler :completion))
                (unless (memq expected calls)
                  (error "Automatic init skipped controlled effect %S"
                         expected))))
           '(unless supertag--initialized
              (error "Post-startup require did not run init"))
           `(dolist (feature ',supertag-archived-entry-test--features)
              (when (featurep feature)
                (error "Post-startup init loaded archive: %S" feature)))
           `(dolist (feature ',supertag-archived-entry-test--capability-features)
              (when (featurep feature)
                (error "Post-startup init loaded Node capability: %S"
                       feature)))
           '(princ "POST-INIT-OK")))))
    (should (string-match-p "POST-INIT-OK" output))))

(provide 'archived-view-entrypoints-test)
;;; archived-view-entrypoints-test.el ends here
