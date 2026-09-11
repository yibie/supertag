;;; supertag.el --- Semantic knowledge system for Org mode -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Yibie

;; Author: Yibie
;; Keywords: org-mode, tags, metadata, workflow, automation
;; Version: 6.0.0
;; URL: https://github.com/yibie/supertag

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Supertag is a semantic knowledge system for Org mode that extends the
;; traditional tagging capabilities with advanced features

;; Package-Requires: ((emacs "29.1") (org "9.6") (ht "2.4"))


;; Commands: supertag-init; startup/exit/Org hooks assemble existing owner entrypoints.
;; Dependencies: cl-lib, org, org-id, subr-x, supertag-vault, ht, supertag-core-store,
;; supertag-query, supertag-core-persistence, supertag-node, supertag-tag, supertag-automation,
;; supertag-services-sync, supertag-link, supertag-mention, supertag-api, supertag-discovery,
;; supertag-view-framework, supertag-concept, supertag-view-node, supertag-view-stream,
;; supertag-ai, supertag-semantic, supertag-embark, supertag-migrate. Lazy Doctor and Git
;; entrypoints: supertag-doctor, supertag-git. ServiceOrg arrives through Node; Menu is a
;; separately loaded optional entrypoint. External superchat and Embark remain optional; Semantic
;; requests require explicit configuration.
;;; Code:


