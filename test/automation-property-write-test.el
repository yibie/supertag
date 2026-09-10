;;; automation-property-write-test.el --- Org-first Automation property writes -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)

(when load-file-name
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)
(require 'supertag-node)
(require 'supertag-service-org)
(require 'supertag-automation)

(defmacro supertag-automation-property-test--with-node (property-line &rest body)
  "Run BODY with an isolated projected node containing PROPERTY-LINE."
  (declare (indent 1) (debug t))
  `(let* ((tmp (make-temp-file "supertag-automation-property-test-" t))
          (file (expand-file-name "nodes.org" tmp))
          (supertag--store nil)
          (supertag--subscribers (make-hash-table :test 'equal))
          (supertag-sync--internal-modifications (make-hash-table :test 'equal))
          buffer)
     (unwind-protect
         (progn
           (with-temp-file file
             (insert "* TODO Node\n:PROPERTIES:\n:ID:       node-id\n")
             (when ,property-line (insert ,property-line "\n"))
             (insert ":END:\nBody\n"))
           (supertag--ensure-store)
           (supertag-node-create
            `(:id "node-id" :title "Node" :todo "TODO" :file ,file
              :level 1 :position 1 :properties (:STATUS "database")))
           (setq buffer (find-file-noselect file))
           (with-current-buffer buffer
             (org-mode)
             (goto-char (point-min)))
           ,@body)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (ignore-errors (delete-directory tmp t)))))

(defun supertag-automation-property-test--disk-property (file property)
  "Read PROPERTY from FILE without visiting user state."
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (goto-char (point-min))
    (org-entry-get nil property)))

