;;; supertag-mention.el --- Mention feature -*- lexical-binding: t; -*-
;; Commands: supertag-mention-link, supertag-mention-link-all-in-node
;; Dependencies: button, cl-lib, org, org-id, org-element, subr-x, supertag-core-store, supertag-node, supertag-services-sync, supertag-link, supertag-view-framework

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'org)
(require 'org-id)
(require 'org-element)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-node)
(require 'supertag-services-sync)
(require 'supertag-link)
(require 'supertag-view-framework)

;;; 候选扫描

(defgroup supertag-mention nil
  "Unlinked mention discovery for Supertag."
  :group 'supertag-reference)

(defcustom supertag-mention-context-before 64
  "Maximum source characters shown before an unlinked mention."
  :type 'integer
  :group 'supertag-mention)

(defcustom supertag-mention-context-after 120
  "Maximum source characters shown after an unlinked mention."
  :type 'integer
  :group 'supertag-mention)

(defcustom supertag-mention-max-results 300
  "Maximum unlinked mention candidates returned for one target node."
  :type 'integer
  :group 'supertag-mention)

(defcustom supertag-mention-min-term-length 2
  "Minimum title or alias length considered for unlinked mentions."
  :type 'integer
  :group 'supertag-mention)

(defcustom supertag-mention-protected-range-cache-size 128
  "Maximum ephemeral Org parse results retained by the mention scanner."
  :type 'integer
  :group 'supertag-mention)

(defcustom supertag-mention-result-cache-size 64
  "Maximum target queries retained by the disposable mention result cache."
  :type 'integer
  :group 'supertag-mention)

(defvar supertag-mention-service--protected-range-cache
  (make-hash-table :test #'equal)
  "Ephemeral content-hash to protected-range cache.
This cache is never persisted and owns no reference facts.")

(defvar supertag-mention-service--result-cache
  (make-hash-table :test #'equal)
  "Ephemeral mention query cache keyed by target and display policy.
Each value records the exact Store identity/revision token it represents.")

(defconst supertag-mention-ignore-property :SUPERTAG_IGNORE_MENTIONS
  "Org property used to ignore target nodes inside one source node.")

(defun supertag-mention-service--node-prop (node property)
  "Return PROPERTY from plist or hash-table NODE."
  (cond
   ((hash-table-p node) (gethash property node))
   ((listp node) (plist-get node property))
   (t nil)))

(defun supertag-mention-service--node-properties (node)
  "Return NODE's projected Org properties as a plist."
  (let ((properties (supertag-mention-service--node-prop node :properties)))
    (cond
     ((hash-table-p properties)
      (let (result)
        (maphash (lambda (key value)
                   (setq result (plist-put result key value)))
                 properties)
        result))
     ((listp properties) properties)
     (t nil))))

(defun supertag-mention-service-ignored-targets (source-node)
  "Return target IDs ignored by SOURCE-NODE."
  (let ((raw (plist-get (supertag-mention-service--node-properties source-node)
                        supertag-mention-ignore-property)))
    (cl-delete-duplicates
     (cond
      ((null raw) nil)
      ((listp raw)
       (cl-remove-if #'string-empty-p
                     (mapcar (lambda (item)
                               (string-trim (format "%s" item)))
                             raw)))
      ((stringp raw)
       (split-string raw "[ \t\n\r,;]+" t))
      (t nil))
     :test #'equal)))

(defun supertag-mention-service-ignored-p (source-node target-id)
  "Return non-nil when SOURCE-NODE ignores TARGET-ID."
  (member target-id
          (supertag-mention-service-ignored-targets source-node)))

(defun supertag-mention-service--compute-protected-ranges (content)
  "Return zero-based protected ranges in CONTENT.

Org links, source/example blocks, inline code and verbatim objects are
protected.  Mentions inside these ranges must never be rewritten."
  (when (and (stringp content) (not (string-empty-p content)))
    (with-temp-buffer
      (let ((org-mode-hook nil)
            (org-inhibit-startup t)
            (org-element-use-cache nil))
        (insert content)
        (org-mode)
        (let ((ast (org-element-parse-buffer))
              (ranges
               ;; Reuse the generated-Embed exclusion boundary, on scratch text.
               ;; Its deletions proceed forwards; accumulate original offsets.
               (with-temp-buffer
                 (insert content)
                 (let ((removed 0) excluded
                       (inhibit-modification-hooks nil))
                   (setq-local before-change-functions
                               (list (lambda (beg end)
                               (push (cons (+ removed (1- beg))
                                           (+ removed (1- end))) excluded)
                               (cl-incf removed (- end beg)))))
                   (supertag-sync--strip-embed-block-contents "mention scratch")
                   excluded))))
          (org-element-map
              ast '(link src-block example-block fixed-width code verbatim
                    drawer property-drawer comment comment-block dynamic-block table keyword)
            (lambda (element)
              (let ((begin (org-element-property :begin element))
                    (end (org-element-property :end element)))
                (when (and begin end (< begin end))
                  ;; Org positions are one-based; string offsets are zero-based.
                  (push (cons (1- begin) (1- end)) ranges)))))
          (sort ranges (lambda (left right) (< (car left) (car right)))))))))

(defun supertag-mention-service--protected-ranges (content)
  "Return cached protected ranges for CONTENT."
  (let* ((key (secure-hash 'sha256 (or content "")))
         (missing (make-symbol "missing"))
         (cached (gethash key
                          supertag-mention-service--protected-range-cache
                          missing)))
    (if (not (eq cached missing))
        cached
      (when (>= (hash-table-count
                 supertag-mention-service--protected-range-cache)
                (max 1 supertag-mention-protected-range-cache-size))
        (clrhash supertag-mention-service--protected-range-cache))
      (let ((ranges
             (supertag-mention-service--compute-protected-ranges content)))
        (puthash key ranges supertag-mention-service--protected-range-cache)
        ranges))))

(defun supertag-mention-service-clear-cache ()
  "Clear disposable parse and result caches used by mention discovery."
  (clrhash supertag-mention-service--protected-range-cache)
  (clrhash supertag-mention-service--result-cache))

(defun supertag-mention-service--inside-range-p (start end ranges)
  "Return non-nil when START..END overlaps one of RANGES."
  (cl-some (lambda (range)
             (and (< start (cdr range)) (> end (car range))))
           ranges))

(defun supertag-mention-service--ascii-identifier-term-p (term)
  "Return non-nil when TERM needs ASCII identifier boundaries."
  (and (string-match-p "\\`[[:ascii:]]+\\'" term)
       (string-match-p "[[:alnum:]_]" (substring term 0 1))
       (string-match-p "[[:alnum:]_]" (substring term -1))))

(defun supertag-mention-service--identifier-char-p (character)
  "Return non-nil when CHARACTER is an ASCII identifier character."
  (and character
       (< character 128)
       (string-match-p "[[:alnum:]_]" (char-to-string character))))

(defun supertag-mention-service--boundary-valid-p (content term start end)
  "Return non-nil when TERM at START..END is a valid mention in CONTENT."
  (or
   ;; CJK and other non-ASCII terms must not use Emacs word boundaries; doing
   ;; so would incorrectly hide normal Chinese occurrences.
   (not (supertag-mention-service--ascii-identifier-term-p term))
   (and (not (supertag-mention-service--identifier-char-p
              (and (> start 0) (aref content (1- start)))))
        (not (supertag-mention-service--identifier-char-p
              (and (< end (length content)) (aref content end)))))))

(defun supertag-mention-service--candidate-id (source-id target-id term start)
  "Return deterministic candidate identity."
  (concat "mention-"
          (substring
           (secure-hash 'sha256
                        (format "%s|%s|%s|%d"
                                source-id target-id term start))
           0 24)))

(defun supertag-mention-service--context-parts (content start end)
  "Return (:before :match :after) around START..END in CONTENT."
  (let* ((before-start (max 0 (- start supertag-mention-context-before)))
         (after-end (min (length content)
                         (+ end supertag-mention-context-after))))
    (list :before (concat (if (> before-start 0) "…" "")
                          (substring content before-start start))
          :match (substring content start end)
          :after (concat (substring content end after-end)
                         (if (< after-end (length content)) "…" "")))))

(defun supertag-mention-service--normalize-terms (terms)
  "Return non-empty TERMS deduplicated under case-folded matching."
  (let ((seen (make-hash-table :test #'equal)) result)
    (dolist (value (or terms nil) (nreverse result))
      (let* ((term (string-trim (format "%s" value)))
             (identity (downcase term)))
        (when (and (>= (length term) supertag-mention-min-term-length)
                   (not (string-empty-p term))
                   (not (gethash identity seen)))
          (puthash identity t seen)
          (push term result))))))

(defun supertag-mention-service-scan-content (content terms)
  "Return non-overlapping mention matches for TERMS in CONTENT.

Each result contains zero-based :start and :end offsets.  Longer overlapping
terms win.  Existing Org links and literal/code regions are excluded."
  (let* ((text (or content ""))
         (case-fold-search t)
         (protected (supertag-mention-service--protected-ranges text))
         (terms (sort
                 (supertag-mention-service--normalize-terms terms)
                 (lambda (left right)
                   (if (= (length left) (length right))
                       (string< left right)
                     (> (length left) (length right))))))
         raw selected)
    (dolist (term terms)
      (let ((regexp (regexp-quote term))
            (offset 0))
        (while (and (< offset (length text))
                    (string-match regexp text offset))
          (let ((start (match-beginning 0))
                (end (match-end 0)))
            (when (and (< start end)
                       (supertag-mention-service--boundary-valid-p
                        text term start end)
                       (not (supertag-mention-service--inside-range-p
                             start end protected)))
              (push (list :term term :start start :end end) raw))
            ;; Always advance at least one character, including pathological
            ;; zero-width regex behavior (though TERM is literal and nonempty).
            (setq offset (max (1+ start) end))))))
    ;; Resolve overlap by semantic specificity first, not merely by the first
    ;; textual start position.  This makes the documented "longer term wins"
    ;; rule true even when the longer alias starts inside a shorter match.
    (setq raw
          (sort raw
                (lambda (left right)
                  (let* ((left-start (plist-get left :start))
                         (right-start (plist-get right :start))
                         (left-length (- (plist-get left :end) left-start))
                         (right-length (- (plist-get right :end) right-start)))
                    (cond
                     ((/= left-length right-length)
                      (> left-length right-length))
                     ((/= left-start right-start)
                      (< left-start right-start))
                     (t
                      (string< (plist-get left :term)
                               (plist-get right :term))))))))
    (dolist (match raw)
      (unless (cl-some
               (lambda (kept)
                 (and (< (plist-get match :start) (plist-get kept :end))
                      (> (plist-get match :end) (plist-get kept :start))))
               selected)
        (push match selected)))
    (sort selected
          (lambda (left right)
            (< (plist-get left :start) (plist-get right :start))))))

(defun supertag-mention-service--source-item
    (source-id source-node target-id target-node match content-hash ordinal)
  "Build one UI-ready mention item."
  (let* ((start (plist-get match :start))
         (end (plist-get match :end))
         (context (supertag-mention-service--context-parts
                   (or (supertag-mention-service--node-prop source-node :content) "")
                   start end)))
    (append
     (list :id (supertag-mention-service--candidate-id
                source-id target-id (plist-get match :term) start)
           :source-id source-id
           :source-title (supertag-reference-service-node-title source-node)
           :source-location
           (supertag-reference-service-node-location source-node)
           :source-file (supertag-mention-service--node-prop source-node :file)
           :source-position
           (or (supertag-mention-service--node-prop source-node :position)
               (supertag-mention-service--node-prop source-node :pos)
               0)
           :target-id target-id
           :target-title (supertag-reference-service-node-title target-node)
           :term (plist-get match :term)
           :start start :end end :ordinal ordinal
           :source-content-hash content-hash)
     context)))

(defun supertag-mention-service--content-maybe-matches-p (content terms)
  "Return non-nil when CONTENT cheaply contains one of TERMS."
  (let ((case-fold-search t))
    (cl-some (lambda (term)
               (string-match-p (regexp-quote term) content))
             terms)))

(defun supertag-mention-service--source-nodes ()
  "Return Store source nodes in deterministic location order."
  (let (nodes)
    (maphash
     (lambda (id node)
       (when (and (stringp (supertag-mention-service--node-prop node :content))
                  (stringp (supertag-mention-service--node-prop node :file)))
         (push (cons id node) nodes)))
     (supertag-store-get-collection :nodes))
    (sort
     nodes
     (lambda (left right)
       (let* ((left-node (cdr left))
              (right-node (cdr right))
              (left-file
               (or (supertag-mention-service--node-prop left-node :file) ""))
              (right-file
               (or (supertag-mention-service--node-prop right-node :file) ""))
              (left-position
               (or (supertag-mention-service--node-prop left-node :position)
                   (supertag-mention-service--node-prop left-node :pos)
                   0))
              (right-position
               (or (supertag-mention-service--node-prop right-node :position)
                   (supertag-mention-service--node-prop right-node :pos)
                   0)))
         (cond
          ((not (string-equal left-file right-file))
           (string< left-file right-file))
          ((/= left-position right-position)
           (< left-position right-position))
          (t (string< (car left) (car right)))))))))

(defun supertag-mention-service--find-uncached (target-id target terms)
  "Compute mention candidates for TARGET-ID, TARGET, and normalized TERMS."
  (let (results
        (count 0))
    (catch 'limit-reached
      (dolist (pair (supertag-mention-service--source-nodes))
        (let ((source-id (car pair))
              (source (cdr pair)))
          (when (and (not (equal source-id target-id))
                     (not (supertag-mention-service-ignored-p
                           source target-id)))
            (let ((content
                   (or (supertag-mention-service--node-prop
                        source :content)
                       "")))
              (when (supertag-mention-service--content-maybe-matches-p
                     content terms)
                (let ((content-hash (secure-hash 'sha256 content))
                      (ordinal 0))
                  (dolist (match
                           (supertag-mention-service-scan-content
                            content terms))
                    (push
                     (supertag-mention-service--source-item
                      source-id source target-id target match
                      content-hash ordinal)
                     results)
                    (setq ordinal (1+ ordinal)
                          count (1+ count))
                    (when (>= count supertag-mention-max-results)
                      (throw 'limit-reached t))))))))))
    (nreverse results)))

(defun supertag-mention-service-find (target-id)
  "Return disposable unlinked mention candidates for TARGET-ID.

Results are cached only while the exact Store identity and `:nodes' revision
remain current.  Returned records are copied so callers cannot mutate the
cached read model."
  (let* ((target (supertag-store-get-entity :nodes target-id))
         (terms
          (and target
               (cl-remove-if
                (lambda (term)
                  (< (length term) supertag-mention-min-term-length))
                (sort (supertag-reference-service-node-terms target)
                      (lambda (left right)
                        (> (length left) (length right)))))))
         (cache-key
          (list target-id
                supertag-mention-min-term-length
                supertag-mention-max-results
                supertag-mention-context-before
                supertag-mention-context-after))
         (token (supertag-index-source-token '(:nodes)))
         (entry (gethash cache-key supertag-mention-service--result-cache)))
    (when (and target terms)
      (if (and entry
               (supertag-index-source-current-p (car entry) '(:nodes)))
          (copy-tree (cdr entry))
        (let ((results
               (supertag-mention-service--find-uncached
                target-id target terms)))
          (when (>= (hash-table-count supertag-mention-service--result-cache)
                    (max 1 supertag-mention-result-cache-size))
            (clrhash supertag-mention-service--result-cache))
          (puthash cache-key (cons token (copy-tree results))
                   supertag-mention-service--result-cache)
          results)))))

;;; 命令

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

(defun supertag-mention--finish-source-edit (source-id)
  "Save and reproject SOURCE-ID after a source-owned edit."
  (save-buffer)
  (supertag-ui--reproject-containing-node source-id))

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
    (message "Linked %d mention(s) to %s" (length matches) title)))

(defun supertag-mention--ignore-value (ids)
  "Return stable Org property text for ignored target IDS."
  (string-join (sort (cl-delete-duplicates (copy-sequence ids) :test #'equal)
                     #'string<)
               " "))

;;; 节点视图段

(declare-function supertag-goto-node "supertag-node"
                  (node-id &optional other-window))

(defun supertag-view-mention--jump (button)
  "Jump to BUTTON's source node."
  (supertag-goto-node (button-get button 'supertag-source-id)))

(defun supertag-view-mention--link (button)
  "Link BUTTON's mention candidate."
  (supertag-mention-link (button-get button 'supertag-mention)))

(defun supertag-view-mention--link-all (button)
  "Link all mentions represented by BUTTON's source candidate."
  (supertag-mention-link-all-in-node
   (button-get button 'supertag-mention)))

(defun supertag-view-mention--ignore (button)
  "Ignore BUTTON's target throughout its source node."
  (let* ((candidate (button-get button 'supertag-mention))
         (source-id (plist-get candidate :source-id))
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

(defun supertag-view-mention--context-text (candidate)
  "Return CANDIDATE's source context as plain display text."
  (concat (or (plist-get candidate :before) "")
          (or (plist-get candidate :match) "")
          (or (plist-get candidate :after) "")))

(defun supertag-view-mention--insert-card (candidate)
  "Insert one magazine-style unlinked mention CANDIDATE."
  (let ((source-id (plist-get candidate :source-id))
        (source-title (or (plist-get candidate :source-title)
                          (plist-get candidate :source-id)))
        (start (point)))
    (insert "  ")
    (insert-text-button source-title 'face 'supertag-view-entry 'follow-link t
                        'action #'supertag-view-mention--jump
                        'help-echo (format "Jump to %s" source-title)
                        'supertag-source-id source-id)
    (insert "\n")
    (supertag-view-helper-insert-excerpt
     (supertag-view-mention--context-text candidate))
    (insert "    ")
    (supertag-view-helper-insert-action-button
     "[Link]" #'supertag-view-mention--link candidate
     "Turn this occurrence into a canonical Org ID link" 'supertag-mention)
    (insert "  ")
    (supertag-view-helper-insert-action-button
     "[Ignore in node]" #'supertag-view-mention--ignore candidate
     "Suppress mentions of this target in this source node" 'supertag-mention)
    (insert "\n")
    (add-text-properties start (point) '(line-spacing 0.15))))

(defun supertag-view-mention-insert-section (target-id)
  "Insert nonempty unlinked mention candidates for TARGET-ID."
  (let ((mentions (supertag-mention-service-find target-id)))
    (when mentions
      (insert "\n")
      (supertag-view-helper-insert-section-chip "Unlinked Mentions" (length mentions)
                                                   'supertag-view-chip3)
      (dolist (candidate mentions)
        (supertag-view-mention--insert-card candidate)))))

(provide 'supertag-mention)
;;; supertag-mention.el ends here
