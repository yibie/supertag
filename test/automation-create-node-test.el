;;; automation-create-node-test.el --- Org-first Automation node creation -*- lexical-binding: t; -*-

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

(defmacro supertag-automation-create-test--with-file (contents &rest body)
  "Run BODY with an isolated existing Org FILE containing CONTENTS."
  (declare (indent 1) (debug t))
  `(let* ((tmp (make-temp-file "supertag-automation-create-test-" t))
          (file (expand-file-name "target.org" tmp))
          (supertag--store nil)
          (supertag--subscribers (make-hash-table :test 'equal))
          (supertag--rule-index (make-hash-table :test 'equal))
          (supertag-sync--internal-modifications (make-hash-table :test 'equal))
          buffer)
     (unwind-protect
         (progn
           (with-temp-file file (insert ,contents))
           (supertag--ensure-store)
           (setq buffer (find-file-noselect file))
           (with-current-buffer buffer (org-mode))
           ,@body)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (ignore-errors (delete-directory tmp t)))))

(defun supertag-automation-create-test--disk-string (file)
  "Return FILE contents."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(ert-deftest supertag-automation-create-appends-level-one-and-preserves-context ()
  "Creation appends one heading while preserving live drafts and caller context."
  (supertag-automation-create-test--with-file "#+title: Target\n* Existing\nBody\n"
    (supertag-tag-create '(:name "alpha"))
    (supertag-tag-create '(:name "beta"))
    (with-current-buffer buffer
      (goto-char (point-min))
      (forward-line 1)
      (insert "Draft before heading\n")
      (let ((before-point (point))
            (before-min (point-min))
            (before-max (point-max)))
        (narrow-to-region (point-min) (line-end-position 2))
        (let ((narrow-min (point-min)) (narrow-max (point-max))
              (real-save (symbol-function 'save-buffer))
              (real-project
               (symbol-function 'supertag-service-org--project-current-node))
              (saves 0) (projections 0) order)
          (cl-letf (((symbol-function 'supertag-node-identity-new)
                     (lambda () "created-id"))
                    ((symbol-function 'save-buffer)
                     (lambda (&rest args)
                       (cl-incf saves)
                       (setq order (append order '(save)))
                       (apply real-save args)))
                    ((symbol-function 'supertag-service-org--project-current-node)
                     (lambda (node-id)
                       (cl-incf projections)
                       (setq order (append order '(project)))
                       (funcall real-project node-id))))
            (should (equal "created-id"
                           (supertag-service-org-create-node
                            file "Created" '("alpha" "beta")))))
          (should (= 1 saves))
          (should (= 1 projections))
          (should (equal '(save project) order))
          (should (= before-point (point)))
          (should (= narrow-min (point-min)))
          (should (= narrow-max (point-max))))
        (widen)
        (should (> (point-max) before-max))))
    (let ((text (supertag-automation-create-test--disk-string file)))
      (should (string-prefix-p "#+title: Target\nDraft before heading\n* Existing\nBody\n" text))
      (should (string-match-p "\n\\* Created #alpha #beta\n:PROPERTIES:\n:ID:[ \t]+created-id\n:END:\n\\'" text)))
    (let ((node (supertag-node-get "created-id")))
      (should (equal (file-truename file)
                     (file-truename (plist-get node :file))))
      (should (= 1 (plist-get node :level)))
      (should (= 2 (length (plist-get node :tags))))
      (should (supertag-tag-resolve-occurrence "alpha"))
      (should (supertag-tag-resolve-occurrence "beta")))))

(ert-deftest supertag-automation-create-identical-titles-get-distinct-ids ()
  "Every accepted invocation creates a new identity."
  (supertag-automation-create-test--with-file "* Existing\n"
    (let ((ids '("first-id" "second-id")))
      (cl-letf (((symbol-function 'supertag-node-identity-new)
                 (lambda () (pop ids))))
        (should (equal "first-id"
                       (supertag-automation-action-create-node
                        `(:title "Same" :target-file ,file))))
        (should (equal "second-id"
                       (supertag-automation-action-create-node
                        `(:title "Same" :target-file ,file))))))
    (with-current-buffer buffer
      (should (= 2 (how-many "^\\* Same$" (point-min) (point-max)))))))

(ert-deftest supertag-automation-create-file-end-org-matrix ()
  "Common EOF shapes preserve old text and append a parsed level-1 headline."
  (let* ((tmp (make-temp-file "supertag-automation-create-eof-" t))
         (supertag--store nil)
         (supertag--subscribers (make-hash-table :test 'equal))
         (supertag-sync--internal-modifications (make-hash-table :test 'equal))
         (fixtures
          '(("empty.org" . "")
            ("no-newline.org" . "* Existing\nBody without newline")
            ("drawer.org" . "* Existing\n:PROPERTIES:\n:NOTE: kept\n:END:\n")
            ("block.org" . "#+begin_src emacs-lisp\n(message \"kept\")\n#+end_src\n")))
         buffers)
    (unwind-protect
        (progn
          (supertag--ensure-store)
          (cl-loop for (name . original) in fixtures
                   for index from 1
                   for file = (expand-file-name name tmp)
                   for id = (format "matrix-id-%d" index)
                   do
                   (with-temp-file file (insert original))
                   (cl-letf (((symbol-function 'supertag-node-identity-new)
                              (lambda () id)))
                     (should (equal id
                                    (supertag-service-org-create-node
                                     file (format "Matrix %d" index) nil))))
                   (push (find-buffer-visiting file) buffers)
                   (let ((text (supertag-automation-create-test--disk-string file)))
                     (should (string-prefix-p original text)))
                   (with-temp-buffer
                     (insert-file-contents file)
                     (org-mode)
                     (goto-char (point-min))
                     (should (re-search-forward
                              (concat "^[ \t]*:ID:[ \t]*" (regexp-quote id)
                                      "[ \t]*$") nil t))
                     (org-back-to-heading t)
                     (let ((element (org-element-at-point)))
                       (should (eq 'headline (org-element-type element)))
                       (should (= 1 (org-element-property :level element)))))))
      (dolist (buffer buffers)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (ignore-errors (delete-directory tmp t)))))

(ert-deftest supertag-automation-create-validates-before-identity-or-edit ()
  "Unsafe or ambiguous targets and structural input fail before mutation."
  (supertag-automation-create-test--with-file "* Existing\n"
    (let ((before (with-current-buffer buffer (buffer-string)))
          (ids 0))
      (cl-letf (((symbol-function 'supertag-node-identity-new)
                 (lambda () (cl-incf ids) "unused")))
        (dolist (params
                 `((:title "Node" :target-file "relative.org")
                   (:title "Node")
                   (:title "Node" :target-file "/ssh:example:/tmp/target.org")
                   (:title "Bad\n* Injected" :target-file ,file)
                   (:title "Node" :tags ("ok" "bad\n* Injected") :target-file ,file)
                   (:title "Node" :tags "not-a-list" :target-file ,file)
                   (:title "" :target-file ,file)))
          (should-error (supertag-automation-action-create-node params))))
      (should (= 0 ids))
      (should (equal before (with-current-buffer buffer (buffer-string)))))))

