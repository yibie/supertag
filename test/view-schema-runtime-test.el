;;; view-schema-runtime-test.el --- Schema View Runtime regressions -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ht)
(require 'supertag-core-store)
(require 'supertag-ops-global-field)
(require 'supertag-ops-schema)
(require 'supertag-ops-tag)
(require 'supertag-view-framework)
(require 'supertag-view-schema)

(defvar supertag-view-schema-runtime-test--render-count 0)

(defmacro supertag-view-schema-runtime-test--with-store (&rest body)
  "Run BODY with an isolated Store and View Runtime."
  (declare (indent 0) (debug t))
  `(let ((supertag--store nil)
         (supertag--store-origin nil)
         (supertag--subscribers (ht-create))
         (supertag--view-registry (make-hash-table :test 'eq))
         (supertag--view-configs (make-hash-table :test 'eq))
         (supertag-ops-schema--resolved-cache (make-hash-table :test 'equal))
         (supertag-ops-schema--source-token nil)
         (supertag-schema-authority-provider-function nil)
         (supertag-view-schema-runtime-test--render-count 0))
     (supertag--ensure-store)
     (unwind-protect
         (cl-letf (((symbol-function 'display-buffer) #'ignore)
                   ((symbol-function 'pop-to-buffer)
                    (lambda (buffer &rest _) buffer)))
           ,@body)
       (when-let* ((buffer (get-buffer "*Supertag Schema*")))
         (kill-buffer buffer)))))

(defun supertag-view-schema-runtime-test--put-tag (id name)
  "Create a test Tag with ID and NAME."
  (supertag-tag-create (list :id id :name name)))

(defun supertag-view-schema-runtime-test--install-render-counter ()
  "Register Schema View and wrap its renderer with a counter."
  (supertag-schema--register-view)
  (let* ((view (supertag-view-get 'schema))
         (render-fn (plist-get view :render-fn)))
    (setf (plist-get view :render-fn)
          (lambda (state)
            (cl-incf supertag-view-schema-runtime-test--render-count)
            (funcall render-fn state)))))

(defun supertag-view-schema-runtime-test--open-counted ()
  "Open Schema View with a render counter and ignore the initial render."
  (supertag-view-schema-runtime-test--install-render-counter)
  (let ((buffer (supertag-view-schema)))
    (setq supertag-view-schema-runtime-test--render-count 0)
    buffer))

(ert-deftest supertag-view-schema-runtime-opens-one-managed-buffer ()
  "Schema View opens one buffer owned by the View Runtime."
  (supertag-view-schema-runtime-test--with-store
    (supertag-view-schema-runtime-test--put-tag "task" "Task")
    (let ((first (supertag-view-schema))
          (second (supertag-view-schema)))
      (should (eq first second))
      (should (equal (buffer-name first) "*Supertag Schema*"))
      (with-current-buffer first
        (should supertag-view--instance)
        (should (eq (plist-get supertag-view--instance :view-id) 'schema))))))

(ert-deftest supertag-view-schema-runtime-tag-rename-renders-once ()
  "A Tag rename refreshes Schema View exactly once."
  (supertag-view-schema-runtime-test--with-store
    (supertag-view-schema-runtime-test--put-tag "task" "Task")
    (let ((buffer (supertag-view-schema-runtime-test--open-counted)))
      (supertag-tag-rename "task" "Renamed")
      (should (= supertag-view-schema-runtime-test--render-count 1))
      (with-current-buffer buffer
        (should (string-match-p "^Renamed$" (buffer-string)))))))

(ert-deftest supertag-view-schema-runtime-restores-field-selection ()
  "Adding a field restores point to the previously selected field."
  (supertag-view-schema-runtime-test--with-store
    (supertag-view-schema-runtime-test--put-tag "task" "Task")
    (supertag-tag-add-field
     "task" '(:id "status" :name "Status" :type :string))
    (let ((buffer (supertag-view-schema-runtime-test--open-counted)))
      (with-current-buffer buffer
        (should (supertag-schema--goto-context
                 '(:type :field :tag-id "task" :field-name "Status"
                   :field-id "status"))))
      (supertag-tag-add-field
       "task" '(:id "priority" :name "Priority" :type :string))
      (with-current-buffer buffer
        (let ((context (supertag-schema--get-context-at-point)))
          (should (eq (plist-get context :type) :field))
          (should (equal (plist-get context :tag-id) "task"))
          (should (equal (plist-get context :field-id) "status")))))))

(ert-deftest supertag-view-schema-runtime-preserves-and-prunes-marks ()
  "Marks survive unrelated changes and disappear with deleted items."
  (supertag-view-schema-runtime-test--with-store
    (supertag-view-schema-runtime-test--put-tag "task" "Task")
    (supertag-view-schema-runtime-test--put-tag "other" "Other")
    (let ((buffer (supertag-view-schema-runtime-test--open-counted)))
      (with-current-buffer buffer
        (should (supertag-schema--goto-context
                 '(:type :tag :tag-id "task")))
        (supertag-schema--mark-item)
        (should (= (length supertag-schema--marked-items) 1)))
      (supertag-tag-rename "other" "Elsewhere")
      (with-current-buffer buffer
        (should (= (length supertag-schema--marked-items) 1))
        (should (supertag-schema--goto-context
                 '(:type :tag :tag-id "task")))
        (should (eq (get-text-property (point) 'face)
                    'supertag-schema-marked-face)))
      (supertag-tag-delete "task")
      (with-current-buffer buffer
        (should-not supertag-schema--marked-items)
        (should-not (supertag-schema--goto-context
                     '(:type :tag :tag-id "task")))))))

(ert-deftest supertag-view-schema-runtime-cleans-subscription-on-kill ()
  "Killing Schema View prevents later Store changes from rendering it."
  (supertag-view-schema-runtime-test--with-store
    (supertag-view-schema-runtime-test--put-tag "task" "Task")
    (let ((buffer (supertag-view-schema-runtime-test--open-counted)))
      (kill-buffer buffer)
      (supertag-tag-rename "task" "After Kill")
      (should (= supertag-view-schema-runtime-test--render-count 0)))))

(ert-deftest supertag-view-schema-runtime-reports-multi-collection-renders ()
  "Adding a field exposes, rather than coalesces, its two Store events."
  (supertag-view-schema-runtime-test--with-store
    (supertag-view-schema-runtime-test--put-tag "task" "Task")
    (supertag-view-schema-runtime-test--open-counted)
    (supertag-tag-add-field
     "task" '(:id "status" :name "Status" :type :string))
    (should (= supertag-view-schema-runtime-test--render-count 2))))

(ert-deftest supertag-view-schema-runtime-renderer-uses-state-only ()
  "The Schema renderer performs no Store reads after state gathering."
  (supertag-view-schema-runtime-test--with-store
    (supertag-view-schema-runtime-test--put-tag "task" "Task")
    (supertag-tag-add-field
     "task" '(:id "status" :name "Status" :type :string))
    (let ((state (supertag-schema--build-view-state nil)))
      (with-temp-buffer
        (supertag-schema-view-mode)
        (cl-letf (((symbol-function 'supertag-query-tags)
                   (lambda () (ert-fail "renderer queried Tags")))
                  ((symbol-function 'supertag-query-field-definitions)
                   (lambda () (ert-fail "renderer queried fields")))
                  ((symbol-function 'supertag-query-tag-field-associations)
                   (lambda (&rest _) (ert-fail "renderer queried bindings")))
                  ((symbol-function 'supertag-link-definition-list)
                   (lambda () (ert-fail "renderer queried links")))
                  ((symbol-function 'supertag-schema-authority-get)
                   (lambda (&rest _) (ert-fail "renderer queried authority"))))
          (supertag-schema--render-view state))
        (should (string-match-p "Status" (buffer-string)))))))

(provide 'view-schema-runtime-test)

;;; view-schema-runtime-test.el ends here
