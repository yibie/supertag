;;; property-consumers-test.el --- Property consumers -*- lexical-binding: t; -*-
(require 'legacy-field-fixture)
(require 'document-fixture)
(require 'supertag-query)
(require 'supertag-automation)
(require 'supertag-view-node)
(require 'supertag-api)

(ert-deftest supertag-property-consumers-query-and-formula ()
  (supertag-document-test-with-vault
    (supertag-service-org-set-property "document-node" "K" "7")
    (supertag-test-legacy-value "document-node" "K" "legacy")
    (should (equal '("document-node") (supertag-query-node-ids '(property "k" "7"))))
    (should (equal (supertag-query-node-ids '(property "K" "7"))
                   (supertag-query-node-ids '(field "k" "7"))))
    (should (= 14 (supertag-formula-evaluate "k * 2" (supertag-node-get "document-node"))))))

(ert-deftest supertag-property-consumers-single-event-channel ()
  (supertag-document-test-with-vault
    (let ((supertag-automation--enabled t)
          (supertag-automation-sync--enabled t)
          (supertag-after-operation-hook nil)
          (count 0))
      (supertag-automation-create
       '(:name "Count property" :trigger :on-property-change
         :condition (property-changed "K")
         :actions ((:action :call-function :function ignore))))
      (supertag-subscribe :store-changed #'supertag-automation--handle-entity-change)
      (supertag-automation-sync-enable)
      (cl-letf (((symbol-function 'supertag-rule-execute)
                 (lambda (&rest _) (cl-incf count))))
        (supertag-service-org-set-property "document-node" "K" "v")
        (should (= count 1))
        (supertag-automation-sync-disable)
        (supertag-service-org-set-property "document-node" "K" "disabled")
        (should (= count 1)))
      (should-not supertag-after-operation-hook))))

(ert-deftest supertag-property-consumers-node-view ()
  (supertag-document-test-with-vault
    (supertag-test-legacy-value "document-node" "LEGACY_ONLY" "hidden")
    (supertag-view-node-open "document-node")
    (with-current-buffer supertag-view-node--buffer-name
      (should (string-match-p "ALPHA[ \t]+first" (buffer-string)))
      (should-not (string-match-p "LEGACY_ONLY\\|No fields defined" (buffer-string)))
      (should-not (text-property-not-all (point-min) (point-max) 'field-name nil)))))
(ert-deftest supertag-property-consumers-auto-columns ()
  (supertag-document-test-with-vault
    (supertag-service-org-set-property "document-node" "STATUS" "active")
    (dolist (operator '(property field))
      (with-current-buffer (find-file-noselect plain)
        (goto-char (point-max))
        (insert (format "\n#+BEGIN: supertag-query :query \"(%s \\\"status\\\" \\\"active\\\")\"\n#+END:\n" operator))
        (search-backward "#+BEGIN:")
        (org-dblock-update)
        (should (string-match-p "| STATUS" (buffer-string)))
        (should (string-match-p "| active" (buffer-string)))
        (erase-buffer)))))

(ert-deftest supertag-property-consumers-init-once ()
  (supertag-document-test-with-vault
    (let ((supertag-automation--subscribed nil)
          (supertag-automation-sync--enabled t) (count 0))
      (supertag-automation-create
       '(:name "Init once" :trigger :on-property-change :condition (property-changed "K")
         :actions ((:action :call-function :function ignore))))
      (supertag-automation-init)
      (supertag-automation-init)
      (cl-letf (((symbol-function 'supertag-rule-execute) (lambda (&rest _) (cl-incf count))))
        (supertag-service-org-set-property "document-node" "K" "v"))
      (should (= 1 count)))))

(ert-deftest supertag-property-consumers-formula-values ()
  (let ((node '(:id "formula" :properties (:ABC "abc" :N "3.5"))))
    (should-not (supertag-formula-evaluate "missing" node))
    (should (equal "abc" (supertag-formula-evaluate "abc" node)))
    (should-not (supertag-formula-evaluate "missing + 1" node))
    (should-not (supertag-formula-evaluate "abc * 2" node))
    (should (= 4.5 (supertag-formula-evaluate "n + 1" node)))))

(ert-deftest supertag-property-consumers-formula-error-boundary ()
  (should-error
   (supertag-formula-evaluate "x + 1" nil
                              (lambda (_) (signal 'wrong-type-argument '(numberp broken))))
   :type 'wrong-type-argument)
  (dolist (formula '("missing - 1" "missing / 1" "1 / missing" "-missing"))
    (should-not (supertag-formula-evaluate formula nil)))
  (should (= 0 (supertag-formula-evaluate "1 / 0" nil)))
  (should-error (supertag-formula-evaluate "(" nil)))

(ert-deftest supertag-property-consumers-api-properties-json ()
  (supertag-document-test-with-vault
    (let* ((node (supertag-api-node "document-node"))
           (properties (plist-get node :properties))
           (json (json-parse-string
                  (json-serialize (supertag-api--json-value node)))))
      (should (equal "first" (plist-get properties :ALPHA)))
      (should (equal "last" (plist-get properties :ZETA)))
      (should (hash-table-p (gethash "properties" json)))
      (should (equal "first" (gethash "ALPHA" (gethash "properties" json))))
      (should (equal "last" (gethash "ZETA" (gethash "properties" json))))
      (should (eq :null (plist-get (supertag-api--json-value '(:properties nil)) :properties))))))

(provide 'property-consumers-test)

(ert-deftest supertag-property-consumers-query-b-automation ()
  "Warm real projection and Tag lookup; evaluator remains real at error seams."
  (supertag-document-test-with-vault
    (let ((supertag-automation--event-queue nil)
          (supertag-automation--processing-timer nil))
      (unwind-protect
          (progn
            (supertag-service-org-set-property "document-node" "X" "2")
            (supertag-tag-create '(:id "qb-tag" :name "qb-tag"))
            (supertag-tag-update "qb-tag" (lambda (tag) (plist-put tag :properties '(:X "9"))))
            (let ((snapshot (prin1-to-string supertag--store))
                  (disk (supertag-document-test-disk file))
                  (live (with-current-buffer (find-file-noselect file) (buffer-string)))
                  (dirty (with-current-buffer (find-file-noselect file) (buffer-modified-p))))
              (should (= 3 (supertag-automation--evaluate-formula "x + 1" "document-node")))
              (should-not (supertag-query-node "qb-tag"))
              (should (= 10 (supertag-automation--evaluate-formula "x + 1" "qb-tag")))
              (should-not (supertag-automation-calculate-formula "document-node" '(:name "result")))
              (should (= 3 (supertag-automation-calculate-formula "document-node" '(:name "result" :formula "x + 1"))))
              (should (= 0 (supertag-automation-calculate-formula "document-node" '(:name "result" :formula "x - 2"))))
              (should-not (supertag-automation-calculate-formula "document-node" '(:formula "missing + 1")))
              (should-error (supertag-formula-evaluate "x +" (supertag-query-node "document-node")))
              (should (= 0 (supertag-automation--evaluate-formula "x +" "document-node")))
              (cl-letf (((symbol-function 'supertag-query-node)
                         (lambda (_) (signal 'file-error '("QB lookup")))))
                (should-error (supertag-automation--evaluate-formula "x + 1" "document-node") :type 'file-error)
                (should-error (supertag-automation-calculate-formula "document-node" '(:formula "x + 1")) :type 'file-error))
              (load (expand-file-name "supertag-query.el" (file-name-directory (locate-library "supertag-query"))) nil nil t)
              (should (= 3 (supertag-automation--evaluate-formula "x + 1" "document-node")))
              (should (equal snapshot (prin1-to-string supertag--store)))
              (should (equal disk (supertag-document-test-disk file)))
              (with-current-buffer (find-file-noselect file)
                (should (equal live (buffer-string))) (should (eq dirty (buffer-modified-p))))
              (princ "QUERY-B-DONE automation\n")))
        (when (timerp supertag-automation--processing-timer)
          (cancel-timer supertag-automation--processing-timer))))))

;;; AUTOMATION-A: original event/action and independent cold-owner controls.
(defconst supertag-property-consumers-aua--root
  (file-name-directory (directory-file-name (file-name-directory load-file-name))))

(defun supertag-property-consumers-aua--child (name body)
  "Evaluate BODY in an independent source process and retain phase evidence."
  (let* ((tmp (make-temp-file "supertag-aua-child-" t))
         (script (expand-file-name "child.el" tmp))
         (root supertag-property-consumers-aua--root)
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (process-environment (copy-sequence process-environment))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (form
          `(unwind-protect
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
                 (let ((aua-root ,root)
                       (before (equal (getenv "SUPERTAG_AUA_STAGE") "before")))
                   ,body)
                 (princ ,(format "AUA-%s-DONE\n" name)))
             (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil
                   enable-theme-functions nil)
             (mapc #'cancel-timer (append timer-list timer-idle-list)))))
    (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
    (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
    (with-temp-file script
      (insert ";;; -*- lexical-binding: t; -*-\n")
      (prin1 `(condition-case err ,form
                (error (princ (format "AUA-ERROR %S\n" err)) (kill-emacs 1))) (current-buffer)))
    (unwind-protect
        (with-temp-buffer
          (let* ((exit (apply #'call-process program nil t nil
                              (append '("-Q" "--batch")
                                      (apply #'append (mapcar (lambda (dir) (list "-L" dir)) deps))
                                      (list "-L" root "-l" script))))
                 (output (buffer-string))
                 (evidence (getenv "SUPERTAG_AUA_EVIDENCE")))
            (when evidence
              (make-directory evidence t)
              (copy-file script (expand-file-name (concat name ".el") evidence) t)
              (with-temp-file (expand-file-name (concat name ".log") evidence) (insert output))
              (with-temp-file (expand-file-name (concat name ".exit") evidence) (prin1 exit (current-buffer))))
            (princ output)
            (unless (and (equal exit 0) (string-match-p (concat "AUA-" name "-DONE") output))
              (ert-fail (format "AUA-%s exit=%S\n%s" name exit output)))))
      (delete-directory tmp t))))

(ert-deftest supertag-property-consumers-aua-cold-init ()
  (supertag-property-consumers-aua--child
   "init"
   '(progn
      (setq supertag-automation--enabled nil
            supertag-automation-sync--enabled nil
            supertag-automation-sync--batch-size 7
            supertag-automation-sync--async-enabled nil
            supertag-automation-sync--processing-stack '("preset"))
      (let ((inits 0) (subscriptions 0) (callbacks 0))
        (advice-add 'supertag-automation-init :before (lambda (&rest _) (cl-incf inits)))
        (advice-add 'supertag-subscribe :before
                    (lambda (topic callback)
                      (when (eq callback 'supertag-automation--handle-entity-change)
                        (should (eq topic :store-changed)) (cl-incf subscriptions))))
        (require 'supertag-automation)
        (princ "AUA-init-ENTRY\n")
        (should (= inits 1)) (should (= subscriptions 1))
        (should supertag-automation--enabled)
        (should-not supertag-automation-sync--enabled)
        (should-not supertag-automation-sync--async-enabled)
        (should (= supertag-automation-sync--batch-size 7))
        (should (equal supertag-automation-sync--processing-stack '("preset")))
        (should (hash-table-p supertag--rule-index))
        (should (fboundp 'supertag-scheduler-register-task))
        (should-not (autoloadp (symbol-function 'supertag-scheduler-register-task)))
        (should (equal "supertag-automation.el"
                       (file-name-nondirectory
                        (symbol-file 'supertag-scheduler-register-task 'defun))))
        (let ((cell (symbol-function 'supertag-automation-sync-handle-event)))
          (require 'supertag-automation)
          (should (eq cell (symbol-function 'supertag-automation-sync-handle-event)))
          (should (= inits 1)))
        (setq supertag-automation--enabled nil supertag-automation--processing-queue t)
        (load (expand-file-name "supertag-automation.el" aua-root) nil nil t)
        (should (= inits 2)) (should (= subscriptions 1))
        (should supertag-automation--enabled) (should-not supertag-automation--processing-queue)
        (should (= 1 (cl-count 'supertag-automation--handle-entity-change
                              (gethash :store-changed supertag--subscribers))))
        (advice-add 'supertag-automation--handle-entity-change :before
                    (lambda (&rest _) (cl-incf callbacks)))
        (supertag-store-put-entity :automations "aua-cold" '(:id "aua-cold" :enabled nil) t)
        (should (= callbacks 1))
        (princ (format "AUA-INIT inits=%s subscriptions=%s callbacks=%s\n" inits subscriptions callbacks))))))

(ert-deftest supertag-property-consumers-aua-entry-owner ()
  "Always assert the new owner, so the original production entry is red."
  (supertag-property-consumers-aua--child
   "owner"
   '(progn
      (require 'supertag-automation)
      (princ "AUA-owner-ENTRY\n")
      (should-not (file-exists-p (expand-file-name "supertag-automation-sync.el" aua-root)))
      (should-not (featurep 'supertag-automation-sync))
      (should-not (cl-find-if (lambda (row) (and (stringp (car row))
                                                (string-match-p "supertag-automation-sync\\.el" (car row)))) load-history))
      (let ((owned 0))
        (mapatoms (lambda (symbol)
                    (when (and (string-prefix-p "supertag-automation-sync-" (symbol-name symbol))
                               (fboundp symbol))
                      (cl-incf owned)
                      (should (equal "supertag-automation.el"
                                     (file-name-nondirectory (symbol-file symbol 'defun)))))))
        (should (= owned 25))))))

(ert-deftest supertag-property-consumers-aua-main-order ()
  (supertag-property-consumers-aua--child
   "main"
   '(let ((events nil))
      (add-hook 'after-load-functions
                (lambda (file)
                  (when (member (file-name-base file)
                                '("supertag-automation" "supertag-services-scheduler" "supertag-services-sync"))
                    (push (file-name-base file) events))))
      (require 'supertag)
      (princ "AUA-main-ENTRY\n")
      (setq events (nreverse events))
      (princ (format "AUA-MAIN order=%S\n" events))
      (should (featurep 'supertag-services-sync))
      (if (or before (equal (getenv "SUPERTAG_AUB_STAGE") "before"))
          (should (featurep 'supertag-services-scheduler))
        (should-not (featurep 'supertag-services-scheduler)))
      (should (= 1 (cl-count "supertag-automation" events :test #'equal)))
      (if (or before (equal (getenv "SUPERTAG_AUB_STAGE") "before"))
          (should (equal events '("supertag-services-sync" "supertag-automation"
                               "supertag-services-scheduler")))
        (should (equal events
                       (if (equal (getenv "SUPERTAG_ORGA_STAGE") "before")
                           '("supertag-services-sync" "supertag-automation")
                         '("supertag-automation" "supertag-services-sync"))))))))

(defun supertag-property-consumers-aua--dynamic-write ()
  "Run a real saved projection, event-sensitive rule and saved Org action."
  (supertag-document-test-with-vault
    (let ((supertag-automation--enabled t) (supertag-automation-sync--enabled t)
          (supertag-automation--executing nil) (supertag-automation-sync--processing-stack nil)
          (supertag-automation--current-event '(:outer t)) (events nil) (writes 0))
      (supertag-subscribe :store-changed #'supertag-automation--handle-entity-change)
      (supertag-automation-create
       '(:name "AUA dynamic" :trigger :on-property-change :condition (property-changed "STAGE")
         :actions ((:action :update-property :params (:property "RESULT" :value "matched")))) )
      (let ((observer (lambda (real condition node-id)
                        (when (equal condition '(property-changed "STAGE"))
                          (push (copy-tree supertag-automation--current-event) events))
                        (funcall real condition node-id))))
        (advice-add 'supertag-automation--evaluate-condition :around observer)
        (unwind-protect
            (cl-letf (((symbol-function 'save-buffer)
                       (let ((real (symbol-function 'save-buffer)))
                         (lambda (&rest args) (cl-incf writes) (apply real args)))))
              (supertag-document-test-save-property file "STAGE" "go")
              (supertag-document-test-drain))
          (advice-remove 'supertag-automation--evaluate-condition observer)))
      (princ (format "AUA-DYNAMIC-EXECUTED writes=%s events=%S\n" writes events))
      (should (= writes 2))
      (should (equal "matched" (plist-get (plist-get (supertag-node-get "document-node") :properties) :RESULT)))
      (should (string-match-p ":RESULT:[ \t]+matched" (supertag-document-test-disk file)))
      (should (member '(:path (:nodes "document-node" :properties :STAGE) :old nil :new "go") events))
      (should (equal supertag-automation--current-event '(:outer t)))
      ;; A named action error escapes the real event-condition/action chain.
      (let ((rule (list :enabled t :trigger :on-property-change :condition '(property-changed "STAGE")
                        :actions (list (list :action :call-function :params
                                             (list :function (lambda (&rest _) (error "AUA injected action"))))))))
        (should-error (supertag-automation-sync--execute-rule-for-event
                       rule "document-node" '(:path (:nodes "document-node" :properties :STAGE) :old "go" :new "next")))
        (should (equal supertag-automation--current-event '(:outer t))))
      (princ "AUA-DYNAMIC-DONE\n"))))

(ert-deftest supertag-property-consumers-aua-dynamic-write ()
  (supertag-property-consumers-aua--dynamic-write))

(ert-deftest supertag-property-consumers-aua-tag-delta ()
  (supertag-document-test-with-vault
    (let ((supertag-automation--enabled t) (supertag-automation-sync--enabled t)
          (supertag-automation--executing nil) (supertag-automation-sync--processing-stack nil)
          (seen nil))
      (supertag-tag-create '(:id "aua-tag" :name "aua-tag"))
      (supertag-subscribe :store-changed #'supertag-automation--handle-entity-change)
      (dolist (op '(:on-tag-added :on-tag-removed))
        (supertag-automation-create
         (list :name (symbol-name op) :trigger (list op "aua-tag")
               :condition (if (eq op :on-tag-added) '(has-tag "aua-tag") '(not (has-tag "aua-tag")))
               :actions (list (list :action :call-function :params
                                    (list :function (lambda (_node context) (push context seen))))))))
      (supertag-service-org-add-tag "document-node" "aua-tag")
      (supertag-service-org-remove-tag "document-node" "aua-tag")
      (princ (format "AUA-TAG actual=%S\n" seen))
      ;; Each condition reads the real post-edit facts, including removal.
      (should (equal (reverse seen) '((:tag-event :added :tag "aua-tag")
                                      (:tag-event :removed :tag "aua-tag"))))
      (setq supertag-automation-sync--enabled nil)
      (supertag-service-org-add-tag "document-node" "aua-tag")
      (should (= 2 (length seen)))
      (should (member "aua-tag" (plist-get (supertag-node-get "document-node") :tags))))))

(ert-deftest supertag-property-consumers-aua-queue-protocols ()
  (let ((supertag-automation--event-queue nil) (supertag-automation--processing-timer nil)
        (supertag-automation-sync--async-enabled t) (seen nil) (timers nil))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat callback &rest args)
                 (push (cons callback args) timers) 'aua-timer)))
      (supertag-automation--queue-event (lambda (x) (push x seen)) 'first)
      (supertag-automation--queue-event (lambda (x) (push x seen)) 'second)
      (should (= 1 (length timers)))
      (apply (caar timers) (cdar timers))
      (should (equal (reverse seen) '(first second)))
      (should-not supertag-automation--event-queue) (should-not supertag-automation--processing-timer)
      (setq seen nil timers nil)
      (supertag-automation--queue-event (lambda () (error "AUA legacy")))
      (supertag-automation--queue-event (lambda () (push 'unreachable seen)))
      (should-error (apply (caar timers) (cdar timers)))
      (should-not seen) (should-not supertag-automation--event-queue)
      (setq timers nil)
      (supertag-automation-sync--queue-async-handler (lambda () (push 'first seen)))
      (supertag-automation-sync--queue-async-handler (lambda () (error "AUA thunk")))
      (supertag-automation-sync--queue-async-handler (lambda () (push 'last seen)))
      (should (= 1 (length timers)))
      (apply (caar timers) (cdar timers))
      (should (equal (reverse seen) '(first last)))
      (should-not supertag-automation--event-queue) (should-not supertag-automation--processing-timer))))

(ert-deftest supertag-property-consumers-aua-dispatch-and-reset ()
  (supertag-document-test-with-vault
    (let ((supertag-automation--enabled t) (supertag-automation-sync--enabled t)
          (supertag-automation-sync--async-enabled t) (supertag-automation-sync--batch-size 0)
          (supertag-automation-sync--processing-stack nil) (supertag-automation--executing nil)
          (supertag-automation--event-queue nil) (supertag-automation--processing-timer nil)
          (calls 0) (id "document-node") (timers nil))
      (supertag-automation-create
       (list :name "AUA dispatch" :trigger :on-property-change :condition '(property-changed "K")
             :actions (list (list :action :call-function :params
                                  (list :function (lambda (&rest _) (cl-incf calls)))))))
      (cl-labels ((dispatch ()
                    (supertag-automation-sync-handle-event :update :nodes id
                      '(:properties (:K "new")) '(:properties (:K "old")))))
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_time _repeat callback &rest args)
                     (push (cons callback args) timers) 'aua-timer)))
          (dispatch) (should (= calls 1)) (should-not timers)
          (let ((supertag-automation-sync--processing-stack '("other")))
            (dispatch) (should (= calls 1)) (should (= 1 (length supertag-automation--event-queue))))
          (apply (caar timers) (cdar timers)) (should (= calls 2))
          (let ((supertag-automation-sync--processing-stack '("other"))
                (supertag-automation-sync--async-enabled nil))
            (dispatch) (should (= calls 3)))
          (let ((supertag-automation-sync--async-enabled nil))
            (supertag-automation-sync--with-protection id #'dispatch)
            (should (= calls 3)))
          (should-error (supertag-automation-sync--with-protection id (lambda () (error "AUA protected"))))
          (should-not supertag-automation-sync--processing-stack)))
      (let ((timer (run-at-time 600 nil #'ignore)))
        (setq supertag-automation--processing-timer timer
              supertag-automation--event-queue '(pending)
              supertag-automation--current-event '(:pending t)
              supertag-automation-sync--processing-stack '(pending))
        (supertag-automation--reset-runtime)
        (should-not (memq timer timer-list))
        (should-not supertag-automation--event-queue)
        (should-not supertag-automation--current-event)
        (should supertag-automation-sync--processing-stack)
        (supertag-automation-sync--reset-runtime)
        (should-not supertag-automation-sync--processing-stack)))))

;;; AUTOMATION-B: Scheduler ownership, actual first registration and state.
(ert-deftest supertag-property-consumers-aub-first-registration ()
  (supertag-property-consumers-aua--child
   "aub-first"
   '(let ((registry (make-hash-table :test 'equal)) (output nil) (inits 0))
      (require 'supertag-core-store)
      (supertag--ensure-store)
      (supertag-store-put-entity
       :automations "aub-first"
       (list :id "aub-first" :name "AUB first" :trigger :on-schedule :enabled t
             :schedule '(:time "00:00") :condition nil
             :actions (list (list :action :call-function :params
                                  (list :function (lambda (_node context) (push context output)))))))
      (puthash 'aub-first '(:last-run "prebound") registry)
      (puthash 'unrelated '(:type :daily :time "23:59" :last-run "kept") registry)
      (setq supertag-scheduler--tasks registry supertag-scheduler--master-timer nil
            supertag-scheduler--state-file "prebound-path" supertag-scheduler-check-interval 17)
      (advice-add 'supertag-automation-init :before (lambda (&rest _) (cl-incf inits)))
      (require 'supertag-automation)
      (princ "AUB-FIRST-ENTRY\n")
      (should (= inits 1)) (should (eq registry supertag-scheduler--tasks))
      ;; Must be produced by the original unique load-init, not by this test.
      (should (functionp (plist-get (gethash 'aub-first registry) :function)))
      (should (equal "prebound" (plist-get (gethash 'aub-first registry) :last-run)))
      (should (equal "kept" (plist-get (gethash 'unrelated registry) :last-run)))
      (should (equal "prebound-path" supertag-scheduler--state-file))
      (should (= 17 supertag-scheduler-check-interval)) (should-not supertag-scheduler--master-timer)
      (let ((now (encode-time 0 0 12 8 9 2026)))
        (cl-letf (((symbol-function 'current-time) (lambda () now)))
          (supertag-scheduler--check-tasks)))
      (princ (format "AUB-TICK-EXECUTED output=%S\n" output))
      (should (equal output '((:scheduled t :rule "aub-first"))))
      (let ((cell (symbol-function 'supertag-scheduler-register-task))
            (task (gethash 'aub-first registry)))
        (require 'supertag-automation)
        (should (= inits 1)) (should (eq cell (symbol-function 'supertag-scheduler-register-task)))
        (should (eq task (gethash 'aub-first registry)))
        (let ((timer (run-at-time 600 nil #'ignore)))
          (setq supertag-scheduler--master-timer timer)
          (load (expand-file-name "supertag-automation.el" aua-root) nil nil t)
          (should (eq timer supertag-scheduler--master-timer))
          (should (memq timer timer-list)))
        (should (= inits 2)) (should (eq registry supertag-scheduler--tasks))
        (should-not (eq task (gethash 'aub-first registry)))
        (should (equal "2026-09-08" (plist-get (gethash 'aub-first registry) :last-run))))
      (should (= 1 (cl-count 'supertag-automation--handle-entity-change
                            (gethash :store-changed supertag--subscribers))))
      (princ "AUB-FIRST-PASS\n"))))

(ert-deftest supertag-property-consumers-aub-entry-owner ()
  (supertag-property-consumers-aua--child
   "aub-owner"
   '(progn
      (require 'supertag-automation)
      (princ "AUB-OWNER-ENTRY\n")
      (should-not (file-exists-p (expand-file-name "supertag-services-scheduler.el" aua-root)))
      (should-not (featurep 'supertag-services-scheduler))
      (should-not (cl-find-if (lambda (item) (and (stringp (car item))
                                                 (string-match-p "supertag-services-scheduler\\.el" (car item)))) load-history))
      (dolist (symbol '(supertag-scheduler--state-path supertag-scheduler--save-state
                       supertag-scheduler--load-state supertag-scheduler-register-task
                       supertag-scheduler-deregister-task supertag-scheduler-start supertag-scheduler-stop
                       supertag-scheduler-list-tasks supertag-scheduler--check-tasks
                       supertag-scheduler--run-task supertag-scheduler--reset-runtime))
        (should (equal "supertag-automation.el" (file-name-nondirectory (symbol-file symbol 'defun))))) )))

(ert-deftest supertag-property-consumers-aub-old-entry-and-crud ()
  (supertag-property-consumers-aua--child
   "aub-crud"
   '(let ((output nil))
      (require 'supertag-automation)
      (princ "AUB-CRUD-ENTRY\n")
      (let* ((rule (supertag-automation-create
                    (list :name "AUB CRUD" :trigger :on-schedule :enabled t :schedule '(:time "00:00")
                          :actions (list (list :action :call-function :params
                                               (list :function (lambda (&rest _) (push 'old output))))))))
             (id (plist-get rule :id)) (key (intern id))
             (old-runner (plist-get (gethash key supertag-scheduler--tasks) :function)))
        (should (functionp old-runner))
        (supertag-automation-update
         id (lambda (current)
              (plist-put current :actions
                         (list (list :action :call-function :params
                                     (list :function (lambda (&rest _) (push 'updated output))))
                               '(:action :update-property :params (:property "FORBIDDEN" :value "ignored"))))))
        ;; The previously captured task must read the updated rule, not stale actions.
        (funcall old-runner) (should (equal output '(updated)))
        (supertag-automation-update id (lambda (current) (plist-put current :enabled nil)))
        (funcall old-runner) (should (equal output '(updated)))
        (supertag-automation-delete id)
        (should-not (gethash key supertag-scheduler--tasks))
        (funcall old-runner) (should (equal output '(updated))))
      (should-error (supertag-scheduler-register-task 'invalid :interval #'ignore :interval 0))
      (should-not (gethash 'invalid supertag-scheduler--tasks))
      ;; The original bridge catches invalid schedule errors; no task is inserted.
      (supertag-automation--register-scheduled-rule '(:id "bad-bridge" :trigger :on-schedule :schedule (:time "bad")))
      (should-not (gethash 'bad-bridge supertag-scheduler--tasks)))))

(ert-deftest supertag-property-consumers-aub-json-timer-boundaries ()
  (supertag-property-consumers-aua--child
   "aub-json"
   '(progn
      (require 'supertag-automation)
      (princ "AUB-JSON-ENTRY\n")
      (let ((path (supertag-scheduler--state-path)) (now '(27295 12345 0 0)) (loads 0))
        (supertag-scheduler-register-task 'daily :daily #'ignore :time "00:00")
        (supertag-scheduler-register-task 'interval :interval #'ignore :interval 30)
        (plist-put (gethash 'daily supertag-scheduler--tasks) :last-run "2026-09-07")
        (plist-put (gethash 'interval supertag-scheduler--tasks) :last-run now)
        (supertag-scheduler--save-state)
        (clrhash supertag-scheduler--tasks)
        (supertag-scheduler-register-task 'daily :daily #'ignore :time "00:00")
        (supertag-scheduler-register-task 'interval :interval #'ignore :interval 30)
        (supertag-scheduler--load-state)
        (should (equal "2026-09-07" (plist-get (gethash 'daily supertag-scheduler--tasks) :last-run)))
        (should (equal now (plist-get (gethash 'interval supertag-scheduler--tasks) :last-run)))
        (with-temp-file path (insert "{\"unknown\":\"not-a-task\"}"))
        (supertag-scheduler--load-state) (should (= 2 (hash-table-count supertag-scheduler--tasks)))
        (with-temp-file path (insert "")) (supertag-scheduler--load-state)
        (delete-file path) (supertag-scheduler--load-state)
        (with-temp-file path (insert "{"))
        (should-error (supertag-scheduler-start)) (should-not supertag-scheduler--master-timer)
        (with-temp-file path (insert "{}"))
        (advice-add 'supertag-scheduler--load-state :before (lambda (&rest _) (cl-incf loads)))
        (cl-letf (((symbol-function 'run-with-timer)
                   (let ((real (symbol-function 'run-with-timer)))
                     (lambda (_initial repeat callback &rest args)
                       (apply real 600 repeat callback args)))))
          (supertag-scheduler-start) (supertag-scheduler-start))
        (should (= loads 1))
        (let ((timer supertag-scheduler--master-timer))
          (cl-letf (((symbol-function 'write-file)
                     (lambda (&rest _) (error "AUB named save IO"))))
            (should-error (supertag-scheduler-stop)))
          (should-not (memq timer timer-list)) (should-not supertag-scheduler--master-timer))
        (let ((saved (with-temp-buffer (insert-file-contents path) (buffer-string))))
          (supertag-scheduler-stop)
          (should (equal saved (with-temp-buffer (insert-file-contents path) (buffer-string))))
          (setq supertag-scheduler--master-timer (run-at-time 600 nil #'ignore))
          (let ((timer supertag-scheduler--master-timer))
            (supertag-scheduler--reset-runtime)
            (should-not (memq timer timer-list)))
          (should (= 0 (hash-table-count supertag-scheduler--tasks)))
          (should (equal saved (with-temp-buffer (insert-file-contents path) (buffer-string)))))
        ;; Task function error is caught, but daily IO error propagates AFTER last-run update.
        (let ((task (list :type :daily :function (lambda () (error "AUB task error")))))
          (cl-letf (((symbol-function 'write-file) (lambda (&rest _) (error "AUB daily save"))))
            (should-error (supertag-scheduler--run-task 'daily task now)))
          (should (equal (format-time-string "%Y-%m-%d" now) (plist-get task :last-run)))
          (should (eq task (gethash 'daily supertag-scheduler--tasks))))
        (let ((task (list :type :interval :function (lambda () (error "AUB interval error")))))
          (cl-letf (((symbol-function 'write-file) (lambda (&rest _) (error "must not save interval"))))
            (supertag-scheduler--run-task 'interval task now))
          (should (equal now (plist-get task :last-run))))
        (clrhash supertag-scheduler--tasks)
        (let ((calls nil) (clock (encode-time 0 0 12 8 9 2026)))
          (supertag-scheduler-register-task 'daily :daily (lambda () (push 'daily calls)) :time "12:00")
          (supertag-scheduler-register-task 'interval :interval (lambda () (push 'interval calls)) :interval 30)
          (cl-letf (((symbol-function 'current-time) (lambda () clock)))
            (supertag-scheduler--check-tasks)
            (should (equal calls '(interval)))
            (supertag-scheduler--check-tasks) (should (equal calls '(interval)))
            (setq clock (encode-time 0 1 12 8 9 2026))
            (supertag-scheduler--check-tasks)
            (should (= 1 (cl-count 'daily calls))) (should (= 2 (cl-count 'interval calls)))
            (supertag-scheduler-register-task 'daily :daily (lambda () (push 'wrong-day calls))
                                              :time "00:00" :days-of-week '(3))
            (supertag-scheduler--check-tasks)
            (should-not (memq 'wrong-day calls))))))))

(ert-deftest supertag-property-consumers-aub-main-late-store ()
  (supertag-property-consumers-aua--child
   "aub-late"
   '(progn
      ;; Real Sync state satisfies the persistence guard, without loading Automation/main.
      (require 'supertag-core-persistence)
      (require 'supertag-services-sync)
      (supertag-sync-load-state)
      (supertag-load-store)
      (supertag-store-put-entity :automations "aub-late"
        '(:id "aub-late" :name "Late" :trigger :on-schedule :enabled t :schedule (:time "00:00")
          :actions ((:action :call-function :params (:function ignore)))))
      (supertag-mark-dirty) (should (supertag-save-store))
      (should (file-exists-p supertag-db-file))
      (setq supertag--store nil supertag--store-origin nil supertag-sync-auto-start nil)
      (should-not (featurep 'supertag-automation))
      (require 'supertag)
      (princ "AUB-LATE-ENTRY empty-memory main\n")
      (should-not (supertag-automation-get "aub-late"))
      (should (= 0 (hash-table-count supertag-scheduler--tasks)))
      (should (= 1 (cl-count 'supertag-automation--after-store-load
                             supertag-persistence-after-load-hook)))
      (load (expand-file-name "supertag-automation.el" aua-root) nil nil t)
      (should (= 1 (cl-count 'supertag-automation--after-store-load
                             supertag-persistence-after-load-hook)))
      (let ((order nil))
        (advice-add 'supertag-load-store :after (lambda (&rest _) (push 'load order)))
        (advice-add 'supertag-rebuild-rule-index :after (lambda (&rest _) (push 'index order)))
        (advice-add 'supertag-automation--register-all-scheduled :after (lambda (&rest _) (push 'register order)))
        (advice-add 'supertag-scheduler-start :after (lambda (&rest _) (push 'start order)))
        (cl-letf (((symbol-function 'run-with-timer)
                   (let ((real (symbol-function 'run-with-timer)))
                     (lambda (_initial repeat callback &rest args) (apply real 600 repeat callback args)))))
          (supertag-init))
        (princ (format "AUB-LATE-EXECUTED order=%S rules=%S tasks=%s\n"
                       (reverse order) (supertag-automation-get "aub-late") (hash-table-count supertag-scheduler--tasks)))
        (should (supertag-automation-get "aub-late"))
        (should (memq 'load order)) (should (memq 'index order)) (should (memq 'start order))
        (should (memq 'register order))
        (should (= 1 (hash-table-count supertag-scheduler--tasks)))
        (should (timerp supertag-scheduler--master-timer))))))
