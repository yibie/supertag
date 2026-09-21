;;; supertag-link-writer-boundary-test.el --- Physical link writer tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'supertag-ui-commands)
(require 'supertag-service-org)
(require 'supertag-ui-search)
(require 'supertag-link)
(require 'supertag-core-store)
(require 'supertag-link)
(require 'supertag-services-sync)

(defun supertag-link-writer-test--replace (beg end target-id title)
  "Test double for materializing BEG..END as TARGET-ID titled TITLE."
  (with-current-buffer (marker-buffer beg)
    (goto-char beg)
    (delete-region beg end)
    (insert (supertag-node-format-link target-id title))))

(defmacro supertag-link-writer-test--with-store (&rest body)
  "Run BODY with an isolated Store and sync root."
  (declare (indent 0) (debug t))
  `(let* ((vault (make-temp-file "supertag-link-writer-vault" t))
          (data (make-temp-file "supertag-link-writer-data" t))
          (supertag-data-directory data)
          (supertag-db-file (expand-file-name "supertag-db.el" data))
          (supertag-db-backup-directory (expand-file-name "backups" data))
          (supertag--store nil)
          (supertag--store-origin nil)
          (supertag-sync-directories (list vault))
          (supertag-active-sync-directory vault)
          (org-id-locations nil)
          (org-id-files nil)
          (org-id-locations-file (expand-file-name "org-id-locations" data)))
     (unwind-protect
         (progn
           (supertag--ensure-store)
           ,@body)
       (dolist (buffer (buffer-list))
         (when-let* ((file (buffer-file-name buffer)))
           (when (or (string-prefix-p vault file)
                     (string-prefix-p data file))
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer))))
       (ignore-errors (delete-directory vault t))
       (ignore-errors (delete-directory data t)))))

(ert-deftest supertag-add-reference-delegates-physical-write-to-materializer ()
  "Add Reference retains its UI while delegating the physical write."
  (with-temp-buffer
    (org-mode)
    (insert "* Source\nBody\n")
    (goto-char (point-max))
    (let (materialized reprojected)
      (cl-letf (((symbol-function 'supertag-ui--get-containing-node-at-point)
                 (lambda () "source"))
                ((symbol-function 'supertag-ui--ensure-node-synced) #'ignore)
                ((symbol-function 'supertag-ui-select-node)
                 (lambda (&rest _) "target"))
                ((symbol-function 'supertag-node-get)
                 (lambda (_id) '(:title "Target")))
                ((symbol-function 'supertag-ui--document-link-bounds)
                 (lambda (_id) (cons (point-min) (point-max))))
                ((symbol-function 'supertag-node-link-pattern)
                 (lambda (_id) "never-match"))
                ((symbol-function 'supertag-reference-materialize)
                 (lambda (beg end target-id title)
                   (setq materialized
                         (list (marker-position beg) (marker-position end)
                               target-id title))))
                ((symbol-function 'supertag-ui--reproject-containing-node)
                 (lambda (_id) (setq reprojected t)))
                ((symbol-function 'save-buffer) #'ignore)
                ((symbol-function 'message) #'ignore))
        (let ((at (point)))
          (supertag-add-reference)
          (should (equal (list at at "target" "Target") materialized))
          (should-not reprojected))))))

(ert-deftest supertag-ui-move-and-link-delegates-common-service ()
  "The interactive move command delegates its replacement link to the service."
  (let* ((dir (make-temp-file "supertag-ui-move-link" t))
         (source (expand-file-name "source.org" dir))
         (target (expand-file-name "target.org" dir))
         source-buffer
         delegated)
    (unwind-protect
        (progn
          (with-temp-file source
            (insert "* Node\n:PROPERTIES:\n:ID: node-id\n:END:\nBody\n* Keep\n"))
          (with-temp-file target)
          (setq source-buffer (find-file-noselect source))
          (with-current-buffer source-buffer
            (org-mode)
            (goto-char (point-min))
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest _) target))
                      ((symbol-function 'supertag-ui-select-insert-position)
                       (lambda (_file) '(:position 1 :level 1)))
                      ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                      ((symbol-function 'supertag-service-org-move-nodes)
                       (lambda (sources file position level leave-link)
                         (setq delegated
                               (list sources file position level leave-link))
                         '("node-id")))
                      ((symbol-function 'message) #'ignore))
              (supertag-move-node-and-link))
            (should (equal '("node-id") (nth 0 delegated)))
            (should (equal target (nth 1 delegated)))
            (should (markerp (nth 2 delegated)))
            (should (= 1 (nth 3 delegated)))
            (should (eq t (nth 4 delegated)))))
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer (set-buffer-modified-p nil))
        (kill-buffer source-buffer))
      (when-let* ((buffer (get-file-buffer target)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest supertag-service-move-leave-link-writes-independent-stub ()
  "The Org move service writes a distinct stub without nested materialization."
  (let* ((dir (make-temp-file "supertag-service-move-link" t))
         (source (expand-file-name "source.org" dir))
         (target (expand-file-name "target.org" dir))
         source-buffer
         (materialized 0))
    (unwind-protect
        (progn
          (with-temp-file source
            (insert "* Node\n:PROPERTIES:\n:ID: node-id\n:END:\nBody\n* Keep\n"))
          (with-temp-file target)
          (setq source-buffer (find-file-noselect source))
          (with-current-buffer source-buffer (org-mode))
          (let ((source-marker
                 (with-current-buffer source-buffer (copy-marker (point-min)))))
            (cl-letf (((symbol-function 'supertag-node-location-find)
                       (lambda (_id) source-marker))
                      ((symbol-function 'supertag-node-set-location) #'ignore)
                      ((symbol-function 'supertag--mark-internal-modification)
                       #'ignore)
                      ((symbol-function 'supertag-reference-materialize)
                       (lambda (&rest _) (cl-incf materialized)))
                      ((symbol-function 'supertag-reference-materialize-at-point)
                       (lambda (&rest _) (cl-incf materialized)))
                      ((symbol-function 'message) #'ignore))
              (supertag-service-org-move-node-to-file
               "node-id" target t))
            (set-marker source-marker nil))
          (with-current-buffer source-buffer
            (goto-char (point-min))
            (should (= 0 materialized))
            (should (looking-at-p "\\* Node$"))
            (let ((stub-id (org-entry-get nil "ID")))
              (should stub-id)
              (should-not (equal stub-id "node-id")))
            (org-end-of-meta-data t)
            (should (looking-at-p "\\[\\[id:node-id\\]\\[Node\\]\\]$"))))
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer (set-buffer-modified-p nil))
        (kill-buffer source-buffer))
      (when-let* ((buffer (get-file-buffer target)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest supertag-service-move-leave-link-projects-from-stub-body ()
  "A completed move leaves a body link whose Document Link is projected."
  (supertag-link-writer-test--with-store
    (let* ((source (expand-file-name "source.org" vault))
           (target (expand-file-name "target.org" vault)))
      (with-temp-file source
        (insert "* Node\n:PROPERTIES:\n:ID: node-id\n:END:\nBody\n* Keep\n"))
      (with-temp-file target)
      (with-current-buffer (find-file-noselect source)
        (org-mode)
        (goto-char (point-min))
        (should (supertag-node-sync-at-point)))
      (should (supertag-service-org-move-node-to-file "node-id" target t))
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-min))
        (should (looking-at-p "\\* Node$"))
        (let ((stub-id (org-entry-get nil "ID")))
          (should stub-id)
          (org-end-of-meta-data t)
          (should (looking-at-p "\\[\\[id:node-id\\]\\[Node\\]\\]$"))
          (let ((relations
                 (supertag-relation-find-between
                  stub-id "node-id" :reference)))
            (should (= 1 (length relations)))
            (should (supertag-relation-document-link-p (car relations)))))))))

(ert-deftest supertag-ui-move-and-link-projects-from-stub-body ()
  "The interactive move completes with a projected backlink from its stub."
  (supertag-link-writer-test--with-store
    (let* ((source (expand-file-name "source.org" vault))
           (target (expand-file-name "target.org" vault)))
      (with-temp-file source
        (insert "* Node\n:PROPERTIES:\n:ID: node-id\n:END:\nBody\n* Keep\n"))
      (with-temp-file target)
      (with-current-buffer (find-file-noselect source)
        (org-mode)
        (goto-char (point-min))
        (should (supertag-node-sync-at-point))
        (cl-letf (((symbol-function 'read-file-name)
                   (lambda (&rest _) target))
                  ((symbol-function 'supertag-ui-select-insert-position)
                   (lambda (_file) '(:position 1 :level 1)))
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                  ((symbol-function 'message) #'ignore))
          (supertag-move-node-and-link))
        (goto-char (point-min))
        (should (looking-at-p "\\* Node$"))
        (let ((stub-id (org-entry-get nil "ID")))
          (should stub-id)
          (org-end-of-meta-data t)
          (should (looking-at-p "\\[\\[id:node-id\\]\\[Node\\]\\]$"))
          (let ((relations
                 (supertag-relation-find-between
                  stub-id "node-id" :reference)))
            (should (= 1 (length relations)))
            (should (supertag-relation-document-link-p (car relations)))))))))

(ert-deftest supertag-discovery-insert-delegates-each-link-to-materializer ()
  "Inserting marked Discovery results delegates every physical link."
  (let* ((tmp (make-temp-file "supertag-discovery-boundary-" t))
         (source (expand-file-name "source.org" tmp))
         (origin (find-file-noselect source))
        (search-buffer (generate-new-buffer " *supertag-search-results*"))
        calls)
    (unwind-protect
        (progn
          (with-current-buffer origin
            (org-mode)
            (insert "* Source\n")
            (goto-char (point-max)))
          (with-current-buffer search-buffer
            (setq-local supertag-discovery--marked-nodes '("two" "one")
                        supertag-discovery--origin-marker
                        (with-current-buffer origin (copy-marker (point) t))
                        supertag-discovery--origin-min-marker
                        (with-current-buffer origin (copy-marker (point-min)))
                        supertag-discovery--origin-max-marker
                        (with-current-buffer origin (copy-marker (point-max) t)))
            (cl-letf (((symbol-function 'supertag-node-get)
                       (lambda (id)
                         (list :id id :title (capitalize id))))
                      ((symbol-function 'supertag-node-location-find)
                       (lambda (_id)
                         (with-current-buffer origin (copy-marker (point-min)))))
                      ((symbol-function 'supertag-reference-materialize)
                       (lambda (beg end target-id title)
                         (push (list target-id title) calls)
                         (supertag-link-writer-test--replace
                          beg end target-id title)))
                      ((symbol-function 'message) #'ignore))
              (supertag-discovery-insert-references)))
          (should (equal '(("one" "One") ("two" "Two"))
                         (nreverse calls)))
          (with-current-buffer origin
            (should (equal "* Source\n- [[id:one][One]]\n- [[id:two][Two]]\n"
                           (buffer-string)))))
      (when (buffer-live-p origin) (kill-buffer origin))
      (when (buffer-live-p search-buffer) (kill-buffer search-buffer))
      (ignore-errors (delete-directory tmp t)))))

(ert-deftest supertag-search-export-writes-a-generated-view-without-materializing ()
  "A new export is a generated view, not a source-owned reference assertion."
  (let* ((dir (make-temp-file "supertag-search-export" t))
         (file (expand-file-name "export.org" dir)))
    (unwind-protect
        (cl-letf (((symbol-function 'supertag-search-get-selected-nodes)
                   (lambda () '("one" "two")))
                  ((symbol-function 'read-file-name)
                   (lambda (&rest _) file))
                  ((symbol-function 'supertag-node-get)
                   (lambda (id) (list :id id :title (capitalize id))))
                  ((symbol-function 'supertag-reference-materialize)
                   (lambda (&rest _)
                     (ert-fail "Generated export called the materializer")))
                  ((symbol-function 'find-file) #'ignore)
                  ((symbol-function 'message) #'ignore))
          (supertag-search-export-results-to-new-file)
          (with-temp-buffer
            (insert-file-contents file)
            (org-mode)
            (should (search-forward "#+BEGIN: supertag-search-export" nil t))
            (should (search-forward "- [[id:one][One]]" nil t))
            (should (search-forward "- [[id:two][Two]]" nil t))
            (should (search-forward "#+END:" nil t))
            (let* ((tree (org-element-parse-buffer))
                   (headline (org-element-map tree 'headline #'identity nil t)))
              (should-not
               (plist-get (supertag-extractor--refs headline file nil)
                          :ref-to)))))
      (when-let* ((buffer (get-file-buffer file)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest supertag-reference-materialize-at-point-cleans-up-its-markers ()
  "The at-point helper preserves insertion behavior and releases its markers."
  (with-temp-buffer
    (insert "beforeafter")
    (goto-char 7)
    (let (beg end)
      (cl-letf (((symbol-function 'supertag-reference-materialize)
                 (lambda (beg-marker end-marker target-id title)
                   (setq beg beg-marker end end-marker)
                   (supertag-link-writer-test--replace
                    beg-marker end-marker target-id title))))
        (supertag-reference-materialize-at-point "target" "Target"))
      (should (equal "before[[id:target][Target]]after" (buffer-string)))
      (should-not (marker-buffer beg))
      (should-not (marker-buffer end)))))

(provide 'supertag-link-writer-boundary-test)

;;; supertag-link-writer-boundary-test.el ends here
