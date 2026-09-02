;;; supertag-menu.el --- Discoverable transient menu for Supertag -*- lexical-binding: t; -*-

;; Keywords: convenience

;;; Commentary:

;; `supertag-menu' is a single entry point that surfaces the most useful
;; Supertag commands in one discoverable `transient' pop-up, so users
;; do not have to hunt through `M-x' to remember command names.
;;
;; `transient' has shipped with Emacs since 28.1, so this file adds no new
;; dependency.
;;
;; Design notes:
;; - The top level follows four user tasks: Capture & Write, Organize,
;;   Find & View, and Maintain.  Each column keeps daily commands visible
;;   and sends specialized operations to a task-specific secondary menu.
;; - Top-level keys are short and unique; lowercase "q" is left untouched
;;   so `transient's default quit binding keeps working.
;; - Every command referenced here already exists elsewhere in
;;   Supertag; none are (re)defined in this file. Commands whose
;;   owning feature carries an `;;;###autoload' cookie (or is guaranteed
;;   to already be loaded as part of Supertag's own core `require'
;;   chain) are wired directly by symbol. Commands whose owning feature
;;   is NOT unconditionally loaded (or has no autoload cookie) are wired
;;   through a thin `supertag-menu--*' wrapper that `require's the owning
;;   feature before calling the real command interactively, so the menu
;;   works regardless of what has been loaded so far.
;; - Every suffix names a command defined after this feature loads.  Lazy
;;   wrappers additionally verify their target after loading its feature,
;;   so a stale menu entry fails as "unavailable" rather than as a void
;;   function.

;;; Code:

