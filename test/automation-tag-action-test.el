;;; automation-tag-action-test.el --- Live-first Automation tag actions -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(when load-file-name
  (add-to-list 'load-path (file-name-directory load-file-name))
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'ownership-fixture)
(require 'supertag-tag)
(require 'supertag-service-org)
(require 'supertag-automation)

(defmacro supertag-automation-tag-test--with-vault (&rest body)
  "Run BODY with isolated Store state and real synthetic Org files."
  (declare (indent 0) (debug t))
  `(supertag-ownership-test-with-vault
     (let ((supertag-sync--state
            (list :sync-state (make-hash-table :test 'equal)))
           (supertag-sync--state-source
            (expand-file-name "sync-state.el" supertag-data-directory))
           (supertag-sync--deferred-files (make-hash-table :test 'equal))
           (supertag-sync--internal-modifications (make-hash-table :test 'equal))
           (supertag--subscribers (make-hash-table :test 'equal)))
       (cl-letf (((symbol-function 'supertag-sync-save-state) #'ignore))
         (should (eq 'complete (plist-get (supertag-reindex-org) :status))))
       (supertag-tag-create '(:id "extra" :name "extra"))
       (unwind-protect
           (progn ,@body)
         (dolist (buffer (buffer-list))
           (when-let* ((file (buffer-file-name buffer)))
             (when (file-in-directory-p file vault)
               (with-current-buffer buffer (set-buffer-modified-p nil))
               (kill-buffer buffer))))))))

(defun supertag-automation-tag-test--disk-has-token-p (file token)
  "Return non-nil when FILE's first heading contains #TOKEN."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (re-search-forward
     (format "^\\* .*#%s\\(?:[[:space:]]\\|$\\)" (regexp-quote token))
     (line-end-position) t)))

(defun supertag-automation-tag-test--insert-draft-token (file token)
  "Insert #TOKEN into FILE's live first heading without saving it."
  (let ((buffer (find-file-noselect file)))
    (with-current-buffer buffer
      (goto-char (point-min))
      (end-of-line)
      (insert " #" token))
    buffer))

(ert-deftest supertag-automation-add-tag-obeys-live-org-when-db-says-present ()
  "Stale projected membership cannot suppress an absent Org occurrence."
  (supertag-automation-tag-test--with-vault
    (let* ((file (car files))
           (buffer (find-file-noselect file))
           restricted-text point-offset)
      (supertag-node-add-tag supertag-ownership-test-node-a "extra")
      (should-not (supertag-automation-tag-test--disk-has-token-p file "extra"))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "Keeps one physical")
        (narrow-to-region (line-beginning-position)
                          (min (point-max) (1+ (line-end-position))))
        (goto-char (+ (point-min) 5))
        (setq restricted-text (buffer-string)
              point-offset (- (point) (point-min))))
      (supertag-automation-action-add-tag
       supertag-ownership-test-node-a '(:tag "extra"))
      (with-current-buffer buffer
        (should (buffer-narrowed-p))
        (should (equal restricted-text (buffer-string)))
        (should (= point-offset (- (point) (point-min)))))
      (should (supertag-automation-tag-test--disk-has-token-p file "extra"))
      (should (member "extra"
                      (plist-get (supertag-node-get supertag-ownership-test-node-a)
                                 :tags))))))

(ert-deftest supertag-automation-remove-tag-obeys-live-org-when-db-says-absent ()
  "Missing projected membership cannot preserve a live Org occurrence."
  (supertag-automation-tag-test--with-vault
    (let ((file (car files)))
      (supertag-service-org-add-tag supertag-ownership-test-node-a "extra")
      (supertag-node-remove-tag supertag-ownership-test-node-a "extra")
      (should (supertag-automation-tag-test--disk-has-token-p file "extra"))
      (supertag-automation-action-remove-tag
       supertag-ownership-test-node-a '(:tag "extra"))
      (should-not (supertag-automation-tag-test--disk-has-token-p file "extra"))
      (should-not
       (member "extra"
               (plist-get (supertag-node-get supertag-ownership-test-node-a)
                          :tags))))))

(ert-deftest supertag-automation-add-tag-saves-live-draft-before-repair ()
  "An unsaved occurrence becomes durable before repairing its Projection."
  (supertag-automation-tag-test--with-vault
    (let* ((file (car files))
           (buffer (supertag-automation-tag-test--insert-draft-token
                    file "extra"))
           (real-save (symbol-function 'save-buffer))
           (saves 0))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (should (buffer-modified-p)))
            (should-not
             (supertag-automation-tag-test--disk-has-token-p file "extra"))
            (cl-letf (((symbol-function 'save-buffer)
                       (lambda (&rest args)
                         (cl-incf saves)
                         (apply real-save args))))
              (supertag-automation-action-add-tag
               supertag-ownership-test-node-a '(:tag "extra")))
            (should (= 1 saves))
            (should (supertag-automation-tag-test--disk-has-token-p file "extra"))
            (should (member "extra"
                            (plist-get
                             (supertag-node-get supertag-ownership-test-node-a)
                             :tags))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest supertag-automation-add-dirty-unchanged-text-forces-repair ()
  "A dirty save repairs stale membership even when the Org hash is unchanged."
  (supertag-automation-tag-test--with-vault
    (let* ((file (car files))
           (buffer (find-file-noselect file))
           (real-save (symbol-function 'save-buffer))
           (saves 0))
      (supertag-service-org-add-tag supertag-ownership-test-node-a "extra")
      (supertag-node-remove-tag supertag-ownership-test-node-a "extra")
      (with-current-buffer buffer
        (set-buffer-modified-p t))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (cl-incf saves)
                   (apply real-save args))))
        (supertag-automation-action-add-tag
         supertag-ownership-test-node-a '(:tag "extra")))
      (should (= 1 saves))
      (should (supertag-automation-tag-test--disk-has-token-p file "extra"))
      (should (member "extra"
                      (plist-get (supertag-node-get supertag-ownership-test-node-a)
                                 :tags))))))

(ert-deftest supertag-automation-add-draft-repair-save-failure-does-not-project ()
  "A dirty repair save error propagates before any successful Projection."
  (supertag-automation-tag-test--with-vault
    (let* ((file (car files))
           (buffer (supertag-automation-tag-test--insert-draft-token
                    file "extra"))
           projected)
      (should-error
       (cl-letf (((symbol-function 'save-buffer)
                  (lambda (&rest _) (error "deliberate save failure")))
                 ;; Tag actions refresh membership here, not through the
                 ;; whole-file projector (`8b020d3').
                 ((symbol-function 'supertag-sync--resolve-node-tag-occurrences)
                  (lambda (&rest _) (setq projected t))))
         (supertag-automation-action-add-tag
          supertag-ownership-test-node-a '(:tag "extra"))))
      (should-not projected)
      (should-not (supertag-automation-tag-test--disk-has-token-p file "extra"))
      (should-not
       (member "extra"
               (plist-get (supertag-node-get supertag-ownership-test-node-a)
                          :tags)))
      (with-current-buffer buffer
        (should (buffer-modified-p))))))

(ert-deftest supertag-automation-add-draft-repair-projection-failure-is-retryable ()
  "Dirty repair saves once and exposes the ordinary Projection retry once."
  (supertag-automation-tag-test--with-vault
    (let* ((file (car files))
           (_buffer (supertag-automation-tag-test--insert-draft-token
                     file "extra"))
           (real-save (symbol-function 'save-buffer))
           (saves 0)
           caught)
      (condition-case err
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest args)
                       (cl-incf saves)
                       (apply real-save args)))
                    ;; Tag actions refresh membership here, not through the
                    ;; whole-file projector (`8b020d3').
                    ((symbol-function 'supertag-sync--resolve-node-tag-occurrences)
                     (lambda (&rest _)
                       (error "deliberate projection failure"))))
            (supertag-automation-action-add-tag
             supertag-ownership-test-node-a '(:tag "extra")))
        (error (setq caught err)))
      (should (= 1 saves))
      (should (eq 'supertag-projection-error (car caught)))
      (should (eq 'error (car (plist-get (cdr caught) :cause))))
      (should (eq 'supertag-service-org-retry-node-projection
                  (plist-get (cdr caught) :retry)))
      (should (equal (list supertag-ownership-test-node-a file)
                     (plist-get (cdr caught) :retry-args)))
      (should (supertag-automation-tag-test--disk-has-token-p file "extra"))
      (should-not
       (member "extra"
               (plist-get (supertag-node-get supertag-ownership-test-node-a)
                          :tags))))))

(ert-deftest supertag-automation-tag-actions-repeat-through-service-noop ()
  "Repeated add/remove calls save and project only real live Org changes."
  (supertag-automation-tag-test--with-vault
    (let ((file (car files))
          (real-save (symbol-function 'save-buffer))
          (real-record
           (symbol-function 'supertag-service-org-save-and-record-tags-at-point))
          calls)
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (push 'save calls)
                   (apply real-save args)))
                ;; Tag actions record membership here, not through the
                ;; whole-file projector (`8b020d3').
                ((symbol-function 'supertag-service-org-save-and-record-tags-at-point)
                 (lambda (&rest args)
                   (push 'record calls)
                   (apply real-record args))))
        (dotimes (_ 2)
          (supertag-automation-action-add-tag
           supertag-ownership-test-node-a '(:tag "extra")))
        (dotimes (_ 2)
          (supertag-automation-action-remove-tag
           supertag-ownership-test-node-a '(:tag "extra"))))
      ;; The save happens inside the recorder, so it is pushed second.
      (should (equal '(record save record save) (nreverse calls)))
      (should-not (supertag-automation-tag-test--disk-has-token-p file "extra")))))

(ert-deftest supertag-automation-add-unknown-save-failure-keeps-definition ()
  "An independently created Semantic Tag survives a failed Org save."
  (supertag-automation-tag-test--with-vault
    (let* ((file (car files))
           (buffer (find-file-noselect file))
           (before-node (copy-tree
                         (supertag-node-get supertag-ownership-test-node-a))))
      (should-error
       (cl-letf (((symbol-function 'save-buffer)
                  (lambda (&rest _) (error "deliberate save failure"))))
         (supertag-automation-action-add-tag
          supertag-ownership-test-node-a '(:tag "new-automation-tag"))))
      (let ((tag-id (supertag-tag-resolve-occurrence "new-automation-tag")))
        (should tag-id)
        (should (supertag-tag-get tag-id))
        (should-not (member tag-id
                            (plist-get (supertag-node-get
                                        supertag-ownership-test-node-a)
                                       :tags))))
      (should (equal before-node
                     (supertag-node-get supertag-ownership-test-node-a)))
      (should-not
       (supertag-automation-tag-test--disk-has-token-p
        file "new-automation-tag"))
      (with-current-buffer buffer
        (should (buffer-modified-p))
        (goto-char (point-min))
        (should (search-forward "#new-automation-tag" (line-end-position) t))))))

(ert-deftest supertag-automation-remove-unresolved-tag-is-a-noop ()
  "Removing an unresolved tag keeps the existing compatibility no-op."
  (supertag-automation-tag-test--with-vault
    (let* ((file (car files))
           (before (with-temp-buffer
                     (insert-file-contents-literally file)
                     (buffer-string)))
           called)
      (cl-letf (((symbol-function 'supertag-service-org-remove-tag)
                 (lambda (&rest _) (setq called t))))
        (supertag-automation-action-remove-tag
         supertag-ownership-test-node-a '(:tag "unknown-tag")))
      (should-not called)
      (should (equal before
                     (with-temp-buffer
                       (insert-file-contents-literally file)
                       (buffer-string)))))))

(ert-deftest supertag-automation-add-projection-failure-is-retryable ()
  "A Projection failure keeps durable Org and exposes the existing retry."
  (supertag-automation-tag-test--with-vault
    (let ((file (car files)) caught)
      (condition-case err
          (cl-letf (((symbol-function
                      'supertag-sync--resolve-node-tag-occurrences)
                     (lambda (&rest _)
                       (error "deliberate projection failure"))))
            (supertag-automation-action-add-tag
             supertag-ownership-test-node-a '(:tag "extra")))
        (error (setq caught err)))
      (should (eq 'supertag-projection-error (car caught)))
      (should (eq 'supertag-service-org-retry-node-projection
                  (plist-get (cdr caught) :retry)))
      (should (equal (list supertag-ownership-test-node-a file)
                     (plist-get (cdr caught) :retry-args)))
      (should (supertag-automation-tag-test--disk-has-token-p file "extra"))
      (should-not
       (member "extra"
               (plist-get (supertag-node-get supertag-ownership-test-node-a)
                          :tags)))
      (apply (plist-get (cdr caught) :retry)
             (plist-get (cdr caught) :retry-args))
      (should (member "extra"
                      (plist-get (supertag-node-get supertag-ownership-test-node-a)
                                 :tags))))))

(ert-deftest supertag-automation-tag-real-trigger-writes-org ()
  "A database-matched tag event reaches the Org tag writer."
  (supertag-automation-tag-test--with-vault
    (let ((file (car files)))
      (supertag-tag-create '(:id "trigger" :name "trigger"))
      (supertag-subscribe :store-changed
                          #'supertag-automation--handle-entity-change)
      (supertag-automation-create
       '(:name "tag-action-trigger"
         :trigger (:on-tag-added "trigger")
         :actions ((:action :add-tag :params (:tag "extra")))))
      (supertag-node-add-tag supertag-ownership-test-node-a "trigger")
      (should (supertag-automation-tag-test--disk-has-token-p file "extra"))
      (should (member "extra"
                      (plist-get (supertag-node-get supertag-ownership-test-node-a)
                                 :tags))))))

(provide 'automation-tag-action-test)
;;; automation-tag-action-test.el ends here
