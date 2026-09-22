;;; supertag-vault.el --- Vault selection, configuration and runtime -*- lexical-binding: t; -*-

;; Commands: supertag-vault-activate; supertag-vault-indicator-mode after main preparation.
;; Dependencies: cl-lib, subr-x, easy-mmode. Guarded
;; runtime capabilities come from supertag-core-persistence, supertag-services-sync,
;; supertag-automation, supertag-discovery and supertag-view-node; declarations do not load them.
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'easy-mmode)

;; The Store special is owned and initialized by main and Store.
(defvar supertag--store)

;; Caller-owned configuration; declarations do not initialize providers.
(defvar supertag--base-data-directory)
(defvar supertag-data-directory)
(defvar supertag-sync-directories-mode)
(defvar supertag-sync-directories)

;; Guard state and caller-owned configuration; no default values here.
(defvar supertag--config-guard-enabled)
(defvar supertag--config-guard-allow)
(defvar supertag--config-guard--reverting)
(defvar supertag--config-guard-state)
(defvar supertag--initialized)
(defvar supertag-db-file)
(defvar supertag-db-backup-directory)
(defvar supertag-sync-state-file)
(defvar supertag-active-sync-directory)

;; Runtime specials; declarations do not prepare defaults or load providers.
(defvar supertag-vault-auto-switch)
(defvar supertag-vault-modeline-indicator)
(defvar supertag-vault--current)
(defvar supertag-vault--buffer-indicator)
(defvar supertag-vault-indicator-mode)
(defvar supertag--store-origin)
(defvar supertag-db--last-backup-date)
(defvar supertag-git-sync-mode)
(defvar supertag-sync-auto-start)

;; Optional capabilities remain conditional; declarations do not make them available.
(declare-function supertag-sync-save-state "supertag-services-sync" ())
(declare-function supertag-dirty-p "supertag-core-persistence" ())
(declare-function supertag-save-store "supertag-core-persistence" (&optional file))
(declare-function supertag-scheduler-stop "supertag-automation" ())
(declare-function supertag-sync--cancel-auto-start "supertag-services-sync" ())
(declare-function supertag-sync-stop-auto-sync "supertag-services-sync" ())
(declare-function supertag-persistence-ensure-data-directory "supertag-core-persistence" ())
(declare-function supertag-sync-load-state "supertag-services-sync" ())
(declare-function supertag-load-store "supertag-core-persistence" (&optional file))
(declare-function supertag-discovery--load-history "supertag-discovery" ())
(declare-function supertag-scheduler-start "supertag-automation" ())
(declare-function supertag-sync-start-auto-sync "supertag-services-sync" (&optional interval))
(declare-function supertag-view-node-refresh "supertag-view-node" ())
;; Mode function is defined only by the indicator preparation point.
(declare-function supertag-vault-indicator-mode "supertag-vault" (&optional arg))

(defun supertag-vault-selection-normalize-path (path)
  "Return a canonical directory PATH for configured-root comparison."
  (when (and (stringp path) (not (string-empty-p path)))
    (file-name-as-directory
     (file-truename (expand-file-name path)))))

(defun supertag-vault-selection--normalized-roots (directories)
  "Return canonical configured roots from DIRECTORIES."
  (delq nil
        (mapcar #'supertag-vault-selection-normalize-path
                (and (listp directories) directories))))

