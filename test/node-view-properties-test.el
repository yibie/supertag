;;; node-view-properties-test.el --- Public document view contracts -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-query)
(require 'supertag-view-node)

(defun supertag-document-view-test-mode-line-values ()
  "Evaluate the real mode-line expressions in batch Emacs.
Batch `format-mode-line' returns an empty string; use its installed expressions."
  (mapcar (lambda (item) (eval (cadr item) t))
          (cl-remove-if-not (lambda (item) (eq (car-safe item) :eval))
                            mode-line-format)))

(ert-deftest supertag-node-view-renders-only-real-projected-properties ()
  "The public window renders Q's title, ordered metadata and both counts."
  (supertag-document-test-with-vault
    (with-current-buffer (find-file-noselect file)
      (let ((disk (supertag-document-test-disk file))
            (live (buffer-string))
            (store (prin1-to-string supertag--store)))
        (cl-letf (((symbol-function 'supertag-query-node-detail)
                   (lambda (&rest _) (ert-fail "Public builder used old detail"))))
          (let ((view (supertag-view-node-open "document-node")))
            (should (get-buffer-window view))
            (with-current-buffer view
              (should (string-match-p "Property Node" (buffer-string)))
              (should (string-match-p "3 properties" (buffer-string)))
              (should (string-match-p "ALPHA +first" (buffer-string)))
              (should (string-match-p "EMPTY +\n" (buffer-string)))
              (should (string-match-p "ZETA +last" (buffer-string)))
              (should (string-match-p "ALPHA\\(?:.\\|\n\\)*EMPTY\\(?:.\\|\n\\)*ZETA"
                                      (buffer-string)))
              (should (equal '("document-node" "3" "0→0")
                             (mapcar #'substring-no-properties
                                     (supertag-document-view-test-mode-line-values)))))
            (kill-buffer view)))
        (set-buffer (find-file-noselect file))
        (should (equal live (buffer-string)))
        (should-not (buffer-modified-p))
        (should (equal disk (supertag-document-test-disk file)))
        (should (equal store (prin1-to-string supertag--store)))
        (should-not (memq #'supertag-view-node--post-command post-command-hook))))))

(ert-deftest supertag-node-view-refreshes-saved-property-change-and-deletion ()
  "Native saves, real queue/projection and subscribed public view stay current."
  (supertag-document-test-with-vault
    (let ((view (with-current-buffer (find-file-noselect file)
                  (supertag-view-node-open "document-node"))))
      (with-current-buffer view
        (goto-char (point-min)) (search-forward "ZETA")
        (beginning-of-line))
      (supertag-document-test-save-property file "ZETA" "changed")
      (supertag-document-test-drain)
      (with-current-buffer view
        (should (string-match-p "ZETA +changed" (buffer-string)))
        (should (looking-at-p " +ZETA")))
      (supertag-document-test-save-property file "ZETA" nil)
      (supertag-document-test-drain)
      (with-current-buffer view
        (should-not (string-match-p "ZETA\\|changed" (buffer-string)))
        (should (looking-at-p " +ALPHA"))
        (should (string-match-p "2 properties" (buffer-string)))
        (should (equal "2" (nth 1 (supertag-document-view-test-mode-line-values))))
        (supertag-view-node-refresh)
        (should (string-match-p "2 properties" (buffer-string))))
      (kill-buffer view)
      (should-not (get-buffer "*Supertag Node*"))
      (with-current-buffer (find-file-noselect file)
        (should-not (memq #'supertag-view-node--post-command post-command-hook))))))

(ert-deftest supertag-node-view-consumes-q-values-and-projection-version ()
  "Q output is observed by header, metadata and mode-line; live drafts are separate."
  (supertag-document-test-with-vault
    (supertag-document-test-save-property file "ALPHA" "saved-S1")
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min)) (org-entry-put nil "ALPHA" "live-S2"))
    (supertag-document-test-drain)
    (let ((view (supertag-view-node-open "document-node")))
      (with-current-buffer view
        (should (string-match-p "saved-S1" (buffer-string)))
        (should-not (string-match-p "live-S2" (buffer-string))))
      (let ((original (symbol-function 'supertag-note-query-read-node)))
        (cl-letf (((symbol-function 'supertag-note-query-read-node)
                   (lambda (id)
                     (let ((result (funcall original id)))
                       (setf (plist-get (plist-get result :node) :title) "Q sentinel"
                             (plist-get result :properties)
                             '((:key :PROBE :name "PROBE" :value "from-Q"))
                             (plist-get result :property-count) 1)
                       result))))
          (with-current-buffer view
            (supertag-view-node-refresh)
            (should (string-match-p "Q sentinel" (buffer-string)))
            (should (string-match-p "PROBE +from-Q" (buffer-string)))
            (should (string-match-p "1 properties" (buffer-string)))
            (should (equal "1" (nth 1 (supertag-document-view-test-mode-line-values)))))))
      (kill-buffer view))))

(provide 'node-view-properties-test)
;;; node-view-properties-test.el ends here

(ert-deftest supertag-node-view-many-saved-properties-at-default-depth ()
  "303 saved properties reach the public window through the native queue."
  (supertag-document-test-with-vault
    (let ((depth max-lisp-eval-depth))
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-min))
        (dotimes (n 300)
          (org-entry-put nil (format "P%04d" n) (format "v-%d" n)))
        (setq-local after-save-hook nil)
        (supertag-sync-setup-realtime-hooks)
        (save-buffer))
      (should (member (file-truename file) supertag-async--queue))
      (supertag-document-test-drain)
      (should (= 606 (length (plist-get
                             (supertag-store-get-entity :nodes "document-node")
                             :properties))))
      (with-current-buffer (find-file-noselect file)
        (let ((live (buffer-string))
              (disk (supertag-document-test-disk file))
              (store (prin1-to-string supertag--store))
              (view (supertag-view-node-open "document-node")))
          (with-current-buffer view
            (should (get-buffer-window view))
            (should (string-match-p "303 properties" (buffer-string)))
            (should (string-match-p "P0000 +v-0" (buffer-string)))
            (should (string-match-p "P0299 +v-299" (buffer-string)))
            (should (equal "303" (nth 1 (supertag-document-view-test-mode-line-values))))
            (supertag-view-node-refresh)
            (should (string-match-p "P0299 +v-299" (buffer-string))))
          (kill-buffer view)
          (set-buffer (find-file-noselect file))
          (should (equal live (buffer-string)))
          (should-not (buffer-modified-p))
          (should (equal disk (supertag-document-test-disk file)))
          (should (equal store (prin1-to-string supertag--store)))))
      (should (= depth max-lisp-eval-depth)))))

;;; VWA independent view ownership controls.
(defconst supertag-node-view-vwa--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(defun supertag-node-view-vwa--child (name body)
  "Run BODY in a genuinely fresh, isolated source process; retain evidence."
  (let* ((tmp (make-temp-file "supertag-vwa-" t))
         (script (expand-file-name "child.el" tmp))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (root supertag-node-view-vwa--root)
         (process-environment (copy-sequence process-environment)))
    (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
    (with-temp-file script
      (insert ";;; -*- lexical-binding: t; -*-\n")
      (prin1
       `(condition-case err
            (unwind-protect
                (progn
                  (require 'cl-lib) (require 'ert)
                  (setq user-emacs-directory ,(file-name-as-directory tmp)
                        supertag-data-directory ,tmp supertag--base-data-directory ,tmp
                        supertag-db-file ,(expand-file-name "db.el" tmp)
                        supertag-db-backup-directory ,(expand-file-name "backups" tmp)
                        supertag-sync-state-file ,(expand-file-name "sync.el" tmp)
                        supertag-sync--state-source supertag-sync-state-file
                        org-id-locations-file ,(expand-file-name "ids" tmp)
                        org-id-track-globally nil after-init-time nil
                        supertag-sync-directories (list ,tmp)
                        supertag-sync-directories-mode 'unified
                        make-backup-files nil auto-save-default nil)
                  (let ((vwa-root ,root) (vwa-tmp ,tmp)
                        (before (equal (getenv "SUPERTAG_VWA_STAGE") "before")))
                    ,body)
                  (princ ,(concat "VWA-" name "-DONE\n")))
              (setq kill-emacs-hook nil emacs-startup-hook nil org-mode-hook nil
                    enable-theme-functions nil)
              (mapc #'cancel-timer (append timer-list timer-idle-list)))
          (error (princ (format "VWA-ERROR %S\n" err)) (kill-emacs 1)))
       (current-buffer)))
    (unwind-protect
        (with-temp-buffer
          (let* ((exit (apply #'call-process
                              (or (getenv "EMACS_BIN")
                                  (expand-file-name invocation-name invocation-directory))
                              nil t nil
                              (append '("-Q" "--batch")
                                      (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                      (list "-L" root "-L" (expand-file-name "test" root)
                                            "-l" script))))
                 (output (buffer-string)) (evidence (getenv "SUPERTAG_VWA_EVIDENCE")))
            (when evidence
              (make-directory evidence t)
              (copy-file script (expand-file-name (concat name ".el") evidence) t)
              (with-temp-file (expand-file-name (concat name ".log") evidence) (insert output))
              (with-temp-file (expand-file-name (concat name ".exit") evidence) (prin1 exit (current-buffer))))
            (princ output)
            (should (equal exit 0))
            (should (string-match-p (concat "VWA-" name "-DONE") output))))
      (delete-directory tmp t))))

(ert-deftest supertag-node-view-vwa-cold-services-entry ()
  (supertag-node-view-vwa--child
   "services"
   '(progn
      (should-not (featurep 'supertag-services-sync))
      (should-not (featurep 'document-fixture))
      (should-not (featurep 'supertag-view-node))
      (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener))
      (princ "VWA-services-ENTRY\n")
      (should (featurep 'supertag-services-sync))
      (should-not (featurep 'document-fixture))
      (should-not (featurep 'supertag-view-node))
      (should-not (fboundp 'supertag-register-listener))
      (if before
          (should (equal "supertag-services-ui.el"
                         (file-name-nondirectory (symbol-file 'supertag-view-build-node-state 'defun))))
        (should-not (fboundp 'supertag-view-build-node-state)))
      (require 'supertag-view-node)
      (let ((builder (symbol-function 'supertag-view-build-node-state)) (calls nil))
        (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener))
        (require 'supertag-view-node)
        (should (eq builder (symbol-function 'supertag-view-build-node-state)))
        ;; Deliberately installed availability seam, not a native subscription API.
        (cl-letf (((symbol-function 'supertag-register-listener)
                   (lambda (event callback) (push (list event callback) calls))))
          (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener))
          (should-not calls)
          (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener t)))
        (should (equal calls '((:store-changed supertag-ui--invalidate-cache-on-change))))
        (should (equal (if before "supertag-services-ui.el" "supertag-view-node.el")
                       (file-name-nondirectory (symbol-file 'supertag-view-build-node-state 'defun))))
        (unless before (should (eq builder (symbol-function 'supertag-view-build-node-state)))))
      (princ "VWA-CONDITIONAL-LISTENER call=1; native API originally absent\n"))))

(ert-deftest supertag-node-view-vwa-cold-node-entry ()
  (supertag-node-view-vwa--child
   "node"
   '(progn
      (should-not (featurep 'document-fixture))
      (should-not (featurep 'supertag-services-sync))
      (require 'supertag-view-node)
      (princ "VWA-node-ENTRY\n")
      (should-not (featurep 'supertag-services-ui))
      (should supertag-node--cache-listener-prepared)
      (should (featurep 'supertag-services-sync))
      (should-not (featurep 'document-fixture))
      (should (fboundp 'supertag-view-build-node-state))
      (should (= 1 (cl-count #'supertag-view-node--on-window-selection-change
                             window-selection-change-functions)))
      (let ((fn (symbol-function 'supertag-view-build-node-state))
            (hooks (copy-sequence window-selection-change-functions)))
        (require 'supertag-view-node)
        (should (eq fn (symbol-function 'supertag-view-build-node-state)))
        (should (equal hooks window-selection-change-functions)))
      (let ((supertag--store nil))
        (should-not (supertag-view-build-node-state nil))
        (should-not (supertag-view-build-node-state 12))
        (should-error (supertag-view-build-node-state "missing"))
        (should-error (supertag-view-build-node-state ""))
        (should-not supertag--store)))))

(ert-deftest supertag-node-view-vwa-owner ()
  (supertag-node-view-vwa--child
   "owner"
   '(progn
      (require 'supertag-view-node)
      (princ "VWA-owner-ENTRY\n")
      (should (equal "supertag-view-node.el"
                     (file-name-nondirectory (symbol-file 'supertag-view-build-node-state 'defun)))))))

(ert-deftest supertag-node-view-vwa-state-and-public-refresh ()
  (supertag-node-view-vwa--child
   "state"
   '(progn
      ;; Real cold snapshot precedes any fixture/Sync preload.
      (should-not (featurep 'document-fixture))
      (should-not (featurep 'supertag-services-sync))
      (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener))
      (when before (should (fboundp 'supertag-view-build-node-state)))
      (require 'supertag-view-node)
      (princ "VWA-state-ENTRY-COLD-COMPLETE\n")
      (require 'document-fixture)
      (supertag-document-test-with-vault
        (let ((other (expand-file-name "other.org" tmp))
              (incoming (expand-file-name "incoming.org" tmp))
              (supertag-text-link-relation-types '("supports")))
          (supertag-tag-create '(:id "vwa-tag" :name "vwa-tag"))
          (with-temp-file other
            (insert "* Other\n:PROPERTIES:\n:ID: vwa-other\n:END:\nBody\n"))
          (with-temp-file incoming
            (insert "* Incoming\n:PROPERTIES:\n:ID: vwa-in\n:END:\n[[id:document-node][incoming]]\n[[supports:document-node][named incoming]]\n"))
          (with-current-buffer (find-file-noselect file)
            (goto-char (point-min)) (end-of-line) (insert " #vwa-tag")
            (goto-char (point-max))
            (insert "[[id:vwa-other][outgoing]]\n[[supports:vwa-other][named outgoing]]\n")
            (save-buffer))
          (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
          (princ "VWA-state-REAL-PROJECTION\n")
          (let* ((files (list file plain other incoming))
                 (disks (mapcar #'supertag-document-test-disk files))
                 (live (with-current-buffer (find-file-noselect file) (buffer-string)))
                 (store (prin1-to-string supertag--store))
                 (state (supertag-view-build-node-state "document-node")))
            (should-not (supertag-view-build-node-state "missing"))
            (should (equal "document-node" (plist-get state :id)))
            (should (equal '("vwa-tag") (plist-get state :tags)))
            (should (equal '("ALPHA" "EMPTY" "ZETA")
                           (mapcar (lambda (p) (plist-get p :name)) (plist-get state :properties))))
            (should (equal '("first" "" "last")
                           (mapcar (lambda (p) (plist-get p :value)) (plist-get state :properties))))
            (should (equal '("vwa-other") (plist-get state :refs-to)))
            (should (equal '("vwa-in") (plist-get state :refs-from)))
            (should (= 2 (plist-get state :ref-count)))
            (should (= 3 (plist-get state :property-count)))
            (should (= 1 (length (supertag-query-named-links-from "document-node"))))
            (should (= 1 (length (supertag-query-named-links-to "document-node"))))
            ;; Only Q-detached node/properties are promised deeply isolated.
            (aset (plist-get (plist-get state :node) :title) 0 ?X)
            (aset (plist-get (car (plist-get state :properties)) :value) 0 ?X)
            (should (equal store (prin1-to-string supertag--store)))
            (should (equal disks (mapcar #'supertag-document-test-disk files)))
            (with-current-buffer (find-file-noselect file)
              (should (equal live (buffer-string))) (should-not (buffer-modified-p))))
          (let* ((baseline (length (gethash :store-changed supertag--subscribers)))
                 (view (with-current-buffer (find-file-noselect file)
                         (supertag-view-node-open "document-node"))))
            (unwind-protect
                (progn
                  (should (= (1+ baseline) (length (gethash :store-changed supertag--subscribers))))
                  (with-current-buffer view
                    (should (string-match-p "Property Node" (buffer-string)))
                    (should (string-match-p "3 properties" (buffer-string)))
                    (should (string-match-p "ALPHA +first" (buffer-string)))
                    (should (string-match-p "supports" (buffer-string)))
                    (goto-char (point-min)) (search-forward "ZETA") (beginning-of-line)
                    (princ (format "VWA-WINDOW before point=%s start=%S\n"
                                   (point) (window-start (get-buffer-window view)))))
                  (supertag-document-test-save-property file "ZETA" "updated")
                  (supertag-document-test-drain)
                  (with-current-buffer view
                    (should (looking-at-p " +ZETA"))
                    (should (string-match-p "ZETA +updated" (buffer-string)))
                    (supertag-view-node-refresh)
                    (princ (format "VWA-WINDOW after point=%s start=%S\n"
                                   (point) (window-start (get-buffer-window view)))))
                  (supertag-view-node-open "document-node")
                  (should (= (1+ baseline) (length (gethash :store-changed supertag--subscribers))))
                  (princ "VWA-REAL-OUTPUT refs=2 properties=3 title=Property Node\n")
                  (should (= 2 (plist-get (supertag-view-build-node-state "document-node") :ref-count))))
              (when (buffer-live-p view) (kill-buffer view)))
            (should (= baseline (length (gethash :store-changed supertag--subscribers))))
            (with-current-buffer (find-file-noselect file)
              (should-not (memq #'supertag-view-node--post-command post-command-hook))))
          (let ((missing (supertag-view-node-open "missing")))
            (unwind-protect
                (with-current-buffer missing
                  (should (equal "Node missing not found." (buffer-string)))
                  (should-not supertag-view-node--current-node-id))
              (when (buffer-live-p missing) (kill-buffer missing)))))))))
