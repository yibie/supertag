;;; supertag-core-store.el --- Core data storage and atomic update for Supertag -*- lexical-binding: t; -*-

;;; Commentary:
;; This file implements the physical Store for Supertag.  The Store holds
;; Semantic Facts, Document Projections and derived state.  Physical storage does
;; not decide ownership, and the old ownership charter
;; (archive/docs/legacy/OWNERSHIP-CONSTITUTION_cn.md) is historical material,
;; not current authority.


;; Commands: none; Lisp entrypoints include supertag-get, supertag-set,
;; supertag-store-get-entity, supertag-store-put-entity, supertag-with-transaction,
;; supertag-subscribe, supertag-change-commit, supertag-index-rebuild-all.
;; Dependencies: cl-lib, ht; guarded supertag-core-persistence dirty marking, supertag-tag and
;; supertag-automation index callbacks. Legacy schema cache callbacks remain optional
;; capabilities, not a required module.
;; Transaction execution, rollback and shared notification state are owned here.
;; Former State/Notify carrier names in preserved API documentation are historical.
;;; Code:

(require 'cl-lib)
(require 'ht) ; Ensures `ht` API availability

(defun supertag-current-time ()
  "Return the current time as a four-element list for Store timestamps.
Derives from `current-time' so it stays the single clock source that tests
and callers can stub; on Emacs 32 `current-time' itself returns (TICKS . HZ)."
  (time-convert (current-time) 'list))
;;; --- Shared Core State Variables ---

(defvar supertag--suppress-notifications nil
  "If non-nil, suppress change notifications. Used for batch operations and transactions.")

(defvar supertag--pending-changes nil
  "List of changes to be notified when notifications are unsuppressed.
Each element is a list: (path old-value new-value).")

(defvar supertag--transaction-active nil
  "Flag indicating if a transaction is currently active.")

(defvar supertag--transaction-log nil
  "Log of changes made within the active transaction, for rollback.
Each element is a list: (PATH EXISTED-P OLD-VALUE), recorded the *first*
time PATH is touched during the transaction (see
`supertag--transaction-record-old-value'), and pushed so the head of the
list is always the most recently touched path. EXISTED-P is nil when PATH
had no entity before the transaction (so rollback must delete PATH again
rather than restore a value); otherwise OLD-VALUE is the pre-transaction
value to restore verbatim.")

(defvar supertag--transaction-seen nil
  "Hash table (equal-keyed) of paths already recorded in the current
transaction's rollback log, or nil when no transaction is active. Ensures
`supertag--transaction-record-old-value' only records the *original*
pre-transaction value the first time a path is touched — later writes to
the same path within the same transaction must not overwrite that snapshot
with an intermediate value.")

(defun supertag--transaction-record-old-value (path existed-p old-value)
  "Record OLD-VALUE for PATH the first time it is touched in this transaction.
No-op unless `supertag--transaction-active' is non-nil. Meant to be called
by the low-level store mutation primitives (`supertag-core-store.el') right
before they mutate PATH, so `supertag-with-transaction' can restore every
touched path to its true pre-transaction value on error.

EXISTED-P distinguishes an update (PATH already had OLD-VALUE, so rollback
restores it) from a creation (PATH did not exist, so rollback deletes it
again). OLD-VALUE is deep-copied with `copy-tree' so later in-place mutation
of the live entity plist cannot corrupt the recorded snapshot."
  (when supertag--transaction-active
    (unless (hash-table-p supertag--transaction-seen)
      (setq supertag--transaction-seen (make-hash-table :test 'equal)))
    (unless (gethash path supertag--transaction-seen)
      (puthash path t supertag--transaction-seen)
      (push (list path existed-p (copy-tree old-value)) supertag--transaction-log))))

;;; --- Macro for Managing Suppressed Notifications ---

(defmacro supertag-core-state-with-suppressed-notifications (&rest body)
  "Execute BODY with notifications suppressed.
Ensures proper cleanup of notification state even if an error occurs."
  (declare (indent 0))
  `(let ((supertag--suppress-notifications t)
         (supertag--pending-changes '()))
     (unwind-protect
         (progn ,@body)
       ;; Ensure notifications are re-enabled and pending changes cleared
       (setq supertag--suppress-notifications nil)
       (setq supertag--pending-changes '()))))



;;; --- Change Notification System ---

(defvar supertag--subscribers (ht-create)
  "Hash table to store subscribers for data path changes.
Key: data path (list of keys)
Value: list of callback functions")

(defun supertag-subscribe (event-type callback)
  "Subscribe to a specific EVENT-TYPE.
EVENT-TYPE can be a data path (list of keys) or a generic keyword (e.g., :store-changed).
CALLBACK will be called with arguments relevant to the event.
Returns a function to unsubscribe."
  (when (and (eq event-type :store-changed)
             (fboundp 'supertag-change--assert-legacy-topic-available))
    (supertag-change--assert-legacy-topic-available callback))
  (let ((callbacks (gethash event-type supertag--subscribers)))
    (puthash event-type (cons callback callbacks) supertag--subscribers)
    ;; Return an unsubscribe function
    (lambda ()
      (puthash event-type (cl-delete callback (gethash event-type supertag--subscribers)) supertag--subscribers))))

(defun supertag-emit-event (event-type &rest args)
  "Emit a generic event.
EVENT-TYPE is a keyword (e.g., :store-changed).
ARGS are the arguments to pass to the event handlers."
  (unless (and (eq event-type :store-changed)
               (bound-and-true-p
                supertag-change--suppress-legacy-store-changed))
    (let ((callbacks (gethash event-type supertag--subscribers)))
      (when callbacks
        (dolist (callback callbacks)
          ;; Call callbacks directly and let errors propagate.
          (apply callback args))))))

(defun supertag-notify (event-type &rest args)
  "Notify subscribers about an event.
This is a wrapper around supertag-emit-event for backward compatibility."
  (apply 'supertag-emit-event event-type args))

;;; --- Core Change Handler (called by supertag-store) ---

(defun supertag-core-notify-handle-change (path old-value new-value)
  "Handle a single data change notification.
This function is called by `supertag-store` after an update.
It manages pending changes for batch operations and dispatches notifications."
  (when (and (not (bound-and-true-p supertag--suppress-notifications))
             (not (equal old-value new-value))) ; Only notify if value actually changed
    (let ((callbacks (gethash path supertag--subscribers)))
      (when callbacks
        (dolist (callback callbacks)
          (funcall callback path old-value new-value)))))
  (when (bound-and-true-p supertag--suppress-notifications)
    (push (list path old-value new-value) supertag--pending-changes)))

;;; --- Batch Notification ---

(defun supertag--notify-batch-changes ()
  "Notify all pending changes in a batch.
This function is called after a batch operation or transaction commits.
It iterates through supertag--pending-changes and dispatches notifications."
  (setq supertag--suppress-notifications nil) ; Ensure notifications are re-enabled
  (dolist (change (nreverse supertag--pending-changes)) ; Notify in order
    (let ((path (nth 0 change))
          (old-value (nth 1 change))
          (new-value (nth 2 change)))
      (supertag-core-notify-handle-change path old-value new-value)))
  (setq supertag--pending-changes '())) ; Clear pending changes after notification


(declare-function supertag-mark-dirty "supertag-core-persistence")

;;; --- Core Data Store ---

(defvar supertag--store nil ; Initialize to nil, will be loaded by supertag-load-store
  "The central hash table for all application state.
Data is stored in a tree-like structure using nested hash tables.")

(defvar supertag-store-read-only-context nil
  "Non-nil while a trusted caller may read but must not mutate the Store.")

(defun supertag-store-assert-mutable (&optional operation)
  "Reject Store mutation in a read-only context.
OPERATION is included in the diagnostic when supplied."
  (when supertag-store-read-only-context
    (error "Store mutation%s is forbidden in %s"
           (if operation (format " (%s)" operation) "")
           supertag-store-read-only-context)))

(defconst supertag--store-collections
  '(:nodes
    :tags
    :relations
    :link-definitions         ; Link schema; concrete instances remain in :relations
    :ontology-bindings       ; logical ontology identity -> runtime entity binding
    :ontology-modules        ; deployed module provenance
    :ontology-migrations     ; applied ontology migration ledger
    :ontology-functions      ; deployed read-only Function contracts
    :ontology-actions        ; deployed Action contracts
    :ontology-policies       ; deployed Action authorization contracts
    :ontology-action-executions ; successful Action audit ledger
    :boards                     ; board-id -> board plist (whiteboard layouts)
    :views                      ; view-id -> persisted view config plist
    :automations                ; automation-id -> durable rule plist
    :sync-conflicts             ; conflict-id -> durable unresolved conflict plist
    :meta)
  "Durable root collections maintained in `supertag--store'.
Declared collections are initialized and verified. Unknown roots are retained
on load/save; the version migration explicitly retires legacy field roots
only after preserving their contents as pending migration records.
`:embeds' was removed (2026-08-13, task028): no production code reads or
writes it, and old files still load their `:embeds' lines via the loader's
normalization arms; the loaded data stays in memory and is written back
on the next save.  `:queries' was retired on 2026-09-06: the loader
`supertag--persistence--canonicalize-store-root' discards that root.")

(defconst supertag--canonical-collections
  '(:nodes :tags :relations :link-definitions
    :ontology-bindings :ontology-modules :ontology-migrations
    :ontology-functions :ontology-actions :ontology-policies
    :ontology-action-executions
    :boards :automations :sync-conflicts)
  "Collections expected to contain entity plists keyed by identifier.")

(defconst supertag--not-found (make-symbol "supertag-not-found")
  "Sentinel used to signal missing entries during path resolution.")

(defun supertag-store--put-and-notify (collection id data &optional emit-event-p)
  "Internal helper to store DATA under COLLECTION/ID and optionally emit event."
  (supertag-store-assert-mutable (list :put collection id))
  (let* ((bucket (supertag-store-get-collection collection))
         (existing (gethash id bucket supertag--not-found))
         (existed-p (not (eq existing supertag--not-found)))
         (canonical (supertag--normalize-entity data)))
    ;; Transaction seam: record the pre-write value (or "did not exist") the
    ;; first time this path is touched in the active transaction, so
    ;; `supertag-with-transaction' can roll it back on error. No-op when no
    ;; transaction is active.
    (supertag--transaction-record-old-value
     (list collection id) existed-p (if existed-p existing nil))
    (puthash id canonical bucket)
    (when (fboundp 'supertag-index-note-store-change)
      (supertag-index-note-store-change collection))
    (when emit-event-p
      (supertag-emit-event :store-changed (list collection id) nil canonical))
    canonical))

(defconst supertag-data-version "7.2.0"
  "Current data format version.
Used for data format compatibility checks and automatic migration.

Bumped 7.1.0 -> 7.2.0: a Tag's `:extends' is a list of parent Tag IDs, not a
single parent ID.  `supertag-migrate--normalize-extends-lists' rewrites every
stored string into a one-element list (DB-only, idempotent), and
`supertag-migrate--apply-legacy-extends' now adds a parent to the list
instead of reporting a second parent as a conflict.

Bumped 7.0.0 -> 7.1.0: `supertag-migrate--apply-legacy-extends' now resolves
`:legacy-extends' records directly into `:extends' on Tag entities (DB-only,
idempotent) instead of leaving them for an interactive path-rename step.
Records that cannot be resolved (missing child/parent, a cycle, or a
conflicting existing `:extends') remain in `:legacy-extends' and are reported
by `supertag-migrate-status' under `:unresolved-extends'.

7.0.0 preserves retired field data as pending migration records.
The verified migration chain stamps this version only after DB steps succeed.

Bumped 6.0.0 -> 6.1.0 to retire the duplicate `:node-tag' relation
projection.  Node `:tags' remains the authoritative membership projection.

Bumped 5.0.0 -> 6.0.0 (P1-8, see
archive/legacy-v2/2026-08-25-phrase/phases/phase-git-sync-20260713/PLAN.md
\"S2 Canonical Serialization\", revised 2026-07-13): the S2 canonical, line-per-entity
serialization is NOT actually readable by pre-6.0 (<= 5.9.x) builds the way
the original S2 writeup assumed. Those builds'
`supertag--persistence--try-read-store'
does exactly ONE `read' of the file and returns whatever single form that
call happens to consume; against the canonical format's line-per-entity
layout, that first `read' only ever sees the root scalar line (e.g.
`(:version \"6.0.0\" ...)') and never reaches any of the following
`(:collection ...)' entity lines -- so an old build loads what LOOKS like a
valid, merely-empty store, not a parse error. Bumping the data version at
least makes `supertag--maybe-auto-migrate' fire (with its own pre-migration
snapshot) the first time a pre-6.0 database is loaded by THIS (>= 6.0)
build, and keeps `supertag--get-data-version'/`supertag-migrate-run'
honest about the fact that the format actually changed here. See
`supertag--persistence--write-canonical-store' for the belt-and-suspenders
`supertag-db-preformat6-*' snapshot, which covers the case this version
bump alone does not: a database already stamped `:version \"6.0.0\"' (or
any version equal to `supertag-data-version') by a subsequent save, so
`supertag--maybe-auto-migrate' sees no version mismatch and never runs,
yet the on-disk file might still be the pre-canonical (legacy single-`prin1')
format if it was never resaved since upgrading this package.")

(defun supertag--ensure-store ()
  "Ensure `supertag--store' exists and has canonical collections.
A store created here is current-version data, so it is stamped with
`supertag-data-version'.  A store that came from disk keeps the version its
file carried, including none at all -- an unstamped file is unknown, not current."
  (unless (hash-table-p supertag--store)
    (setq supertag--store (ht-create))
    (puthash :version supertag-data-version supertag--store))
  (dolist (collection supertag--store-collections)
    (let ((bucket (gethash collection supertag--store 'missing)))
      (unless (hash-table-p bucket)
        (puthash collection (ht-create) supertag--store))))
  supertag--store)

(defun supertag--normalize-entity (value)
  "Return VALUE converted to canonical plist when it is a hash table."
  (cond
   ((hash-table-p value)
    (let (plist)
      (maphash (lambda (k v)
                 (setq plist (plist-put plist k v)))
               value)
      plist))
   (t value)))

(defun supertag-store-get-collection (collection)
  "Return hash table for COLLECTION, creating it if necessary."
  (supertag--ensure-store)
  (let ((bucket (gethash collection supertag--store 'missing)))
    (unless (hash-table-p bucket)
      (setq bucket (ht-create))
      (puthash collection bucket supertag--store))
    bucket))

(defun supertag-store-collection-names ()
  "Return the names of all hash-table collections in the Store."
  (let (names)
    (maphash (lambda (name value)
               (when (hash-table-p value)
                 (push name names)))
             (supertag--ensure-store))
    (nreverse names)))

(defun supertag-store-get-entity (collection id)
  "Return entity plist stored under COLLECTION keyed by ID."
  (gethash id (supertag-store-get-collection collection)))

(defun supertag-store-put-entity (collection id data &optional emit-event-p)
  "Store DATA under COLLECTION/ID.
When EMIT-EVENT-P is non-nil, emit :store-changed notification."
  (supertag-store--put-and-notify collection id data emit-event-p))

(defun supertag-store-remove-entity (collection id)
  "Remove entity under COLLECTION/ID. Returns removed value or nil."
  (supertag-store-assert-mutable (list :remove collection id))
  (let* ((bucket (supertag-store-get-collection collection))
         (old (and bucket (gethash id bucket))))
    (when old
      (supertag--transaction-record-old-value (list collection id) t old)
      (remhash id bucket)
      (when (fboundp 'supertag-index-note-store-change)
        (supertag-index-note-store-change collection))
      (supertag-emit-event :store-changed (list collection id) old nil))
    old))

(defun supertag--coerce-store-table (data)
  "Coerce DATA into a hash table representation of the store."
  (cond
   ((hash-table-p data)
    data)
   ((null data)
    (ht-create))
   ;; Property list layout: (:nodes <val> :tags <val> ...)
   ((and (listp data) (keywordp (car data)))
    (let ((table (ht-create))
          (cursor data))
      (while cursor
        (let ((key (pop cursor))
              (value (pop cursor)))
          (puthash key value table)))
      table))
   ;; Association list layout: ((:nodes . <val>) (:tags . <val>))
   ((and (listp data) (consp (car data)))
    (let ((table (ht-create)))
      (dolist (cell data table)
        (puthash (car cell) (cdr cell) table))))
   (t
    (let ((table (ht-create)))
      (puthash :data data table)
      table))))

(defun supertag--normalize-collection-value (collection value)
  "Normalize VALUE stored under COLLECTION into canonical hash tables/plists."
  (let ((bucket
         (cond
          ((hash-table-p value)
           value)
          ((null value)
           (ht-create))
          ;; Allow plist-based buckets: (id1 plist1 id2 plist2 ...)
          ((and (listp value) (not (null value)) (keywordp (car value)))
           (let ((table (ht-create))
                 (cursor value))
             (while cursor
               (let ((entry-key (pop cursor))
                     (entry-val (pop cursor)))
                 (puthash entry-key entry-val table)))
             table))
          ;; Alist buckets: ((id . plist) ...)
          ((and (listp value) (consp (car value)))
           (let ((table (ht-create)))
             (dolist (cell value table)
               (puthash (car cell) (cdr cell) table))))
          (t
           (let ((table (ht-create)))
             (puthash :value value table)
             table)))))
    (when (memq collection supertag--canonical-collections)
      (maphash
       (lambda (entity-id entity)
         (when (hash-table-p entity)
           (puthash entity-id (supertag--normalize-entity entity) bucket)))
       bucket))
    bucket))

;;; --- Canonical Path Resolution ---

(defun supertag--resolve-path (container path)
  "Traverse CONTAINER following PATH and return the located value or `supertag--not-found'.
CONTAINER may be a hash table, plist, or alist. PATH is a list of keys."
  (if (null path)
      container
    (let ((key (car path))
          (rest (cdr path)))
      (cond
       ;; Nothing left to traverse: missing
       ((null container)
        supertag--not-found)
       ;; Hash-table navigation
       ((hash-table-p container)
        (let ((value (gethash key container supertag--not-found)))
          (if (eq value supertag--not-found)
              supertag--not-found
            (if rest
                (supertag--resolve-path value rest)
              value))))
       ;; Keyword lookup in plist
       ((and (listp container) (keywordp key))
        (let ((cell (plist-member container key)))
          (if cell
              (let ((value (cadr cell)))
                (if rest
                    (supertag--resolve-path value rest)
                  value))
            supertag--not-found)))
       ;; Association list lookup (string/symbol keys)
       ((and (listp container) (consp (car container)))
        (let ((cell (assoc key container)))
          (if cell
              (let ((value (cdr cell)))
                (if rest
                    (supertag--resolve-path value rest)
                  value))
            supertag--not-found)))
       ;; Fallback: treat as flat key/value list (\"key\" value ...)
       ((listp container)
        (let ((cursor container)
              (found supertag--not-found))
          (while (and cursor (not (eq found supertag--not-found)))
            (let ((entry-key (car cursor))
                  (entry-val (cadr cursor)))
              (when (equal entry-key key)
                (setq found entry-val))
              (setq cursor (cddr cursor))))
          (if (eq found supertag--not-found)
              supertag--not-found
            (if rest
                (supertag--resolve-path found rest)
              found))))
       (t
        supertag--not-found)))))

;;; --- Change Notification ---

(defun supertag--notify-change (path old-value new-value)
  "Trigger a change notification for PATH with OLD-VALUE and NEW-VALUE.
This function dispatches to the notification handler owned by this Store module."
  ;; Keep the existing availability guard for the Store-owned handler.
  (when (fboundp 'supertag-core-notify-handle-change)
    (supertag-core-notify-handle-change path old-value new-value)))

;;; --- Public API for Data Storage ---

(defun supertag-get (path &optional default)
  "Get data from the store by PATH.
PATH is a list of keys (e.g., '(:nodes \"123\" :tags)).
Supports mixed structures: hash-tables and plists."
  ;; Ensure store is initialized
  (supertag--ensure-store)
  (let ((resolved (supertag--resolve-path supertag--store path)))
    (if (eq resolved supertag--not-found)
        default
      resolved)))

(defun supertag-update (path value)
  "Atomically update a value in the central store at PATH.
 PATH is a list of keys. Returns the old value.
 Triggers change notifications unless suppressed.
 Stores plist values directly.

In canonical mode PATH must reference either a collection (:nodes) or
a collection entity (:nodes \"id\")."
  (supertag-store-assert-mutable (list :update path))
  ;; Ensure store is initialized
  (supertag--ensure-store)

  (unless (and (listp path) path)
    (error "PATH must be a non-empty list, got: %S" path))

  (pcase path
    (`(,collection)
     (let* ((old-value (supertag-get path supertag--not-found))
            (normalized (supertag--normalize-collection-value collection value)))
       (if (and (not (eq old-value supertag--not-found))
                (equal old-value normalized))
           old-value
         (let ((old (if (eq old-value supertag--not-found) nil old-value)))
           (supertag--transaction-record-old-value
            path (not (eq old-value supertag--not-found)) old)
           (puthash collection normalized supertag--store)
           (when (fboundp 'supertag-index-note-store-change)
             (supertag-index-note-store-change collection))
           (supertag--notify-change path old normalized)
           (supertag-emit-event :store-changed path old normalized))
         (if (eq old-value supertag--not-found) nil old-value))))
    (`(,collection ,id)
     (let* ((canonical (supertag--normalize-entity value))
            (old-value (supertag-store-get-entity collection id)))
       (if (equal old-value canonical)
           old-value
         (supertag-store-put-entity collection id canonical)
         (supertag--notify-change path old-value canonical)
         (supertag-emit-event :store-changed path old-value canonical)
         old-value)))
    (_
     (error "Canonical store update only supports collection/entity paths, got: %S" path))))

(defun supertag-delete (path)
  "Atomically delete a value from the central store at PATH."
  (supertag-store-assert-mutable (list :delete path))
  ;; Ensure store is initialized
  (supertag--ensure-store)

  (unless (and (listp path) path)
    (error "PATH must be a non-empty list, got: %S" path))

  (pcase path
    (`(,collection)
     (let ((existing (supertag-get path supertag--not-found)))
       (if (eq existing supertag--not-found)
           nil
         (let ((cleared (supertag--normalize-collection-value collection nil)))
           (supertag--transaction-record-old-value path t existing)
           (puthash collection cleared supertag--store)
           (when (fboundp 'supertag-index-note-store-change)
             (supertag-index-note-store-change collection))
           (supertag--notify-change path existing nil)
           (supertag-emit-event :store-changed path existing nil)
           existing))))
    (`(,collection ,id)
     (let ((old-value (supertag-store-remove-entity collection id)))
       (when old-value
         (supertag--notify-change path old-value nil))
       old-value))
    (_
     (error "Canonical store delete only supports collection/entity paths, got: %S" path))))

;;; --- Unified Commit Pipeline ---

(defvar supertag-before-operation-hook nil
  "Hook run before `supertag-ops-commit`.
Each function receives a plist containing at least
`:operation', `:collection', `:id', `:path', `:context', and `:previous'.")

(defvar supertag-after-operation-hook nil
  "Hook run after `supertag-ops-commit`.
Each function receives a plist containing the commit payload plus
`:current' and `:changed' keys.")

(defvar supertag-ops-defer-events nil
  "Non-nil while `supertag-ops-commit' must defer post-mutation delivery.")

(defvar supertag-ops-deferred-events nil
  "Dynamically accumulated post-mutation event bundles.")

(defvar supertag-ops-deferred-event-errors nil
  "Captured deferred event delivery failures, newest first.")

(defun supertag-ops--deliver-event-bundle (bundle)
  "Deliver one committed operation BUNDLE.
Store events are emitted only for a changed operation.  The compatibility
`supertag-after-operation-hook' still runs for no-op operations, matching the
non-deferred `supertag-ops-commit' contract."
  (let ((event (plist-get bundle :event))
        (event-payload (plist-get bundle :event-payload))
        (path (plist-get bundle :path))
        (previous (plist-get bundle :previous))
        (current (plist-get bundle :current)))
    (when (plist-get event :changed)
      (supertag-emit-event :store-committed event-payload)
      (when path
        (supertag-emit-event :store-changed path previous current)))
    (run-hook-with-args 'supertag-after-operation-hook event)))

(defun supertag-ops-flush-deferred-events (bundles)
  "Deliver committed operation BUNDLES after their outer transaction.

Failures are isolated because the Store has already committed.  They are
recorded in `supertag-ops-deferred-event-errors'."
  (dolist (bundle bundles)
    (condition-case err
        (supertag-ops--deliver-event-bundle bundle)
      (error
       (push (list :bundle bundle :error (error-message-string err))
             supertag-ops-deferred-event-errors)
       (message "[supertag] Deferred operation event failed: %s"
                (error-message-string err))))))

(defun supertag-ops-commit (&rest spec)
  "Execute a datastore mutation described by SPEC and broadcast a unified event.
Required keys in SPEC:
- :operation — keyword describing the logical action (:create, :update, :delete, ...).
- :perform   — thunk that performs the mutation (must be non-nil unless :new or :result supplied).

Optional keys:
- :collection — top-level store collection (e.g., :nodes).
- :id         — entity identifier within COLLECTION.
- :path       — explicit path used for event payloads when COLLECTION/ID is not enough.
- :context    — arbitrary metadata passed through to hooks and listeners.
- :previous   — precomputed previous value (otherwise derived from store when possible).
- :new        — explicitly provide resulting value (skips post-fetch).
- :result     — fallback return value when no collection is associated.
- :force-event — emit events even when :previous and :new compare equal.
- :suppress-mark-dirty — inhibit automatic dirty flag toggling.

Returns the updated entity when available, otherwise falls back to :result or :previous."
  (let* ((operation (plist-get spec :operation))
         (perform (plist-get spec :perform))
         (collection (plist-get spec :collection))
         (entity-id (plist-get spec :id))
         (explicit-path (plist-get spec :path))
         (context (plist-get spec :context)))
    (unless operation
      (error "supertag-ops-commit requires :operation"))
    (unless (or (functionp perform)
                (plist-member spec :new)
                (plist-member spec :result))
      (error "supertag-ops-commit requires :perform or :new/:result"))
    (let* ((path (or explicit-path
                     (when collection
                       (if entity-id
                           (list collection entity-id)
                         (list collection)))))
           (previous (if (plist-member spec :previous)
                         (plist-get spec :previous)
                       (when (and collection entity-id)
                         (supertag-store-get-entity collection entity-id))))
           (before-payload (list :operation operation
                                 :collection collection
                                 :id entity-id
                                 :path path
                                 :context context
                                 :previous previous)))
      (run-hook-with-args 'supertag-before-operation-hook before-payload)
      (let* ((result (cond
                      ((functionp perform) (funcall perform))
                      ((plist-member spec :result) (plist-get spec :result))
                      (t nil)))
             (current (cond
                       ((plist-member spec :new) (plist-get spec :new))
                       ((and collection entity-id)
                        (supertag-store-get-entity collection entity-id))
                       ((plist-member spec :result) (plist-get spec :result))
                       (t result)))
             (changed (or (plist-get spec :force-event)
                          (not (equal previous current))))
             (event (plist-put (plist-put (copy-sequence before-payload)
                                          :current current)
                               :changed changed)))
        (when (and changed
                   (not (plist-get spec :suppress-mark-dirty))
                   (fboundp 'supertag-mark-dirty))
          (supertag-mark-dirty))
        (let ((bundle
               (list :event event
                     :event-payload
                     (when changed
                       (plist-put (copy-tree event) :result result))
                     :path path :previous previous :current current)))
          (if supertag-ops-defer-events
              (push bundle supertag-ops-deferred-events)
            (supertag-ops--deliver-event-bundle bundle)))
        (cond
         ((plist-member spec :return) (plist-get spec :return))
         (current current)
         (result result)
         (t previous))))))

;;; --- Transaction Support ---

(defun supertag--transaction-restore-entry (entry)
  "Undo one recorded ENTRY of the form (PATH EXISTED-P OLD-VALUE).
Supports (COLLECTION ID) entity changes and (COLLECTION) replacement."
  (let ((path (nth 0 entry))
        (existed-p (nth 1 entry))
        (old-value (nth 2 entry)))
    (cond
     ((= (length path) 2)
      (let ((collection (nth 0 path))
            (id (nth 1 path)))
        (if existed-p
            (supertag-store-put-entity collection id old-value)
          (supertag-store-remove-entity collection id))))
     ((= (length path) 1)
      (if existed-p
          (supertag-update path old-value)
        (supertag-delete path)))
     (t
      (error "supertag--transaction-restore-entry: unsupported path shape %S" path)))))

(defun supertag--transaction-rollback (log)
  "Undo every change recorded in LOG, most-recently-touched path first.
LOG is a list of (PATH EXISTED-P OLD-VALUE) entries as produced by
`supertag--transaction-record-old-value' — since entries are pushed as they
are first recorded, LOG is already in the correct (reverse chronological)
order for `dolist' to walk directly. Restoration itself must not be treated
as new transactional writes, so the active-transaction flag is bound to nil
for the duration."
  (let ((supertag--transaction-active nil)
        (supertag--transaction-seen nil))
    (dolist (entry log)
      (supertag--transaction-restore-entry entry))))

(defvar supertag-after-transaction-rollback-hook nil
  "Hook run after an outer transaction restores its Store state.
Functions on this hook must not mutate the Store.")

(defun supertag--run-transaction-rollback-hooks ()
  "Run every rollback invariant and return the first error, if any."
  (let (first-error)
    (run-hook-wrapped
     'supertag-after-transaction-rollback-hook
     (lambda (function)
       (condition-case err
           (funcall function)
         (error
          (unless first-error
            (setq first-error err))))
       nil))
    first-error))

(defmacro supertag-with-transaction (&rest body)
  "Execute BODY within a transaction.
If an error occurs during BODY execution, every path touched during the
transaction — directly, or transitively via automation actions triggered
synchronously by those writes — is restored to its exact pre-transaction
value: entities created during the transaction are removed again, and
entities deleted during the transaction are resurrected with their original
value. This works because every low-level store mutation primitive
(`supertag-store-put-entity', `supertag-store-remove-entity',
and
the whole-collection replace/clear paths in `supertag-update'/`supertag-delete')
calls `supertag--transaction-record-old-value' before mutating, which is a
no-op unless a transaction is active.

Nesting: invoking `supertag-with-transaction' while one is already active
simply runs BODY inline so its changes join the *enclosing* transaction's
log — there is no separate commit, rollback, or notification flush for the
inner call; only the outermost transaction commits or rolls back.

Notifications are suppressed until the (outermost) transaction commits, at
which point exactly one batch notification flush happens."
  (declare (indent 0))
  ;; Use an uninterned symbol so BODY may freely use a variable named
  ;; `result' without it being captured by this expansion.
  (let ((result (make-symbol "result")))
  `(if supertag--transaction-active
       ;; Already inside a transaction: just run BODY so it joins the
       ;; enclosing transaction's log instead of starting/ending its own.
       (progn ,@body)
     (let ((supertag--transaction-active t) ; Flag for transaction
           (supertag--transaction-log '()) ; Log for rollback
           (supertag--transaction-seen nil) ; Dedup set: first-touch only
           (supertag--tx-success nil)
           (supertag--rollback-error nil)
           ,result) ; Variable to capture the result
       (unwind-protect
           (progn
             (setq ,result (supertag-core-state-with-suppressed-notifications
                           (progn ,@body)))
             (setq supertag--tx-success t)
             ;; Commit transaction: notify all pending changes
             (when (fboundp 'supertag--notify-batch-changes)
               (supertag--notify-batch-changes))
             ,result) ; Return the result
         ;; Cleanup: roll back on error, then always reset transaction state.
         (unless supertag--tx-success
           (supertag--transaction-rollback supertag--transaction-log)
           (setq supertag--rollback-error
                 (supertag--run-transaction-rollback-hooks)))
         (setq supertag--transaction-active nil)
         (setq supertag--transaction-log nil)
         (setq supertag--transaction-seen nil)
         (when supertag--rollback-error
           (signal (car supertag--rollback-error)
                   (cdr supertag--rollback-error))))))))

;;; --- Derived Store indexes and rollback registration ---

(defvar supertag--store)

;;; --- Index Variables ---

(defvar supertag--index-relations-by-from (make-hash-table :test 'equal)
  "Index: from-id -> hash-table of relation-id -> t.")

(defvar supertag--index-relations-by-to (make-hash-table :test 'equal)
  "Index: to-id -> hash-table of relation-id -> t.")

(defvar supertag--index-relations-source-token nil
  "Source token represented by the current relation indexes.")

(defvar supertag--index-nodes-by-tag (make-hash-table :test 'equal)
  "Index: Tag ID or occurrence token -> hash-set of node IDs.")

(defvar supertag--index-node-ranks (make-hash-table :test 'equal)
  "Index: node ID -> Store traversal rank for query-order compatibility.")

(defvar supertag--index-nodes-source-token nil
  "Source token represented by `supertag--index-nodes-by-tag'.")

(defvar supertag--index-source-revisions (make-hash-table :test 'eq)
  "Monotonic in-memory revisions for Store collections.")

(defun supertag-index-note-store-change (collection)
  "Record a mutation of Store COLLECTION."
  (puthash collection
           (1+ (gethash collection supertag--index-source-revisions 0))
           supertag--index-source-revisions))

(defun supertag-index-source-token (collections)
  "Return the current Store identity and revisions for COLLECTIONS."
  (cons supertag--store
        (mapcar (lambda (collection)
                  (cons collection
                        (gethash collection supertag--index-source-revisions 0)))
                collections)))

(defun supertag-index-source-current-p (token collections)
  "Return non-nil when TOKEN still represents COLLECTIONS in the live Store."
  (and token
       (eq (car token) supertag--store)
       (equal (cdr token) (cdr (supertag-index-source-token collections)))))

;;; --- Incremental Maintenance ---

(defun supertag-index--add-relation-entry (relation-id from-id to-id)
  "Add RELATION-ID to the indexes for FROM-ID and TO-ID."
  (let ((from-set (gethash from-id supertag--index-relations-by-from)))
    (unless from-set
      (setq from-set (make-hash-table :test 'equal))
      (puthash from-id from-set supertag--index-relations-by-from))
    (puthash relation-id t from-set))
  (let ((to-set (gethash to-id supertag--index-relations-by-to)))
    (unless to-set
      (setq to-set (make-hash-table :test 'equal))
      (puthash to-id to-set supertag--index-relations-by-to))
    (puthash relation-id t to-set)))

(defun supertag-index--remove-relation-entry (relation-id from-id to-id)
  "Remove RELATION-ID from the indexes for FROM-ID and TO-ID."
  (let ((from-set (gethash from-id supertag--index-relations-by-from)))
    (when from-set
      (remhash relation-id from-set)
      (when (= 0 (hash-table-count from-set))
        (remhash from-id supertag--index-relations-by-from))))
  (let ((to-set (gethash to-id supertag--index-relations-by-to)))
    (when to-set
      (remhash relation-id to-set)
      (when (= 0 (hash-table-count to-set))
        (remhash to-id supertag--index-relations-by-to)))))

(defun supertag-index--on-relation-changed
    (relation-id old-from old-to new-from new-to)
  "Apply one completed Store mutation of RELATION-ID to relation indexes."
  (let* ((current-token (supertag-index-source-token '(:relations)))
         (old-revision (alist-get :relations
                                  (cdr supertag--index-relations-source-token)))
         (current-revision (alist-get :relations (cdr current-token))))
    (when (and old-revision
               (eq (car supertag--index-relations-source-token) supertag--store)
               (= (1+ old-revision) current-revision))
      (when (and old-from old-to)
        (supertag-index--remove-relation-entry relation-id old-from old-to))
      (when (and new-from new-to)
        (supertag-index--add-relation-entry relation-id new-from new-to))
      (setq supertag--index-relations-source-token current-token))))

;;; --- Full Rebuild ---

(defun supertag-index-rebuild-relations ()
  "Rebuild relation indexes from the :relations collection.
Call this after loading the store from disk."
  (setq supertag--index-relations-by-from (make-hash-table :test 'equal))
  (setq supertag--index-relations-by-to   (make-hash-table :test 'equal))
  (when (and (boundp 'supertag--store)
             (hash-table-p supertag--store))
    (let ((relations (gethash :relations supertag--store)))
      (when (hash-table-p relations)
        (maphash
         (lambda (rel-id relation)
           (when relation
             (let ((from-id (plist-get relation :from))
                   (to-id   (plist-get relation :to)))
               (when (and from-id to-id)
                 (supertag-index--add-relation-entry rel-id from-id to-id)))))
         relations))))
  (setq supertag--index-relations-source-token
        (supertag-index-source-token '(:relations))))

(defun supertag-index--ensure-relations ()
  "Cold rebuild relation indexes when their Store source changed."
  (unless (supertag-index-source-current-p
           supertag--index-relations-source-token '(:relations))
    (supertag-index-rebuild-relations)))

(defun supertag-node-tag-query-keys (node-data)
  "Return Semantic Tag IDs and Org Tag Occurrences from NODE-DATA."
  (delete-dups
   (append (copy-sequence (or (plist-get node-data :tags) '()))
           (copy-sequence (or (plist-get node-data :tag-occurrences) '())))))

(defun supertag-index-clear-nodes-by-tag ()
  "Clear the node membership index."
  (setq supertag--index-nodes-by-tag (make-hash-table :test 'equal)
        supertag--index-node-ranks (make-hash-table :test 'equal)
        supertag--index-nodes-source-token nil))

(defun supertag-index-rebuild-nodes-by-tag ()
  "Rebuild Tag/occurrence -> node membership from Document Projections."
  (supertag-index-clear-nodes-by-tag)
  (let ((nodes (and (boundp 'supertag--store)
                    (hash-table-p supertag--store)
                    (gethash :nodes supertag--store)))
        (rank 0))
    (when (hash-table-p nodes)
      (maphash
       (lambda (node-id node)
         (puthash node-id rank supertag--index-node-ranks)
         (setq rank (1+ rank))
         (dolist (tag (supertag-node-tag-query-keys node))
           (when (stringp tag)
             (let ((set (or (gethash tag supertag--index-nodes-by-tag)
                            (let ((new (make-hash-table :test 'equal)))
                              (puthash tag new supertag--index-nodes-by-tag)
                              new))))
               (puthash node-id t set)))))
       nodes)))
  (setq supertag--index-nodes-source-token
        (supertag-index-source-token '(:nodes))))

(defun supertag-index--ensure-nodes-by-tag ()
  "Cold rebuild node membership when its Document Projection changed."
  (unless (supertag-index-source-current-p
           supertag--index-nodes-source-token '(:nodes))
    (supertag-index-rebuild-nodes-by-tag)))

(defun supertag-index-find-node-ids-by-tags (tag-ids)
  "Return node IDs belonging to any ID/token in TAG-IDS."
  (supertag-index--ensure-nodes-by-tag)
  (let ((seen (make-hash-table :test 'equal))
        result)
    (dolist (tag-id tag-ids)
      (when-let* ((set (gethash tag-id supertag--index-nodes-by-tag)))
        (maphash (lambda (node-id _present)
                   (puthash node-id t seen))
                 set)))
    (maphash (lambda (node-id _present) (push node-id result)) seen)
    (sort result
          (lambda (left right)
            (< (gethash left supertag--index-node-ranks most-positive-fixnum)
               (gethash right supertag--index-node-ranks most-positive-fixnum))))))

(defun supertag-index-clear-all ()
  "Clear every Store-derived runtime index without touching the Store."
  (setq supertag--index-relations-by-from (make-hash-table :test 'equal)
        supertag--index-relations-by-to (make-hash-table :test 'equal)
        supertag--index-relations-source-token nil)
  (supertag-index-clear-nodes-by-tag)
  (when (fboundp 'supertag-tag-index-clear)
    (supertag-tag-index-clear))
  (when (fboundp 'supertag-schema-clear-global-field-caches)
    (supertag-schema-clear-global-field-caches))

  (when (fboundp 'supertag-automation-clear-rule-index)
    (supertag-automation-clear-rule-index)))

(defun supertag-index-rebuild-all ()
  "Cold rebuild every Store-derived runtime index as one generation."
  (supertag-index-clear-all)
  (condition-case err
      (progn
        (supertag-index-rebuild-relations)
        (when (fboundp 'supertag-tag-index-rebuild)
          (supertag-tag-index-rebuild))
        (supertag-index-rebuild-nodes-by-tag)
        (when (fboundp 'supertag-schema-rebuild-global-field-caches)
          (supertag-schema-rebuild-global-field-caches))

        (when (fboundp 'supertag-rebuild-rule-index)
          (supertag-rebuild-rule-index))
        t)
    (error
     (supertag-index-clear-all)
     (signal (car err) (cdr err)))))

;;; --- Index-Accelerated Queries ---

(defun supertag-index--collect-relations (entity-id index-table &optional type)
  "Collect relation plists for ENTITY-ID from INDEX-TABLE, optionally filtered by TYPE."
  (let ((id-set (gethash entity-id index-table))
        (result '()))
    (when id-set
      (let ((relations-ht (and (boundp 'supertag--store)
                               (hash-table-p supertag--store)
                               (gethash :relations supertag--store))))
        (when (hash-table-p relations-ht)
          (maphash
           (lambda (rel-id _v)
             (let ((relation (gethash rel-id relations-ht)))
               (when (and relation
                          (or (null type)
                              (eq (plist-get relation :type) type)))
                 (push relation result))))
           id-set))))
    result))

(defun supertag-index-find-by-from (from-id &optional type)
  "Find relations originating from FROM-ID.  O(k) where k = matching relations.
Optional TYPE filters by relation type."
  (supertag-index--ensure-relations)
  (supertag-index--collect-relations from-id supertag--index-relations-by-from type))

(defun supertag-index-find-by-to (to-id &optional type)
  "Find relations targeting TO-ID.  O(k) where k = matching relations.
Optional TYPE filters by relation type."
  (supertag-index--ensure-relations)
  (supertag-index--collect-relations to-id supertag--index-relations-by-to type))

(defun supertag-index-find-between (from-id to-id &optional type)
  "Find relations from FROM-ID to TO-ID.  O(k) where k = from-id's relations.
Optional TYPE filters by relation type."
  (supertag-index--ensure-relations)
  (let ((id-set (gethash from-id supertag--index-relations-by-from))
        (result '()))
    (when id-set
      (let ((relations-ht (and (boundp 'supertag--store)
                               (hash-table-p supertag--store)
                               (gethash :relations supertag--store))))
        (when (hash-table-p relations-ht)
          (maphash
           (lambda (rel-id _v)
             (let ((relation (gethash rel-id relations-ht)))
               (when (and relation
                          (equal (plist-get relation :to) to-id)
                          (or (null type)
                              (eq (plist-get relation :type) type)))
                 (push relation result))))
           id-set))))
    result))

(add-hook 'supertag-after-transaction-rollback-hook
          #'supertag-index-rebuild-all)

;;; --- Canonical committed changes ---

(defconst supertag-change--authorities
  '(:document :semantic :operational)
  "Authorities accepted by Canonical Change version 1.")

(defconst supertag-change--scopes
  '(:fact :projection :fact+projection)
  "Mutation scopes accepted by Canonical Change version 1.")

(defconst supertag-change--max-affected-entries 32
  "Maximum number of collection summaries in one Canonical Change.")

(defvar supertag-change--subscribers nil
  "Canonical Change callbacks, in subscription order.")

(defvar supertag-change--queue nil
  "FIFO of complete committed delivery batches awaiting delivery.")

(defvar supertag-change--dispatching nil
  "Non-nil while the Canonical Change FIFO is being drained.")

(defvar supertag-change--delivering-change-id nil
  "Change ID currently being delivered, used as nested commit causation.")

(defvar supertag-change--subscriber-errors nil
  "Captured subscriber failures, newest first.")

(defvar supertag-change--id-counter 0
  "Process-local suffix for Canonical Change IDs.")

(defvar supertag-change--suppress-legacy-store-changed nil
  "Non-nil while a managed body must suppress immediate legacy delivery.")

(defvar supertag-change--bridge-commit-count 0
  "Number of committed batches passed through the legacy bridge.")

(defvar supertag-change--bridge-total-path-count 0
  "Total number of path events passed through the legacy bridge.")

(defvar supertag-change--bridge-last-path-count 0
  "Number of path events in the most recently bridged commit.")

(defcustom supertag-change-bridge-debug nil
  "When non-nil, log bounded legacy bridge delivery diagnostics."
  :type 'boolean
  :group 'supertag)

(defun supertag-change--plist-p (value)
  "Return non-nil when VALUE is a proper keyword property list."
  (and (proper-list-p value)
       (zerop (% (length value) 2))
       (cl-loop for (key _value) on value by #'cddr
                always (keywordp key))))

(defun supertag-change--plist-keys (plist)
  "Return PLIST keys in order."
  (cl-loop for (key _value) on plist by #'cddr collect key))

(defun supertag-change--contains-raw-diff-p (value)
  "Return non-nil when VALUE contains Kernel-private raw diff vocabulary."
  (cond
   ((hash-table-p value) t)
   ((supertag-change--plist-p value)
    (cl-loop for (key item) on value by #'cddr
             thereis (or (memq key '(:path :paths :old :new :commit-record))
                         (supertag-change--contains-raw-diff-p item))))
   ((consp value)
    (cl-some #'supertag-change--contains-raw-diff-p value))
   (t nil)))

(defun supertag-change--validate-affected (affected)
  "Validate bounded AFFECTED collection/count summaries."
  (unless (and (proper-list-p affected)
               (<= (length affected)
                   supertag-change--max-affected-entries))
    (error "Canonical Change :affected must contain at most %d entries"
           supertag-change--max-affected-entries))
  (dolist (entry affected)
    (unless (and (supertag-change--plist-p entry)
                 (equal (sort (copy-sequence
                               (supertag-change--plist-keys entry))
                              (lambda (left right)
                                (string< (symbol-name left)
                                         (symbol-name right))))
                        '(:collection :count))
                 (keywordp (plist-get entry :collection))
                 (natnump (plist-get entry :count)))
      (error "Invalid Canonical Change :affected entry: %S" entry))))

(defun supertag-change--validate-envelope (envelope)
  "Validate and return Canonical Change ENVELOPE."
  (unless (supertag-change--plist-p envelope)
    (error "Canonical Change envelope must be a keyword plist"))
  (let ((allowed '(:authority :scope :operation :subject
                   :cardinality :affected :metadata)))
    (dolist (key (supertag-change--plist-keys envelope))
      (unless (memq key allowed)
        (error "Unknown Canonical Change envelope key: %S" key))))
  (dolist (required '(:authority :scope :operation :cardinality :affected))
    (unless (plist-member envelope required)
      (error "Canonical Change requires %S" required)))
  (unless (memq (plist-get envelope :authority)
                supertag-change--authorities)
    (error "Invalid Canonical Change authority: %S"
           (plist-get envelope :authority)))
  (unless (memq (plist-get envelope :scope) supertag-change--scopes)
    (error "Invalid Canonical Change scope: %S"
           (plist-get envelope :scope)))
  (unless (and (symbolp (plist-get envelope :operation))
               (plist-get envelope :operation))
    (error "Canonical Change :operation must be a non-nil symbol"))
  (unless (or (null (plist-get envelope :subject))
              (supertag-change--plist-p (plist-get envelope :subject)))
    (error "Canonical Change :subject must be nil or a keyword plist"))
  (unless (memq (plist-get envelope :cardinality) '(:single :batch))
    (error "Invalid Canonical Change cardinality: %S"
           (plist-get envelope :cardinality)))
  (unless (or (null (plist-get envelope :metadata))
              (supertag-change--plist-p (plist-get envelope :metadata)))
    (error "Canonical Change :metadata must be nil or a keyword plist"))
  (when (or (supertag-change--contains-raw-diff-p
             (plist-get envelope :subject))
            (supertag-change--contains-raw-diff-p
             (plist-get envelope :metadata)))
    (error "Canonical Change public data cannot contain raw Store diffs"))
  (supertag-change--validate-affected (plist-get envelope :affected))
  envelope)

(defun supertag-change--capture-commit-record ()
  "Return the changed first-touch entries in the active transaction.

Each private entry retains path/old/new data for commit plumbing.  Equal
first-touch writes are omitted so a logical no-op publishes no change."
  (let ((missing (make-symbol "supertag-change-missing")))
    (cl-loop
     for (path old-existed-p old-value) in (nreverse supertag--transaction-log)
     for current = (supertag-get path missing)
     for current-existed-p = (not (eq current missing))
     unless (and (eq (not (null old-existed-p)) current-existed-p)
                 (equal old-value (unless (eq current missing) current)))
     collect (list :path (copy-tree path)
                   :old-existed-p old-existed-p
                   :old (copy-tree old-value)
                   :new-existed-p current-existed-p
                   :new (unless (eq current missing) (copy-tree current))))))

(defun supertag-change--next-id ()
  "Return a process-unique Canonical Change ID."
  (format "change-%d-%d-%d"
          (emacs-pid)
          (truncate (* 1000000 (float-time)))
          (cl-incf supertag-change--id-counter)))

(defun supertag-change--make-change (envelope)
  "Build a public Canonical Change from validated ENVELOPE."
  (list :version 1
        :change-id (supertag-change--next-id)
        :causation-id supertag-change--delivering-change-id
        :authority (plist-get envelope :authority)
        :scope (plist-get envelope :scope)
        :operation (plist-get envelope :operation)
        :subject (copy-tree (plist-get envelope :subject))
        :cardinality (plist-get envelope :cardinality)
        :affected (copy-tree (plist-get envelope :affected))
        :metadata (copy-tree (plist-get envelope :metadata))))

(defun supertag-change--legacy-subscriber-count ()
  "Return the current number of legacy `:store-changed' subscribers."
  (if (hash-table-p supertag--subscribers)
      (length (gethash :store-changed supertag--subscribers))
    0))

(defun supertag-change--assert-legacy-topic-available (callback)
  "Reject legacy subscription when CALLBACK already receives Canonical Change."
  (when (memq callback supertag-change--subscribers)
    (error "Callback cannot subscribe to both Canonical Change and :store-changed")))

(defun supertag-change-bridge-diagnostics ()
  "Return bounded counters for the temporary one-way legacy bridge."
  (list :legacy-subscriber-count
        (supertag-change--legacy-subscriber-count)
        :bridged-commit-count supertag-change--bridge-commit-count
        :total-path-count supertag-change--bridge-total-path-count
        :last-commit-path-count supertag-change--bridge-last-path-count))

(defun supertag-change-subscribe (callback)
  "Subscribe CALLBACK to committed Canonical Changes.
Return an idempotent function that unsubscribes CALLBACK."
  (unless (functionp callback)
    (error "Canonical Change subscriber must be callable"))
  (when (and (hash-table-p supertag--subscribers)
             (memq callback
                   (gethash :store-changed supertag--subscribers)))
    (error "Callback cannot subscribe to both Canonical Change and :store-changed"))
  (setq supertag-change--subscribers
        (append supertag-change--subscribers (list callback)))
  (let ((subscribed t))
    (lambda ()
      (when subscribed
        (setq subscribed nil)
        (setq supertag-change--subscribers
              (delq callback supertag-change--subscribers))))))

(defun supertag-change--deliver-canonical (change)
  "Deliver committed CHANGE to a stable snapshot of subscribers."
  (dolist (subscriber (copy-sequence supertag-change--subscribers))
    (condition-case cause
        (funcall subscriber change)
      (error
       (push (list :change-id (plist-get change :change-id)
                   :subscriber subscriber
                   :cause cause)
             supertag-change--subscriber-errors)
       (message "[supertag] Canonical Change subscriber failed: %s"
                (error-message-string cause))))))

(defun supertag-change--deliver-batch (batch)
  "Deliver private BATCH with Canonical Change before its legacy path events."
  (let* ((change (plist-get batch :change))
         (commit-record (plist-get batch :commit-record))
         (supertag-change--delivering-change-id
          (plist-get change :change-id)))
    (supertag-change--deliver-canonical change)
    (dolist (entry commit-record)
      (supertag-emit-event :store-changed
                           (plist-get entry :path)
                           (plist-get entry :old)
                           (plist-get entry :new)))))

(defun supertag-change--drain ()
  "Synchronously drain the Canonical Change FIFO without reentry."
  (unless supertag-change--dispatching
    (let ((supertag-change--dispatching t))
      (while supertag-change--queue
        (let ((batch (pop supertag-change--queue)))
          (supertag-change--deliver-batch batch))))))

(defun supertag-change--enqueue (change commit-record)
  "Append one committed CHANGE/COMMIT-RECORD batch to the delivery FIFO."
  (let ((path-count (length commit-record)))
    (cl-incf supertag-change--bridge-commit-count)
    (cl-incf supertag-change--bridge-total-path-count path-count)
    (setq supertag-change--bridge-last-path-count path-count)
    (when supertag-change-bridge-debug
      (message
       "[supertag] Legacy bridge commit %s: %d path event(s), %d subscriber(s)"
       (plist-get change :change-id)
       path-count
       (supertag-change--legacy-subscriber-count))))
  (setq supertag-change--queue
        (nconc supertag-change--queue
               (list (list :change change
                           :commit-record commit-record))))
  (supertag-change--drain))

(defun supertag-change-commit (envelope body)
  "Run BODY atomically and publish one Canonical Change for a real mutation.

ENVELOPE contains bounded domain metadata; raw Store diffs stay in a private,
short-lived CommitRecord.  This initial seam must own the outer transaction,
so invoking it from an already-active transaction is rejected.  A subscriber
may invoke it safely: the nested committed change joins the FIFO and is not
delivered until the current change finishes.  Return BODY's result."
  (supertag-change--validate-envelope envelope)
  (unless (functionp body)
    (error "Canonical Change body must be callable"))
  (when supertag--transaction-active
    (error "Canonical Change seam must own the outer transaction"))
  (let (commit-record result)
    (let ((supertag-change--suppress-legacy-store-changed t))
      (setq result
            (supertag-with-transaction
              (prog1 (funcall body)
                (setq commit-record
                      (supertag-change--capture-commit-record))))))
    (when commit-record
      (supertag-change--enqueue
       (supertag-change--make-change envelope)
       commit-record))
    result))

(provide 'supertag-core-store)

;;; supertag-core-store.el ends here