(ert-deftest supertag-automation-property-live-source-overrides-stale-projection ()
  "A matching stale DB value cannot suppress a different live Org write."
  (supertag-automation-property-test--with-node ":STATUS: live"
    (supertag-automation-action-update-property
     "node-id" '(:property :status :value "database"))
    (should (equal "database"
                   (supertag-automation-property-test--disk-property file "STATUS")))
    (should (equal "database"
                   (plist-get (plist-get (supertag-node-get "node-id") :properties)
                              :STATUS)))))

(ert-deftest supertag-automation-property-noop-uses-live-value ()
  "An unchanged live value neither saves nor projects, regardless of DB state."
  (supertag-automation-property-test--with-node ":STATUS: live"
    (let (calls)
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest _) (push 'save calls)))
                ((symbol-function 'supertag-service-org--project-current-node)
                 (lambda (&rest _) (push 'project calls))))
        (should (equal "live"
                       (supertag-service-org-set-property
                        "node-id" :status "live"))))
      (should-not calls))))

(ert-deftest supertag-automation-property-nil-deletes-live-property ()
  "A nil value removes the property from Org and its Projection."
  (supertag-automation-property-test--with-node ":STATUS: live"
    (should-not (supertag-service-org-set-property "node-id" "STATUS" nil))
    (should-not (supertag-automation-property-test--disk-property file "STATUS"))
    (should-not (plist-member
                 (plist-get (supertag-node-get "node-id") :properties) :STATUS))))

(ert-deftest supertag-automation-property-converts-supported-scalars ()
  "Supported scalar values have deterministic Org text representations."
  (supertag-automation-property-test--with-node nil
    (dolist (case '((:count 42 "42") (:ratio 1.5 "1.5")
                    (:active t "true") (:state ready "ready")))
      (supertag-service-org-set-property "node-id" (nth 0 case) (nth 1 case))
      (should (equal (nth 2 case)
                     (supertag-automation-property-test--disk-property
                      file (upcase (substring (symbol-name (nth 0 case)) 1))))))))

(ert-deftest supertag-automation-property-rejects-unsafe-input-before-edit ()
  "Invalid names, identity writes, multiline and structured values fail closed."
  (supertag-automation-property-test--with-node ":STATUS: live"
    (let ((before (with-current-buffer buffer (buffer-string))))
      (dolist (args '(("bad name" "x") ("ID" "other")
                      ("TAGS" "x") ("STATUS" "two\nlines")
                      ("STATUS" ("structured"))))
        (should-error
         (apply #'supertag-service-org-set-property "node-id" args)))
      (should (equal before (with-current-buffer buffer (buffer-string))))
      (should-not (buffer-modified-p buffer)))))

(ert-deftest supertag-automation-property-uses-native-special-properties ()
  "Writable special properties retain Org's native behavior."
  (supertag-automation-property-test--with-node nil
    (let ((org-log-done nil)
          (org-log-repeat nil))
      (supertag-service-org-set-property "node-id" :todo "DONE")
      (with-current-buffer buffer
        (goto-char (point-min))
        (should (equal "DONE" (org-get-todo-state))))
      (supertag-service-org-set-property "node-id" :priority "A")
      (with-current-buffer buffer
        (goto-char (point-min))
        (should (equal "A" (org-entry-get nil "PRIORITY"))))
      (supertag-service-org-set-property "node-id" :todo nil)
      (with-current-buffer buffer
        (goto-char (point-min))
        (should-not (org-get-todo-state))))))

(ert-deftest supertag-automation-property-nil-removes-planning-line ()
  "Nil removes an existing SCHEDULED value through Org's native path."
  (supertag-automation-property-test--with-node nil
    (with-current-buffer buffer
      (goto-char (point-min))
      (forward-line 1)
      (insert "SCHEDULED: <2026-09-06 Sun>\n")
      (save-buffer))
    (should (org-string-nw-p
             (with-current-buffer buffer
               (goto-char (point-min))
               (org-entry-get nil "SCHEDULED"))))
    (should-not
     (supertag-service-org-set-property "node-id" :scheduled nil))
    (with-temp-buffer
      (insert-file-contents file)
      (should-not (search-forward "SCHEDULED:" nil t)))))

(ert-deftest supertag-automation-property-planning-input-normalizes-before-noop ()
  "A repeated raw date input saves once after Org adds timestamp syntax."
  (supertag-automation-property-test--with-node nil
    (let ((real-save (symbol-function 'save-buffer))
          (saves 0))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (cl-incf saves)
                   (apply real-save args))))
        (supertag-service-org-set-property "node-id" :scheduled "2026-09-05")
        (supertag-service-org-set-property "node-id" :scheduled "2026-09-05"))
      (should (= 1 saves))
      (with-temp-buffer
        (insert-file-contents file)
        (should (re-search-forward
                 "SCHEDULED: <2026-09-05 [A-Za-z]+>" nil t))))))

(ert-deftest supertag-automation-property-planning-preserves-repeater-semantics ()
  "Equal dates with different repeaters are distinct planning values."
  (supertag-automation-property-test--with-node nil
    (with-current-buffer buffer
      (goto-char (point-min))
      (forward-line 1)
      (insert "SCHEDULED: <2026-09-05 Sat +1w>\n")
      (save-buffer))
    (supertag-service-org-set-property
     "node-id" :scheduled "<2026-09-05 Sat +1m>")
    (should (equal "<2026-09-05 Sat +1m>"
                   (supertag-automation-property-test--disk-property
                    file "SCHEDULED")))))

(ert-deftest supertag-automation-property-bare-date-removes-live-repeater ()
  "A bare date request must not equal a same-day repeating timestamp."
  (supertag-automation-property-test--with-node nil
    (with-current-buffer buffer
      (goto-char (point-min))
      (forward-line 1)
      (insert "SCHEDULED: <2026-09-05 Sat +1w>\n")
      (save-buffer))
    (supertag-service-org-set-property "node-id" :scheduled "2026-09-05")
    (should (equal "<2026-09-05 Sat>"
                   (supertag-automation-property-test--disk-property
                    file "SCHEDULED")))))

(ert-deftest supertag-automation-property-full-stamp-removes-live-repeater ()
  "An absolute timestamp without a repeater replaces one that has it."
  (supertag-automation-property-test--with-node nil
    (with-current-buffer buffer
      (goto-char (point-min))
      (forward-line 1)
      (insert "SCHEDULED: <2026-09-10 Thu +1w>\n")
      (save-buffer))
    (let ((real-save (symbol-function 'save-buffer))
          (saves 0))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (cl-incf saves)
                   (apply real-save args))))
        (supertag-service-org-set-property
         "node-id" :scheduled "<2026-09-10 Thu>")
        (supertag-service-org-set-property
         "node-id" :scheduled "<2026-09-10 Thu>"))
      (should (= 1 saves))
      (should (equal "<2026-09-10 Thu>"
                     (supertag-automation-property-test--disk-property
                      file "SCHEDULED"))))))

(ert-deftest supertag-automation-property-full-stamp-removes-live-warning ()
  "An absolute timestamp without a warning replaces one that has it."
  (supertag-automation-property-test--with-node nil
    (with-current-buffer buffer
      (goto-char (point-min))
      (forward-line 1)
      (insert "DEADLINE: <2026-09-10 Thu -2d>\n")
      (save-buffer))
    (let ((real-save (symbol-function 'save-buffer))
          (saves 0))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (cl-incf saves)
                   (apply real-save args))))
        (supertag-service-org-set-property
         "node-id" :deadline "<2026-09-10 Thu>")
        (supertag-service-org-set-property
         "node-id" :deadline "<2026-09-10 Thu>"))
      (should (= 1 saves))
      (should (equal "<2026-09-10 Thu>"
                     (supertag-automation-property-test--disk-property
                      file "DEADLINE"))))))

(ert-deftest supertag-automation-property-ordinary-text-normalizes-before-noop ()
  "A repeated padded scalar saves once after Org text normalization."
  (supertag-automation-property-test--with-node nil
    (let ((real-save (symbol-function 'save-buffer))
          (saves 0))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (cl-incf saves)
                   (apply real-save args))))
        (supertag-service-org-set-property "node-id" :label "  padded  ")
        (supertag-service-org-set-property "node-id" :label "  padded  "))
      (should (= 1 saves))
      (should (equal "padded"
                     (supertag-automation-property-test--disk-property
                      file "LABEL"))))))