(require 'transient)

;;; --- Forward declarations ---
;; These commands live in other Supertag modules. None of those
;; modules are `require'd unconditionally here (to keep this file cheap
;; to load); each is either pulled in lazily by a wrapper below, or is
;; already guaranteed to be loaded by the time a real Supertag session
;; calls `supertag-menu' (see the module-by-module notes below).

;; supertag-view-table.el (no autoload cookie; wrapped)
(declare-function supertag-view-table "supertag-view-table" (data-source &optional columns view-config named-views))
;; supertag-ui-commands.el (no autoload cookie; wrapped)
(declare-function supertag-view-kanban "supertag-ui-commands" ())
;; supertag-view-node.el (no autoload cookie; wrapped)
(declare-function supertag-view-node "supertag-view-node" ())
(declare-function supertag-view-stream "supertag-view-stream" (&optional tag-id))
;; supertag-view-schema.el (;;;###autoload; also unconditionally required
;; by supertag.el, so it is safe to reference directly)
(declare-function supertag-view-schema "supertag-view-schema" ())
;; supertag-board.el (;;;###autoload; optional feature, requires the
;; external `websocket' package; guarded with :if fboundp below)
(declare-function supertag-board-mode "supertag-board" (&optional arg))
(autoload 'supertag-board-mode "supertag-board" nil t)
;; supertag-graph-ui.el (;;;###autoload; optional feature, requires the
;; external `websocket' package; guarded with :if fboundp below)
(declare-function supertag-graph-ui-open "supertag-graph-ui" ())
(autoload 'supertag-graph-ui-open "supertag-graph-ui" nil t)

;; supertag-ui-commands.el (no autoload cookies; all wrapped)
(declare-function supertag-add-tag "supertag-ui-commands" (&optional beg end))
(declare-function supertag-remove-tag-from-node "supertag-ui-commands" ())
(declare-function supertag-change-tag-at-point "supertag-ui-commands" ())
(declare-function supertag-rename-tag "supertag-ui-commands" (&optional tag-id))
(declare-function supertag-delete-tag-everywhere "supertag-ui-commands" (&optional tag-id))
(declare-function supertag-ui-quick-edit-field "supertag-ui-commands" ())
(declare-function supertag-edit-fields "supertag-ui-commands" (&optional node-id tag-id))
(declare-function supertag-find-node "supertag-ui-commands" ())
(declare-function supertag-reference-insert "supertag-ui-reference"
                  (&optional choose-target))
(declare-function supertag-insert-embed "supertag-ui-commands" ())
(declare-function supertag-convert-link-to-embed "supertag-ui-commands" ())
(declare-function supertag-capture "supertag-ui-commands" (&optional target-file headline))
(declare-function supertag-act "supertag-ui-act" ())

;; supertag-ui-link.el (small typed-Link workflow; wrapped)
(declare-function supertag-link-add "supertag-ui-link" (&optional node-id))
(declare-function supertag-link-remove "supertag-ui-link" (&optional node-id))
(declare-function supertag-link-menu "supertag-ui-link" ())

;; supertag-concept.el (;;;###autoload; also unconditionally required by
;; supertag.el, so it is safe to reference directly)
(declare-function supertag-promote-concept "supertag-concept" (beg end))

;; supertag-ui-search.el (no autoload cookie; wrapped)
(declare-function supertag-search "supertag-ui-search" ())
;; supertag-ui-query-block.el (no autoload cookie; wrapped)
(declare-function supertag-insert-query-block "supertag-ui-query-block" ())
(declare-function supertag-insert-query-dblock "supertag-ui-query-block" ())
(declare-function supertag-query-build "supertag-query-library" ())
(declare-function supertag-query-run-saved "supertag-query-library" ())
(declare-function supertag-query-describe-syntax "supertag-query-library" ())

;; supertag-view-ontology-migration.el (optional control-plane UI; wrapped)
(declare-function supertag-ontology-migration-preview
                  "supertag-view-ontology-migration" (&optional name))
(declare-function supertag-ontology-migration-apply
                  "supertag-view-ontology-migration" (&optional name))
(declare-function supertag-ontology-migration-status
                  "supertag-view-ontology-migration" (&optional module))
(declare-function supertag-ontology-migration-goto-definition
                  "supertag-view-ontology-migration" (&optional name))

;; supertag-ui-tool.el (transient, provider-neutral LLM tool catalog)
(declare-function supertag-ui-tool-list "supertag-ui-tool" (&optional actor))
(declare-function supertag-ui-tool-copy-catalog-json
                  "supertag-ui-tool" (&optional pretty))

;; supertag-services-capture.el (;;;###autoload; also unconditionally
;; required by supertag.el, so it is safe to reference directly)
(declare-function supertag-capture-with-template "supertag-services-capture" (&optional template-key))

;; supertag-ui-commands.el / supertag-services-sync.el (;;;###autoload;
;; unconditionally required by supertag.el, so it is safe to
;; reference these directly)
(declare-function supertag-sync-check-now "supertag-ui-commands" ())
(declare-function supertag-sync-cleanup-database "supertag-ui-commands" ())
(declare-function supertag-sync-status "supertag-ui-commands" ())
(declare-function supertag-reindex-org "supertag-services-sync" ())

;; supertag-doctor.el (;;;###autoload, but NOT part of supertag.el's
;; own `require' chain; wrapped for robustness)
(declare-function supertag-doctor "supertag-doctor" (&optional report-only))
;; supertag-core-persistence.el (no autoload cookie; wrapped)
(declare-function supertag-db-retry-lock "supertag-core-persistence" ())
;; supertag-core-persistence.el (owned by a teammate; `supertag-restore'
;; is developed alongside this iteration too, so it is wrapped exactly
;; like `supertag-db-retry-lock' above rather than assumed present)
(declare-function supertag-restore "supertag-core-persistence" ())

;; supertag-git.el (;;;###autoload, but NOT part of supertag.el's own
;; `require' chain; wrapped for robustness, same as `supertag-doctor')
(declare-function supertag-git-setup "supertag-git" ())
(declare-function supertag-git-clone "supertag-git" (remote-url local-directory))
(declare-function supertag-git-sync-mode "supertag-git" (&optional arg))

;; supertag-conflicts.el (;;;###autoload; also unconditionally required by
;; supertag.el, so it is safe to reference directly)
(declare-function supertag-conflicts-resolve "supertag-conflicts" ())
(declare-function supertag-conflicts-use-ours-all "supertag-conflicts" ())
(declare-function supertag-conflicts-use-theirs-all "supertag-conflicts" ())

;; supertag-automation-sync.el / supertag-automation.el (no autoload
;; cookie; unconditionally required by supertag.el, but wrapped
;; anyway since Supertag's own menu entries for this file wrap every
;; non-autoloaded command)
(declare-function supertag-automation-sync-enable "supertag-automation-sync" ())
(declare-function supertag-automation-sync-disable "supertag-automation-sync" ())
(declare-function supertag-automation-recalculate-all-rollups "supertag-automation" ())
;; supertag-services-scheduler.el (no autoload cookie; wrapped)
(declare-function supertag-scheduler-start "supertag-services-scheduler" ())
(declare-function supertag-scheduler-stop "supertag-services-scheduler" ())
(declare-function supertag-scheduler-list-tasks "supertag-services-scheduler" ())

;; supertag-virtual-column.el (no autoload cookie; wrapped)
(declare-function supertag-virtual-column-create-interactive "supertag-virtual-column" ())
(declare-function supertag-virtual-column-edit-interactive "supertag-virtual-column" ())
(declare-function supertag-virtual-column-delete-interactive "supertag-virtual-column" ())
(declare-function supertag-virtual-column-list-interactive "supertag-virtual-column" ())

;; supertag-migration.el (;;;###autoload; also unconditionally required by
;; supertag.el, so it is safe to reference directly)
(declare-function supertag-migrate-database-to-new-arch "supertag-migration" ())
(declare-function supertag-batch-convert-properties-to-fields "supertag-migration" ())
(declare-function supertag-migration-add-ids-to-org-headings "supertag-migration" (directory))
(declare-function supertag-migration-preview-reciprocal-links "supertag-migration" (&optional displayp))
(declare-function supertag-migrate-reciprocal-links "supertag-migration" ())
;; supertag-migrate-tag-ids.el (no autoload cookie; NOT part of
;; supertag.el's own `require' chain; wrapped)
(declare-function supertag-migrate-tag-ids "supertag-migrate-tag-ids" ())

;; supertag-view-svg-tag.el / supertag-concept.el (;;;###autoload; also
;; unconditionally required by supertag.el, so it is safe to
;; reference these directly)
(declare-function supertag-svg-tag-mode-toggle "supertag-view-svg-tag" ())
(declare-function supertag-concept-link-mode "supertag-concept" (&optional arg))

;; supertag-setup.el and supertag-automation-templates.el are developed
;; alongside this file; guard every reference with `fboundp' and never
;; `require' them directly from here.
(declare-function supertag-setup "supertag-setup" ())
(declare-function supertag-automation-insert-template "supertag-automation-templates" ())
(declare-function supertag-automation-list-templates "supertag-automation-templates" ())

;;; --- Thin lazy-loading wrappers ---
;; Each wrapper `require's the owning feature (safe: these files have no
;; load-time side effects of their own -- unlike `supertag.el', which
;; runs `supertag-init' at load time) and then calls the real, already
;;-interactive command. This keeps `supertag-menu' usable even when only
;; part of Supertag has been loaded so far.

(defmacro supertag-menu--defwrapper (name feature command doc)
  "Define NAME as a command that `require's FEATURE, then calls COMMAND.
DOC is used as the docstring of the generated wrapper."
  (declare (indent defun))
  `(defun ,name ()
     ,doc
     (interactive)
     (require ',feature)
     (unless (fboundp ',command)
       (user-error "Supertag command `%s' is unavailable" ',command))
     (call-interactively #',command)))

(supertag-menu--defwrapper supertag-menu--view-table
  supertag-view-table supertag-view-table
  "Open `supertag-view-table', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--view-kanban
  supertag-ui-commands supertag-view-kanban
  "Open `supertag-view-kanban', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--view-node
  supertag-view-node supertag-view-node
  "Open `supertag-view-node', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--view-stream
  supertag-view-stream supertag-view-stream
  "Open `supertag-view-stream', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--view-schema
  supertag-view-schema supertag-view-schema
  "Open `supertag-view-schema', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--act
  supertag-ui-act supertag-act
  "Open context actions for the object at point.")

(supertag-menu--defwrapper supertag-menu--add-tag
  supertag-ui-commands supertag-add-tag
  "Run `supertag-add-tag', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--remove-tag
  supertag-ui-commands supertag-remove-tag-from-node
  "Run `supertag-remove-tag-from-node', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--change-tag
  supertag-ui-commands supertag-change-tag-at-point
  "Run `supertag-change-tag-at-point', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--rename-tag
  supertag-ui-commands supertag-rename-tag
  "Run `supertag-rename-tag', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--delete-tag
  supertag-ui-commands supertag-delete-tag-everywhere
  "Run `supertag-delete-tag-everywhere', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--quick-edit-field
  supertag-ui-commands supertag-ui-quick-edit-field
  "Run `supertag-ui-quick-edit-field', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--edit-fields
  supertag-ui-commands supertag-edit-fields
  "Edit all fields for the current node in one continuous pass.")

(supertag-menu--defwrapper supertag-menu--search
  supertag-ui-search supertag-search
  "Run `supertag-search', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--insert-query-block
  supertag-ui-query-block supertag-insert-query-block
  "Run `supertag-insert-query-block', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--insert-query-dblock
  supertag-ui-query-block supertag-insert-query-dblock
  "Run `supertag-insert-query-dblock', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--query-build
  supertag-query-library supertag-query-build
  "Run `supertag-query-build', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--query-run-saved
  supertag-query-library supertag-query-run-saved
  "Run `supertag-query-run-saved', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--query-describe-syntax
  supertag-query-library supertag-query-describe-syntax
  "Run `supertag-query-describe-syntax', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--ontology-migration-preview
  supertag-view-ontology-migration supertag-ontology-migration-preview
  "Preview one registered Ontology migration without mutating the Store.")

(supertag-menu--defwrapper supertag-menu--ontology-migration-apply
  supertag-view-ontology-migration supertag-ontology-migration-apply
  "Preview again and atomically apply one registered Ontology migration.")

(supertag-menu--defwrapper supertag-menu--ontology-migration-status
  supertag-view-ontology-migration supertag-ontology-migration-status
  "Show the Store-owned applied Ontology migration ledger.")

(supertag-menu--defwrapper supertag-menu--ontology-migration-goto
  supertag-view-ontology-migration supertag-ontology-migration-goto-definition
  "Visit the source declaration of one registered Ontology migration.")

(supertag-menu--defwrapper supertag-menu--ontology-tool-list
  supertag-ui-tool supertag-ui-tool-list
  "Inspect the transient Policy-aware LLM tool catalog.")

(supertag-menu--defwrapper supertag-menu--ontology-tool-copy-json
  supertag-ui-tool supertag-ui-tool-copy-catalog-json
  "Copy the provider-neutral LLM tool catalog as JSON.")

(supertag-menu--defwrapper supertag-menu--insert-embed
  supertag-ui-commands supertag-insert-embed
  "Run `supertag-insert-embed', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--convert-link-to-embed
  supertag-ui-commands supertag-convert-link-to-embed
  "Run `supertag-convert-link-to-embed', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--add-reference
  supertag-ui-reference supertag-reference-insert
  "Create or link a reference, loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--find-node
  supertag-ui-commands supertag-find-node
  "Run `supertag-find-node', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--link-add
  supertag-ui-link supertag-link-add
  "Add a typed Link from the current node.")

(supertag-menu--defwrapper supertag-menu--link-remove
  supertag-ui-link supertag-link-remove
  "Remove a typed Link touching the current node.")

(supertag-menu--defwrapper supertag-menu--link-menu
  supertag-ui-link supertag-link-menu
  "Open the typed-Link action menu for the current node.")

(supertag-menu--defwrapper supertag-menu--capture
  supertag-ui-commands supertag-capture
  "Run `supertag-capture', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--capture-with-template
  supertag-services-capture supertag-capture-with-template
  "Capture a node with a reusable template.")

(supertag-menu--defwrapper supertag-menu--promote-concept
  supertag-concept supertag-promote-concept
  "Promote the active region to a concept.")

(supertag-menu--defwrapper supertag-menu--doctor
  supertag-doctor supertag-doctor
  "Run `supertag-doctor', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--db-retry-lock
  supertag-core-persistence supertag-db-retry-lock
  "Run `supertag-db-retry-lock', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--restore
  supertag-core-persistence supertag-restore
  "Run `supertag-restore', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--sync-check
  supertag-ui-commands supertag-sync-check-now
  "Check for changed Org files and synchronize them now.")

(supertag-menu--defwrapper supertag-menu--sync-cleanup
  supertag-ui-commands supertag-sync-cleanup-database
  "Clean stale projections from the database.")

(supertag-menu--defwrapper supertag-menu--sync-status
  supertag-ui-commands supertag-sync-status
  "Show the current synchronization status.")

(supertag-menu--defwrapper supertag-menu--reindex
  supertag-services-sync supertag-reindex-org
  "Rebuild Document Projections from Org files.")

(supertag-menu--defwrapper supertag-menu--git-setup
  supertag-git supertag-git-setup
  "Run `supertag-git-setup', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--git-clone
  supertag-git supertag-git-clone
  "Run `supertag-git-clone', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--git-sync-mode
  supertag-git supertag-git-sync-mode
  "Toggle `supertag-git-sync-mode', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--conflicts-resolve
  supertag-conflicts supertag-conflicts-resolve
  "Open the conflict-resolution workflow.")

(supertag-menu--defwrapper supertag-menu--conflicts-use-ours
  supertag-conflicts supertag-conflicts-use-ours-all
  "Resolve every conflict using the local side.")

(supertag-menu--defwrapper supertag-menu--conflicts-use-theirs
  supertag-conflicts supertag-conflicts-use-theirs-all
  "Resolve every conflict using the incoming side.")

(supertag-menu--defwrapper supertag-menu--automation-sync-enable
  supertag-automation-sync supertag-automation-sync-enable
  "Run `supertag-automation-sync-enable', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--automation-sync-disable
  supertag-automation-sync supertag-automation-sync-disable
  "Run `supertag-automation-sync-disable', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--automation-recalculate-all-rollups
  supertag-automation supertag-automation-recalculate-all-rollups
  "Run `supertag-automation-recalculate-all-rollups', loading its feature
first if needed.")

(supertag-menu--defwrapper supertag-menu--scheduler-start
  supertag-services-scheduler supertag-scheduler-start
  "Run `supertag-scheduler-start', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--scheduler-stop
  supertag-services-scheduler supertag-scheduler-stop
  "Run `supertag-scheduler-stop', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--scheduler-list-tasks
  supertag-services-scheduler supertag-scheduler-list-tasks
  "Run `supertag-scheduler-list-tasks', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--automation-insert-template
  supertag-automation-templates supertag-automation-insert-template
  "Insert an automation template.")

(supertag-menu--defwrapper supertag-menu--automation-list-templates
  supertag-automation-templates supertag-automation-list-templates
  "List the available automation templates.")

(supertag-menu--defwrapper supertag-menu--virtual-column-create
  supertag-virtual-column supertag-virtual-column-create-interactive
  "Run `supertag-virtual-column-create-interactive', loading its feature
first if needed.")

(supertag-menu--defwrapper supertag-menu--virtual-column-edit
  supertag-virtual-column supertag-virtual-column-edit-interactive
  "Run `supertag-virtual-column-edit-interactive', loading its feature
first if needed.")

(supertag-menu--defwrapper supertag-menu--virtual-column-delete
  supertag-virtual-column supertag-virtual-column-delete-interactive
  "Run `supertag-virtual-column-delete-interactive', loading its feature
first if needed.")

(supertag-menu--defwrapper supertag-menu--virtual-column-list
  supertag-virtual-column supertag-virtual-column-list-interactive
  "Run `supertag-virtual-column-list-interactive', loading its feature
first if needed.")

(supertag-menu--defwrapper supertag-menu--toggle-svg-tags
  supertag-view-svg-tag supertag-svg-tag-mode-toggle
  "Toggle SVG rendering for inline tags.")

(supertag-menu--defwrapper supertag-menu--toggle-concept-links
  supertag-concept supertag-concept-link-mode
  "Toggle dynamic concept-mention highlighting.")

(supertag-menu--defwrapper supertag-menu--setup
  supertag-setup supertag-setup
  "Open the guided Supertag setup wizard.")

(supertag-menu--defwrapper supertag-menu--migrate-database
  supertag-migration supertag-migrate-database-to-new-arch
  "Migrate the database to the current architecture.")

(supertag-menu--defwrapper supertag-menu--migrate-properties
  supertag-migration supertag-batch-convert-properties-to-fields
  "Convert legacy Org properties to Supertag fields.")

(supertag-menu--defwrapper supertag-menu--migrate-add-ids
  supertag-migration supertag-migration-add-ids-to-org-headings
  "Add IDs to Org headings during migration.")

(supertag-menu--defwrapper supertag-menu--migrate-preview-links
  supertag-migration supertag-migration-preview-reciprocal-links
  "Preview reciprocal-link migration.")

(supertag-menu--defwrapper supertag-menu--migrate-links
  supertag-migration supertag-migrate-reciprocal-links
  "Migrate reciprocal links.")

(supertag-menu--defwrapper supertag-menu--migrate-tag-ids
  supertag-migrate-tag-ids supertag-migrate-tag-ids
  "Run `supertag-migrate-tag-ids', loading its feature first if needed.")

;;; --- The menu ---

;;;###autoload
(transient-define-prefix supertag-menu-write-more ()
  "Less-frequent commands for writing structured content."
  [["Query blocks"
    ("b" "Insert query block"   supertag-menu--insert-query-block)
    ("d" "Insert dynamic query" supertag-menu--insert-query-dblock)]
   ["References & concepts"
    ("c" "Convert link to embed" supertag-menu--convert-link-to-embed)
    ("p" "Promote selection to concept" supertag-menu--promote-concept)]
   ["Automation"
    ("t" "Insert automation template" supertag-menu--automation-insert-template)]])

;;;###autoload
(transient-define-prefix supertag-menu-organize-more ()
  "Less-frequent commands for reorganizing tags, fields, and Links."
  [["Tags & schema"
    ("c" "Change tag on node"    supertag-menu--change-tag)
    ("r" "Rename tag everywhere" supertag-menu--rename-tag)
    ("D" "Delete tag everywhere" supertag-menu--delete-tag)
    ("s" "Open schema"           supertag-menu--view-schema)]
   ["Typed Links"
    ("a" "Add typed Link"    supertag-menu--link-add)
    ("d" "Remove typed Link" supertag-menu--link-remove)]
   ["Virtual columns"
    ("vc" "Create" supertag-menu--virtual-column-create)
    ("ve" "Edit"   supertag-menu--virtual-column-edit)
    ("vd" "Delete" supertag-menu--virtual-column-delete)
    ("vl" "List"   supertag-menu--virtual-column-list)]])

;;;###autoload
(transient-define-prefix supertag-menu-find-more ()
  "Less-frequent commands for queries, views, and inspection."
  [["Queries"
    ("b" "Build query"       supertag-menu--query-build)
    ("r" "Run saved query"   supertag-menu--query-run-saved)
    ("h" "Query syntax help" supertag-menu--query-describe-syntax)]
   ["Additional views"
    ("s" "Stream view"                 supertag-menu--view-stream)
    ("w" "Whiteboard"                  supertag-board-mode
     :if (lambda () (fboundp 'supertag-board-mode)))
    ("G" "Graph UI"                    supertag-graph-ui-open
     :if (lambda () (fboundp 'supertag-graph-ui-open)))]
   ["Display"
    ("t" "Toggle SVG tags"      supertag-menu--toggle-svg-tags)
    ("c" "Toggle concept links" supertag-menu--toggle-concept-links)]
   ["LLM tools"
    ("l" "Inspect catalog"   supertag-menu--ontology-tool-list)
    ("j" "Copy catalog JSON" supertag-menu--ontology-tool-copy-json)]])

;;;###autoload
(transient-define-prefix supertag-menu-maintain-more ()
  "Less-frequent commands for maintenance, automation, and migration."
  [["Data & setup"
    ("c" "Cleanup database" supertag-menu--sync-cleanup)
    ("l" "Retry DB lock"    supertag-menu--db-retry-lock)
    ("s" "Setup wizard"     supertag-menu--setup)]
   ["Git & conflicts"
    ("gs" "Setup git sync"    supertag-menu--git-setup)
    ("gc" "Clone vault"       supertag-menu--git-clone)
    ("gm" "Toggle sync mode"  supertag-menu--git-sync-mode)
    ("gr" "Resolve conflicts" supertag-menu--conflicts-resolve)
    ("go" "Use ours (all)"    supertag-menu--conflicts-use-ours)
    ("gt" "Use theirs (all)"  supertag-menu--conflicts-use-theirs)]
   ["Automation"
    ("al" "List templates"       supertag-menu--automation-list-templates)
    ("ae" "Enable auto-sync"     supertag-menu--automation-sync-enable)
    ("ad" "Disable auto-sync"    supertag-menu--automation-sync-disable)
    ("ar" "Recalculate rollups"  supertag-menu--automation-recalculate-all-rollups)
    ("as" "Start scheduler"      supertag-menu--scheduler-start)
    ("ax" "Stop scheduler"       supertag-menu--scheduler-stop)
    ("at" "List scheduled tasks" supertag-menu--scheduler-list-tasks)]
   ["Ontology migration"
    ("op" "Preview plan"      supertag-menu--ontology-migration-preview)
    ("oa" "Apply migration"   supertag-menu--ontology-migration-apply)
    ("os" "Applied status"    supertag-menu--ontology-migration-status)
    ("og" "Go to declaration" supertag-menu--ontology-migration-goto)]
   ["Legacy migration"
    ("md" "Migrate database"         supertag-menu--migrate-database)
    ("mp" "Properties to fields"     supertag-menu--migrate-properties)
    ("mi" "Add IDs to headings"      supertag-menu--migrate-add-ids)
    ("mr" "Preview reciprocal links" supertag-menu--migrate-preview-links)
    ("mx" "Migrate reciprocal links" supertag-menu--migrate-links)
    ("mt" "Migrate tag IDs"          supertag-menu--migrate-tag-ids)]])

;;;###autoload
(transient-define-prefix supertag-menu ()
  "Open Supertag commands grouped by the user's current task."
  [["记录 Capture & Write"
    ("c" "Capture"                  supertag-menu--capture)
    ("t" "Capture with template"    supertag-menu--capture-with-template)
    ("l" "Create or link reference" supertag-menu--add-reference)
    ("e" "Edit fields (whole page)" supertag-menu--edit-fields)
    ("i" "Insert embed"             supertag-menu--insert-embed)
    ("w" "More writing..."          supertag-menu-write-more)]
   ["整理 Organize"
    ("a" "Act at point..."       supertag-menu--act)
    ("g" "Add tag"               supertag-menu--add-tag)
    ("r" "Remove tag from node"  supertag-menu--remove-tag)
    ("f" "Quick edit one field"  supertag-menu--quick-edit-field)
    ("k" "Typed Link actions..." supertag-menu--link-menu)
    ("o" "More organize..."      supertag-menu-organize-more)]
   ["查找 Find & View"
    ("s" "Search"              supertag-menu--search)
    ("n" "Find node"           supertag-menu--find-node)
    ("v" "Node view"           supertag-menu--view-node)
    ("b" "Table view"          supertag-menu--view-table)
    ("j" "Kanban board"        supertag-menu--view-kanban)
    ("V" "More find & view..." supertag-menu-find-more)]
   ["维护 Maintain"
    ("d" "Doctor"              supertag-menu--doctor)
    ("y" "Check & sync now"    supertag-menu--sync-check)
    ("u" "Sync status"         supertag-menu--sync-status)
    ("R" "Restore from backup" supertag-menu--restore)
    ("x" "Reindex Org"         supertag-menu--reindex)
    ("M" "More maintenance..." supertag-menu-maintain-more)]])

;;;###autoload
(transient-define-prefix supertag-menu-more ()
  "Compatibility index for the task-specific secondary menus."
  [["More by task"
    ("w" "Capture & Write" supertag-menu-write-more)
    ("o" "Organize"        supertag-menu-organize-more)
    ("f" "Find & View"     supertag-menu-find-more)
    ("m" "Maintain"        supertag-menu-maintain-more)]])

(provide 'supertag-menu)

;;; supertag-menu.el ends here
