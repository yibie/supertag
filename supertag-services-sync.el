;;; supertag-services-sync.el --- Synchronization mechanism for Supertag -*- lexical-binding: t; -*-

;;; Commentary:
;; This file implements the synchronization mechanism for the Supertag
;; data-centric architecture. It handles importing data from Org files into the
;; central store and exporting data from the store back to Org files.


;; Commands: supertag-sync-full-rescan, supertag-sync-cleanup-database,
;; supertag-sync-force-resync-current-file, supertag-sync-status.
;; Dependencies: cl-lib, subr-x, ht, org-element, org-id;
;; supertag-core-store,
;; supertag-node, supertag-query, supertag-core-persistence, supertag-tag;
;; ordinary Link vocabulary/Relation providers. The file queue is internal.
;; Tag entity ensure/normalization and inline Tag parsing are provided by supertag-tag.
;;; Code:


(require 'cl-lib)
(require 'subr-x)
(require 'ht)
(require 'org-element) ; For parsing Org files
(require 'org-id)     ; For generating Org IDs
(require 'supertag-core-store)
(require 'supertag-node) ; For supertag-node-create
(require 'supertag-query)
;; File membership reads no longer arrive through Query's eager scan load.
(autoload 'supertag-find-nodes-by-file "supertag-query")
(declare-function supertag-find-nodes-by-file "supertag-query" (file-path))
(require 'supertag-core-persistence) ; For supertag-data-directory
(require 'supertag-tag) ; For supertag-tag-create
;; Ordinary Relation providers load Link only on first use.
(autoload 'supertag-relation-named-document-link-p "supertag-link")
(declare-function supertag-relation-named-document-link-p "supertag-link" (relation &optional relation-name))
(autoload 'supertag-relation-document-link-p "supertag-link")
(declare-function supertag-relation-document-link-p "supertag-link" (relation))
(autoload 'supertag-relation-find-between "supertag-link")
(declare-function supertag-relation-find-between "supertag-link" (from-id to-id &optional type kind))
(autoload 'supertag-relation-project-document-link "supertag-link")
(declare-function supertag-relation-project-document-link "supertag-link" (from-id to-id &optional relation-name))
(autoload 'supertag-relation-find-by-from "supertag-link")
(declare-function supertag-relation-find-by-from "supertag-link" (from-id &optional type kind))
(autoload 'supertag-relation-find-by-to "supertag-link")
(declare-function supertag-relation-find-by-to "supertag-link" (to-id &optional type kind))
(autoload 'supertag-relation-delete "supertag-link")
(declare-function supertag-relation-delete "supertag-link" (id))
;; Relation vocabulary is owned by Link; parsers resolve it on first use.
(autoload 'supertag-text-link-refresh "supertag-link")
(declare-function supertag-text-link-refresh "supertag-link" ())
(autoload 'supertag-text-link-relation-type-p "supertag-link")
(declare-function supertag-text-link-relation-type-p "supertag-link" (type))
(autoload 'supertag-text-link-relation-types "supertag-link")
(declare-function supertag-text-link-relation-types "supertag-link" ())
;;; Internal File Queue

(defgroup supertag-async nil
  "Asynchronous processing settings for Supertag."
  :group 'supertag)

(defcustom supertag-async-idle-delay 0.5
  "Seconds of idle time to wait before processing the next job in the queue.
Lower values make sync faster but might interfere with typing.
Higher values ensure Emacs is truly idle."
  :type 'number
  :group 'supertag-async)

(defcustom supertag-async-slice-seconds 0.05
  "Seconds the queue may work in one idle cycle before Emacs runs again.
A cycle always processes one file, however long that takes, and goes on to
the next ones only while this much time has not passed.  Pending input ends
a cycle early.  Zero means one file per cycle."
  :type 'number
  :group 'supertag-async)

;;; Variables

(defvar supertag-async--queue '()
  "List of items (usually file paths) waiting to be processed.
Ordered from oldest to newest.")

(defvar supertag-async--failed-items '()
  "Items whose most recent processing attempt failed.
They are kept outside the active queue to avoid a tight automatic retry
loop.  A complete `supertag-sync-full-rescan' forgets them via
`supertag-async-clear-failed'.")

(defvar supertag-async--timer nil
  "The active idle timer, or nil if not running.")

(defvar supertag-async--processor-fn nil
  "The function to call for each item in the queue.
Must accept a single argument (the item).")

(defvar supertag-async-drained-hook nil
  "Functions run by the worker once no queued or handed-out work remains.")

(defvar supertag-sync-parser--in-flight nil
  "Files handed to the parser process whose records are not applied yet.
Oldest first; the process answers in this order.")

(defvar supertag-sync-parser--ready 0
  "Number of complete answers of the parser process waiting to be applied.")

;;; Core Functions

(defun supertag-async-init (processor-fn)
  "Initialize the async system with a PROCESSOR-FN.
PROCESSOR-FN is a function that takes one argument (the item to process)."
  (setq supertag-async--processor-fn processor-fn)
  (setq supertag-async--queue '())
  (setq supertag-async--failed-items '())
  (supertag-sync-parser--stop)
  (supertag-async--ensure-timer))

(defun supertag-async-enqueue (item)
  "Add ITEM to the processing queue.
If ITEM is already in the queue, it is moved to the end (re-prioritized).
Returns the new queue length."
  ;; Remove if exists (deduplicate)
  (setq supertag-async--queue (delete item supertag-async--queue))
  ;; A fresh enqueue supersedes an earlier failed attempt for this item.
  (setq supertag-async--failed-items
        (delete item supertag-async--failed-items))
  ;; Add to end
  (setq supertag-async--queue (append supertag-async--queue (list item)))
  ;; Ensure timer is running
  (supertag-async--ensure-timer)
  (length supertag-async--queue))

(defun supertag-async-enqueue-many (items)
  "Add every one of ITEMS to the processing queue and return its new length.
The queue ends up as if `supertag-async-enqueue' had been called on each
item, but in one pass over the queue however many items there are."
  (when items
    (let ((incoming (make-hash-table :test 'equal :size (length items)))
          fresh)
      ;; An item listed twice keeps its last place, as re-queueing it would.
      (dolist (item (reverse items))
        (unless (gethash item incoming)
          (puthash item t incoming)
          (push item fresh)))
      (cl-flet ((incoming-p (item) (gethash item incoming)))
        (setq supertag-async--failed-items
              (cl-delete-if #'incoming-p supertag-async--failed-items))
        (setq supertag-async--queue
              (nconc (cl-delete-if #'incoming-p supertag-async--queue)
                     fresh))))
    (supertag-async--ensure-timer))
  (length supertag-async--queue))

(defun supertag-async-clear ()
  "Clear all pending jobs."
  (setq supertag-async--queue '())
  (setq supertag-async--failed-items '())
  (supertag-sync-parser--stop))

(defun supertag-async-busy-p ()
  "Return non-nil while a queued item or a file at the parser process remains."
  (or supertag-async--queue supertag-sync-parser--in-flight))

(defun supertag-async-clear-failed ()
  "Forget every retained failed item and return how many were dropped.
Called after a complete full rescan, which has re-read those files."
  (prog1 (length supertag-async--failed-items)
    (setq supertag-async--failed-items nil)))

;;; Internal Timer Logic

(defun supertag-async--work-ready-p ()
  "Return non-nil when the worker could do something right now.
Files the parser process is still reading are not such work: its answer
starts the timer again."
  (or (> supertag-sync-parser--ready 0)
      (and supertag-async--queue
           (or (not (supertag-sync-parser--usable-p))
               (supertag-sync-parser--room-p)))))

(defun supertag-async--ensure-timer ()
  "Start the idle timer if it's not already running and there is work to do."
  (when (and (not supertag-async--timer)
             (supertag-async--work-ready-p))
    (setq supertag-async--timer
          (run-with-idle-timer
           supertag-async-idle-delay
           nil ;; Run once (we will re-schedule if more work remains)
           #'supertag-async--worker))))

(defun supertag-async--attempt (item function)
  "Call FUNCTION, which processes ITEM, and retain ITEM when it fails.
Each item is attempted on its own so one failure does not hide which file
failed or discard the rest of this batch."
  (condition-case err
      (funcall function)
    (error
     (cl-pushnew item supertag-async--failed-items :test #'equal)
     (message
      (concat "Supertag sync failed for %s: %s. "
              "Data safety: the Org source file was not modified, and its filename is retained for retry. "
              "Next: fix the cause, then run M-x supertag-sync-full-rescan.")
      item (error-message-string err)))))

(defun supertag-async--worker ()
  "Process the next batch of items from the queue.
Files go to the parser process when it can be used, and this applies the
records it has sent back; otherwise each item is processed here."
  (setq supertag-async--timer nil) ;; Timer has fired, so it's gone

  (when (and supertag-async--processor-fn (supertag-async-busy-p))
    (let ((deadline (+ (float-time) supertag-async-slice-seconds))
          (count 0))
      (when (supertag-sync-parser--usable-p)
        (supertag-sync-parser--dispatch))
      ;; Pending input ends the batch: the rest waits for the next idle.
      (while (and (or (> supertag-sync-parser--ready 0)
                      (and supertag-async--queue
                           (not (supertag-sync-parser--usable-p))))
                  (or (= count 0) (< (float-time) deadline))
                  (not (input-pending-p)))
        (if (> supertag-sync-parser--ready 0)
            (supertag-sync-parser--apply-next)
          ;; Pop before invoking user code.  The processor may enqueue work
          ;; synchronously; removing the old head afterward would then operate
          ;; on that newer queue and could discard an unrelated pending item.
          (let ((item (pop supertag-async--queue)))
            (supertag-async--attempt
             item (lambda () (funcall supertag-async--processor-fn item)))))
        (cl-incf count))
      (when (supertag-sync-parser--usable-p)
        (supertag-sync-parser--dispatch)))

    ;; Files still at the parser process start the timer when it answers.
    (cond
     ((supertag-async--work-ready-p) (supertag-async--ensure-timer))
     ((not (supertag-async-busy-p))
      (supertag-sync-parser--drained)
      (run-hooks 'supertag-async-drained-hook)))))

(defvar supertag-file-id-source 'org-roam
  "Policy for recognizing stable file node IDs.")

;;; Customization (from supertag-old/supertag-sync.el)

(defgroup supertag-sync nil
  "Synchronization settings for Supertag."
  :group 'supertag)

(defcustom supertag-sync-state-file
  (expand-file-name "sync-state.el" supertag-data-directory) ; Use new data directory
  "File to store sync state data."
  :type 'file
  :group 'supertag-sync)

(defvar supertag-sync--state-source nil
  "Resolved sync-state file path last loaded into memory.")

(defcustom supertag-sync-auto-interval 900
  "Interval in seconds for automatic synchronization."
  :type 'integer
  :group 'supertag-sync)

(defcustom supertag-sync-idle-delay 1.0
  "Seconds of idle time required before automatic sync runs."
  :type 'number
  :group 'supertag-sync)

(defcustom supertag-sync-directories nil
  "List of directories to monitor for automatic synchronization.
Each entry should be an absolute path. Subdirectories will also be monitored.
If nil, no automatic synchronization will occur."
  :type '(repeat directory)
  :group 'supertag-sync)

(defcustom supertag-sync-directories-mode 'unified
  "How to interpret `supertag-sync-directories`.

- `unified`: all directories share one database (legacy/default behavior).
- `vaults`: each directory is treated as an isolated vault with its own
DB/state,
  and sync only runs for the currently active vault directory.

Vault activation is handled by `supertag.el` (see `supertag-vault-activate`)."
  :type '(choice (const :tag "Unified DB" unified)
                 (const :tag "Vaults (isolated per directory)" vaults))
  :group 'supertag-sync)

(defun supertag-sync--effective-directories ()
  "Return effective sync directories.

When Supertag is running in vault mode, this resolves to the active vault's
directory (single-element list). Otherwise returns `supertag-sync-directories`."
  (if (and (eq supertag-sync-directories-mode 'vaults)
           (fboundp 'supertag--effective-sync-directories))
      (supertag--effective-sync-directories)
    supertag-sync-directories))

(defcustom supertag-sync-exclude-directories nil
  "List of directories to exclude from synchronization.
Takes precedence over `supertag-sync-directories`."
  :type '(repeat directory)
  :group 'supertag-sync)

(defcustom supertag-sync-file-pattern "\.org$"
  "Regular expression for matching files to synchronize."
  :type 'string
  :group 'supertag-sync)

(defcustom supertag-sync-quiet-when-idle t
  "If non-nil, suppress routine sync summary/diagnostic messages when no changes
were detected."
  :type 'boolean
  :group 'supertag-sync)

(defcustom supertag-sync-snapshot-guard t
  "When non-nil, sync uses snapshot state to guard destructive operations."
  :type 'boolean
  :group 'supertag-sync)


(defun supertag-sync--state-file ()
  "Return the resolved sync-state file path for current data directory."
  (let* ((data-dir (file-name-as-directory (expand-file-name supertag-data-directory)))
         (default-file (expand-file-name "sync-state.el" data-dir)))
    (setq supertag-sync-state-file default-file)
    supertag-sync-state-file))


(defcustom supertag-sync-hash-props
  '(:raw-value :olp :tags :todo :priority :content :properties :parent-id)
  "Additional properties to include when calculating node hashes.
All keys in `supertag-sync-document-fact-hash-props' are always included;
this option can extend that contract, but cannot remove Document Facts."
  :type '(repeat symbol)
  :group 'supertag-sync)

(defconst supertag-sync-document-fact-hash-props
  '(:title :raw-value :olp :tags :todo :priority :scheduled :deadline
    :tag-occurrences :unresolved-tags :content :properties :ref-to :named-links :file
    :level :position :pos :parent-id :link-type)
  "Document Projection properties that must participate in node hashes.")

(defcustom supertag-sync-smart-detection-enabled nil
  "If non-nil, enable smart detection to skip unchanged files during sync.
When enabled, files are hashed and only re-parsed if their content has changed."
  :type 'boolean
  :group 'supertag-sync)

(defcustom supertag-sync-smart-detection-verbose nil
  "If non-nil, show messages about smart detection decisions during sync."
  :type 'boolean
  :group 'supertag-sync)

(defvar supertag-sync--last-smart-detection-decision nil
  "Internal state tracking the last smart detection decision.
Stores a plist with :file, :decision, :reason, and :time.")

(defcustom supertag-sync-auto-create-node nil
  "Deprecated compatibility option; sync never invents heading IDs.
Adding a tag or a link (`supertag-add-tag', `supertag-add-link') persists
an Org ID before projection.  A read-only scan skips ID-less headings."
  :type 'boolean
  :group 'supertag-sync)

(defcustom supertag-sync-node-creation-level 1
  "Minimum heading level for automatic node creation.
Only headings at this level or deeper will be considered for node creation."
  :type 'integer
  :group 'supertag-sync)

;; Safety guards against accidental mass-deletion/data loss
(defcustom supertag-sync-max-delete-ratio 0.5
  "Maximum ratio of all nodes that one bulk deletion may remove.
A bulk deletion removes the nodes of files that disappeared, or the nodes
a full rescan or `supertag-sync-cleanup-database' finds no Org file for.
When it would remove more than this fraction of all nodes, nothing is
deleted.  Headings removed from a file that is still there are not bulk
deletions and are never capped."
  :type 'number
  :group 'supertag-sync)

(defcustom supertag-sync-max-delete-count 1000
  "Maximum number of nodes that one bulk deletion may remove.
When a bulk deletion would remove more nodes than this, nothing is
deleted.  See `supertag-sync-max-delete-ratio' for what counts as one."
  :type 'integer
  :group 'supertag-sync)

;;; Auto-start configuration (safer defaults to reduce user setup)

(defcustom supertag-sync-auto-start t
  "Automatically start Supertag auto-sync after Emacs startup.
Start is delayed and retried until sync directories are available
to avoid race conditions at early startup."
  :type 'boolean
  :group 'supertag-sync)

(defcustom supertag-sync-auto-start-initial-delay 0.5
  "Seconds Emacs must be idle before the first auto-start attempt.
Emacs is not idle while it starts up, so the attempt comes after the init
file has run."
  :type 'number
  :group 'supertag-sync)

(defcustom supertag-sync-auto-start-retry-interval 5
  "Seconds between auto-start retry attempts when directories are not yet
available."
  :type 'integer
  :group 'supertag-sync)

(defcustom supertag-sync-auto-start-max-retries 24
  "Maximum number of auto-start retries before giving up.
With the default interval, this caps retries to about 2 minutes."
  :type 'integer
  :group 'supertag-sync)

(defvar supertag-sync--auto-start-timer nil
  "Internal timer used for deferred auto-start of the sync worker.")

(defvar supertag-sync--auto-start-retries-left 0
  "Internal counter for remaining auto-start retries.")

;; Tag write-format configuration and token rules are owned by supertag-tag.


;; Native Org tags are not part of the Supertag namespace unless opted in.
(defcustom supertag-sync-import-org-tags nil
  "When non-nil, import Org native `:tag:' syntax as tag occurrences.
Import is read-only and never modifies Org files."
  :type 'boolean
  :group 'supertag-sync)

;;; Variables

(defvar supertag-sync--state (make-hash-table :test 'equal)
  "Track file modification states.
Key: file path
Value: last sync time")

(defvar supertag-sync--internal-modifications (make-hash-table :test 'equal)
  "Track files modified internally by Supertag code.
Key: file path (absolute)
Value: timestamp of last internal modification.
This is used to distinguish internal modifications (by automation/UI) from
external modifications (by user/other tools), preventing unnecessary re-sync.")

(defvar supertag-sync--deferred-files (make-hash-table :test 'equal)
  "Files processed while destructive sync is disabled.
These files will be re-verified once the snapshot becomes complete.")

(defvar supertag-sync--is-full-rescan-p nil
  "Dynamically bound to t during a full rescan.
This allows special behavior, like one-time import of legacy tags.")

(defvar supertag-automation-sync--enabled)

;;; Helper functions for accessing sync state data

(defun supertag--mark-internal-modification (file)
  "Mark FILE as internally modified by Supertag.
FILE should be an absolute path. This function records the current time
to prevent sync from re-parsing the file we just modified."
  (when file
    (let ((abs-file (file-truename (expand-file-name file))))
      (puthash abs-file (supertag-current-time) supertag-sync--internal-modifications))))

(defun supertag--clear-internal-modification (file)
  "Forget the internal modification marker for FILE."
  (when file
    (remhash (file-truename (expand-file-name file))
             supertag-sync--internal-modifications)))

(defun supertag--is-internal-modification-p (file)
  "Check if FILE was recently modified internally by Supertag.
Returns t if the file's modification time is within 1 second of the last
internal modification timestamp, indicating this save is from Supertag code."
  (when file
    (let* ((abs-file (file-truename (expand-file-name file)))
           (last-internal (gethash abs-file supertag-sync--internal-modifications))
           (file-mtime (when (file-exists-p abs-file)
                        (file-attribute-modification-time (file-attributes abs-file)))))
      (and last-internal
           file-mtime
           ;; If file mtime is within 2 seconds after internal modification, skip sync
           (time-less-p file-mtime (time-add last-internal 2))))))

(defun supertag-sync--get-state-table ()
  "Get the actual state hash table from supertag-sync--state.
Handles both old format (direct hash table) and new format (plist with
:sync-state key)."
  (cond
   ((hash-table-p supertag-sync--state)
    ;; Old format: direct hash table
    supertag-sync--state)
   ((and (listp supertag-sync--state) (plist-get supertag-sync--state :sync-state))
    ;; New format: plist with :sync-state key
    (plist-get supertag-sync--state :sync-state))
   (t
    ;; Fallback: create empty hash table
    (let ((new-table (make-hash-table :test 'equal)))
      (setq supertag-sync--state (list :sync-state new-table))
      new-table))))

(defun supertag-sync--ensure-state-format ()
  "Ensure supertag-sync--state is in the correct format for current code.
If it's a hash table, wrap it in a plist so metadata can be stored."
  (cond
   ((hash-table-p supertag-sync--state)
    (setq supertag-sync--state (list :sync-state supertag-sync--state)))
   ((and (listp supertag-sync--state)
         (plist-get supertag-sync--state :sync-state))
    supertag-sync--state)
   (t
    (setq supertag-sync--state (list :sync-state (make-hash-table :test 'equal))))))

(defun supertag-sync--snapshot-get ()
  "Return snapshot metadata stored in sync state."
  (when (and (listp supertag-sync--state)
             (plist-get supertag-sync--state :snapshot))
    (plist-get supertag-sync--state :snapshot)))

(defun supertag-sync--snapshot-set (snapshot)
  "Store SNAPSHOT metadata in sync state (in-memory)."
  (supertag-sync--ensure-state-format)
  (setq supertag-sync--state (plist-put supertag-sync--state :snapshot snapshot))
  snapshot)

(defun supertag-sync--snapshot-status ()
  "Return current snapshot status symbol, or nil."
  (plist-get (supertag-sync--snapshot-get) :status))

(defun supertag-sync--allow-destructive-p ()
  "Return non-nil when destructive sync operations are allowed."
  (or (not supertag-sync-snapshot-guard)
      (eq (supertag-sync--snapshot-status) 'complete)))

(defun supertag-sync--ensure-state-source ()
  "Ensure in-memory sync state matches the current data directory."
  (let ((state-file (supertag-sync--state-file)))
    (unless (and (stringp supertag-sync--state-source)
                 (string= supertag-sync--state-source state-file))
      (supertag-sync-load-state))))


;;; --- Sync Mechanism ---

;; Core Functions - File State Tracking

(defvar supertag-sync--truename-directory-cache nil
  "Memoized canonical directory list for `supertag-sync--in-scope-path-p'.
A cons of (CONFIGURED-DIRS . TRUENAME-DIRS), reused while CONFIGURED-DIRS
stays `equal'.  The scope predicate runs once per file during full scans, so
`file-truename' on every configured directory must not repeat per file.
Re-pointing a symlinked directory mid-session keeps the cached target until
CONFIGURED-DIRS changes; restart or reconfigure to refresh.")

(defun supertag-sync--truename-directories (dirs)
  "Return DIRS canonicalised to trailing-slash truenames.
Mirrors `supertag-git--truename-dir': `file-truename' (not just
`expand-file-name') is what makes a configured directory reached through a
symlink match, e.g. `~/org' -> `/mnt/data/org' or macOS's `/var' ->
`/private/var'.  Missing directory entries are fine, since `file-truename'
resolves only the ancestors that exist.  Result is cached; see
`supertag-sync--truename-directory-cache'."
  (if (and supertag-sync--truename-directory-cache
           (equal (car supertag-sync--truename-directory-cache) dirs))
      (cdr supertag-sync--truename-directory-cache)
    (let ((resolved (mapcar (lambda (dir)
                              (file-name-as-directory
                               (file-truename (expand-file-name dir))))
                            dirs)))
      (setq supertag-sync--truename-directory-cache
            (cons (copy-sequence dirs) resolved))
      resolved)))

(defvar supertag-sync--directory-truenames nil
  "Hash table of directory -> its truename, or nil outside a vault pass.
`file-truename' resolves every component of a path, which costs more than
the rest of the scope check.  A pass over a whole vault binds this so that
each directory is resolved once rather than once per file in it.")

(defmacro supertag-sync--with-directory-truenames (&rest body)
  "Run BODY resolving each directory's truename at most once."
  (declare (indent 0) (debug t))
  `(let ((supertag-sync--directory-truenames
          (or supertag-sync--directory-truenames
              (make-hash-table :test 'equal))))
     ,@body))

(defun supertag-sync--truename-directory-of (file)
  "Return the directory part of the truename of FILE."
  (let ((file (expand-file-name file)))
    ;; Only a file that is not itself a symlink is sure to live in the
    ;; truename of its directory.
    (if (or (null supertag-sync--directory-truenames)
            (file-symlink-p file))
        (file-name-directory (file-truename file))
      (let ((dir (file-name-directory file)))
        (or (gethash dir supertag-sync--directory-truenames)
            (puthash dir (file-name-as-directory (file-truename dir))
                     supertag-sync--directory-truenames))))))

(defun supertag-sync--in-scope-path-p (file)
  "Check if FILE path is within synchronization scope.
Does not require the file to exist: `file-truename' still resolves the
existing ancestors of a missing path.
FILE and both configured directory lists are compared as truenames, so a
`supertag-sync-directories' entry that goes through a symlink still matches.
The same reasoning is spelled out above `supertag-git--truename-dir'."
  (when file
    (let* ((file-dir (supertag-sync--truename-directory-of file))
           (excluded (and supertag-sync-exclude-directories
                          (cl-some (lambda (dir) (string-prefix-p dir file-dir))
                                   (supertag-sync--truename-directories
                                    supertag-sync-exclude-directories))))
           (sync-dirs (supertag-sync--effective-directories))
           (included (if sync-dirs
                         (cl-some (lambda (dir) (string-prefix-p dir file-dir))
                                  (supertag-sync--truename-directories sync-dirs))
                       t)))
      (and included
           (not excluded)
           (string-match-p supertag-sync-file-pattern file)))))

(defun supertag-sync--scanned-name (file)
  "Return the name a scan of the sync directories gives FILE.
A scan names each file after its configured directory, and the sync state
and the nodes of the file carry that name.  FILE reached another way, such
as through its truename while the directory goes through a symlink, would
otherwise be synchronized as a second file."
  (let ((dirs (supertag-sync--effective-directories)))
    (or (and (cl-some (lambda (dir)
                        (string-prefix-p (file-name-as-directory dir) file))
                      dirs)
             file)
        (let ((true (file-truename file))
              (roots (supertag-sync--truename-directories dirs))
              found)
          (while (and dirs (not found))
            (when (string-prefix-p (car roots) true)
              (setq found (concat (file-name-as-directory (car dirs))
                                  (substring true (length (car roots))))))
            (setq dirs (cdr dirs)
                  roots (cdr roots)))
          found)
        file)))

(defun supertag-sync--in-sync-scope-p (file)
  "Check if FILE is within synchronization scope.
Returns t if file should be synchronized based on configured directories.
If no directories are configured, returns t for all org files."
  (when (and file (file-exists-p file))
    (supertag-sync--in-scope-path-p file)))

(defun supertag-scan-sync-directories (&optional all-files-p)
  "Scan sync directories for org files.
If ALL-FILES-P is non-nil, return all files in scope.
Otherwise, returns a list of new files that are not yet in sync state."
  (let ((files nil)
        (state-table (supertag-sync--get-state-table)))
    (let ((sync-dirs (supertag-sync--effective-directories)))
      (if (not sync-dirs)
          (message "WARNING: supertag-sync-directories is not configured. No files will be synced.")
        (dolist (dir sync-dirs)
          (when (file-exists-p dir)
            (let ((dir-files (directory-files-recursively
                              dir supertag-sync-file-pattern t)))
              (dolist (file dir-files)
                (when (and (file-regular-p file)
                           (supertag-sync--in-sync-scope-p file)
                           (or all-files-p
                               (not (gethash file state-table))))
                  (push file files))))))))
    files))

(defun supertag-sync--snapshot-build ()
  "Build a snapshot of sync directories.
Returns a plist with :status, :files, :scope, :errors, :observed-at."
  (let* ((sync-dirs (supertag-sync--effective-directories))
         (errors '()))
    (cond
     ((not sync-dirs)
      (list :status 'unavailable
            :files nil
            :scope nil
            :errors (list "sync directories not configured")
            :observed-at (supertag-current-time)))
     (t
      (let ((unavailable nil))
        (dolist (dir sync-dirs)
          (unless (and (file-directory-p dir)
                       (file-readable-p dir))
            (push (list :dir dir :error 'unavailable) errors)
            (setq unavailable t)))
        (if unavailable
            (list :status 'unavailable
                  :files nil
                  :scope sync-dirs
                  :errors (nreverse errors)
                  :observed-at (supertag-current-time))
          (let ((partial nil)
                (files '()))
            (supertag-sync--with-directory-truenames
              (dolist (dir sync-dirs)
                (condition-case err
                    (let ((dir-files (directory-files-recursively
                                      dir supertag-sync-file-pattern t)))
                      (dolist (file dir-files)
                        (when (and (file-regular-p file)
                                   (supertag-sync--in-scope-path-p file))
                          (push file files))))
                  (error
                   (setq partial t)
                   (push (list :dir dir :error (error-message-string err)) errors)))))
            (list :status (if partial 'partial 'complete)
                  :files (delete-dups files)
                  :scope sync-dirs
                  :errors (nreverse errors)
                  :observed-at (supertag-current-time)))))))))

(defun supertag-sync--snapshot-new-files (snapshot-files)
  "Return files that are in SNAPSHOT-FILES but missing from sync state."
  (let ((state-table (supertag-sync--get-state-table))
        (new-files '()))
    (dolist (file snapshot-files)
      (unless (gethash file state-table)
        (push file new-files)))
    new-files))

(defun supertag-sync--snapshot-files-to-remove (snapshot-files)
  "Return state files that should be removed based on SNAPSHOT-FILES."
  (let ((state-table (supertag-sync--get-state-table))
        (snapshot-set (make-hash-table :test 'equal))
        (files-to-remove '()))
    (dolist (file snapshot-files)
      (puthash file t snapshot-set))
    (maphash
     (lambda (file _state)
       (let ((in-scope (supertag-sync--in-scope-path-p file)))
         (when (or (not in-scope)
                   (not (gethash file snapshot-set)))
           (push file files-to-remove))))
     state-table)
    files-to-remove))

(defun supertag-sync-update-state (file &optional content-hash)
  "Update sync state for FILE.
If CONTENT-HASH is provided, store it in the state entry."
  (when (file-exists-p file)
    (let* ((state-table (supertag-sync--get-state-table))
           (attrs (file-attributes file))
           (mtime (file-attribute-modification-time attrs))
           (size (file-attribute-size attrs))
           (old-state (gethash file state-table))
           (old-hash (when (and (listp old-state) (keywordp (car old-state)))
                       (plist-get old-state :content-hash))))
      (puthash file
               (list :mtime mtime
                     :size size
                     :content-hash (or content-hash old-hash)
                     :hash-algo 'sha1)
               state-table))))

(defun supertag-sync--state-mtime (state)
  "Extract the last sync mtime from STATE.
STATE may be a time value or a plist containing the :mtime keyword."
  (cond
   ((and (listp state) (keywordp (car state)))
    (plist-get state :mtime))
   (t state)))

(defun supertag-sync--normalize-time (time-val)
  "Normalize TIME-VAL to a value accepted by `time-less-p`."
  (cond
   ((null time-val) nil)
   ((stringp time-val)
    (apply #'encode-time
           (mapcar (lambda (x) (or x 0))
                   (parse-time-string time-val))))
   ((numberp time-val)
    (seconds-to-time time-val))
   (t time-val)))

(defun supertag-sync-check-state (file)
  "Check if FILE needs synchronization.
Returns t if file has been modified since last sync."
  (let ((state-table (supertag-sync--get-state-table)))
    (when-let* ((state (gethash file state-table)))
      (let ((last-sync (supertag-sync--normalize-time
                        (supertag-sync--state-mtime state)))
            (mtime (file-attribute-modification-time
                       (file-attributes file))))
        (and last-sync mtime (time-less-p last-sync mtime))))))

(defun supertag-get-modified-files ()
  "Get list of files that need synchronization.
Returns files that have been modified since last sync."
  (let ((files nil)
        (state-table (supertag-sync--get-state-table)))
    (maphash
     (lambda (file _state)
       (when (and (file-exists-p file)
                  (supertag-sync--in-sync-scope-p file)
                  (supertag-sync-check-state file))
         (push file files)))
     state-table)
    files))

;; --- State Management ---

(defun supertag-sync-import-file (file)
  "Import data from FILE into the store.
Reads the file, parses Org nodes, and creates/updates them using hybrid
architecture.
Returns a list of imported/updated node data."
  (let ((nodes (supertag--parse-org-nodes file))
        (imported-nodes '()))
    ;; Process each node with hybrid architecture (strict validation + direct storage)
    (dolist (node-props nodes)
      (let ((imported-node (supertag-node-create node-props)))
        (push imported-node imported-nodes)))
    (nreverse imported-nodes)))

(defun supertag-sync-export-file (file)
  "Export data from the store to FILE.
Finds all nodes associated with FILE, generates Org content,
and writes it to the file.
Returns a list of exported node data."
  (let* ((nodes (supertag-find-nodes-by-file file))
         (node-data (mapcar #'cdr nodes)) ; Extract only the node data from (id . data) pairs
         (org-content (supertag--generate-org-content node-data)))
    (with-temp-file file (insert org-content))
    node-data))

  (defun supertag--generate-org-content (nodes)
  "Helper function to generate Org content from node plists.
NODES is a list of node plists.
Returns a string containing the Org content."
    (with-temp-buffer
      (dolist (node nodes)
        (let* ((title (plist-get node :title))
               (tags (plist-get node :tags))
               (level (or (plist-get node :level) 1))
               (content (or (plist-get node :content) ""))
               (id (plist-get node :id))
               (tags-part (supertag--format-inline-tags tags)))
          ;; Reconstruct the node with inline tag formatting.
          (insert (format "%s %s%s\n"
                          (make-string level ?*)
                          title
                          tags-part))
          (insert (format ":PROPERTIES:\n:ID:       %s\n:END:\n" id))
          ;; Insert content
          (when content
            (insert content))
          (unless (or (string-empty-p content) (string-suffix-p "\n" content))
            (insert "\n"))))
      (buffer-string)))

(defvar supertag-sync--state-unsaved nil
  "Non-nil while the queue has changed sync state that is not on disk.")

(defvar supertag-sync--state-saved-at 0.0
  "When the sync state was last written, as a float time.")

(defconst supertag-sync--state-checkpoint-seconds 30
  "How long a draining queue may run before its sync state is written.")

(defun supertag-sync-save-state ()
  "Save sync state to file."
  (supertag-sync--ensure-state-format)
  (let ((state-file (supertag-sync--state-file)))
    (make-directory (file-name-directory state-file) t)
    (with-temp-file state-file
      (let ((print-length nil)
            (print-level nil))
        (prin1 supertag-sync--state (current-buffer))))
    (setq supertag-sync--state-source state-file
          supertag-sync--state-unsaved nil
          supertag-sync--state-saved-at (float-time))))

(defun supertag-sync-load-state ()
  "Load sync state from file.
If file doesn't exist, initialize empty state.
Returns the loaded or initialized sync state."
  (let ((state-file (supertag-sync--state-file)))
    (condition-case err
        (let ((result
               (if (file-exists-p state-file)
                   (with-temp-buffer
                     (insert-file-contents state-file)
                   (goto-char (point-min))
                   ;; Check if file is empty
                   (if (= (point-min) (point-max))
                       (progn
                         (message "Warning: Sync state file is empty, initializing new state")
                         (setq supertag-sync--state (make-hash-table :test 'equal))
                         (supertag-sync--ensure-state-format)
                         (setq supertag-sync--state-source state-file))
                     (condition-case read-err
                         (progn
                           (setq supertag-sync--state (read (current-buffer)))
                           (message "Loaded sync state with %d entries"
                                    (let ((state-table (supertag-sync--get-state-table)))
                                      (if (hash-table-p state-table)
                                          (hash-table-count state-table)
                                        0)))
                           ;; Ensure the loaded state is in the correct format
                           (supertag-sync--ensure-state-format)
                           (setq supertag-sync--state-source state-file)
                           supertag-sync--state)
                       (error
                        (message "Error reading sync state: %s" (error-message-string read-err))
                        (message "Initializing new sync state")
                        (setq supertag-sync--state (make-hash-table :test 'equal))
                        (supertag-sync--ensure-state-format)
                        (setq supertag-sync--state-source state-file)
                        supertag-sync--state))))
               ;; Initialize empty state if file doesn't exist
               (progn
                 (message "Sync state file does not exist, initializing empty state")
                 (setq supertag-sync--state (make-hash-table :test 'equal))
                 ;; Save the initial state
                 (supertag-sync-save-state)
                 supertag-sync--state))))
          result)
      (error
       (message "Critical error loading sync state: %s" (error-message-string err))
       (message "Initializing fresh sync state")
       (setq supertag-sync--state (make-hash-table :test 'equal))
       (setq supertag-sync--state-source state-file)
       supertag-sync--state))))

;; --- Check and sync ---

(defun supertag-sync-ensure-directories ()
  "Ensure sync directories are properly configured."
  (unless (supertag-sync--effective-directories)
    (message "Warning: `supertag-sync-directories` is not set. Auto-sync will not occur.")))

(defvar supertag-sync--timer nil
  "Timer for periodic sync checks.")

(defvar supertag-sync--idle-dispatch nil
  "Idle timer used to defer sync execution until Emacs is idle.")

(defun supertag-sync--cancel-idle-dispatch ()
  "Cancel any pending idle dispatch for the sync worker."
  (when (timerp supertag-sync--idle-dispatch)
    (cancel-timer supertag-sync--idle-dispatch))
  (setq supertag-sync--idle-dispatch nil))

(defun supertag-sync--queue-idle-dispatch ()
  "Schedule sync execution for the next idle period."
  (unless (timerp supertag-sync--idle-dispatch)
    (setq supertag-sync--idle-dispatch
          (run-with-idle-timer
           (max supertag-sync-idle-delay 0)
           nil
           #'supertag-sync--run-idle-dispatch))))

(defun supertag-sync--run-idle-dispatch ()
  "Run the sync worker after idle delay."
  (setq supertag-sync--idle-dispatch nil)
  (when (fboundp 'supertag-sync--check-and-sync)
    (supertag-sync--check-and-sync)))

;;; Auto-start manager -------------------------------------------------

(defun supertag-sync--dirs-ready-p ()
  "Return non-nil when all configured sync directories exist and are accessible."
  (let ((sync-dirs (supertag-sync--effective-directories)))
    (and sync-dirs
         (cl-every #'file-directory-p sync-dirs))))

(defun supertag-sync--cancel-auto-start ()
  "Cancel any pending auto-start timer."
  (when (timerp supertag-sync--auto-start-timer)
    (cancel-timer supertag-sync--auto-start-timer))
  (setq supertag-sync--auto-start-timer nil)
  (setq supertag-sync--auto-start-retries-left 0))

(defun supertag-sync--auto-start-tick ()
  "Auto-start attempt: start sync when directories are ready, otherwise retry."
  (cond
   ((not supertag-sync-auto-start)
    (supertag-sync--cancel-auto-start))
   ((supertag-sync--dirs-ready-p)
    (supertag-sync--cancel-auto-start)
    (message "Supertag: directories ready; starting auto-sync")
    (supertag-sync-start-auto-sync))
   ((<= supertag-sync--auto-start-retries-left 0)
    (supertag-sync--cancel-auto-start)
    (message "Supertag: auto-sync not started; directories unavailable"))
   (t
    (setq supertag-sync--auto-start-retries-left (1- supertag-sync--auto-start-retries-left))
    (when (timerp supertag-sync--auto-start-timer)
      (cancel-timer supertag-sync--auto-start-timer))
    (setq supertag-sync--auto-start-timer
          (run-with-timer (max 1 supertag-sync-auto-start-retry-interval) nil
                          #'supertag-sync--auto-start-tick)))))

(defun supertag-sync-schedule-auto-start ()
  "Schedule deferred auto-start of auto-sync with retries until directories are
ready.
The first attempt waits for Emacs to be idle, later ones for the retry
interval."
  (when supertag-sync-auto-start
    (supertag-sync--cancel-auto-start)
    (setq supertag-sync--auto-start-retries-left supertag-sync-auto-start-max-retries)
    (setq supertag-sync--auto-start-timer
          (run-with-idle-timer
           (max 0 supertag-sync-auto-start-initial-delay)
           nil
           #'supertag-sync--auto-start-tick))))


;; (defun supertag-sync-emergency-recovery ()
;;   "Emergency recovery function to clean up all sync-related timers and state.
;; Use this when experiencing persistent timer-related errors."
;;   (interactive)
;;   (message "Starting emergency recovery for sync system...")

;;   ;; Cancel our timer
;;   (when (timerp supertag-sync--timer)
;;     (cancel-timer supertag-sync--timer)
;;     (setq supertag-sync--timer nil)
;;     (message "Canceled supertag-sync--timer"))

;;   ;; Clean up any other timers that might be calling our function
;;   (let ((all-timers (timer-list))
;;         (cleaned-count 0))
;;     (dolist (timer all-timers)
;;       (when (and (timerp timer)
;;                  (or (equal (timer--function timer) 'supertag-sync--check-and-sync)
;;                      (and (listp (timer--function timer))
;;                           (equal (car (timer--function timer)) 'lambda))))
;;         (cancel-timer timer)
;;         (cl-incf cleaned-count)))
;;     (when (> cleaned-count 0)
;;     )

;;   ;; Reset sync state
;;   (setq supertag-sync--state (make-hash-table :test 'equal))
;;   (message "Reset sync state")

;;   ;; Verify function is defined
;;   (if (fboundp 'supertag-sync--check-and-sync)
;;       (message "Function supertag-sync--check-and-sync is properly defined")
;;     (message "WARNING: Function supertag-sync--check-and-sync is NOT defined"))
;;   (message "Emergency recovery completed. You can now try M-x supertag-sync-start-auto-sync"))

;;; Core Functions - Node Hash Support (from supertag-old/supertag-sync.el)

(defun supertag--node-hash--properties-to-alist (props)
  "Normalize PROPS into an alist of (key . value) pairs for hashing."
  (cond
   ((hash-table-p props)
    (let (alist)
      (maphash (lambda (k v)
                 (push (cons k v) alist))
               props)
      (nreverse alist)))
   ((and (listp props) (consp (car props)))
    ;; Already an alist such as ((:KEY . "value"))
    (cl-copy-list props))
   ((plistp props)
    (let ((cursor props)
          (alist '()))
      (while cursor
        (let ((key (car cursor))
              (val (cadr cursor)))
          (push (cons key val) alist))
        (setq cursor (cddr cursor)))
      (nreverse alist)))
   (t nil)))

(defun supertag--node-hash--property-key-string (key)
  "Return a comparable string representation for property KEY."
  (cond
   ((keywordp key) (symbol-name key))
   ((symbolp key) (symbol-name key))
   ((stringp key) key)
   (t (format "%s" key))))

(defun supertag--node-hash--property-value-string (value)
  "Return stable string representation for property VALUE."
  (cond
   ((null value) "")
   ((stringp value) value)
   (t (format "%s" value))))

(defun supertag--node-hash--value (node key)
  "Return normalized string value for NODE's KEY."
  (pcase key
    ((or :todo :todo-type)
     (or (plist-get node :todo) ""))
    (:raw-value
     (or (plist-get node :raw-value) ""))
    (:olp
     (let ((olp (plist-get node :olp)))
       (cond
        ((listp olp) (string-join olp "/"))
        ((stringp olp) olp)
        (t ""))))
    (:content
     (or (plist-get node :content) ""))
    (:tags
     (let ((tag-list (plist-get node :tags)))
       (cond
        ((listp tag-list) (mapconcat #'identity (sort (copy-sequence tag-list) #'string<) "|"))
        ((stringp tag-list) tag-list)
        (t ""))))
    (:priority
     (or (plist-get node :priority) ""))
    (:properties
     (let* ((raw-props (plist-get node :properties))
            (props-alist (supertag--node-hash--properties-to-alist raw-props)))
       (if (null props-alist)
           ""
         (let* ((sorted (sort (cl-copy-list props-alist)
                              (lambda (a b)
                                (string< (supertag--node-hash--property-key-string (car a))
                                         (supertag--node-hash--property-key-string (car b)))))))
           (mapconcat (lambda (pair)
                        (format "%s=%s"
                                (supertag--node-hash--property-key-string (car pair))
                                (supertag--node-hash--property-value-string (cdr pair))))
                      sorted
                      "|")))))
    (_
     (supertag--node-hash--property-value-string (plist-get node key)))))

(defun supertag-node-hash (node)
  "Calculate hash value for NODE.
Includes the node's ID to ensure absolute uniqueness of the state fingerprint."
  (let* ((id (or (plist-get node :id) "")) ; Ensure ID is part of the hash
         (hash-props
          (delete-dups
           (append supertag-sync-document-fact-hash-props
                   (copy-sequence (or supertag-sync-hash-props '())))))
         (payload (mapconcat
                   (lambda (key)
                     (format "%s=%s"
                             (supertag--node-hash--property-key-string key)
                             (supertag--node-hash--value node key)))
                   hash-props
                   "|")))
    (secure-hash 'sha1 (format "%s|%s" id payload))))

(defun supertag-node-file-node-p (node)
  "Return non-nil when NODE is a file node (level 0).
File nodes represent file-level identity rather than Org headings."
  (eq (plist-get node :level) 0))

(defun supertag-sync--resolve-node-tag-occurrences (props &optional unresolved-p)
  "Resolve PROPS Tag Occurrences against existing Semantic Tags.
The returned copy stores Org tokens in :tag-occurrences, resolved Semantic
Tag IDs in :tags, and unresolved tokens in :unresolved-tags.  Resolution is
read-only and never creates or modifies Semantic Tags.
With UNRESOLVED-P non-nil no Semantic Tag is looked up and every token is
left unresolved, which is how the parser process, having no Store, sees a
node."
  (if (not (or (plist-member props :tag-occurrences)
               (plist-member props :tags)))
      props
    (let* ((raw (if (plist-member props :tag-occurrences)
                    (plist-get props :tag-occurrences)
                  (plist-get props :tags)))
           (occurrences
            (delete-dups (mapcar #'supertag-sanitize-tag-name (or raw '()))))
           resolved unresolved
           (result (copy-sequence props)))
      (dolist (occurrence occurrences)
        (let ((tag-id (and (not unresolved-p)
                           (supertag-tag-resolve-occurrence occurrence))))
          (if tag-id
              (push tag-id resolved)
            (push occurrence unresolved))))
      (setq result (plist-put result :tag-occurrences occurrences))
      (setq result (plist-put result :tags (delete-dups (nreverse resolved))))
      (plist-put result :unresolved-tags (nreverse unresolved)))))

;;; --- Unresolved Document Links ---

(defvar supertag-sync--unresolved-links nil
  "Cons (STORE . TABLE) of the Org links whose target has no node, or nil.
TABLE maps a target ID to a hash-set of the IDs of the nodes whose Org
text links to it.  It is derived from :ref-to and :named-links and rebuilt
on demand whenever STORE is no longer the live Store.  A node that appears
after the nodes linking to it receives their Document Links from here.")

(defun supertag-sync-forget-unresolved-links ()
  "Drop the unresolved-link table so the next use rebuilds it."
  (setq supertag-sync--unresolved-links nil))

(defun supertag-sync--unresolved-links-table ()
  "Return the unresolved-link table of the live Store, building it if stale."
  (unless (and supertag-sync--unresolved-links
               (eq (car supertag-sync--unresolved-links) supertag--store))
    (let ((table (make-hash-table :test 'equal))
          (nodes (supertag-store-get-collection :nodes)))
      (when (hash-table-p nodes)
        (maphash
         (lambda (id node)
           (dolist (target (append
                            (plist-get node :ref-to)
                            (mapcar (lambda (link) (plist-get link :target-id))
                                    (plist-get node :named-links))))
             (when (and (stringp target) (not (gethash target nodes)))
               (puthash id t
                        (or (gethash target table)
                            (puthash target (make-hash-table :test 'equal)
                                     table))))))
         nodes))
      (setq supertag-sync--unresolved-links (cons supertag--store table))))
  (cdr supertag-sync--unresolved-links))

(defun supertag-sync--note-unresolved-link (source-id target-id)
  "Remember that SOURCE-ID links to TARGET-ID, which has no node."
  (let ((table (supertag-sync--unresolved-links-table)))
    (puthash source-id t
             (or (gethash target-id table)
                 (puthash target-id (make-hash-table :test 'equal) table)))))

(defun supertag-sync--project-links-to (id counters)
  "Project the Document Links that other nodes hold to the node ID.
Call this once ID is in the Store.  COUNTERS receives the relation totals."
  (let* ((table (supertag-sync--unresolved-links-table))
         (sources (gethash id table)))
    (when sources
      (remhash id table)
      (maphash (lambda (source-id _present)
                 (when-let* ((source (supertag-node-get source-id)))
                   (supertag--process-node-references source counters)
                   (supertag--process-node-named-links source counters)))
               sources))))

(defun supertag-sync--delete-node (id)
  "Delete the node ID, whose heading or file is gone.
The nodes whose Org text still links to ID are remembered, so their
Document Links return if ID reappears, for instance in another file."
  (let ((sources (mapcar (lambda (relation) (plist-get relation :from))
                         (cl-remove-if-not
                          #'supertag-relation-document-link-p
                          (supertag-relation-find-by-to id :reference)))))
    (supertag-node-delete id)
    (dolist (source sources)
      (unless (equal source id)
        (supertag-sync--note-unresolved-link source id)))))

(defun supertag-sync--delete-nodes (ids counters)
  "Delete the nodes IDS in one bulk deletion and return how many were deleted.
COUNTERS, when non-nil, receives the :nodes-deleted total.  Return nil
without deleting anything when IDS exceeds `supertag-sync-max-delete-ratio'
or `supertag-sync-max-delete-count'."
  (let* ((nodes (supertag-store-get-collection :nodes))
         (total (if (hash-table-p nodes) (hash-table-count nodes) 0))
         (count (length ids))
         (ratio (if (> total 0) (/ (float count) total) 0.0)))
    (if (and (> count 0)
             (or (> ratio (or supertag-sync-max-delete-ratio 1.0))
                 (> count (or supertag-sync-max-delete-count
                              most-positive-fixnum))))
        (progn
          (message (concat "Supertag: not deleting %d of %d nodes (%.0f%%); "
                           "that exceeds the safety caps.  Adjust "
                           "`supertag-sync-max-delete-ratio'/"
                           "`supertag-sync-max-delete-count' if intentional.")
                   count total (* ratio 100))
          nil)
      (dolist (id ids)
        (supertag-sync--delete-node id))
      (when counters
        (setf (plist-get counters :nodes-deleted)
              (+ count (or (plist-get counters :nodes-deleted) 0))))
      count)))

(defun supertag-sync--parsed-hash (props)
  "Return the hash PROPS get when none of their Tag Occurrences resolves."
  (supertag-node-hash (supertag-sync--resolve-node-tag-occurrences props t)))

(defun supertag-sync--projected-hash (props)
  "Return the hash of PROPS, whose Tag Occurrences are already resolved.
The parser process hashed the node as `supertag-sync--parsed-hash' does and
left the result in :parsed-hash.  That is the hash of PROPS when none of
their occurrences resolved to a Semantic Tag."
  (let ((parsed (plist-get props :parsed-hash)))
    (if (and parsed (null (plist-get props :tags)))
        parsed
      (supertag-node-hash props))))

(defun supertag-db-add-with-hash (id props &optional counters)
  "Add node with ID and PROPS to database, including hash value.
Existing creation time is preserved while file-backed properties are updated.
This function also handles tag resolution and reference relations.
COUNTERS is an optional plist for tracking statistics."
  (let ((existing (supertag-node-get id)))
    (when-let* ((created-at (plist-get existing :created-at)))
      (setq props (plist-put (copy-sequence props) :created-at created-at)))
    (setq props (supertag-sync--resolve-node-tag-occurrences props))
    (let ((node-hash (supertag-sync--projected-hash props)))
      ;; :parsed-hash is a note from the parser process, not a node property.
      (when (plist-member props :parsed-hash)
        (setq props (copy-sequence props))
        (cl-remf props :parsed-hash))
      ;; Ensure :id, :type and :hash are added to props while preserving existing fields
      (let ((node-props (plist-put props :id id)))
        (setq node-props (plist-put node-props :type :node))
        (setq node-props (plist-put node-props :hash node-hash))
        ;; Reference reconciliation is part of projection, not reporting.
        (let ((reference-counters
               (or counters (list :references-created 0 :references-deleted 0)))
              (current-refs (plist-get node-props :ref-to))
              (current-named-links (plist-get node-props :named-links)))
          (supertag--cleanup-orphaned-references
           id current-refs reference-counters)
          (supertag--cleanup-orphaned-named-links
           id current-named-links reference-counters)
          (supertag--process-node-references node-props reference-counters)
          (supertag--process-node-named-links node-props reference-counters)
          (prog1 (if existing
                     (supertag-node-update id (lambda (_previous) node-props))
                   (supertag-node-create node-props))
            ;; Links parsed before this node existed could not be projected.
            (supertag-sync--project-links-to id reference-counters)))))))

(defun supertag-node-changed-p (old-node new-node)
  "Compare OLD-NODE and NEW-NODE to detect changes.
If OLD-NODE doesn't have a hash value, calculate it on the fly."
  (let* ((projected-new
          (supertag-sync--resolve-node-tag-occurrences new-node))
         (old-hash (or (plist-get old-node :hash)
                       (supertag-node-hash old-node)))
         (new-hash (supertag-sync--projected-hash projected-new)))
    ;; The stored hash is not refreshed when only the location is rewritten
    ;; (`supertag-node-set-location'), so compare :file directly.
    (or (not (equal (plist-get old-node :file)
                    (plist-get new-node :file)))
        (not (string= old-hash new-hash)))))

(defun supertag-sync--reconcile-node (new-props &optional counters)
  "Reconcile NEW-PROPS with its current node Projection.
COUNTERS, when non-nil, receives create/update counts.  Both file and point
sync use this function so change detection, tag membership, and reference
reconciliation cannot diverge.  Org parsing replaces the complete Document
Projection; Semantic Facts live in their own Store collections."
  (let* ((id (plist-get new-props :id))
         (old-props (and id (supertag-node-get id))))
    (cond
     ((null id) nil)
     ((null old-props)
      (prog1 (supertag-db-add-with-hash id new-props counters)
        (when counters
          (setf (plist-get counters :nodes-created)
                (1+ (or (plist-get counters :nodes-created) 0))))))
     ((or supertag-sync--is-full-rescan-p
          (supertag-node-changed-p old-props new-props))
      (prog1
          (supertag-db-add-with-hash id new-props counters)
        (when counters
          (setf (plist-get counters :nodes-updated)
                (1+ (or (plist-get counters :nodes-updated) 0))))))
     (t old-props))))

(defun supertag-sync--buffer-may-hold-named-links-p ()
  "Return non-nil when the current buffer could hold a named relation link.
A link of a relation type spells that type before a colon, so a buffer
without such text needs no parse to know it has none."
  (when-let* ((types (supertag-text-link-relation-types)))
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search t))
        (re-search-forward (concat (regexp-opt types) ":") nil t)))))

(defun supertag-sync--extract-file-header-named-links ()
  "Extract named links from a stripped copy of the current file header."
  ;; The copy below starts Org mode and parses again, for every file.
  (when (supertag-sync--buffer-may-hold-named-links-p)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (with-temp-buffer
        (insert text)
        (let ((inhibit-modification-hooks t)
              (org-mode-hook nil)
              (org-inhibit-startup t)
              (org-agenda-inhibit-startup t))
          (delay-mode-hooks (org-mode))
          (setq-local org-element-use-cache nil)
          (supertag-sync--strip-embed-block-contents
           (or (buffer-file-name) "<file-header>"))
          (narrow-to-region
           (point-min)
           (save-excursion
             (goto-char (point-min))
             (if (re-search-forward "^\\*+\\s-" nil t)
                 (match-beginning 0)
               (point-max))))
          (supertag--extract-named-links
           (org-element-contents (org-element-parse-buffer))))))))

(defun supertag-sync--file-header-identity ()
  "Return (ID . LINK-TYPE) for the file in the current buffer.
Both are nil when the file has no identity.  Identity selection follows
`supertag-file-id-source'.  Only the text is searched, so a caller that
wants the ID alone pays for no parse."
  (save-excursion
    (goto-char (point-min))
    (let (org-id denote-id)
      ;; A file-level Org ID must be in the drawer at the start of the file.
      (skip-chars-forward " \t\r\n")
      (when (looking-at "^:PROPERTIES:")
        (let ((drawer-end (save-excursion
                            (when (re-search-forward "^:END:" nil t)
                              (point)))))
          (when (and drawer-end
                     (re-search-forward "^:ID:\\s-*\\(.+\\)" drawer-end t))
            (setq org-id (string-trim (match-string 1))))))
      ;; Denote mirrors its persistent file identifier in Org front matter.
      (goto-char (point-min))
      (when (re-search-forward
             "^#\\+IDENTIFIER:\\s-*\\(.+\\)"
             (min 2000 (point-max)) t)
        (setq denote-id (string-trim (match-string 1))))
      (pcase supertag-file-id-source
        ((or 'org-roam 'org-id)
         (cons org-id (and org-id 'id)))
        ('denote
         (cons denote-id (and denote-id 'denote)))
        ('auto
         (cons (or org-id denote-id)
               (cond (org-id 'id) (denote-id 'denote))))
        ('disabled (cons nil nil))
        (_ (user-error "Unknown file node policy: %S"
                       supertag-file-id-source))))))

(defun supertag-sync--parse-file-header ()
  "Parse file header in current buffer for file node properties.
Returns a plist with identity, title, tags, and top-level :ref-to links.
Identity selection follows `supertag-file-id-source'."
  (supertag-text-link-refresh)
  (save-excursion
    (goto-char (point-min))
    (let* ((identity (supertag-sync--file-header-identity))
           (id (car identity))
           (link-type (cdr identity))
           title file-tags ref-to named-links)
      ;; Read #+TITLE:
      (goto-char (point-min))
      (when (re-search-forward
             "^#\\+TITLE:\\s-*\\(.+\\)"
             (min 2000 (point-max)) t)
        (setq title (string-trim (match-string 1))))
      ;; Read #+FILETAGS:
      (goto-char (point-min))
      (when (re-search-forward
             "^#\\+FILETAGS:\\s-*\\(.+\\)"
             (min 2000 (point-max)) t)
        (let ((raw (string-trim (match-string 1))))
          (setq file-tags (supertag-sync--parse-filetags raw))))
      ;; File-node content ends where the first heading begins.
      (setq ref-to
            (save-restriction
              (narrow-to-region
               (point-min)
               (save-excursion
                 (goto-char (point-min))
                 (if (re-search-forward "^\\*+\\s-" nil t)
                     (match-beginning 0)
                   (point-max))))
              (cl-delete-duplicates
               (supertag--extract-refs
                (org-element-contents (org-element-parse-buffer)))
               :test #'equal)))
      (setq named-links (supertag-sync--extract-file-header-named-links))
      (append (list :id id :link-type link-type :title title
                    :file-tags file-tags :ref-to ref-to)
              (when named-links (list :named-links named-links))))))

(defun supertag-sync--parse-filetags (raw)
  "Parse RAW #+FILETAGS: value into a list of tag strings.
Handles both colon-separated (:tag1:tag2:) and space-separated formats."
  (let ((clean (string-trim raw)))
    (if (string-empty-p clean)
        nil
      (cl-remove-if #'string-empty-p
                    (mapcar #'string-trim
                            (if (string-prefix-p ":" clean)
                                (split-string clean ":" t)
                              (split-string clean nil t)))))))

(defun supertag-sync--file-node-props (file file-header)
  "Return the properties of the file node of FILE, from FILE-HEADER.
FILE-HEADER is a plist from `supertag-sync--parse-file-header' that holds
an :id."
  (append (list :id (plist-get file-header :id)
                :file file
                :level 0
                :link-type (or (plist-get file-header :link-type) 'id)
                :title (plist-get file-header :title)
                :tags (plist-get file-header :file-tags)
                :ref-to (plist-get file-header :ref-to)
                :position 1
                :content nil
                :properties nil)
          (when-let* ((named-links (plist-get file-header :named-links)))
            (list :named-links named-links))))

(defun supertag-sync--upsert-file-node (file file-header counters)
  "Upsert a file node for FILE using FILE-HEADER properties.
FILE-HEADER is a plist from `supertag-sync--parse-file-header'.
Return its persistent ID, or nil when the selected policy finds none."
  (when-let* ((file-id (plist-get file-header :id)))
    (let* ((props (append (supertag-sync--file-node-props file file-header)
                          (when-let* ((hash (plist-get file-header :parsed-hash)))
                            (list :parsed-hash hash))))
           (existing (supertag-node-get file-id)))
      (if existing
          (when (supertag-node-changed-p existing props)
            (supertag-db-add-with-hash file-id props counters)
            (when counters
              (setf (plist-get counters :nodes-updated)
                    (1+ (or (plist-get counters :nodes-updated) 0)))))
        (supertag-db-add-with-hash file-id props counters)
        (when counters
          (setf (plist-get counters :nodes-created)
                (1+ (or (plist-get counters :nodes-created) 0)))))
      file-id)))

(defvar supertag-sync--verified-ids nil
  "Hash table of the node IDs a full rescan read from their files, or nil.
A value is (FILE . FILE-NODE-P): the file the ID was read from, and whether
it was read as the identity of the file itself.  `supertag-reindex-org'
binds it so the validation that ends the rescan does not read every file a
second time.")

(defvar supertag-sync--yield-to-input nil
  "Non-nil while a background sync may abandon parsing when the user types.
Only the queue worker binds this; a sync the user asked for runs to the end.")

(defun supertag-sync--read-file-records (file old-hash force &optional ids)
  "Read FILE and return what a sync needs to know about it, as a plist.
:hash is the hash of its text.  When that is OLD-HASH and FORCE is nil the
file was not parsed and :unchanged is t; with IDS non-nil, :ids then lists
the IDs of its heading nodes.  Otherwise :header holds the properties of
the file node and :nodes the records of its heading nodes.
Nothing here reads or writes the Store, so the parser process runs it too."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((hash (secure-hash 'sha1 (current-buffer))))
      (cond
       ((not (and old-hash (string= hash old-hash) (not force)))
        (list :hash hash
              :header (supertag-sync--parse-file-header)
              :nodes (supertag-sync--parse-nodes file)))
       (ids
        (list :hash hash :unchanged t
              :ids (mapcar (lambda (node) (plist-get node :id))
                           (supertag-sync--parse-nodes file))))
       (t (list :hash hash :unchanged t))))))

(defun supertag-sync--apply-file-records (file records counters)
  "Reconcile the Store with RECORDS, read from FILE.
RECORDS is a plist from `supertag-sync--read-file-records'.  COUNTERS is a
plist for tracking :nodes-created, :nodes-updated, and :nodes-deleted.
Return `reconciled' when FILE was parsed and its vanished nodes removed."
  (let* ((should-parse (not (plist-get records :unchanged)))
         (content-hash (plist-get records :hash))
         (file-header (plist-get records :header))
         (nodes-from-file (plist-get records :nodes))
         (allow-destructive (supertag-sync--allow-destructive-p))
         (deferred-entry (gethash file supertag-sync--deferred-files))
         (deferred-deletions nil))
    (if (not should-parse)
        ;; Just update state (mtime + hash)
        (supertag-sync-update-state file content-hash)
      (when supertag-sync--verified-ids
        (when-let* ((file-id (plist-get file-header :id)))
          (puthash file-id (cons file t) supertag-sync--verified-ids))
        (dolist (node-props nodes-from-file)
          (puthash (plist-get node-props :id) (cons file nil)
                   supertag-sync--verified-ids)))
      ;; Upsert file node
      (supertag-sync--upsert-file-node file file-header counters)
      ;; Update heading nodes
      (let* ((current-nodes-in-file (make-hash-table :test 'equal))
             (existing-nodes-in-store (supertag-find-nodes-by-file file)))

        ;; Populate current-nodes-in-file hash table
        (dolist (node-props nodes-from-file)
          (puthash (plist-get node-props :id) node-props current-nodes-in-file))

        ;; Process existing nodes (skip file nodes, level 0)
        (dolist (existing-node-pair existing-nodes-in-store)
          (let* ((id (car existing-node-pair))
                 (old-node-props (cdr existing-node-pair))
                 (new-node-props (gethash id current-nodes-in-file)))
            ;; ponytail: file nodes (level 0) are not managed by heading sync
            (unless (supertag-node-file-node-p old-node-props)
              (cond
               ((null new-node-props)
		(if allow-destructive
                    (progn
                      (supertag-sync--delete-node id)
                      (setf (plist-get counters :nodes-deleted)
                            (1+ (or (plist-get counters :nodes-deleted) 0))))
                  (setq deferred-deletions t)))
               (new-node-props
		(supertag-sync--reconcile-node new-node-props counters))
               (t nil))
              (remhash id current-nodes-in-file))))

        ;; Process new nodes
        (maphash (lambda (_id new-node-props)
                   (supertag-sync--reconcile-node new-node-props counters))
                 current-nodes-in-file)

        ;; Update sync state — but keep the old hash while deletions are
        ;; deferred, so the retry survives an Emacs restart (the
        ;; deferred-files marker below is in-memory only).
        (unless deferred-deletions
          (supertag-sync-update-state file content-hash))))

    (when (and allow-destructive deferred-entry)
      (remhash file supertag-sync--deferred-files))
    (when (and (not allow-destructive) should-parse)
      (puthash file :pending supertag-sync--deferred-files))
    ;; Non-nil tells the caller this pass already removed the nodes that
    ;; left FILE, so a second parse to look for them would find nothing.
    (and should-parse allow-destructive 'reconciled)))

(defun supertag-sync--file-parse-request (file)
  "Return (OLD-HASH FORCE), the arguments a read of FILE for a sync takes.
OLD-HASH is the hash of the text last synchronized and FORCE is non-nil
when FILE has to be parsed even if its text is still that."
  (let ((state (gethash file (supertag-sync--get-state-table))))
    (list (when (and (listp state) (keywordp (car state)))
            (plist-get state :content-hash))
          (and (or supertag-sync--is-full-rescan-p
                   (and (supertag-sync--allow-destructive-p)
                        (gethash file supertag-sync--deferred-files)))
               t))))

(defun supertag-sync--process-single-file (file counters)
  "Process a single FILE for synchronization.
COUNTERS is a plist for tracking :nodes-created, :nodes-updated, and
:nodes-deleted.
Return `reconciled' when FILE was parsed and its vanished nodes removed, and
`yielded' when `supertag-sync--yield-to-input' let input interrupt parsing;
nothing has been written to the Store in that case."
  (let ((request (supertag-sync--file-parse-request file))
        (records nil)
        (yielded nil))
    ;; Reading and parsing only build values, so a background sync can drop
    ;; them the moment the user types and start over on the next idle.
    (cl-flet ((read-and-parse ()
                (setq records
                      (apply #'supertag-sync--read-file-records file request))
                nil))
      (if (not supertag-sync--yield-to-input)
          (read-and-parse)
        ;; Timers run with quitting inhibited, which also holds back the
        ;; throw `while-no-input' relies on.
        (setq yielded
              (condition-case nil
                  (let ((inhibit-quit nil))
                    (eq t (while-no-input (read-and-parse))))
                (quit t)))))
    (if yielded
        'yielded
      (supertag-sync--apply-file-records file records counters))))


(defun supertag-sync--delete-nodes-missing-from (file ids counters)
  "Delete the heading nodes of FILE whose ID is not among IDS.
COUNTERS is a plist for tracking :nodes-deleted."
  (let ((current-nodes-in-file (make-hash-table :test 'equal)))
    (dolist (id ids)
      (puthash id t current-nodes-in-file))
    (dolist (existing-node-pair (supertag-find-nodes-by-file file))
      (let ((id (car existing-node-pair)))
        ;; ponytail: file node lifecycle mirrors the file itself
        (unless (or (supertag-node-file-node-p (cdr existing-node-pair))
                    (gethash id current-nodes-in-file))
          (supertag-sync--delete-node id)
          (setf (plist-get counters :nodes-deleted)
                (1+ (plist-get counters :nodes-deleted))))))))

(defun supertag-sync--verify-file-nodes (file counters)
  "Delete the heading nodes of FILE whose ID is no longer in the file.
COUNTERS is a plist for tracking :nodes-deleted.  Files that disappeared
are handled by `supertag-sync--drop-removed-files'."
  (when (and (supertag-sync--allow-destructive-p) (file-exists-p file))
    (supertag-sync--delete-nodes-missing-from
     file
     (mapcar (lambda (node-props) (plist-get node-props :id))
             (supertag--parse-org-nodes file))
     counters)))

(defvar supertag-sync--removed-files nil
  "Files that left the sync scope and whose nodes still await deletion.")

(defun supertag-sync--drop-removed-files (files)
  "Forget FILES, which left the sync scope, and delete the nodes of those gone.
A renamed file shows up as one gone file and one new file, so the
deletion waits until the queued files are parsed: a node found again
there keeps its identity and only moves."
  (dolist (file files)
    (cl-pushnew file supertag-sync--removed-files :test #'equal))
  (unless (supertag-async-busy-p)
    (supertag-sync--flush-removed-files)))

(defun supertag-sync--flush-removed-files ()
  "Delete the nodes still attached to a removed file, in one bulk deletion.
While the snapshot guard or the mass-deletion caps refuse it, the sync
state is kept so that the next check tries again."
  (when-let* ((files (prog1 supertag-sync--removed-files
                       (setq supertag-sync--removed-files nil))))
    (let ((gone (make-hash-table :test 'equal))
          ids)
      (dolist (file files)
        (unless (file-exists-p file)
          (puthash file t gone)))
      (when (> (hash-table-count gone) 0)
        (supertag-traverse-nodes
         (lambda (id node)
           (when (gethash (plist-get node :file) gone)
             (push id ids)))))
      (when (or (null ids)
                (and (supertag-sync--allow-destructive-p)
                     (supertag-with-transaction
                       (supertag-sync--delete-nodes ids nil))))
        (let ((state-table (supertag-sync--get-state-table)))
          (dolist (file files)
            (remhash file state-table)))
        (supertag-sync-save-state)))))

(add-hook 'supertag-async-drained-hook #'supertag-sync--flush-removed-files)

;; A timer that is set again while Emacs is idle runs at once, so the save
;; that follows each change would write the whole Store after every batch.
(defun supertag-sync--save-waits-p ()
  "Return non-nil while the queue is being worked on and will drain."
  (and (supertag-async-busy-p)
       (or (timerp supertag-async--timer)
           supertag-sync-parser--in-flight)))

(add-hook 'supertag-save-defer-functions #'supertag-sync--save-waits-p)
(add-hook 'supertag-async-drained-hook #'supertag-schedule-save t)


(cl-defun supertag-sync--check-and-sync-legacy ()
  "Check and synchronize modified files.
  This is the main sync function called periodically.
  It enqueues modified files for asynchronous processing."
  ;; Pre-check: Warn if sync directories are not configured
  (unless (supertag-sync--effective-directories)
    (message "WARNING: supertag-sync-directories is not configured. Sync will not run.")
    (cl-return-from supertag-sync--check-and-sync-legacy nil))

  (let ((files-to-remove nil)
        (modified-files (supertag-get-modified-files)))

    ;; 1. Cleanup Sync State - Remove files that are no longer in scope
    (when (supertag-sync--effective-directories)
      (let ((state-table (supertag-sync--get-state-table)))
        (maphash (lambda (file _state)
                   (let ((file-exists (file-exists-p file))
                         (in-scope (supertag-sync--in-sync-scope-p file)))
                     (when (or (not file-exists)
                               (not in-scope))
                       (push file files-to-remove))))
                 state-table)))

    ;; 2. Scan for New Files
    (let ((new-files (supertag-scan-sync-directories)))
      (when new-files
        (setq modified-files
              (delete-dups (append modified-files new-files)))))

    ;; 3. Enqueue Modified Files for Async Processing
    (when modified-files
      (supertag-async-enqueue-many modified-files)
      (unless supertag-sync-quiet-when-idle
        (message "Queued %d files for async sync." (length modified-files))))

    ;; 4. Check for Orphans (Files in directory but not in state)
    ;; This is less urgent, can be done periodically or also queued.
    ;; For now, let's queue them if found.
    (let ((all-files-in-scope (supertag-scan-sync-directories t))
          (state-table (supertag-sync--get-state-table)))
      (supertag-async-enqueue-many
       (cl-remove-if (lambda (file) (gethash file state-table))
                     all-files-in-scope)))

    ;; Removed files go last: a renamed file is queued above as a new one.
    (when files-to-remove
      (supertag-sync--drop-removed-files files-to-remove))

    ;; 5. Report if needed (mostly handled by async worker now)
    (let ((idle-run (and (null modified-files) (null files-to-remove))))
      (when idle-run
        (supertag--diagnose-empty-sync supertag-sync-quiet-when-idle)))))

(cl-defun supertag-sync--check-and-sync-guarded ()
  "Check and synchronize modified files with snapshot guard."
  ;; Pre-check: Warn if sync directories are not configured
  (unless (supertag-sync--effective-directories)
    (message "WARNING: supertag-sync-directories is not configured. Sync will not run.")
    (cl-return-from supertag-sync--check-and-sync-guarded nil))
  (let* ((snapshot (supertag-sync--snapshot-build))
         (status (plist-get snapshot :status))
         (snapshot-files (plist-get snapshot :files))
         (files-to-remove nil)
         (modified-files (supertag-get-modified-files)))
    (supertag-sync--snapshot-set snapshot)
    (when (eq status 'unavailable)
      (message "Supertag: sync skipped; directories unavailable")
      (cl-return-from supertag-sync--check-and-sync-guarded nil))

    ;; 1. Cleanup Sync State (only when snapshot complete)
    (when (eq status 'complete)
      (setq files-to-remove (supertag-sync--snapshot-files-to-remove snapshot-files)))

    ;; 2. Scan for New Files (from snapshot)
    (let ((new-files (supertag-sync--snapshot-new-files snapshot-files)))
      (when new-files
        (setq modified-files
              (delete-dups (append modified-files new-files)))))

    ;; 2.5 Re-verify deferred files when snapshot becomes complete
    (when (eq status 'complete)
      (let ((deferred-files '()))
        (maphash (lambda (file _state)
                   (cond
                    ((not (file-exists-p file))
                     (remhash file supertag-sync--deferred-files))
                    ((supertag-sync--in-sync-scope-p file)
                     (push file deferred-files))))
                 supertag-sync--deferred-files)
        (when deferred-files
          (setq modified-files
                (delete-dups (append modified-files deferred-files))))))

    ;; 3. Enqueue Modified Files for Async Processing
    (when modified-files
      (supertag-async-enqueue-many modified-files)
      (unless supertag-sync-quiet-when-idle
        (message "Queued %d files for async sync." (length modified-files))))

    ;; Removed files go last: a renamed file is queued above as a new one.
    (when files-to-remove
      (supertag-sync--drop-removed-files files-to-remove))

    ;; 4. Report if needed (mostly handled by async worker now)
    (let ((idle-run (and (null modified-files) (null files-to-remove))))
      (when idle-run
        (supertag--diagnose-empty-sync supertag-sync-quiet-when-idle)))))

(defun supertag-sync--check-and-sync ()
  "Entry point for sync worker."
  (supertag-sync--ensure-state-source)
  (supertag-sync--with-directory-truenames
    (if supertag-sync-snapshot-guard
        (supertag-sync--check-and-sync-guarded)
      (supertag-sync--check-and-sync-legacy))))

(defun supertag-sync-check-now ()
  "Check the managed Org files once and sync the modified ones.
Git sync nudges this after a merge; the auto-sync timer runs the same
check on its own schedule."
  (supertag-sync--check-and-sync))

;;; --- Enhanced Hash Table Traversal Utilities ---

(defun supertag-traverse-nodes (callback)
  "Traverse all nodes in the store.
CALLBACK is a function that receives (id node-data) pairs.
Returns a list of results from CALLBACK."
  (let ((nodes-collection (supertag-store-get-collection :nodes))
        (results '())
        (total-nodes 0)
        (valid-nodes 0))
    (when (hash-table-p nodes-collection)
      (maphash (lambda (id node-data)
                 (cl-incf total-nodes)
                 (when (and node-data (plist-get node-data :type))
                   (cl-incf valid-nodes)
                   (push (funcall callback id node-data) results)))
               nodes-collection))
    (nreverse results)))

(defun supertag-find-nodes-by-condition (condition-fn)
  "Find all nodes that satisfy CONDITION-FN.
CONDITION-FN is a function that receives (id node-data) and returns t if the
node should be included.
Returns a list of (id . node-data) pairs."
  (supertag-traverse-nodes
   (lambda (id node-data)
     (when (funcall condition-fn id node-data)
       (cons id node-data)))))

(defun supertag-sync--id-exists-in-file-p (id file)
  "Check if a node ID exists in the specified FILE.
ID is the node ID string. FILE is the absolute path.
Returns t if the node ID is found, nil otherwise."
  (and id
       file
       (file-exists-p file)
       (with-temp-buffer
         (insert-file-contents-literally file)
         (goto-char (point-min))
         (re-search-forward (concat ":ID:[ \t]+" (regexp-quote id)) nil t))))

(defun supertag-sync--file-identity-matches-p (id node file)
  "Return non-nil when NODE's persisted identity in FILE still equals ID."
  (let ((policy (pcase (plist-get node :link-type)
                  ('id 'org-id)
                  ('denote 'denote))))
    (and policy
         (file-exists-p file)
         (with-temp-buffer
           (insert-file-contents-literally file)
           (let ((supertag-file-id-source policy))
             (equal id (car (supertag-sync--file-header-identity))))))))

(defun supertag-sync-validate-nodes (&optional counters)
  "Delete every node that no Org file backs, and return how many were deleted.
A node is unbacked when it has no file, when its file is gone, or when
the file no longer holds its ID.  The nodes go in one bulk deletion, so
nothing is deleted, and nil is returned, when they exceed the
mass-deletion caps.  COUNTERS is a plist for tracking :nodes-deleted."
  (let (stale)
    (supertag-traverse-nodes
     (lambda (id node)
       (when (and (eq (plist-get node :type) :node)
                  (stringp id)
                  (not (string-empty-p id)))
         ;; Current file nodes carry their identity kind.  Legacy nodes do
         ;; not, so preserve them while the file exists rather than guessing.
         (let ((file (plist-get node :file))
               (link-type (plist-get node :link-type))
               (verified (and supertag-sync--verified-ids
                              (gethash id supertag-sync--verified-ids))))
           (when (cond
                  ((null file) t)
                  ;; This rescan just read the ID from this very file.
                  ((and verified
                        (equal (car verified) file)
                        (eq (cdr verified)
                            (and (supertag-node-file-node-p node) t)))
                   nil)
                  ((not (supertag-node-file-node-p node))
                   (not (supertag-sync--id-exists-in-file-p id file)))
                  ((not (file-exists-p file)) t)
                  ((memq link-type '(id denote))
                   (not (supertag-sync--file-identity-matches-p id node file)))
                  (t nil))
             (push id stale))))))
    (supertag-sync--delete-nodes stale counters)))


;; --- Org Parser ---
(defun supertag--parse-properties (headline)
  "Extract user-defined properties from HEADLINE org-element.
org-element stores PROPERTIES drawer entries as uppercase keyword properties
directly on the headline element (e.g., :AUTHOR, :DATE).
Returns a plist of keyword-value pairs, excluding org-internal properties."
  (let ((user-props '())
        ;; Standard org-element properties to exclude (not user-defined)
        (standard-props '(:standard-properties :pre-blank :raw-value :title :level
                          :priority :tags :todo-keyword :todo-type
                          :footnote-section-p :archivedp :commentedp
                          :begin :end :contents-begin :contents-end :post-blank :parent
                          :scheduled :deadline :closed))
        ;; Org-mode internal PROPERTIES drawer entries to exclude
        (org-internal-props '(:ID :CUSTOM_ID :CATEGORY)))
    (when headline
      (let ((props (nth 1 headline)))
        (while props
          (let ((key (car props))
                (val (cadr props)))
            ;; User properties are uppercase keywords not in standard/internal lists
            (when (and (keywordp key)
                       (not (memq key standard-props))
                       (not (memq key org-internal-props))
                       val  ; Has a value
                       (let ((name (symbol-name key)))
                         (and (> (length name) 1)
                              ;; Check if the property name (after :) is all uppercase
                              (equal (upcase (substring name 1))
                                     (substring name 1)))))
              (setq user-props (plist-put user-props key val))))
          (setq props (cddr props)))))
    user-props))

(defun supertag--generated-reference-context-p (element)
  "Return non-nil when ELEMENT belongs to generated Org output.
Dynamic-block bodies and elements affiliated with `#+RESULTS:' are replaceable
views, so links below either container do not assert Document Link facts."
  (let ((current element)
        generated)
    (while (and current (not generated))
      (setq generated
            (or (eq (org-element-type current) 'dynamic-block)
                (org-element-property :results current))
            current (org-element-property :parent current)))
    generated))

(defun supertag--link-reference-target (link)
  "Return the node ID that source-authored LINK refers to, or nil.
Links in dynamic blocks and Babel result containers are generated views and
are intentionally excluded."
  (unless (supertag--generated-reference-context-p link)
    (let* ((type (org-element-property :type link))
           (path (org-element-property :path link))
           (raw (org-element-property :raw-link link))
           (denote-id (cond
                       ((equal type "denote") path)
                       ((and raw (string-prefix-p "denote:" raw))
                        (substring raw (length "denote:"))))))
      (when (and (stringp path)
                 (not (string-empty-p path))
                 (or (equal type "id") denote-id))
        (or denote-id path)))))

(defun supertag--extract-refs (elements)
  "Extract source-authored node reference links from Org ELEMENTS.
Links in dynamic blocks and Babel result containers are generated views and
are intentionally excluded."
  (when elements
    (org-element-map elements 'link #'supertag--link-reference-target)))

(defun supertag--link-named-relation (link)
  "Return (:relation-name NAME :target-id ID) for named node LINK, or nil."
  (unless (supertag--generated-reference-context-p link)
    (let ((name (org-element-property :type link))
          (target (org-element-property :path link)))
      (when (and (supertag-text-link-relation-type-p name)
                 (stringp target) (not (string-empty-p target)))
        (list :relation-name name :target-id target)))))

(defun supertag--extract-named-links (elements)
  "Extract configured named node links from Org ELEMENTS."
  (when (and elements (supertag-text-link-relation-types))
    (delete-dups
     (org-element-map elements 'link #'supertag--link-named-relation))))

(defvar supertag--stripped-title-cache nil
  "Hash table from a parsed headline to its title without inline tags.
Bound for the duration of one buffer parse.  Every node's outline path
needs the cleaned title of each of its ancestors, so without this a deep
file strips the same ancestor headline once per descendant.")

(defun supertag--strip-inline-tags (headline)
  "Return HEADLINE's title without direct-prose inline tags.
Org links, code and other inline objects are preserved verbatim."
  (if (not supertag--stripped-title-cache)
      (supertag--strip-inline-tags-1 headline)
    (let ((cached (gethash headline supertag--stripped-title-cache
                           'supertag--unset)))
      (if (eq cached 'supertag--unset)
          (puthash headline (supertag--strip-inline-tags-1 headline)
                   supertag--stripped-title-cache)
        cached))))

(defun supertag--strip-inline-tags-1 (headline)
  "Compute the title of HEADLINE without direct-prose inline tags."
  (let ((raw-title (org-element-property :raw-value headline)))
    (when raw-title
      (let* ((line-begin (org-element-property :begin headline))
             (line-end (save-excursion
                         (goto-char line-begin)
                         (line-end-position)))
             (title-begin
              (save-excursion
                (goto-char line-end)
                (search-backward raw-title line-begin t)))
             (without-tags raw-title))
        (when title-begin
          (dolist (match
                   (reverse
                    (supertag-transform-inline-tag-matches-in-region
                     title-begin (+ title-begin (length raw-title)) headline)))
            (let ((start (- (nth 0 match) title-begin))
                  (end (- (nth 1 match) title-begin)))
              (while (and (< end (length without-tags))
                          (memq (aref without-tags end) '(?\s ?\t)))
                (setq end (1+ end)))
              (setq without-tags
                    (concat (substring without-tags 0 start)
                            (substring without-tags end))))))
        (string-trim
         (replace-regexp-in-string "[ \t]+" " " without-tags))))))

(defun supertag--paragraph-inline-tag-names (paragraph)
  "Return the inline tag names in PARAGRAPH, or nil inside a drawer."
  (unless (org-element-lineage paragraph '(drawer property-drawer) t)
    (mapcar #'caddr
            (supertag-transform-inline-tag-matches-in-region
             (org-element-property :begin paragraph)
             (org-element-property :end paragraph)
             paragraph))))

(defun supertag--extract-inline-tags (headline)
  "Extract inline tags from HEADLINE's own direct Org prose."
  (unless (org-element-property :commentedp headline)
    (let ((tags
           (mapcar
            #'caddr
            (supertag-transform-inline-tag-matches-in-region
             (org-element-property :begin headline)
             (save-excursion
               (goto-char (org-element-property :begin headline))
               (line-end-position))
             headline)))
          (section (car (org-element-contents headline))))
      (when (eq (org-element-type section) 'section)
        (setq tags
              (apply #'append tags
                     (org-element-map section 'paragraph
                       #'supertag--paragraph-inline-tag-names))))
      (cl-delete-duplicates tags :test #'equal))))

  (defun supertag--extract-org-headline-tags (headline)
    "Extract org native tags (:tag:) from HEADLINE element.
Return a list of tag strings, or an empty list if none."
    (let ((tags (org-element-property :tags headline)))
      (when tags
        (cl-remove-if (lambda (s) (or (null s) (string-empty-p s)))
                      (mapcar #'identity tags)))))









  (defun supertag--render-org-headline (level title tags &optional tag-position)
    "Render an Org headline line given LEVEL, TITLE and TAGS.
Returns a single line string ending with a newline.
TAG-POSITION can be :before-title, :after-title, or nil (default after title)."
    (let* ((stars (make-string (max 1 (or level 1)) ?*))
           (tags-part (supertag--format-inline-tags tags)))
      (cond
       ;; Tags before title: * #tag1 #tag2 Title
       ((eq tag-position :before-title)
        (format "%s%s %s\n" stars (or tags-part "") title))
       ;; Tags after title (default): * Title #tag1 #tag2
       (t
        (format "%s %s%s\n" stars title (or tags-part ""))))))

(defun supertag--process-node-references (node-data counters)
  "Project Org reference relations for NODE-DATA without modifying Org files.
NODE-DATA is the node plist containing reference information.
COUNTERS is a plist for tracking relation statistics.
This function is called only when a node is actually being created or updated."
  (let ((node-id (plist-get node-data :id))
        (ref-to-list (plist-get node-data :ref-to)))
    (when (and node-id ref-to-list)
      ;; Process each reference
      (dolist (target-id ref-to-list)
        (when (and (stringp target-id) (not (string-empty-p target-id)))
          ;; Check if target node exists in the store
          (let ((target-node (supertag-node-get target-id)))
            ;; A missing target is normal while a batch is still being
            ;; imported; it collects this link when it appears.
            (if (not target-node)
                (supertag-sync--note-unresolved-link node-id target-id)
              (let ((existing
                     (cl-find-if
                      (lambda (relation)
                        (not (supertag-relation-named-document-link-p relation)))
                      (supertag-relation-find-between
                       node-id target-id :reference :document-link))))
                (when (supertag-relation-project-document-link node-id target-id)
                  (unless existing
                    (setf (plist-get counters :references-created)
                          (1+ (or (plist-get counters :references-created)
                                  0)))))))))))))

(defun supertag--process-node-named-links (node-data counters)
  "Project configured named links in NODE-DATA."
  (let ((node-id (plist-get node-data :id)))
    (dolist (link (plist-get node-data :named-links))
      (let ((name (plist-get link :relation-name))
            (target-id (plist-get link :target-id)))
        (when (and node-id (stringp target-id)
                   (not (supertag-node-get target-id)))
          (supertag-sync--note-unresolved-link node-id target-id))
        (when (and node-id (supertag-node-get target-id))
          (let ((existing (cl-find-if
                           (lambda (relation)
                             (supertag-relation-named-document-link-p relation name))
                           (supertag-relation-find-between
                            node-id target-id :reference :document-link))))
            (when (supertag-relation-project-document-link node-id target-id name)
              (unless existing
                (setf (plist-get counters :references-created)
                      (1+ (or (plist-get counters :references-created) 0)))))))))))

(defun supertag--cleanup-orphaned-named-links (node-id current-links counters)
  "Delete named projections absent from CURRENT-LINKS for NODE-ID."
  (dolist (relation (supertag-relation-find-by-from node-id :reference))
    (when (and (supertag-relation-named-document-link-p relation)
               (not (member (list :relation-name (plist-get relation :relation-name)
                                  :target-id (plist-get relation :to))
                            current-links)))
      (supertag-relation-delete (plist-get relation :id))
      (setf (plist-get counters :references-deleted)
            (1+ (or (plist-get counters :references-deleted) 0))))))

(defun supertag--cleanup-orphaned-references (node-id current-refs counters)
  "Clean up orphaned reference relations for a node.
NODE-ID is the node's ID.
CURRENT-REFS is the current list of references from the file.
COUNTERS is a plist for tracking relation statistics."
  (let ((existing-relations (supertag-relation-find-by-from node-id :reference)))
    (dolist (relation existing-relations)
      (let ((target-id (plist-get relation :to)))
        ;; Only Org-owned projections may be deleted from an Org rescan.
        (when (and (supertag-relation-document-link-p relation)
                   (not (supertag-relation-named-document-link-p relation))
                   (not (member target-id current-refs)))
          (supertag-relation-delete (plist-get relation :id))
          (setf (plist-get counters :references-deleted)
                (1+ (or (plist-get counters :references-deleted) 0))))))))

(defun supertag-sync--reconcile-all-projected-relations (counters)
  "Reconcile relation projections after every document node is available.
COUNTERS receives Document Link creation/deletion totals."
  (let (nodes)
    (supertag-traverse-nodes
     (lambda (_id node)
       (when (and (eq (plist-get node :type) :node)
                  (plist-get node :file))
         (push node nodes))))
    (dolist (node nodes)
      (supertag--cleanup-orphaned-references
       (plist-get node :id) (plist-get node :ref-to) counters)
      (supertag--cleanup-orphaned-named-links
       (plist-get node :id) (plist-get node :named-links) counters)
      (supertag--process-node-references node counters)
      (supertag--process-node-named-links node counters))))

(defun supertag-sync--rebuild-reference-caches ()
  "Rebuild derived node backlink caches from indexed reference relations."
  (let (node-ids)
    (supertag-traverse-nodes
     (lambda (id node)
       (when (eq (plist-get node :type) :node)
         (push id node-ids))))
    (dolist (id node-ids)
      (when-let* ((node (supertag-node-get id)))
        (let* ((incoming
                (sort
                 (delete-dups
                  (mapcar (lambda (relation) (plist-get relation :from))
                          (cl-remove-if
                           #'supertag-relation-named-document-link-p
                           (supertag-relation-find-by-to
                            id :reference :document-link))))
                 #'string<))
               (count (length incoming)))
          (unless (and (equal incoming (plist-get node :ref-from))
                       (= count (or (plist-get node :ref-count) 0)))
            (supertag-store-put-entity
             :nodes id
             (plist-put
              (plist-put (copy-sequence node) :ref-from incoming)
              :ref-count count))))))))

(defun supertag--extract-outline-path (headline)
  "Extract the outline path (olp) for HEADLINE.
Returns a list of ancestor titles from root to current headline (inclusive).
For example: (\"Top Level\" \"Second Level\" \"Current Headline\")
The titles remove inline #tags as well as TODO keywords and org :tags:."
  (let ((path '())
        (current headline))
    ;; Traverse up the hierarchy collecting titles
    (while current
      (when (eq (org-element-type current) 'headline)
        (let ((cleaned-title (supertag--strip-inline-tags current)))
          (when cleaned-title (push cleaned-title path))))
      ;; Move to parent element
      (setq current (org-element-property :parent current))
      ;; Stop if we've reached the document root
      (when (or (not current)
                (eq (org-element-type current) 'org-data))
        (setq current nil)))
    path))

(defun supertag--extract-node-own-content (headline contents-begin contents-end)
  "Extract only the content that belongs to HEADLINE, excluding sub-headlines.
HEADLINE is the org-element headline object.
CONTENTS-BEGIN and CONTENTS-END are the content boundaries from org-element.
Returns a string containing only the node's own content."
  (if (not (and contents-begin contents-end (> contents-end contents-begin)))
      ""
    (save-excursion
      (goto-char contents-begin)
      (let ((current-level (org-element-property :level headline))
            (content-end contents-end))
        ;; Use a safer approach: find first child headline
        (goto-char contents-begin)
        (when (re-search-forward (format "^\\*\\{%d,\\} " (1+ current-level)) contents-end t)
          ;; Found a child headline at deeper level
          (setq content-end (line-beginning-position)))
        ;; Extract content from contents-begin to the adjusted content-end
        (buffer-substring-no-properties contents-begin content-end)))))

;;; --- Extractor Plugin System ---

(defvar supertag-extractor--registry nil
  "Ordered list of registered extractors.
Each entry is a plist with :name, :priority, and :fn keywords.
Sorted by :priority (ascending, lower runs first).")

(cl-defun supertag-extractor-register (&key name priority fn)
  "Register an extractor FN with NAME and PRIORITY.
If an extractor with the same NAME already exists, replace it.
Lower PRIORITY runs first; later extractors override earlier ones
when they produce the same key."
  (declare (indent 0))
  (setq supertag-extractor--registry
        (cl-remove name supertag-extractor--registry
                   :key (lambda (e) (plist-get e :name)) :test #'equal))
  (push (list :name name :priority priority :fn fn)
        supertag-extractor--registry)
  (setq supertag-extractor--registry
        (cl-sort supertag-extractor--registry #'<
                 :key (lambda (e) (plist-get e :priority)))))

(defun supertag-extractor-unregister (name)
  "Remove the extractor with NAME from the registry."
  (setq supertag-extractor--registry
        (cl-remove name supertag-extractor--registry
                   :key (lambda (e) (plist-get e :name)) :test #'equal)))

(defun supertag-extractor-list ()
  "Return a copy of the current extractor registry, sorted by priority."
  (copy-sequence supertag-extractor--registry))

(defun supertag-extractor--run (element file ctx)
  "Run all registered extractors on ELEMENT and return merged plist.
ELEMENT is the org-element headline.
FILE is the absolute file path of the buffer.
CTX is a plist with parse-context flags (e.g. :full-rescan-p).
Extractors are called in priority order; for any key produced by
multiple extractors, the one with the highest priority (called last)
wins."
  (let ((result '()))
    (dolist (entry supertag-extractor--registry)
      (let* ((fn (plist-get entry :fn))
             (patch (funcall fn element file ctx)))
        (when patch
          (cl-loop for (key val) on patch by #'cddr
                   do (setq result (plist-put result key val))))))
    result))

;;; --- Built-in Extractors ---

(defun supertag-extractor--core-structure (headline _file _ctx)
  "Extract core structural fields from a headline element.
Returns: :level, :todo, :priority, :scheduled, :deadline,
:position, :pos."
  (list :level (org-element-property :level headline)
        :todo (org-element-property :todo-keyword headline)
        :priority (let ((p (org-element-property :priority headline)))
                    (and p (format "#%c" p)))
        :scheduled (let ((ts (org-element-property :scheduled headline)))
                     (and ts (org-element-interpret-data ts)))
        :deadline (let ((ts (org-element-property :deadline headline)))
                    (and ts (org-element-interpret-data ts)))
        :position (org-element-property :begin headline)
        :pos (org-element-property :begin headline)))

(defun supertag-extractor--title (headline _file _ctx)
  "Extract and clean the title from a headline element.
Returns: :title (cleaned, user-visible title),
:raw-value (same cleaned title, used for hashing)."
  (let* ((original-raw-title (org-element-property :raw-value headline))
         (cleaned-title (supertag--strip-inline-tags headline))
         (final-title (if (or (null cleaned-title) (string-empty-p cleaned-title))
                          original-raw-title
                        cleaned-title)))
    (list :title (or final-title "Untitled Node")
          :raw-value final-title)))

(defun supertag-extractor--olp (headline _file _ctx)
  "Extract the outline path from a headline element.
Returns: :olp (list of ancestor titles from root to current)."
  (list :olp (supertag--extract-outline-path headline)))

(defun supertag-extractor--tags (headline _file _ctx)
  "Extract tags from a headline element.
Reads inline #tags from title/content and, when
`supertag-sync-import-org-tags' is non-nil, native Org :tags:.
Returns: :tag-occurrences (list of sanitized Org tokens)."
  (let* ((inline-tags (supertag--extract-inline-tags headline))
         (org-native-tags
          (if supertag-sync-import-org-tags
              (or (supertag--extract-org-headline-tags headline) '())
            '()))
         (all-tags (supertag--merge-and-sanitize-tags
                    inline-tags org-native-tags)))
    (list :tag-occurrences all-tags)))

(defun supertag-extractor--properties (headline _file _ctx)
  "Extract user-defined properties from a headline element.
Returns: :properties (plist of keyword-value pairs)."
  (list :properties (supertag--parse-properties headline)))

(defun supertag-extractor--content (headline _file _ctx)
  "Extract the body content of a headline, excluding sub-headlines.
Strips any :PROPERTIES: drawers found in the content area.
Returns: :content (string)."
  (let* ((contents-begin (org-element-property :contents-begin headline))
         (contents-end (org-element-property :contents-end headline))
         (raw-content (if (and contents-begin contents-end)
                          (supertag--extract-node-own-content
                           headline contents-begin contents-end)
                        "")))
    (list :content (replace-regexp-in-string
                    ":PROPERTIES:\n\\(.\\|\n\\)*?:END:\n?"
                    "" raw-content))))

(defun supertag-extractor--refs (headline _file _ctx)
  "Extract source-authored link references from a headline's direct content.
Only extracts from non-headline children and excludes generated Org views.
Returns: :ref-to (list of UUID strings)."
  (let* ((contents-begin (org-element-property :contents-begin headline))
         (refs-to (supertag--extract-refs
                   (when contents-begin
                     (cl-remove-if (lambda (el) (eq (org-element-type el) 'headline))
                                   (org-element-contents headline))))))
    (list :ref-to (cl-delete-duplicates refs-to :test #'equal)
          :named-links
          (supertag--extract-named-links
           (when contents-begin
             (cl-remove-if (lambda (el) (eq (org-element-type el) 'headline))
                           (org-element-contents headline)))))))

(defun supertag-extractor--setup-defaults ()
  "Register all built-in extractors with default priorities."
  (supertag-extractor-register :name 'core-structure :priority 0
                               :fn #'supertag-extractor--core-structure)
  (supertag-extractor-register :name 'title :priority 5
                               :fn #'supertag-extractor--title)
  (supertag-extractor-register :name 'olp :priority 10
                               :fn #'supertag-extractor--olp)
  (supertag-extractor-register :name 'tags :priority 20
                               :fn #'supertag-extractor--tags)
  (supertag-extractor-register :name 'properties :priority 30
                               :fn #'supertag-extractor--properties)
  (supertag-extractor-register :name 'content :priority 40
                               :fn #'supertag-extractor--content)
  (supertag-extractor-register :name 'refs :priority 50
                               :fn #'supertag-extractor--refs))

(defun supertag--convert-element-to-node-plist (headline file &optional _migration-mode)
  "Convert a headline ELEMENT from org-element into a node plist.
This is the core reusable parser for a single headline.
NOTE: This function only parses data, it does NOT create tag entities or
relations.
The optional third argument is retained for caller compatibility.  Projection
always requires an Org-owned persistent ID and skips ID-less headings."
  (when-let* ((id (org-element-property :ID headline)))
    (let* ((ctx (list :file file
                      :full-rescan-p supertag-sync--is-full-rescan-p))
           (extracted (supertag-extractor--run headline file ctx)))
      (supertag-sync--resolve-node-tag-occurrences
       (append (list :id id :file file) extracted)))))

(defun supertag--map-headlines (parsed-ast file &optional migration-mode node-id)
  "Map over headlines in PARSED-AST and parse them into nodes.
MIGRATION-MODE is retained for caller compatibility; all modes require IDs.
When NODE-ID is non-nil, run extractors only for that identity."
  (let (nodes)
    (org-element-map parsed-ast 'headline
      (lambda (headline)
        (when (or (null node-id) (equal node-id (org-element-property :ID headline)))
          (let ((node (supertag--convert-element-to-node-plist headline file migration-mode)))
            (when node (push node nodes))))))
    (nreverse nodes)))

(defun supertag-sync--strip-embed-block-contents (file)
  "Strip generated embed contents from the current buffer before parsing FILE.
For an unclosed embed block, conservatively strip through the next Org heading
or the end of the buffer.  Return the number of unclosed blocks found."
  (goto-char (point-min))
  (let ((unclosed-count 0))
    (while (re-search-forward "^#\\+begin_embed:.*$" nil t)
      (let* ((content-start (line-beginning-position 2))
             (block-end (save-excursion
                          (when (re-search-forward "^#\\+end_embed" nil t)
                            (match-beginning 0))))
             (unit-end (save-excursion
                         (when (re-search-forward
                                "^\\*+\\(?:[ \t]+\\|$\\)" nil t)
                           (match-beginning 0)))))
        (if (and block-end
                 (or (null unit-end) (< block-end unit-end)))
            (progn
              (delete-region content-start block-end)
              (goto-char content-start))
          (cl-incf unclosed-count)
          (delete-region content-start (or unit-end (point-max)))
          (goto-char content-start))))
    (when (> unclosed-count 0)
      (message "Supertag: ignored %d unclosed embed block%s while parsing %s"
               unclosed-count
               (if (= unclosed-count 1) "" "s")
               (abbreviate-file-name file)))
    unclosed-count))

(defun supertag--parse-node-tree (node-id)
  "Parse NODE-ID's subtree with its ancestors from a headline-only Org tree.
Unrelated headings retain structural context without parsing their bodies."
  (let* ((outline (org-element-parse-buffer 'headline nil t))
         (headline (org-element-map outline 'headline
                     (lambda (element)
                       (when (equal node-id (org-element-property :ID element))
                         element))
                     nil t)))
    (when headline
      (save-restriction
        (narrow-to-region (org-element-property :begin headline)
                          (org-element-property :end headline))
        (let* ((tree (org-element-parse-buffer))
               (root (car (org-element-contents tree))))
          (org-element-put-property root :parent
                                    (org-element-property :parent headline))
          tree)))))

(defmacro supertag-sync--with-parse-buffer (file &rest body)
  "Run BODY with the current buffer prepared for parsing FILE's Org text.
The buffer is put in Org mode without its startup hooks and the contents
of embed blocks are removed, so positions seen by BODY are positions in
that stripped text."
  (declare (indent 1) (debug t))
  `(progn
     (supertag-text-link-refresh)
     (let ((inhibit-modification-hooks t)
           (org-mode-hook nil)
           (org-inhibit-startup t)
           (org-agenda-inhibit-startup t)
           (supertag--stripped-title-cache (make-hash-table :test 'eq)))
       (unless (derived-mode-p 'org-mode)
         (delay-mode-hooks (org-mode)))
       (setq-local org-element-use-cache nil)
       ;; Ensure tab-width is 8 as required by org-current-text-column
       (setq-local tab-width 8)
       ;; Pre-process to remove content of embed blocks before parsing
       (supertag-sync--strip-embed-block-contents ,file)
       (goto-char (point-min))
       ,@body)))

(defun supertag-sync--buffer-may-hold-nodes-p ()
  "Return nil when the current buffer cannot hold a heading node.
A heading is a node only through an ID in its property drawer, so text
with no ID line below its first heading has none, and neither Org mode nor
a parse is needed to know that.  An embed block still takes the full path,
which reports the ones left unclosed."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t))
      (or (and (re-search-forward "^\\*+ " nil t)
               (re-search-forward "^[ \t]*:ID:" nil t))
          (progn (goto-char (point-min))
                 (re-search-forward "^#\\+begin_embed:" nil t))))))

(defun supertag-sync--parse-prepared-buffer (file &optional migration-mode node-id)
  "Parse every node of FILE from the current, already prepared buffer.
MIGRATION-MODE and NODE-ID are as for
`supertag--parse-org-nodes-from-current-buffer'."
  ;; Parse without triggering org-mode initialization.
  (let* ((file-id (car (supertag-sync--file-header-identity)))
         (parsed-ast (if node-id
                         (supertag--parse-node-tree node-id)
                       (org-element-parse-buffer)))
         (nodes (supertag--map-headlines parsed-ast file migration-mode node-id)))
    (if (null file-id)
        nodes
      (mapcar (lambda (node)
                (plist-put node :parent-id file-id))
              nodes))))

(defun supertag--parse-org-nodes-from-current-buffer (file &optional migration-mode node-id)
  "Parse org nodes from current buffer content.
FILE is used for setting the :file property on nodes.
When NODE-ID is non-nil, parse its subtree and headline-only ancestor context."
  (if (supertag-sync--buffer-may-hold-nodes-p)
      (supertag-sync--with-parse-buffer file
        (supertag-sync--parse-prepared-buffer file migration-mode node-id))
    ;; A caller finds the link types registered either way.
    (supertag-text-link-refresh)
    nil))

;;; --- Parsing only the headings that changed ---

;; Re-synchronizing a saved file used to parse and extract every heading in
;; it, so the cost of one edited line grew with the size of the file.  A
;; node's record is built from its own heading line, the text below it up to
;; the next heading, and the heading lines of its ancestors (for the outline
;; path).  Remembering the last record of each node together with a
;; fingerprint of exactly that text lets the next parse reuse every record
;; whose fingerprint is unchanged.

(defcustom supertag-sync-incremental-parse t
  "When non-nil, re-parse only the headings of a file whose text changed.
The result is the same as parsing the whole file; nil always parses the
whole file."
  :type 'boolean
  :group 'supertag-sync)

(defvar supertag-sync--parse-memo (make-hash-table :test 'equal)
  "Hash table from a file to the records of its last complete parse.
Each value is a plist with :config, :header and :nodes; :nodes maps a node
ID to (FINGERPRINT . RECORD).  Session-local, so the first sync of a file
after startup parses all of it.")

(defun supertag-sync--parse-config ()
  "Return the settings a node record depends on besides its file's text."
  (list (copy-tree supertag-extractor--registry)
        supertag-sync-import-org-tags
        (copy-tree org-todo-keywords)))

(defun supertag-sync--fingerprint (text)
  "Return a fingerprint of TEXT."
  ;; Hashing a string is far cheaper than hashing a buffer region.
  (md5 text nil nil 'utf-8-emacs t))

(defun supertag-sync--outline-units ()
  "Return the current buffer's headings in order as a list of plists.
Each has :headline (a headline-only element), :key, :begin, :end (where
the next heading starts), :extract-end and :fingerprint.  :key is the
heading's ID paired with the number of earlier headings carrying the same
ID, so that a file with duplicated IDs still identifies each heading."
  (let* ((outline (org-element-parse-buffer 'headline nil t))
         (headlines (org-element-map outline 'headline #'identity))
         (lines (make-hash-table :test 'eq))
         (seen (make-hash-table :test 'equal))
         units)
    (cl-flet ((heading-line (headline)
                (or (gethash headline lines)
                    (puthash headline
                             (save-excursion
                               (goto-char (org-element-property :begin headline))
                               (buffer-substring-no-properties
                                (point) (line-beginning-position 2)))
                             lines))))
      (while headlines
        (let* ((headline (car headlines))
               (next (cadr headlines))
               (id (org-element-property :ID headline))
               (begin (org-element-property :begin headline))
               (end (if next (org-element-property :begin next) (point-max))))
          (when id
            (let ((parent (org-element-property :parent headline))
                  (nth (gethash id seen 0))
                  context)
              (puthash id (1+ nth) seen)
              (while (and parent (eq (org-element-type parent) 'headline))
                (push (heading-line parent) context)
                (setq parent (org-element-property :parent parent)))
              (push (list :headline headline :key (cons id nth)
                          :begin begin :end end
                          ;; Keeping a child's heading line in view makes a
                          ;; lone parse of this unit end its body exactly
                          ;; where a parse of the whole file would.
                          :extract-end
                          (if (and next
                                   (> (org-element-property :level next)
                                      (org-element-property :level headline)))
                              (save-excursion
                                (goto-char end) (line-beginning-position 2))
                            end)
                          :fingerprint
                          (supertag-sync--fingerprint
                           (concat (apply #'concat context) "\0"
                                   (buffer-substring-no-properties begin end))))
                    units))))
        (setq headlines (cdr headlines))))
    (nreverse units)))

(defun supertag-sync--header-fingerprint ()
  "Return a fingerprint of the current buffer's text before its first heading."
  (save-excursion
    (goto-char (point-min))
    (supertag-sync--fingerprint
     (buffer-substring-no-properties
      (point-min)
      (if (re-search-forward org-outline-regexp-bol nil t)
          (match-beginning 0)
        (point-max))))))

(defun supertag-sync--parse-unit (unit file file-id)
  "Return the record of UNIT in FILE, parsed on its own.
FILE-ID is the identity of FILE's file node, or nil."
  (let* ((headline (plist-get unit :headline))
         (id (org-element-property :ID headline))
         (node
          (save-restriction
            ;; The outline path cleans each ancestor's title from the
            ;; buffer text, which the narrowing below hides.
            (let ((parent (org-element-property :parent headline)))
              (while (and parent (eq (org-element-type parent) 'headline))
                (supertag--strip-inline-tags parent)
                (setq parent (org-element-property :parent parent))))
            (narrow-to-region (plist-get unit :begin)
                              (plist-get unit :extract-end))
            (let* ((tree (org-element-parse-buffer))
                   (root (car (org-element-contents tree))))
              (org-element-put-property
               root :parent (org-element-property :parent headline))
              (car (supertag--map-headlines tree file nil id))))))
    (if (and node file-id)
        (plist-put node :parent-id file-id)
      node)))

(defun supertag-sync--remember-parse (file header units nodes)
  "Remember NODES, the records of FILE, for its next parse.
HEADER is the fingerprint of FILE's header and UNITS its outline."
  (let ((table (make-hash-table :test 'equal))
        (by-key (make-hash-table :test 'equal))
        (node-count (make-hash-table :test 'equal))
        (unit-count (make-hash-table :test 'equal)))
    (dolist (node nodes)
      (let* ((id (plist-get node :id))
             (nth (gethash id node-count 0)))
        (puthash (cons id nth) node by-key)
        (puthash id (1+ nth) node-count)))
    (dolist (unit units)
      (let ((id (car (plist-get unit :key))))
        (puthash id (1+ (gethash id unit-count 0)) unit-count)))
    (dolist (unit units)
      (let* ((key (plist-get unit :key))
             (node (gethash key by-key)))
        ;; Records are paired with headings by order; when a heading
        ;; yielded no record that pairing is unknown for its ID.
        (when (and node (eql (gethash (car key) node-count)
                             (gethash (car key) unit-count)))
          (puthash key (cons (plist-get unit :fingerprint) (copy-tree node))
                   table))))
    (puthash file (list :config (supertag-sync--parse-config)
                        :header header :nodes table)
             supertag-sync--parse-memo)))

(defun supertag-sync--parse-nodes (file)
  "Return the node records of FILE from the current buffer.
Equivalent to `supertag--parse-org-nodes-from-current-buffer', but when
FILE was parsed earlier in this session only the headings whose text
changed since then are parsed again."
  (let ((memo (and supertag-sync-incremental-parse
                   (not supertag-sync--is-full-rescan-p)
                   (gethash file supertag-sync--parse-memo))))
    (cond
     ((or (not supertag-sync-incremental-parse)
          supertag-sync--is-full-rescan-p)
      (supertag--parse-org-nodes-from-current-buffer file))
     ((not (and memo (equal (plist-get memo :config)
                            (supertag-sync--parse-config))))
      (let ((nodes (supertag--parse-org-nodes-from-current-buffer file)))
        ;; The buffer is left prepared by the parse above.
        (when (derived-mode-p 'org-mode)
          (supertag-sync--remember-parse
           file (supertag-sync--header-fingerprint)
           (supertag-sync--outline-units) nodes))
        nodes))
     (t
      (supertag-sync--with-parse-buffer file
        (let* ((header (supertag-sync--header-fingerprint))
               (units (supertag-sync--outline-units))
               (known (plist-get memo :nodes))
               (changed 0))
          (dolist (unit units)
            (let ((entry (gethash (plist-get unit :key) known)))
              (unless (and entry
                           (equal (car entry) (plist-get unit :fingerprint)))
                (cl-incf changed))))
          (if (or (not (equal header (plist-get memo :header)))
                  ;; With this much changed, one parse of the file is cheaper.
                  (> (* 3 changed) (max 24 (length units))))
              (let ((nodes (supertag-sync--parse-prepared-buffer file)))
                (supertag-sync--remember-parse file header units nodes)
                nodes)
            (let ((file-id (car (supertag-sync--file-header-identity)))
                  nodes)
              (dolist (unit units)
                (let* ((entry (gethash (plist-get unit :key) known))
                       (node
                        (if (and entry
                                 (equal (car entry)
                                        (plist-get unit :fingerprint)))
                            ;; Unchanged text, but it may have moved, and
                            ;; Tags may have been created since.
                            (let ((node (copy-tree (cdr entry)))
                                  (begin (plist-get unit :begin)))
                              (setq node (plist-put node :position begin))
                              (setq node (plist-put node :pos begin))
                              (supertag-sync--resolve-node-tag-occurrences node))
                          (supertag-sync--parse-unit unit file file-id))))
                  (when node (push node nodes))))
              (setq nodes (nreverse nodes))
              (supertag-sync--remember-parse file header units nodes)
              nodes))))))))

;;;###autoload
(defun supertag--parse-org-nodes (file &optional migration-mode)
  "Parse the org file and return a list of nodes. Entry point.
This function IGNORES content inside #+begin_embed blocks.
Uses a temporary buffer with minimal side effects to avoid interfering with
other packages.
MIGRATION-MODE is retained for caller compatibility; all modes require IDs."
  (unless (file-exists-p file)
    (error "File does not exist: %s" file))
  (with-temp-buffer
    (insert-file-contents file)
    (supertag--parse-org-nodes-from-current-buffer file migration-mode)))

;;;------------------------------------------------------------------
;;; Supertag Sync Auto Star or Stop
;;;------------------------------------------------------------------

(defun supertag-sync--file-counters ()
  "Return fresh counters for synchronizing one file."
  (list :nodes-created 0 :nodes-updated 0 :nodes-deleted 0
        :references-created 0 :references-deleted 0))

(defun supertag-sync--after-queued-file (counters)
  "Note what COUNTERS say a queued file changed and checkpoint the sync state."
  (when (and counters
             (> (+ (plist-get counters :nodes-created)
                   (plist-get counters :nodes-updated)
                   (plist-get counters :nodes-deleted))
                0))
    (setq supertag-sync--state-unsaved t))
  ;; Writing the state prints every file's entry, so a long queue writes it
  ;; at checkpoints and after its last file.  State that is lost only makes
  ;; the next check read those files again.
  (when (and supertag-sync--state-unsaved
             (or (not (supertag-async-busy-p))
                 (> (- (float-time) supertag-sync--state-saved-at)
                    supertag-sync--state-checkpoint-seconds)))
    (supertag-sync-save-state)))

(defun supertag-sync--async-processor (file)
  "Worker function for the async queue.
Processes FILE for synchronization."
  (let ((counters (and (file-exists-p file) (supertag-sync--file-counters))))
    (when counters
      (supertag-with-deferred-gc
        (supertag-with-transaction
          (pcase (let ((supertag-sync--yield-to-input t))
                   (supertag-sync--process-single-file file counters))
            ;; The user typed while FILE was being parsed: nothing was
            ;; written, so put it back and try again on the next idle.
            ('yielded (supertag-async-enqueue file))
            ;; Verification parses FILE again, so skip it when the pass
            ;; above already reconciled against a fresh parse.
            ('reconciled nil)
            (_ (supertag-sync--verify-file-nodes file counters))))))
    (supertag-sync--after-queued-file counters)))

;;; --- Parsing in another process ---

;; Reading and parsing a file touches nothing but that file, while applying
;; the records it yields needs the Store.  The queue therefore hands its
;; files to one long-lived batch Emacs that reads and parses them, and only
;; applies what comes back: the session is busy for the apply alone, however
;; large the file.  Requests and answers are one printed form per line, and
;; the process answers in the order it was asked.

(defcustom supertag-sync-parse-in-subprocess t
  "When non-nil, background sync parses Org files in a separate Emacs process.
The session then only applies the parsed records, so it stays responsive
while many files or a very large one are synchronized.  With nil, or when
that process cannot be used, files are parsed in this session during idle
time.  A full rescan always parses in this session."
  :type 'boolean
  :group 'supertag-sync)

(defconst supertag-sync-parser--window 64
  "Most files that may be at the parser process, answered or not, at once.")

(defconst supertag-sync-parser--silence-seconds 300
  "Seconds without an answer after which the parser process counts as stuck.")

(defconst supertag-sync-parser--linger-seconds 300
  "Seconds an idle parser process is kept before it is ended.")

(defconst supertag-sync-parser--org-variables
  '(org-todo-keywords org-comment-string org-archive-tag org-footnote-section
    org-odd-levels-only org-priority-highest org-priority-lowest
    org-link-abbrev-alist org-use-tag-inheritance
    org-tags-exclude-from-inheritance)
  "Org options a parse depends on, sent to the parser process with ours.")

(defvar supertag-sync-parser--process nil
  "The parser process, or nil when none is running.")

(defvar supertag-sync-parser--buffer nil
  "Buffer collecting the answers of the parser process.")

(defvar supertag-sync-parser--read-position 1
  "Position in the answer buffer of the first answer not yet applied.")

(defvar supertag-sync-parser--answered nil
  "Non-nil once the current parser process has sent a complete answer.")

(defvar supertag-sync-parser--heard-at 0.0
  "Time the parser process was last sent a request or answered one.")

(defvar supertag-sync-parser--broken nil
  "Non-nil when the parser process could not be used in this session.")

(defvar supertag-sync-parser--config nil
  "Printed settings for the parser process, or nil when they must be rebuilt.")

(defvar supertag-sync-parser--timer nil
  "Timer that ends an idle parser process or a stuck one.")

(defvar supertag-sync-parser--errors ""
  "The last text the parser process wrote to its standard error.")

(defvar supertag-sync-parser--default-extractors nil
  "The extractor registry as `supertag-extractor--setup-defaults' leaves it.")

(defvar supertag-text-link-relation-types)
(defvar supertag-text-link--session-types)

(defun supertag-sync-parser--print (object)
  "Return OBJECT printed as one line of ASCII text that `read' restores."
  (let ((print-escape-newlines t)
        (print-escape-control-characters t)
        (print-escape-nonascii t)
        (print-escape-multibyte t)
        (print-length nil)
        (print-level nil)
        (print-circle nil))
    (prin1-to-string object)))

(defun supertag-sync-parser--usable-p ()
  "Return non-nil when queued files should go to the parser process.
Extractors registered by the user are functions of this session, so their
presence keeps parsing here."
  (and supertag-sync-parse-in-subprocess
       (not supertag-sync-parser--broken)
       (eq supertag-async--processor-fn #'supertag-sync--async-processor)
       (equal supertag-extractor--registry
              supertag-sync-parser--default-extractors)))

(defun supertag-sync-parser--room-p ()
  "Return non-nil when the parser process can be handed more files."
  (<= (* 2 (length supertag-sync-parser--in-flight))
      supertag-sync-parser--window))

(defun supertag-sync-parser--settings ()
  "Return the printed settings a parse in the parser process depends on.
They are every Supertag option, the Org options in
`supertag-sync-parser--org-variables', the relation types and the names of
the registered Org link types.  Collected once for each run of the queue."
  (or supertag-sync-parser--config
      (let (symbols variables)
        (mapatoms
         (lambda (symbol)
           (when (and (boundp symbol)
                      (custom-variable-p symbol)
                      (string-prefix-p "supertag-" (symbol-name symbol)))
             (push symbol symbols))))
        (dolist (symbol supertag-sync-parser--org-variables)
          (when (boundp symbol)
            (push symbol symbols)))
        (dolist (symbol (sort symbols #'string<))
          (let ((value (symbol-value symbol)))
            ;; A value that does not survive printing stays at its default.
            (when (ignore-errors
                    (read-from-string (supertag-sync-parser--print value)))
              (push (cons symbol value) variables))))
        (setq supertag-sync-parser--config
              (supertag-sync-parser--print
               (list :variables (nreverse variables)
                     :relation-types (supertag-text-link-relation-types)
                     :link-types (mapcar #'car org-link-parameters)
                     :features (cl-remove-if-not #'featurep
                                                 '(org-inlinetask))))))))

(defun supertag-sync-parser--start ()
  "Start the parser process and return it, or nil when it cannot be started."
  (condition-case err
      (let* ((buffer (or (and (buffer-live-p supertag-sync-parser--buffer)
                              supertag-sync-parser--buffer)
                         (setq supertag-sync-parser--buffer
                               (generate-new-buffer
                                " *supertag-sync-parser*" t))))
             (errors (make-pipe-process
                      :name "supertag-sync-parser-errors"
                      :buffer nil :noquery t
                      :filter (lambda (_process text)
                                (setq supertag-sync-parser--errors
                                      (let ((all (concat
                                                  supertag-sync-parser--errors
                                                  text)))
                                        (substring
                                         all (max 0 (- (length all) 2000))))))
                      :sentinel #'ignore))
             (process
              (make-process
               :name "supertag-sync-parser"
               :buffer buffer
               :command
               (list (expand-file-name invocation-name invocation-directory)
                     "-Q" "--batch" "--eval"
                     (prin1-to-string
                      '(let ((init (read-from-minibuffer "" nil nil t)))
                         (setq load-path (plist-get init :load-path)
                               load-prefer-newer
                               (plist-get init :load-prefer-newer))
                         (require 'supertag-services-sync)
                         (supertag-sync-parser-serve init))))
               :connection-type 'pipe
               ;; Both directions carry ASCII only; see
               ;; `supertag-sync-parser--print'.
               :coding 'binary
               :noquery t
               :stderr errors
               :filter #'supertag-sync-parser--filter
               :sentinel #'supertag-sync-parser--sentinel)))
        (process-put process 'errors errors)
        (setq supertag-sync-parser--process process
              supertag-sync-parser--answered nil
              supertag-sync-parser--errors ""
              supertag-sync-parser--config nil)
        (process-send-string
         process
         (concat (supertag-sync-parser--print
                  (list :load-path load-path
                        :load-prefer-newer load-prefer-newer
                        :language-environment current-language-environment
                        :coding-priority (coding-system-priority-list)))
                 "\n"))
        process)
    (error
     (supertag-sync-parser--give-up (error-message-string err))
     nil)))

(defun supertag-sync-parser--give-up (reason)
  "Parse in this session from now on, because of REASON."
  (setq supertag-sync-parser--broken t)
  (message "Supertag: parsing in this session; the parser process failed: %s"
           (string-trim reason)))

(defun supertag-sync-parser--stop (&optional requeue)
  "End the parser process and forget what it was handed.
With REQUEUE non-nil, put the files it held back at the head of the queue."
  (when requeue
    (setq supertag-async--queue
          (nconc supertag-sync-parser--in-flight supertag-async--queue)))
  (when-let* ((process supertag-sync-parser--process))
    ;; Cleared first, so that the sentinel sees an intended end.
    (setq supertag-sync-parser--process nil)
    (when-let* ((errors (process-get process 'errors)))
      (delete-process errors))
    (delete-process process))
  (when (timerp supertag-sync-parser--timer)
    (cancel-timer supertag-sync-parser--timer))
  (when (buffer-live-p supertag-sync-parser--buffer)
    (with-current-buffer supertag-sync-parser--buffer
      (erase-buffer)))
  (setq supertag-sync-parser--timer nil
        supertag-sync-parser--in-flight nil
        supertag-sync-parser--ready 0
        supertag-sync-parser--read-position 1
        supertag-sync-parser--config nil))

(defun supertag-sync-parser--watch (seconds)
  "Look at the parser process again in SECONDS."
  (when (timerp supertag-sync-parser--timer)
    (cancel-timer supertag-sync-parser--timer))
  (setq supertag-sync-parser--timer
        (run-with-timer seconds nil #'supertag-sync-parser--check)))

(defun supertag-sync-parser--check ()
  "End the parser process when it is idle, or silent over files it holds."
  (setq supertag-sync-parser--timer nil)
  (cond
   ((not (process-live-p supertag-sync-parser--process)) nil)
   ((not (supertag-async-busy-p)) (supertag-sync-parser--stop))
   ((and (nthcdr supertag-sync-parser--ready supertag-sync-parser--in-flight)
         (> (- (float-time) supertag-sync-parser--heard-at)
            supertag-sync-parser--silence-seconds))
    ;; Its sentinel sets aside the file it was reading.
    (setq supertag-sync-parser--answered t)
    (delete-process supertag-sync-parser--process))
   (t (supertag-sync-parser--watch supertag-sync-parser--silence-seconds))))

(defun supertag-sync-parser--drained ()
  "Note that the queue has no work left for the parser process."
  (setq supertag-sync-parser--config nil)
  (when (process-live-p supertag-sync-parser--process)
    (supertag-sync-parser--watch supertag-sync-parser--linger-seconds)))

(defun supertag-sync-parser--dispatch ()
  "Hand queued files to the parser process while it has room for them."
  (when (and supertag-async--queue (supertag-sync-parser--room-p))
    (when-let* ((process (if (process-live-p supertag-sync-parser--process)
                             supertag-sync-parser--process
                           (supertag-sync-parser--start))))
      (let ((room (- supertag-sync-parser--window
                     (length supertag-sync-parser--in-flight)))
            files entries)
        (while (and supertag-async--queue (> room 0))
          (let ((file (pop supertag-async--queue)))
            (push file files)
            (push (cons file (supertag-sync--file-parse-request file)) entries)
            (cl-decf room)))
        (setq supertag-sync-parser--in-flight
              (nconc supertag-sync-parser--in-flight (nreverse files))
              supertag-sync-parser--heard-at (float-time))
        (process-send-string
         process
         (concat "(:settings " (supertag-sync-parser--settings)
                 " :files " (supertag-sync-parser--print (nreverse entries))
                 ")\n"))
        (supertag-sync-parser--watch supertag-sync-parser--silence-seconds)))))

(defun supertag-sync-parser--filter (process text)
  "Collect TEXT, which the parser PROCESS answered, for the next idle time."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (goto-char (point-max))
      (insert text)))
  (when (eq process supertag-sync-parser--process)
    (let ((start 0))
      (while (setq start (string-search "\n" text start))
        (cl-incf supertag-sync-parser--ready)
        (cl-incf start)))
    (setq supertag-sync-parser--heard-at (float-time))
    (when (> supertag-sync-parser--ready 0)
      (setq supertag-sync-parser--answered t)
      (supertag-async--ensure-timer))))

(defun supertag-sync-parser--sentinel (process _event)
  "Recover the files PROCESS, the parser process, held when it ended."
  (when (and (eq process supertag-sync-parser--process)
             (not (process-live-p process)))
    (setq supertag-sync-parser--process nil)
    (when-let* ((errors (process-get process 'errors)))
      (delete-process errors))
    (when (buffer-live-p supertag-sync-parser--buffer)
      ;; An answer cut short is no answer.
      (with-current-buffer supertag-sync-parser--buffer
        (goto-char (point-max))
        (delete-region (line-beginning-position) (point-max))))
    (let* ((answered (cl-subseq supertag-sync-parser--in-flight
                                0 (min supertag-sync-parser--ready
                                       (length supertag-sync-parser--in-flight))))
           (unanswered (nthcdr (length answered)
                               supertag-sync-parser--in-flight)))
      (setq supertag-sync-parser--in-flight answered)
      (cond
       ((null unanswered) nil)
       ((not supertag-sync-parser--answered)
        ;; It never got as far as one file: its environment is the problem.
        (supertag-sync-parser--give-up supertag-sync-parser--errors))
       (t
        ;; It ended while reading the first of them.
        (let ((file (pop unanswered)))
          (cl-pushnew file supertag-async--failed-items :test #'equal)
          (message
           (concat "Supertag sync failed for %s: the parser process ended while reading it. "
                   "Data safety: the Org source file was not modified, and its filename is retained for retry. "
                   "Next: fix the cause, then run M-x supertag-sync-full-rescan.")
           file))))
      (setq supertag-async--queue (nconc unanswered supertag-async--queue)))
    (supertag-async--ensure-timer)))

(defun supertag-sync-parser--take ()
  "Remove the oldest waiting answer and return it, or nil if it is not one."
  (with-current-buffer supertag-sync-parser--buffer
    (goto-char supertag-sync-parser--read-position)
    (let* ((end (line-end-position))
           (form (save-restriction
                   (narrow-to-region (point) end)
                   (ignore-errors (read (current-buffer))))))
      (cl-decf supertag-sync-parser--ready)
      (setq supertag-sync-parser--read-position (min (1+ end) (point-max)))
      (cond
       ((= supertag-sync-parser--read-position (point-max))
        (erase-buffer)
        (setq supertag-sync-parser--read-position 1))
       ;; Text still arriving keeps the buffer from ever being empty.
       ((> supertag-sync-parser--read-position 1000000)
        (delete-region (point-min) supertag-sync-parser--read-position)
        (setq supertag-sync-parser--read-position 1)))
      (when (eq (car-safe form) 'supertag-parsed)
        (cdr form)))))

(defun supertag-sync-parser--apply-next ()
  "Apply the oldest answer of the parser process to the Store."
  (when-let* ((answer (supertag-sync-parser--take))
              (file (plist-get answer :file)))
    (setq supertag-sync-parser--in-flight
          (cl-delete file supertag-sync-parser--in-flight
                     :test #'equal :count 1))
    (dolist (text (plist-get answer :messages))
      (message "%s" text))
    (let ((attributes (file-attributes file)))
      (cond
       ((or (plist-get answer :missing) (null attributes))
        (supertag-sync--after-queued-file nil))
       ;; Whatever stopped the parse there is reported by parsing here.
       ((plist-get answer :error)
        (supertag-async--attempt
         file (lambda () (funcall supertag-async--processor-fn file))))
       ;; FILE changed after it was read: these records are of older text.
       ((not (and (equal (plist-get answer :size)
                         (file-attribute-size attributes))
                  (time-equal-p
                   (plist-get answer :mtime)
                   (file-attribute-modification-time attributes))))
        (supertag-async-enqueue file))
       (t
        (supertag-async--attempt
         file (lambda () (supertag-sync--apply-parsed-file file answer))))))))

(defun supertag-sync--apply-parsed-file (file records)
  "Apply RECORDS, which the parser process read from FILE, to the Store."
  (let ((counters (supertag-sync--file-counters)))
    (supertag-with-deferred-gc
      (supertag-with-transaction
        (unless (supertag-sync--apply-file-records file records counters)
          ;; The file's text is the text last synchronized; only nodes the
          ;; Store still holds for it can be wrong.
          (when (and (plist-get records :unchanged)
                     (supertag-sync--allow-destructive-p))
            (supertag-sync--delete-nodes-missing-from
             file (plist-get records :ids) counters)))))
    (supertag-sync--after-queued-file counters)))

;; The functions below run in the parser process.

(defvar supertag-sync-parser--applied-settings nil
  "In the parser process, the settings of the last request.")

(defun supertag-sync-parser--apply-settings (settings)
  "In the parser process, parse from now on as SETTINGS say."
  (unless (equal settings supertag-sync-parser--applied-settings)
    (setq supertag-sync-parser--applied-settings settings)
    ;; Records remembered under other settings are no longer the same parse.
    (clrhash supertag-sync--parse-memo)
    (dolist (feature (plist-get settings :features))
      (require feature nil t))
    (pcase-dolist (`(,symbol . ,value) (plist-get settings :variables))
      (set symbol value))
    (require 'supertag-link)
    (setq supertag-text-link-relation-types (plist-get settings :relation-types)
          supertag-text-link--session-types nil)
    (supertag-text-link-refresh)
    (dolist (type (plist-get settings :link-types))
      (unless (assoc type org-link-parameters)
        (org-link-set-parameters type)))
    (org-link-make-regexps)))

(defun supertag-sync-parser--hash-records (file records)
  "In the parser process, return RECORDS of FILE with every node hashed.
Hashing is most of what the session would otherwise do for a node that did
not change.  The hash goes in :parsed-hash, on a copy: the node records are
shared with the memo of parsed headings and their hash moves with them."
  (let ((header (plist-get records :header))
        (nodes (plist-get records :nodes)))
    (when (plist-get header :id)
      (setq records
            (plist-put (copy-sequence records) :header
                       (append header
                               (list :parsed-hash
                                     (supertag-sync--parsed-hash
                                      (supertag-sync--file-node-props
                                       file header)))))))
    (when nodes
      (setq records
            (plist-put (copy-sequence records) :nodes
                       (mapcar (lambda (node)
                                 (append node
                                         (list :parsed-hash
                                               (supertag-sync--parsed-hash node))))
                               nodes))))
    records))

(defun supertag-sync-parser--read (file old-hash force)
  "In the parser process, return the answer for FILE as a plist.
OLD-HASH and FORCE are as for `supertag-sync--read-file-records'."
  (let ((logged (with-current-buffer (messages-buffer) (point-max))))
    (append
     (list :file file)
     (condition-case err
         (let ((attributes (file-attributes file)))
           (if (null attributes)
               (list :missing t)
             (append
              (list :size (file-attribute-size attributes)
                    :mtime (file-attribute-modification-time attributes))
              (supertag-sync-parser--hash-records
               file (supertag-sync--read-file-records file old-hash force t)))))
       (error (list :error (error-message-string err))))
     (with-current-buffer (messages-buffer)
       (when (> (point-max) logged)
         (list :messages
               (split-string (buffer-substring-no-properties
                              logged (point-max))
                             "\n" t)))))))

(defun supertag-sync-parser-serve (init)
  "Answer parse requests from standard input until it closes.
This is all the parser process does.  INIT is the first form the session
sent; it names the language environment and coding systems to read files
with."
  (setq kill-emacs-hook nil)
  (when-let* ((environment (plist-get init :language-environment)))
    (ignore-errors (set-language-environment environment)))
  (when-let* ((priority (plist-get init :coding-priority)))
    (ignore-errors (apply #'set-coding-system-priority priority)))
  (condition-case nil
      (while t
        (let ((request (read-from-minibuffer "" nil nil t)))
          (supertag-sync-parser--apply-settings (plist-get request :settings))
          (dolist (entry (plist-get request :files))
            (princ (supertag-sync-parser--print
                    (cons 'supertag-parsed
                          (apply #'supertag-sync-parser--read entry))))
            (terpri)
            (flush-standard-output))))
    ;; Standard input closed: the session is gone or has ended us.
    (end-of-file nil))
  (kill-emacs 0))

(defun supertag-sync-start-auto-sync (&optional interval)
  "Start automatic synchronization with INTERVAL seconds.
If INTERVAL is nil, use `supertag-sync-auto-interval`."
  ;; Safety check: ensure function is defined before setting timer
  (unless (fboundp 'supertag-sync--check-and-sync)
    (error "supertag-sync--check-and-sync function is not defined. Cannot start auto-sync."))

  ;; Cancel existing timer
  (when supertag-sync--timer
    (cancel-timer supertag-sync--timer)
    (setq supertag-sync--timer nil))

  ;; Initialize the async queue with our processor
  (supertag-async-init #'supertag-sync--async-processor)

  ;; Ensure store is initialized before starting auto-sync
  (unless (hash-table-p supertag--store)
    (setq supertag--store (ht-create)))
  ;; Start new timer with safety wrapper (fixed interval, not idle)
  (setq supertag-sync--timer
        (run-with-timer
         0 ; First sync as soon as timers run
         (or interval supertag-sync-auto-interval) ; Then, repeat at the configured interval
         (lambda ()
           "Safe wrapper for scheduling sync during idle periods."
           (supertag-sync--check-and-sync)))))

(defun supertag-sync-stop-auto-sync ()
  "Stop automatic synchronization."
  (when supertag-sync--timer
    (cancel-timer supertag-sync--timer)
    (setq supertag-sync--timer nil)
    (message "Auto-sync stopped"))
  ;; Stop the async worker
  (supertag-async-clear))

(defun supertag-reindex-org ()
  "Rebuild Document Projections from one complete Org snapshot.
This function never restores Semantic Facts and never modifies Org files;
the user command is `supertag-sync-full-rescan'.
Return a report plist whose :status is `complete', `aborted', or `failed'."
  (supertag-sync--ensure-state-source)
  (let* (;; One truename per directory for the whole pass.
         (supertag-sync--directory-truenames
          (or supertag-sync--directory-truenames
              (make-hash-table :test 'equal)))
         (previous-snapshot (copy-tree (supertag-sync--snapshot-get)))
         (snapshot (supertag-sync--snapshot-build))
         (snapshot-status (plist-get snapshot :status))
         (files (sort (copy-sequence (plist-get snapshot :files)) #'string<))
         (state-table (supertag-sync--get-state-table))
         (state-before (copy-hash-table state-table))
         (deferred-before (copy-hash-table supertag-sync--deferred-files))
         (processed 0)
         (counters '(:nodes-created 0 :nodes-updated 0 :nodes-deleted 0
                     :references-created 0 :references-deleted 0))
         (supertag-sync--is-full-rescan-p t)
         (supertag-sync--verified-ids (make-hash-table :test 'equal))
         (supertag-automation-sync--enabled nil)
         report)
    (supertag-sync--snapshot-set snapshot)
    (if (not (eq snapshot-status 'complete))
        (setq report
              (list :status 'aborted
                    :snapshot-status snapshot-status
                    :files-discovered (length files)
                    :files-processed 0
                    :errors (plist-get snapshot :errors)))
      (progn
        (condition-case err
            (progn
              (supertag-with-transaction
                (dolist (file files)
                  (supertag-sync--process-single-file file counters)
                  (cl-incf processed))
                ;; File order cannot affect links or derived query state.
                (supertag-index-rebuild-relations)
                (supertag-sync--reconcile-all-projected-relations counters)
                (supertag-sync--rebuild-reference-caches)
                (supertag-sync-validate-nodes counters)
                (supertag-index-rebuild-all))
              (setq report
                    (list :status 'complete
                          :snapshot-status snapshot-status
                          :files-discovered (length files)
                          :files-processed processed
                          :nodes-created (plist-get counters :nodes-created)
                          :nodes-updated (plist-get counters :nodes-updated)
                          :nodes-deleted (plist-get counters :nodes-deleted)
                          :references-created
                          (plist-get counters :references-created)
                          :references-deleted
                          (plist-get counters :references-deleted))))
          (error
           (clrhash state-table)
           (maphash (lambda (file state)
                      (puthash file state state-table))
                    state-before)
           (setq supertag-sync--deferred-files deferred-before)
           (supertag-sync--snapshot-set previous-snapshot)
           (setq report
                 (list :status 'failed
                       :snapshot-status snapshot-status
                       :files-discovered (length files)
                       :files-processed processed
                       :errors (list (error-message-string err))))))
        (when (eq (plist-get report :status) 'complete)
          ;; A surrounding caller owns its own commit/save boundary.
          (unless supertag--transaction-active
            (supertag-save-store))
          (supertag-sync-save-state))))
    report))

;;;###autoload
(defun supertag-sync-full-rescan ()
  "Rebuild Document Projections from one complete Org snapshot.
Run `supertag-reindex-org', report the outcome in the echo area, and
after a complete rebuild forget the files retained by failed background
syncs (`supertag-async-clear-failed'), since the rebuild re-read them.
Never restore Semantic Facts and never modify Org files.  Return the
report plist."
  (interactive)
  (let ((report (supertag-reindex-org)))
    (when (eq (plist-get report :status) 'complete)
      (supertag-async-clear-failed))
    (pcase (plist-get report :status)
      ('complete
       (message
        "Supertag reindex: %d files, %d created, %d updated, %d deleted, %d refs created, %d refs deleted."
        (plist-get report :files-processed)
        (plist-get report :nodes-created)
        (plist-get report :nodes-updated)
        (plist-get report :nodes-deleted)
        (plist-get report :references-created)
        (plist-get report :references-deleted)))
      ('aborted
       (message "Supertag reindex aborted: snapshot is %s; no changes made."
                (plist-get report :snapshot-status)))
      ('failed
       (message "Supertag reindex failed after %d files; Store changes rolled back: %s"
                (plist-get report :files-processed) (car (plist-get report :errors)))))
    report))

;;;-------------------------------------------------------------------
;;; Database Cleanup
;;;-------------------------------------------------------------------

;;;###autoload
(defun supertag-sync-cleanup-database ()
  "Delete every database node that no Org file backs.
`supertag-sync-validate-nodes' checks each node against its source file
and deletes the ones whose file is gone or no longer holds their ID.
Org files are never modified."
  (interactive)
  (when (or (not (called-interactively-p 'interactive))
            (yes-or-no-p "Delete database nodes that no Org file backs? "))
    (let ((deleted (or (supertag-with-transaction
                         (supertag-sync-validate-nodes))
                       0)))
      (when (and (> deleted 0) (not supertag--transaction-active))
        (supertag-save-store))
      (message "Database cleanup complete. %d nodes deleted." deleted))))


;;;-------------------------------------------------------------------
;;; Node-Based Real-time Sync
;;;-------------------------------------------------------------------

(defun supertag-sync--run-on-save ()
  "Hook function to run single-node sync after saving a buffer.
This function distinguishes between internal modifications (by Supertag) and
external modifications (by user/other tools) to avoid unnecessary re-parsing."
  ;; Only run for org-mode buffers that are part of the sync scope
  (when (and (derived-mode-p 'org-mode) (buffer-file-name))
    (let* ((file (buffer-file-name))
           (file-norm (and file (file-truename (expand-file-name file)))))
      (when (and file-norm (supertag-sync--in-sync-scope-p file-norm))
        ;; Check if this is an internal modification
        (if (supertag--is-internal-modification-p file-norm)
            ;; Internal modification: skip sync, memory is already up-to-date
            (progn
              (when supertag-sync-smart-detection-verbose
                (message "Supertag: Skip sync for internal modification: %s" (file-name-nondirectory file-norm)))
              ;; Update sync state to prevent periodic sync from re-syncing
              (supertag-sync-update-state
               (supertag-sync--scanned-name file-norm)))
          ;; External modification: enqueue for async sync
          (when supertag-sync-smart-detection-verbose
            (message "↻ %s" (file-name-nondirectory file-norm)))
          (supertag-async-enqueue
           (supertag-sync--scanned-name file-norm)))))))


(defun supertag-sync-setup-realtime-hooks ()
  "Add hooks for real-time node synchronization."
  (add-hook 'after-save-hook #'supertag-sync--run-on-save nil t))

(defun supertag--project-nodes-from-org-text (current-file source-text &optional node-id)
  "Return heading node projections in SOURCE-TEXT for CURRENT-FILE.
When NODE-ID is non-nil, extract only that node, preserving ancestor context.

SOURCE-TEXT is projected in a scratch buffer, so the destructive embed-block
stripping `supertag--parse-org-nodes-from-current-buffer' performs never
reaches the caller's buffer.  Org syntax that the source buffer configures
per-buffer -- TODO keywords and the regexps derived from them -- is carried
over so the projection reads the text the same way its own buffer does.

Only heading nodes are returned; the file node belongs to
`supertag-sync--upsert-file-node' and is not part of this projection."
  (let ((source-todo-keywords-1 org-todo-keywords-1)
        (source-todo-regexp org-todo-regexp)
        (source-not-done-regexp org-not-done-regexp)
        (source-complex-heading-regexp org-complex-heading-regexp)
        (source-todo-line-regexp org-todo-line-regexp))
    (with-temp-buffer
      (let ((org-mode-hook nil)
            (org-inhibit-startup t)
            (org-agenda-inhibit-startup t)
            (inhibit-modification-hooks t))
        (insert source-text)
        (delay-mode-hooks (org-mode))
        (setq-local org-element-use-cache nil)
        (setq-local org-todo-keywords-1 source-todo-keywords-1)
        (setq-local org-todo-regexp source-todo-regexp)
        (setq-local org-not-done-regexp source-not-done-regexp)
        (setq-local org-complex-heading-regexp source-complex-heading-regexp)
        (setq-local org-todo-line-regexp source-todo-line-regexp)
        (setq-local tab-width 8)
        (if node-id
            (supertag--parse-org-nodes-from-current-buffer current-file nil node-id)
          (supertag--parse-org-nodes-from-current-buffer current-file))))))

(defun supertag--project-node-from-org-text (node-id current-file source-text)
  "Return NODE-ID's projection from SOURCE-TEXT, Org source for CURRENT-FILE.

SOURCE-TEXT is projected in a scratch buffer, so the destructive embed-block
stripping `supertag--parse-org-nodes-from-current-buffer' performs never
reaches the caller's buffer.  Org syntax that the source buffer configures
per-buffer -- TODO keywords and the regexps derived from them -- is carried
over so the projection reads the text the same way its own buffer does.

Callers that reproject several nodes of one file want
`supertag--project-nodes-from-org-text' instead: this function parses the
outline and NODE-ID's subtree, running extractors only for NODE-ID."
  (cl-find node-id
           (supertag--project-nodes-from-org-text current-file source-text node-id)
           :key (lambda (node) (plist-get node :id))
           :test #'equal))

(defun supertag--parse-node-at-point ()
  "Parse the Org heading at point and return its property list.
The current unsaved buffer is parsed through the same projector as file sync,
preserving outline path, file parent, and absolute positions.

The outline is parsed for context, but only this subtree's body is parsed
and only this node is extracted.  Callers that only need
node-local data should use `supertag-node-tag-occurrences-at-point' or another
region-scoped reader instead."
  (when (org-at-heading-p)
    (save-excursion
      (org-back-to-heading t)
      (let* ((source-buffer (or (buffer-base-buffer) (current-buffer)))
             (source-file (buffer-local-value 'buffer-file-name source-buffer)))
        (when-let* ((node-id (org-entry-get nil "ID"))
                    (current-file (and source-file
                                       (file-truename
                                        (expand-file-name source-file)))))
          (supertag--project-node-from-org-text
           node-id current-file
           (save-restriction
             (widen)
             (buffer-substring-no-properties (point-min) (point-max)))))))))

(defun supertag-node-tag-occurrences-at-point ()
  "Return the Org Tag Occurrences of the heading at point, or nil.

Same list as (plist-get (supertag--parse-node-at-point) :tag-occurrences),
including nil when point is not on a heading.  It runs only the Tag extractor
on the heading under point: title line plus direct body before the next
heading.  The surrounding nodes cannot contribute occurrences, so parsing
them would make every tag edit scale with the file rather than with the node.

Only `:tag-occurrences' is read because the remaining fields of a local
reader (`:olp', `:parent-id', and positions) are not a replacement for a
whole-file projection."
  (when (org-at-heading-p)
    (save-excursion
      (org-back-to-heading t)
      (when-let* ((_ (org-entry-get nil "ID"))
                  (begin (point))
                  (end (save-excursion (outline-next-heading) (point)))
                  ;; This parser sees only the current heading and its direct
                  ;; body.  `org-element-at-point' leaves those contents
                  ;; deferred, while `org-element-parse-buffer' would parse
                  ;; every heading in the file.
                  (headline (car (org-element--parse-elements
                                  begin end nil nil nil nil nil)))
                  (_ (eq (org-element-type headline) 'headline)))
        (plist-get (supertag-extractor--tags headline nil nil)
                   :tag-occurrences)))))

;;;###autoload
(defun supertag-node-sync-at-point ()
  "Re-sync the node at point with the database.
Parses the current state of the headline and updates the store."
  (when (org-at-heading-p)
    (let ((props (supertag--parse-node-at-point)))
      (when props
        (supertag-sync--reconcile-node props)))))

(defun supertag-node-sync-current-buffer (node-id)
  "Re-sync NODE-ID from its authoritative Org text in the current buffer."
  (let ((node (supertag-node-get node-id)))
    (if (zerop (or (plist-get node :level) 1))
        (supertag-sync--upsert-file-node
         (buffer-file-name) (supertag-sync--parse-file-header) nil)
      (unless (and (org-at-heading-p)
                   (equal node-id (org-entry-get nil "ID")))
        (goto-char (point-min))
        (unless (re-search-forward
                 (concat "^[ \t]*:ID:[ \t]*"
                         (regexp-quote node-id) "[ \t]*$") nil t)
          (user-error "Node '%s' was not found in %s" node-id (buffer-name)))
        (org-back-to-heading t))
      (supertag-node-sync-at-point))))

;;;###autoload
(defun supertag-migrate-org-files-to-database (path &optional counters allow-no-id)
  "One-time migration function to import nodes and tags from Org files
into the database.
PATH can be a file or a directory path. If it is a directory, all .org files
will be processed recursively.

COUNTERS is an optional plist for tracking migration statistics.
ALLOW-NO-ID is retained for caller compatibility; ID-less headings are
skipped.
Returns a plist containing summary information.

This is a one-time operation for initializing user data when first using
supertag.
It will create entities of type :node and :tag, and establish relations
between them."
  (let* ((counters (or counters (list :files-processed 0
                                     :nodes-created 0
                                     :tags-created 0
                                     :relations-created 0
                                     :errors 0)))
         (org-files (if (file-directory-p path)
                        (supertag--find-org-files path)
                      (list path)))
         (all-nodes '())
         (all-tags '()))

    (message "Migrating org files to database...")
    (message "Found %d org files" (length org-files))

    ;; First phase: Parse all files, collect nodes and tags
    (dolist (file org-files)
      (condition-case err
          (progn
            (message "Parsing file: %s" file)
            (let ((nodes (supertag--parse-org-nodes file (not allow-no-id))))
              (setq all-nodes (append all-nodes nodes))
              ;; Collect tags from valid nodes
              (dolist (node nodes)
                (let ((node-tags (or (plist-get node :tag-occurrences)
                                     (plist-get node :tags))))
                  (when node-tags
                    (setq all-tags (append all-tags node-tags))))))
            (setf (plist-get counters :files-processed)
                  (1+ (plist-get counters :files-processed))))
        (error
         (message "Failed to parse file %s: %s" file (error-message-string err))
         (setf (plist-get counters :errors)
               (1+ (plist-get counters :errors))))))

    ;; Remove duplicate tags
    (setq all-tags (cl-delete-duplicates all-tags :test #'equal))

    (message "Parsing completed: %d nodes, %d unique tags"
             (length all-nodes) (length all-tags))

    ;; Second phase: Create tag entities
    (message "Creating tag entities...")
    (let ((tag-ids (supertag--create-tag-entities all-tags)))
      (setf (plist-get counters :tags-created) (length tag-ids)))

    ;; Third phase: Create node entities
    (message "Creating node entities...")
    (dolist (node all-nodes)
      (condition-case err
          (let ((canonical-node
                 (supertag-sync--resolve-node-tag-occurrences node)))
            ;; Create node
            (supertag-node-create canonical-node)
            (setf (plist-get counters :nodes-created)
                  (1+ (plist-get counters :nodes-created))))
        (error
         (message "Failed to create node %s: %s" (plist-get node :id) (error-message-string err))
         (setf (plist-get counters :errors)
               (1+ (plist-get counters :errors))))))

    ;; Return statistics
    (message "Migration completed!")
    (message "Statistics: files=%d, nodes=%d, tags=%d, relations=%d, errors=%d"
             (plist-get counters :files-processed)
             (plist-get counters :nodes-created)
             (plist-get counters :tags-created)
             (plist-get counters :relations-created)
             (plist-get counters :errors))

    counters))

(defun supertag--find-org-files (directory)
  "Recursively find all .org files in DIRECTORY.
DIRECTORY is the directory path to search.
Returns a list of .org file paths."
  (let ((org-files '()))
    (dolist (file (directory-files-recursively directory "\\.org$"))
      (when (file-readable-p file)
        (push file org-files)))
    (nreverse org-files)))

(defun supertag--diagnose-empty-sync (&optional quiet)
  "Diagnose why sync found no files to process.
QUIET suppresses benign \"all clear\" diagnostics.
Provides helpful hints to the user about configuration issues."
  (let* ((sync-dirs (supertag-sync--effective-directories))
         (state-table (supertag-sync--get-state-table))
        (state-count (if (hash-table-p state-table)
                         (hash-table-count state-table)
                       0)))

    (cond
     ;; Case 1: No sync directories configured
     ((null sync-dirs)
      (message "DIAGNOSTIC: No sync directories configured. Set supertag-sync-directories."))

     ;; Case 2: Sync directories don't exist
     ((not (cl-some #'file-directory-p sync-dirs))
      (message "DIAGNOSTIC: None of the configured sync directories exist:")
      (dolist (dir sync-dirs)
        (message "  - %s [%s]" dir (if (file-exists-p dir) "exists but not a directory" "does not exist"))))

     ;; Case 3: Directories exist but contain no matching files
     ((= state-count 0)
      (message "DIAGNOSTIC: Sync directories exist but no .org files found or tracked:")
      (dolist (dir sync-dirs)
        (when (file-directory-p dir)
          (let ((org-files (directory-files-recursively dir "\\.org$" nil)))
            (message "  - %s: %d .org files found" dir (length org-files))
            (when (= (length org-files) 0)
              (message "    Hint: Check if directory contains .org files"))))))
     ;; Case 4: Files tracked but all up-to-date
     ((not quiet)
      (message "DIAGNOSTIC: %d files tracked." state-count)))))

;;; --- Explicit Resync and Status Commands ---

(defun supertag-sync-force-resync-file (file)
  "Force resync FILE, ignoring existing sync state."
  (unless (file-exists-p file)
    (user-error "File does not exist: %s" file))

  (unless (supertag-sync--in-sync-scope-p file)
    (user-error "File is not in sync scope: %s" file))

  (when (yes-or-no-p (format "Force resync file %s? " (file-name-nondirectory file)))
    (message "Force resyncing file: %s" file)

    ;; Remove from sync state to force processing
    (let ((state-table (supertag-sync--get-state-table)))
      (remhash file state-table))

    ;; Process the file
    (let ((counters '(:nodes-created 0 :nodes-updated 0 :nodes-deleted 0
                     :references-created 0 :references-deleted 0)))
      (supertag-with-transaction
        (supertag-sync--process-single-file file counters))

      ;; Update state and report
      (supertag-sync-update-state file)
      (supertag-sync-save-state)

      (message "Force resync completed: %d created, %d updated, %d deleted"
               (plist-get counters :nodes-created)
               (plist-get counters :nodes-updated)
               (plist-get counters :nodes-deleted)))))

;;;###autoload
(defun supertag-sync-force-resync-current-file ()
 "Force resync the current file."
 (interactive)
 (unless (buffer-file-name)
   (user-error "Current buffer is not visiting a file"))
 (supertag-sync-force-resync-file (buffer-file-name)))

;;;###autoload
(defun supertag-sync-status ()
 "Show current sync status and configuration."
 (interactive)
 (let* ((state-table (supertag-sync--get-state-table))
        (num-tracked-files (hash-table-count state-table))
        (modified-files (supertag-get-modified-files))
        (num-modified (length modified-files))
        (timer-active (and supertag-sync--timer (not (null supertag-sync--timer)))))

   (message "=== Supertag Sync Status ===")
   (message "Sync directories: %s" supertag-sync-directories)
   (message "Exclude directories: %s" supertag-sync-exclude-directories)
   (message "File pattern: %s" supertag-sync-file-pattern)
   (message "Auto-sync: %s" (if timer-active "ACTIVE" "INACTIVE"))
   (message "Tracked files: %d" num-tracked-files)
   (message "Modified files: %d" num-modified)

   (when (> num-modified 0)
     (message "Modified files:")
     (dolist (file modified-files)
       (message "  - %s" file)))))

;;; --- Register Built-in Extractors ---
(supertag-extractor--setup-defaults)
(setq supertag-sync-parser--default-extractors
      (copy-tree supertag-extractor--registry))

(defun supertag-sync--reset-runtime ()
  "Clear in-memory sync work belonging to the previous vault."
  (clrhash supertag-sync--deferred-files)
  (clrhash supertag-sync--internal-modifications)
  (clrhash supertag-sync--parse-memo)
  ;; The queue outlives this, so the files handed out go back into it.
  (supertag-sync-parser--stop t))

(provide 'supertag-services-sync)
