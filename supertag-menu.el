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
;; - Business commands live in their owning modules, not in this file;
;;   optional targets may be unavailable. The declared feature wrappers
;;   below are used regardless of autoload cookies or main's require chain;
;;   direct migration actions expect the initialized session. Each thin
;;   `supertag-menu--*' wrapper registers a native
;;   autoload on first use when neither target nor owner is already present,
;;   then calls the target interactively. Menu-only loading installs no
;;   business-target bindings and loads no business features.
;; - An already loaded owner with an absent target reports "unavailable".
;;   Cold autoload failures keep their native error/quit; loading a file
;;   which does not define its advertised target is a native autoload error.


;; Commands: supertag-menu, supertag-menu-more, supertag-menu-write-more,
;; supertag-menu-organize-more, supertag-menu-find-more, supertag-menu-maintain-more;
;; supertag-menu--* target wrappers are local menu actions.
;; Dependencies: transient only at load time. Native-autoload targets: supertag-view-node,
;; supertag-view-stream, supertag-view-tags, supertag-tag, supertag-node, supertag-link, supertag-concept,
;; supertag-discovery, supertag-query, supertag-semantic, supertag-ai, supertag-services-sync,
;; supertag-git, supertag-automation, supertag-vault. Direct migration targets use
;; supertag-migrate in an initialized session; supertag-migrate-tag-ids remains a known
;; unavailable optional target.
;;; Code:

(require 'transient)

;;; --- Forward declarations ---
;; These commands live in other Supertag modules. None of those
;; modules are `require'd unconditionally here (to keep this file cheap
;; to load); each is either pulled in lazily by a wrapper below, or is
;; already guaranteed to be loaded by the time a real Supertag session
;; calls `supertag-menu' (see the module-by-module notes below).

;; supertag-view-node.el (no autoload cookie; wrapped)
(declare-function supertag-view-node "supertag-view-node" ())
(declare-function supertag-view-stream "supertag-view-stream" (&optional tag-id))

;; Tag, Node and Link commands (loaded through their feature wrappers)
;; Add Tag is owned by the Tag feature.
(declare-function supertag-add-tag "supertag-tag" (&optional beg end))
(declare-function supertag-remove-tag-from-node "supertag-tag" ())
;; Tag management is loaded lazily from its feature.
(declare-function supertag-tag-rename "supertag-tag" (&optional old-id new-name))
(declare-function supertag-delete-tag-everywhere "supertag-tag" (&optional tag-name))
(declare-function supertag-tag-set-parent "supertag-tag" (&optional tag-id parent-ids))
(declare-function supertag-view-tags "supertag-view-tags" ())
(declare-function supertag-find-node "supertag-node" (&optional other-window))
(declare-function supertag-add-link "supertag-link"
                  (&optional choose-target))
;; supertag-concept.el (Promote uses its feature wrapper below)
(declare-function supertag-promote "supertag-concept" (&optional template-key selected-node))

;; supertag-discovery.el (no autoload cookie; wrapped)
(declare-function supertag-discovery "supertag-discovery" ())
;; supertag-query.el (wrapped; build/describe also have autoload cookies)
(declare-function supertag-add-query-block "supertag-query" ())
(declare-function supertag-query-build "supertag-query" ())
(declare-function supertag-query-describe-syntax "supertag-query" ())

;; supertag-services-sync.el (maintenance commands use feature wrappers below)
(declare-function supertag-sync-cleanup-database "supertag-services-sync" ())
(declare-function supertag-sync-status "supertag-services-sync" ())
(declare-function supertag-sync-full-rescan "supertag-services-sync" ())

;; supertag-git.el (;;;###autoload, but NOT part of supertag.el's own
;; `require' chain; wrapped for robustness)
(declare-function supertag-git-setup "supertag-git" ())
(declare-function supertag-git-clone "supertag-git" (remote-url local-directory))
(declare-function supertag-git-sync-mode "supertag-git" (&optional arg))

;; supertag-migrate.el (required by supertag.el)
(declare-function supertag-migrate-preview "supertag-migrate" ())
(declare-function supertag-migrate-apply "supertag-migrate" ())
(declare-function supertag-migrate-status "supertag-migrate" ())
(declare-function supertag-migrate-run "supertag-migrate" ())
(declare-function supertag-migrate-tag-ids "supertag-migrate-tag-ids" ())

;; supertag-tag.el / supertag-concept.el (display toggles use feature wrappers below)
(declare-function supertag-toggle-tag-style "supertag-tag" ())
(declare-function supertag-mention-mode "supertag-concept" (&optional arg))

;; Setup and Automation commands are loaded by their feature wrappers below.
(declare-function supertag-setup "supertag-vault" ())
(declare-function supertag-automation-insert-template "supertag-automation" ())
(declare-function supertag-automation-list-templates "supertag-automation" ())

