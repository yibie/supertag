;;; test-view-table.el --- Tests for table views -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'supertag-view-table)

(ert-deftest supertag-view-table-refs-field-is-not-duplicated ()
  "The reserved Refs column must replace a same-slug schema field."
  (let ((supertag-use-global-fields nil))
    (cl-letf (((symbol-function 'supertag-tag-get-id-by-name)
               (lambda (_) "task"))
              ((symbol-function 'supertag-tag-get-all-fields)
               (lambda (_) '((:name "Refs" :type :node-reference))))
              ((symbol-function 'supertag-view-table--get-virtual-columns)
               #'ignore))
      (let ((keys
             (mapcar (lambda (column) (plist-get column :key))
                     (supertag-view-table--get-columns-for-tag "task"))))
        (should (= 1 (cl-count :refs keys :test #'eq)))
        (should-not (memq 'refs keys))))))

(ert-deftest supertag-view-table-column-read-does-not-create-refs-schema ()
  "Reading Table columns must not mutate legacy or global schemas."
  (dolist (use-global '(nil t))
    (let ((supertag--store (make-hash-table :test 'equal))
          (supertag--schema-cache (make-hash-table :test 'eq))
          (supertag-ops-schema--resolved-cache (make-hash-table :test 'equal))
          (supertag-use-global-fields use-global)
          (event-count 0))
      (supertag--ensure-store)
      (supertag-store-put-entity
       :tags "task" '(:id "task" :name "task" :fields nil))
      ;; Pre-create the read collections so the assertion only observes
      ;; semantic writes, not lazy empty-bucket allocation.
      (supertag-store-get-collection :field-definitions)
      (supertag-store-get-collection :tag-field-associations)
      (cl-letf (((symbol-function 'supertag-emit-event)
                 (lambda (&rest _args) (cl-incf event-count))))
        (should (memq :refs
                      (mapcar (lambda (column) (plist-get column :key))
                              (supertag-view-table--get-columns-for-tag
                               "task")))))
      (should (zerop event-count))
      (should-not (supertag-store-get-field-definition "refs"))
      (should-not (supertag-store-get-tag-field-associations "task"))
      (should-not (plist-get (supertag-store-get-entity :tags "task")
                             :fields)))))

(ert-deftest supertag-view-table-preserves-smart-key-cell-properties ()
  "Rendered cells must retain the existing Smart Key properties."
  (let ((supertag--store (make-hash-table :test 'equal))
        (buffer-name "*Supertag Table: all*"))
    (unwind-protect
        (progn
          (supertag--ensure-store)
          (supertag-store-put-entity
           :nodes "table-1" '(:id "table-1" :title "Alpha"))
          (let ((buffer
                 (save-window-excursion
                   (supertag-view-table
                    '(:type :nodes :value "all")
                    '((:name "Title" :key :title :width 20))))))
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Alpha")
              (let ((position (1- (point))))
                (should (equal (get-text-property position 'entity-id)
                               "table-1"))
                (should (eq (get-text-property position 'col-key) :title))
                (should (= (get-text-property position 'col-index) 0))))))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest supertag-view-table-runtime-refresh-restores-selected-row ()
  "Table refresh must rebuild data and restore the selected entity."
  (let ((supertag--store (make-hash-table :test 'equal))
        (buffer-name "*Supertag Table: all*"))
    (unwind-protect
        (progn
          (supertag--ensure-store)
          (supertag-store-put-entity
           :nodes "table-1" '(:id "table-1" :title "Alpha"))
          (supertag-store-put-entity
           :nodes "table-2" '(:id "table-2" :title "Beta"))
          (let ((buffer
                 (save-window-excursion
                   (supertag-view-table
                    '(:type :nodes :value "all")
                    '((:name "Title" :key :title :width 20))))))
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Beta"))
            (supertag-store-put-entity
             :nodes "table-2" '(:id "table-2" :title "Beta updated"))
            (with-current-buffer buffer
              (supertag-view-table-refresh)
              (should (equal (get-text-property (point) 'entity-id)
                             "table-2"))
              (should (equal (get-text-property (point) 'supertag-entity-id)
                             "table-2"))
              (should (string-match-p "Beta updated" (buffer-string))))))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest supertag-view-table-runtime-owns-store-subscription ()
  "Table must refresh on real Store events and unsubscribe on kill."
  (let ((supertag--store (make-hash-table :test 'equal))
        (supertag--subscribers (make-hash-table :test 'equal))
        (buffer-name "*Supertag Table: all*"))
    (unwind-protect
        (progn
          (supertag--ensure-store)
          (supertag-store-put-entity
           :nodes "table-1" '(:id "table-1" :title "Before"))
          (let ((buffer
                 (save-window-excursion
                   (supertag-view-table
                    '(:type :nodes :value "all")
                    '((:name "Title" :key :title :width 20))))))
            (should (= (length (gethash :store-changed supertag--subscribers))
                       1))
            (supertag-store-put-entity
             :nodes "table-1" '(:id "table-1" :title "After") t)
            (with-current-buffer buffer
              (should (string-match-p "After" (buffer-string))))
            (kill-buffer buffer)
            (should-not (gethash :store-changed supertag--subscribers))))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest supertag-view-table-row-cache-invalidates-on-store-revision ()
  "A direct Store mutation must invalidate cached rows before rebuilding."
  (let ((supertag--store (make-hash-table :test 'equal))
        (supertag--index-source-revisions (make-hash-table :test #'eq))
        (cell-reads 0)
        (original-cell-reader
         (symbol-function 'supertag-view-table--get-cell-value)))
    (supertag--ensure-store)
    (supertag-store-put-entity :nodes "one" '(:id "one" :title "Before"))
    (supertag-store-put-entity :nodes "two" '(:id "two" :title "Stable"))
    (with-temp-buffer
      (setq-local supertag-view-table--query-objs
                  '((:type :nodes :value "all")))
      (setq-local supertag-view-table--current-table-index 0)
      (setq-local supertag-view-table--entity-ids '("one" "two"))
      (setq-local supertag-view-table--columns
                  '((:name "Title" :key :title :width 20)))
      (cl-letf (((symbol-function 'supertag-view-table--get-cell-value)
                 (lambda (data key column)
                   (cl-incf cell-reads)
                   (funcall original-cell-reader data key column))))
        (supertag-view-table--build-state)
        (supertag-view-table--build-state)
        (should (= 2 cell-reads))
        ;; No event is emitted here.  The Store revision token is the safety
        ;; net for callers that build state outside a live Runtime view.
        (supertag-store-put-entity
         :nodes "one" '(:id "one" :title "After"))
        (let* ((state (supertag-view-table--build-state))
               (row (car (plist-get state :rows))))
          (should (= 4 cell-reads))
          (should (equal "After" (cdar (plist-get row :values)))))))))

(ert-deftest supertag-view-table-row-cache-targets-field-change ()
  "A field event evicts its row while retaining unaffected cached rows."
  (let ((supertag--store (make-hash-table :test 'equal))
        (supertag--index-source-revisions (make-hash-table :test #'eq))
        (cell-reads 0)
        (original-cell-reader
         (symbol-function 'supertag-view-table--get-cell-value)))
    (supertag--ensure-store)
    (supertag-store-put-entity :nodes "one" '(:id "one" :title "One"))
    (supertag-store-put-entity :nodes "two" '(:id "two" :title "Two"))
    (with-temp-buffer
      (setq-local supertag-view-table--query-objs
                  '((:type :nodes :value "all")))
      (setq-local supertag-view-table--current-table-index 0)
      (setq-local supertag-view-table--entity-ids '("one" "two"))
      (setq-local supertag-view-table--columns
                  '((:name "Title" :key :title :width 20)))
      (cl-letf (((symbol-function 'supertag-view-table--get-cell-value)
                 (lambda (data key column)
                   (cl-incf cell-reads)
                   (funcall original-cell-reader data key column))))
        (supertag-view-table--build-state)
        (supertag-index-note-store-change :field-values)
        (supertag-view-table--invalidate-row-cache
         '(:field-values "one" "status"))
        (supertag-view-table--build-state)
        (should (= 3 cell-reads))))))

(ert-deftest supertag-view-table-does-not-cache-dynamic-default-columns ()
  "Function-valued defaults have no Store invalidation signal, so stay live."
  (let ((supertag--store (make-hash-table :test 'equal))
        (supertag--index-source-revisions (make-hash-table :test #'eq))
        (cell-reads 0)
        (original-cell-reader
         (symbol-function 'supertag-view-table--get-cell-value)))
    (supertag--ensure-store)
    (supertag-store-put-entity :nodes "one" '(:id "one" :title "One"))
    (with-temp-buffer
      (setq-local supertag-view-table--query-objs
                  '((:type :nodes :value "all")))
      (setq-local supertag-view-table--current-table-index 0)
      (setq-local supertag-view-table--entity-ids '("one"))
      (setq-local supertag-view-table--columns
                  (list (list :name "Dynamic" :key :title :width 20
                              :default (lambda () (current-time-string)))))
      (cl-letf (((symbol-function 'supertag-view-table--get-cell-value)
                 (lambda (data key column)
                   (cl-incf cell-reads)
                   (funcall original-cell-reader data key column))))
        (supertag-view-table--build-state)
        (supertag-view-table--build-state)
        (should (= 2 cell-reads))))))

(ert-deftest supertag-view-table-event-does-not-hide-earlier-unannounced-change ()
  "Targeted invalidation must fall back to full when another revision changed."
  (let ((supertag--store (make-hash-table :test 'equal))
        (supertag--index-source-revisions (make-hash-table :test #'eq))
        (cell-reads 0)
        (original-cell-reader
         (symbol-function 'supertag-view-table--get-cell-value)))
    (supertag--ensure-store)
    (supertag-store-put-entity :nodes "one" '(:id "one" :title "Before"))
    (supertag-store-put-entity :nodes "two" '(:id "two" :title "Stable"))
    (with-temp-buffer
      (setq-local supertag-view-table--query-objs
                  '((:type :nodes :value "all")))
      (setq-local supertag-view-table--current-table-index 0)
      (setq-local supertag-view-table--entity-ids '("one" "two"))
      (setq-local supertag-view-table--columns
                  '((:name "Title" :key :title :width 20)))
      (cl-letf (((symbol-function 'supertag-view-table--get-cell-value)
                 (lambda (data key column)
                   (cl-incf cell-reads)
                   (funcall original-cell-reader data key column))))
        (supertag-view-table--build-state)
        (supertag-store-put-entity
         :nodes "one" '(:id "one" :title "After"))
        (supertag-index-note-store-change :field-values)
        (supertag-view-table--invalidate-row-cache
         '(:field-values "two" "status"))
        (let* ((state (supertag-view-table--build-state))
               (row (car (plist-get state :rows))))
          (should (= 4 cell-reads))
          (should (equal "After" (cdar (plist-get row :values)))))))))

(provide 'test-view-table)

;;; test-view-table.el ends here