(require 'cl-lib)
(require 'org)
(require 'org-id)
(require 'subr-x)
(require 'supertag-vault)
(defvar supertag-sync-directories-mode)
(defvar supertag--store-origin)
(defvar supertag--config-guard-allow)

(defgroup supertag nil
  "Core configuration for Supertag."
  :group 'org)

(supertag-vault--prepare-configuration)

(defcustom supertag-file-id-source 'org-roam
  "Policy for recognizing stable file node IDs.
- `org-roam' => require :ID: in the top-level :PROPERTIES: drawer
- `denote'   => require a #+IDENTIFIER: keyword
- `auto'     => prefer a top-level :ID:, then #+IDENTIFIER:
- `disabled' => do not create file nodes

Files without the selected persistent identity remain ordinary Org files."
  :type '(choice (const :tag "org-roam (:PROPERTIES: :ID:)" org-roam)
                 (const :tag "denote (#+IDENTIFIER:)" denote)
                 (const :tag "auto-detect either identity" auto)
                 (const :tag "disable file nodes" disabled))
  :group 'supertag)

(supertag-vault--prepare-indicator)

(defvar supertag--initialized nil
  "Non-nil after `supertag-init` completes.")

(supertag-vault--prepare-guard-defaults)





;;;###autoload (autoload 'supertag--effective-sync-directories "supertag" "Return effective sync directories for the current session.\n\nIn vault mode, returns a single-element list containing the active vault root.\nOtherwise, returns `supertag-sync-directories` unchanged." nil)
(supertag-vault--prepare-effective-wrappers)















(defcustom supertag-project-root
  (file-name-directory (file-name-directory (or load-file-name buffer-file-name)))
  "The root directory of the supertag project."
  :type 'directory
  :group 'supertag)

;; --- Core Components ---
(require 'ht) ; Ensure ht is loaded before other modules that might depend on it
(require 'supertag-core-store)
(require 'supertag-query)
(require 'supertag-core-persistence)

;; --- Entity Operations (ops) ---
(require 'supertag-node)
(require 'supertag-tag)

;; --- Automation System ---
(require 'supertag-automation)

;; --- Service Functions (services) ---
(require 'supertag-services-sync)
(require 'supertag-link)
(require 'supertag-mention)

;; --- Agent-facing plain-data API (callee surface for bridges) ---
(require 'supertag-api)


;; --- User Interface (ui) ---
(require 'supertag-discovery)

;; --- View ---
(require 'supertag-view-framework)
;; (require 'supertag-view-examples-simple)
(require 'supertag-concept)
(require 'supertag-view-node)
(require 'supertag-view-stream)
(require 'supertag-view-tags)
(require 'supertag-ai)
(require 'supertag-semantic)
(require 'supertag-embark)

;; --- RAG ---
;; (archived: supertag-rag, supertag-ui-chat — moved to archive/)

 ;; --- Version gated migration ---
(require 'supertag-migrate)

;; --- Diagnostics (optional) ---
(autoload 'supertag-doctor "supertag-doctor"
  "Run Supertag health checks and guided repairs." nil)

;; --- Git sync (optional) ---
;; Keep the documented M-x commands discoverable even when Supertag is
;; loaded directly from source and no package-generated autoload file exists.
(autoload 'supertag-git-setup "supertag-git"
  "Configure Git sync for the current Supertag vault." t)
(autoload 'supertag-git-clone "supertag-git"
  "Clone and configure an Supertag Git vault." t)
(autoload 'supertag-git-sync-mode "supertag-git"
  "Toggle automatic Git synchronization for the current vault." t)
(autoload 'supertag-git-sync-now "supertag-git"
  "Synchronize the current Supertag Git vault immediately." t)

;; --- Initialization ---
(defun supertag-init ()
 "Initialize the Supertag system.
This function loads all necessary components and sets up the environment."
    (interactive)

    ;; Step 0: Refuse ambiguous legacy/default data roots before any IO.
    (supertag-persistence-check-legacy-data-directory)

    ;; Step 1: Select default vault (if configured) before any IO.
    (supertag-vault--select-startup-default)

    ;; Step 1: Ensure data directories exist
    (supertag-persistence-ensure-data-directory)

    ;; Step 2: Check critical configuration before loading data
    (supertag--check-critical-config)

    ;; Step 3: Load sync state
    (supertag-sync-load-state)

    ;; Step 4: Load data from persistent storage
    (supertag-load-store)
    (when (and (boundp 'supertag--store-origin)
               (eq (plist-get supertag--store-origin :status) :new)
               (file-exists-p supertag-db-file))
      (message "Supertag: DB exists (%s) but store origin is :new (candidates=%S); retrying."
               (abbreviate-file-name supertag-db-file)
               (mapcar #'abbreviate-file-name
                       (or (plist-get supertag--store-origin :load-candidates) '())))
      (supertag-load-store supertag-db-file))

    ;; Step 5: Validate loaded data and sync directories
    (supertag--validate-initialization)

    ;; Step 6: Store load already cold-rebuilt every derived index.

    ;; Step 7: Set up auto-save and daily backup timers
    (supertag-setup-all-timers)

    ;; Step 8: Schedule safe auto-start for sync (optional, guarded)
    (when (and (boundp 'supertag-sync-auto-start)
               supertag-sync-auto-start)
      (supertag-sync-schedule-auto-start))

    ;; Step 10: Start scheduler
    (supertag-scheduler-start)

    ;; Step 11: Enable completion globally
    (global-supertag-ui-completion-mode 1)

    ;; Step 12: Enable completion in already-open org buffers
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (derived-mode-p 'org-mode)
          (supertag-ui-completion-mode 1))))

    ;; Step 13: Enable runtime config guard after successful init
    (setq supertag--initialized t)
    (supertag-config-guard-enable))

  ;; Optionally auto-show Node View side window and follow context
  (when (and (boundp 'supertag-view-node-auto-show)
             supertag-view-node-auto-show
             (fboundp 'supertag-view-node-ensure-shown))
    (supertag-view-node-ensure-shown))

(defun supertag--check-critical-config ()
  "Check critical configuration before initialization.
Warn user if important settings are missing or incorrect."
  (unless supertag-sync-directories
    (display-warning 'supertag
                     "supertag-sync-directories is not configured!\n\
This means no files will be synchronized automatically.\n\
Please set this variable in your Emacs configuration, for example:\n\
  (setq supertag-sync-directories '(\"/path/to/your/notes\"))"
                     :warning))

  (when supertag-sync-directories
    (dolist (dir supertag-sync-directories)
      (unless (file-directory-p (expand-file-name dir))
        (display-warning 'supertag
                         (format "Configured sync directory does not exist: %s\n\
Please check your supertag-sync-directories configuration."
                                 (abbreviate-file-name (expand-file-name dir)))
                         :warning))))

  (when (supertag-vault--vault-mode-p)
    (let ((vaults (supertag-vault--normalized-vaults)))
      (when (and (> (length supertag-sync-directories) 1)
                 (null vaults))
        (display-warning 'supertag
                         "Vault mode is enabled but no valid vault roots were found.\n\
Check `supertag-sync-directories`."
                         :warning)))))

(defun supertag--validate-initialization ()
  "Validate initialization state and provide helpful diagnostics."
  (let* ((store-is-valid (and (hash-table-p supertag--store)
                              (> (hash-table-count supertag--store) 0)))
         (nodes-table (when store-is-valid
                        (gethash :nodes supertag--store)))
         (node-count (if (hash-table-p nodes-table)
                         (hash-table-count nodes-table)
                       0))
         (db-file supertag-db-file)
         (db-exists (file-exists-p db-file))
         (db-size (when db-exists (file-attribute-size (file-attributes db-file)))))

    ;; Report database status
    (message "Database status: %s, Size: %s bytes, Nodes: %d"
             (if db-exists "exists" "NEW")
             (if db-size db-size "N/A")
             node-count)

    ;; Warn if database is empty but should have data
    ;; Only warn if store itself is invalid or truly empty (no collections at all)
    (when (and db-exists
               (> db-size 100)  ; Non-trivial file size
               (not store-is-valid)  ; Store is invalid or empty
               (= node-count 0))
      (display-warning 'supertag
                       (format "Database file exists but contains no nodes!\n\
Database: %s\n\
This may indicate:\n\
1. Database corruption or format issues\n\
2. All nodes were deleted or marked as orphaned\n\
3. Sync directories configuration changed\n\n\
Consider running: M-x supertag-sync-full-rescan" db-file)
                       :warning))

    ;; Suggest initial sync if database is truly empty
    (when (and (= node-count 0)
               supertag-sync-directories
               (cl-some #'file-directory-p supertag-sync-directories))
      (message "Database is empty. Consider running: M-x supertag-sync-full-rescan"))))

;; --- Hooks for persistence ---
(add-hook 'kill-emacs-hook #'supertag-save-store)
(add-hook 'kill-emacs-hook #'supertag-cleanup-all-timers) ; Clean up all timers on exit
(add-hook 'kill-emacs-hook #'supertag-sync-save-state) ; Save sync state on exit
(add-hook 'kill-emacs-hook #'supertag-sync-stop-auto-sync) ; Stop auto-sync on exit
;; Release the multi-instance DB lock last, after the final `supertag-save-store'
;; above has run (APPEND t places this at the end of `kill-emacs-hook', which
;; — given the other entries above are added without APPEND, i.e. prepended —
;; runs after all of them).
(add-hook 'kill-emacs-hook #'supertag--db-release-lock t)
;; Best-effort delete this host's own cross-machine presence claim on exit
;; (only if it still names this host; see `supertag--presence-release').
;; Order relative to the lock release above does not matter — presence and
;; the local lock are independent mechanisms — but it belongs in this same
;; "final cleanup" group of appended hooks.
(add-hook 'kill-emacs-hook #'supertag--presence-release t)
;; If Emacs has already finished startup by the time this file loads
;; (lazy-load via autoload / use-package :defer / late require), the
;; `emacs-startup-hook' has already fired, so hooking into it silently
;; drops `supertag-init'. Run it immediately in that case.
(if after-init-time
    (supertag-init)
  (add-hook 'emacs-startup-hook #'supertag-init))
(add-hook 'org-mode-hook #'supertag-vault-auto-activate)
(add-hook 'org-mode-hook #'supertag-sync-setup-realtime-hooks)


(provide 'supertag)

;;; supertag.el ends here