(defun supertag-vault-selection-effective-root (mode directories active)
  "Return the effective configured vault root for MODE.

DIRECTORIES is the configured root list.  In `vaults' MODE, ACTIVE wins only
when it names one of those roots; otherwise the first configured root wins."
  (when (eq mode 'vaults)
    (let* ((roots (supertag-vault-selection--normalized-roots directories))
           (active-root (supertag-vault-selection-normalize-path active)))
      (or (and active-root (cl-find active-root roots :test #'string=))
          (car roots)))))

(defun supertag-vault-selection-effective-directories
    (mode directories active)
  "Return effective sync DIRECTORIES for MODE and ACTIVE root."
  (if (eq mode 'vaults)
      (when-let* ((root (supertag-vault-selection-effective-root
                         mode directories active)))
        (list root))
    directories))

(defun supertag-vault--normalize-path (path)
  "Return a canonical directory PATH for matching and IO."
  (supertag-vault-selection-normalize-path path))

(defun supertag-vault--sanitize-name (name)
  "Return filesystem-friendly NAME."
  (let ((s (or name "")))
    (setq s (downcase s))
    (setq s (replace-regexp-in-string "[^[:alnum:]_.-]+" "-" s))
    (setq s (replace-regexp-in-string "^-+" "" s))
    (setq s (replace-regexp-in-string "-+$" "" s))
    (if (string-empty-p s) "vault" s)))

(defun supertag-vault--id (vault)
  "Return stable identifier string for VAULT."
  (let* ((root (plist-get vault :root))
         (name (plist-get vault :name))
         (root-norm (and root (supertag-vault--normalize-path root)))
         (base (supertag-vault--sanitize-name (or name "vault")))
         (suffix (when root-norm (substring (secure-hash 'sha1 root-norm) 0 10))))
    (if suffix (format "%s-%s" base suffix) base)))

(defun supertag-vault--normalize-vault-root (root)
  "Normalize ROOT directory into a vault plist."
  (let* ((root-norm (supertag-vault--normalize-path root)))
    (when root-norm
      (let* ((name (file-name-nondirectory (directory-file-name root-norm)))
             (vault (list :name (or name "vault") :root root-norm))
             (id (supertag-vault--id vault))
             (base (or supertag--base-data-directory
                       (file-name-as-directory (expand-file-name supertag-data-directory))))
             (data-dir (file-name-as-directory
                        (expand-file-name (format "vaults/%s" id) base))))
        (list :id id :name (plist-get vault :name) :root root-norm :data-directory data-dir)))))

(defun supertag-vault--vault-mode-p ()
  "Return non-nil when sync directories are treated as separate vaults."
  (and (boundp 'supertag-sync-directories-mode)
       (eq supertag-sync-directories-mode 'vaults)))

(defun supertag-vault--normalized-vaults ()
  "Return list of normalized vaults."
  (when (and (supertag-vault--vault-mode-p) (listp supertag-sync-directories))
    (delq nil (mapcar #'supertag-vault--normalize-vault-root supertag-sync-directories))))

(defun supertag-vault--find-by-root (root)
  "Find normalized vault by ROOT directory."
  (let ((target (supertag-vault--normalize-path root)))
    (when target
      (cl-find-if (lambda (v) (string= (plist-get v :root) target))
                  (supertag-vault--normalized-vaults)))))

(defun supertag-vault--find-by-file (file)
  "Find the best matching vault for FILE (longest root prefix)."
  (when (and (stringp file) (not (string-empty-p file)))
    (let* ((file-norm (condition-case nil
                          (file-truename (expand-file-name file))
                        (error (expand-file-name file))))
           (best nil)
           (best-len -1))
      (dolist (vault (supertag-vault--normalized-vaults))
        (let* ((root (plist-get vault :root))
               (root-len (length root)))
          (when (and (string-prefix-p root file-norm)
                     (> root-len best-len))
            (setq best vault)
            (setq best-len root-len))))
      best)))

(defun supertag-vault--prepare-guard-defaults ()
  "Prepare missing guard defaults.
Do not capture configuration or install watchers."
(defvar supertag--config-guard-enabled nil
  "When non-nil, prevent manual runtime changes to vault persistence variables.")

(defvar supertag--config-guard-allow nil
  "When non-nil, allow guarded variable updates for vault switching.")

(defvar supertag--config-guard--reverting nil
  "Internal guard flag used while reverting blocked config changes.")

(defvar supertag--config-guard-state nil
  "Expected runtime values for vault persistence variables.")
)

(defun supertag-config-guard--key (symbol)
  "Return guard key for SYMBOL, or nil when untracked."
  (pcase symbol
    ('supertag-data-directory :data-directory)
    ('supertag-db-file :db-file)
    ('supertag-db-backup-directory :backup-directory)
    ('supertag-sync-state-file :sync-state-file)
    ('supertag-sync-directories :sync-directories)
    ('supertag-active-sync-directory :active-sync-directory)
    (_ nil)))

(defun supertag-config-guard--capture ()
  "Capture current vault persistence settings."
  (setq supertag--config-guard-state
        (list :data-directory supertag-data-directory
              :db-file supertag-db-file
              :backup-directory supertag-db-backup-directory
              :sync-state-file (when (boundp 'supertag-sync-state-file)
                                 supertag-sync-state-file)
              :sync-directories (when (boundp 'supertag-sync-directories)
                                  supertag-sync-directories)
              :active-sync-directory (when (boundp 'supertag-active-sync-directory)
                                       supertag-active-sync-directory))))

(defun supertag-config-guard--update (symbol newval)
  "Update guard state for SYMBOL to NEWVAL."
  (let ((key (supertag-config-guard--key symbol)))
    (when key
      (setq supertag--config-guard-state
            (plist-put supertag--config-guard-state key newval)))))

(defun supertag-config-guard--watch (symbol newval operation _where)
  "Block manual runtime changes to guarded variables."
  (when (and supertag--config-guard-enabled
             supertag--initialized
             (memq operation '(set let))
             (not supertag--config-guard--reverting))
    (let ((key (supertag-config-guard--key symbol)))
      (when key
        (if supertag--config-guard-allow
            (supertag-config-guard--update symbol newval)
          (let ((expected (plist-get supertag--config-guard-state key)))
            (unless (equal newval expected)
              (user-error "Supertag: manual config change blocked. Use M-x supertag-vault-activate to switch vaults."))))))))

(defun supertag-config-guard-enable ()
  "Enable runtime guard for vault persistence variables."
  (supertag-config-guard--capture)
  (unless supertag--config-guard-enabled
    (setq supertag--config-guard-enabled t)
    (when (fboundp 'add-variable-watcher)
      (dolist (var '(supertag-data-directory
                     supertag-db-file
                     supertag-db-backup-directory
                     supertag-sync-state-file
                     supertag-sync-directories
                     supertag-active-sync-directory))
        (add-variable-watcher var #'supertag-config-guard--watch)))))

(defmacro supertag-config-guard--with-allow (&rest body)
  "Execute BODY while allowing guarded config changes."
  (declare (indent 0))
  `(let ((supertag--config-guard-allow t))
     ,@body))

