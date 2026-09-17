;;; vault-test.el --- Multi-vault isolation contracts -*- lexical-binding: t; -*-
(require 'ert)
(require 'supertag)

(ert-deftest supertag-vault-reset-clears-runtime-state ()
  (setq supertag-ui--node-cache '("old")
        supertag-automation--event-queue '(old)
        supertag-automation--processing-queue '(old)
        supertag-automation-sync--processing-stack '(old)
        supertag-migrate--last-error "old"
        supertag-migrate--last-snapshot "old")
  (clrhash supertag-ai--candidates)
  (puthash "old" t supertag-ai--candidates)
  (supertag-ui--reset-runtime)
  (supertag-automation--reset-runtime)
  (supertag-automation-sync--reset-runtime)
  (supertag-ai--reset-runtime)
  (supertag-migrate--reset-runtime)
  (should-not supertag-ui--node-cache)
  (should-not supertag-automation--event-queue)
  (should-not supertag-automation--processing-queue)
  (should-not supertag-automation-sync--processing-stack)
  (should-not supertag-migrate--last-error)
  (should-not supertag-migrate--last-snapshot)
  (should (= 0 (hash-table-count supertag-ai--candidates))))

(ert-deftest supertag-vault-guard-rejects-manual-path-change ()
  (let ((supertag--initialized t)
        (supertag--config-guard-enabled t)
        (supertag--config-guard-allow nil)
        (supertag--config-guard-state '(:active-sync-directory "/old"))
        (supertag-active-sync-directory "/old"))
    (should-error
     (supertag-config-guard--watch 'supertag-active-sync-directory "/new" 'set nil))))

(ert-deftest supertag-vault-git-mode-rejects-activation ()
  (let ((supertag-sync-directories-mode 'vaults)
        (supertag-git-sync-mode t)
        (supertag-vault--current '(:id "a")))
    (should-error (supertag-vault-activate '(:id "b" :root "/tmp")))))

(ert-deftest supertag-vault-save-failure-preserves-active-state ()
  (let ((supertag-sync-directories-mode 'vaults)
        (supertag-git-sync-mode nil)
        (supertag-vault--current '(:id "a" :root "/tmp/a"))
        (stopped nil))
    (cl-letf (((symbol-function 'supertag-vault--persist-current)
               (lambda () (user-error "save failed")))
              ((symbol-function 'supertag-sync-stop-auto-sync)
               (lambda () (setq stopped t))))
      (should-error (supertag-vault-activate '(:id "b" :root "/tmp/b")))
      (should (equal "a" (plist-get supertag-vault--current :id)))
      (should-not stopped))))

(ert-deftest supertag-vault-state-paths-follow-active-data-directory ()
  (let ((supertag-data-directory supertag-data-directory)
        (supertag--config-guard-allow t))
    (supertag-config-guard--with-allow
      (setq supertag-data-directory (make-temp-file "supertag-vault-a-" t)))
    (let ((scheduler-a (supertag-scheduler--state-path))
          (history-a (supertag-discovery--history-path)))
      (supertag-config-guard--with-allow
        (setq supertag-data-directory (make-temp-file "supertag-vault-b-" t)))
      (should-not (equal scheduler-a (supertag-scheduler--state-path)))
      (should-not (equal history-a (supertag-discovery--history-path))))))

(ert-deftest supertag-vault-node-view-refreshes-to-empty-state ()
  (require 'supertag-view-node)
  (let ((buf (get-buffer-create supertag-view-node--buffer-name)))
    (unwind-protect
        (with-current-buffer buf
          (setq supertag-view--instance t
                supertag-view-node--current-node-id "from-other-vault")
          (cl-letf (((symbol-function 'supertag-node-get) (lambda (_) nil)))
            (supertag-view-node--refresh-view)
            (should (string-match-p "not available in this vault"
                                    (buffer-string)))))
      (kill-buffer buf))))

(ert-deftest supertag-vault-save-store-refusal-does-not-switch ()
  (let ((supertag-sync-directories-mode 'vaults)
        (supertag-git-sync-mode nil)
        (supertag-vault--current '(:id "a" :root "/tmp/a"))
        (supertag--store-origin '(:status :failed))
        (dirty t))
    (cl-letf (((symbol-function 'supertag-dirty-p) (lambda () dirty))
              ((symbol-function 'supertag-save-store)
               (lambda () "save refused"))
              ((symbol-function 'supertag-scheduler-stop) #'ignore))
      (should-error (supertag-vault-activate '(:id "b" :root "/tmp/b")))
      (should (equal "a" (plist-get supertag-vault--current :id))))))

(ert-deftest supertag-vault-discovery-history-clears-at-boundary ()
  (require 'supertag-discovery)
  (let* ((dir (make-temp-file "supertag-vault-history-" t))
         (supertag-discovery-history-file
          (expand-file-name "history.el" dir))
         (supertag-discovery--history '((:query "only-a")))
         )
    (supertag-discovery--save-history)
    (setq supertag-discovery--history '((:query "stale-a")))
    (supertag-discovery--reset-runtime)
    (should-not supertag-discovery--history)))

(ert-deftest supertag-vault-automation-reset-cancels-processing-timer ()
  (require 'supertag-automation)
  (let ((timer (run-at-time 3600 nil #'ignore)))
    (setq supertag-automation--processing-timer timer)
    (supertag-automation--reset-runtime)
    (should-not (timerp supertag-automation--processing-timer))
    (should-not (memq timer timer-list))))

(ert-deftest supertag-vault-scheduler-reset-cancels-and-clears ()
  (require 'supertag-automation)
  (puthash 'vault-test '(:type :daily :time "00:00") supertag-scheduler--tasks)
  (let ((timer (run-at-time 3600 nil #'ignore)))
    (setq supertag-scheduler--master-timer timer)
    (supertag-scheduler--reset-runtime)
    (should-not (timerp supertag-scheduler--master-timer))
    (should (= 0 (hash-table-count supertag-scheduler--tasks)))
    (should-not (memq timer timer-list))))

(ert-deftest supertag-vault-scheduler-state-roundtrip-uses-current-vault ()
  (require 'supertag-automation)
  (let ()
    (puthash 'vault-rule (list :type :daily :time "00:00"
                               :last-run "2026-09-01")
             supertag-scheduler--tasks)
    (supertag-scheduler--save-state)
    (clrhash supertag-scheduler--tasks)
    (puthash 'vault-rule (list :type :daily :time "00:00")
             supertag-scheduler--tasks)
    (supertag-scheduler--load-state)
    (should (equal "2026-09-01"
                   (plist-get (gethash 'vault-rule supertag-scheduler--tasks)
                              :last-run)))))

(ert-deftest supertag-vault-activate-save-precedes-scheduler-stop ()
  (let ((order nil))
    (cl-letf (((symbol-function 'supertag-vault--persist-current)
               (lambda () (setq order (append order '(save)))))
              ((symbol-function 'supertag-vault--reset-runtime)
               (lambda () (setq order (append order '(reset)))))
              ((symbol-function 'supertag-vault--vault-mode-p) (lambda () t))
              ((symbol-function 'supertag-vault--current-id) (lambda () "a")))
      (let ((supertag-vault--current '(:id "a"))
            (supertag-sync-directories-mode 'vaults)
            (supertag-git-sync-mode nil))
        (should-error (supertag-vault-activate '(:id "b" :root "/tmp/b"))))
      (should (eq (car order) 'save)))))

(ert-deftest supertag-vault-real-two-vault-scheduler-roundtrip ()
  "Activation loads each vault's scheduler state without cross-vault leakage."
  (let* ((supertag--config-guard-enabled nil)
         (supertag--config-guard-allow t)
         (root-a (make-temp-file "supertag-vault-a-root-" t))
         (root-b (make-temp-file "supertag-vault-b-root-" t))
         (data-a (make-temp-file "supertag-vault-a-data-" t))
         (data-b (make-temp-file "supertag-vault-b-data-" t))
         (vault-a (list :id "a" :root root-a :data-directory data-a))
         (vault-b (list :id "b" :root root-b :data-directory data-b))
         (supertag-sync-directories-mode 'vaults)
         (supertag-sync-directories (list root-a root-b))
         (supertag-git-sync-mode nil)
         (supertag-sync-auto-start nil)
         (supertag-vault--current nil)
         (order nil))
    (let ((persist-advice (lambda (&rest _)
                            (setq order (append order '(persist)))))
          (stop-advice (lambda (&rest _)
                         (setq order (append order '(stop))))))
      (advice-add 'supertag-vault--persist-current :before persist-advice)
      (advice-add 'supertag-scheduler-stop :before stop-advice)
      (unwind-protect
        (progn
          ;; These are real activation and persistence calls; only the order
          ;; probes are advised.
          (supertag-config-guard--with-allow
            (supertag-vault-activate vault-a))
          (supertag-scheduler-register-task 'vault-last-run :daily #'ignore
                                            :time "00:00")
          (plist-put (gethash 'vault-last-run supertag-scheduler--tasks)
                     :last-run "A-last-run")
          (supertag-scheduler--save-state)
          (supertag-config-guard--with-allow
            (supertag-vault-activate vault-b))
          (should-not (file-exists-p
                       (expand-file-name "scheduler-state.json" data-b)))
          (supertag-config-guard--with-allow
            (supertag-vault-activate vault-a))
          (supertag-scheduler-register-task 'vault-last-run :daily #'ignore
                                            :time "00:00")
          (supertag-scheduler--load-state)
          (should (equal "A-last-run"
                         (plist-get (gethash 'vault-last-run
                                             supertag-scheduler--tasks)
                                    :last-run)))
          (should (equal '(persist stop) (seq-take order 2))))
        (advice-remove 'supertag-vault--persist-current persist-advice)
        (advice-remove 'supertag-scheduler-stop stop-advice)
        (when (timerp supertag-scheduler--master-timer)
          (supertag-scheduler-stop))))))

(provide 'vault-test)

;;; AUTOMATION-B: persisted rules, automatic task rebuilding and durable refusal.
(defvar supertag-vault-aub--events nil)
(defun supertag-vault-aub--record (_node context)
  (push (plist-get context :rule) supertag-vault-aub--events))

(ert-deftest supertag-vault-aub-persistent-rules-automatic-roundtrip ()
  (let* ((supertag--config-guard-allow t) (supertag--config-guard-enabled nil)
         (base (make-temp-file "supertag-aub-vaults-" t))
         (root-a (expand-file-name "a/" base)) (root-b (expand-file-name "b/" base))
         (data-a (expand-file-name "data-a/" base)) (data-b (expand-file-name "data-b/" base))
         (a (list :id "aub-a" :root root-a :data-directory data-a))
         (b (list :id "aub-b" :root root-b :data-directory data-b))
         (supertag-data-directory base) (supertag--base-data-directory base)
         (supertag-db-file (expand-file-name "initial.el" base))
         (supertag-db-backup-directory (expand-file-name "backups" base))
         (supertag-sync-state-file (expand-file-name "sync.el" base))
         (supertag-sync--state-source supertag-sync-state-file)
         (supertag-sync--state (list :sync-state (make-hash-table :test 'equal)))
         (supertag-sync-directories-mode 'vaults) (supertag-sync-directories (list root-a root-b))
         (supertag-active-sync-directory nil) (supertag-vault--current nil)
         (supertag-sync-auto-start nil) (supertag-git-sync-mode nil)
         (supertag--store nil) (supertag--store-origin nil)
         (supertag-db--dirty nil) (supertag-db--last-backup-date nil)
         (supertag-scheduler--tasks (make-hash-table :test 'equal))
         (supertag-scheduler--master-timer nil) (supertag-vault-aub--events nil)
         (org-id-locations nil) (org-id-locations-file (expand-file-name "ids" base))
         (org-id-track-globally nil) (order nil) (observers nil) id-a id-b)
    (dolist (root (list root-a root-b))
      (make-directory root t)
      (with-temp-file (expand-file-name "node.org" root)
        (insert (format "* Node\n:PROPERTIES:\n:ID: %s\n:END:\nBody\n" (if (equal root root-a) "aub-node-a" "aub-node-b")))))
    (dolist (pair '((supertag-vault--persist-current . persist) (supertag-scheduler-stop . stop)
                    (supertag-vault--reset-runtime . reset) (supertag-load-store . load)
                    (supertag-automation--register-all-scheduled . register) (supertag-scheduler-start . start)))
      (let* ((name (car pair)) (event (cdr pair))
             (fn (lambda (&rest _) (push (list event supertag-data-directory) order))))
        (push (cons name fn) observers) (advice-add name :before fn)))
    (unwind-protect
        (cl-letf (((symbol-function 'run-with-timer)
                   (let ((real (symbol-function 'run-with-timer)))
                     (lambda (_initial repeat callback &rest args) (apply real 600 repeat callback args)))))
          (supertag-vault-activate a)
          (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
          (setq id-a (plist-get (supertag-automation-create
                                '(:name "AUB A" :trigger :on-schedule :enabled t :schedule (:time "00:00")
                                  :actions ((:action :call-function :params (:function supertag-vault-aub--record))))) :id))
          (plist-put (gethash (intern id-a) supertag-scheduler--tasks) :last-run "A-date")
          (should (supertag-save-store))
          (supertag-vault-activate b)
          (should-not (gethash (intern id-a) supertag-scheduler--tasks))
          (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
          (setq id-b (plist-get (supertag-automation-create
                                '(:name "AUB B" :trigger :on-schedule :enabled t :schedule (:time "00:00")
                                  :actions ((:action :call-function :params (:function supertag-vault-aub--record))))) :id))
          (plist-put (gethash (intern id-b) supertag-scheduler--tasks) :last-run "B-date")
          (should (supertag-save-store))
          (setq order nil)
          (supertag-vault-activate a)
          (princ (format "AUB-VAULT-LOADED A tasks=%S order=%S\n" (hash-table-keys supertag-scheduler--tasks) (reverse order)))
          ;; No manual register or state-load compensation after activate.
          (should (equal "A-date" (plist-get (gethash (intern id-a) supertag-scheduler--tasks) :last-run)))
          (should-not (gethash (intern id-b) supertag-scheduler--tasks))
          (should (equal '(persist stop reset load register start) (mapcar #'car (reverse order))))
          (should (equal data-b (cadr (car (reverse order)))))
          (should (equal data-a (cadr (car order))))
          (should (timerp supertag-scheduler--master-timer))
          (funcall (plist-get (gethash (intern id-a) supertag-scheduler--tasks) :function))
          (should (equal supertag-vault-aub--events (list id-a)))
          (supertag-vault-activate b)
          (should (equal "B-date" (plist-get (gethash (intern id-b) supertag-scheduler--tasks) :last-run)))
          (should-not (gethash (intern id-a) supertag-scheduler--tasks))
          (funcall (plist-get (gethash (intern id-b) supertag-scheduler--tasks) :function))
          (should (equal supertag-vault-aub--events (list id-b id-a)))
          ;; Real persist-current must reject a guarded Store save before stop.
          (supertag-mark-dirty)
          (let ((supertag--store-origin '(:status :failed))
                (timer supertag-scheduler--master-timer))
            (setq order nil)
            (should-error (supertag-vault-activate a) :type 'user-error)
            (should (equal "aub-b" (plist-get supertag-vault--current :id)))
            (should (eq timer supertag-scheduler--master-timer))
            (should (memq timer timer-list))
            (should-not (assq 'stop order)))
          (princ "AUB-VAULT-PASS automatic last-run/actions and real save refusal\n"))
      (dolist (entry observers) (advice-remove (car entry) (cdr entry)))
      (when (timerp supertag-scheduler--master-timer) (cancel-timer supertag-scheduler--master-timer))
      (dolist (buffer (buffer-list))
        (when-let ((path (buffer-file-name buffer)))
          (when (file-in-directory-p path base)
            (with-current-buffer buffer (set-buffer-modified-p nil)) (kill-buffer buffer))))
      (delete-directory base t))))

;;; V2-VAULT-C: independent cold guard/default preparation controls.
(defconst supertag-vault-test--vc-program
  '(progn
     (require 'ert)
     (require 'cl-lib)
     (setq user-emacs-directory (file-name-as-directory vc-tmp)
           default-directory (file-name-as-directory vc-tmp)
           after-init-time nil load-prefer-newer t)
     (let* ((states '(supertag--config-guard-enabled supertag--config-guard-allow
                      supertag--config-guard--reverting supertag--config-guard-state))
            (symbols '(supertag-config-guard--key supertag-config-guard--capture
                       supertag-config-guard--update supertag-config-guard--watch
                       supertag-config-guard-enable supertag-config-guard--with-allow))
            (expected-owner (if vc-before "supertag.el" "supertag-vault.el"))
            (watch-vars '(supertag-data-directory supertag-db-file
                          supertag-db-backup-directory supertag-sync-state-file
                          supertag-sync-directories supertag-active-sync-directory))
            (data (expand-file-name "data/" vc-tmp))
            (next (expand-file-name "next/" vc-tmp))
            (sentinels (mapcar (lambda (s) (list s 'sentinel)) states)))
       (dolist (s states) (should-not (boundp s)))
       (dolist (s '(supertag--base-data-directory supertag-data-directory
                    supertag-sync-directories-mode supertag-sync-directories))
         (should-not (boundp s)))
       (when (eq vc-case 'preset)
         (cl-mapc (lambda (s v) (set s v)) states sentinels))
       (when (and (not vc-before) (not (eq vc-case 'pure-vault)))
         (require 'org) (require 'org-element) (require 'org-id))
       (let ((hooks (mapcar (lambda (s) (and (boundp s) (copy-tree (symbol-value s))))
                            '(emacs-startup-hook kill-emacs-hook org-mode-hook enable-theme-functions)))
             (timers (copy-sequence timer-list)) (idle (copy-sequence timer-idle-list))
             (watchers (mapcar #'get-variable-watchers watch-vars)))
         (require (if (eq vc-case 'pure-vault) 'supertag-vault (if vc-before 'supertag-services-template 'supertag-service-org)))
         (princ (format "VC-PURE-ENTRY %S states=%S functions=%S\n"
                        vc-case (mapcar #'boundp states) (mapcar #'fboundp symbols)))
         (if (eq vc-case 'preset)
             (cl-mapc (lambda (s v) (should (eq v (symbol-value s)))) states sentinels)
           (dolist (s states) (should-not (boundp s))))
         (dolist (s symbols)
           (if vc-before (should-not (fboundp s)) (should (fboundp s))))
         (dolist (f '(supertag supertag-services-sync supertag-core-persistence
                      supertag-node supertag-tag supertag-query document-fixture))
           (should-not (featurep f)))
         (dolist (s '(supertag--base-data-directory supertag-data-directory
                      supertag-sync-directories-mode supertag-sync-directories))
           (should-not (boundp s)))
         (should-not (fboundp 'supertag--effective-sync-directories))
         (should-not (fboundp 'supertag-vault--effective-root))
         (should (equal watchers (mapcar #'get-variable-watchers watch-vars)))
         (should (equal timers timer-list)) (should (equal idle timer-idle-list))
         (should (equal hooks (mapcar (lambda (s) (and (boundp s) (symbol-value s)))
                                     '(emacs-startup-hook kill-emacs-hook org-mode-hook enable-theme-functions)))))
       (cond
        ((memq vc-case '(pure-vault pure-template)) nil)
        ((eq vc-case 'unconfigured)
         (if vc-before
             (princ "VC-BEFORE-PREPARE-UNAVAILABLE\n")
           (supertag-vault--prepare-guard-defaults)
           (dolist (s states) (should (boundp s)) (should-not (symbol-value s)))
           (should-not (boundp 'supertag-data-directory))
           (should-not (boundp 'supertag-db-file))
           (let ((err (should-error (supertag-config-guard--capture) :type 'void-variable)))
             (princ (format "VC-UNCONFIGURED-CAPTURE %S\n" err))
             (should (equal err '(void-variable supertag-data-directory))))
           (let ((err (should-error (supertag-config-guard-enable) :type 'void-variable)))
             (princ (format "VC-UNCONFIGURED-ENABLE %S\n" err))
             (should (equal err '(void-variable supertag-data-directory))))
           (should-not supertag--config-guard-state)
           (should-not supertag--config-guard-enabled)))
        (t
         ;; Real main preinit, isolated configuration AFTER genuinely pure observation.
         (setq supertag-data-directory data
               supertag-db-file (expand-file-name "store.el" vc-tmp)
               supertag-db-backup-directory (expand-file-name "backup/" vc-tmp)
               supertag-sync-state-file (expand-file-name "sync.el" vc-tmp)
               org-id-locations-file (expand-file-name "ids" vc-tmp)
               supertag-sync-directories-mode 'unified supertag-sync-directories nil
               supertag-active-sync-directory nil supertag-sync-auto-start nil
               supertag-vault-auto-switch nil supertag-vault-modeline-indicator nil
               supertag-tag-auto-enable nil)
         (require 'supertag)
         (should-not supertag--initialized)
         (dolist (s watch-vars)
           (should-not (memq 'supertag-config-guard--watch (get-variable-watchers s))))
         (princ (format "VC-MAIN-ENTRY case=%S owner=%S\n" vc-case
                        (symbol-file 'supertag-config-guard--capture 'defun)))
         (dolist (s symbols)
           (should (equal expected-owner (file-name-nondirectory (symbol-file s 'defun)))))
         (if (eq vc-case 'preset)
             (progn
               (cl-mapc (lambda (s v) (should (eq v (symbol-value s)))) states sentinels)
               (load (expand-file-name "supertag.el" vc-root) nil nil t)
               (cl-mapc (lambda (s v) (should (eq v (symbol-value s)))) states sentinels)
               (unless vc-before
                 (supertag-vault--prepare-guard-defaults)
                 (cl-mapc (lambda (s v) (should (eq v (symbol-value s)))) states sentinels))
               (princ "VC-PRESET-RELOAD-PRESERVED\n"))
           (dolist (s states) (should (boundp s)) (should-not (symbol-value s)))
           (supertag-config-guard--capture)
           (princ (format "VC-CAPTURE-ACTUAL %S\n" supertag--config-guard-state))
           (should (equal data (plist-get supertag--config-guard-state :data-directory)))
           (should (equal supertag-db-file (plist-get supertag--config-guard-state :db-file)))
           (let ((state supertag--config-guard-state)
                 (cells (mapcar #'symbol-function symbols)))
             (require (if vc-before 'supertag 'supertag-vault))
             (cl-mapc (lambda (s c) (should (eq c (symbol-function s)))) symbols cells)
             (load (expand-file-name (if vc-before "supertag.el" "supertag-vault.el") vc-root) nil nil t)
             (should (eq state supertag--config-guard-state))
             (princ (format "VC-RELOAD-EQ %S\n"
                            (cl-mapcar (lambda (s c) (eq c (symbol-function s))) symbols cells))))
           (when (memq vc-case '(watcher compiled compile))
             (if (eq vc-case 'compile)
                 (progn
                   (require 'bytecomp)
                   (let ((file (expand-file-name "guard-control.el" vc-tmp)))
                     (with-temp-file file
                       (insert ";;; -*- lexical-binding: t; -*-\n")
                       (prin1 `(require ',(if vc-before 'supertag 'supertag-vault)) (current-buffer))
                       (insert "\n(declare-function supertag--persistence--set-db-file \"supertag-core-persistence\" (path))\n")
                       (prin1 '(defun supertag-vc-compiled-change (path db)
                                 (supertag-config-guard--with-allow
                                   (setq supertag-data-directory path)
                                   (supertag--persistence--set-db-file db)
                                   (error "VC compiled exit"))) (current-buffer)))
                     (should-not (fboundp 'supertag-vc-compiled-change))
                     (should (byte-compile-file file))
                     (should (file-exists-p (concat file "c")))
                     (should-not (fboundp 'supertag-vc-compiled-change))
                     (princ "VC-COMPILED-ONLY-NOT-EVALUATED\n")))
               (setq supertag--initialized t)
               (supertag-config-guard-enable)
               (dolist (s watch-vars)
                 (should (= 1 (cl-count 'supertag-config-guard--watch (get-variable-watchers s)))))
               (let ((old-state supertag--config-guard-state))
                 (supertag-config-guard-enable)
                 (should-not (eq old-state supertag--config-guard-state)))
               (dolist (s watch-vars)
                 (should (= 1 (cl-count 'supertag-config-guard--watch (get-variable-watchers s)))))
               (let ((old-state (copy-tree supertag--config-guard-state)))
                 (should-error (setq supertag-data-directory next) :type 'user-error)
                 (should (equal data supertag-data-directory))
                 (should (equal old-state supertag--config-guard-state))
                 (let ((err (should-error
                             (eval '(let ((supertag-data-directory "VC blocked let"))
                                      supertag-data-directory) t) :type 'user-error)))
                   (princ (format "VC-LET-REJECTION %S value=%S state=%S\n"
                                  err supertag-data-directory supertag--config-guard-state)))
                 (should (equal data supertag-data-directory))
                 (should (equal old-state supertag--config-guard-state)))
               (let ((db (expand-file-name "new-store.el" vc-tmp)))
                 (if (eq vc-case 'compiled)
                     (progn
                       (should-not (fboundp 'supertag-vc-compiled-change))
                       (load (expand-file-name "guard-control.elc" vc-tmp) nil nil t)
                       (should (string-suffix-p "guard-control.elc"
                                                (symbol-file 'supertag-vc-compiled-change 'defun)))
                       (should-error (supertag-vc-compiled-change next db) :type 'error)
                       (princ (format "VC-FRESH-ELC %S\n" (symbol-file 'supertag-vc-compiled-change 'defun))))
                   (should-error
                    (eval `(supertag-config-guard--with-allow
                             (setq supertag-data-directory ,next)
                             (error "VC allowed exit")) t) :type 'error)
                   (should (equal db (supertag--persistence--set-db-file db))))
                 (princ (format "VC-WATCHER-ACTUAL data=%S db=%S expected=%S\n"
                                supertag-data-directory supertag-db-file supertag--config-guard-state))
                 (should (equal next supertag-data-directory))
                 (should (equal next (plist-get supertag--config-guard-state :data-directory)))
                 (should (equal db supertag-db-file))
                 (should (equal db (plist-get supertag--config-guard-state :db-file)))
                 (should-not supertag--config-guard-allow)))))))
       (princ (format "VC-DONE %S\n" vc-case)))))

(defun supertag-vault-test--vc-child (case)
  "Run guard CASE in fresh isolated processes, before fixtures can initialize state."
  (let* ((tmp (make-temp-file "supertag-vc-" t))
         (source (file-name-as-directory (or (getenv "SUPERTAG_VC_ROOT")
                                            (file-name-directory (locate-library "supertag-vault")))))
         (root source) (before (equal (getenv "SUPERTAG_VC_STAGE") "before"))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (process-environment (copy-sequence process-environment))
         (evidence (getenv "SUPERTAG_VC_EVIDENCE")))
    (unwind-protect
        (progn
          (when (eq case 'compiled)
            (setq root (expand-file-name "compile-tree/" tmp)) (make-directory root)
            (dolist (file (directory-files source t "\\.el\\'"))
              (copy-file file (expand-file-name (file-name-nondirectory file) root))))
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (dolist (phase (if (eq case 'compiled) '(compile compiled) (list case)))
            (let ((script (expand-file-name (format "%s.el" phase) tmp)))
              (with-temp-file script
                (insert ";;; -*- lexical-binding: t; -*-\n")
                (prin1 `(setq vc-root ,root vc-tmp ,tmp vc-before ,before vc-case ',phase) (current-buffer))
                (terpri (current-buffer))
                (prin1 `(condition-case err
                            (unwind-protect ,supertag-vault-test--vc-program
                              (dolist (s '(supertag-data-directory supertag-db-file supertag-db-backup-directory
                                           supertag-sync-state-file supertag-sync-directories supertag-active-sync-directory))
                                (remove-variable-watcher s 'supertag-config-guard--watch))
                              (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
                              (mapc #'cancel-timer (append timer-list timer-idle-list)))
                          (error (princ (format "VC-ERROR %S\n" err)) (kill-emacs 1))) (current-buffer)))
              (with-temp-buffer
                (let ((status (apply #'call-process program nil t nil
                                     (append '("-Q" "--batch")
                                             (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                             (list "-L" root "-l" script)))))
                  (when evidence
                    (make-directory evidence t)
                    (let ((base (expand-file-name (symbol-name phase) evidence)))
                      (copy-file script (concat base ".el") t)
                      (write-region (point-min) (point-max) (concat base ".log") nil 'silent)
                      (with-temp-file (concat base ".exit") (insert (format "%s\n" status)))
                      (when (eq phase 'compile)
                        (dolist (name '("guard-control.el" "guard-control.elc"))
                          (when (file-exists-p (expand-file-name name tmp))
                            (copy-file (expand-file-name name tmp) (expand-file-name name evidence) t))))))
                  (princ (buffer-string)) (should (equal 0 status))
                  (should (string-match-p (format "VC-DONE %s" phase) (buffer-string))))))))
      (delete-directory tmp t))))

(ert-deftest supertag-vault-vc-pure-vault () (supertag-vault-test--vc-child 'pure-vault))
(ert-deftest supertag-vault-vc-pure-template () (supertag-vault-test--vc-child 'pure-template))
(ert-deftest supertag-vault-vc-unconfigured () (supertag-vault-test--vc-child 'unconfigured))
(ert-deftest supertag-vault-vc-preset () (supertag-vault-test--vc-child 'preset))
(ert-deftest supertag-vault-vc-preinit () (supertag-vault-test--vc-child 'preinit))
(ert-deftest supertag-vault-vc-watcher () (supertag-vault-test--vc-child 'watcher))
(ert-deftest supertag-vault-vc-compiled () (supertag-vault-test--vc-child 'compiled))

(ert-deftest supertag-vault-vc-compiled-main-apply-preserves-dynamic-guard ()
  "Compile real main, then apply with its bytecode and real watchers."
  (let* ((tmp (make-temp-file "supertag-vc-main-regression-" t))
         (tree (expand-file-name "tree/" tmp))
         (source (file-name-directory (locate-library "supertag-vault")))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (process-environment (copy-sequence process-environment))
         (evidence (getenv "SUPERTAG_VC_R1_EVIDENCE")))
    (unwind-protect
        (progn
          (make-directory tree)
          (dolist (file (directory-files source t "\\.el\\'"))
            (copy-file file (expand-file-name (file-name-nondirectory file) tree)))
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "VC_R1_TREE" tree)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (dolist (phase
                   (list (list "compile" ";;; -*- lexical-binding: t; -*-
(require 'bytecomp)
(let ((tree (getenv \"VC_R1_TREE\")))
  (setq after-init-time nil
        user-emacs-directory (expand-file-name \"state/\" tree)
        supertag-data-directory user-emacs-directory
        supertag--base-data-directory user-emacs-directory
        supertag-db-file (expand-file-name \"store.el\" user-emacs-directory)
        supertag-db-backup-directory (expand-file-name \"backups/\" user-emacs-directory)
        supertag-sync-state-file (expand-file-name \"sync.el\" user-emacs-directory)
        org-id-locations-file (expand-file-name \"ids\" user-emacs-directory)
        supertag-sync-directories nil)
  (unwind-protect
      (dolist (name '(\"supertag-vault.el\" \"supertag.el\" \"supertag-git.el\"))
        (unless (byte-compile-file (expand-file-name name tree)) (error \"Compile failed: %s\" name)))
    (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil)
    (mapc #'cancel-timer (append timer-list timer-idle-list))))
(princ \"MAIN-COMPILE-DONE\\n\")
" "MAIN-COMPILE-DONE")
                         (list "apply" ";;; -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(let* ((tree (getenv \"VC_R1_TREE\"))
       (fixed t)
       (case \"apply\")
       (tmp (make-temp-file \"supertag-vc-main-macro-\" t))
       (root-a (expand-file-name \"a/\" tmp))
       (root-b (expand-file-name \"b/\" tmp))
       (data-a (expand-file-name \"data-a/\" tmp))
       (data-b (expand-file-name \"data-b/\" tmp))
       (vault-b (list :id \"b\" :root root-b :data-directory data-b))
       result)
  (unwind-protect
      (progn
        ;; No test-side defvar for guard-allow, no helper macro/function compile.
        (setq user-emacs-directory (file-name-as-directory tmp)
              default-directory (file-name-as-directory tmp)
              after-init-time nil load-prefer-newer nil
              supertag-data-directory data-a
              supertag-db-file (expand-file-name \"supertag-db.el\" data-a)
              supertag-db-backup-directory (expand-file-name \"backups/\" data-a)
              supertag-sync-state-file (expand-file-name \"sync-state.el\" data-a)
              org-id-locations-file (expand-file-name \"ids\" tmp)
              supertag-sync-directories-mode 'vaults
              supertag-sync-directories (list root-a root-b)
              supertag-active-sync-directory root-a
              supertag-sync-auto-start nil supertag-vault-auto-switch nil
              supertag-vault-modeline-indicator nil supertag-tag-auto-enable nil)
        (make-directory root-a t) (make-directory root-b t)
        (load (expand-file-name \"supertag.elc\" tree) nil nil t)
        (dolist (fn '(supertag-vault--apply supertag-vault-activate))
          (should (byte-code-function-p (symbol-function fn)))
          (should (equal (expand-file-name (if (equal (getenv \"SUPERTAG_VD_STAGE\") \"before\") \"supertag.elc\" \"supertag-vault.elc\") tree) (symbol-file fn 'defun))))
        (should-not supertag--initialized)
        (supertag-sync-load-state)
        (supertag-load-store)
        (setq supertag--initialized t)
        (supertag-config-guard-enable)
        (should-not supertag--config-guard-allow)
        (should (memq 'supertag-config-guard--watch
                      (get-variable-watchers 'supertag-data-directory)))
        (princ (format \"MAIN-COMPILED-ENTRY fixed=%S case=%s file=%S\\n\"
                       fixed case (symbol-file 'supertag-vault--apply 'defun)))
        (supertag-vault--apply vault-b)
        (setq result 'ok)
        (princ (format \"MAIN-COMPILED-RESULT %S data=%S active=%S current=%S allow=%S expected=%S\\n\"
                       result supertag-data-directory supertag-active-sync-directory
                       supertag-vault--current supertag--config-guard-allow supertag--config-guard-state))
        (should-not supertag--config-guard-allow)
        (should (equal data-b supertag-data-directory))
        (should (equal data-b (plist-get supertag--config-guard-state :data-directory)))
        (princ \"MAIN-COMPILED-PROBE-DONE\\n\"))
    (dolist (s '(supertag-data-directory supertag-db-file supertag-db-backup-directory
                 supertag-sync-state-file supertag-sync-directories supertag-active-sync-directory))
      (remove-variable-watcher s 'supertag-config-guard--watch))
    (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
    (mapc #'cancel-timer (append timer-list timer-idle-list))
    (delete-directory tmp t)))
" "MAIN-COMPILED-PROBE-DONE")))
            (let ((script (expand-file-name (concat (car phase) ".el") tmp)))
              (with-temp-file script (insert (nth 1 phase)))
              (with-temp-buffer
                (let ((status (apply #'call-process program nil t nil
                                     (append '("-Q" "--batch")
                                             (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                             (list "-L" tree "-l" script)))))
                  (when evidence
                    (make-directory evidence t)
                    (copy-file script (expand-file-name (concat (car phase) ".el") evidence) t)
                    (write-region (point-min) (point-max)
                                  (expand-file-name (concat (car phase) ".log") evidence) nil 'silent)
                    (with-temp-file (expand-file-name (concat (car phase) ".exit") evidence)
                      (insert (format "%s\n" status))))
                  (princ (buffer-string))
                  (should (equal 0 status))
                  (should (string-match-p (nth 2 phase) (buffer-string))))))))
      (delete-directory tmp t))))

;;; VAULT-D: independent configuration/runtime preparation contracts.
(defconst supertag-vault-test--vd-program ";;; -*- lexical-binding: t; -*-\n(require 'ert)\n(require 'cl-lib)\n(defvar vd-events nil)\n(defun supertag-vd-test--observe (phase)\n  (push (list phase\n              (boundp 'supertag-file-id-source)\n              (boundp 'supertag-vault--current)\n              (fboundp 'supertag-vault-indicator-mode)\n              (boundp 'supertag--initialized)\n              (fboundp 'supertag--effective-sync-directories)\n              (boundp 'supertag--base-data-directory)) vd-events))\n(let* ((tree (getenv \"VD_TREE\")) (tmp (getenv \"VD_TMP\"))\n       (phase (getenv \"VD_PHASE\"))\n       (case (getenv \"VD_CASE\"))\n       (before (equal (getenv \"SUPERTAG_VD_STAGE\") \"before\"))\n       (a (expand-file-name \"a/\" tmp)) (b (expand-file-name \"b/\" tmp))\n       (base (expand-file-name \"data/\" tmp))\n       (roots (list a b)) (held-base (expand-file-name \"prebound/\" tmp))\n       (held-current (list :id \"preset\")) (held-state (list :held t))\n       (generated (expand-file-name \"autoloads.el\" tree)))\n  (unwind-protect\n      (progn\n        (setq user-emacs-directory (file-name-as-directory tmp)\n              default-directory (file-name-as-directory tmp)\n              after-init-time nil load-prefer-newer nil\n              org-id-locations-file (expand-file-name \"ids\" tmp))\n        (make-directory a t) (make-directory b t)\n        (cond\n         ((equal phase \"generate\")\n          (require 'loaddefs-gen)\n          (loaddefs-generate\n           (list tree) generated\n           (cl-remove-if (lambda (s) (member (file-name-nondirectory s)\n                                            '(\"supertag.el\" \"supertag-vault.el\")))\n                         (directory-files tree t \"\\\\.el\\\\'\")) nil nil t)\n          (let (entries all-entries)\n            (with-temp-buffer\n              (insert-file-contents generated) (goto-char (point-min))\n              (condition-case nil\n                  (while t\n                    (let ((form (read (current-buffer))))\n                      (when (eq (car-safe form) 'autoload) (push form all-entries))\n                      (when (and (eq (car-safe form) 'autoload)\n                                 (eq (cadr (cadr form)) 'supertag--effective-sync-directories))\n                        (push form entries))))\n                (end-of-file nil)))\n            (should (= 1 (length entries)))\n            (should (equal \"supertag\" (nth 2 (car entries))))\n            (should-not (nth 4 (car entries)))\n            (should (string-prefix-p\n                     \"Return effective sync directories for the current session.\\n\\nIn vault mode, returns a single-element list containing the active vault root.\\nOtherwise, returns `supertag-sync-directories` unchanged.\"\n                     (nth 3 (car entries))))\n            (dolist (fn '(supertag-vault--effective-root\n                          supertag-vault--prepare-configuration\n                          supertag-vault--prepare-indicator\n                          supertag-vault--prepare-effective-wrappers))\n              (should-not (cl-find fn all-entries :key (lambda (form) (cadr (cadr form))))))\n            (princ (format \"VD-GENERATED version=%s entry=%S\\n\" emacs-version entries))))\n         ((equal phase \"compile\")\n          (require 'bytecomp)\n          ;; Do not initialize any Vault configuration or guard special in this child.\n          (should (byte-compile-file (expand-file-name \"supertag-vault.el\" tree)))\n          (should-not (fboundp 'supertag--effective-sync-directories))\n          (should-not (fboundp 'supertag-vault-indicator-mode))\n          (should-not (boundp 'supertag-vault--current))\n          (should (byte-compile-file (expand-file-name \"supertag.el\" tree)))\n          (princ \"VD-COMPILE-ACTUAL-LIBRARIES\\n\"))\n         (t\n          (when (equal case \"compiled-timing\")\n            (load (expand-file-name \"supertag-vault.elc\" tree) nil nil t))\n          (when (member case '(\"pure\" \"unconfigured\" \"source-timing\" \"reload-indicator\" \"cold-sync\"))\n            (require (if before 'supertag-services-template 'supertag-service-org)))\n          (when (equal case \"pure-vault\") (require 'supertag-vault))\n          (when (member case '(\"pure\" \"pure-vault\"))\n            (dolist (s '(supertag-vault--current supertag-vault--buffer-indicator\n                         supertag-vault-auto-switch supertag--base-data-directory))\n              (should-not (boundp s)))\n            (should-not (fboundp 'supertag-vault-indicator-mode))\n            (should-not (fboundp 'supertag--effective-sync-directories))\n            (should-not (featurep 'supertag-services-sync))\n            (should-not (featurep 'supertag))\n            (should (eq (not before) (fboundp 'supertag-vault-activate))))\n          (when (equal case \"unconfigured\")\n            (let ((error-value (should-error (supertag-vault--current-id))))\n              (should (eq (car error-value) (if before 'void-function 'void-variable)))\n              (princ (format \"VD-UNCONFIGURED %S\\n\" error-value)))\n            (dolist (fn '(supertag-sync-save-state supertag-save-store\n                         supertag-scheduler-start supertag-load-store))\n              (should-not (fboundp fn))))\n          (when (member case '(\"generated-activate\" \"generated-auto\"))\n            (setq supertag-sync-directories-mode 'vaults supertag-sync-directories roots)\n            (load generated nil nil t)\n            (let* ((fn (if (equal case \"generated-activate\")\n                           'supertag-vault-activate 'supertag-vault-auto-activate))\n                   (cell (symbol-function fn)) result)\n              (should (autoloadp cell))\n              (should (equal (nth 1 cell) (if before \"supertag\" \"supertag-vault\")))\n              (princ (format \"VD-PUBLIC-FIRST-CALL %S before=%S\\n\" fn before))\n              (setq result (condition-case err\n                               (progn (if (eq fn 'supertag-vault-activate)\n                                          (funcall fn nil) (funcall fn)) 'ok)\n                             (error err)))\n              (princ (format \"VD-PUBLIC-RESULT %S main=%S\\n\" result (featurep 'supertag)))\n              (if (eq fn 'supertag-vault-activate)\n                  (progn (should (eq (car-safe result) 'user-error))\n                         (should (equal (cadr result) \"No vault selected\")))\n                (if before (should (eq result 'ok))\n                  (should (eq (car-safe result) 'void-variable))\n                  (should (eq (cadr result) 'supertag-vault-modeline-indicator))))\n              (should (eq before (featurep 'supertag)))))\n          (unless (member case '(\"pure\" \"pure-vault\" \"unconfigured\" \"generated-activate\" \"generated-auto\"))\n            ;; All configured values below name only temporary files/directories.\n            (setq supertag-data-directory base\n                  supertag-db-file (expand-file-name \"store.el\" base)\n                  supertag-db-backup-directory (expand-file-name \"backups/\" base)\n                  supertag-sync-state-file (expand-file-name \"sync.el\" base)\n                  supertag-sync-directories-mode 'vaults\n                  supertag-sync-directories roots\n                  supertag-active-sync-directory b\n                  supertag-sync-auto-start nil supertag-tag-auto-enable nil)\n            (when (equal case \"prebound\")\n              (require (if before 'supertag-services-template 'supertag-service-org))\n              (setq supertag--base-data-directory held-base\n                    supertag-vault--current held-current\n                    supertag--config-guard-state held-state\n                    supertag-vault-auto-switch t\n                    supertag-vault-modeline-indicator nil))\n            (when (equal case \"cold-sync\")\n              (require 'supertag-services-sync)\n              (should-not (fboundp 'supertag--effective-sync-directories))\n              (should (eq roots (supertag-sync--effective-directories)))\n              (princ (format \"VD-SYNC-COLD %S\\n\" (supertag-sync--effective-directories))))\n            (when (equal case \"generated\")\n              (load generated nil nil t)\n              (should (autoloadp (symbol-function 'supertag--effective-sync-directories)))\n              (should-not (commandp 'supertag--effective-sync-directories))\n              (princ \"VD-GENERATED-FIRST-CALL\\n\")\n              (should (equal (list b) (supertag--effective-sync-directories)))\n              (should (featurep 'supertag))\n              (dolist (fn '(supertag--effective-sync-directories supertag-vault--effective-root))\n                (should-not (autoloadp (symbol-function fn)))))\n            (unless (equal case \"generated\")\n              (if (equal case \"compiled-timing\")\n                  (load (expand-file-name \"supertag.elc\" tree) nil nil t)\n                (require 'supertag)))\n            (princ (format \"VD-ENTRY case=%s owner=%S wrapper-owner=%S\\n\" case\n                           (symbol-file 'supertag-vault--apply 'defun)\n                           (symbol-file 'supertag--effective-sync-directories 'defun)))\n            (should-not supertag--initialized)\n            (should (equal (list b) (supertag-sync--effective-directories)))\n            (when (equal case \"prebound\")\n              (should (eq held-base supertag--base-data-directory))\n              (should (eq held-current supertag-vault--current))\n              (should (eq held-state supertag--config-guard-state))\n              (should supertag-vault-auto-switch)\n              (should-not supertag-vault-modeline-indicator)\n              (with-temp-buffer\n                (setq-local supertag-vault--buffer-indicator \"local\")\n                (let ((local-cell supertag-vault--buffer-indicator))\n                  (load (expand-file-name \"supertag.el\" tree) nil nil t)\n                  (should (local-variable-p 'supertag-vault--buffer-indicator))\n                  (should (eq local-cell supertag-vault--buffer-indicator))))\n              (princ \"VD-PREBOUND-REAL-RELOAD\\n\"))\n            (when (equal case \"owner\")\n              (should (equal (file-name-nondirectory (symbol-file 'supertag-vault--apply 'defun))\n                             (if before \"supertag.el\" \"supertag-vault.el\"))))\n            (when (member case '(\"source-timing\" \"compiled-timing\"))\n              (setq vd-events (reverse vd-events))\n              (princ (format \"VD-PREPARE-ORDER %S\\n\" vd-events))\n              (should (equal (mapcar #'car vd-events)\n                             '(p1-before p1-after p2-before p2-after guard-before guard-after p3-before p3-after)))\n              (should-not (nth 1 (assq 'p1-before vd-events)))\n              (should-not (nth 1 (assq 'p1-after vd-events)))\n              (should (nth 1 (assq 'p2-before vd-events)))\n              (should-not (nth 2 (assq 'p2-before vd-events)))\n              (should (nth 2 (assq 'p2-after vd-events)))\n              (should (nth 3 (assq 'p2-after vd-events)))\n              (should-not (nth 4 (assq 'p2-after vd-events)))\n              (should (nth 4 (assq 'guard-before vd-events)))\n              (should-not (nth 5 (assq 'p3-before vd-events)))\n              (should (nth 5 (assq 'p3-after vd-events)))\n              (should (equal (file-name-as-directory base) supertag--base-data-directory))\n              (when (equal case \"compiled-timing\")\n                (should (byte-code-function-p (symbol-function 'supertag-vault--apply))))\n              (princ (format \"VD-TIMING-ACTUAL %S\\n\" (supertag--effective-sync-directories))))\n            (when (equal case \"reload-indicator\")\n              (let ((base-cell supertag--base-data-directory)\n                    (current-cell (list :id \"held\"))\n                    (state-cell (list :sentinel t))\n                    (wrapper (symbol-function 'supertag--effective-sync-directories)))\n                (setq supertag-vault--current current-cell supertag--config-guard-state state-cell)\n                (require 'supertag)\n                (should (eq wrapper (symbol-function 'supertag--effective-sync-directories)))\n                (load (expand-file-name \"supertag-vault.el\" tree) nil nil t)\n                (should (eq wrapper (symbol-function 'supertag--effective-sync-directories)))\n                (should (eq state-cell supertag--config-guard-state))\n                (load (expand-file-name \"supertag.el\" tree) nil nil t)\n                (should (eq base-cell supertag--base-data-directory))\n                (should (eq current-cell supertag-vault--current))\n                (should (eq state-cell supertag--config-guard-state))\n                (should-not (eq wrapper (symbol-function 'supertag--effective-sync-directories)))\n                (should (get 'supertag-vault-auto-switch 'standard-value))\n                (should-not supertag-vault-auto-switch)\n                (let ((file (expand-file-name \"note.org\" a)))\n                  (with-temp-file file (insert \"* Ordinary\\nBody\\n\"))\n                  (let ((buf (find-file-noselect file)))\n                    (unwind-protect\n                        (with-current-buffer buf\n                          (should (derived-mode-p 'org-mode))\n                          (supertag-vault-auto-activate)\n                          (should supertag-vault-indicator-mode)\n                          (should (local-variable-p 'supertag-vault--buffer-indicator))\n                          (should (equal \" ST[a]\" supertag-vault--buffer-indicator))\n                          (should (eq current-cell supertag-vault--current))\n                          (should (= 1 (cl-count 'supertag-vault-auto-activate org-mode-hook))))\n                      (kill-buffer buf))))))\n            (when (equal case \"partial-failure\")\n              (let* ((va (list :id \"a\" :root a :data-directory (expand-file-name \"da/\" tmp)))\n                     (vb (list :id \"b\" :root b :data-directory (expand-file-name \"db/\" tmp)))\n                     (calls nil) (watchers nil))\n                (supertag-vault-activate va)\n                (setq supertag--initialized t)\n                (supertag-config-guard-enable)\n                (dolist (pair '((supertag-vault--persist-current . persist)\n                                (supertag-scheduler-stop . stop)\n                                (supertag-vault--reset-runtime . reset)\n                                (supertag-vault--apply . apply)\n                                (supertag-sync-load-state . sync-load)))\n                  (let* ((event (cdr pair)) (fn (lambda (&rest _) (push event calls))))\n                    (push (cons (car pair) fn) watchers)\n                    (advice-add (car pair) :before fn)))\n                (unwind-protect\n                    (cl-letf (((symbol-function 'supertag-load-store)\n                               (lambda (&rest _) (push 'store-error calls) (error \"VD load failure\"))))\n                      (should-error (supertag-vault-activate vb) :type 'error)\n                      (princ (format \"VD-PARTIAL-ORDER %S\\n\" (reverse calls)))\n                      (should (equal '(persist stop reset apply sync-load store-error) (reverse calls)))\n                      (should (eq vb supertag-vault--current))\n                      (should (equal b supertag-active-sync-directory))\n                      (should (equal (plist-get vb :data-directory) supertag-data-directory))\n                      (should-not supertag--config-guard-allow))\n                  (dolist (pair watchers) (advice-remove (car pair) (cdr pair)))))))))\n        (princ (format \"VD-DONE %s/%s\\n\" case phase)))\n    (dolist (s '(supertag-data-directory supertag-db-file supertag-db-backup-directory\n                 supertag-sync-state-file supertag-sync-directories supertag-active-sync-directory))\n      (remove-variable-watcher s 'supertag-config-guard--watch))\n    (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)\n    (dolist (buf (buffer-list))\n      (when (buffer-file-name buf)\n        (with-current-buffer buf (set-buffer-modified-p nil))\n        (kill-buffer buf)))\n    (mapc #'cancel-timer (append timer-list timer-idle-list))))\n")

(defun supertag-vault-test--vd-child (case)
  "Execute CASE in fresh processes with complete temporary source copies."
  (let* ((tmp (file-truename (make-temp-file "supertag-vd-" t)))
         (tree (expand-file-name "tree/" tmp))
         (source (file-name-as-directory
                  (or (getenv "SUPERTAG_VD_ROOT")
                      (file-name-directory (locate-library "supertag-vault")))))
         (before (equal (getenv "SUPERTAG_VD_STAGE") "before"))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (process-environment (copy-sequence process-environment))
         (default-directory tmp)
         (evidence (when (getenv "SUPERTAG_VD_EVIDENCE")
                     (expand-file-name case (getenv "SUPERTAG_VD_EVIDENCE")))))
    (unwind-protect
        (progn
          (make-directory tree)
          (dolist (file (directory-files source t "\\.el\\'"))
            (copy-file file (expand-file-name (file-name-nondirectory file) tree)))
          (when (member case '("source-timing" "compiled-timing"))
            ;; Transparent observations around the real original groups/calls;
            ;; no declaration, default, provider, macro or writer substitution.
            (with-temp-buffer
              (insert-file-contents (expand-file-name "supertag.el" tree))
              (dolist (pair
                       (list (cons (if before "(defcustom supertag-data-directory\n"
                                     "(supertag-vault--prepare-configuration)") 'p1-before)
                             (cons "(defcustom supertag-file-id-source " 'p1-after)
                             (cons (if before "(defvar supertag-vault--current "
                                     "(supertag-vault--prepare-indicator)") 'p2-before)
                             (cons "(defvar supertag--initialized " 'p2-after)
                             (cons "(supertag-vault--prepare-guard-defaults)" 'guard-before)
                             (cons (if before "(defun supertag-vault--effective-root "
                                     "(supertag-vault--prepare-effective-wrappers)") 'p3-before)
                             (cons (if before "(defun supertag-vault--persist-current "
                                     "(defcustom supertag-project-root") 'p3-after)))
                (goto-char (point-min))
                (should (search-forward (car pair) nil t))
                (goto-char (match-beginning 0))
                (insert (format "(supertag-vd-test--observe '%s)\n" (cdr pair))))
              (goto-char (point-min))
              (should (search-forward "(supertag-vault--prepare-guard-defaults)" nil t))
              (insert "\n(supertag-vd-test--observe 'guard-after)")
              (write-region (point-min) (point-max) (expand-file-name "supertag.el" tree) nil 'silent)))
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (setenv "VD_TREE" tree) (setenv "VD_TMP" tmp) (setenv "VD_CASE" case)
          (dolist (phase (append (cond ((member case '("generated" "generated-activate" "generated-auto")) '("generate"))
                                      ((equal case "compiled-timing") '("compile"))) '("execute")))
            (setenv "VD_PHASE" phase)
            (let ((script (expand-file-name (concat phase ".el") tmp)))
              (with-temp-file script (insert supertag-vault-test--vd-program))
              (with-temp-buffer
                (let ((status (apply #'call-process program nil t nil
                                     (append '("-Q" "--batch")
                                             (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                             (list "-L" tree "-l" script)))))
                  (when evidence
                    (make-directory evidence t)
                    (copy-file script (expand-file-name (concat phase ".el") evidence) t)
                    (write-region (point-min) (point-max) (expand-file-name (concat phase ".log") evidence) nil 'silent)
                    (with-temp-file (expand-file-name (concat phase ".exit") evidence) (insert (format "%s\n" status)))
                    (dolist (name '("supertag.el" "supertag-vault.el" "supertag.elc" "supertag-vault.elc"))
                      (when (file-exists-p (expand-file-name name tree))
                        (copy-file (expand-file-name name tree) (expand-file-name name evidence) t)))
                    (when (file-exists-p (expand-file-name "autoloads.el" tree))
                      (copy-file (expand-file-name "autoloads.el" tree) (expand-file-name "autoloads.el" evidence) t)))
                  (princ (buffer-string)) (should (equal 0 status))
                  (should (string-match-p (format "VD-DONE %s/%s" case phase) (buffer-string))))))))
      (delete-directory tmp t))))

(ert-deftest supertag-vault-vd-pure-template () (supertag-vault-test--vd-child "pure"))
(ert-deftest supertag-vault-vd-unconfigured-runtime () (supertag-vault-test--vd-child "unconfigured"))
(ert-deftest supertag-vault-vd-source-preparation-order () (supertag-vault-test--vd-child "source-timing"))
(ert-deftest supertag-vault-vd-compiled-preparation-order () (supertag-vault-test--vd-child "compiled-timing"))
(ert-deftest supertag-vault-vd-generated-main-autoload () (supertag-vault-test--vd-child "generated"))
(ert-deftest supertag-vault-vd-cold-sync-wrappers () (supertag-vault-test--vd-child "cold-sync"))
(ert-deftest supertag-vault-vd-reload-and-real-org-indicator () (supertag-vault-test--vd-child "reload-indicator"))
(ert-deftest supertag-vault-vd-partial-load-failure () (supertag-vault-test--vd-child "partial-failure"))
(ert-deftest supertag-vault-vd-runtime-owner () (supertag-vault-test--vd-child "owner"))

(ert-deftest supertag-vault-vd-pure-vault () (supertag-vault-test--vd-child "pure-vault"))
(ert-deftest supertag-vault-vd-prebound-preparation () (supertag-vault-test--vd-child "prebound"))

(ert-deftest supertag-vault-vd-generated-activate-precondition () (supertag-vault-test--vd-child "generated-activate"))
(ert-deftest supertag-vault-vd-generated-auto-precondition () (supertag-vault-test--vd-child "generated-auto"))

;;; VAULT-E: independent Setup entry and writer boundaries.
(defconst supertag-vault-test--ve-program ";;; -*- lexical-binding: t; -*-\n(require 'ert)\n(require 'cl-lib)\n(let* ((tree (getenv \"VE_TREE\")) (tmp (getenv \"VE_TMP\"))\n       (case (getenv \"VE_CASE\")) (phase (getenv \"VE_PHASE\"))\n       (before (equal (getenv \"SUPERTAG_VE_STAGE\") \"before\"))\n       (root (expand-file-name \"org/\" tmp)) (data (expand-file-name \"data/\" tmp))\n       (generated (expand-file-name \"autoloads.el\" tree))\n       (prompts 0) (init-count 0) (provider-count 0) (resolver-count 0)\n       (input-choice \"Nothing -- I only wanted to see the status\")\n       (init-advice (lambda (&rest _) (cl-incf init-count)))\n       saved-cell result)\n  (setq user-emacs-directory (file-name-as-directory tmp)\n        default-directory (file-name-as-directory tmp) after-init-time nil\n        load-prefer-newer nil org-id-locations-file (expand-file-name \"ids\" tmp))\n  (make-directory root t)\n  (unwind-protect\n      (progn\n        (cond\n         ((equal phase \"generate\")\n          (require 'loaddefs-gen)\n          (loaddefs-generate (list tree) generated\n           (cl-remove-if (lambda (s) (member (file-name-nondirectory s)\n                                  '(\"supertag.el\" \"supertag-vault.el\" \"supertag-setup.el\")))\n                         (directory-files tree t \"\\\\.el\\\\'\")) nil nil t)\n          (let (forms)\n            (with-temp-buffer\n              (insert-file-contents generated)\n              (goto-char (point-min))\n              (condition-case nil\n                  (while t (let ((f (read (current-buffer))))\n                             (when (eq (car-safe f) 'autoload) (push f forms))))\n                (end-of-file nil)))\n            (dolist (spec `((supertag-setup ,(if before \"supertag-setup\" \"supertag-vault\") t)\n                           (supertag--effective-sync-directories \"supertag\" nil)))\n              (let ((hits (cl-remove-if-not (lambda (f) (eq (cadr (cadr f)) (car spec))) forms)))\n                (should (= 1 (length hits)))\n                (should (equal (nth 2 (car hits)) (nth 1 spec)))\n                (should (eq (nth 4 (car hits)) (nth 2 spec)))\n                (should (stringp (nth 3 (car hits))))))))\n         ((equal phase \"compile\")\n          (require 'bytecomp)\n          (setq supertag-data-directory data supertag-db-file (expand-file-name \"store.el\" data)\n                supertag-db-backup-directory (expand-file-name \"backups/\" data)\n                supertag-sync-state-file (expand-file-name \"sync.el\" data)\n                supertag-sync-directories (list root) supertag-sync-auto-start nil)\n          (dolist (name (append '(\"supertag-vault.el\" \"supertag.el\" \"supertag-menu.el\")\n                               (when before '(\"supertag-setup.el\"))))\n            (should (byte-compile-file (expand-file-name name tree)))))\n         (t\n          (when (equal case \"foreign-before\")\n            (autoload 'supertag-init \"ve-foreign\" \"foreign\" t)\n            (setq saved-cell (symbol-function 'supertag-init)))\n          (when (member case '(\"pending\" \"late\"))\n            (should-not (fboundp 'supertag-init))\n            (advice-add 'supertag-init :before init-advice))\n          (when (equal case \"ordinary-before\")\n            (fset 'supertag-init (lambda () (cl-incf provider-count)))\n            (setq saved-cell (symbol-function 'supertag-init)))\n          ;; Pure phase, no configuration, no document-fixture or Sync preload.\n          (unless (member case '(\"generated\" \"menu\" \"load-error\" \"load-quit\"))\n            (require (if before 'supertag-services-template 'supertag-service-org))\n            (should-not (featurep 'supertag))\n            (should-not (featurep 'supertag-services-sync))\n            (should-not (boundp 'supertag-vault--current))\n            (should-not (boundp 'supertag--base-data-directory))\n            (should-not (fboundp 'supertag--effective-sync-directories))\n            (unless (member case '(\"foreign-before\" \"ordinary-before\"))\n              (if before (should-not (fboundp 'supertag-init))\n                (let ((c (symbol-function 'supertag-init)))\n                  (princ (format \"VE-INIT-CELL %S\\n\" c))\n                  (should (autoloadp c)) (should (equal \"supertag\" (nth 1 c)))\n                  (should (eq t (nth 3 c))) (should-not (nth 4 c))))))\n          (if (equal case \"pure\")\n              (progn\n                (when before (require 'supertag-setup) (should (featurep 'supertag)))\n                (princ (format \"VE-ENTRY pure main=%S\\n\" (featurep 'supertag))))\n            ;; Configuration below is entirely temporary. Entry still loads actual main.\n            (setq supertag-data-directory data supertag-db-file (expand-file-name \"store.el\" data)\n                  supertag-db-backup-directory (expand-file-name \"backups/\" data)\n                  supertag-sync-state-file (expand-file-name \"sync.el\" data)\n                  supertag-sync-directories (list root) supertag-sync-directories-mode 'unified\n                  supertag-sync-auto-start nil supertag-tag-auto-enable nil\n                  supertag-vault-auto-switch nil supertag-view-node-auto-show nil)\n            (when (member case '(\"late\" \"pending\")) (setq after-init-time '(1 0 0 0)))\n            (when (equal case \"foreign-before\") (should (eq saved-cell (symbol-function 'supertag-init))))\n            (when (member case '(\"foreign-after\" \"compiled-foreign\"))\n              (autoload 'supertag-init \"ve-foreign\" \"foreign\" t)\n              (setq saved-cell (symbol-function 'supertag-init)))\n            (when (member case '(\"macro\" \"keymap\"))\n              (fset 'supertag-init (list 'autoload \"supertag\" \"typed\" t (intern case)))\n              (setq saved-cell (symbol-function 'supertag-init)))\n            (when (equal case \"unbound\")\n              ;; Explicit mutation of the post-load cell, not a cold-load simulation.\n              (fmakunbound 'supertag-init))\n            (let* ((reject (member case '(\"foreign-before\" \"foreign-after\" \"compiled-foreign\"\n                                          \"ordinary-before\" \"macro\" \"keymap\" \"unbound\")))\n                   (load-failure (member case '(\"load-error\" \"load-quit\")))\n                   (main-loads 0)\n                   (real-load (symbol-function 'load))\n                   (real-resolve (symbol-function 'autoload-do-load)))\n              (cl-letf (((symbol-function 'completing-read)\n                         (lambda (&rest _)\n                           (should (featurep 'supertag)) (cl-incf prompts) input-choice))\n                        ((symbol-function 'autoload-do-load)\n                         (lambda (&rest args) (when (eq (cadr args) 'supertag-init) (cl-incf resolver-count)) (apply real-resolve args)))\n                        ((symbol-function 'load)\n                         (lambda (file &rest args)\n                           (when (member file '(\"supertag\" \"supertag.el\" \"supertag.elc\"))\n                             (cl-incf main-loads)\n                             (when load-failure\n                               (signal (if (equal case \"load-quit\") 'quit 'error) '(\"VE injected main load\"))))\n                           (apply real-load file args))))\n                (setq result\n                      (condition-case err\n                          (progn\n                            (cond\n                             ((equal case \"generated\") (load generated nil nil t)\n                              (should (autoloadp (symbol-function 'supertag-setup)))\n                              (call-interactively 'supertag-setup))\n                             ((equal case \"menu\") (require 'supertag-menu)\n                              (call-interactively 'supertag-menu--setup))\n                             (t (require (if before 'supertag-setup 'supertag-vault))\n                                (when (equal case \"compiled\")\n                                  (should (byte-code-function-p (symbol-function 'supertag-setup))))\n                                (call-interactively 'supertag-setup)))\n                            'ok)\n                        ((error quit) err)))\n                (princ (format \"VE-ENTRY %s before=%S result=%S main=%S prompts=%s init=%s resolver=%s\\n\"\n                               case before result (featurep 'supertag) prompts init-count resolver-count))\n                (cond\n                 (load-failure\n                  (should (eq (car-safe result) (if (equal case \"load-quit\") 'quit 'error)))\n                  (should (= 0 prompts)) (should-not (featurep 'supertag)))\n                 ((and reject (not before))\n                  (should (eq (car-safe result) 'user-error))\n                  (should (equal (cadr result) \"Supertag setup requires the main entry; load supertag first\"))\n                  (should-not (featurep 'supertag)) (should (= 0 prompts))\n                  (should (= 0 resolver-count)) (should (= 0 provider-count))\n                  (if saved-cell (should (eq saved-cell (symbol-function 'supertag-init)))\n                    (when (equal case \"unbound\") (should-not (fboundp 'supertag-init)))))\n                 (t\n                  (should (eq result 'ok)) (should (featurep 'supertag)) (should (= 1 prompts))\n                  (if (member case '(\"late\" \"pending\"))\n                      (progn (should supertag--initialized) (should (= 1 init-count))\n                             (should (advice-member-p init-advice 'supertag-init)))\n                    (should-not supertag--initialized)\n                    (should (memq 'supertag-init emacs-startup-hook)))\n                  ;; Already-loaded main must not repeat initialization or replace an advised cell.\n                  (let ((cell (symbol-function 'supertag-init)) (count init-count))\n                    (call-interactively 'supertag-setup)\n                    (should (eq cell (symbol-function 'supertag-init)))\n                    (should (= count init-count))))))\n              (when (equal case \"owner\")\n                (should (equal (if (and before (not (getenv \"VE_OWNER_RED\"))) \"supertag-setup.el\" \"supertag-vault.el\")\n                               (file-name-nondirectory (symbol-file 'supertag-setup 'defun))))))\n            (when (equal case \"loaded-private\")\n              (let ((cell (lambda () (cl-incf provider-count))))\n                (fset 'supertag-init cell)\n                (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) input-choice)))\n                  (call-interactively 'supertag-setup))\n                (should (eq cell (symbol-function 'supertag-init)))\n                (should (= 0 provider-count))))\n            (when (equal case \"persist-quit\")\n              (setq supertag-sync-directories nil)\n              (let ((questions 0))\n                (cl-letf (((symbol-function 'read-directory-name) (lambda (&rest _) root))\n                          ((symbol-function 'completing-read)\n                           (lambda (prompt choices &rest _)\n                             (if (string-match-p \"persisted\\\\|Apply how\" prompt)\n                                 (car (last choices 2)) (car choices))))\n                          ((symbol-function 'y-or-n-p)\n                           (lambda (&rest _) (cl-incf questions)\n                             (if (= questions 1) nil (signal 'quit nil)))))\n                  (should-not (call-interactively 'supertag-setup)))\n                (should (= 2 questions)) (should (equal (list root) supertag-sync-directories))))\n            (when (member case '(\"session\" \"snippet\" \"save\" \"partial-save\" \"guard\" \"scan\" \"quit\"))\n              (let ((new-roots (list (expand-file-name \"other/\" tmp)))\n                    (new-id 'denote) (calls 0)\n                    (custom-file (expand-file-name \"custom.el\" tmp))\n                    (user-init-file (expand-file-name \"init.el\" tmp)))\n                (with-temp-file user-init-file (insert \"; temporary init\\n\"))\n                (let ((old-roots supertag-sync-directories))\n                  (cond\n                   ((equal case \"scan\")\n                    (with-temp-file (expand-file-name \"note.org\" root)\n                      (insert \"* VE node\\n:PROPERTIES:\\n:ID: ve-node\\n:END:\\nBody\\n\"))\n                    (supertag-load-store)\n                    (let ((n (supertag-setup--node-count)))\n                      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))\n                        (supertag-setup--run-scan 'supertag-sync-full-rescan \"VE scan\"))\n                      (should (supertag-node-get \"ve-node\"))\n                      (should (> (supertag-setup--node-count) n)))\n                    (let ((ensure (symbol-function 'supertag-persistence-ensure-data-directory)))\n                      (cl-letf (((symbol-function 'supertag-persistence-ensure-data-directory)\n                                 (lambda (&rest args) (cl-incf calls) (apply ensure args)))\n                                ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))\n                        (supertag-setup--run-scan 've-unavailable \"missing\")\n                        (supertag-setup--run-scan 'supertag-sync-full-rescan \"declined\")\n                        (should (= 0 calls))))\n                    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))\n                              ((symbol-function 'supertag-persistence-ensure-data-directory)\n                               (lambda () (error \"VE ensure failure\"))))\n                      (should (equal (should-error (supertag-setup--run-scan 'supertag-sync-full-rescan \"ensure\"))\n                                     '(error \"VE ensure failure\"))))\n                    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))\n                              ((symbol-function 'supertag-sync-full-rescan)\n                               (lambda () (error \"VE scan failure\"))))\n                      (should (equal (should-error (supertag-setup--run-scan 'supertag-sync-full-rescan \"scan\"))\n                                     '(error \"VE scan failure\")))))\n                   ((equal case \"quit\")\n                    (let ((supertag-sync-directories nil))\n                      (cl-letf (((symbol-function 'read-directory-name) (lambda (&rest _) (signal 'quit nil))))\n                        (should-not (call-interactively 'supertag-setup)))\n                      (should-not supertag-sync-directories))\n                    (should (eq old-roots supertag-sync-directories)))\n                   (t\n                    (when (equal case \"guard\")\n                      (setq supertag--initialized t) (supertag-config-guard-enable))\n                    (require 'cus-edit)\n                    (let ((real-save (symbol-function 'customize-save-variable)))\n                      (cl-letf (((symbol-function 'completing-read)\n                                 (lambda (_prompt choices &rest _)\n                                   (cond ((member case '(\"save\" \"partial-save\")) (car choices))\n                                         ((equal case \"snippet\") (car (last choices)))\n                                         (t (car (last choices 2))))))\n                                ((symbol-function 'customize-save-variable)\n                                 (lambda (&rest args)\n                                   (cl-incf calls)\n                                   (if (and (equal case \"partial-save\") (= calls 2))\n                                       (error \"VE second save\") (apply real-save args)))))\n                        (if (member case '(\"guard\" \"partial-save\"))\n                            (should-error (supertag-setup--persist new-roots new-id))\n                          (supertag-setup--persist new-roots new-id))))\n                    (if (equal case \"guard\")\n                        (should (eq old-roots supertag-sync-directories))\n                      (should (equal new-roots supertag-sync-directories))\n                      (should (eq new-id supertag-file-id-source))\n                      (cond\n                       ((equal case \"snippet\")\n                        (should (get-buffer \"*supertag-setup*\"))\n                        (should (string-match-p \"denote\" (with-current-buffer \"*supertag-setup*\" (buffer-string)))))\n                       ((member case '(\"save\" \"partial-save\"))\n                        (with-temp-buffer\n                          (insert-file-contents custom-file)\n                          (should (search-forward \"supertag-sync-directories\" nil t))\n                          (goto-char (point-min))\n                          (should (eq (not (equal case \"partial-save\"))\n                                      (not (null (search-forward \"supertag-file-id-source\" nil t)))))))))))\n                  (princ (format \"VE-WRITER %s roots=%S id=%S calls=%s\\n\"\n                                 case supertag-sync-directories supertag-file-id-source calls))\n                  (when (getenv \"VE_WRONG_OUTPUT\") (should (equal supertag-file-id-source 've-wrong)))))))))\n        (princ (format \"VE-DONE %s/%s\\n\" case phase)))\n    (dolist (s '(supertag-data-directory supertag-db-file supertag-db-backup-directory\n                 supertag-sync-state-file supertag-sync-directories supertag-active-sync-directory))\n      (remove-variable-watcher s 'supertag-config-guard--watch))\n    (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)\n    (dolist (b (buffer-list))\n      (when (buffer-file-name b) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))\n    (mapc #'cancel-timer (append timer-list timer-idle-list))))\n")

(defun supertag-vault-test--ve-child (case)
  "Run Setup CASE through real production in fresh, isolated processes."
  (let* ((tmp (make-temp-file "supertag-ve-" t))
         (tree (expand-file-name "tree/" tmp))
         (source (or (getenv "SUPERTAG_VE_ROOT")
                     (file-name-directory (locate-library "supertag-vault"))))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (process-environment (copy-sequence process-environment))
         (default-directory tmp)
         (evidence (getenv "SUPERTAG_VE_EVIDENCE")))
    (unwind-protect
        (progn
          (make-directory tree)
          (dolist (file (directory-files source t "\\.el\\'"))
            (copy-file file (expand-file-name (file-name-nondirectory file) tree)))
          (when (member case '("load-error" "load-quit"))
            ;; Inject in actual main source, not a fake provide or require stub.
            (with-temp-buffer
              (insert-file-contents (expand-file-name "supertag.el" tree))
              (goto-char (point-min)) (forward-line 1)
              (insert (if (equal case "load-quit") "(signal 'quit '(\"VE main load\"))\n"
                        "(error \"VE main load\")\n"))
              (write-region (point-min) (point-max) (expand-file-name "supertag.el" tree) nil 'silent)))
          (with-temp-file (expand-file-name "ve-foreign.el" tree)
            (insert "(error \"VE FOREIGN PROVIDER EXECUTED\")\n"))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (setenv "VE_TREE" tree) (setenv "VE_TMP" tmp) (setenv "VE_CASE" case)
          (dolist (phase (append (cond ((equal case "generated") '("generate"))
                                      ((member case '("compiled" "compiled-foreign")) '("compile")))
                                 '("execute")))
            (setenv "VE_PHASE" phase)
            (let ((file (expand-file-name (concat phase ".el") tmp)))
              (with-temp-file file (insert supertag-vault-test--ve-program))
              (with-temp-buffer
                (let ((status (apply #'call-process program nil t nil
                                     (append '("-Q" "--batch")
                                             (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                             (list "-L" tree "-l" file)))))
                  (when evidence
                    (let ((out (expand-file-name (concat case "/") evidence)))
                      (make-directory out t)
                      (copy-file file (expand-file-name (concat phase ".el") out) t)
                      (write-region (point-min) (point-max) (expand-file-name (concat phase ".log") out) nil 'silent)
                      (with-temp-file (expand-file-name (concat phase ".exit") out) (insert (format "%s\n" status)))
                      (dolist (name '("autoloads.el" "supertag.elc" "supertag-vault.elc" "supertag-menu.elc" "supertag-setup.elc"))
                        (when (file-exists-p (expand-file-name name tree))
                          (copy-file (expand-file-name name tree) (expand-file-name name out) t)))))
                  (princ (buffer-string)) (should (equal 0 status))
                  (should (string-match-p (format "VE-DONE %s/%s" case phase) (buffer-string))))))))
      (delete-directory tmp t))))

(ert-deftest supertag-vault-ve-loaded-private () (supertag-vault-test--ve-child "loaded-private"))

(ert-deftest supertag-vault-ve-persist-quit () (supertag-vault-test--ve-child "persist-quit"))

(ert-deftest supertag-vault-ve-pure () (supertag-vault-test--ve-child "pure"))

(ert-deftest supertag-vault-ve-generated () (supertag-vault-test--ve-child "generated"))

(ert-deftest supertag-vault-ve-menu () (supertag-vault-test--ve-child "menu"))

(ert-deftest supertag-vault-ve-late () (supertag-vault-test--ve-child "late"))

(ert-deftest supertag-vault-ve-pending () (supertag-vault-test--ve-child "pending"))

(ert-deftest supertag-vault-ve-foreign-before () (supertag-vault-test--ve-child "foreign-before"))

(ert-deftest supertag-vault-ve-foreign-after () (supertag-vault-test--ve-child "foreign-after"))

(ert-deftest supertag-vault-ve-ordinary-before () (supertag-vault-test--ve-child "ordinary-before"))

(ert-deftest supertag-vault-ve-macro () (supertag-vault-test--ve-child "macro"))

(ert-deftest supertag-vault-ve-keymap () (supertag-vault-test--ve-child "keymap"))

(ert-deftest supertag-vault-ve-unbound () (supertag-vault-test--ve-child "unbound"))

(ert-deftest supertag-vault-ve-load-error () (supertag-vault-test--ve-child "load-error"))

(ert-deftest supertag-vault-ve-load-quit () (supertag-vault-test--ve-child "load-quit"))

(ert-deftest supertag-vault-ve-session () (supertag-vault-test--ve-child "session"))

(ert-deftest supertag-vault-ve-snippet () (supertag-vault-test--ve-child "snippet"))

(ert-deftest supertag-vault-ve-save () (supertag-vault-test--ve-child "save"))

(ert-deftest supertag-vault-ve-partial-save () (supertag-vault-test--ve-child "partial-save"))

(ert-deftest supertag-vault-ve-guard () (supertag-vault-test--ve-child "guard"))

(ert-deftest supertag-vault-ve-scan () (supertag-vault-test--ve-child "scan"))

(ert-deftest supertag-vault-ve-quit () (supertag-vault-test--ve-child "quit"))

(ert-deftest supertag-vault-ve-compiled () (supertag-vault-test--ve-child "compiled"))

(ert-deftest supertag-vault-ve-compiled-foreign () (supertag-vault-test--ve-child "compiled-foreign"))

(ert-deftest supertag-vault-ve-owner () (supertag-vault-test--ve-child "owner"))
