;;; stream-workflow-test.el --- Durable Stream workflows -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'org)
(if (equal (getenv "SUPERTAG_SYA_STAGE") "before")
      (require 'supertag-ui-commands)
    (require 'supertag-services-sync))
(require 'supertag-view-stream)

(defmacro supertag-stream-test--isolated (&rest body)
  "Run BODY with temporary Org files and an isolated projected library."
  (declare (indent 0))
  `(let* ((tmp (file-truename (make-temp-file "supertag-stream-workflow-" t)))
          (supertag-data-directory (expand-file-name "data/" tmp))
          (supertag-db-file (expand-file-name "db.el" tmp))
          (supertag-db-backup-directory (expand-file-name "backup/" tmp))
          (supertag-sync-state-file (expand-file-name "state.el" tmp))
          (supertag-sync-directories (list tmp))
          (supertag--store nil) (supertag--store-origin nil)
          (supertag--subscribers (make-hash-table :test 'equal))
          (supertag--index-source-revisions (make-hash-table :test 'eq))
          (supertag-automation-sync--enabled nil)
          (org-id-locations nil) (org-id-files nil)
          (org-id-locations-file (expand-file-name "ids" tmp))
          (original-buffers (buffer-list)))
     (unwind-protect
         (save-window-excursion
           (supertag--ensure-store)
           (supertag-tag-create '(:id "diary" :name "diary"))
           ,@body)
       (dolist (buffer (cl-set-difference (buffer-list) original-buffers))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory tmp t))))

(defun supertag-stream-test--source (tmp &optional file-level)
  "Write and project a real source in TMP, optionally FILE-LEVEL."
  (let ((file (expand-file-name "source.org" tmp)))
    (with-temp-file file
      (insert (if file-level
                  ":PROPERTIES:\n:ID: source\n:END:\n#+FILETAGS: :diary:\n"
                "* Source :diary:\n:PROPERTIES:\n:ID: source\n:END:\n"))
      (insert "Original body\n")
      (unless file-level
        (insert "* Outside\n:PROPERTIES:\n:ID: outside\n:END:\nOutside body\n")))
    (with-current-buffer (find-file-noselect file)
      (org-mode)
      (goto-char (point-min))
      (if file-level
          (supertag-ui--ensure-file-node-synced file)
        (supertag-node-sync-at-point)))
    file))

(defun supertag-stream-test--disk (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun supertag-stream-test--edit ()
  (supertag-view-stream "diary")
  (supertag-view-stream-edit))

(ert-deftest supertag-stream-finish-saves-whole-file-before-projecting ()
  (supertag-stream-test--isolated
    (let* ((file (supertag-stream-test--source tmp))
           (base (find-file-noselect file)) edit events
           (real-save (symbol-function 'save-buffer))
           (real-project (symbol-function 'supertag-service-org--project-current-node)))
      (with-current-buffer base
        (goto-char (point-max)) (insert "Existing outside draft\n"))
      (setq edit (supertag-stream-test--edit))
      (goto-char (point-max)) (insert "New Stream body\n")
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (push :save events) (apply real-save args)))
                ((symbol-function 'supertag-service-org--project-current-node)
                 (lambda (id)
                   (push :project events) (funcall real-project id))))
        (supertag-view-stream-edit-finish))
      (should (equal '(:save :project) (nreverse events)))
      (should-not (buffer-live-p edit))
      (should-not (buffer-modified-p base))
      (should (string-match-p "Existing outside draft" (supertag-stream-test--disk file)))
      (should (string-match-p "New Stream body" (supertag-stream-test--disk file)))
      (should (string-match-p "New Stream body" (plist-get (supertag-node-get "source") :content)))
      (should (derived-mode-p 'supertag-view-stream-mode))
      (should (equal "source" (supertag-view-stream--current-node-id))))))

(ert-deftest supertag-stream-cancel-restores-context-and-preserves-outside-drafts ()
  (supertag-stream-test--isolated
    (let* ((file (supertag-stream-test--source tmp))
           (base (find-file-noselect file)) before edit)
      (with-current-buffer base
        (goto-char 8) (set-mark 12) (setq mark-active t)
        (narrow-to-region 3 30)
        (setq before (list (point) (mark) mark-active (point-min) (point-max))))
      (setq edit (supertag-stream-test--edit))
      (should (equal before (with-current-buffer base
                             (list (point) (mark) mark-active (point-min) (point-max)))))
      (goto-char (point-max)) (insert "Cancelled\n")
      (with-current-buffer base
        (save-excursion (save-restriction
          (widen) (goto-char (point-max)) (insert "Outside during edit\n"))))
      (supertag-view-stream-edit-abort)
      (should (equal before (with-current-buffer base
                             (list (point) (mark) mark-active (point-min) (point-max)))))
      (with-current-buffer base
        (should (buffer-modified-p))
        (save-restriction
          (widen)
          (should (string-match-p "Outside during edit" (buffer-string)))
          (should-not (string-match-p "Cancelled" (buffer-string)))))
      (should-not (string-match-p "Outside during edit" (supertag-stream-test--disk file))))))

(ert-deftest supertag-stream-native-save-advances-only-successful-cancel-baseline ()
  (supertag-stream-test--isolated
    (let* ((file (supertag-stream-test--source tmp))
           (base (find-file-noselect file))
           (edit (supertag-stream-test--edit)))
      (goto-char (point-max)) (insert "Saved session text\n")
      (call-interactively #'save-buffer)
      (should (string-match-p "Saved session text" (supertag-stream-test--disk file)))
      (goto-char (point-max)) (insert "Unsaved later text\n")
      (supertag-view-stream-edit-abort)
      (should-not (buffer-live-p edit))
      (with-current-buffer base
        (should (string-match-p "Saved session text" (buffer-string)))
        (should-not (string-match-p "Unsaved later text" (buffer-string)))
        (should-not (buffer-modified-p)))
      (should (equal (with-current-buffer base (buffer-string))
                     (supertag-stream-test--disk file))))))

(ert-deftest supertag-stream-failed-native-save-does-not-advance-cancel-baseline ()
  (supertag-stream-test--isolated
    (let* ((file (supertag-stream-test--source tmp))
           (before (supertag-stream-test--disk file))
           (base (find-file-noselect file)))
      (supertag-stream-test--edit)
      (goto-char (point-max)) (insert "Failed save draft\n")
      (cl-letf (((symbol-function 'write-region)
                 (lambda (&rest _) (error "injected disk failure"))))
        (should-error (call-interactively #'save-buffer)
                      :type 'error))
      (should (buffer-modified-p base))
      (supertag-view-stream-edit-abort)
      (should (equal before (supertag-stream-test--disk file)))
      (should (equal before (with-current-buffer base (buffer-string))))
      (should-not (buffer-modified-p base)))))

(ert-deftest supertag-stream-finish-save-failure-retains-edit-without-projecting ()
  (supertag-stream-test--isolated
    (let* ((file (supertag-stream-test--source tmp))
           (before (supertag-stream-test--disk file))
           (projected (copy-tree (supertag-node-get "source")))
           (edit (supertag-stream-test--edit)) caught)
      (goto-char (point-max)) (insert "Retained draft\n")
      (cl-letf (((symbol-function 'write-region)
                 (lambda (&rest _) (error "finish save failed"))))
        (condition-case data (supertag-view-stream-edit-finish)
          (error (setq caught data))))
      (should (equal '(error "finish save failed") caught))
      (should (buffer-live-p edit))
      (should (eq (current-buffer) edit))
      (should (buffer-modified-p (buffer-base-buffer edit)))
      (should (equal projected (supertag-node-get "source")))
      (should (equal before (supertag-stream-test--disk file)))
      (supertag-view-stream-edit-finish)
      (should-not (buffer-live-p edit))
      (should (string-match-p "Retained draft" (supertag-stream-test--disk file))))))

(ert-deftest supertag-stream-projection-failure-keeps-durable-edit-and-retry ()
  (supertag-stream-test--isolated
    (let* ((file (supertag-stream-test--source tmp))
           (edit (supertag-stream-test--edit)) payload)
      (goto-char (point-max)) (insert "Durable text\n")
      (cl-letf (((symbol-function 'supertag-service-org--project-current-node)
                 (lambda (&rest _) (error "projection failed"))))
        (condition-case data (supertag-view-stream-edit-finish)
          (supertag-projection-error (setq payload (cdr data)))))
      (should (plist-get payload :retry))
      (should (buffer-live-p edit))
      (should (string-match-p "Durable text" (supertag-stream-test--disk file)))
      (apply (plist-get payload :retry) (plist-get payload :retry-args))
      (should (string-match-p "Durable text" (plist-get (supertag-node-get "source") :content)))
      (with-current-buffer edit (supertag-view-stream-edit-finish))
      (should (= 1 (with-temp-buffer
                     (insert-file-contents file)
                     (how-many "Durable text" (point-min) (point-max))))))))

(ert-deftest supertag-stream-file-level-finish-and-no-change-finish ()
  (supertag-stream-test--isolated
    (let ((file (supertag-stream-test--source tmp t)))
      (supertag-stream-test--edit)
      (goto-char (point-max)) (insert "File-level text\n")
      (supertag-view-stream-edit-finish)
      (should (string-match-p "File-level text" (supertag-stream-test--disk file)))
      (let ((before (supertag-stream-test--disk file)))
        (supertag-view-stream-edit)
        (supertag-view-stream-edit-finish)
        (should (equal before (supertag-stream-test--disk file)))))))

(ert-deftest supertag-stream-consecutive-sessions-release-save-hooks ()
  (supertag-stream-test--isolated
    (let* ((file (supertag-stream-test--source tmp))
           (base (find-file-noselect file))
           (hooks (buffer-local-value 'after-save-hook base))
           (change-hooks (remq t (copy-sequence
                                  (buffer-local-value 'after-change-functions base)))))
      ;; An unrelated draft predates the edit and must remain dirty on cancel.
      (with-current-buffer base
        (goto-char (point-max)) (insert "Earlier draft\n"))
      (dotimes (_ 3)
        (let* ((edit (supertag-stream-test--edit))
               (callback (plist-get supertag-view-stream-edit--session :save-hook))
               (change-callback (plist-get supertag-view-stream-edit--session :change-hook)))
          (should (functionp callback))
          (should (functionp change-callback))
          (goto-char (point-max)) (insert "Pending session\n")
          ;; A live-only projection is not a successful save checkpoint.
          (goto-char (point-min)) (supertag-node-sync-at-point)
          (supertag-view-stream-edit-abort)
          (should-not (buffer-live-p edit))
          (should-not (memq callback (buffer-local-value 'after-save-hook base)))
          (should-not (memq change-callback (buffer-local-value 'after-change-functions base)))
          (should (equal hooks (remq t (buffer-local-value 'after-save-hook base))))
          (should (equal change-hooks (remq t (buffer-local-value 'after-change-functions base))))
          (with-current-buffer base
            (should (buffer-modified-p))
            (should (string-match-p "Earlier draft" (buffer-string)))
            (should-not (string-match-p "Pending session" (buffer-string))))))
      ;; Killing an edit also releases its local base save callback.
      (let ((edit (supertag-stream-test--edit)))
        (kill-buffer edit)
        (should (equal hooks (remq t (buffer-local-value 'after-save-hook base))))
        (should (equal change-hooks (remq t (buffer-local-value 'after-change-functions base))))))))

(ert-deftest supertag-stream-full-collection-refreshes-saved-title-and-membership ()
  (supertag-stream-test--isolated
    (dotimes (file-index 2)
      (let ((file (expand-file-name (format "collection-%s.org" file-index) tmp)))
        (with-temp-file file
          (dotimes (i 12)
            (insert (format "* Entry %s-%s :diary:\n:PROPERTIES:\n:ID: entry-%s-%s\n:END:\nBody\n"
                            file-index i file-index i))))
        (with-current-buffer (find-file-noselect file)
          (org-mode)
          (org-map-entries (lambda () (supertag-node-sync-at-point)) nil 'file))))
    (let* ((stream (supertag-view-stream "diary"))
           (ids (supertag-view-stream--node-ids stream))
           (id (car ids)))
      (should (= 24 (length ids)))
      (dotimes (_ 23) (call-interactively #'supertag-view-stream-next-node))
      (should (equal (car (last ids)) (supertag-view-stream--current-node-id)))
      (dotimes (_ 23) (call-interactively #'supertag-view-stream-previous-node))
      (should (equal id (supertag-view-stream--current-node-id)))
      (supertag-view-stream-edit)
      (org-edit-headline "Updated title")
      (supertag-view-stream-edit-finish)
      (should (equal id (supertag-view-stream--current-node-id)))
      (should (string-match-p "Updated title" (buffer-string)))
      (supertag-view-stream-edit)
      (org-set-tags nil)
      (supertag-view-stream-edit-finish)
      (should (= 23 (length (supertag-view-stream--node-ids stream))))
      (should-not (member id (supertag-view-stream--node-ids stream)))
      (should (member (supertag-view-stream--current-node-id)
                      (supertag-view-stream--node-ids stream))))))

(ert-deftest supertag-stream-real-node-view-related-note-and-native-return ()
  (supertag-stream-test--isolated
    (let* ((file (supertag-stream-test--source tmp))
           (base (find-file-noselect file))
           (target (expand-file-name "related.org" tmp))
           stream stream-window stream-point view)
      (with-temp-file target
        (insert "* Related\n:PROPERTIES:\n:ID: related\n:END:\nRelated body\n"))
      (with-current-buffer (find-file-noselect target)
        (org-mode) (goto-char (point-min)) (supertag-node-sync-at-point))
      (with-current-buffer base
        (goto-char (point-min)) (search-forward "Original body")
        (insert " [[id:related][Related]]")
        (goto-char (point-min))
        (supertag-service-org-save-and-project-current-node "source"))
      (switch-to-buffer base)
      (goto-char 8) (set-mark 12) (setq mark-active t)
      (narrow-to-region 3 30)
      (setq stream (supertag-view-stream "diary")
            stream-window (selected-window)
            stream-point (point))
      (setq view (supertag-view-stream-open-node-view))
      (should (derived-mode-p 'supertag-view-node-mode))
      (goto-char (point-min))
      (let ((position (text-property-any (point-min) (point-max)
                                          'supertag-node-id "related")))
        ;; text-property-any uses eq; search the rendered card's actual value.
        (unless position
          (setq position (point-min))
          (while (and (< position (point-max))
                      (not (equal "related" (get-text-property position 'supertag-node-id))))
            (setq position (1+ position))))
        (should (< position (point-max)))
        (goto-char position)
        (call-interactively (key-binding (kbd "RET"))))
      (should (equal (file-truename target) (file-truename buffer-file-name)))
      (call-interactively #'previous-buffer)
      (should (eq view (current-buffer)))
      (select-window stream-window)
      (should (eq stream (current-buffer)))
      (should (= stream-point (point)))
      (should (equal "source" (supertag-view-stream--current-node-id)))
      (supertag-view-stream-edit)
      (goto-char (point-max)) (insert "After reading related\n")
      (supertag-view-stream-edit-finish)
      (should (eq stream (current-buffer)))
      (supertag-view-stream-quit)
      (should (eq base (current-buffer)))
      (should (equal '(8 12 t 3 30)
                     (list (point) (mark) mark-active (point-min) (point-max)))))))

(ert-deftest supertag-stream-native-org-link-preserves-live-edit-position ()
  (supertag-stream-test--isolated
    (let* ((file (supertag-stream-test--source tmp))
           (target (expand-file-name "native-target.org" tmp))
           edit edit-window context)
      (with-temp-file target
        (insert "* Native target\n:PROPERTIES:\n:ID: native-target\n:END:\nBody\n"))
      (with-current-buffer (find-file-noselect target)
        (org-mode) (goto-char (point-min)) (supertag-node-sync-at-point))
      (setq edit (supertag-stream-test--edit)
            edit-window (selected-window))
      (goto-char (point-max))
      (insert "[[id:native-target][Read related]]\n")
      (search-backward "Read related")
      (set-mark (point-min)) (setq mark-active t)
      (setq context (list (point) (point-min) (point-max)))
      (call-interactively #'org-open-at-point)
      (should (equal (file-truename target) (file-truename buffer-file-name)))
      (call-interactively #'previous-buffer)
      ;; Org may use another window: the native edit window remains authoritative.
      (select-window edit-window)
      (should (eq edit (current-buffer)))
      (should (equal context (list (point) (point-min) (point-max))))
      ;; Native Org pushes the departure point as mark when following a link.
      (should (= (car context) (mark)))
      (supertag-view-stream-edit-abort)
      (should-not (string-match-p "Read related" (supertag-stream-test--disk file))))))

(defun supertag-stream-test--cancel-boundary (outside inside &optional inside-first)
  "Exercise OUTSIDE/INSIDE edits at one boundary, optionally INSIDE-FIRST."
  (supertag-stream-test--isolated
    (let* ((file (supertag-stream-test--source tmp))
           (before (supertag-stream-test--disk file))
           (base (find-file-noselect file))
           (edit (supertag-stream-test--edit))
           (sibling "* Added outside\nOutside addition\n"))
      (when (and inside inside-first)
        (goto-char (point-max)) (insert "Pending inside\n"))
      (when outside
        (with-current-buffer base
          (goto-char (point-min)) (search-forward "* Outside")
          (beginning-of-line) (insert sibling))
        (with-current-buffer edit
          (should-not (string-match-p "Added outside" (buffer-string)))))
      (when (and inside (not inside-first))
        (with-current-buffer edit
          (goto-char (point-max)) (insert "Pending inside\n")))
      (with-current-buffer edit
        (call-interactively #'supertag-view-stream-edit-abort))
      (should-not (buffer-live-p edit))
      (with-current-buffer base
        (should (equal (if outside
                           (replace-regexp-in-string
                            "\\* Outside" (concat sibling "* Outside") before t t)
                         before)
                       (buffer-string)))
        (should (eq (not (null outside)) (not (null (buffer-modified-p))))))
      (should (equal before (supertag-stream-test--disk file))))))

(ert-deftest supertag-stream-cancel-preserves-base-boundary-new-sibling ()
  (supertag-stream-test--cancel-boundary t nil))

(ert-deftest supertag-stream-cancel-removes-edit-point-max-append ()
  (supertag-stream-test--cancel-boundary nil t))

(ert-deftest supertag-stream-cancel-separates-both-boundary-insertion-orders ()
  (supertag-stream-test--cancel-boundary t t)
  (supertag-stream-test--cancel-boundary t t t))

(defun supertag-stream-test--close-keeps-new-windows (finish)
  "Close via FINISH or cancel without deleting newly opened native windows."
  (supertag-stream-test--isolated
    (let* ((file (supertag-stream-test--source tmp))
           (base (find-file-noselect file))
           stream edit edit-window others)
      (switch-to-buffer base)
      (goto-char 8) (set-mark 12) (setq mark-active t)
      (narrow-to-region 3 30)
      (setq stream (supertag-view-stream "diary")
            edit (supertag-view-stream-edit)
            edit-window (selected-window))
      (delete-other-windows)
      (goto-char (point-max)) (insert "Session change\n")
      (dotimes (i 2)
        (let* ((other-file (expand-file-name (format "other-%s.org" i) tmp))
               (window (split-window-right)))
          (with-temp-file other-file (insert "* Other\nNative content\n"))
          (with-selected-window window
            (find-file other-file)
            (goto-char 5))
          (push (list window (window-buffer window) (window-point window)) others)))
      (let ((layout (mapcar (lambda (window) (cons window (window-edges window)))
                            (window-list))))
        (with-selected-window edit-window
          (call-interactively (if finish #'supertag-view-stream-edit-finish
                                #'supertag-view-stream-edit-abort)))
        (should-not (buffer-live-p edit))
        (dolist (entry others)
          (should (window-live-p (car entry)))
          (should (eq (nth 1 entry) (window-buffer (car entry))))
          (should (= (nth 2 entry) (window-point (car entry)))))
        (should (equal layout
                       (mapcar (lambda (window) (cons window (window-edges window)))
                               (window-list))))
        (should (eq stream (window-buffer edit-window)))
        (with-selected-window edit-window
          (call-interactively #'supertag-view-stream-next-node)
          (should (equal "source" (supertag-view-stream--current-node-id)))))
      (with-current-buffer base
        (should (equal '(8 12 t 3 30)
                       (list (point) (mark) mark-active (point-min) (point-max)))))
      (should (eq (not (null finish))
                  (not (null (string-match-p "Session change"
                                             (supertag-stream-test--disk file)))))))))

(ert-deftest supertag-stream-finish-preserves-new-native-windows ()
  (supertag-stream-test--close-keeps-new-windows t))

(ert-deftest supertag-stream-cancel-preserves-new-native-windows ()
  (supertag-stream-test--close-keeps-new-windows nil))

(provide 'stream-workflow-test)