;;; --- Thin lazy-loading wrappers ---
;; Prefer an existing target binding, including an existing autoload.
;; Otherwise register an interactive autoload only when its owner is not
;; already loaded. `call-interactively' performs native lazy loading and
;; preserves prefix input; no loader failures are intercepted here.

(defmacro supertag-menu--defwrapper (name feature command doc)
  "Define NAME to call COMMAND interactively, autoloading from FEATURE if needed.
An existing target binding is authoritative. If FEATURE is already loaded
but COMMAND is absent, report it as unavailable. Otherwise native autoload
errors propagate unchanged. DOC is the generated wrapper's docstring."
  (declare (indent defun))
  `(defun ,name ()
     ,doc
     (interactive)
     (unless (or (fboundp ',command) (featurep ',feature))
       (autoload ',command ,(symbol-name feature) nil t))
     (unless (fboundp ',command)
       (user-error "Supertag command `%s' is unavailable" ',command))
     (call-interactively #',command)))

(supertag-menu--defwrapper supertag-menu--view-node
  supertag-view-node supertag-view-node
  "Open `supertag-view-node', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--view-stream
  supertag-view-stream supertag-view-stream
  "Open `supertag-view-stream', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--add-tag
  supertag-tag supertag-add-tag
  "Run `supertag-add-tag', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--remove-tag
  supertag-tag supertag-remove-tag-from-node
  "Run `supertag-remove-tag-from-node', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--rename-tag
  supertag-tag supertag-tag-rename
  "Run `supertag-tag-rename', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--delete-tag
  supertag-tag supertag-delete-tag-everywhere
  "Run `supertag-delete-tag-everywhere', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--set-tag-parent
  supertag-tag supertag-tag-set-parent
  "Run `supertag-tag-set-parent', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--view-tags
  supertag-view-tags supertag-view-tags
  "Open `supertag-view-tags', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--discovery
  supertag-discovery supertag-discovery
  "Run `supertag-discovery', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--add-query-block
  supertag-query supertag-add-query-block
  "Run `supertag-add-query-block', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--query-build
  supertag-query supertag-query-build
  "Run `supertag-query-build', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--query-describe-syntax
  supertag-query supertag-query-describe-syntax
  "Run `supertag-query-describe-syntax', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--semantic-rebuild
  supertag-semantic supertag-semantic-rebuild "Rebuild optional semantic candidates.")
(supertag-menu--defwrapper supertag-menu--semantic-status
  supertag-semantic supertag-semantic-status "Show semantic candidate status.")
(supertag-menu--defwrapper supertag-menu--semantic-stop
  supertag-semantic supertag-semantic-stop "Stop the current embedding round.")
(supertag-menu--defwrapper supertag-menu--semantic-resume
  supertag-semantic supertag-semantic-resume "Continue a stopped embedding rebuild.")
(supertag-menu--defwrapper supertag-menu--save-store
  supertag-core-persistence supertag-save-store "Save the current Store now.")
(supertag-menu--defwrapper supertag-menu--reload-store
  supertag-core-persistence supertag-reload-store "Reload the database from disk.")
(supertag-menu--defwrapper supertag-menu--save-store-force
  supertag-core-persistence supertag-save-store-force
  "Save the Store while intentionally overwriting a newer disk copy.")

(supertag-menu--defwrapper supertag-menu--extract-properties
  supertag-ai supertag-ai-extract-properties "Extract property candidates with AI.")

(supertag-menu--defwrapper supertag-menu--extract-tag-properties
  supertag-ai supertag-ai-extract-tag-properties
  "Extract property candidates for every node with a chosen tag, one at a time.")
(supertag-menu--defwrapper supertag-menu--cancel-extraction
  supertag-ai supertag-ai-cancel-extraction "Cancel the AI extraction for the node at point.")
(supertag-menu--defwrapper supertag-menu--cancel-batch
  supertag-ai supertag-ai-cancel-batch "Stop the running AI batch extraction.")

(supertag-menu--defwrapper supertag-menu--add-link
  supertag-link supertag-add-link
  "Add an ordinary or named link, loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--find-node
  supertag-node supertag-find-node
  "Run `supertag-find-node', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--promote
  supertag-concept supertag-promote
  "Promote the active region to a concept.")

(supertag-menu--defwrapper supertag-menu--sync-cleanup
  supertag-services-sync supertag-sync-cleanup-database
  "Clean stale projections from the database.")

(supertag-menu--defwrapper supertag-menu--sync-status
  supertag-services-sync supertag-sync-status
  "Show the current synchronization status.")

(supertag-menu--defwrapper supertag-menu--full-rescan
  supertag-services-sync supertag-sync-full-rescan
  "Rebuild Document Projections from a complete Org snapshot.")

(supertag-menu--defwrapper supertag-menu--git-setup
  supertag-git supertag-git-setup
  "Run `supertag-git-setup', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--git-clone
  supertag-git supertag-git-clone
  "Run `supertag-git-clone', loading its feature first if needed.")

(supertag-menu--defwrapper supertag-menu--git-sync-mode
  supertag-git supertag-git-sync-mode
  "Toggle `supertag-git-sync-mode', loading its feature first if needed.")


(supertag-menu--defwrapper supertag-menu--automation-insert-template
  supertag-automation supertag-automation-insert-template
  "Insert an automation template.")

(supertag-menu--defwrapper supertag-menu--automation-list-templates
  supertag-automation supertag-automation-list-templates
  "List the available automation templates.")

(supertag-menu--defwrapper supertag-menu--toggle-mentions
  supertag-concept supertag-mention-mode
  "Toggle dynamic concept-mention highlighting.")

(supertag-menu--defwrapper supertag-menu--setup
  supertag-vault supertag-setup
  "Open the guided Supertag setup wizard.")

(supertag-menu--defwrapper supertag-menu--migrate-tag-ids
  supertag-migrate-tag-ids supertag-migrate-tag-ids
  "Run `supertag-migrate-tag-ids', loading its feature first if needed.")

;;; --- The menu ---

;;;###autoload
(transient-define-prefix supertag-menu-write-more ()
  "Less-frequent commands for writing structured content."
  [["Query blocks"
    ("b" "Add query block"   supertag-menu--add-query-block)]
   ["References & concepts"
    ("p" "Promote with template" supertag-menu--promote)]
   ["Automation"
    ("t" "Insert automation template" supertag-menu--automation-insert-template)]
   ["AI"
    ("E" "Extract properties by tag (AI)" supertag-menu--extract-tag-properties)
    ("C" "Cancel extraction (AI)"         supertag-menu--cancel-extraction)
    ("B" "Cancel batch (AI)"              supertag-menu--cancel-batch)]])

;;;###autoload
(transient-define-prefix supertag-menu-organize-more ()
  "Less-frequent commands for reorganizing tags."
  [["Tags"
    ("r" "Rename tag everywhere" supertag-menu--rename-tag)
    ("D" "Delete tag everywhere" supertag-menu--delete-tag)
    ("P" "Set tag parent" supertag-menu--set-tag-parent)
    ("T" "Tag manager" supertag-menu--view-tags)]
   ])

;;;###autoload
(transient-define-prefix supertag-menu-find-more ()
  "Less-frequent commands for queries, views, and inspection."
  [["Queries"
    ("b" "Build query"       supertag-menu--query-build)
    ("h" "Query syntax help" supertag-menu--query-describe-syntax)]
   ["Additional views"
    ("s" "Stream view"                 supertag-menu--view-stream)]
   ["Display"
    ("c" "Toggle mentions" supertag-menu--toggle-mentions)]
   ])

;;;###autoload
(transient-define-prefix supertag-menu-maintain-more ()
  "Less-frequent commands for maintenance, automation, and migration."
  [["Data & setup"
    ("c" "Cleanup database" supertag-menu--sync-cleanup)
    ("s" "Setup wizard"     supertag-menu--setup)
    ("er" "Rebuild similar notes" supertag-menu--semantic-rebuild)
    ("es" "Similarity status" supertag-menu--semantic-status)
    ("ec" "Continue embeddings" supertag-menu--semantic-resume)
    ("ex" "Stop embeddings" supertag-menu--semantic-stop)
    ("ed" "Save database now" supertag-menu--save-store)
    ("el" "Reload database from disk" supertag-menu--reload-store)
    ("ef" "Save database, overwriting newer disk copy" supertag-menu--save-store-force)]
   ["Git"
    ("gs" "Setup git sync"    supertag-menu--git-setup)
    ("gc" "Clone vault"       supertag-menu--git-clone)
    ("gm" "Toggle sync mode"  supertag-menu--git-sync-mode)]
   ["Automation"
    ("al" "List templates"       supertag-menu--automation-list-templates)]
   ["Migration"
    ("mp" "Preview migration" supertag-migrate-preview)
    ("ma" "Apply migration" supertag-migrate-apply)
    ("ms" "Migration status" supertag-migrate-status)
    ("mr" "Run data migration" supertag-migrate-run)
    ("mt" "Migrate tag IDs"          supertag-menu--migrate-tag-ids)]])

;;;###autoload
(transient-define-prefix supertag-menu ()
  "Open Supertag commands grouped by the user's current task."
  [["记录 Capture & Write"
    ("l" "Add link" supertag-menu--add-link)
    ("e" "Extract properties (AI)" supertag-menu--extract-properties)
    ("w" "More writing..."          supertag-menu-write-more)]
   ["整理 Organize"
    ("g" "Add tag"               supertag-menu--add-tag)
    ("r" "Remove tag from node"  supertag-menu--remove-tag)
    ("o" "More organize..."      supertag-menu-organize-more)]
   ["查找 Find & View"
    ("s" "Discovery"           supertag-menu--discovery)
    ("n" "Find node"           supertag-menu--find-node)
    ("v" "Node view"           supertag-menu--view-node)
    ("V" "More find & view..." supertag-menu-find-more)]
   ["维护 Maintain"
    ("u" "Sync status"         supertag-menu--sync-status)
    ("x" "Full rescan"         supertag-menu--full-rescan)
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