(ert-deftest supertag-automation-create-rejects-missing-and-readonly-target ()
  "Invalid destination state cannot produce an ID or Store node."
  (supertag-automation-create-test--with-file "* Existing\n"
    (let ((ids 0))
      (cl-letf (((symbol-function 'supertag-node-identity-new)
                 (lambda () (cl-incf ids) "unused")))
        (should-error
         (supertag-service-org-create-node
          (expand-file-name "missing.org" tmp) "Missing" nil))
        (with-current-buffer buffer
          (setq buffer-read-only t))
        (unwind-protect
            (should-error (supertag-service-org-create-node file "Readonly" nil))
          (with-current-buffer buffer (setq buffer-read-only nil))))
      (should (= 0 ids)))))

(ert-deftest supertag-automation-create-rejects-non-org-and-unwritable-files ()
  "File kind and filesystem writability are checked before identity creation."
  (supertag-automation-create-test--with-file "Plain text\n"
    (let ((text-file (expand-file-name "plain.txt" tmp))
          (ids 0))
      (with-temp-file text-file (insert "Plain text\n"))
      (cl-letf (((symbol-function 'supertag-node-identity-new)
                 (lambda () (cl-incf ids) "unused")))
        (should-error
         (supertag-service-org-create-node text-file "Not Org" nil))
        (set-file-modes file #o444)
        (unwind-protect
            (should-error
             (supertag-service-org-create-node file "Not writable" nil))
          (set-file-modes file #o644)))
      (should (= 0 ids)))))

(ert-deftest supertag-automation-create-save-failure-leaves-visible-no-projection ()
  "Save failure retains the unsaved heading and publishes no node."
  (supertag-automation-create-test--with-file "* Existing\n"
    (cl-letf (((symbol-function 'supertag-node-identity-new)
               (lambda () "failed-id"))
              ((symbol-function 'save-buffer)
               (lambda (&rest _) (error "deliberate save failure"))))
      (should-error
       (supertag-service-org-create-node file "Unsaved" '("not-created"))))
    (should-not (supertag-node-get "failed-id"))
    (should (= 0 (hash-table-count (supertag-store-get-collection :tags))))
    (should-not (string-match-p "failed-id"
                                (supertag-automation-create-test--disk-string file)))
    (with-current-buffer buffer
      (should (buffer-modified-p))
      (should (search-forward "failed-id" nil t)))))

(ert-deftest supertag-automation-create-projection-failure-is-retryable ()
  "Projection failure retains one durable heading and exposes Projection retry."
  (supertag-automation-create-test--with-file "* Existing\n"
    (let (caught)
      (cl-letf (((symbol-function 'supertag-node-identity-new)
                 (lambda () "retry-id"))
                ((symbol-function 'supertag-node-sync-current-buffer)
                 (lambda (&rest _) (error "deliberate projection failure"))))
        (condition-case err
            (supertag-service-org-create-node file "Retry" nil)
          (error (setq caught err))))
      (should (eq 'supertag-projection-error (car caught)))
      (should (equal '("retry-id")
                     (list (plist-get (cdr caught) :node-id))))
      (should (eq 'supertag-service-org-retry-node-projection
                  (plist-get (cdr caught) :retry)))
      (should (equal (list "retry-id" file)
                     (plist-get (cdr caught) :retry-args)))
      (should-not (supertag-node-get "retry-id"))
      (should (= 1 (with-temp-buffer
                     (insert-file-contents file)
                     (how-many "retry-id" (point-min) (point-max)))))
      (supertag-service-org-retry-node-projection "retry-id" file)
      (should (supertag-node-get "retry-id")))))

(ert-deftest supertag-automation-create-real-trigger-has-no-runtime-prompts ()
  "A matching Store event creates and projects a node without UI reads."
  (supertag-automation-create-test--with-file "* Existing\n"
    (let ((source-file (expand-file-name "source.org" tmp)))
      (with-temp-file source-file
        (insert "* Source\n:PROPERTIES:\n:ID: source-id\n:END:\n"))
      (supertag-node-create
       `(:id "source-id" :title "Source" :file ,source-file
         :level 1 :position 1 :tags nil))
      (supertag-subscribe :store-changed
                          #'supertag-automation--handle-entity-change)
      (supertag-automation-create
       `(:name "create-on-tag" :trigger (:on-tag-added "go")
         :actions ((:action :create-node
                    :params (:title "Triggered" :target-file ,file)))))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (ert-fail "runtime title prompt")))
                ((symbol-function 'read-file-name)
                 (lambda (&rest _) (ert-fail "runtime target prompt")))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) (ert-fail "runtime selection prompt"))))
        (supertag-node-add-tag "source-id" "go"))
      (let (created)
        (maphash (lambda (_id node)
                   (when (equal "Triggered" (plist-get node :title))
                     (setq created node)))
                 (supertag-store-get-collection :nodes))
        (should created)
        (should (equal (file-truename file)
                       (file-truename (plist-get created :file))))
        (should (string-match-p (regexp-quote (plist-get created :id))
                                (supertag-automation-create-test--disk-string file)))))))

(ert-deftest supertag-automation-create-followup-template-requires-target-file ()
  "The built-in follow-up template writes its configured absolute target."
  (let* ((template (cl-find :tag-added-create-followup-node
                            supertag-automation-templates
                            :key (lambda (item) (plist-get item :id))))
         (params '((tag . "go") (title . "Follow up")
                   (followup-tags . "task, followup")
                   (target-file . "/tmp/followups.org")))
         (rule (funcall (plist-get template :build) params))
         (action-params (plist-get (car (plist-get rule :actions)) :params)))
    (should (member '(target-file "Destination Org file" file)
                    (plist-get template :params)))
    (should (equal "/tmp/followups.org"
                   (plist-get action-params :target-file)))))

(provide 'automation-create-node-test)
;;; automation-create-node-test.el ends here

;;; AUC: independent Templates ownership and actual business controls.
(defconst supertag-automation-create-auc--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(defun supertag-automation-create-auc--child (name body)
  "Run BODY in a genuinely fresh, isolated source process; retain evidence."
  (let* ((tmp (make-temp-file "supertag-auc-" t))
         (script (expand-file-name "child.el" tmp))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (root supertag-automation-create-auc--root)
         (process-environment (copy-sequence process-environment)))
    (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
    (with-temp-file script
      (insert ";;; -*- lexical-binding: t; -*-\n")
      (prin1
       `(condition-case err
            (unwind-protect
                (progn
                  (require 'cl-lib) (require 'ert) (require 'org)
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
                  (let ((auc-root ,root) (auc-tmp ,tmp)
                        (before (equal (getenv "SUPERTAG_AUC_STAGE") "before")))
                    ,body)
                  (princ ,(concat "AUC-" name "-DONE\n")))
              (setq kill-emacs-hook nil emacs-startup-hook nil org-mode-hook nil
                    enable-theme-functions nil)
              (mapc #'cancel-timer (append timer-list timer-idle-list)))
          (error (princ (format "AUC-ERROR %S\n" err)) (kill-emacs 1)))
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
                 (output (buffer-string)) (evidence (getenv "SUPERTAG_AUC_EVIDENCE")))
            (when evidence
              (make-directory evidence t)
              (copy-file script (expand-file-name (concat name ".el") evidence) t)
              (with-temp-file (expand-file-name (concat name ".log") evidence) (insert output))
              (with-temp-file (expand-file-name (concat name ".exit") evidence) (prin1 exit (current-buffer))))
            (princ output)
            (should (equal exit 0))
            (should (string-match-p (concat "AUC-" name "-DONE") output))))
      (delete-directory tmp t))))

(ert-deftest supertag-automation-create-auc-lifecycle ()
  (supertag-automation-create-auc--child
   "lifecycle"
   '(let ((inits 0) (subscriptions 0))
      (if (equal (getenv "SUPERTAG_STA_STAGE") "before")
          (require 'supertag-core-notify)
        (require 'supertag-core-store))
      (advice-add 'supertag-automation-init :before (lambda (&rest _) (cl-incf inits)))
      (advice-add 'supertag-subscribe :before
                  (lambda (event handler &rest _)
                    (when (and (eq event :store-changed)
                               (eq handler 'supertag-automation--handle-entity-change))
                      (cl-incf subscriptions))))
      (require 'supertag-automation)
      (princ "AUC-lifecycle-ENTRY\n")
      (should (= inits 1)) (should (= subscriptions 1))
      (if before
          (progn
            (should-not (boundp 'supertag-automation-templates))
            (should-not (fboundp 'supertag-automation-insert-template))
            (require 'supertag-automation-templates))
        (should-not (featurep 'supertag-automation-templates)))
      (should (= 9 (length supertag-automation-templates)))
      (should (commandp 'supertag-automation-insert-template))
      (should (commandp 'supertag-automation-list-templates))
      (let ((catalog supertag-automation-templates))
        (require 'supertag-automation)
        (should (eq catalog supertag-automation-templates))
        (should (= inits 1))
        (load (expand-file-name "supertag-automation.el" auc-root) nil nil t)
        (should (= inits 2)) (should (= subscriptions 1))
        (if before (should (eq catalog supertag-automation-templates))
          (should-not (eq catalog supertag-automation-templates))))
      (should-not supertag-scheduler--master-timer)
      (should (= 0 (hash-table-count supertag-scheduler--tasks)))
      (princ (format "AUC-LIFECYCLE catalog=%s init=%s subscriptions=%s\n"
                     (length supertag-automation-templates) inits subscriptions)))))

(ert-deftest supertag-automation-create-auc-entry-owner ()
  (supertag-automation-create-auc--child
   "owner"
   '(progn
      (require 'supertag-automation)
      (princ "AUC-owner-ENTRY\n")
      (should-not (locate-library "supertag-automation-templates"))
      (should-not (featurep 'supertag-automation-templates))
      (should-not (cl-find-if
                   (lambda (row) (and (stringp (car row))
                                     (string-match-p "supertag-automation-templates\\.el" (car row))))
                   load-history))
      (dolist (fn '(supertag-automation-templates--param
                    supertag-automation-templates--keywordize
                    supertag-automation-templates--split-tags
                    supertag-automation-templates--scheduled-set-property
                    supertag-automation-templates--all-tag-names
                    supertag-automation-templates--read-tag
                    supertag-automation-templates--read-todo-state
                    supertag-automation-templates--read-param
                    supertag-automation-templates--collect-params
                    supertag-automation-templates--choose
                    supertag-automation-templates--preview-buffer
                    supertag-automation-templates--create-with-retry
                    supertag-automation-insert-template supertag-automation-list-templates))
        (should (equal "supertag-automation.el" (file-name-nondirectory (symbol-file fn 'defun)))))
      (should (equal "supertag-automation.el"
                     (file-name-nondirectory (symbol-file 'supertag-automation-templates 'defvar)))))))

(ert-deftest supertag-automation-create-auc-menu-inputs ()
  (supertag-automation-create-auc--child
   "menu"
   '(progn
      (require 'supertag-menu)
      (should-not (featurep 'supertag-automation))
      (let ((shown nil))
        (cl-letf (((symbol-function 'display-buffer) (lambda (b &rest _) (push b shown))))
          (call-interactively #'supertag-menu--automation-list-templates)
          (princ "AUC-menu-ENTRY\n")
          (with-current-buffer "*Supertag Automation Templates*"
            (should buffer-read-only)
            (should (= 9 (how-many "  \\[" (point-min) (point-max)))))
          (supertag-tag-create '(:id "canonical" :name "Display"))
          (dolist (pair '(("Display" . "canonical") ("new/path" . "new/path") ("" . "")))
            (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (car pair))))
              (should (equal (cdr pair) (supertag-automation-templates--read-tag "Tag")))))
          (let ((org-todo-keywords-1 nil))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt collection &rest _)
                         (should (equal collection '("TODO" "NEXT" "DONE" "CANCELLED"))) " DONE ")))
              (should (equal "DONE" (supertag-automation-templates--read-todo-state "State")))))
          (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) "relative.org")))
            (should (equal (expand-file-name "relative.org")
                           (supertag-automation-templates--read-param "File" 'file))))
          (let ((store (prin1-to-string supertag--store))
                (answers '("Tag added -> set a property" "Display"))
                (values '("AUTHOR" "Ada")))
            (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (pop answers)))
                      ((symbol-function 'read-string) (lambda (&rest _) (pop values)))
                      ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
              (call-interactively #'supertag-menu--automation-insert-template))
            (should (equal store (prin1-to-string supertag--store)))
            (with-current-buffer "*Supertag Automation Preview*"
              (should buffer-read-only)
              (should (string-match-p ":AUTHOR" (buffer-string)))
              (should (string-match-p "Ada" (buffer-string))))
            (should-not (file-exists-p supertag-db-file)))
          (let ((answers '("Tag added -> set a property" "Display"))
                (values '("AUTHOR" "Ada")))
            (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (pop answers)))
                      ((symbol-function 'read-string) (lambda (&rest _) (pop values)))
                      ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
              (call-interactively #'supertag-menu--automation-insert-template)))
          (should (supertag-automation-get-by-name "Tag 'canonical' sets AUTHOR"))
          (should (= 3 (length shown))))))))

(ert-deftest supertag-automation-create-auc-collision-and-errors ()
  (supertag-automation-create-auc--child
   "collision"
   '(progn
      (require 'supertag-automation)
      (when before (require 'supertag-automation-templates))
      (princ "AUC-collision-ENTRY\n")
      (let* ((tpl (cl-find :tag-added-set-property supertag-automation-templates
                           :key (lambda (x) (plist-get x :id))))
             (args (funcall (plist-get tpl :build) '((tag . "go") (property . "AUTHOR") (value . "old"))))
             (old (supertag-automation-create args))
             (newargs (copy-tree args)))
        (plist-put newargs :description "replacement")
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
                  ((symbol-function 'read-string) (lambda (&rest _) "Renamed")))
          (should (equal "Renamed" (plist-get (supertag-automation-templates--create-with-retry newargs) :name))))
        (should (equal old (supertag-automation-get (plist-get old :id))))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (supertag-automation-templates--create-with-retry (plist-put (copy-tree args) :description "replacement")))
        (should (equal "replacement" (plist-get (supertag-automation-get (plist-get old :id)) :description)))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (signal 'quit nil))))
          (should (eq 'quit (condition-case nil
                               (supertag-automation-templates--create-with-retry args)
                             (quit 'quit))))))
      (should-not (supertag-automation-templates--create-with-retry '(:name "invalid"))))))

(ert-deftest supertag-automation-create-auc-vertical-writers ()
  (supertag-automation-create-auc--child
   "writers"
   '(progn
      (require 'supertag-automation)
      (when before (require 'supertag-automation-templates))
      (require 'document-fixture)
      (princ "AUC-writers-ENTRY\n")
      (supertag-document-test-with-vault
        (let ((supertag--dirty nil) (supertag--rule-index (make-hash-table :test 'equal))
              (supertag-scheduler--tasks (make-hash-table :test 'equal))
              (supertag-automation--enabled t) (supertag-automation-sync--enabled t)
              (supertag-automation-sync--async-enabled nil))
          (supertag-load-store)
          (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
          (dolist (name '("other.org" "followup.org"))
            (with-temp-file (expand-file-name name tmp) (insert "#+title: Target\n")))
          (supertag-tag-create '(:id "go" :name "go"))
          (supertag-subscribe :store-changed #'supertag-automation--handle-entity-change)
          (dolist (spec `((:tag-added-set-property (tag . "go") (property . "AUTHOR") (value . "Ada"))
                          (:daily-set-property-for-tag (tag . "go") (property . "REVIEW") (value . "done") (time . "00:00"))
                          (:tag-added-create-followup-node (tag . "go") (title . "Followup") (followup-tags . "next")
                           (target-file . ,(expand-file-name "followup.org" tmp)))))
            (let ((tpl (cl-find (car spec) supertag-automation-templates :key (lambda (x) (plist-get x :id)))))
              (supertag-automation-create (funcall (plist-get tpl :build) (cdr spec)))))
          (let ((other (supertag-service-org-create-node (expand-file-name "other.org" tmp) "Other" nil)))
            (supertag-service-org-add-tag "document-node" "go")
            (should (equal "Ada" (plist-get (plist-get (supertag-node-get "document-node") :properties) :AUTHOR)))
            (should (string-match-p ":AUTHOR:[ \t]+Ada" (supertag-document-test-disk file)))
            (let* ((out (expand-file-name "followup.org" tmp))
                   (nodes (mapcar #'cdr (supertag-find-nodes-by-file out))))
              (should (= 1 (length nodes)))
              (should (equal "Followup" (plist-get (car nodes) :title)))
              (should (string-match-p (regexp-quote (plist-get (car nodes) :id)) (supertag-document-test-disk out))))
            (let* ((scheduled (car (supertag-automation-find-scheduled)))
                   (callback (plist-get (plist-get (car (plist-get scheduled :actions)) :params) :function)))
              (should (eq callback 'supertag-automation-templates--scheduled-set-property))
              (should (supertag-save-store))
              (should (file-exists-p supertag-db-file))
              (supertag-load-store)
              (should (eq callback (plist-get (plist-get (car (plist-get
                                      (supertag-automation-get (plist-get scheduled :id)) :actions)) :params) :function))))
            (let ((now (time-convert (encode-time 0 0 12 1 1 2026) 'list)))
              (cl-letf (((symbol-function 'current-time) (lambda () now)))
                (supertag-scheduler--check-tasks)))
            (should (equal "done" (plist-get (plist-get (supertag-node-get "document-node") :properties) :REVIEW)))
            (should-not (plist-get (plist-get (supertag-node-get other) :properties) :REVIEW))
            (should (string-match-p ":REVIEW:[ \t]+done" (supertag-document-test-disk file)))
            (should (file-exists-p (supertag-scheduler--state-path)))
            (princ "AUC-REAL-WRITERS author=Ada review=done followup=1\n")
            (should (equal "Ada" (plist-get (plist-get (supertag-node-get "document-node") :properties) :AUTHOR)))))))))

(ert-deftest supertag-automation-create-auc-field-compatibility ()
  (supertag-automation-create-auc--child
   "fields"
   '(progn
      (require 'supertag-automation)
      (when before (require 'supertag-automation-templates))
      (require 'document-fixture)
      (princ "AUC-fields-ENTRY\n")
      (supertag-document-test-with-vault
        (let ((supertag--dirty nil) (supertag--rule-index (make-hash-table :test 'equal))
              (supertag-automation--enabled t) (supertag-automation-sync--enabled t)
              (supertag-automation-sync--async-enabled nil) rules)
          (supertag-load-store)
          (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
          (supertag-tag-create '(:id "scope" :name "scope"))
          (supertag-service-org-add-tag "document-node" "scope")
          (supertag-subscribe :store-changed #'supertag-automation--handle-entity-change)
          (dolist (spec `((:field-change-update-field (scope-tag . "scope") (source-field . "status")
                          (target-tag . "scope") (target-field . "other") (target-value . "changed"))
                         (:field-equals-move-node (scope-tag . "scope") (field . "status") (value . "go")
                          (target-file . ,(expand-file-name "archive.org" tmp)))))
            (let* ((tpl (cl-find (car spec) supertag-automation-templates :key (lambda (x) (plist-get x :id))))
                   (rule (supertag-automation-create (funcall (plist-get tpl :build) (cdr spec)))))
              (push (copy-tree rule) rules)
              (should (equal :on-field-change (plist-get rule :trigger)))
              (should-not (supertag-automation--trigger-match-p (plist-get rule :trigger) '(:type :property-change)))
              (should-not (supertag-automation--evaluate-condition (plist-get rule :condition) "document-node"))))
          (should-not (supertag-automation--evaluate-condition '(field-equals "status" "go") "document-node"))
          (should (supertag-automation--evaluate-condition '(property-equals :ALPHA "first") "document-node"))
          (supertag-document-test-save-property file "status" "go")
          (supertag-document-test-drain)
          (supertag-service-org-remove-tag "document-node" "scope")
          (supertag-service-org-add-tag "document-node" "scope")
          (should-not (file-exists-p (expand-file-name "archive.org" tmp)))
          (should-not (plist-get (supertag-node-get "document-node") :fields))
          (let ((disk (supertag-document-test-disk file))
                (store (prin1-to-string supertag--store)) (messages nil)
                (real-message (symbol-function 'message)) result)
            (cl-letf (((symbol-function 'message)
                       (lambda (fmt &rest args)
                         (push (apply #'format fmt args) messages)
                         (apply real-message fmt args))))
              (setq result (supertag-automation-execute-action :update-field "document-node"
                                                              '(:tag "scope" :field "other" :value "changed") nil)))
            (princ (format "AUC-FIELD direct=%S messages=%S\n" result messages))
            (should (equal result "Unknown action type: :update-field"))
            (should (member "Unknown action type: :update-field" messages))
            (should (equal disk (supertag-document-test-disk file)))
            (should (equal store (prin1-to-string supertag--store))))
          (should (supertag-save-store)) (should (file-exists-p supertag-db-file))
          (setq supertag--store nil)
          (supertag-load-store)
          (dolist (rule rules)
            (let ((saved (supertag-automation-get (plist-get rule :id))))
              (should (equal (plist-get rule :trigger) (plist-get saved :trigger)))
              (should (equal (supertag--persistence--canonicalize-value (plist-get rule :actions))
                             (supertag--persistence--canonicalize-value (plist-get saved :actions))))))
          (princ "AUC-FIELD created=2 persisted=2 condition=nil real-events-no-field-write\n"))))))
