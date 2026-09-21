;;; supertag-graph-ui.el --- Web-based graph visualization for supertag -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2025

;; This file is part of supertag.
;; Based on org-roam-ui by Sidharth Arya (GPL-3.0).

;;; Commentary:

;; Provides a force-directed graph visualization of supertag nodes
;; and relations in the browser, forked from org-roam-ui.
;;
;; Requires optional packages `websocket' and `simple-httpd'.
;;
;; Usage:
;;   M-x supertag-graph-ui-mode    — start/stop servers
;;   M-x supertag-graph-ui-open    — open graph in browser
;;   M-x supertag-graph-ui-follow-mode — sync graph focus to cursor

;;; Code:

(require 'json)
(require 'supertag-view-api)
(require 'supertag-services-query)
(require 'supertag-core-schema)
(require 'supertag-service-node-identity)

;;; --- Configuration ---

(defgroup supertag-graph-ui nil
  "Graph visualization for supertag."
  :group 'supertag
  :prefix "supertag-graph-ui-")

(defcustom supertag-graph-ui-port 35901
  "HTTP port for serving the graph UI."
  :type 'integer
  :group 'supertag-graph-ui)

(defcustom supertag-graph-ui-ws-port 35903
  "WebSocket port for live graph data."
  :type 'integer
  :group 'supertag-graph-ui)

(defcustom supertag-graph-ui-open-on-start t
  "Whether to open browser when starting graph UI mode."
  :type 'boolean
  :group 'supertag-graph-ui)

(defcustom supertag-graph-ui-follow nil
  "Whether to enable follow mode on startup."
  :type 'boolean
  :group 'supertag-graph-ui)

(defcustom supertag-graph-ui-sync-theme t
  "Whether to sync Emacs theme to graph UI."
  :type 'boolean
  :group 'supertag-graph-ui)

(defvar supertag-graph-ui-app-build-dir
  (expand-file-name "../../ext/graph-ui/out/"
                    (file-name-directory
                     (or load-file-name buffer-file-name
                         (locate-library "supertag-graph-ui"))))
  "Path to the built graph UI frontend.")

;;; --- State ---

(defvar supertag-graph-ui--ws-server nil
  "WebSocket server instance.")

(defvar supertag-graph-ui--ws-socket nil
  "Current WebSocket connection.")

(defvar supertag-graph-ui--ws-current-node nil
  "Last node ID sent via follow mode.")

(defvar supertag-graph-ui--unsubscribe-fn nil
  "Unsubscribe function for store change events.")

(defvar supertag-graph-ui--update-timer nil
  "Debounce timer for graph updates.")

;;; --- Minor Mode ---

;;;###autoload
(define-minor-mode supertag-graph-ui-mode
  "Enable supertag graph visualization.
Starts HTTP and WebSocket servers to serve the graph UI."
  :lighter " graph-ui"
  :global t
  :group 'supertag-graph-ui
  :init-value nil
  (cond
   (supertag-graph-ui-mode
    (unless (require 'websocket nil t)
      (supertag-graph-ui-mode -1)
      (user-error "Package `websocket' is required. Install via M-x package-install"))
    (unless (require 'simple-httpd nil t)
      (supertag-graph-ui-mode -1)
      (user-error "Package `simple-httpd' is required. Install via M-x package-install"))
    (unless (file-directory-p supertag-graph-ui-app-build-dir)
      (supertag-graph-ui-mode -1)
      (user-error "Graph UI build directory not found: %s" supertag-graph-ui-app-build-dir))
    (setq httpd-port supertag-graph-ui-port)
    (setq httpd-root supertag-graph-ui-app-build-dir)
    (httpd-start)
    (setq supertag-graph-ui--ws-server
          (websocket-server
           supertag-graph-ui-ws-port
           :host 'local
           :on-open #'supertag-graph-ui--ws-on-open
           :on-message #'supertag-graph-ui--ws-on-message
           :on-close #'supertag-graph-ui--ws-on-close))
    ;; Subscribe to store changes for live updates
    (setq supertag-graph-ui--unsubscribe-fn
          (supertag-view-api-subscribe :store-changed
                                       #'supertag-graph-ui--on-store-change))
    (when supertag-graph-ui-open-on-start
      (supertag-graph-ui-open))
    (when supertag-graph-ui-follow
      (supertag-graph-ui-follow-mode 1)))
   (t
    (when supertag-graph-ui--ws-server
      (websocket-server-close supertag-graph-ui--ws-server)
      (setq supertag-graph-ui--ws-server nil))
    (when (fboundp 'httpd-stop) (httpd-stop))
    (when (functionp supertag-graph-ui--unsubscribe-fn)
      (funcall supertag-graph-ui--unsubscribe-fn)
      (setq supertag-graph-ui--unsubscribe-fn nil))
    (when supertag-graph-ui--update-timer
      (cancel-timer supertag-graph-ui--update-timer)
      (setq supertag-graph-ui--update-timer nil))
    (supertag-graph-ui-follow-mode -1)
    (setq supertag-graph-ui--ws-socket nil))))

;;;###autoload
(defun supertag-graph-ui-open ()
  "Open the graph UI in the default browser."
  (interactive)
  (browse-url (format "http://localhost:%d" supertag-graph-ui-port)))

;;; --- WebSocket Handlers ---

(defun supertag-graph-ui--ws-on-open (ws)
  "Handle new WebSocket connection WS, send initial data."
  (setq supertag-graph-ui--ws-socket ws)
  (supertag-graph-ui--send-variables ws)
  (supertag-graph-ui--send-graphdata)
  (message "Connection established with supertag graph UI"))

(defun supertag-graph-ui--ws-on-message (_ws frame)
  "Handle incoming WebSocket message FRAME."
  (condition-case err
      (let* ((msg (json-parse-string
                   (websocket-frame-text frame) :object-type 'alist))
             (command (alist-get 'command msg))
             (data (alist-get 'data msg)))
        (cond
         ((equal command "open")
          (supertag-graph-ui--on-msg-open-node data))
         (t nil)))
    (error (message "supertag-graph-ui: message error: %s" err))))

(defun supertag-graph-ui--ws-on-close (_ws)
  "Handle WebSocket close."
  (setq supertag-graph-ui--ws-socket nil))

;;; --- Open Node in Emacs ---

(defun supertag-graph-ui--on-msg-open-node (data)
  "Open node from DATA received via WebSocket."
  (let ((id (alist-get 'id data)))
    (when id
      (condition-case err
          (supertag-graph-ui--jump-to-node id)
        (error (message "supertag-graph-ui: Cannot open node %s: %s" id err))))))

(defun supertag-graph-ui--jump-to-node (id)
  "Navigate to node with ID using the Store-first location boundary."
  (if-let* ((marker (supertag-node-location-find id)))
      (progn
        (pop-to-buffer (marker-buffer marker))
        (goto-char marker)
        (org-show-context)
        (select-frame-set-input-focus (selected-frame)))
    (message "supertag-graph-ui: node %s not found" id)))

;;; --- Data Serialization ---

(defun supertag-graph-ui--get-nodes ()
  "Get all nodes from supertag store as a list of alists.
Format is compatible with org-roam-ui frontend."
  (mapcar
   (lambda (pair)
     (let* ((id (car pair))
            (data (cdr pair)))
       `((id . ,id)
         (file . ,(or (plist-get data :file) ""))
         (title . ,(or (plist-get data :title) "Untitled"))
         (level . ,(or (plist-get data :level) 0))
         (pos . ,(or (plist-get data :position) 0))
         (olp . ,(vconcat (or (plist-get data :olp) '())))
         (properties . ,(make-hash-table :size 0))
         (tags . ,(vconcat (or (plist-get data :tags) '()))))))
   (supertag-query-nodes
    (lambda (id data) (and id (stringp id) data)))))

(defun supertag-graph-ui--get-links ()
  "Get all relations between existing nodes as a list of alists.
Includes semantic type metadata (label, color, style) when available."
  (let* ((node-ids
          (mapcar #'car
                  (supertag-query-nodes
                   (lambda (id data) (and id (stringp id) data)))))
         (relations (supertag-query-relations-among node-ids))
         (result '()))
    (dolist (rel relations (nreverse result))
      (let* ((from (plist-get rel :from))
             (to (plist-get rel :to))
             (type (plist-get rel :type))
             (type-str (and type (substring (symbol-name type) 1)))
             (meta (and type (supertag-relation-type-get type))))
        (push `((source . ,from)
                (target . ,to)
                (type . ,(or type-str "id"))
                ,@(when meta
                    `((label . ,(plist-get meta :name))
                      (color . ,(or (plist-get meta :color) ""))
                      (style . ,(let ((s (plist-get meta :style)))
                                  (if (eq s :dashed) "dashed" "solid"))))))
              result)))))

(defun supertag-graph-ui--get-tags ()
  "Get all unique tag names."
  (let ((result '()))
    (dolist (name (supertag-view-api-list-tags))
      (push name result))
    (vconcat (nreverse result))))

(defun supertag-graph-ui--get-parent-child-links ()
  "Derive parent-child links from org heading hierarchy.
Uses :file, :level, and :position fields to determine parent-child
relationships within each file.  Returns a list of alists with
source (parent id), target (child id), and type \"parent-child\"."
  (let ((by-file (make-hash-table :test 'equal))
        (result '()))
    ;; Group nodes by file
    (dolist (pair
             (supertag-query-nodes
              (lambda (id data)
                (and id (stringp id) data
                     (stringp (plist-get data :file))
                     (not (string-empty-p (plist-get data :file)))))))
      (let* ((id (car pair))
             (data (cdr pair))
             (file (plist-get data :file)))
        (puthash file
                 (cons (list :id id
                             :level (or (plist-get data :level) 0)
                             :pos (or (plist-get data :position) 0))
                       (gethash file by-file '()))
                 by-file)))
    ;; Per file: sort by position, then use a stack to find each
    ;; node's nearest ancestor (lowest enclosing level).
    (maphash
     (lambda (_file nodes)
       (let* ((sorted (sort (copy-sequence nodes)
                            (lambda (a b)
                              (< (plist-get a :pos)
                                 (plist-get b :pos)))))
              (stack '()))
         (dolist (node sorted)
           (let ((level (plist-get node :level))
                 (id    (plist-get node :id)))
             ;; Pop entries whose level >= current (they are siblings
             ;; or deeper, not ancestors).
             (while (and stack
                         (>= (plist-get (car stack) :level) level))
               (setq stack (cdr stack)))
             ;; Top of stack is the direct parent, if any.
             (when stack
               (push `((source . ,(plist-get (car stack) :id))
                       (target . ,id)
                       (type   . "parent-child"))
                     result))
             (push node stack)))))
     by-file)
    (nreverse result)))


(defun supertag-graph-ui--send-graphdata ()
  "Send graph data to the connected WebSocket client."
  (when (and supertag-graph-ui--ws-socket
             (websocket-openp supertag-graph-ui--ws-socket))
    (let* ((nodes (supertag-graph-ui--get-nodes))
           (links (append (supertag-graph-ui--get-links)
                          (supertag-graph-ui--get-parent-child-links)))
           (tags (supertag-graph-ui--get-tags))
           (response `((nodes . ,(vconcat nodes))
                       (links . ,(vconcat links))
                       (tags . ,(vconcat tags)))))
      (condition-case nil
          (websocket-send-text
           supertag-graph-ui--ws-socket
           (json-encode `((type . "graphdata")
                          (data . ,response))))
        (error nil)))))

;;; --- HTTP Node Content Endpoint ---

(defun httpd/node (proc path _query &rest _args)
  "Serve org node content for sidebar preview.
PATH is /node/<encoded-id>."
  (let* ((id (url-unhex-string (url-unhex-string
              (replace-regexp-in-string "^/node/" "" path))))
         (text (condition-case nil
                   (when (and id (not (string-empty-p id)))
                     (let ((marker (supertag-node-location-find id)))
                       (when marker
                         (with-current-buffer (marker-buffer marker)
                           (save-excursion
                             (goto-char marker)
                             (let ((beg (point))
                                   (end (save-excursion
                                          (org-end-of-subtree t t)
                                          (point))))
                               (buffer-substring-no-properties beg end)))))))
                 (error nil))))
    (with-httpd-buffer proc "text/plain; charset=utf-8"
      (insert (or text "(empty node)")))))

;;; --- Variables ---

(defun supertag-graph-ui--send-variables (ws)
  "Send configuration variables through WebSocket WS."
  (let ((sync-dirs (or (and (boundp 'supertag-sync-directories)
                            supertag-sync-directories)
                       '())))
    (condition-case nil
        (websocket-send-text
         ws
         (json-encode
          `((type . "variables")
            (data . (("subDirs" . ,(vconcat sync-dirs))
                     ("dailyDir" . "")
                     ("attachDir" . "")
                     ("useInheritance" . :json-false)
                     ("roamDir" . ,(or (car sync-dirs) ""))
                     ("katexMacros" . nil))))))
      (error nil))))

;;; --- Theme Sync ---

(defun supertag-graph-ui--get-theme ()
  "Extract current Emacs theme colors."
  (when supertag-graph-ui-sync-theme
    (if (boundp 'doom-themes--colors)
        (let (theme)
          (dolist (color (butlast doom-themes--colors
                                  (- (length doom-themes--colors) 25)))
            (push (cons (car color) (cadr color)) theme))
          theme)
      ;; Fallback: extract from faces
      `(("bg" . ,(face-background 'default))
        ("fg" . ,(face-foreground 'default))))))

;;; --- Store Change Listener ---

(defun supertag-graph-ui--on-store-change (&rest _args)
  "Handle store change, debounce graph update."
  (when supertag-graph-ui--update-timer
    (cancel-timer supertag-graph-ui--update-timer))
  (setq supertag-graph-ui--update-timer
        (run-with-idle-timer 0.5 nil #'supertag-graph-ui--send-graphdata)))

;;; --- Follow Mode ---

(defun supertag-graph-ui--update-current-node ()
  "Send the current node ID to the graph UI for focus."
  (when (and supertag-graph-ui--ws-socket
             (websocket-openp supertag-graph-ui--ws-socket)
             (derived-mode-p 'org-mode)
             (buffer-file-name (buffer-base-buffer)))
    (let ((id (org-entry-get nil "ID")))
      (when (and id (not (equal id supertag-graph-ui--ws-current-node)))
        (setq supertag-graph-ui--ws-current-node id)
        (condition-case nil
            (websocket-send-text
             supertag-graph-ui--ws-socket
             (json-encode `((type . "command")
                            (data . ((commandName . "follow")
                                     (id . ,id))))))
          (error nil))))))

;;;###autoload
(define-minor-mode supertag-graph-ui-follow-mode
  "Sync the graph UI focus to the current node in Emacs."
  :lighter " gf"
  :global t
  :group 'supertag-graph-ui
  :init-value nil
  (if supertag-graph-ui-follow-mode
      (add-hook 'post-command-hook #'supertag-graph-ui--update-current-node)
    (remove-hook 'post-command-hook #'supertag-graph-ui--update-current-node)))

(provide 'supertag-graph-ui)
;;; supertag-graph-ui.el ends here
