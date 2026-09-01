;;; supertag-ui-mention.el --- Source-owned unlinked mention actions -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Turns disposable mention candidates into canonical Org ID links, or stores
;; an explicit source-owned ignore decision on the source heading.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-id)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-ops-node)
(require 'supertag-services-mention)
(require 'supertag-services-reference)
(require 'supertag-ui-commands)
(require 'supertag-ui-reference)

(declare-function supertag-view-node-refresh "supertag-view-node")

(defun supertag-mention--source-buffer-and-position (candidate)
  "Return (BUFFER . POSITION) for CANDIDATE's source heading."
  (let* ((source-id (plist-get candidate :source-id))
         (source (supertag-store-get-entity :nodes source-id))
         (file (or (plist-get candidate :source-file)
                   (plist-get source :file)))
         (fallback (or (plist-get candidate :source-position)
                       (plist-get source :position)
                       (plist-get source :pos)
                       1)))
    (unless (and file (file-readable-p file))
      (user-error "Source file is unavailable for node %s" source-id))
    (let ((buffer (find-file-noselect file)))
      (with-current-buffer buffer
        (org-with-wide-buffer
          (goto-char (min (point-max) (max (point-min) fallback)))
          (unless (and (derived-mode-p 'org-mode)
                       (ignore-errors
                         (org-back-to-heading t)
                         (equal source-id (org-entry-get nil "ID"))))
            (goto-char (point-min))
            (unless (re-search-forward
                     (concat "^[ \t]*:ID:[ \t]*"
                             (regexp-quote source-id) "[ \t]*$") nil t)
              (user-error "Source node %s is not present in %s"
                          source-id file))
            (org-back-to-heading t))
          (cons buffer (point)))))))

(defun supertag-mention--live-matches (candidate)
  "Return live source bounds and matches corresponding to CANDIDATE.
Signal when the source projection changed after the candidate was rendered."
  (let* ((source-id (plist-get candidate :source-id))
         (target-id (plist-get candidate :target-id))
         (target (or (supertag-store-get-entity :nodes target-id)
                     (user-error "Target node %s no longer exists" target-id)))
         (terms (supertag-reference-service-node-terms target))
         (location (supertag-mention--source-buffer-and-position candidate))
         (buffer (car location))
         (position (cdr location)))
    (with-current-buffer buffer
      (org-with-wide-buffer
        (goto-char position)
        (let* ((fresh (supertag--parse-node-at-point))
               (fresh-content (or (plist-get fresh :content) ""))
               (expected-hash (plist-get candidate :source-content-hash)))
          (unless (equal expected-hash (secure-hash 'sha256 fresh-content))
            (user-error
             "Source node %s changed; refresh the Node View before linking"
             source-id))
          (let* ((bounds (supertag-ui--document-link-bounds source-id))
                 (raw (buffer-substring-no-properties
                       (car bounds) (cdr bounds)))
                 (matches (supertag-mention-service-scan-content raw terms)))
            (list :buffer buffer :position position :bounds bounds
                  :raw raw :matches matches)))))))

(defun supertag-mention--find-live-match (candidate matches)
  "Return the live match corresponding exactly to CANDIDATE.

The source-content hash already proves that offsets did not move.  Matching by
the rendered :start/:end pair is stricter than relying on an ordinal that could
change when a target title or alias is edited after the Node View was rendered."
  (cl-find-if
   (lambda (match)
     (and (= (plist-get candidate :start) (plist-get match :start))
          (= (plist-get candidate :end) (plist-get match :end))))
   matches))

(defun supertag-mention--link-at-match (bounds match target-id &optional title)
  "Replace MATCH inside BOUNDS with a canonical Org link.
Use MATCH's exact source term as the visible description unless TITLE is
provided explicitly.  This preserves aliases and sentence wording."
  (let* ((start (+ (car bounds) (plist-get match :start)))
         (end (+ (car bounds) (plist-get match :end)))
         (description
          (or title
              (buffer-substring-no-properties start end)
              (plist-get match :term)
              target-id))
         (beg-marker (copy-marker start))
         (end-marker (copy-marker end t)))
    (unwind-protect
        (supertag-reference-materialize
         beg-marker end-marker target-id description)
      (set-marker beg-marker nil)
      (set-marker end-marker nil))))

(defun supertag-mention--refresh-view ()
  "Refresh the Node View after a mention action."
  (when (fboundp 'supertag-view-node-refresh)
    (ignore-errors (supertag-view-node-refresh))))

(defun supertag-mention--finish-source-edit (source-id)
  "Save and reproject SOURCE-ID after a source-owned edit."
  (save-buffer)
  (supertag-ui--reproject-containing-node source-id)
  (supertag-mention--refresh-view))

(defun supertag-mention-link (candidate)
  "Convert one unlinked mention CANDIDATE into a canonical Org ID link."
  (interactive)
  (let* ((live (supertag-mention--live-matches candidate))
         (matches (plist-get live :matches))
         (match (supertag-mention--find-live-match candidate matches))
         (target-id (plist-get candidate :target-id))
         (title (or (plist-get candidate :target-title) target-id)))
    (unless match
      (user-error "Mention candidate is stale; refresh the Node View"))
    (with-current-buffer (plist-get live :buffer)
      (org-with-wide-buffer
        (goto-char (plist-get live :position))
        (supertag-mention--link-at-match
         (plist-get live :bounds) match target-id)))
    (supertag-mention--refresh-view)
    (message "Linked mention to %s" title)))

(defun supertag-mention-link-all-in-node (candidate)
  "Link every mention of CANDIDATE's target in its source node."
  (interactive)
  (let* ((live (supertag-mention--live-matches candidate))
         (matches (plist-get live :matches))
         (target-id (plist-get candidate :target-id))
         (title (or (plist-get candidate :target-title) target-id)))
    (unless matches
      (user-error "No live unlinked mentions remain in the source node"))
    (with-current-buffer (plist-get live :buffer)
      (org-with-wide-buffer
        (goto-char (plist-get live :position))
        ;; Back-to-front replacement preserves every earlier offset.
        (dolist (match (reverse (copy-sequence matches)))
          (supertag-mention--link-at-match
           (plist-get live :bounds) match target-id))))
    (supertag-mention--refresh-view)
    (message "Linked %d mention(s) to %s" (length matches) title)))

(defun supertag-mention--ignore-value (ids)
  "Return stable Org property text for ignored target IDS."
  (string-join (sort (cl-delete-duplicates (copy-sequence ids) :test #'equal)
                     #'string<)
               " "))

(defun supertag-mention-ignore-in-node (candidate)
  "Ignore CANDIDATE's target throughout its source node."
  (interactive)
  (let* ((source-id (plist-get candidate :source-id))
         (target-id (plist-get candidate :target-id))
         (location (supertag-mention--source-buffer-and-position candidate)))
    (with-current-buffer (car location)
      (org-with-wide-buffer
        (goto-char (cdr location))
        (let* ((source (supertag-store-get-entity :nodes source-id))
               (ignored (supertag-mention-service-ignored-targets source)))
          (org-set-property
           (substring (symbol-name supertag-mention-ignore-property) 1)
           (supertag-mention--ignore-value (cons target-id ignored))))
        (supertag-mention--finish-source-edit source-id)))
    (message "Ignored mentions of %s in %s"
             (or (plist-get candidate :target-title) target-id)
             (or (plist-get candidate :source-title) source-id))))

(provide 'supertag-ui-mention)
;;; supertag-ui-mention.el ends here
