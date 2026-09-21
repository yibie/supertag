;;; test-view-node-runtime.el --- Node View Runtime tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'supertag-view-framework)
(require 'supertag-view-node)

(ert-deftest supertag-view-node-follow-defers-refresh-until-idle ()
  "Crossing a heading must not rebuild Node View inside cursor motion."
  (let ((origin (generate-new-buffer " *supertag-node-follow-origin*"))
        (view (generate-new-buffer " *supertag-node-follow-view*"))
        (supertag--store (make-hash-table :test 'equal))
        scheduled cancelled resolved refreshed timer-callback timer-args)
    (unwind-protect
        (progn
          (with-current-buffer view
            (setq-local supertag-view--instance '(:input (:node-id "old"))))
          (with-current-buffer origin
            (supertag--ensure-store)
            (org-mode)
            (setq-local supertag-view-node--last-entity-id "old")
            (cl-letf (((symbol-function 'supertag-view-node--current-entity-id)
                       (lambda ()
                         (setq resolved (1+ (or resolved 0)))
                         "new"))
                      ((symbol-function 'supertag-view-node--buffer)
                       (lambda () view))
                      ((symbol-function 'run-with-idle-timer)
                       (lambda (_delay _repeat function &rest args)
                         (setq scheduled (1+ (or scheduled 0))
                               timer-callback function
                               timer-args args)
                         'fake-timer))
                      ((symbol-function 'cancel-timer)
                       (lambda (_timer)
                         (setq cancelled (1+ (or cancelled 0)))))
                      ((symbol-function 'supertag-view-refresh)
                       (lambda (_buffer)
                         (setq refreshed (1+ (or refreshed 0))))))
              (let ((supertag-view-node--enabled t)
                    (supertag-view-node-auto-show nil))
                (supertag-view-node--post-command)
                (should (= scheduled 1))
                (should-not resolved)
                (should-not refreshed)
                ;; More motion replaces pending work instead of rendering.
                (supertag-view-node--post-command)
                (should (= scheduled 2))
                (should (= cancelled 1))
                (should-not resolved)
                (should-not refreshed)
                (apply timer-callback timer-args)
                (should (= resolved 1))
                (should (= refreshed 1))))))
      (when (buffer-live-p origin) (kill-buffer origin))
      (when (buffer-live-p view) (kill-buffer view)))))

(ert-deftest supertag-view-node-runtime-owns-side-view-lifecycle ()
  "Node View must refresh through Runtime and release follow/subscription state."
  (supertag-view-framework-init)
  (let ((origin (generate-new-buffer " *supertag-node-origin*"))
        (supertag--store (make-hash-table :test 'equal))
        (supertag--subscribers (make-hash-table :test 'equal))
        (supertag-view-node--enabled nil)
        (supertag-view-node-auto-show nil))
    (unwind-protect
        (progn
          (supertag--ensure-store)
          (supertag-store-put-entity
           :nodes "node-1" '(:id "node-1" :title "Runtime Node"))
          (cl-letf (((symbol-function 'display-buffer) #'ignore)
                    ((symbol-function 'display-buffer-in-side-window) #'ignore))
            (with-current-buffer origin
              (supertag-view-node--show-side "node-1")
              (supertag-view-node--show-side "node-1"))
            (let ((buffer (supertag-view-node--buffer)))
              (should (buffer-live-p buffer))
              (should (= (length (gethash :store-changed supertag--subscribers))
                         1))
              (with-current-buffer buffer
                (should (derived-mode-p 'supertag-view-node-mode))
                (should (string-match-p "Runtime Node" (buffer-string)))
                (goto-char (point-min))
                (should (equal (get-text-property
                                (point) 'supertag-entity-id)
                               "node-1")))
              (supertag-view-refresh buffer)
              (supertag-view-node--hide-side)
              (should (buffer-live-p buffer))
              (with-current-buffer buffer
                (should-not supertag-view--instance)
                (should-error (supertag-view-node--refresh-view)
                              :type 'user-error))
              (let ((supertag-view-node-auto-show t))
                (with-current-buffer origin
                  (setq supertag-view-node--last-entity-id nil)
                  (cl-letf (((symbol-function
                              'supertag-view-node--current-entity-id)
                             (lambda () "node-1")))
                    (supertag-view-node--post-command))))
              (with-current-buffer buffer
                (should supertag-view--instance))
              (kill-buffer buffer)
              (should-not (gethash :store-changed supertag--subscribers))
              (with-current-buffer origin
                (should-not (memq #'supertag-view-node--post-command
                                  post-command-hook))))))
      (when-let* ((buffer (supertag-view-node--buffer)))
        (kill-buffer buffer))
      (when (buffer-live-p origin)
        (kill-buffer origin)))))

(ert-deftest supertag-view-node-runtime-refresh-restores-property-selection ()
  "Node refresh restores a surviving property and falls back after deletion."
  (supertag-view-framework-init)
  (let ((origin (generate-new-buffer " *supertag-node-property-origin*"))
        (supertag--store (make-hash-table :test 'equal))
        (supertag--subscribers (make-hash-table :test 'equal))
        (supertag-view-node--enabled nil)
        (supertag-view-node-auto-show nil))
    (unwind-protect
        (progn
          (supertag--ensure-store)
          (supertag-store-put-entity
           :nodes "node-1"
           '(:id "node-1" :title "Task" :tags ("task")
             :properties (:OTHER "x" :STATUS "todo")))
          (supertag-store-put-entity
           :tags "task" '(:id "task" :name "task"))
          (cl-letf (((symbol-function 'display-buffer) #'ignore)
                    ((symbol-function 'display-buffer-in-side-window) #'ignore))
            (with-current-buffer origin
              (supertag-view-node--show-side "node-1"))
            (let ((buffer (supertag-view-node--buffer)))
              (with-current-buffer buffer
                (goto-char (point-min))
                (search-forward "todo")
                (goto-char (1- (point)))
                (should (eq (get-text-property (point) 'property-key)
                            :STATUS)))
              (supertag-node-update
               "node-1"
               (lambda (node)
                 (plist-put node :properties '(:OTHER "x" :STATUS "done"))))
              (supertag-view-refresh buffer)
              (with-current-buffer buffer
                (should (eq (get-text-property (point) 'property-key) :STATUS))
                (should (string-match-p "done" (buffer-string))))
              (supertag-node-update
               "node-1"
               (lambda (node)
                 (plist-put node :properties '(:OTHER "x"))))
              (supertag-view-refresh buffer)
              (with-current-buffer buffer
                (should (eq (get-text-property (point) 'property-key) :OTHER))
                (should-not (lookup-key supertag-view-node-mode-map (kbd "RET")))
                (should-not (lookup-key supertag-view-node-mode-map (kbd "c")))
                (should-not (lookup-key supertag-view-node-mode-map (kbd "x")))
                (should-not (lookup-key supertag-view-node-mode-map (kbd "C")))
                (let ((help (documentation 'supertag-view-node-mode)))
                  (should-not
                   (string-match-p
                    "Field types determine input validation and display format"
                    help))
                  (should-not
                   (string-match-p "Changes are saved automatically" help)))))))
      (when-let* ((buffer (supertag-view-node--buffer)))
        (kill-buffer buffer))
      (when (buffer-live-p origin)
        (kill-buffer origin)))))

(ert-deftest supertag-view-node-mode-line-uses-runtime-property-count ()
  "The actual mode-line expression reads Runtime state, never field schema."
  (supertag-view-framework-init)
  (let ((origin (generate-new-buffer " *supertag-node-mode-line-origin*"))
        (supertag--store (make-hash-table :test 'equal))
        (supertag--subscribers (make-hash-table :test 'equal))
        (supertag-view-node--enabled nil)
        (supertag-view-node-auto-show nil))
    (unwind-protect
        (progn
          (supertag--ensure-store)
          (supertag-store-put-entity
           :nodes "node-1"
           '(:id "node-1" :title "Mode Line" :tags ("task")
             :properties (:ALPHA "a" :BETA "b")))
          (supertag-store-put-entity
           :tags "task" '(:id "task" :name "task"))
          (cl-letf (((symbol-function 'display-buffer) #'ignore)
                    ((symbol-function 'display-buffer-in-side-window) #'ignore))
            (with-current-buffer origin
              (supertag-view-node--show-side "node-1"))
            (with-current-buffer (supertag-view-node--buffer)
              (let* ((eval-forms
                      (cl-remove-if-not
                       (lambda (entry)
                         (and (consp entry) (eq (car entry) :eval)))
                       mode-line-format))
                     (property-expression (cadr (nth 1 eval-forms))))
                (should (= 2 (plist-get
                              (plist-get supertag-view--instance :state)
                              :property-count)))
                (cl-letf (((symbol-function 'supertag-query-resolved-fields)
                           (lambda (&rest _)
                             (ert-fail "Mode line read legacy field schema"))))
                  (should (equal "2"
                                 (substring-no-properties
                                  (eval property-expression t)))))))))
      (when-let* ((buffer (supertag-view-node--buffer)))
        (kill-buffer buffer))
      (when (buffer-live-p origin)
        (kill-buffer origin)))))

(provide 'test-view-node-runtime)

;;; test-view-node-runtime.el ends here
