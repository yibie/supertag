;;; view-refresh-single-path-test.el --- Single-path View refresh tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'org-id)
(require 'supertag-core-index)
(require 'supertag-core-store)
(require 'supertag-ops-relation)
(require 'supertag-ui-link)
(require 'supertag-ui-mention)
(require 'supertag-view-framework)
(require 'supertag-view-node)

(defmacro supertag-view-refresh-test--with-clean-env (&rest body)
  "Run BODY with an isolated Store, View registry, and temporary Org files."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "supertag-view-refresh-test" t))
          (supertag-data-directory tmp)
          (supertag-db-file (expand-file-name "supertag-db.el" tmp))
          (supertag-db-backup-directory (expand-file-name "backups" tmp))
          (supertag--store nil)
          (supertag--store-origin nil)
          (supertag--subscribers (make-hash-table :test #'equal))
          (supertag-view-node--enabled nil)
          (supertag-view-node-auto-show nil)
          (org-id-locations nil)
          (org-id-files nil)
          (org-id-locations-file (expand-file-name "org-id-locations" tmp)))
     (unwind-protect
         (progn
           (supertag--ensure-store)
           (supertag-index-rebuild-all)
           (supertag-view-framework-init)
           ,@body)
       (when-let* ((buffer (get-buffer supertag-view-node--buffer-name)))
         (kill-buffer buffer))
       (dolist (buffer (buffer-list))
         (when-let* ((file (buffer-file-name buffer)))
           (when (string-prefix-p tmp file)
             (kill-buffer buffer))))
       (ignore-errors (delete-directory tmp t)))))

(defun supertag-view-refresh-test--seed-link-model ()
  "Create two typed nodes and their Link Definition in the current Store."
  (supertag-store-put-entity
   :tags "source-tag" '(:id "source-tag" :name "Source"))
  (supertag-store-put-entity
   :tags "target-tag" '(:id "target-tag" :name "Target"))
  (supertag-store-put-entity
   :nodes "source-node"
   '(:id "source-node" :title "Source Node" :tags ("source-tag")))
  (supertag-store-put-entity
   :nodes "target-node"
   '(:id "target-node" :title "Target Node" :tags ("target-tag")))
  (supertag-store-put-entity
   :link-definitions "relates"
   '(:id "relates" :name "Relates" :inverse-name "Related from"
     :from-tag-id "source-tag" :to-tag-id "target-tag"
     :from-cardinality :many :to-cardinality :many
     :managed-by :interactive)))

(defun supertag-view-refresh-test--direction ()
  "Return the outgoing test Link direction descriptor."
  (list :definition (supertag-store-get-entity :link-definitions "relates")
        :definition-id "relates"
        :direction :out
        :label "Relates"
        :other-tag-id "target-tag"))

(defun supertag-view-refresh-test--open-counted-node (node-id)
  "Open NODE-ID through Runtime and return a mutable render counter."
  (supertag-view-node--register-view)
  (let* ((view (supertag-view-get 'node))
         (render-fn (plist-get view :render-fn))
         (counter (list 0)))
    (setf (plist-get view :render-fn)
          (lambda (state)
            (setcar counter (1+ (car counter)))
            (funcall render-fn state)))
    (with-temp-buffer
      (supertag-view-node--show-side node-id))
    (setcar counter 0)
    counter))

(ert-deftest supertag-view-refresh-link-add-renders-once ()
  "A typed-Link add must reach Node View through one Runtime refresh path."
  (supertag-view-refresh-test--with-clean-env
    (supertag-view-refresh-test--seed-link-model)
    (cl-letf (((symbol-function 'display-buffer) #'ignore)
              ((symbol-function 'display-buffer-in-side-window) #'ignore))
      (let ((counter
             (supertag-view-refresh-test--open-counted-node "source-node")))
        (with-current-buffer (get-buffer supertag-view-node--buffer-name)
          (cl-letf (((symbol-function 'supertag-link-ui--read-direction)
                     (lambda (_node-id)
                       (supertag-view-refresh-test--direction)))
                    ((symbol-function 'supertag-link-ui--read-other-node)
                     (lambda (_node-id _direction) "target-node")))
            (supertag-link-add "source-node")))
        (should (= (car counter) 1))
        (with-current-buffer (get-buffer supertag-view-node--buffer-name)
          (should (string-match-p "Target Node" (buffer-string))))))))

(ert-deftest supertag-view-refresh-link-remove-renders-once ()
  "A typed-Link removal must reach Node View through one Runtime refresh path."
  (supertag-view-refresh-test--with-clean-env
    (supertag-view-refresh-test--seed-link-model)
    (supertag-link-create "relates" "source-node" "target-node")
    (cl-letf (((symbol-function 'display-buffer) #'ignore)
              ((symbol-function 'display-buffer-in-side-window) #'ignore))
      (let ((counter
             (supertag-view-refresh-test--open-counted-node "source-node")))
        (with-current-buffer (get-buffer supertag-view-node--buffer-name)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt collection &rest _)
                       (caar collection)))
                    ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
            (supertag-link-remove "source-node")))
        (should (= (car counter) 1))
        (with-current-buffer (get-buffer supertag-view-node--buffer-name)
          (should-not (string-match-p "Target Node" (buffer-string)))
          (should (string-match-p "No typed Links" (buffer-string))))))))

(ert-deftest supertag-view-refresh-mention-reproject-renders-once ()
  "Mention reprojection must reach Node View through one Runtime refresh path."
  (supertag-view-refresh-test--with-clean-env
    (let ((source-file (expand-file-name "source.org" tmp)))
      (with-temp-file source-file
        (insert "* Source Node\n:PROPERTIES:\n:ID: source-node\n:END:\n\nBefore.\n"))
      (with-current-buffer (find-file-noselect source-file)
        (org-mode)
        (goto-char (point-min))
        (supertag-node-sync-at-point))
      (cl-letf (((symbol-function 'display-buffer) #'ignore)
                ((symbol-function 'display-buffer-in-side-window) #'ignore))
        (let ((counter
               (supertag-view-refresh-test--open-counted-node "source-node")))
          (with-current-buffer (find-file-noselect source-file)
            (goto-char (point-max))
            (insert "After.\n")
            (supertag-mention--finish-source-edit "source-node"))
          (should (= (car counter) 1)))))))

(provide 'view-refresh-single-path-test)

;;; view-refresh-single-path-test.el ends here