(ert-deftest supertag-automation-property-custom-id-preserves-node-identity ()
  "CUSTOM_ID remains an ordinary property and cannot replace the node ID."
  (supertag-automation-property-test--with-node nil
    (supertag-service-org-set-property "node-id" :custom_id "public-name")
    (with-current-buffer buffer
      (goto-char (point-min))
      (should (equal "node-id" (org-entry-get nil "ID")))
      (should (equal "public-name" (org-entry-get nil "CUSTOM_ID"))))
    (should (equal "node-id" (plist-get (supertag-node-get "node-id") :id)))))

(ert-deftest supertag-automation-property-save-failure-leaves-visible-unsaved-edit ()
  "Save failure keeps the edit visible and publishes no Projection."
  (supertag-automation-property-test--with-node ":STATUS: live"
    (let ((before-node (copy-tree (supertag-node-get "node-id")))
          projected)
      (should-error
       (cl-letf (((symbol-function 'save-buffer)
                  (lambda (&rest _) (error "deliberate save failure")))
                 ((symbol-function 'supertag-service-org--project-current-node)
                  (lambda (&rest _) (setq projected t))))
         (supertag-service-org-set-property "node-id" :status "edited")))
      (should-not projected)
      (should (equal before-node (supertag-node-get "node-id")))
      (should (equal "live"
                     (supertag-automation-property-test--disk-property file "STATUS")))
      (with-current-buffer buffer
        (goto-char (point-min))
        (should (equal "edited" (org-entry-get nil "STATUS")))
        (should (buffer-modified-p))))))

(ert-deftest supertag-automation-property-projection-failure-keeps-durable-text ()
  "Post-save Projection failure retains Org and carries retry metadata."
  (supertag-automation-property-test--with-node ":STATUS: live"
    (let (caught)
      (condition-case err
          (cl-letf (((symbol-function 'supertag-service-org--project-current-node)
                     (lambda (&rest _) (error "deliberate projection failure"))))
            (supertag-service-org-set-property "node-id" :status "durable"))
        (error (setq caught err)))
      (should (eq 'supertag-projection-error (car caught)))
      (should (equal "node-id" (plist-get (cdr caught) :node-id)))
      (should (equal file (plist-get (cdr caught) :file)))
      (should (eq 'supertag-service-org-retry-node-projection
                  (plist-get (cdr caught) :retry)))
      (should (equal (list "node-id" file)
                     (plist-get (cdr caught) :retry-args)))
      (should (equal "durable"
                     (supertag-automation-property-test--disk-property file "STATUS"))))))

(ert-deftest supertag-automation-property-missing-or-readonly-source-fails-closed ()
  "Missing and read-only sources fail without editing their Projection."
  (supertag-automation-property-test--with-node ":STATUS: live"
    (let ((before (copy-tree (supertag-node-get "node-id"))))
      (with-current-buffer buffer (setq buffer-read-only t))
      (unwind-protect
          (should-error
           (supertag-service-org-set-property "node-id" :status "blocked"))
        (with-current-buffer buffer (setq buffer-read-only nil)))
      (should (equal before (supertag-node-get "node-id")))
      (delete-file file)
      (should-error
       (supertag-service-org-set-property "node-id" :status "missing"))
      (should (equal before (supertag-node-get "node-id"))))))

(ert-deftest supertag-automation-property-rejects-file-level-node ()
  "AC6 accepts identified headings, not synthetic file-level nodes."
  (supertag-automation-property-test--with-node ":STATUS: live"
    (supertag-node-update
     "node-id" (lambda (node) (plist-put (copy-tree node) :level 0)))
    (should-error
     (supertag-service-org-set-property "node-id" :status "blocked"))
    (should (equal "live"
                   (supertag-automation-property-test--disk-property file "STATUS")))))

(ert-deftest supertag-automation-property-trigger-matches-repeat-save-once ()
  "Repeated matching tag events reach Org, whose live no-op saves only once."
  (supertag-automation-property-test--with-node ":STATUS: live"
    (supertag-subscribe :store-changed #'supertag-automation--handle-entity-change)
    (supertag-automation-create
     '(:name "property-trigger"
       :trigger (:on-tag-added "repeat-tag")
       :actions ((:action :update-property
                  :params (:property :status :value "durable")))))
    (let ((real-save (symbol-function 'save-buffer))
          (saves 0))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (cl-incf saves)
                   (apply real-save args))))
        (supertag-node-add-tag "node-id" "repeat-tag")
        (supertag-node-remove-tag "node-id" "repeat-tag")
        (supertag-node-add-tag "node-id" "repeat-tag"))
      (should (= 1 saves))
      (should (equal "durable"
                     (supertag-automation-property-test--disk-property file "STATUS")))
      (should (equal "durable"
                     (plist-get (plist-get (supertag-node-get "node-id") :properties)
                                :STATUS))))))

(provide 'automation-property-write-test)
;;; automation-property-write-test.el ends here