;; Configuration and runtime; preparation is invoked by the main entry.

(defun supertag-vault--prepare-configuration ()
  "Prepare Vault configuration at the main entry's original position."
(defcustom supertag-data-directory
  (expand-file-name "supertag" user-emacs-directory)
  "Directory for storing Supertag data."
  :type 'directory
  :group 'supertag)

(defvar supertag--base-data-directory
  (file-name-as-directory (expand-file-name supertag-data-directory))
  "Base data directory for vault storage.

This stays constant even when `supertag-data-directory` is switched per vault.")

(defcustom supertag-active-sync-directory nil
  "Active vault root directory when `supertag-sync-directories` lists multiple roots.

This is only used when `supertag-sync-directories-mode` is `vaults`.
The value may include `~`; it will be normalized internally."
  :type '(choice (const :tag "First directory" nil)
                 directory)
  :group 'supertag)

(defcustom supertag-vault-auto-switch nil
  "When non-nil, automatically switch the active vault for Org buffers.

If enabled, entering an Org buffer will activate the matching vault (by file path),
which includes loading that vault's DB/state and restarting auto-sync for it.

Default is nil to avoid unexpected IO and model reload costs during navigation."
  :type 'boolean
  :group 'supertag)

(defcustom supertag-vault-modeline-indicator t
  "When non-nil, show the matched vault name in the mode line for Org buffers.

This does not switch the active vault; it only displays which vault the current
file belongs to (based on its path)."
  :type 'boolean
  :group 'supertag)
)

(defun supertag-vault--prepare-indicator ()
  "Prepare Vault indicator state and mode at the original main position."
(defvar supertag-vault--current nil
  "Currently active vault plist (normalized).")

(defvar-local supertag-vault--buffer-indicator nil
  "Cached mode line indicator for the current buffer.")

(define-minor-mode supertag-vault-indicator-mode
  "Show Supertag vault indicator in the mode line."
  :init-value nil
  :lighter (:eval (or supertag-vault--buffer-indicator "")))
)

(defun supertag-vault--apply (vault)
  "Apply VAULT persistence and sync configuration without loading data."
  (supertag-config-guard--with-allow
    (let* ((data-dir (file-name-as-directory (plist-get vault :data-directory))))
      (setq supertag-data-directory data-dir)
      (setq supertag-db-file (expand-file-name "supertag-db.el" data-dir))
      (setq supertag-db-backup-directory (expand-file-name "backups" data-dir))
      (setq supertag-sync-state-file (expand-file-name "sync-state.el" data-dir))
      ;; Backup date is per-vault; reset to allow correct daily backup decisions.
      (when (boundp 'supertag-db--last-backup-date)
        (setq supertag-db--last-backup-date nil))))
  (supertag-config-guard--capture))

(defun supertag-vault--current-id ()
  "Return current vault ID or nil."
  (plist-get supertag-vault--current :id))

(defun supertag-vault--prepare-effective-wrappers ()
  "Define session wrappers at the original main entry position."
(defun supertag-vault--effective-root ()
  "Return the active vault root directory, or nil when not in vault mode."
  (supertag-vault-selection-effective-root
   supertag-sync-directories-mode
   supertag-sync-directories
   supertag-active-sync-directory))

(defun supertag--effective-sync-directories ()
  "Return effective sync directories for the current session.

In vault mode, returns a single-element list containing the active vault root.
Otherwise, returns `supertag-sync-directories` unchanged."
  (supertag-vault-selection-effective-directories
   supertag-sync-directories-mode
   supertag-sync-directories
   supertag-active-sync-directory))
)

(defun supertag-vault--persist-current ()
  "Persist current vault state/store, signaling failure to the caller."
  (when (fboundp 'supertag-sync-save-state) (supertag-sync-save-state))
  (when (and (fboundp 'supertag-dirty-p) (supertag-dirty-p)
             (fboundp 'supertag-save-store)
             (progn
               (supertag-save-store)
               (or (supertag-dirty-p)
                   (eq (plist-get supertag--store-origin :status) :failed))))
    (user-error "Current vault was not saved; switch aborted"))
  (when (fboundp 'supertag-scheduler-stop)
    (supertag-scheduler-stop))
  t)

(defun supertag-vault--reset-runtime ()
  "Stop and clear runtime state before loading another vault."
  (dolist (reset '(supertag-ui--reset-runtime
                   supertag-automation--reset-runtime
                   supertag-automation-sync--reset-runtime
                   supertag-scheduler--reset-runtime
                   supertag-sync--reset-runtime
                   supertag-ai--reset-runtime
                   supertag-migrate--reset-runtime
                   supertag-discovery--reset-runtime))
    (when (fboundp reset) (funcall reset))))

(defun supertag-vault--buffer-vault-name (&optional file)
  "Return vault name that FILE belongs to, or nil."
  (let* ((file (or file (buffer-file-name)))
         (vault (and file (supertag-vault--find-by-file file))))
    (plist-get vault :name)))

(defun supertag-vault--update-buffer-indicator ()
  "Update `supertag-vault--buffer-indicator` for the current buffer."
  (setq supertag-vault--buffer-indicator nil)
  (when (and supertag-vault-modeline-indicator
             (listp supertag-sync-directories)
             (> (length supertag-sync-directories) 1))
    (let ((name (supertag-vault--buffer-vault-name)))
      (setq supertag-vault--buffer-indicator
            (if name
                (format " ST[%s]" name)
              " ST[-]"))))
  (force-mode-line-update))

;;;###autoload
(defun supertag-vault-activate (vault)
  "Activate VAULT (normalized plist) and load its DB/state.

This stops the current auto-sync worker (if any), switches persistence paths,
loads store/sync-state for the selected vault, and restarts auto-sync for the
active vault when `supertag-sync-auto-start` is non-nil."
  (interactive
   (let* ((vaults (supertag-vault--normalized-vaults))
          (choices (mapcar (lambda (v)
                             (format "%s  (%s)"
                                     (plist-get v :name)
                                     (abbreviate-file-name (plist-get v :root))))
                           vaults))
          (choice (completing-read "Supertag vault: " choices nil t)))
     (list (nth (cl-position choice choices :test #'string=) vaults))))
  (unless vault
    (user-error "No vault selected"))
  (unless (supertag-vault--vault-mode-p)
    (user-error "Vault switching requires `supertag-sync-directories-mode` set to 'vaults"))
  (when (and (boundp 'supertag-git-sync-mode) supertag-git-sync-mode)
    (user-error "Disable Git sync before switching vaults"))
  (unless (equal (plist-get vault :id) (supertag-vault--current-id))
    (condition-case nil (supertag-vault--persist-current)
      (error (user-error "Current vault was not saved; switch aborted")))
    (supertag-vault--reset-runtime)
    (when (fboundp 'supertag-sync--cancel-auto-start)
      (ignore-errors (supertag-sync--cancel-auto-start)))
    (when (fboundp 'supertag-sync-stop-auto-sync)
      (ignore-errors (supertag-sync-stop-auto-sync)))
    (supertag-config-guard--with-allow
      (setq supertag-vault--current vault)
      (setq supertag-active-sync-directory (plist-get vault :root)))
    (supertag-vault--apply vault)
    (when (fboundp 'supertag-persistence-ensure-data-directory)
      (supertag-persistence-ensure-data-directory))
    (when (fboundp 'supertag-sync-load-state)
      (supertag-sync-load-state))
    (when (fboundp 'supertag-load-store)
      (supertag-load-store))
    (when (fboundp 'supertag-discovery--load-history)
      (supertag-discovery--load-history))
    (when (fboundp 'supertag-scheduler-start)
      (supertag-scheduler-start))
    (when (and (boundp 'supertag-sync-auto-start)
               supertag-sync-auto-start
               (fboundp 'supertag-sync-start-auto-sync))
      (ignore-errors (supertag-sync-start-auto-sync)))
    (when (fboundp 'supertag-view-node-refresh)
      (ignore-errors (supertag-view-node-refresh)))
    (message "Supertag: active vault => %s (%s)"
             (plist-get vault :name)
             (abbreviate-file-name (plist-get vault :root)))))

;;;###autoload
(defun supertag-vault-auto-activate ()
  "Update vault indicator and optionally auto-switch active vault for Org buffers."
  (when (and (listp supertag-sync-directories)
             (> (length supertag-sync-directories) 1))
    (when supertag-vault-modeline-indicator
      (supertag-vault-indicator-mode 1))
    (supertag-vault--update-buffer-indicator)
    (when supertag-vault-auto-switch
      (let ((file (buffer-file-name)))
        (when file
          (let ((vault (supertag-vault--find-by-file file)))
            (when vault
              (supertag-vault-activate vault))))))))

(defun supertag-vault--select-startup-default ()
  "Select and apply a default vault at startup (without loading)."
  (setq supertag--base-data-directory
        (or supertag--base-data-directory
            (file-name-as-directory (expand-file-name supertag-data-directory))))
  (when (and (supertag-vault--vault-mode-p)
             (listp supertag-sync-directories)
             (> (length supertag-sync-directories) 1))
    (let* ((vault (or (supertag-vault--find-by-root supertag-active-sync-directory)
                      (car (supertag-vault--normalized-vaults)))))
      (when vault
        (setq supertag-vault--current vault)
        (setq supertag-active-sync-directory (plist-get vault :root))
        (supertag-vault--apply vault)))))


(provide 'supertag-vault)
;;; supertag-vault.el ends here
