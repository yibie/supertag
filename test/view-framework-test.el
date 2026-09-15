;;; view-framework-test.el --- Tests for supertag-view-framework -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the view framework registration and rendering system.

;;; Code:

(require 'ert)

;; Load the module under test
(when load-file-name
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))
(require 'supertag-view-framework)
(when (equal (getenv "SUPERTAG_VWD_STAGE") "before") (require 'supertag-view-helper))
(require 'supertag-tag)
(require 'supertag-view-stream)
(require 'supertag-view-node)
(require 'supertag-discovery)
(require 'supertag-core-store)
(require 'supertag-tag)

;; Setup and teardown
(defun view-framework-test--setup ()
  "Initialize clean view framework for testing."
  (clrhash supertag--view-registry))

(ert-deftest supertag-view-framework-retired-commands-are-unbound ()
  (dolist (name '(supertag-view-framework-init supertag-view-dsl-example
                  supertag-view-config-save-to-store supertag-view-list-interactive
                  supertag-view-select-and-render supertag-view-select-from-schema
                  supertag-view-style-refresh supertag-view-style-toggle
                  supertag-view-widget-mode supertag-view-widget-forward
                  supertag-view-widget-backward))
    (should-not (fboundp name)))
  (should (commandp #'supertag-view-refresh))
  (should (commandp #'supertag-view-style-mode)))

(ert-deftest supertag-view-framework-live-refresh-consumers-are-present ()
  "Keep the retained Stream, Node and Discovery refresh consumers live."
  (dolist (command '(supertag-view-refresh
                     supertag-view-stream
                     supertag-view-node-refresh
                     supertag-discovery-refresh))
    (should (fboundp command)))
  (should (memq #'supertag-view-helper--auto-enable org-mode-hook)))

(ert-deftest supertag-view-framework-config-only-tags-are-isolated ()
  "Configuration entries remain queryable without creating a runtime view."
  (view-framework-test--setup)
  (let ((config (supertag-view-config-register
                 '(:id config-only :name "Config only" :valid-for ("tag-only")))))
    (should (equal config (supertag-view-config-get 'config-only)))
    (should (equal (list config) (supertag-view-config-list)))
    (should-not (gethash 'missing-config supertag--view-configs))))

(ert-deftest supertag-view-framework-stream-g-refreshes-new-node ()
  "The retained Stream `g' command renders a node added after opening."
  (let ((supertag--store nil)
        (supertag--subscribers (make-hash-table :test 'equal)))
    (supertag--ensure-store)
    (supertag-store-put-entity :tags "T" '(:id "T" :name "T" :type :tag))
    (supertag-store-put-entity :nodes "N1"
                               '(:id "N1" :type :node :title "Node One"
                                 :tags ("T") :content "one"))
    (supertag-view-stream--register-view)
    (let ((buffer (supertag-view-stream "T")))
      (unwind-protect
          (progn
            (should (with-current-buffer buffer
                      (string-match-p "Node One" (buffer-string))))
            (supertag-store-put-entity
             :nodes "N2"
             '(:id "N2" :type :node :title "Node Two"
               :tags ("T") :content "two"))
            (with-current-buffer buffer
              (call-interactively (key-binding (kbd "g")))
              (should (string-match-p "Node Two" (buffer-string)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest supertag-view-framework-stream-interactive-entrypoint ()
  "The interactive Stream entrypoint resolves a tag through the real reader."
  (let ((supertag--store nil)
        (supertag--subscribers (make-hash-table :test 'equal)))
    (supertag--ensure-store)
    (supertag-store-put-entity :tags "T" '(:id "T" :name "T" :type :tag))
    (supertag-store-put-entity :nodes "N1"
                               '(:id "N1" :type :node :title "Node One"
                                 :tags ("T") :content "one"))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "T")))
      (let ((buffer (call-interactively #'supertag-view-stream)))
        (unwind-protect
            (progn
              (should (with-current-buffer buffer
                        (string-match-p "Node One" (buffer-string)))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest supertag-view-framework-node-refreshes-changed-title ()
  "Node View refresh reads the changed title from the live Store."
  (let ((supertag--store nil)
        (supertag--subscribers (make-hash-table :test 'equal)))
    (supertag--ensure-store)
    (supertag-store-put-entity :nodes "N1"
                               '(:id "N1" :type :node :title "Before"
                                 :tags nil :content "body"))
    (let ((buffer (supertag-view-node-open "N1")))
      (unwind-protect
          (progn
            (supertag-store-put-entity
             :nodes "N1"
             '(:id "N1" :type :node :title "After"
               :tags nil :content "body"))
            (with-current-buffer buffer
              (supertag-view-node-refresh)
              (should (string-match-p "After" (buffer-string)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest supertag-view-framework-discovery-refreshes-new-node ()
  "Discovery refresh renders a node added after the initial sample."
  (let ((supertag--store nil)
        (supertag--subscribers (make-hash-table :test 'equal)))
    (supertag--ensure-store)
    (supertag-store-put-entity :nodes "D1"
                               '(:id "D1" :type :node :title "Discovery One"
                                 :tags nil :content "one"))
    (let ((buffer (supertag-discovery)))
      (unwind-protect
          (progn
            (supertag-store-put-entity
             :nodes "D2"
             '(:id "D2" :type :node :title "Discovery Two"
               :tags nil :content "two"))
            (with-current-buffer buffer
              (supertag-discovery-refresh)
              (should (string-match-p "Discovery Two" (buffer-string)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest supertag-view-framework-org-hook-auto-enable-contract ()
  "Opening an Org buffer enables style mode only when opted in."
  (let ((supertag-view-style-auto-enable t))
    (with-temp-buffer
      (org-mode)
      (should supertag-view-style-mode)))
  (let ((supertag-view-style-auto-enable nil))
    (with-temp-buffer
      (org-mode)
      (should-not supertag-view-style-mode))))

(ert-deftest supertag-view-framework-config-only-tag-orphan-lifecycle ()
  "A config-only tag is referenced only while its config is registered."
  (let ((supertag--store nil)
        (supertag--subscribers (make-hash-table :test 'equal)))
    (supertag--ensure-store)
    (supertag-store-put-entity :tags "T2" '(:id "T2" :name "T2" :type :tag))
    (clrhash supertag--view-configs)
    (should (member "T2" (supertag-tag-orphaned-ids)))
    (supertag-view-config-register
     '(:id config-t2 :name "T2 config" :valid-for ("T2")))
    (should-not (member "T2" (supertag-tag-orphaned-ids)))
    (clrhash supertag--view-configs)
    (should (member "T2" (supertag-tag-orphaned-ids)))))

;; Tests for registration
(ert-deftest test-view-register-basic ()
  "Test basic view registration."
  (view-framework-test--setup)
  (let ((view (supertag-view-register
               :id 'test-view
               :name "Test View"
               :render-fn #'ignore)))
    (should view)
    (should (eq (plist-get view :id) 'test-view))
    (should (string= (plist-get view :name) "Test View"))
    (should (functionp (plist-get view :render-fn)))))

(ert-deftest test-view-register-with-optional-props ()
  "Test registration with optional properties."
  (view-framework-test--setup)
  (let ((view (supertag-view-register
               :id 'full-view
               :name "Full View"
               :description "A test view with all properties"
               :category :test
               :render-fn #'ignore
               :valid-for '("project" "task"))))
    (should (string= (plist-get view :description) "A test view with all properties"))
    (should (eq (plist-get view :category) :test))
    (should (equal (plist-get view :valid-for) '("project" "task")))))

(ert-deftest test-view-register-error-no-id ()
  "Test that registration fails without :id."
  (view-framework-test--setup)
  (should-error (supertag-view-register
                 :name "No ID View"
                 :render-fn #'ignore)))

(ert-deftest test-view-register-error-no-name ()
  "Test that registration fails without :name."
  (view-framework-test--setup)
  (should-error (supertag-view-register
                 :id 'no-name-view
                 :render-fn #'ignore)))

(ert-deftest test-view-register-error-no-render-fn ()
  "Test that registration fails without :render-fn."
  (view-framework-test--setup)
  (should-error (supertag-view-register
                 :id 'no-render-view
                 :name "No Render View")))

;; Tests for unregistration
(ert-deftest test-view-unregister ()
  "Test view unregistration."
  (view-framework-test--setup)
  (supertag-view-register
   :id 'to-remove
   :name "To Remove"
   :render-fn #'ignore)
  (should (supertag-view-get 'to-remove))
  (let ((removed (supertag-view-unregister 'to-remove)))
    (should removed)
    (should (eq (plist-get removed :id) 'to-remove))
    (should-not (supertag-view-get 'to-remove))))

;; Tests for listing



(ert-deftest test-view-header ()
  "Test header insertion."
  (with-temp-buffer
    (supertag-view--header "Test Header")
    (should (string-match-p "Test Header" (buffer-string)))
    (should (string-match-p "===========" (buffer-string)))))

(ert-deftest test-view-progress-bar ()
  "Test progress bar insertion."
  (with-temp-buffer
    (supertag-view--progress-bar 50 10)
    (let ((content (buffer-string)))
      (should (string-match-p "\\[" content))
      (should (string-match-p "\\]" content))
      (should (string-match-p "50%" content)))))

(ert-deftest test-widget-progress-bar-preserves-integer-ratios ()
  "Widget progress values must not be truncated by integer division."
  (with-temp-buffer
    (supertag-widget-render 'progress-bar '(:value 41 :max 100 :width 10))
    (should (string-match-p "41%" (buffer-string)))))

(ert-deftest test-view-stat-row ()
  "Test stat row insertion."
  (with-temp-buffer
    (supertag-view--stat-row '(("Total" . 100) ("Done" . 80)))
    (let ((content (buffer-string)))
      (should (string-match-p "Total: 100" content))
      (should (string-match-p "Done: 80" content)))))

(ert-deftest test-view-style-enables-existing-org-buffers ()
  "Late loading must enable styling in Org buffers that already exist."
  (let ((org-buffer (generate-new-buffer " *supertag-existing-org*"))
        (text-buffer (generate-new-buffer " *supertag-existing-text*"))
        (supertag-view-style-auto-enable t))
    (unwind-protect
        (progn
          (with-current-buffer org-buffer
            (org-mode)
            (supertag-view-style-mode -1))
          (with-current-buffer text-buffer
            (text-mode))
          (let ((supertag-view-style-auto-enable nil))
            (supertag-view-helper--enable-existing-org-buffers))
          (with-current-buffer org-buffer
            (should-not supertag-view-style-mode))
          (supertag-view-helper--enable-existing-org-buffers)
          (with-current-buffer org-buffer
            (should supertag-view-style-mode)
            (insert "plain #tag")
            (cl-letf (((symbol-function 'display-graphic-p)
                       (lambda (&optional _frame) t))
                      ((symbol-function 'supertag-svg-tag--get-cached)
                       (lambda (_tag) '(image :type svg :data "dummy"))))
              (supertag-svg-tag--refresh-all-buffers)
              (font-lock-ensure))
            (goto-char (point-min))
            (search-forward "#")
            (should (get-text-property (1- (point)) 'display)))
          (with-current-buffer text-buffer
            (should-not supertag-view-style-mode)))
      (kill-buffer org-buffer)
      (kill-buffer text-buffer))))

(ert-deftest test-view-style-face-stops-before-adjacent-org-link ()
  "Face font-lock must style only the range-aware Tag token."
  (let ((supertag-view-style-auto-enable nil)
        (supertag-svg-tag-enable nil))
    (with-temp-buffer
      (org-mode)
      (insert "* T #outer[[id:n][label]]\n")
      (supertag-view-style-mode 1)
      (font-lock-ensure)
      (goto-char (point-min))
      (search-forward "#outer")
      (let ((tag-start (- (point) (length "#outer")))
            (link-start (point))
            (label-start (progn (search-forward "label")
                                (- (point) (length "label")))))
        ;; An unregistered token renders with the unresolved face; this
        ;; test only cares that styling stops at the Org link boundary.
        (should (memq (get-text-property tag-start 'face)
                      '(supertag-inline-face supertag-unresolved-tag-face)))
        (should-not (memq (get-text-property link-start 'face)
                          '(supertag-inline-face
                            supertag-unresolved-tag-face)))
        (should-not (memq (get-text-property label-start 'face)
                          '(supertag-inline-face
                            supertag-unresolved-tag-face)))))))

(ert-deftest test-view-style-svg-stops-before-adjacent-org-link ()
  "SVG font-lock must not replace the Org link following a Tag token."
  (let ((supertag-view-style-auto-enable nil)
        (supertag-svg-tag-enable t))
    (with-temp-buffer
      (org-mode)
      (insert "* T #outer[[id:n][label]]\n")
      (cl-letf (((symbol-function 'display-graphic-p)
                 (lambda (&optional _frame) t))
                ((symbol-function 'supertag-svg-tag--get-cached)
                 (lambda (_tag) '(image :type svg :data "dummy"))))
        (supertag-view-style-mode 1)
        (font-lock-ensure))
      (goto-char (point-min))
      (search-forward "#outer")
      (let ((tag-start (- (point) (length "#outer")))
            (link-start (point))
            (label-start (progn (search-forward "label")
                                (- (point) (length "label")))))
        (should (equal (get-text-property tag-start 'display)
                       '(image :type svg :data "dummy")))
        (should-not (get-text-property link-start 'display))
        (should-not (get-text-property label-start 'display))))))

(provide 'view-framework-test)

;;; view-framework-test.el ends here

;;; D4 business selector keeps its plist and the real Stream descendant contract.
(require 'document-fixture)
(ert-deftest supertag-view-framework-tag-reader-real-path-stream-and-cancel ()
  (supertag-document-test-with-vault
    ;; Hierarchy is the explicit `:extends' relation; names stay flat.
    (dolist (spec '(("stable-parent" "topic" nil) ("stable-child" "child" "stable-parent")
                    ("stable-grand" "grand" "stable-child") ("stable-leaf" "solo" nil)))
      (supertag-tag-create (append (list :id (nth 0 spec) :name (nth 1 spec))
                                   (when (nth 2 spec) (list :extends (list (nth 2 spec)))))))
    (with-current-buffer (find-file-noselect file)
      (erase-buffer)
      (insert "* Parent #topic\n:PROPERTIES:\n:ID: p\n:END:\nParent body\n* Child #child\n:PROPERTIES:\n:ID: c\n:END:\nChild body\n* Grand #grand\n:PROPERTIES:\n:ID: g\n:END:\nGrand body\n* Leaf #solo\n:PROPERTIES:\n:ID: l\n:END:\nLeaf body\n")
      (save-buffer))
    (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
    (let ((facts (prin1-to-string supertag--store))
          (disk (supertag-document-test-disk file))
          (text (with-current-buffer (find-file-noselect file) (buffer-string))))
      (dolist (pair '(("topic" :type :tag :value "stable-parent" :include-descendants t)
                      ("solo" :type :tag :value "stable-leaf")))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt table &rest _)
                     (or (cl-find (car pair) (all-completions "" table) :test #'equal)
                         (ert-fail "Missing canonical candidate")))))
          (should (equal (cdr pair) (supertag-view--read-tag)))))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "topic")))
        (let ((buffer (call-interactively #'supertag-view-stream)))
          (unwind-protect
              (progn
                (should (equal '("c" "g" "p") (sort (copy-sequence (supertag-view-stream--node-ids buffer)) #'string<)))
                (with-current-buffer buffer
                  (dolist (title '("Parent" "Child" "Grand")) (should (string-match-p title (buffer-string))))))
            (when (buffer-live-p buffer) (kill-buffer buffer)))))
      ;; Empty/unknown answers are not silently promoted into semantic entities.
      (dolist (answer '("" "virtual"))
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) answer)))
          (should-error (supertag-view--read-tag) :type 'user-error)))
      (should (equal facts (prin1-to-string supertag--store)))
      (should (equal disk (supertag-document-test-disk file)))
      (with-current-buffer (find-file-noselect file)
        (should (equal text (buffer-string))) (should-not (buffer-modified-p))))))

;;; VWB independent owner, notifier, and consumer controls.
(defconst supertag-view-framework-vwb--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(defun supertag-view-framework-vwb--child (name body)
  "Run BODY in a genuinely fresh, isolated source process; retain evidence."
  (let* ((tmp (make-temp-file "supertag-vwb-" t))
         (script (expand-file-name "child.el" tmp))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (root supertag-view-framework-vwb--root)
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
                  (let ((vwb-root ,root) (vwb-tmp ,tmp)
                        (before (equal (getenv "SUPERTAG_VWB_STAGE") "before")))
                    ,body)
                  (princ ,(concat "VWB-" name "-DONE\n")))
              (setq kill-emacs-hook nil emacs-startup-hook nil org-mode-hook nil
                    enable-theme-functions nil)
              (mapc #'cancel-timer (append timer-list timer-idle-list)))
          (error (princ (format "VWB-ERROR %S\n" err)) (kill-emacs 1)))
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
                 (output (buffer-string)) (evidence (getenv "SUPERTAG_VWB_EVIDENCE")))
            (when evidence
              (make-directory evidence t)
              (copy-file script (expand-file-name (concat name ".el") evidence) t)
              (with-temp-file (expand-file-name (concat name ".log") evidence) (insert output))
              (with-temp-file (expand-file-name (concat name ".exit") evidence) (prin1 exit (current-buffer))))
            (princ output)
            (should (equal exit 0))
            (should (string-match-p (concat "VWB-" name "-DONE") output))))
      (delete-directory tmp t))))

(ert-deftest supertag-view-framework-vwb-cold-api-contract ()
  (supertag-view-framework-vwb--child
   "api" '(progn
     (should-not (featurep 'document-fixture))
     (should-not (featurep 'supertag-services-sync))
     (require (if before 'supertag-view-api 'supertag-view-framework))
     (princ "VWB-ENTRY-api\n")
     (should (eq (featurep 'supertag-view-framework) (not before)))
     (dolist (symbol '(supertag-view-api-node-base-field supertag-view-api-subscribe))
       (should (equal (file-name-nondirectory (symbol-file symbol 'defun))
                      (if before "supertag-view-api.el" "supertag-view-framework.el"))))
     (should (eq (featurep 'supertag-view-api) before))
     (unless before
       (should-not (file-exists-p (expand-file-name "supertag-view-api.el" vwb-root)))
       (should-not (cl-find-if (lambda (row) (and (stringp (car row))
                                  (string-suffix-p "/supertag-view-api.el" (car row)))) load-history)))
     (let* ((items (list "one" "two")) (node (list :title "Title" :nil nil :items items)))
       (should-not (supertag-view-api-node-base-field node :missing))
       (should-not (supertag-view-api-node-base-field node :nil))
       (should (equal (supertag-view-api-node-base-field node :title) "Title"))
       (should (eq (supertag-view-api-node-base-field node :items) items))
       (setcar (supertag-view-api-node-base-field node :items) "changed")
       (should (equal (plist-get node :items) '("changed" "two")))))))

(ert-deftest supertag-view-framework-vwb-owner-after-entry ()
  (supertag-view-framework-vwb--child
   "owner" '(progn
     (should-not (featurep 'supertag-services-sync))
     (require 'supertag-view-framework)
     (princ "VWB-ENTRY-owner\n")
     (dolist (symbol '(supertag-view-api-node-base-field supertag-view-api-subscribe))
       (should (equal (file-name-nondirectory (symbol-file symbol 'defun))
                      (if (and before (not (getenv "SUPERTAG_VWB_OWNER_CURRENT")))
                          "supertag-view-api.el" "supertag-view-framework.el")))))))

(ert-deftest supertag-view-framework-vwb-real-notifier ()
  (supertag-view-framework-vwb--child
   "notifier" '(progn
     (require (if before 'supertag-view-api 'supertag-view-framework))
     (let ((supertag--subscribers (make-hash-table :test 'equal)) (seen nil))
       (should-error (supertag-view-api-subscribe :vwb 42))
       (should (= 0 (hash-table-count supertag--subscribers)))
       (dolist (topic '(:vwb (:nodes "N" :title)))
         (setq seen nil)
         (let* ((a (lambda (&rest args) (push (cons 'a args) seen)))
                (b (lambda (&rest args) (push (cons 'b args) seen)))
                (ua (supertag-view-api-subscribe topic a))
                (ub (supertag-view-api-subscribe topic b)))
           (supertag-emit-event topic "old" "new")
           (princ (format "VWB-CALLBACK %S %S\n" topic (reverse seen)))
           (should (equal (reverse seen) '((b "old" "new") (a "old" "new"))))
           (should (equal (funcall ua) (list b)))
           (should (equal (funcall ua) (list b)))
           (setq seen nil)
           (supertag-emit-event topic 1 2 3)
           (should (equal seen '((b 1 2 3))))
           (should-not (funcall ub))
           (should-not (funcall ub))
           (setq seen nil) (supertag-emit-event topic :ignored)
           (should-not seen)))))))

(ert-deftest supertag-view-framework-vwb-reload-and-listener-seam ()
  (supertag-view-framework-vwb--child
   "reload" '(progn
     (require (if before 'supertag-view-api 'supertag-view-framework))
     (require 'supertag-view-framework)
     (let* ((registry supertag--view-registry) (configs supertag--view-configs)
            (subscribers supertag--subscribers)
            (node-read (symbol-function 'supertag-view-api-node-base-field))
            (view (supertag-view-register :id 'vwb :name "VWB" :render-fn #'ignore))
            (config (supertag-view-config-register '(:id vwb :name "VWB")))
            (called 0) (off (supertag-view-api-subscribe :vwb (lambda (&rest _) (cl-incf called)))))
       (require 'supertag-view-framework)
       (should (eq node-read (symbol-function 'supertag-view-api-node-base-field)))
       (dotimes (_ 2) (load (expand-file-name "supertag-view-framework.el" vwb-root) nil nil t))
       (should (eq registry supertag--view-registry))
       (should (eq configs supertag--view-configs))
       (should (eq subscribers supertag--subscribers))
       (should (eq view (supertag-view-get 'vwb)))
       (should (eq config (supertag-view-config-get 'vwb)))
       (supertag-emit-event :vwb) (should (= called 1)) (funcall off)
       (require 'supertag-view-node) (require 'supertag-view-stream)
       (supertag-view-node--register-view)
       (should (functionp (plist-get (supertag-view-get 'node) :render-fn)))
       (should (functionp (plist-get (supertag-view-get 'stream) :render-fn)))
       (princ (format "VWB-RELOAD same-function=%S\n"
                      (eq node-read (symbol-function 'supertag-view-api-node-base-field)))))
     ;; This conditional availability seam is not the native notifier API.
     (should-not (fboundp 'supertag-register-listener))
     (let (calls)
       (cl-letf (((symbol-function 'supertag-register-listener)
                  (lambda (&rest args) (push args calls))))
         (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener t)))
       (should (equal calls (list (list :store-changed #'supertag-ui--invalidate-cache-on-change))))))))

(ert-deftest supertag-view-framework-vwb-helper-cold-read-and-render ()
  (supertag-view-framework-vwb--child
   "helper" '(progn
     (should-not (featurep 'supertag-view-helper))
     (require 'supertag-tag)
     (should-not (featurep 'supertag-view-helper))
     (let ((text (supertag-view-helper-format-tag-value nil)))
       (should (equal (substring-no-properties text) "[No tags]"))
       (should (eq (get-text-property 0 'face text) 'supertag-view-mute)))
     (if (or before (equal (getenv "SUPERTAG_VWC_STAGE") "before"))
         (should (featurep 'supertag-view-helper))
       (should (featurep 'supertag-view-framework))
       (should-not (featurep 'supertag-view-helper)))
     (should (featurep 'supertag-node)) (should (featurep 'supertag-query))
     (should (eq (featurep 'supertag-view-api) before))
     ;; The retained locator fixture is a separate phase after first-color costs.
     (unless (or before (equal (getenv "SUPERTAG_VWC_STAGE") "before"))
       (require (if (equal (getenv "SUPERTAG_VWD_STAGE") "before") 'supertag-view-helper 'supertag-node)))
     (let ((supertag--store nil) (file (expand-file-name "source.org" vwb-tmp)))
       (with-temp-file file (insert "* Existing\n"))
       (supertag--ensure-store)
       (supertag-store-put-entity :nodes "N" (list :id "N" :file file :position 7))
       (should (equal (supertag-view-helper-find-node-location "N") (cons 7 file)))
       (should-not (supertag-view-helper-find-node-location "missing")))
     (let ((text (supertag-view-helper-render-org-links "See [[id:N][Label]]!")))
       (should (equal (substring-no-properties text) "See Label!"))
       (should (keymapp (get-text-property 4 'keymap text)))))))

(ert-deftest supertag-view-framework-vwb-link-first-helper-render ()
  (supertag-view-framework-vwb--child
   "link" '(progn
     (require 'supertag-link)
     (should-not (featurep 'supertag-view-helper))
     (with-temp-buffer
       (supertag--ensure-store)
       (supertag-view-reference-insert-outgoing-section "missing")
       (princ (format "VWB-LINK-RENDER %S\n" (buffer-string)))
       (should (string-empty-p (buffer-string))))
     (should-not (featurep 'supertag-view-framework))
     (should (eq (featurep 'supertag-view-api) before)))))

(ert-deftest supertag-view-framework-vwb-live-view-subscriptions ()
  (supertag-view-framework-vwb--child
   "views" '(progn
     (require 'supertag-view-framework)
     (princ "VWB-ENTRY-views\n")
     ;; Fixture is loaded only after the genuinely cold Framework entry.
     (require 'document-fixture)
     (require 'supertag-view-node) (require 'supertag-view-stream)
     (supertag-document-test-with-vault
       (supertag-store-put-entity :tags "T" '(:id "T" :name "T" :type :tag))
       (let* ((node (supertag-node-get "document-node"))
              (baseline (length (gethash :store-changed supertag--subscribers)))
              (nv nil) (stream nil))
         (supertag-store-put-entity :nodes "document-node" (plist-put node :tags '("T")))
         (unwind-protect
             (progn
               (setq nv (supertag-view-node-open "document-node") stream (supertag-view-stream "T"))
               (should (= (length (gethash :store-changed supertag--subscribers)) (+ baseline 2)))
               (with-current-buffer nv
                 (let ((pos (point-min)) found)
                   (while (and (< pos (point-max)) (not found))
                     (if (equal (get-text-property pos 'id) "T")
                         (setq found pos)
                       (setq pos (or (next-single-property-change pos 'id nil (point-max))
                                     (point-max)))))
                   (should (goto-char found))))
               (let ((stream-session (buffer-local-value 'supertag-view-stream--origin-window-configuration stream)))
                 (supertag-store-put-entity :nodes "document-node"
                                           (plist-put (copy-tree (supertag-node-get "document-node")) :title "VWB changed") t)
                 (dolist (view (list nv stream))
                   (should (with-current-buffer view (string-match-p "VWB changed" (buffer-string)))))
                 (should (eq stream-session (buffer-local-value 'supertag-view-stream--origin-window-configuration stream))))
               (with-current-buffer nv
                 (should (equal (plist-get (supertag-view-node--capture-selection) :id) "T")))
               (kill-buffer nv) (setq nv nil)
               (kill-buffer stream) (setq stream nil)
               (should (= baseline (length (gethash :store-changed supertag--subscribers)))))
           (dolist (view (list nv stream)) (when (buffer-live-p view) (kill-buffer view)))))))))

;;; VWC independent drawing contracts, separate from VWB history.
(defconst supertag-view-framework-vwc--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(defun supertag-view-framework-vwc--child (name body)
  "Run BODY in a genuinely fresh, isolated source process; retain evidence."
  (let* ((tmp (make-temp-file "supertag-vwc-" t))
         (script (expand-file-name "child.el" tmp))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (root supertag-view-framework-vwc--root)
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
                  (let ((vwc-root ,root) (vwc-tmp ,tmp)
                        (before (equal (getenv "SUPERTAG_VWC_STAGE") "before")))
                    ,body)
                  (princ ,(concat "VWC-" name "-DONE\n")))
              (setq kill-emacs-hook nil emacs-startup-hook nil org-mode-hook nil
                    enable-theme-functions nil)
              (mapc #'cancel-timer (append timer-list timer-idle-list)))
          (error (princ (format "VWC-ERROR %S\n" err)) (kill-emacs 1)))
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
                 (output (buffer-string)) (evidence (getenv "SUPERTAG_VWC_EVIDENCE")))
            (when evidence
              (make-directory evidence t)
              (copy-file script (expand-file-name (concat name ".el") evidence) t)
              (with-temp-file (expand-file-name (concat name ".log") evidence) (insert output))
              (with-temp-file (expand-file-name (concat name ".exit") evidence) (prin1 exit (current-buffer))))
            (princ output)
            (should (equal exit 0))
            (should (string-match-p (concat "VWC-" name "-DONE") output))))
      (delete-directory tmp t))))


(defconst supertag-view-framework-vwc--drawing-symbols
  '((supertag-view-apply-palette defun)
    (supertag-view-helper-insert-action-button defun)
    (supertag-view-helper-insert-section-chip defun)
    (supertag-view-helper-insert-excerpt defun)
    (supertag-view-helper-format-value defun)
    (supertag-view-helper-render-org-links defun)
    (supertag-view-helper-format-boolean-value defun)
    (supertag-view-helper-format-number-value defun)
    (supertag-view-helper-format-date-value defun)
    (supertag-view-helper-format-url-value defun)
    (supertag-view-helper-insert-simple-empty-state defun)
    (supertag-view-helper-highlight-current-line defun)
    (supertag-view-helper-unhighlight-all-lines defun)
    (supertag-view-helper-enable-line-highlighting defun)
    (supertag-view-helper-insert-status-badge defun)
    (supertag-view-helper-insert-stats-summary defun)
    (supertag-view-helper-insert-help-text defun)
    (supertag-view-helper-insert-empty-state defun)
    (supertag-view-helper-insert-node-info defun)
    (supertag-view-helper-display-buffer-right defun)))


(ert-deftest supertag-view-framework-vwc-entry-owner-and-retained-helper ()
  (supertag-view-framework-vwc--child
   "owner"
   `(progn
      (should-not (featurep 'document-fixture))
      (should-not (featurep 'supertag-services-sync))
      (should-not (featurep 'supertag-view-helper))
      (should-not (featurep 'supertag-view-framework))
      (require (if before 'supertag-view-helper 'supertag-view-framework))
      (princ "VWC-ENTRY-owner\n")
      (dolist (pair ',supertag-view-framework-vwc--drawing-symbols)
        (should (equal (file-name-nondirectory (symbol-file (car pair) (cadr pair)))
                       (if (and before (not (getenv "SUPERTAG_VWC_EXPECT_FRAMEWORK")))
                           "supertag-view-helper.el" "supertag-view-framework.el"))))
      (let ((fn (symbol-function 'supertag-view-helper-insert-action-button))
            (palette supertag-view-palette))
        (require (if before 'supertag-view-helper 'supertag-view-framework))
        (should (eq fn (symbol-function 'supertag-view-helper-insert-action-button)))
        (should (eq palette supertag-view-palette)))
      (if (equal (getenv "SUPERTAG_VWD_STAGE") "before")
          (progn
            (load (expand-file-name "supertag-view-helper.el" vwc-root) nil nil t)
            (should (featurep 'supertag-view-helper)))
        (should-not (featurep 'supertag-view-helper))
        (should-not (file-exists-p (expand-file-name "supertag-view-helper.el" vwc-root)))
        (require 'supertag-node))
      (should (equal (file-name-nondirectory (symbol-file 'supertag-view-helper-find-node-location 'defun))
                     (if (equal (getenv "SUPERTAG_VWD_STAGE") "before") "supertag-view-helper.el" "supertag-node.el")))
      (dolist (pair ',supertag-view-framework-vwc--drawing-symbols)
        (should (equal (file-name-nondirectory (symbol-file (car pair) (cadr pair)))
                       (if before "supertag-view-helper.el" "supertag-view-framework.el")))))))

(ert-deftest supertag-view-framework-vwc-helper-only-capability ()
  (supertag-view-framework-vwc--child
   "helper-only" '(progn
     (require (if (equal (getenv "SUPERTAG_VWD_STAGE") "before") 'supertag-view-helper 'supertag-node))
     (should-not (featurep 'supertag-view-framework))
     (should (eq (fboundp 'supertag-view-helper-insert-action-button) before))
     (should (featurep 'supertag-node))
     (if (equal (getenv "SUPERTAG_VWD_STAGE") "before")
         (should (featurep 'supertag-query))
       (should-not (featurep 'supertag-query))
       (should-not (featurep 'supertag-tag))
       (should-not (featurep 'supertag-view-helper))
       (should (autoloadp (symbol-function 'supertag-view-api-get-entity)))
       (princ "VWD-LOCATOR-BEFORE-QUERY\n"))
     (let ((file (expand-file-name "node.org" vwc-tmp)))
       (with-temp-file file (insert "* Target\n:PROPERTIES:\n:ID: vwc\n:END:\n"))
       (supertag--ensure-store)
       (supertag-store-put-entity :nodes "vwc" (list :id "vwc" :file file))
       (let ((facts (prin1-to-string supertag--store))
             (disk (with-temp-buffer (insert-file-contents file) (buffer-string))))
         (should (equal (supertag-view-helper-find-node-location "vwc") (cons 1 file)))
         (unless (equal (getenv "SUPERTAG_VWD_STAGE") "before")
           (should (featurep 'supertag-query))
           (should-not (autoloadp (symbol-function 'supertag-view-api-get-entity)))
           (should (equal (file-name-nondirectory (symbol-file 'supertag-view-api-get-entity 'defun))
                          "supertag-query.el")))
         (should-not (supertag-view-helper-find-node-location nil))
         (should-not (supertag-view-helper-find-node-location "absent"))
         (should (equal facts (prin1-to-string supertag--store)))
         (should (equal disk (with-temp-buffer (insert-file-contents file) (buffer-string)))))
       (delete-file file)
       (should-not (supertag-view-helper-find-node-location "vwc"))))))

(ert-deftest supertag-view-framework-vwc-button-and-format-output ()
  (supertag-view-framework-vwc--child
   "button" '(progn
     (require (if before 'supertag-view-helper 'supertag-view-framework))
     (let ((data (list :node "N")) seen)
       (with-temp-buffer
         (supertag-view-helper-insert-action-button
          "Execute" (lambda (b) (push (button-get b 'supertag-action) seen)) data "Run action")
         (let ((b (button-at (point-min))))
           (should b) (should (eq (button-get b 'supertag-action) data))
           (should (equal (button-get b 'help-echo) "Run action"))
           (should (button-get b 'follow-link))
           (should (eq (button-get b 'face) 'widget-button))
           (button-activate b)
           (should (equal seen '((:node "N")))))
         (should (equal (buffer-string) "Execute"))))
     (should (facep 'supertag-view-panel))
     (should (facep 'supertag-view-chip1))
     (should (facep 'supertag-view-rule))
     (supertag-view-apply-palette 'paper)
     (let ((paper (face-background 'supertag-view-chip1 nil t)))
       (supertag-view-apply-palette 'neon)
       (should-not (equal paper (face-background 'supertag-view-chip1 nil t))))
     (should-error (supertag-view-apply-palette 'missing) :type 'user-error)
     (should (equal (substring-no-properties (supertag-view-helper-format-value nil)) "[Empty]")))))

(ert-deftest supertag-view-framework-vwc-components-overlays-and-window ()
  (supertag-view-framework-vwc--child
   "components" '(progn
     (require (if before 'supertag-view-helper 'supertag-view-framework))
     (with-temp-buffer
       (setq-local fill-column 72)
       (supertag-view-helper-insert-section-chip "References" 2 'supertag-view-chip1)
       (should (equal (buffer-string)
                      (concat "\n\n REFERENCES / 02 " (make-string 54 ?\s) "\n")))
       (goto-char (point-min))
       (forward-line 2)
       (should (get-text-property (point) 'supertag-view-section)))
     (with-temp-buffer
       (supertag-view-helper-insert-excerpt nil)
       (supertag-view-helper-insert-excerpt "  \n\t ")
       (should (string-empty-p (buffer-string)))
       (supertag-view-helper-insert-excerpt
        (concat " first\n second " (make-string 240 ?x)))
       (should (string-prefix-p "      first second " (buffer-string)))
       (should (string-suffix-p "…\n" (buffer-string)))
       (should (eq (get-text-property (point-min) 'face) 'supertag-view-excerpt))
       (should (= (count-lines (point-min) (point-max)) 2))
       (dolist (line (split-string (buffer-string) "\n" t))
         (should (string-prefix-p "      " line))
         (should (<= (string-width line) fill-column))))
     (with-temp-buffer
       (insert "one\ntwo\n") (goto-char (point-min))
       (supertag-view-helper-highlight-current-line)
       (let ((ov (car (overlays-in (point-min) (point-max)))))
         (should (= (overlay-start ov) 1))
         (should (eq (overlay-get ov 'face) 'supertag-view-panel)))
       (supertag-view-helper-unhighlight-all-lines)
       (should-not (overlays-in (point-min) (point-max)))))))

(ert-deftest supertag-view-framework-vwc-org-ret-and-mouse-real-id-open ()
  (supertag-view-framework-vwc--child
   "org" '(progn
     (require (if before 'supertag-view-helper 'supertag-view-framework))
     (require 'org-id)
     (setq org-id-locations (make-hash-table :test 'equal))
     (let ((a (expand-file-name "a.org" vwc-tmp)) (b (expand-file-name "b.org" vwc-tmp)))
       (dolist (pair (list (cons "vwc-a" a) (cons "vwc-b" b)))
         (with-temp-file (cdr pair) (insert (format "* %s\n:PROPERTIES:\n:ID: %s\n:END:\nBody\n" (car pair) (car pair))))
         (puthash (car pair) (cdr pair) org-id-locations))
       (let ((text (supertag-view-helper-render-org-links "[[id:vwc-a][Alpha]] / [[id:vwc-b][Beta]]")))
         (should (equal (substring-no-properties text) "Alpha / Beta"))
         (dolist (case (list (list 0 (kbd "RET") a "vwc-a") (list 8 [mouse-1] b "vwc-b")))
           (let ((action (lookup-key (get-text-property (car case) 'keymap text) (cadr case))))
             (should (commandp action))
             (call-interactively action)
             (should (equal (file-truename (buffer-file-name)) (file-truename (nth 2 case))))
             (should (equal (org-entry-get nil "ID") (nth 3 case)))
             (should-not (buffer-modified-p))
             (princ (format "VWC-ORG-OPEN %S\n" (org-entry-get nil "ID"))))))
       (dolist (file (list a b))
         (should (with-temp-buffer (insert-file-contents file) (string-suffix-p ":END:\nBody\n" (buffer-string)))))))))

(ert-deftest supertag-view-framework-vwc-reload-preserves-state ()
  (supertag-view-framework-vwc--child
   "reload" '(progn
     (require (if before 'supertag-view-helper 'supertag-view-framework))
     (require 'supertag-view-framework)
     (let* ((registry supertag--view-registry) (configs supertag--view-configs)
            (subscribers supertag--subscribers) (seen 0)
            (palette supertag-view-palette)
            (off (supertag-view-api-subscribe :vwc (lambda (&rest _) (cl-incf seen)))))
       (supertag-view-register :id 'vwc :name "VWC" :render-fn #'ignore)
       (supertag-view-config-register '(:id vwc :name "VWC"))
       (let ((fn (symbol-function 'supertag-view-helper-insert-action-button)))
         (require (if before 'supertag-view-helper 'supertag-view-framework))
         (should (eq fn (symbol-function 'supertag-view-helper-insert-action-button))))
       (dotimes (_ 2)
         (load (expand-file-name "supertag-view-framework.el" vwc-root) nil nil t)
         (when (equal (getenv "SUPERTAG_VWD_STAGE") "before")
           (load (expand-file-name "supertag-view-helper.el" vwc-root) nil nil t)))
       (should (eq registry supertag--view-registry)) (should (eq configs supertag--view-configs))
       (should (eq subscribers supertag--subscribers))
       (should (eq palette supertag-view-palette))
       (should (supertag-view-get 'vwc)) (should (supertag-view-config-get 'vwc))
       (supertag-emit-event :vwc) (should (= seen 1)) (funcall off)
       (supertag-emit-event :vwc) (should (= seen 1))))))

(ert-deftest supertag-view-framework-vwc-tag-and-link-real-first-render ()
  (dolist (entry '(tag link))
    (supertag-view-framework-vwc--child
     (symbol-name entry)
     `(progn
        (require ',(if (eq entry 'tag) 'supertag-tag 'supertag-link))
        (should-not (featurep 'supertag-view-helper))
        (should-not (featurep 'supertag-view-framework))
        ,(if (eq entry 'tag)
             '(let ((text (supertag-view-helper-format-tag-value '("red" "blue"))))
                (should (equal (substring-no-properties text) "#red #blue"))
                (should (member 'supertag-view-accent (get-text-property 0 'face text))))
           '(let ((target (expand-file-name "target.org" vwc-tmp)))
              (with-temp-file target (insert "* Target\n:PROPERTIES:\n:ID: vwc-target\n:END:\nBody\n"))
              (supertag--ensure-store)
              ;; Explicit Store seed for a display card, not a claimed Sync projection.
              (supertag-store-put-entity :nodes "vwc-target" (list :id "vwc-target" :title "Target" :file target :position 1))
              (let ((facts (prin1-to-string supertag--store))
                    (disk (with-temp-buffer (insert-file-contents target) (buffer-string))))
                (with-temp-buffer
                  (supertag-view-reference--insert-card
                   '(:node-id "vwc-target" :title "Target" :location "target.org" :snippet "Body"))
                  (should (string-match-p "Target" (buffer-string)))
                  (should (featurep (if before 'supertag-view-helper 'supertag-view-framework)))
                  (unless before (should-not (featurep 'supertag-view-helper)))
                  (princ (format "VWC-FIRST-CARD helper=%S framework=%S\n" (featurep 'supertag-view-helper) (featurep 'supertag-view-framework)))
                  (goto-char (point-min)) (search-forward "Target")
                  (let ((button (button-at (1- (point)))))
                    (should button)
                    (button-activate button)
                    (should (equal (file-truename target) (file-truename (buffer-file-name))))
                    (should (equal "vwc-target" (org-entry-get nil "ID")))))
                (should (equal facts (prin1-to-string supertag--store)))
                (should (equal disk (with-temp-buffer (insert-file-contents target) (buffer-string)))))))
        (should (featurep (if before 'supertag-view-helper 'supertag-view-framework)))
        (princ (format "VWC-FIRST-%S helper=%S framework=%S\n" ',entry (featurep 'supertag-view-helper) (featurep 'supertag-view-framework)))))))

(ert-deftest supertag-view-framework-vwc-ai-semantic-mention-public-sections ()
  (supertag-view-framework-vwc--child
   "sections" '(progn
     (require (if before 'supertag-view-helper 'supertag-view-framework))
     (princ "VWC-ENTRY-sections\n")
     (require 'document-fixture)
     (require 'supertag-ai) (require 'supertag-semantic) (require 'supertag-mention)
     (supertag-document-test-with-vault
       (let ((target (expand-file-name "target.org" tmp)))
         (with-temp-file target (insert "* Example\n:PROPERTIES:\n:ID: vwc-example\n:END:\nTarget body\n"))
         (with-current-buffer (find-file-noselect file)
           (goto-char (point-max)) (insert "Example is discussed here.\n") (save-buffer))
         (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
         (let ((facts (prin1-to-string supertag--store)) (disk (supertag-document-test-disk file))
               (target-disk (supertag-document-test-disk target))
               (supertag-ai--candidates (make-hash-table :test 'equal))
               (supertag-semantic-enabled t) (supertag-semantic--paused t)
               (supertag-semantic--error "Fixture pause"))
           ;; In-memory candidate fixture; no Runtime or model submission.
           (puthash "document-node" '(:status done :candidates ((:name "AUTHOR" :value "Ada" :current nil :source "Body" :source-verified t))) supertag-ai--candidates)
           (with-temp-buffer
             (supertag-ai-insert-section "document-node")
             (should (string-match-p "AUTHOR: Ada" (buffer-string)))
             (goto-char (point-min)) (search-forward "[Skip]")
             (let ((button (button-at (1- (point)))))
               (should button) (button-activate button))
             (should-not (plist-get (gethash "document-node" supertag-ai--candidates) :candidates)))
           (with-temp-buffer
             (supertag-semantic-insert-section "document-node")
             (should-not (text-property-not-all
                          (point-min) (point-max) 'supertag-view-section nil))
             (should-not (string-match-p " SIMILAR / " (buffer-string)))
             (should (string-match-p "Unavailable: Fixture pause" (buffer-string)))
             (goto-char (point-min)) (search-forward "[Retry]")
             (should (equal (button-get (button-at (1- (point))) 'supertag-semantic) "document-node")))
           (with-temp-buffer
             (supertag-view-mention-insert-section "vwc-example")
             (should (string-match-p " UNLINKED MENTIONS / 01 " (buffer-string)))
             (should (string-match-p "Example is discussed" (buffer-string)))
             (goto-char (point-min)) (search-forward "[Link]")
             (should (equal (plist-get (button-get (button-at (1- (point))) 'supertag-mention) :source-id) "document-node")))
           (should (equal facts (prin1-to-string supertag--store)))
           (should (equal disk (supertag-document-test-disk file)))
           (should (equal target-disk (supertag-document-test-disk target)))))))))

;;; VWD independent projected-location contracts.
(defconst supertag-view-framework-vwd--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(defun supertag-view-framework-vwd--child (name body)
  "Run BODY in a genuinely fresh, isolated source process; retain evidence."
  (let* ((tmp (make-temp-file "supertag-vwd-" t))
         (script (expand-file-name "child.el" tmp))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (root supertag-view-framework-vwd--root)
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
                  (let ((vwd-root ,root) (vwd-tmp ,tmp)
                        (before (equal (getenv "SUPERTAG_VWD_STAGE") "before")))
                    ,body)
                  (princ ,(concat "VWD-" name "-DONE\n")))
              (setq kill-emacs-hook nil emacs-startup-hook nil org-mode-hook nil
                    enable-theme-functions nil)
              (mapc #'cancel-timer (append timer-list timer-idle-list)))
          (error (princ (format "VWD-ERROR %S\n" err)) (kill-emacs 1)))
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
                 (output (buffer-string)) (evidence (getenv "SUPERTAG_VWD_EVIDENCE")))
            (when evidence
              (make-directory evidence t)
              (copy-file script (expand-file-name (concat name ".el") evidence) t)
              (with-temp-file (expand-file-name (concat name ".log") evidence) (insert output))
              (with-temp-file (expand-file-name (concat name ".exit") evidence) (prin1 exit (current-buffer))))
            (princ output)
            (should (equal exit 0))
            (should (string-match-p (concat "VWD-" name "-DONE") output))))
      (delete-directory tmp t))))


(ert-deftest supertag-view-framework-vwd-cold-nonempty-location ()
  (supertag-view-framework-vwd--child
   "location" '(progn
     (dolist (feature '(document-fixture supertag-services-sync supertag-query
                        supertag-tag supertag-view-helper supertag-node))
       (should-not (featurep feature)))
     (require (if before 'supertag-view-helper 'supertag-node))
     (princ "VWD-ENTRY-location\n")
     (should (equal (file-name-nondirectory (symbol-file 'supertag-view-helper-find-node-location 'defun))
                    (if (and before (not (getenv "SUPERTAG_VWD_EXPECT_NODE")))
                        "supertag-view-helper.el" "supertag-node.el")))
     (should (eq (featurep 'supertag-tag) before))
     (should (eq (featurep 'supertag-query) before))
     (should-not (featurep 'supertag-services-sync))
     (should-not (featurep 'supertag-view-framework))
     (unless before
       (should-not (featurep 'supertag-view-helper))
       (should-not (file-exists-p (expand-file-name "supertag-view-helper.el" vwd-root)))
       (should-not (assoc (expand-file-name "supertag-view-helper.el" vwd-root) load-history))
       ;; The omission counterexample must reach the real call, not this metadata assertion.
       (unless (getenv "SUPERTAG_VWD_OMIT_PROVIDER")
         (should (autoloadp (symbol-function 'supertag-view-api-get-entity)))))
     (should-not (supertag-view-helper-find-node-location nil))
     (should (eq (featurep 'supertag-query) before))
     (let* ((file (expand-file-name "node.org" vwd-tmp)) (buffer nil))
       (with-temp-file file (insert "* Original\n:PROPERTIES:\n:ID: vwd-node\n:END:\nBody\n"))
       (supertag--ensure-store)
       (supertag-store-put-entity :nodes "vwd-node" (list :id "vwd-node" :title "Original" :file file :position 7))
       (unwind-protect
           (progn
             (setq buffer (find-file-noselect file))
             (with-current-buffer buffer
               (goto-char 3)
               (let ((point0 (point)) (dirty (buffer-modified-p))
                     (live (buffer-string)) (facts (prin1-to-string supertag--store))
                     (disk (with-temp-buffer (insert-file-contents file) (buffer-string))))
                 (should (eq (featurep 'supertag-query) before))
                 (princ "VWD-BEFORE-NONEMPTY\n")
                 (let ((location (supertag-view-helper-find-node-location "vwd-node")))
                   (princ (format "VWD-LOCATION %S\n" location))
                   (should (equal location (cons 7 file)))
                   (setcar location 999))
                 (should (featurep 'supertag-query))
                 (should-not (autoloadp (symbol-function 'supertag-view-api-get-entity)))
                 (should (equal (file-name-nondirectory (symbol-file 'supertag-view-api-get-entity 'defun)) "supertag-query.el"))
                 (should (equal facts (prin1-to-string supertag--store)))
                 (should (equal disk (with-temp-buffer (insert-file-contents file) (buffer-string))))
                 (should (equal live (buffer-string)))
                 (should (eq dirty (buffer-modified-p)))
                 (should (= point0 (point))))))
         (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest supertag-view-framework-vwd-value-and-error-boundaries ()
  (supertag-view-framework-vwd--child
   "boundaries" '(progn
     (require (if before 'supertag-view-helper 'supertag-node))
     (princ "VWD-ENTRY-boundaries\n")
     (supertag--ensure-store)
     (let ((file (expand-file-name "existing.org" vwd-tmp)))
       (with-temp-file file (insert "* Existing\n"))
       (dolist (case (list (list nil nil) (list "missing" nil)))
         (should-not (supertag-view-helper-find-node-location (car case))))
       (dolist (position '(nil 0 9999 "stale-position"))
         (supertag-store-put-entity :nodes "node" (list :id "node" :file file :position position))
         (let ((facts (prin1-to-string supertag--store))
               (disk (with-temp-buffer (insert-file-contents file) (buffer-string))))
           (should (equal (supertag-view-helper-find-node-location "node") (cons (or position 1) file)))
           (should (equal facts (prin1-to-string supertag--store)))
           (should (equal disk (with-temp-buffer (insert-file-contents file) (buffer-string))))))
       (dolist (path (list nil (expand-file-name "absent.org" vwd-tmp)))
         (supertag-store-put-entity :nodes "node" (list :id "node" :file path))
         (should-not (supertag-view-helper-find-node-location "node")))
       ;; Existing directory is accepted by file-exists-p; this is not an Org locator.
       (supertag-store-put-entity :nodes "node" (list :id "node" :file vwd-tmp))
       (should (equal (supertag-view-helper-find-node-location "node") (cons 1 vwd-tmp)))
       (supertag-store-put-entity :nodes "node" '(:id "node" :file 17))
       (let ((facts (prin1-to-string supertag--store)))
         (should-error (supertag-view-helper-find-node-location "node") :type 'wrong-type-argument)
         (should-error (supertag-view-helper-find-node-location "") :type 'error)
         (should-error (supertag-view-helper-find-node-location 17) :type 'error)
         (should (equal facts (prin1-to-string supertag--store))))))))

(ert-deftest supertag-view-framework-vwd-node-reload-and-capture-tail ()
  (dolist (preset '(nil t))
    (supertag-view-framework-vwd--child
     (if preset "reload-on" "reload-off")
     `(progn
        (setq supertag-org-capture-auto-enable ,preset)
        (require (if before 'supertag-view-helper 'supertag-node))
        (princ "VWD-ENTRY-reload\n")
        (let ((function (symbol-function 'supertag-view-helper-find-node-location)))
          (require (if before 'supertag-view-helper 'supertag-node))
          (should (eq function (symbol-function 'supertag-view-helper-find-node-location))))
        (should (eq supertag-org-capture-auto-enable ,preset))
        (should (= (cl-count #'supertag-org-capture-after-finalize org-capture-after-finalize-hook) ,(if preset 1 0)))
        (dotimes (_ 2) (load (expand-file-name "supertag-node.el" vwd-root) nil nil t))
        (should (eq supertag-org-capture-auto-enable ,preset))
        (should (= (cl-count #'supertag-org-capture-after-finalize org-capture-after-finalize-hook) ,(if preset 1 0)))
        (should (equal (file-name-nondirectory (symbol-file 'supertag-view-helper-find-node-location 'defun))
                       (if before "supertag-view-helper.el" "supertag-node.el")))
        (supertag-disable-org-capture-integration)
        (should-not (memq #'supertag-org-capture-after-finalize org-capture-after-finalize-hook))))))

(ert-deftest supertag-view-framework-vwd-embark-loading-order ()
  (supertag-view-framework-vwd--child
   "embark" '(progn
     (should-not (featurep 'supertag-node))
     (let (calls completed first-service)
       (let ((observer
              (lambda (original feature &rest args)
                (when (string-prefix-p "supertag-" (symbol-name feature))
                  (push feature calls))
                (when (and (eq feature 'supertag-service-org) (not first-service))
                  (setq first-service
                        (list (featurep 'supertag-node) (featurep 'supertag-tag)
                              (featurep 'supertag-query) (featurep 'supertag-view-helper))))
                (apply original feature args)))
             (loaded (lambda (file)
                       (when (string-prefix-p "supertag-" (file-name-nondirectory file))
                         (push (file-name-nondirectory file) completed)))))
         (unwind-protect
             (progn
               (advice-add 'require :around observer)
               (add-hook 'after-load-functions loaded)
               (require 'supertag-embark)
               (princ (format "VWD-EMBARK-CALLS %S\nVWD-EMBARK-COMPLETED %S\nVWD-SERVICE-ENTRY %S\n"
                              (reverse calls) (reverse completed) first-service))
               (should (equal (seq-take (reverse calls) 2)
                              (list 'supertag-embark (if before 'supertag-view-helper 'supertag-node))))
               (should (equal first-service (if before '(t t t t) '(nil nil nil nil))))
               (dolist (feature '(supertag-node supertag-tag supertag-query supertag-service-org supertag-embark))
                 (should (featurep feature)))
               (should (eq (featurep 'supertag-view-helper) before))
               (should (equal (file-name-nondirectory (symbol-file 'supertag-view-helper-find-node-location 'defun))
                              (if before "supertag-view-helper.el" "supertag-node.el"))))
           (advice-remove 'require observer)
           (remove-hook 'after-load-functions loaded)))))))

(ert-deftest supertag-view-framework-vwd-retired-helper-and-node-entry ()
  (supertag-view-framework-vwd--child
   "retirement" '(progn
     (should-not (featurep 'supertag-node))
     (if before
         (progn (require 'supertag-view-helper)
                (should (featurep 'supertag-view-helper))
                (should (file-exists-p (expand-file-name "supertag-view-helper.el" vwd-root))))
       (let ((failure (should-error (require 'supertag-view-helper) :type 'file-missing)))
         (should (equal (car (last failure)) "supertag-view-helper")))
       (should-not (featurep 'supertag-view-helper))
       (should-not (fboundp 'supertag-view-helper-find-node-location)))
     (require 'supertag-node)
     (princ "VWD-NODE-POSITIVE-ENTRY\n")
     (should (fboundp 'supertag-view-helper-find-node-location))
     (should-not (supertag-view-helper-find-node-location nil)))))


(ert-deftest supertag-view-framework-type-input-adapter-preserves-original-contract ()
  (require 'supertag-view-framework)
  (should (equal "supertag-view-framework.el"
                 (file-name-nondirectory (symbol-file 'supertag-ui--sanitize-type-input 'defun))))
  (dolist (input '(nil "" " " ":" " : "))
    (should-not (supertag-ui--sanitize-type-input input)))
  (should (eq :node (supertag-ui--sanitize-type-input " :node ")))
  (should (eq :node (supertag-ui--sanitize-type-input "node")))
  (should (eq (intern "::node") (supertag-ui--sanitize-type-input "::node")))
  (should-error (supertag-ui--sanitize-type-input 7) :type 'wrong-type-argument))

(ert-deftest supertag-view-framework-file-display-name ()
  "Denote file names lose their timestamp, tags and extension."
  (require 'supertag-view-framework)
  (should (equal "diary-2025"
                 (supertag-view-helper-file-display-name
                  "/notes/20260629T105208--diary-2025__diary.org")))
  (should (equal "org-supertag"
                 (supertag-view-helper-file-display-name
                  "20260620T131132--org-supertag__emacs_project.org")))
  (should (equal "note"
                 (supertag-view-helper-file-display-name
                  "/notes/20260101T010101--note.org")))
  (should (equal "hangji__project"
                 (supertag-view-helper-file-display-name "/notes/hangji__project.org")))
  (should (equal "plain" (supertag-view-helper-file-display-name "plain.org")))
  (should-not (supertag-view-helper-file-display-name nil))
  (should-not (supertag-view-helper-file-display-name "")))
