;;; node-view-test.el --- Public document view contracts -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-query)
(require 'supertag-view-node)

(ert-deftest supertag-node-view-hides-org-properties-shows-only-discovered-context ()
  "Node View renders a node's discovered tag but never its Org properties."
  (let* ((tmp (file-name-as-directory
               (file-truename (make-temp-file "supertag-node-view-props-" t))))
         (file (expand-file-name "ready-item.org" tmp))
         (supertag-data-directory (expand-file-name "data/" tmp))
         (supertag-db-file (expand-file-name "store.el" supertag-data-directory))
         (supertag-db-backup-directory
          (expand-file-name "backups/" supertag-data-directory))
         (supertag-sync-directories (list tmp))
         (supertag-active-sync-directory tmp)
         (supertag--store nil)
         (supertag--store-origin nil)
         (supertag--subscribers (make-hash-table :test 'equal))
         (supertag-sync--state (list :sync-state (make-hash-table :test 'equal)))
         (supertag-sync--state-source (expand-file-name "sync-state.el" tmp))
         (supertag-sync-state-file (expand-file-name "sync-state.el" tmp))
         (supertag-sync--deferred-files (make-hash-table :test 'equal))
         (supertag-sync--internal-modifications (make-hash-table :test 'equal))
         (supertag-async--queue nil)
         (org-id-locations nil)
         (org-id-locations-file (expand-file-name "ids" tmp))
         (org-id-track-globally nil)
         (make-backup-files nil)
         (auto-save-default nil))
    (unwind-protect
        (progn
          (supertag--ensure-store)
          (supertag-tag-create '(:id "ready-work" :name "ready-work"))
          (with-temp-file file
            (insert "* Ready Item #ready-work\n"
                    ":PROPERTIES:\n:ID: ready-item\n:STAGE: ready\n:END:\n"
                    "Body.\n"))
          (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
          (let ((state (supertag-view-build-node-state "ready-item")))
            (should-not (plist-member state :properties))
            (should-not (plist-member state :property-count))
            (should (equal '("ready-work") (plist-get state :tags))))
          (let ((view (supertag-view-node-open "ready-item"))
                (case-fold-search nil))
            (unwind-protect
                (with-current-buffer view
                  (should (string-match-p "READY-WORK" (buffer-string)))
                  (should-not (string-match-p "Properties" (buffer-string)))
                  (should-not (string-match-p "STAGE" (buffer-string))))
              (when (buffer-live-p view) (kill-buffer view)))))
      (when (get-buffer "*Supertag Node*") (kill-buffer "*Supertag Node*"))
      (delete-directory tmp t))))

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
            (should-not (plist-member state :properties))
            (should-not (plist-member state :property-count))
            (should (equal '("vwa-other") (plist-get state :refs-to)))
            (should (equal '("vwa-in") (plist-get state :refs-from)))
            (should (= 2 (plist-get state :ref-count)))
            (should (= 1 (length (supertag-query-named-links-from "document-node"))))
            (should (= 1 (length (supertag-query-named-links-to "document-node"))))
            ;; Only Q-detached node data is promised deeply isolated.
            (aset (plist-get (plist-get state :node) :title) 0 ?X)
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
                    (should-not (string-match-p "Properties" (buffer-string)))
                    (should-not (string-match-p "ALPHA" (buffer-string)))
                    (should (string-match-p "vwa-tag" (buffer-string)))
                    (should (string-match-p "supports" (buffer-string)))
                    (goto-char (point-min)) (search-forward "vwa-tag") (beginning-of-line)
                    (princ (format "VWA-WINDOW before point=%s start=%S\n"
                                   (point) (window-start (get-buffer-window view)))))
                  ;; A real save that does not touch tags still triggers a
                  ;; Runtime-owned refresh; the tag selection survives it.
                  (supertag-document-test-save-property file "ALPHA" "updated")
                  (supertag-document-test-drain)
                  (with-current-buffer view
                    (should (get-text-property (point) 'supertag-context))
                    (supertag-view-node-refresh)
                    (princ (format "VWA-WINDOW after point=%s start=%S\n"
                                   (point) (window-start (get-buffer-window view)))))
                  (supertag-view-node-open "document-node")
                  (should (= (1+ baseline) (length (gethash :store-changed supertag--subscribers))))
                  (princ "VWA-REAL-OUTPUT refs=2 title=Property Node\n")
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

(ert-deftest supertag-node-view-magazine-omits-empty-reference-chip ()
  "A Node View does not render an empty References section."
  (with-temp-buffer
    (supertag-view-node-mode)
    (cl-letf (((symbol-function 'supertag-view-reference-insert-sections) #'ignore)
              ((symbol-function 'supertag-ai-insert-section) #'ignore)
              ((symbol-function 'supertag-semantic-insert-section) #'ignore)
              ((symbol-function 'supertag-view-node--insert-named-links-section) #'ignore)
              ((symbol-function 'supertag-concept-node-p) (lambda (_node) nil)))
      (supertag-view-node--render-from-state
       '(:id "abcdef012345" :node (:id "abcdef012345" :title "Heading" :file "/tmp/heading.org")
         :tags nil)))
    (should-not (string-match-p "REFERENCES /" (buffer-string)))
    (should (string-match-p "SUPERTAG / NODE  /  ABCDEF01" (buffer-string)))))

(ert-deftest supertag-node-view-magazine-masthead-tag-keeps-context-property ()
  "A masthead chip remains a selectable Tag context."
  (with-temp-buffer
    (supertag-view-node-mode)
    (cl-letf (((symbol-function 'supertag-view-reference-insert-sections) #'ignore)
              ((symbol-function 'supertag-ai-insert-section) #'ignore)
              ((symbol-function 'supertag-semantic-insert-section) #'ignore)
              ((symbol-function 'supertag-view-node--insert-named-links-section) #'ignore)
              ((symbol-function 'supertag-concept-node-p) (lambda (_node) nil)))
      (supertag-view-node--render-from-state
       '(:id "abcdef012345" :node (:id "abcdef012345" :title "Heading") :tags ("project"))))
    (goto-char (point-min))
    (search-forward " PROJECT ")
    (let ((position (match-beginning 0)))
      (should (get-text-property position 'supertag-context))
      (should (eq (get-text-property position 'type) :tag))
      (should (equal (get-text-property position 'tag-id) "project")))))

(ert-deftest supertag-node-view-magazine-tab-folds-chip-section ()
  "TAB creates an invisible fold overlay for a chip section."
  (with-temp-buffer
    (supertag-view-node-mode)
    (cl-letf (((symbol-function 'supertag-view-reference-insert-sections)
               (lambda (_node-id)
                 (insert "\n")
                 (supertag-view-helper-insert-section-chip "References" 1 'supertag-view-chip1)
                 (insert "  Entry\n      Excerpt\n")))
              ((symbol-function 'supertag-ai-insert-section) #'ignore)
              ((symbol-function 'supertag-semantic-insert-section) #'ignore)
              ((symbol-function 'supertag-view-node--insert-named-links-section) #'ignore)
              ((symbol-function 'supertag-concept-node-p) (lambda (_node) nil)))
      (supertag-view-node--render-from-state
       '(:id "abcdef012345" :node (:id "abcdef012345" :title "Heading") :tags nil)))
    (goto-char (point-min))
    (search-forward " REFERENCES / 01 ")
    (beginning-of-line)
    (supertag-view-node-toggle-section)
    (let ((fold (seq-find (lambda (overlay)
                            (overlay-get overlay 'supertag-view-node-fold))
                          (overlays-in (point-min) (point-max)))))
      (should fold)
      (should (overlay-get fold 'invisible))
      (should (equal (substring-no-properties (overlay-get fold 'after-string)) "  …")))))
