;;; supertag-node.el --- Node entities and current-buffer navigation -*- lexical-binding: t; -*-

;;; Commentary:
;; Commands: supertag-find-node, supertag-move-node, supertag-move-node-and-link.
;; Other Lisp entry points are
;; supertag-node-create/get/update/delete/set-location and
;; supertag-node--goto-location, supertag-ui-select-node,
;; supertag-ui-select-multiple-nodes,
;; supertag-node-reference-and-create, supertag-ui--reproject-containing-node,
;; supertag--get-node-props-at-point, supertag-ui--get-node-at-point,
;; supertag-ui--create-heading-node, supertag-ui--heading-title-at-point,
;; supertag-service-org-follow-id, supertag-service-org--parent-title,
;; supertag-view-helper-find-node-location,
;; supertag-capture-finalize-node-at-point,
;; supertag-enable-org-capture-integration and supertag-disable-org-capture-integration.
;; Dependencies: cl-lib, org, org-capture, org-id, org-element, subr-x, supertag-core-store,
;; supertag-link (ordinary Relation provider), supertag-core-persistence, supertag-service-org.
;; Tag membership is loaded lazily.  Identity, transactions and persistence
;; remain shared providers; Link formatting belongs to supertag-link.
;; Shared location adapters use supertag-query and supertag-services-sync only on demand.
;; Find uses shared Org creation presets; Query readers remain ordinary lazy providers.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-capture)
(require 'org-id)
(require 'org-element)
(require 'subr-x)
(require 'supertag-core-store)
;; Ordinary Relation providers load Link only on first use.
(autoload 'supertag-relation-delete-for-node "supertag-link")
(declare-function supertag-relation-delete-for-node "supertag-link" (node-id))
(require 'supertag-core-persistence)
(require 'supertag-service-org)

;; Membership definitions live in Tag; preserve standalone Node callers lazily.
(autoload 'supertag-node-add-tag "supertag-tag")
(autoload 'supertag-node-remove-tag "supertag-tag")
(autoload 'supertag-node-has-tag-p "supertag-tag")
(autoload 'supertag-node-toggle-tag "supertag-tag")

;; Ordinary providers: registration does not execute scan or Sync.
(autoload 'supertag-find-file-node "supertag-query")
(declare-function supertag-find-file-node "supertag-query" (file-path))
(autoload 'supertag-node-sync-at-point "supertag-services-sync")
(declare-function supertag-node-sync-at-point "supertag-services-sync" ())
(autoload 'supertag-sync--process-single-file "supertag-services-sync")
(declare-function supertag-sync--process-single-file "supertag-services-sync" (file counters))
(autoload 'supertag-sync--in-scope-path-p "supertag-services-sync")
(declare-function supertag-sync--in-scope-path-p "supertag-services-sync" (file))
(autoload 'supertag-sync--in-sync-scope-p "supertag-services-sync")
(declare-function supertag-sync--in-sync-scope-p "supertag-services-sync" (file))
(autoload 'supertag-sync-update-state "supertag-services-sync")
(declare-function supertag-sync-update-state "supertag-services-sync" (file &optional content-hash))
(autoload 'supertag-sync--parse-file-header "supertag-services-sync")
(declare-function supertag-sync--parse-file-header "supertag-services-sync" ())
(autoload 'supertag-sync--upsert-file-node "supertag-services-sync")
(declare-function supertag-sync--upsert-file-node "supertag-services-sync" (file file-header counters))

;; Ordinary Find providers are loaded on first use, never at registration.
(autoload 'supertag-query-nodes "supertag-query")
(declare-function supertag-query-nodes "supertag-query" (&optional filter))
(autoload 'supertag-template-read "supertag-service-org")
(declare-function supertag-template-read "supertag-service-org" ())
(autoload 'supertag-template-normalize "supertag-service-org")
(declare-function supertag-template-normalize "supertag-service-org" (template))
(autoload 'supertag-service-org-create-node "supertag-service-org")
(declare-function supertag-service-org-create-node "supertag-service-org" (target-file title &optional tags content))
(autoload 'supertag-view-api-get-entity "supertag-query")
(declare-function supertag-view-api-get-entity "supertag-query" (type entity-id))

;; Move shares the existing Org writer and its recovery payloads on demand.
(autoload 'supertag-service-org-move-nodes "supertag-service-org")
(declare-function supertag-service-org-move-nodes "supertag-service-org"
                  (sources target-file &optional target-position target-level leave-link))

;; Standard Capture reuses Tag input and membership providers on first use.
(autoload 'supertag-capture-add-tags-to-nodes "supertag-tag")
(declare-function supertag-capture-add-tags-to-nodes "supertag-tag" (node-ids tags &optional position))
(autoload 'supertag-capture-add-tag-to-nodes "supertag-tag")
(declare-function supertag-capture-add-tag-to-nodes "supertag-tag" (node-ids tag &optional position))
(autoload 'supertag-capture--get-from-tags-prompt "supertag-tag")
(declare-function supertag-capture--get-from-tags-prompt "supertag-tag" (args))

;; Compatibility reads use the original Sync parser on first invocation.
(autoload 'supertag--convert-element-to-node-plist "supertag-services-sync")
(declare-function supertag--convert-element-to-node-plist "supertag-services-sync"
                  (headline file &optional _migration-mode))

;;; Validation

(defun supertag--validate-node-data (data)
  "Strict validation for node data. Fails fast on any inconsistency.
Implements immediate error reporting as preferred by the user."
  (unless (plist-get data :id)
    (error "Node missing required :id field: %S" data))
  (unless (or (plist-get data :title)
              (eq (plist-get data :level) 0))
    (error "Node missing required :title field: %S" data))
  ;; Validate time format compliance (Emacs native format)
  (when-let ((created-at (plist-get data :created-at)))
    (unless (and (listp created-at) (= (length created-at) 4))
      (error "Node :created-at must use Emacs time format, got: %S" created-at)))
  (when-let ((modified-at (plist-get data :modified-at)))
    (unless (and (listp modified-at) (= (length modified-at) 4))
      (error "Node :modified-at must use Emacs time format, got: %S" modified-at)))
  ;; Validate file path if present
  (when-let ((file (plist-get data :file)))
    (unless (stringp file)
      (error "Node :file must be a string, got: %S" file))))

;;; Entity operations

(defun supertag-node-create (props)
  "Create a new node using the unified commit system.
PROPS is a plist of node properties.
Returns the created node data."
  (let* ((id (or (plist-get props :id) (supertag-node-identity-new)))
         ;; Build final props with required fields
         (final-props (plist-put props :id id))
         (final-props (plist-put final-props :type :node))
         (final-props (plist-put final-props :created-at
                                 (or (plist-get final-props :created-at) (supertag-current-time))))
         (final-props (plist-put final-props :modified-at (supertag-current-time))))


    ;; Use unified commit system
    (supertag-ops-commit
     :operation :create
     :collection :nodes
     :id id
     :previous nil
     :new final-props
     :perform (lambda ()
                (supertag-store-put-entity :nodes id final-props)
                final-props))))

(defun supertag-node-get (id)
  "Get node data.
ID is the unique identifier of the node.
Returns node data, or nil if it does not exist."
  (supertag-store-get-entity :nodes id))

(defun supertag-node-update (id updater)
  "Update node data using the unified commit system.
ID is the unique identifier of the node.
UPDATER is a function that receives the current node data and returns the updated data.
Returns the updated node data."
  (let ((previous (supertag-node-get id)))
    (when previous
      (supertag-ops-commit
       :operation :update
       :collection :nodes
       :id id
       :previous previous
       :perform (lambda ()
                  (let* ((updated-node (funcall updater previous)))
                    (when updated-node
                      (let* ((final-node (plist-put updated-node :modified-at (supertag-current-time)))
                             (final-node (plist-put final-node :type (or (plist-get updated-node :type) (plist-get previous :type)))))
                        (supertag--validate-node-data final-node)
                        (supertag-store-put-entity :nodes id final-node)
                        final-node))))))))

(defun supertag-node-delete (node-id)
  "Delete a node and all of its relationships from the store.
This operation is atomic and ensures no dangling references remain."
  (when node-id
    (let ((previous (supertag-node-get node-id)))
      (when previous
        (supertag-with-transaction
          (supertag-ops-commit
           :operation :delete
           :collection :nodes
           :id node-id
           :previous previous
           :perform (lambda ()
                      (supertag-relation-delete-for-node node-id)
                      (supertag-store-remove-entity :nodes node-id)
                      nil)))))))

;;; Current-buffer navigation and location

(defun supertag-node--goto-location (node-id)
  "Position point at the location of NODE-ID in the current buffer.
Assumes the file for NODE-ID has already been made current.  For a
file-level node (:level 0) point stays at the top of the file; for
heading nodes point is moved to the containing heading.
Returns t on success, nil if the ID could not be found."
  (if (supertag-node-location-goto-current-buffer node-id)
      (progn
        (when (fboundp 'org-show-context)
          (org-show-context))
        t)
    (message "Error: Could not find ID %s in current buffer" node-id)
    nil))

(defun supertag-node-set-location (node-id new-file new-position)
 "Update the file path and position for a node in the store.
This is used when a node is moved from one file to another."
 (when-let ((node (supertag-node-get node-id)))
   (supertag-node-update node-id
     (lambda (n)
       (let* ((p-node (plist-put n :file new-file))
              (p-node (plist-put p-node :position new-position)))
         p-node)))))


;;; Shared location and on-demand projection

(defun supertag-ui--get-containing-node-at-point ()
  "Get the node ID of the containing node, whether at heading or in content.
Works when point is at a heading, within the content of a node, or at the
file-level before any heading."
  (save-excursion
    (cond
     ((org-at-heading-p)
      (supertag-node-identity-ensure-at-point))
     ((org-before-first-heading-p)
      (supertag-ui--get-file-node-at-point))
     ((org-back-to-heading t)
      (supertag-node-identity-ensure-at-point))
     (t
      (supertag-ui--get-file-node-at-point)))))

(defun supertag-ui--ensure-node-synced (node-id)
  "Ensure NODE-ID exists in the store by syncing the heading if necessary."
  (when node-id
    (unless (supertag-node-get node-id)
      (when-let ((marker (supertag-ui--find-node-marker node-id)))
        (org-with-point-at marker
          (when (org-at-heading-p)
            (supertag-node-sync-at-point)))))))

(defun supertag-ui--file-node-p (node-id)
  "Return non-nil if NODE-ID is a file node (level 0)."
  (when-let ((node (supertag-node-get node-id)))
    (eq (plist-get node :level) 0)))

(defun supertag-ui--get-file-node-at-point ()
  "Return the persistent file node ID for the current buffer."
  (let ((file (buffer-file-name)))
    (unless file
      (user-error "Point must be inside an Org heading or a file-level context."))
    (or (car (supertag-find-file-node file))
        (progn
          (supertag-ui--ensure-file-node-synced file)
          (car (supertag-find-file-node file)))
        (user-error
         "No file node for %s; add the identity required by `supertag-file-id-source'"
         file))))

(defun supertag-ui--ensure-file-node-synced (file)
  "Sync FILE's file node when it has a configured persistent identity."
  (if (and (fboundp 'supertag-sync--process-single-file)
           (fboundp 'supertag-sync--in-scope-path-p)
           (supertag-sync--in-scope-path-p file))
      (let ((counters '(:nodes-created 0 :nodes-updated 0 :nodes-deleted 0
                        :references-created 0 :references-deleted 0)))
        (supertag-with-transaction
          (supertag-sync--process-single-file file counters))
        (when (> (+ (plist-get counters :nodes-created)
                    (plist-get counters :nodes-updated)
                    (plist-get counters :nodes-deleted))
                 0)
          (when (fboundp 'supertag-sync-update-state)
            (supertag-sync-update-state file))))
    (with-temp-buffer
      (insert-file-contents file)
      (org-mode)
      (let* ((file-header (supertag-sync--parse-file-header))
             (counters '(:nodes-created 0 :nodes-updated 0 :nodes-deleted 0
                         :references-created 0 :references-deleted 0)))
        (supertag-sync--upsert-file-node file file-header counters)))))

(defun supertag-ui--find-node-marker (node-id)
  "Return a marker at NODE-ID's position in its file.
For heading nodes, use the Store-first node location boundary.
For file nodes, positions after file-level metadata (keywords + :PROPERTIES:)."
  (if (supertag-ui--file-node-p node-id)
      (when-let* ((node (supertag-node-get node-id))
                  (file (plist-get node :file))
                  ((file-exists-p file)))
        (with-current-buffer (find-file-noselect file)
          (save-excursion
            (org-with-wide-buffer
             (goto-char (point-min))
             ;; Skip #+KEYWORD: lines
             (while (looking-at "#\\+\\w+:")
               (forward-line 1))
             ;; Skip optional top-level :PROPERTIES: drawer
             (when (looking-at "\\s-*:PROPERTIES:")
               (re-search-forward "^\\s-*:END:" nil t)
               (forward-line 1))
             ;; Skip trailing blank lines
             (while (and (not (eobp)) (looking-at "\\s-*$"))
               (forward-line 1))
             (point-marker)))))
    (supertag-node-location-find node-id)))

;;; Find candidate state

(defvar supertag-ui--node-cache nil
  "Cache for node selection candidates to improve performance.")

(defvar supertag-ui--cache-timestamp nil
  "Timestamp of when the node cache was last updated.")

;;; Node navigation

(defun supertag-goto-node (node-id &optional other-window)
  "Navigate to the location of NODE-ID based on data in the supertag store.
If OTHER-WINDOW is non-nil, open in another window."
  (let* ((node (supertag-view-api-get-entity :nodes node-id))
         (file (and node (plist-get node :file))))
    (unless node
      (user-error "Node %s is not present in the Supertag projection" node-id))
    (unless file
      (user-error "Node %s has no source file in the Supertag projection" node-id))
    (if (not (file-exists-p file))
        (message "Error: File for node %s does not exist or is not set." node-id)
      (let ((buffer (find-file-noselect file)))
        (if other-window
            (pop-to-buffer buffer)
          (switch-to-buffer buffer))
        (with-current-buffer buffer
          (if (supertag-node--goto-location node-id)
              (message "Jumped to node: %s" (or (plist-get node :raw-value)
                                                 (plist-get node :title)))
            (message "Error: Could not find ID %s in file %s" node-id file)))))))

;;; Candidate reading and formatting

(defun supertag-ui--clear-node-cache ()
  "Clear the node selection cache to force refresh on next access."
  (setq supertag-ui--node-cache nil
        supertag-ui--cache-timestamp nil))

(defun supertag-ui--get-cached-nodes ()
  "Get cached node candidates, refreshing if necessary."
  (let ((current-time (current-time)))
    ;; Refresh cache if it's older than 30 seconds or doesn't exist
    (when (or (null supertag-ui--cache-timestamp)
              (null supertag-ui--node-cache)
              (time-less-p (time-add supertag-ui--cache-timestamp 30) current-time))
      (message "Refreshing node cache...")
      (setq supertag-ui--node-cache (supertag-ui--build-node-candidates)
            supertag-ui--cache-timestamp current-time)
      (message "Node cache refreshed. Found %d nodes." (length supertag-ui--node-cache)))
    supertag-ui--node-cache))

(defun supertag-ui--build-node-candidates ()
  "Build the node candidates list efficiently."
  (let ((candidates
         (mapcar
          (lambda (pair)
            (let ((id (car pair))
                  (node-data (cdr pair)))
              (cons (supertag-ui--format-node-display node-data) id)))
          (supertag-query-nodes (lambda (_id data) data)))))
    (sort candidates (lambda (a b) (string< (car a) (car b))))))

(defun supertag-ui--format-node-display (node-data)
  "Return a human-readable display string for NODE-DATA.
File nodes (level 0) get a \"📄 \" prefix and fall back to filename when untitled."
  (let* ((is-file-node (eq (plist-get node-data :level) 0))
         (raw-title (or (plist-get node-data :raw-value)
                        (plist-get node-data :title)))
         (file (plist-get node-data :file))
         (title (or raw-title
                    (and is-file-node file (file-name-nondirectory file))
                    "Untitled"))
         (olp (plist-get node-data :olp))
         (display-path (if (and (listp olp) (> (length olp) 1))
                           (concat (string-join (butlast olp) " / ") " / " title)
                         title))
         (prefix (if is-file-node "📄 " "")))
    (format "%s%s%s" prefix display-path
            (if file
                (format "  (in %s)" (file-name-nondirectory file))
              "  [orphaned]"))))

(defun supertag-ui-format-node-display (node-data)
  "Return the public human-readable display string for NODE-DATA."
  (supertag-ui--format-node-display node-data))

;;; Find preview and context recovery

(defun supertag-ui--capture-find-context ()
  "Capture the observable editor context surrounding a Find operation."
  (list
   :window-configuration (current-window-configuration)
   :window-histories
   (mapcar (lambda (window)
             (list window
                   (copy-tree (window-prev-buffers window))
                   (copy-sequence (window-next-buffers window))))
           (window-list nil 'no-minibuffer))
   :source-window (selected-window)
   :source-window-start (window-start)
   :source-window-hscroll (window-hscroll)
   :source-buffer (current-buffer)
   :source-point (point)
   :source-mark (mark t)
   :source-mark-active mark-active
   :source-min (point-min)
   :source-max (point-max)))

(defun supertag-ui--restore-find-context (context)
  "Restore an editor CONTEXT captured by `supertag-ui--capture-find-context'."
  (set-window-configuration (plist-get context :window-configuration))
  (dolist (history (plist-get context :window-histories))
    (when (window-live-p (car history))
      (set-window-prev-buffers (car history) (nth 1 history))
      (set-window-next-buffers (car history) (nth 2 history))))
  (let ((source-buffer (plist-get context :source-buffer))
        (source-window (plist-get context :source-window)))
    (when (buffer-live-p source-buffer)
      (set-buffer source-buffer)
      (widen)
      (narrow-to-region (plist-get context :source-min)
                        (plist-get context :source-max))
      (goto-char (min (plist-get context :source-point) (point-max)))
      (if-let* ((source-mark (plist-get context :source-mark)))
          (set-mark source-mark)
        (set-marker (mark-marker) nil))
      (setq mark-active (plist-get context :source-mark-active))
      (when (window-live-p source-window)
        (set-window-start source-window
                          (plist-get context :source-window-start) t)
        (set-window-hscroll source-window
                            (plist-get context :source-window-hscroll))))))

(defmacro supertag-ui--with-find-preview-context (&rest body)
  "Run BODY and restore the caller context used by Find previews."
  (declare (indent 0) (debug t))
  `(let ((find-context (supertag-ui--capture-find-context)))
     (unwind-protect
         (progn ,@body)
       (supertag-ui--restore-find-context find-context))))

(defun supertag-ui--find-existing-matches-p (input candidates)
  "Return non-nil when INPUT matches one or more existing CANDIDATES."
  (and (not (string-empty-p input))
       (completion-all-completions input candidates nil (length input))))

(defun supertag-ui--find-create-label-title (string)
  "Return the requested title when STRING is an exact Find Create label."
  (when (and (stringp string)
             (string-match "\\`\\(.*\\)  \\[Create new node\\]\\'" string))
    (string-trim (match-string 1 string))))

(defun supertag-ui--find-completion-table (candidates)
  "Return a completion table for existing CANDIDATES and explicit creation."
  (lambda (string predicate action)
    (let* ((label-title (supertag-ui--find-create-label-title string))
           (title (or label-title (string-trim string)))
           (create
            (unless (or (string-empty-p title)
                        (supertag-ui--find-existing-matches-p title candidates))
              (list (propertize
                     (format "%s  [Create new node]" title)
                     'supertag-find-create-title title))))
           (choices (append candidates create)))
      (cond
       ((eq (car-safe action) 'boundaries) nil)
       ((eq action 'metadata)
        '(metadata (category . supertag-find-node)
                   (cycle-sort-function . identity)))
       ((eq action t)
        (complete-with-action t choices string predicate))
       ((eq action 'lambda)
        ;; Typing unmatched text is not itself authorization to create.
        (if label-title
            (and create (member string create) t)
          (test-completion string candidates predicate)))
       ((null action)
        (or (try-completion string choices predicate) string))
       (t (complete-with-action action choices string predicate))))))

(defun supertag-ui--find-choice-value (selected candidates)
  "Convert SELECTED from CANDIDATES into a tagged Find result."
  (when selected
    (if-let* ((node-id (cdr (assoc selected candidates))))
        (list :existing node-id)
      (let ((title (or (get-text-property
                        0 'supertag-find-create-title selected)
                       (supertag-ui--find-create-label-title selected))))
        (unless (and title
                     (not (string-empty-p (string-trim title)))
                     (not (supertag-ui--find-existing-matches-p
                           title candidates)))
          (user-error "Select an existing node or the explicit Create action"))
        (list :create (string-trim title))))))

(defun supertag-ui-read-find-node (prompt &optional with-preview)
  "Read an existing node or an explicit creation request using PROMPT.
Return `(:existing ID)', `(:create TITLE)' or nil.  WITH-PREVIEW previews only
  existing nodes in another window and restores the caller context before return."
  (let* ((candidates (supertag-ui--build-node-candidates))
         (table (supertag-ui--find-completion-table candidates))
         selection)
    ;; Find creation authorization must never depend on a stale TTL snapshot.
    (setq supertag-ui--node-cache candidates
          supertag-ui--cache-timestamp (current-time))
    (supertag-ui--with-find-preview-context
      (let ((preview
             (lambda (text)
               (when-let* ((id (cdr (assoc text candidates))))
                 (supertag-goto-node id t)))))
        (cond
         ((and with-preview (bound-and-true-p ivy-mode) (fboundp 'ivy-read))
          (setq selection
                (ivy-read prompt table :require-match t
                          :update-fn
                          (lambda () (funcall preview (ivy-current-match)))
                          :caller 'supertag-ui-read-find-node)))
         ((and with-preview (bound-and-true-p vertico-mode))
          (let ((preview-hook
                 (lambda ()
                   (funcall preview (vertico-current-candidate)))))
            (unwind-protect
                (progn
                  (add-hook 'vertico-selection-hook preview-hook)
                  (setq selection (completing-read prompt table nil t)))
              (remove-hook 'vertico-selection-hook preview-hook))))
         (t
          (setq selection (completing-read prompt table nil t))))))
    (supertag-ui--find-choice-value selection candidates)))

;;; Shared navigation recovery

(defun supertag-ui-navigate-with-recovery (node-id &optional other-window)
  "Navigate to NODE-ID, restoring the caller context if navigation fails.
OTHER-WINDOW has the same meaning as in `supertag-goto-node'.  Return that
function's native result unchanged."
  (let ((context (supertag-ui--capture-find-context))
        result location success)
    (unwind-protect
        (condition-case cause
            (progn
              (setq result (supertag-goto-node node-id other-window)
                    location (supertag-node-location-find node-id)
                    success
                    (and location
                         (eq (current-buffer) (marker-buffer location))
                         (save-excursion
                           (supertag-node-location-goto-current-buffer node-id))))
              (unless success
                (supertag-ui--restore-find-context context))
              result)
          ((error quit)
           (supertag-ui--restore-find-context context)
           (signal (car cause) (cdr cause))))
      (when (markerp location)
        (set-marker location nil)))))

(defun supertag-ui-find-navigate (node-id &optional other-window)
  "Navigate to NODE-ID for Find through the shared recovery boundary."
  (supertag-ui-navigate-with-recovery node-id other-window))

;;; Candidate lifecycle

(defun supertag-ui--invalidate-cache-on-change (path _old-value _new-value)
  "Invalidate UI cache when node data changes."
  (when (and path (eq (car path) :nodes))
    (supertag-ui--clear-node-cache)))

(defvar supertag-node--cache-listener-prepared nil
  "Non-nil after successful cache listener preparation, including absent provider.")

(defun supertag-node--prepare-cache-listener (&optional reload)
  "Prepare Node cache invalidation once, or again when RELOAD is non-nil.
The optional `supertag-register-listener' provider is an availability seam,
not the native Store notifier.  An error or quit preserves the prior state."
  (unless (and supertag-node--cache-listener-prepared (not reload))
    (when (fboundp 'supertag-register-listener)
      (supertag-register-listener :store-changed #'supertag-ui--invalidate-cache-on-change))
    (setq supertag-node--cache-listener-prepared t)))

(defun supertag-ui--reset-runtime ()
  "Clear UI candidate state when switching vaults."
  (supertag-ui--clear-node-cache))

;;; Find command

(defun supertag-find-node (&optional other-window)
  "Find an existing node or explicitly create one from a template.
By default open the result in the current window.  With prefix argument
OTHER-WINDOW, preview and open existing nodes in another window.  Creation is
offered only as an explicit completion action and never changes source text."
  (interactive "P")
  (let* ((prompt
          (if other-window
              "Find node (other window; without C-u: current window): "
            "Find node (current window; C-u: preview/open other window): "))
         (choice (supertag-ui-read-find-node prompt other-window)))
    (when choice
      (let ((node-id
             (pcase (car choice)
               (:existing (cadr choice))
               (:create
                (let* ((template
                        (supertag-template-normalize
                         (supertag-template-read)))
                       (title (cadr choice)))
                  (supertag-service-org-create-node
                   (plist-get template :target-file)
                   title
                   (plist-get template :tags)
                   (list :properties (plist-get template :properties)
                         :body (plist-get template :body)
                         :create-file t))))
               (_ (user-error "Invalid Find node selection")))))
        (supertag-ui-find-navigate node-id other-window)))))

;;; Node position selection

(defun supertag-ui--safe-current-insert-position (position)
  "Return a safe Org headline insertion point at or after POSITION.
When POSITION is already on a heading, keep that heading boundary.  Inside a
subtree, move to its end so a new sibling cannot split existing prose.  In the
file preamble, use the next heading boundary or the end of the file."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char position)
      (cond
       ((org-at-heading-p)
        (list :position (line-beginning-position)
              :level (org-outline-level)))
       ((org-before-first-heading-p)
        (let ((next-heading
               (save-excursion
                 (when (re-search-forward org-heading-regexp nil t)
                   (line-beginning-position)))))
          (list :position (or next-heading (point-max)) :level 1)))
       (t
        (org-back-to-heading t)
        (let ((level (org-outline-level)))
          (org-end-of-subtree t t)
          (list :position (point) :level level)))))))

(defun supertag-ui-select-insert-position (file &optional suggested-position)
  "Interactively let user select an insert position in FILE.
SUGGESTED-POSITION, when valid in FILE, makes the current point the default.
Without it, file end is the default.  Returns (:position POS :level LVL)."
  (unless file
    (user-error "FILE parameter cannot be nil"))
  (unless (file-exists-p file)
    (user-error "File does not exist: %s" file))
  (with-current-buffer (find-file-noselect file)
    (let* ((suggested
            (cond
             ((and (markerp suggested-position)
                   (eq (marker-buffer suggested-position) (current-buffer)))
              (marker-position suggested-position))
             ((and (integerp suggested-position)
                   (<= (point-min) suggested-position)
                   (<= suggested-position (point-max)))
              suggested-position)))
           (headlines (org-map-entries
                       #'(lambda ()
                           (list (org-get-heading t t) (point) (org-outline-level)))
                       t 'file))
           (options (append (when suggested '("Current Position"))
                            '("File Top" "File End"
                              "Under Heading..." "After Heading...")))
           (default (if suggested "Current Position" "File End"))
           (choice (completing-read
                    "Insert position: " options nil t nil nil default)))
      (cond
       ((string= choice "Current Position")
        (supertag-ui--safe-current-insert-position suggested))
       ((string= choice "File Top")
        (list :position (point-min) :level 1))
       ((string= choice "File End")
        (list :position (point-max) :level 1))
       ((or (string= choice "Under Heading...") (string= choice "After Heading..."))
        (let* ((headline-titles (mapcar #'car headlines))
               (selected-title (completing-read "Select target heading: " headline-titles nil t))
               (headline-info (assoc selected-title headlines)))
          (when headline-info
            (let* ((pos (nth 1 headline-info))
                   (level (nth 2 headline-info)))
              (goto-char pos)
              (if (string= choice "Under Heading...")
                  (list :position (save-excursion (org-end-of-subtree t) (point))
                        :level (1+ level))
                ;; After Heading...
                (list :position (save-excursion (org-end-of-subtree t t) (point))
                      :level level))))))
       (t nil)))))

;;; Move source collection and context

(defun supertag-ui--move-roots-in-region (beg end)
  "Collect live root heading markers starting in [BEG, END), without edits.
Include folded headings and ID-less roots; descendants of an included root
are carried with it, not selected again.  This is separate from batch tagging."
  (save-excursion
    (save-restriction
      (widen)
      (let (roots covered-end)
        (org-element-map (org-element-parse-buffer) 'headline
          (lambda (headline)
            (let ((start (org-element-property :begin headline)))
              (when (and (>= start beg) (< start end)
                         (or (not covered-end) (>= start covered-end)))
                (push (copy-marker start) roots)
                (setq covered-end (org-element-property :end headline))))))
        (nreverse roots)))))

(defun supertag-ui--move-select-target (file)
  "Select a position in FILE and return (:position MARKER :level LEVEL).
Preserve the target buffer's point and narrowing, including on cancellation."
  (unless (file-exists-p file)
    (user-error "Target file does not exist: %s" file))
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (save-restriction
        (widen)
        (let* ((selection (supertag-ui-select-insert-position file))
               (position (plist-get selection :position)))
          (unless (and selection (integer-or-marker-p position)
                       (or (not (markerp position))
                           (eq (marker-buffer position) (current-buffer)))
                       (<= (point-min) position) (<= position (point-max)))
            (user-error "No valid insert position selected"))
          (list :position (copy-marker position)
                :level (plist-get selection :level)))))))

(defun supertag-ui--move-source-context ()
  "Record numeric source context and complete text before a Move attempt."
  (let ((buffer (current-buffer))
        (minimum (point-min))
        (maximum (point-max))
        (position (point))
        (mark-position (mark t))
        (active mark-active))
    (save-restriction
      (widen)
      (list :buffer buffer :text (buffer-substring (point-min) (point-max))
            :minimum minimum :maximum maximum :point position
            :mark mark-position :mark-active active))))

(defun supertag-ui--move-restore-source-context (context)
  "Restore numeric CONTEXT only when Move restored the complete source text."
  (let ((buffer (plist-get context :buffer)))
    (when (and (buffer-live-p buffer)
               (with-current-buffer buffer
                 (save-restriction
                   (widen)
                   (equal (plist-get context :text)
                          (buffer-substring (point-min) (point-max))))))
      (with-current-buffer buffer
        (widen)
        (narrow-to-region (plist-get context :minimum)
                          (plist-get context :maximum))
        (goto-char (plist-get context :point))
        (let ((position (plist-get context :mark)))
          (if position
              (set-mark position)
            (set-marker (mark-marker) nil)))
        (setq mark-active (plist-get context :mark-active))))))

;;; Move interaction

(defun supertag-ui--move (beg end leave-link)
  "Prompt once and delegate a bounded move of BEG..END or the current node.
LEAVE-LINK requests a replacement link.  Only the shared Org service writes."
  (let ((source-context (supertag-ui--move-source-context)))
    (condition-case err
        (save-window-excursion
          (save-mark-and-excursion
            (save-restriction
              (let (sources target-marker)
                (unwind-protect
                    (progn
                      (setq sources
                            (if (and beg end)
                                (supertag-ui--move-roots-in-region beg end)
                              (unless (org-at-heading-p)
                                (user-error "Point must be at a heading to move a node."))
                              (let ((id (org-id-get)))
                                (unless id
                                  (user-error "Current heading does not have an ID, it is not a node."))
                                (list id))))
                      (unless sources (user-error "No nodes found to move."))
                      (let* ((target-file (expand-file-name (read-file-name "Move node(s) to file: ")))
                             (selection (supertag-ui--move-select-target target-file)))
                        (setq target-marker (plist-get selection :position))
                        (when (yes-or-no-p
                               (format "Move %d node(s) to %s%s? All unsaved changes in affected files will be saved. "
                                       (length sources) (file-name-nondirectory target-file)
                                       (if leave-link " and leave a link" "")))
                          (let ((moved (supertag-service-org-move-nodes
                                        sources target-file target-marker
                                        (plist-get selection :level) leave-link)))
                            (message "%d node(s) successfully moved to %s."
                                     (length moved) (file-name-nondirectory target-file))
                            moved))))
                  (when (markerp target-marker) (set-marker target-marker nil))
                  (dolist (source sources)
                    (when (markerp source) (set-marker source nil))))))))
      ((error quit)
       (supertag-ui--move-restore-source-context source-context)
       (signal (car err) (cdr err))))))

(defun supertag-move-node (&optional beg end)
  "Move the current identified heading, or root headings in BEG..END.
Choose any target file and insertion position, including in the source file.
Region selection includes folded and ID-less headings.  Identities are only
created by the service after confirmation.  Stay in the original context."
  (interactive
   (when (use-region-p) (list (region-beginning) (region-end))))
  (supertag-ui--move beg end nil))

(defun supertag-move-node-and-link ()
  "Move the current identified heading and leave a link at its old location.
Choose the target position without refile configuration; stay in source context."
  (interactive)
  (supertag-ui--move nil nil t))

;;; Standard org-capture integration

(defgroup supertag-capture nil
  "Capture-related configuration and integration for Supertag."
  :group 'supertag)

(defun supertag-capture-finalize-node-at-point (&optional field-specs explicit-node-id)
  "Finalize current Org headline as a Supertag node.

Ensures the node has a stable ID, syncs it into the Supertag store,
and applies FIELD-SPECS as tags and Org properties.

FIELD-SPECS is a list of plists like:
  (:tag TAG-ID :property PROPERTY-NAME :value VALUE)
Legacy :field is accepted as an alias for :property.

When EXPLICIT-NODE-ID is non-nil, it is enforced as the node ID."
  (let (tags properties)
    ;; Validate every spec before creating identity or mutating Org/Store.
    (dolist (spec field-specs)
      (when (plist-member spec :tag)
        (let ((tag (plist-get spec :tag)))
          (unless (and (stringp tag) (not (string-empty-p tag)))
            (user-error "Capture Tag must be a non-empty string"))
          (push tag tags)))
      (when (or (plist-member spec :property) (plist-member spec :field))
        (let ((name (or (plist-get spec :property) (plist-get spec :field))))
          (unless (and (stringp name) (not (string-empty-p name)))
            (user-error "Capture property must have a non-empty name"))
          (let ((key (replace-regexp-in-string "[[:space:]:]" "_" (upcase name))))
            (when (or (equal key "ID") (member key org-special-properties))
              (user-error "Capture cannot set reserved property %s" key))
            (push (cons key (format "%s" (or (plist-get spec :value) "")))
                  properties)))))
    (unless (org-before-first-heading-p)
      (save-excursion
        (org-back-to-heading t)
        (let ((node-id
               (supertag-node-identity-ensure-at-point explicit-node-id)))
          (dolist (property (nreverse properties))
            (org-entry-put nil (car property) (cdr property)))
          (supertag-node-sync-at-point)
          (when tags
            (supertag-capture-add-tags-to-nodes
             (list node-id) (delete-dups (nreverse tags))))
          node-id)))))

(defcustom supertag-org-capture-auto-enable nil
  "When non-nil, enable Supertag integration with `org-capture'.

This is a convenience toggle.  You can also call
`supertag-enable-org-capture-integration' and
`supertag-disable-org-capture-integration' manually."
  :type 'boolean
  :group 'supertag-capture)

(defun supertag-org-capture-after-finalize ()
  "Attach Supertag metadata for org-capture entries that opt in.

Templates can opt in by adding `:supertag t' to their entry in
`org-capture-templates'.  Optional `:supertag-template' can be a
list of plists of the form:

  (:tag TAG-ID :property PROPERTY-NAME :value VALUE)
Legacy :field is accepted as an alias for :property.

Tags are added and property keys uppercased, with whitespace/colons
replaced by underscores, before projecting the current heading.

Additionally, templates can request a follow-up move using
`supertag-move-node' or `supertag-move-node-and-link' by setting
`:supertag-move' in the template plist:

- :supertag-move t                ; use `supertag-move-node'
- :supertag-move 'node            ; same as t
- :supertag-move 'link            ; use `supertag-move-node-and-link'
- :supertag-move 'within-target   ; move within the capture target file only

You can also enable an interactive Supertag tag prompt after
capture by setting `:supertag-tags-prompt' to non-nil in the
template plist.  This uses the existing Supertag tag completion source."
  (when (and (boundp 'org-capture-plist)
             (plist-get org-capture-plist :supertag))
    (let* ((marker (and (boundp 'org-capture-last-stored-marker)
                        org-capture-last-stored-marker))
           (field-specs (plist-get org-capture-plist :supertag-template))
           (move-spec (plist-get org-capture-plist :supertag-move))
           (tags-prompt (plist-get org-capture-plist :supertag-tags-prompt)))
      (when (markerp marker)
        (with-current-buffer (marker-buffer marker)
          (when (buffer-live-p (current-buffer))
            (goto-char marker)
            (progn
              (let ((node-id (supertag-capture-finalize-node-at-point field-specs)))
                ;; Optional tags prompt using Supertag tag completion
                (when (and tags-prompt node-id)
                  (let* ((chosen
                          (supertag-capture--get-from-tags-prompt
                           (list "Supertag tags (comma separated): ")))
                         (unique-tags
                          (cl-delete-duplicates chosen :test #'string=)))
                    (dolist (tag unique-tags)
                      (supertag-capture-add-tag-to-nodes
                       (list node-id) tag))))
                  (when move-spec
                    (let* ((raw-move move-spec)
                           ;; Normalize move-spec:
                           ;; - (quote foo) -> foo
                           ;; - \"link\" / \"within-target\" -> symbol
                           ;; - symbols remain unchanged
                           (normalized
                            (cond
                             ((and (consp raw-move) (eq (car raw-move) 'quote))
                              (cadr raw-move))
                             ((stringp raw-move)
                              (intern (downcase raw-move)))
                             (t raw-move))))
                      (pcase normalized
                        ;; Move within the current capture target file:
                        ;; re-use `supertag-move-node' but skip the file prompt.
                        ((or 'within-target :within-target)
                         (let ((current-file (buffer-file-name)))
                           (when (and current-file (fboundp 'supertag-move-node))
                             (cl-letf (((symbol-function 'read-file-name)
                                        (lambda (&rest _ignore) current-file)))
                               (call-interactively #'supertag-move-node)))))
                        ;; Move to another file and leave a link behind
                        ((or 'link :link)
                         (when (fboundp 'supertag-move-node-and-link)
                           (call-interactively #'supertag-move-node-and-link)))
                        ;; Default: full `supertag-move-node' UI (file + position)
                        (_
                         (when (fboundp 'supertag-move-node)
                           (call-interactively #'supertag-move-node))))))
              (message "[supertag] org-capture integration: node finalized%s"
                       (if move-spec " and moved" ""))))))))))

(defun supertag-enable-org-capture-integration ()
  "Enable Supertag integration with `org-capture'."
  (add-hook 'org-capture-after-finalize-hook
            #'supertag-org-capture-after-finalize)
  (setq supertag-org-capture-auto-enable t)
  (message "[supertag] org-capture integration enabled"))

(defun supertag-disable-org-capture-integration ()
  "Disable Supertag integration with `org-capture'."
  (remove-hook 'org-capture-after-finalize-hook
               #'supertag-org-capture-after-finalize)
  (setq supertag-org-capture-auto-enable nil)
  (message "[supertag] org-capture integration disabled"))

;;; Generic node selection

(defvar supertag-ui--select-node-candidates nil
  "A list of node candidates used by `supertag-ui-select-node`.
For completion framework integration, e.g., live previews.")

(defun supertag-ui-select-node (&optional prompt use-cache with-preview initial)
  "Interactively prompt user to select a node.
PROMPT is the prompt string (defaults to 'Select node: ').
USE-CACHE when non-nil uses cached data for better performance.
WITH-PREVIEW when non-nil enables live preview in another window
if a supported completion framework (Ivy, Vertico) is active.
INITIAL is an existing node ID offered as the completion default.
Returns the selected node's ID, or nil."
  (let* ((prompt-str (or prompt "Select node: "))
         (candidates (if use-cache
                         (supertag-ui--get-cached-nodes)
                       (supertag-ui--build-node-candidates)))
         (default-display (and initial (car (rassoc initial candidates))))
         (supertag-ui--select-node-candidates candidates)) ; For external hooks
    (if (not (and with-preview candidates))
        (let ((selected (completing-read
                         prompt-str candidates nil t nil nil default-display)))
          (when selected (cdr (assoc selected candidates))))
      (let ((preview-func (lambda (id) (when id (supertag-goto-node id t)))))
        (cond
         ((and (bound-and-true-p ivy-mode) (fboundp 'ivy-read))
          (let* ((ivy-update-fn
                  (lambda (_)
                    (let* ((sel (ivy-current-match))
                           (id (cdr (assoc sel candidates))))
                      (funcall preview-func id))))
                 (selection (ivy-read prompt-str (mapcar #'car candidates)
                                      :require-match t
                                      :preselect default-display
                                      :history 'supertag-ui-select-node-history
                                      :caller 'supertag-ui-select-node)))
            (when selection (cdr (assoc selection candidates)))))
         ((bound-and-true-p vertico-mode)
          (let ((selection nil)
                (preview-hook
                 (lambda ()
                   (let* ((sel (vertico-current-candidate))
                          (id (cdr (assoc sel candidates))))
                     (funcall preview-func id)))))
            (unwind-protect
                (progn
                  (add-hook 'vertico-selection-hook preview-hook)
                  (setq selection (completing-read
                                   prompt-str candidates nil t nil nil
                                   default-display)))
              (remove-hook 'vertico-selection-hook preview-hook))
            (when selection (cdr (assoc selection candidates)))))
          (t
           (message "Live preview supported with Ivy or Vertico. Falling back to default.")
           (let ((selected (completing-read
                            prompt-str candidates nil t nil nil default-display)))
             (when selected (cdr (assoc selected candidates))))))))))

(defun supertag-ui-select-multiple-nodes (&optional prompt use-cache initial with-preview)
  "Interactively select zero or more nodes and return their IDs.
PROMPT customizes the base prompt, USE-CACHE mirrors `supertag-ui-select-node'
for candidate retrieval, INITIAL is a pre-selected list (or single ID),
and WITH-PREVIEW is reserved for future live preview support."
  (ignore with-preview)
  (let* ((prompt-base (or prompt "Select nodes"))
         (candidates (if use-cache
                         (supertag-ui--get-cached-nodes)
                       (supertag-ui--build-node-candidates)))
         (id->display (let ((table (make-hash-table :test 'equal)))
                        (dolist (pair candidates table)
                          (puthash (cdr pair) (car pair) table))
                        table))
         (selection (copy-sequence (cond ((null initial) nil) ((stringp initial) (list initial)) ((listp initial) initial)))))
    (cl-labels ((format-id (id)
                           (or (gethash id id->display) id))
                (refresh-candidates ()
                  (when use-cache
                    (supertag-ui--clear-node-cache))
                  (setq candidates (if use-cache
                                       (supertag-ui--get-cached-nodes)
                                     (supertag-ui--build-node-candidates)))
                  (setq id->display (let ((table (make-hash-table :test 'equal)))
                                      (dolist (pair candidates table)
                                        (puthash (cdr pair) (car pair) table))
                                      table)))
                (selection-summary ()
                                    (if selection
                                        (string-join (mapcar #'format-id selection) ", ")
                                      "none")))
      (catch 'done
        (while t
          (let* ((actions (append '("Add node..." "Create node...")
                                  (when selection '("Remove node..."))
                                  '("Done")))
                 (action (completing-read
                          (format "%s [%s]" prompt-base (selection-summary))
                          actions nil t nil nil "Done")))
            (pcase action
              ("Done"
               (throw 'done (copy-sequence selection)))
              ("Add node..."
               (let* ((available (cl-remove-if
                                  (lambda (pair) (member (cdr pair) selection))
                                  candidates)))
                 (if (null available)
                     (message "All nodes are already selected")
                   (let* ((choice (completing-read "Add node: "
                                                   (mapcar #'car available) nil t))
                          (match (assoc choice candidates)))
                     (when match
                       (let ((node-id (cdr match)))
                         (unless (member node-id selection)
                           (setq selection (append selection (list node-id))))))))))
              ("Create node..."
               (condition-case err
                   (let ((new-node-id (supertag-node-reference-and-create)))
                     (when new-node-id
                       (refresh-candidates)
                       (let* ((node-data (supertag-node-get new-node-id))
                              (display (and node-data (supertag-ui--format-node-display node-data))))
                         (when display
                           (puthash new-node-id display id->display)))
                       (unless (member new-node-id selection)
                         (setq selection (append selection (list new-node-id))))))
                 (quit (signal 'quit nil))
                 (error (message "%s" (error-message-string err)))))
              ("Remove node..."
               (if (null selection)
                   (message "No nodes to remove")
                 (let* ((choices (mapcar (lambda (id)
                                            (cons (format-id id) id))
                                          selection))
                        (choice (completing-read "Remove node: "
                                                 (mapcar #'car choices) nil t))
                        (match (assoc choice choices)))
                   (when match
                     (setq selection (delete (cdr match) selection))))))
              (_ (user-error "Unsupported action: %s" action)))))))))

;;; Reference creation

(defun supertag-node-reference-and-create ()
  "Create a new node for use in node-reference fields and return its ID.
Prompts for a title, destination file, and insert position."
  (let* ((title-input (read-string "New node title: "))
         (title (string-trim title-input)))
    (when (string-empty-p title)
      (user-error "Node title cannot be empty"))
    (let* ((target-file (read-file-name "Store node in file: " nil nil t))
           (insert-info (supertag-ui-select-insert-position target-file)))
      (unless insert-info
        (user-error "No valid insert position selected"))
      (let* ((insert-pos (plist-get insert-info :position))
             (insert-level (max 1 (or (plist-get insert-info :level) 1)))
             (node-id (supertag-node-identity-new)))
        (with-current-buffer (find-file-noselect target-file)
          (org-with-wide-buffer
           (goto-char insert-pos)
           (unless (bolp)
             (insert "\n"))
           (let ((heading-start (point)))
             (insert (format "%s %s\n\n"
                             (make-string insert-level ?*) title))
             (goto-char heading-start)
             (supertag-node-identity-ensure-at-point node-id)
             (supertag-node-sync-at-point))
           (save-buffer)))
        (supertag-ui--clear-node-cache)
        (message "Node '%s' created." title)
        node-id))))

;;; Containing-node projection

(defun supertag-ui--reproject-containing-node (node-id)
  "Refresh NODE-ID's Document Projection from the current Org buffer."
  (if (supertag-ui--file-node-p node-id)
      (supertag-ui--ensure-file-node-synced (buffer-file-name))
    (save-excursion
      (org-back-to-heading t)
      (supertag-node-sync-at-point))))

;;; Compatibility heading reads and identity

(defun supertag--get-node-props-at-point ()
  "Extract node properties from the current Org heading at point."
  (when (org-at-heading-p)
    (when (fboundp 'org-element-at-point)
      (let ((element (org-element-at-point))
            (file (buffer-file-name)))
        ;; Delegate parsing to the authoritative function in the sync service.
        (supertag--convert-element-to-node-plist element file)))))

(defun supertag-ui--get-node-at-point ()
  "Check if point is at a heading and return the node ID.
Creates an ID if one does not exist. Errors out if not on a heading."
  (unless (org-at-heading-p)
    (user-error "Point must be at an Org heading."))
  (supertag-node-identity-ensure-at-point))

;;; Compatibility heading creation

(defun supertag-ui--create-heading-node (title target-file insert-info)
  "Create TITLE in TARGET-FILE at INSERT-INFO and return its node ID."
  (let* ((insert-pos (plist-get insert-info :position))
         (insert-level (plist-get insert-info :level))
         (node-id (supertag-node-identity-new)))
    (with-current-buffer (find-file-noselect target-file)
      (goto-char insert-pos)
      (unless (or (bobp) (looking-back "\n" 1))
        (insert "\n"))
      (let ((heading-start (point)))
        (insert (format "%s %s\n" (make-string insert-level ?*) title))
        (goto-char heading-start)
        (supertag-node-identity-ensure-at-point node-id))
      (save-buffer))
    (supertag-node-create
     `(:id ,node-id
       :title ,title
       :file ,target-file
       :position ,insert-pos
       :level ,insert-level))
    node-id))

;;; Native heading title

(defun supertag-ui--heading-title-at-point ()
  "Return the plain title of the heading at point, or nil."
  (when (org-at-heading-p)
    (org-get-heading t t t t)))

;;; Node ID navigation and parent title

(defun supertag-service-org-follow-id (node-id)
  "Open NODE-ID using Supertag's node location and a robust `:ID:` search.

Returns non-nil when NODE-ID was handled, nil otherwise."
  (let* ((marker (and (stringp node-id)
                      (supertag-node-location-find node-id)))
         (file (and marker
                    (buffer-file-name (marker-buffer marker)))))
    (when (and (stringp file)
               (file-exists-p file)
               ;; Only apply to files in sync scope.
               (or (not (fboundp 'supertag-sync--in-sync-scope-p))
                   (supertag-sync--in-sync-scope-p file)))
      (let ((buffer (marker-buffer marker)))
        (pop-to-buffer buffer)
        ;; Navigating to a node the user asked for outranks whatever the
        ;; buffer happened to be narrowed to, the same way `org-id-goto' does.
        (widen)
        (goto-char marker)
        (org-show-context)
        (recenter)
        t))))

(defun supertag-service-org--parent-title (node-id)
  "Return the direct parent's title for NODE-ID, or nil.
If NODE-ID is already a top-level heading, return nil."
  (let* ((node-info (supertag-node-get node-id))
         (file-path (plist-get node-info :file))
         (result nil))
    (when (and file-path (file-exists-p file-path))
      (save-window-excursion
        (let ((buffer (find-file-noselect file-path)))
          (with-current-buffer buffer
            (save-excursion
              (unless (supertag-node-location-goto-current-buffer node-id)
                (user-error "Node '%s' was not found in %s" node-id file-path))
              (when (org-at-heading-p)
                (when (org-up-heading-safe)
                  (setq result (org-get-heading t t t t)))))))))
    result))

;;; Projected Node location adapter

(defun supertag-view-helper-find-node-location (node-id)
  "Find the location of a node by its ID.
Returns a cons (POSITION . FILE-PATH) if found, nil otherwise."
  (when node-id
    (when-let* ((node (supertag-view-api-get-entity :nodes node-id)))
      (let ((file-path (plist-get node :file))
            (position (plist-get node :position)))
        (when (and file-path (file-exists-p file-path))
          (cons (or position 1) file-path))))))

(when supertag-org-capture-auto-enable
  (supertag-enable-org-capture-integration))

(provide 'supertag-node)
;;; supertag-node.el ends here
