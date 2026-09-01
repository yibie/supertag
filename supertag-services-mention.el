;;; supertag-services-mention.el --- Read model for unlinked mentions -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;;
;; Unlinked mentions are candidates, not facts.  This module scans the direct
;; content already projected on Store nodes and returns disposable UI records.
;; It never writes Org source and never creates another mention index.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'subr-x)
(require 'supertag-core-index)
(require 'supertag-core-store)
(require 'supertag-services-reference)

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
              ranges)
          (org-element-map
              ast '(link src-block example-block fixed-width code verbatim)
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
  (interactive)
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

(provide 'supertag-services-mention)
;;; supertag-services-mention.el ends here
