;;; supertag-tag.el --- Tag entities and :extends hierarchy -*- lexical-binding: t; -*-

;;; Commentary:
;; Semantic Tag IDs identify entities independently of their display names.
;; Tag hierarchy comes solely from explicit `:extends' parent IDs.
;; Org write formats, stable token merging and membership reads share this owner.
;; Entity operations, indexes, hierarchy rules, merge and rename share
;; this feature, including their Org text rewrite and snapshot recovery code.
;; Ordinary face styling and SVG rendering share this feature and parser.
;; Canonical Tag input, Org placement and the raw-membership node selector
;; share this feature. Add/remove use shared Node location helpers from a
;; supertag-node provider.
;; Explicit rename/delete/cleanup and Stream Tag selection are owned here.
;; Membership, Org Tag rules and compensated member writes live here; shared
;; Org location/save/project providers remain lazy service-org dependencies.
;; Loading installs display hooks and reconciles already open Org buffers;
;; it does not edit Org text or persist Store facts.
;;
;; Commands: supertag-view-style-mode, supertag-toggle-tag-style,
;; supertag-ui-completion-mode, global-supertag-ui-completion-mode,
;; supertag-add-tag, supertag-remove-tag-from-node, supertag-tag-rename,
;; supertag-delete-tag-everywhere,
;; supertag-cleanup-orphaned-tags.
;; Hooks: org-mode-hook, enable-theme-functions (when available).
;; Entry points: supertag--normalize-tag-id, supertag--create-tag-entities,
;; supertag-find-tag-descendants, supertag-query-tag-children,
;; supertag-view-api-list-tags, supertag-view-api-tag-id,
;; supertag-view--resolve-node-tags, supertag-view-helper-format-tag-value,
;; supertag-tag-create, supertag-tag-get, supertag-tag-update,
;; supertag-tag-delete, supertag-tag-resolve-occurrence,
;; supertag-tag-display-name, supertag-tag-parent, supertag-tag-ancestors,
;; supertag-tag-descendants, supertag-tag-set-parent,
;; supertag-tag-index-clear, supertag-tag-index-rebuild,
;; supertag-tag-orphaned-ids, supertag-tag-delete-orphans,
;; supertag-ops-add-tag-to-node, supertag-sanitize-tag-name,
;; supertag-tag-merge-plan, supertag-tag-merge-execute,
;; supertag-tag-rename-plan, supertag-tag-rename-execute,
;; supertag-view-helper-rename-tag-text-in-buffer,
;; supertag-view-helper-rename-tag-text-in-files, supertag-ui-read-tag,
;; supertag-ui-read-tags, supertag-ui--read-tag-field, supertag-ui-select-tag-on-node,
;; supertag-capture--get-from-tags-prompt, supertag-view-api-list-tag-ids,
;; supertag-view-helper-find-tag-insertion-point,
;; supertag-view-helper-tag-at-point-bounds, supertag-view-helper-get-tag-at-point.
;; Dependencies: cl-lib, seq, easy-mmode, org, org-id, org-element, svg, color, ht, subr-x,
;; supertag-core-store, supertag-link (ordinary providers),
;; supertag-node, supertag-service-org (via Node); lazy
;; supertag-service-org providers load Sync before FILETAGS callbacks;
;; supertag-query lazily supplies Tag descriptors, membership and occurrences;
;; supertag-view-framework supplies shared role faces for Tag value display on demand;
;; supertag-query lazily supplies node membership reads for Tag management;
;; supertag-node supplies shared containing-node/marker helpers;
;; supertag-link lazily supplies the shared Link CAPF. Loading Tag does not
;; enable global completion; the main entry retains that initialization.
;; Optional loaded view configuration is read through
;; supertag-view-config-list without loading the view framework.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'easy-mmode)
(require 'org)
(require 'org-element)
(require 'svg)
(require 'color)
(require 'ht)
(require 'org-id)
(require 'subr-x)
(require 'supertag-core-store)
;; Ordinary Relation providers load Link only on first use.
(autoload 'supertag-relation-kind "supertag-link")
(declare-function supertag-relation-kind "supertag-link" (relation))
(autoload 'supertag-generate-relation-id "supertag-link")
(declare-function supertag-generate-relation-id "supertag-link" (from-id to-id type &optional kind field-id link-definition-id relation-name))
(require 'supertag-node)


;; Ordinary shared Org providers load only when a member write needs them.
(autoload 'supertag-service-org--node-tags "supertag-service-org")
(autoload 'supertag-service-org--update-buffer-and-resync "supertag-service-org")
(autoload 'supertag-service-org-save-and-project-current-node "supertag-service-org")
(declare-function supertag-service-org--node-tags "supertag-service-org" (node-id))
(declare-function supertag-service-org--update-buffer-and-resync "supertag-service-org"
                  (node-id buffer-update-func &optional repair-projection))
(declare-function supertag-service-org-save-and-project-current-node "supertag-service-org" (node-id))
(declare-function supertag-node-location-find "supertag-service-org" (node-id))
;; FILETAGS callbacks run after the shared Org updater loads its Sync provider.
(declare-function supertag-sync--parse-file-header "supertag-services-sync" ())
(declare-function supertag-node-tag-occurrences-at-point "supertag-services-sync" ())

;; Tag input reads Query only on first use, never while loading this feature.
(autoload 'supertag-query-tag-descriptors "supertag-query")
(declare-function supertag-query-tag-descriptors "supertag-query" ())
(autoload 'supertag-query-node-tags "supertag-query")
(autoload 'supertag-query-tag-occurrences "supertag-query")
(declare-function supertag-query-node-tags "supertag-query" (node-id))
(declare-function supertag-query-tag-occurrences "supertag-query" ())
(autoload 'supertag-query-node-ids-by-tag "supertag-query")
(declare-function supertag-query-node-ids-by-tag "supertag-query" (tag-name &optional include-descendants))


;; Keep the Link CAPF lazy: ordinary tag completion must not load Link merely
;; to learn that point is not inside its shorthand syntax.
(defvar supertag-reference-shorthand-openers
  '(("[[" . "]]" ) ("【【" . "】】"))
  "Opener/closer pairs recognised by reference completion.")

(autoload 'supertag-reference-completion-at-point "supertag-link")
(declare-function supertag-reference-completion-at-point "supertag-link" ())

(defun supertag-tag--reference-shorthand-at-point-p ()
  "Return non-nil when point may be in an unclosed reference shorthand.

This is intentionally only a cheap same-line routing check.  Link owns the
precise bounds and context validation after it is loaded."
  (let ((end (point)) found)
    (dolist (pair supertag-reference-shorthand-openers)
      (let ((opener (car pair)) (closer (cdr pair)))
        (save-excursion
          (when (search-backward opener (line-beginning-position) t)
            (let ((open (point)))
              (goto-char end)
              (unless (search-backward closer open t)
                (setq found t)))))))
    found))

(defun supertag-tag--reference-completion-at-point ()
  "Dispatch to Link's CAPF only for possible reference shorthand syntax."
  (when (supertag-tag--reference-shorthand-at-point-p)
    (supertag-reference-completion-at-point)))

(autoload 'supertag-find-nodes-by-tag "supertag-query")
(declare-function supertag-find-nodes-by-tag "supertag-query" (tag-name &optional include-descendants))
(autoload 'supertag-service-org--with-node-buffer "supertag-service-org")
(declare-function supertag-service-org--with-node-buffer "supertag-service-org" (node-id func))

(autoload 'supertag-ui--get-containing-node-at-point "supertag-node")
(autoload 'supertag-ui--find-node-marker "supertag-node")
(declare-function supertag-ui--get-containing-node-at-point "supertag-node" ())
(declare-function supertag-ui--find-node-marker "supertag-node" (node-id))
;; Node location is lazy; actual projection resolves the ordinary Sync provider.
(declare-function supertag-node-sync-at-point "supertag-services-sync" ())

(declare-function supertag-view-config-list "supertag-view-framework" ())

;;; Shared inline Tag lexical and Org object-range parsing

(defconst supertag-inline-tag-terminator-chars
  "＃　，。；：！？、（）【】《》“”‘’"
  "Characters that terminate an inline tag name.
CJK prose uses full-width punctuation where ASCII text uses whitespace,
so these characters must end a tag name the same way whitespace does.
The full-width hash and ideographic space can never be part of a name.")

(defconst supertag-inline-tag-boundary-char-regexp
  "\\(?:[[:space:]]\\|\\cc\\|\\cj\\|\\ck\\|\\ch\\)"
  "Regexp matching one character that may precede an inline tag marker.
CJK prose puts no space between words, so a CJK character is as valid a
boundary as whitespace; ASCII word characters are not, which keeps URL
fragments and identifiers like word#part unmatched.")

(defconst supertag-inline-tag-boundary-regexp
  (concat "\\(?:\\`\\|\\([[:space:]]\\)\\|\\cc\\|\\cj\\|\\ck\\|\\ch\\)")
  "Regexp matching the boundary before an inline tag marker.
Matches string start, whitespace (captured as group 1), or a CJK
character (see `supertag-inline-tag-boundary-char-regexp').")

(defconst supertag-inline-tag-regexp
  (concat supertag-inline-tag-boundary-regexp
          "[#＃]\\([^[:space:]#" supertag-inline-tag-terminator-chars "]+\\)")
  "Regexp for an inline tag at string start, after whitespace, or after CJK.
Group 1 is the optional whitespace boundary; group 2 is the tag name.
Both the ASCII and full-width hash mark a tag; full-width punctuation
terminates the name (see `supertag-inline-tag-terminator-chars').")

(defun supertag-transform-inline-tag-name-p (name)
  "Return non-nil when NAME can be an inline tag.
An apostrophe immediately after # is Emacs Lisp function-quote syntax,
not a tag."
  (and (stringp name)
       (not (string-empty-p name))
       (not (eq (aref name 0) ?'))))

(defun supertag-transform--inline-tag-object-ranges
    (begin end &optional element restriction)
  "Return Org object ranges between BEGIN and END.
When ELEMENT is nil, parse the region as secondary Org text using
RESTRICTION.  Each range is (BEGIN END TRANSPARENT); sub/superscript
objects are transparent so underscores and carets remain valid Tag text."
  (let* ((parsed (or element
                     (org-element-parse-secondary-string
                      (buffer-substring-no-properties begin end)
                      (org-element-restriction (or restriction 'paragraph)))))
         (parts (cond
                 ((null element) parsed)
                 ((eq (org-element-type element) 'headline)
                  (org-element-property :title element))
                 (t (org-element-contents element))))
         (offset (if element 0 (1- begin)))
         ranges)
    (cl-labels
        ((collect (part)
           (unless (stringp part)
             (let ((object-begin (org-element-property :begin part))
                   (object-end (org-element-property :end part)))
               (when (and object-begin object-end)
                 (setq object-begin (+ offset object-begin)
                       object-end (+ offset object-end))
                 (when (and (< object-begin end) (> object-end begin))
                   (push (list object-begin object-end
                               (memq (org-element-type part)
                                     '(subscript superscript)))
                         ranges))))
             (dolist (child (org-element-contents part))
               (collect child)))))
      (dolist (part (if (listp parts) parts (list parts)))
        (collect part)))
    (sort ranges (lambda (a b) (< (car a) (car b))))))

(defun supertag-transform--inline-tag-prose-end (begin end object-ranges)
  "Return Tag prose end between BEGIN and END using OBJECT-RANGES.
Return nil when BEGIN is inside an Org object.  Transparent ranges may
occur later inside a Tag; other objects terminate it at their opening."
  (unless (cl-some (lambda (range)
                     (and (<= (nth 0 range) begin)
                          (< begin (nth 1 range))))
                   object-ranges)
    (catch 'boundary
      (dolist (range object-ranges)
        (let ((object-begin (nth 0 range))
              (transparent (nth 2 range)))
          (when (and (not transparent)
                     (> object-begin begin)
                     (< object-begin end))
            (throw 'boundary object-begin))))
      end)))

(defun supertag-transform-inline-tag-matches-in-region
    (begin end &optional element restriction)
  "Return range-aware prose Tag matches between BEGIN and END.
Each result is (BEGIN END NAME), with absolute buffer positions.  ELEMENT
may be the parsed headline or paragraph owning the region.  Otherwise the
region is parsed as secondary Org text using RESTRICTION."
  (save-excursion
    (goto-char
     (if (and (> begin (point-min))
              (let ((preceding (char-before begin)))
                (or (eq (char-syntax preceding) ?\s)
                    (string-match-p supertag-inline-tag-boundary-char-regexp
                                    (char-to-string preceding)))))
         (1- begin)
       begin))
    (let ((object-ranges
           (supertag-transform--inline-tag-object-ranges
            begin end element restriction))
          matches)
      (while (re-search-forward supertag-inline-tag-regexp end t)
        (let* ((name-begin (match-beginning 2))
               (raw-end (match-end 2))
               (tag-begin (1- name-begin))
               (tag-end
                (and (>= tag-begin begin)
                     (save-match-data
                       (supertag-transform--inline-tag-prose-end
                        tag-begin raw-end object-ranges))))
               (name (and tag-end
                          (> tag-end name-begin)
                          (buffer-substring-no-properties name-begin tag-end))))
          (when (and name
                     (supertag-transform-inline-tag-name-p name))
            (push (list tag-begin tag-end name) matches))))
      (nreverse matches))))

(defun supertag-transform-extract-inline-tags (content-string)
  "Extract whitespace-delimited #tags from CONTENT-STRING."
  (let ((tags '()))
    (when content-string
      (with-temp-buffer
        (insert content-string)
        (goto-char (point-min))
        (while (re-search-forward supertag-inline-tag-regexp nil t)
          (let ((tag (match-string 2)))
            (when (supertag-transform-inline-tag-name-p tag)
              (push tag tags))))))
    (nreverse tags)))

;;; Tag entities, indexes and operations

;;; --- Internal Helper ---

(defun supertag--validate-tag-data (data)
  "Strict validation for tag data. Fails fast on any inconsistency.
Implements immediate error reporting as preferred by the user."
  (unless (plist-get data :id)
    (error "Tag missing required :id field: %S" data))
  (unless (plist-get data :name)
    (error "Tag missing required :name field: %S" data))
  (when-let* ((aliases (plist-get data :aliases)))
    (unless (and (proper-list-p aliases) (cl-every #'stringp aliases))
      (error "Tag :aliases must be a list of strings, got: %S" aliases)))
  (when (plist-member data :extends)
    (unless (or (null (plist-get data :extends))
                (stringp (plist-get data :extends)))
      (error "Tag :extends must be a string or nil, got: %S"
             (plist-get data :extends))))
  ;; Validate time format compliance (Emacs native format)
  (when-let ((created-at (plist-get data :created-at)))
    (unless (condition-case nil
                (progn (format-time-string "%s" created-at) t)
              (error nil))
      (error "Tag :created-at must use Emacs time format, got: %S" created-at)))
  (when-let ((modified-at (plist-get data :modified-at)))
    (unless (condition-case nil
                (progn (format-time-string "%s" modified-at) t)
              (error nil))
      (error "Tag :modified-at must use Emacs time format, got: %S" modified-at))))

(defun supertag--ensure-plist (data)
  "Ensure DATA is in plist format, converting from hash table if necessary."
  (if (hash-table-p data)
      (let ((plist '()))
        (maphash (lambda (k v)
                   (setq plist (plist-put plist k v)))
                 data)
        plist)
    data))

(defun supertag--deep-copy-plist (plist)
  "Create a deep copy of PLIST, recursively copying nested lists.
This ensures that modifications to the copy do not affect the original."
  (if (not (listp plist))
      plist
    (let ((result '()))
      (while plist
        (let ((key (car plist))
              (val (cadr plist)))
          (setq result
                (plist-put result key
                           (cond
                            ;; Recursively copy nested plists (keyword-prefixed lists)
                            ((and (listp val) (keywordp (car-safe val)))
                             (supertag--deep-copy-plist val))
                            ;; Copy lists of plists (like :fields)
                            ((and (listp val) (listp (car-safe val)))
                             (mapcar #'supertag--deep-copy-plist val))
                            ;; Copy simple lists
                            ((listp val)
                             (copy-sequence val))
                            ;; Non-list values are copied as-is
                            (t val)))))
        (setq plist (cddr plist)))
      result)))

;; Stable Semantic Tag IDs are generated locally with org-id-uuid.

(defun supertag-tag-stable-id-p (value)
  "Return non-nil when VALUE has the Stable Semantic Tag ID shape."
  (and (stringp value)
       (string-match-p "\\`tag-[0-9a-f]\\{32\\}\\'" value)))

(defun supertag-tag--new-stable-id ()
  "Return a fresh Stable Semantic Tag ID."
  (let (id)
    (while (or (null id) (supertag-tag-get id))
      (setq id
            (concat "tag-"
                    (replace-regexp-in-string
                     "-" "" (downcase (org-id-uuid))))))
    id))

(defvar supertag-tag--token-index (make-hash-table :test 'equal)
  "Index: normalized occurrence token -> sorted Semantic Tag IDs.")

(defvar supertag-tag--descendants-index (make-hash-table :test 'equal)
  "Index: Semantic Tag ID -> transitive descendant IDs.")

(defvar supertag-tag--index-source-token nil
  "Source token represented by the Tag indexes.")

(defun supertag-tag-index-clear ()
  "Clear every Semantic Tag lookup index."
  (setq supertag-tag--token-index (make-hash-table :test 'equal)
        supertag-tag--descendants-index (make-hash-table :test 'equal)
        supertag-tag--index-source-token nil))

(defun supertag-tag-index-rebuild ()
  "Cold rebuild token and `:extends' descendant indexes from Store."
  (supertag-tag-index-clear)
  (condition-case err
      (let ((tags (supertag-store-get-collection :tags)))
        (when (hash-table-p tags)
          (let ((children (make-hash-table :test 'equal)))
            (maphash
             (lambda (tag-id raw-tag)
               (let ((tag (supertag--ensure-plist raw-tag)))
                 (dolist (token (supertag-tag--tokens tag-id tag))
                   (puthash token
                            (cons tag-id (gethash token supertag-tag--token-index))
                            supertag-tag--token-index))
                 (let ((parent (plist-get tag :extends)))
                   (when (and (stringp parent)
                              (not (equal parent tag-id))
                              (gethash parent tags))
                     (puthash parent (cons tag-id (gethash parent children))
                              children)))))
             tags)
            (maphash
             (lambda (token owners)
               (puthash token (sort (delete-dups owners) #'string<)
                        supertag-tag--token-index))
             supertag-tag--token-index)
            (maphash
             (lambda (tag-id _tag)
               (let ((queue (copy-sequence (gethash tag-id children)))
                     (seen (make-hash-table :test 'equal))
                     descendants)
                 (while queue
                   (let ((child (pop queue)))
                     (unless (gethash child seen)
                       (puthash child t seen)
                       (push child descendants)
                       (setq queue
                             (nconc queue
                                    (copy-sequence (gethash child children)))))))
                 (puthash tag-id (sort descendants #'string<)
                          supertag-tag--descendants-index)))
             tags)))
        (setq supertag-tag--index-source-token
              (supertag-index-source-token '(:tags))))
    (error
     (supertag-tag-index-clear)
     (signal (car err) (cdr err)))))

(defun supertag-tag--ensure-index ()
  "Cold rebuild Semantic Tag indexes when Tag facts changed."
  (unless (supertag-index-source-current-p
           supertag-tag--index-source-token '(:tags))
    (supertag-tag-index-rebuild)))

(defun supertag-tag--normalize-aliases (aliases)
  "Return sorted unique occurrence tokens from ALIASES."
  (sort
   (delete-dups
    (mapcar #'supertag-sanitize-tag-name
            (cl-remove-if-not #'stringp aliases)))
   #'string<))

(defun supertag-tag--tokens (tag-id tag)
  "Return every token that identifies TAG-ID and TAG."
  (supertag-tag--normalize-aliases
   (append (list tag-id (plist-get tag :name))
           (plist-get tag :aliases))))

(cl-defun supertag-tag--matching-ids
    (token &optional (tag-ids nil tag-ids-supplied-p))
  "Return Tag IDs that claim TOKEN, optionally limited to TAG-IDS."
  (when (and (stringp token) (not (string-empty-p token)))
    (supertag-tag--ensure-index)
    (let* ((normalized (supertag-sanitize-tag-name token))
           (owners (copy-sequence
                    (gethash normalized supertag-tag--token-index))))
      (if tag-ids-supplied-p
          (cl-remove-if-not (lambda (tag-id) (member tag-id tag-ids)) owners)
        owners))))

(defun supertag-tag--assert-tokens-unique (tag-id tokens)
  "Signal when another Tag besides TAG-ID claims one of TOKENS."
  (dolist (token (supertag-tag--normalize-aliases tokens))
    (let ((owners (remove tag-id (supertag-tag--matching-ids token))))
      (when owners
        (user-error "Tag token '%s' is already owned by %s"
                    token (string-join owners ", "))))))

(defun supertag-tag--assert-all-tokens-unique ()
  "Signal when any occurrence token belongs to multiple Semantic Tags."
  (let ((claims (make-hash-table :test 'equal)))
    (maphash
     (lambda (tag-id raw-tag)
       (dolist (token (supertag-tag--tokens
                       tag-id (supertag--ensure-plist raw-tag)))
         (puthash token (cons tag-id (gethash token claims)) claims)))
     (supertag-store-get-collection :tags))
    (maphash
     (lambda (token owners)
       (setq owners (sort (delete-dups owners) #'string<))
       (when (cdr owners)
         (user-error "Tag token '%s' is owned by %s"
                     token (string-join owners ", "))))
     claims)
    t))

;;; --- Tag Operations ---

;; 3.1 Basic Operations

(defun supertag-tag-create (props)
  "Create a new tag using the unified commit system.
PROPS is a plist of tag properties.
Returns the created tag data."
  (when (plist-get props :fields)
    (user-error
     "Tag :fields is retired; fields are Org properties on document headings"))
  (let* ((raw-name (plist-get props :name))
         (name (and (stringp raw-name)
                    (supertag-sanitize-tag-name raw-name)))
         (requested-id (plist-get props :id))
         (existing-id (and (not requested-id) name
                           (supertag-tag-resolve-occurrence name)))
         (id (or requested-id existing-id (supertag-tag--new-stable-id)))
         (extends (plist-get props :extends))
         (existing-tag (supertag-tag-get id)))
    (if existing-tag
        (progn
          (message "Tag '%s' already exists, returning existing tag." id)
          existing-tag)
      (unless (and (stringp name) (not (string-empty-p name)))
        (user-error "Tag name cannot be empty"))
      (supertag-tag--validate-extends id extends)
      (let* ((aliases
              (supertag-tag--normalize-aliases
               (append (list id name)
                       (plist-get props :aliases))))
             (final-props `(:id ,id
                             :name ,name
                             :aliases ,aliases
                             :type :tag
                             :extends ,extends
                             :created-at ,(supertag-current-time)
                             :modified-at ,(supertag-current-time))))
        (supertag--validate-tag-data final-props)
        (supertag-tag--assert-tokens-unique id aliases)
        (supertag-ops-commit
         :operation :create
         :collection :tags
         :id id
         :new final-props
         :perform (lambda ()
                    (supertag-store-put-entity :tags id final-props)
                    final-props))))))

(defun supertag-tag-get (id)
  "Get tag data.
ID is the unique identifier of the tag.
Returns tag data, or nil if it does not exist."
  (supertag-store-get-entity :tags id))

(defun supertag-tag--validate-extends (tag-id parent-id)
  "Signal `user-error' when TAG-ID cannot extend PARENT-ID."
  (unless (or (null parent-id) (stringp parent-id))
    (user-error "Tag :extends must be a string or nil"))
  (when parent-id
    (unless (supertag-tag-get parent-id)
      (user-error "Parent tag '%s' does not exist" parent-id))
    (when (equal tag-id parent-id)
      (user-error "Tag '%s' cannot extend itself" tag-id))
    (let ((current parent-id)
          (seen (make-hash-table :test 'equal)))
      (puthash tag-id t seen)
      (while current
        (when (gethash current seen)
          (user-error "Tag :extends would create a cycle involving '%s'" tag-id))
        (puthash current t seen)
        (setq current
              (plist-get (supertag--ensure-plist (supertag-tag-get current))
                         :extends))))))

(defun supertag-tag-find-ghosts ()
  "Return Tag IDs whose stored value is nil (ghost entries)."
  (let (ghosts)
    (maphash
     (lambda (key value)
       (when (null value)
         (push key ghosts)))
     (supertag-store-get-collection :tags))
    ghosts))

(defun supertag-tag-parent (tag-id)
  "Return TAG-ID's direct `:extends' parent ID, or nil."
  (when-let* ((tag (supertag--ensure-plist (supertag-tag-get tag-id))))
    (plist-get tag :extends)))

(defun supertag-tag-ancestors (tag-id)
  "Return TAG-ID's ancestors from nearest to farthest.
Stop when a malformed stored parent cycle is encountered."
  (let ((parent (supertag-tag-parent tag-id))
        (seen (make-hash-table :test 'equal))
        ancestors)
    (puthash tag-id t seen)
    (while (and parent (not (gethash parent seen)))
      (puthash parent t seen)
      (push parent ancestors)
      (setq parent (supertag-tag-parent parent)))
    (nreverse ancestors)))

(defun supertag-tag-display-name (tag-id)
  "Return TAG-ID's ancestor-name chain joined with ` › '."
  (let (names)
    (dolist (id (append (nreverse (supertag-tag-ancestors tag-id))
                        (list tag-id)))
      (let ((tag (supertag--ensure-plist (supertag-tag-get id))))
        (push (or (plist-get tag :name) id) names)))
    (string-join (nreverse names) " › ")))

(defun supertag-tag-descendants (tag-id)
  "Return cached transitive descendants of Semantic TAG-ID."
  (supertag-tag--ensure-index)
  (copy-sequence (gethash tag-id supertag-tag--descendants-index)))

(cl-defun supertag-tag-resolve-occurrence
    (token &optional (tag-ids nil tag-ids-supplied-p))
  "Return the existing Semantic Tag ID resolved from occurrence TOKEN.
Return nil when TOKEN has no Semantic Tag.  This function never creates or
modifies Tag entities."
  (let ((matches
         (if tag-ids-supplied-p
             (supertag-tag--matching-ids token tag-ids)
           (supertag-tag--matching-ids token))))
    (cond
     ((null matches) nil)
     ((null (cdr matches)) (car matches))
     (t (error "Ambiguous Tag token '%s' is owned by %s"
               token (string-join matches ", "))))))

(defun supertag-tag-affixate-candidates (candidates)
  "Display CANDIDATES with their `:extends' display names."
  (mapcar
   (lambda (candidate)
     (let* ((new-name (get-text-property 0 'new-tag-name candidate))
            (id (or new-name
                    (get-text-property 0 'supertag-tag-id candidate)
                    (substring-no-properties candidate)))
            (display (supertag-tag-display-name id))
            (suffix
             (cond
              ((get-text-property 0 'supertag-tag-conflict candidate)
               (propertize "  [Conflict]" 'face 'error))
              ((get-text-property 0 'is-new-tag candidate)
               (propertize "  [New]" 'face 'warning))
              ((get-text-property 0 'supertag-tag-occurrence candidate)
               (propertize "  [Unresolved]" 'face 'shadow))
              (t ""))))
       (list display "" suffix)))
   candidates))

(defun supertag-tag-update (id updater)
  "Update tag data using the unified commit system.
ID is the unique identifier of the tag.
UPDATER is a function that receives the current tag data and returns the updated data.
Returns the updated tag data."


(let ((previous (supertag-tag-get id)))
    (when previous
      ;; Convert hash table to plist if necessary
      (let* ((original-plist (supertag--ensure-plist previous))
             ;; Deep copy to avoid mutation affecting original-plist comparison
             (copy-for-update (supertag--deep-copy-plist original-plist)))
        (supertag-with-transaction
          (supertag-ops-commit
           :operation :update
           :collection :tags
           :id id
           :previous original-plist
           :perform (lambda ()
                      (let ((updated-tag (funcall updater copy-for-update)))
                        (when updated-tag
                        ;; Always save if updater returned non-nil, since the updater
                        ;; is expected to make changes. The equal check was unreliable
                        ;; due to plist-put mutation semantics.
                        (let* ((aliases
                                (supertag-tag--normalize-aliases
                                 (append
                                  (list id (plist-get updated-tag :name))
                                  (plist-get updated-tag :aliases))))
                               (normalized-tag
                                (plist-put updated-tag :aliases aliases))
                               (final-tag (plist-put normalized-tag :modified-at (supertag-current-time))))
                          (supertag-tag--assert-tokens-unique id aliases)
                          (supertag-tag--validate-extends
                           id (plist-get final-tag :extends))
                          (supertag--validate-tag-data final-tag)
                            (supertag-store-put-entity :tags id final-tag)
                            (supertag-tag--assert-all-tokens-unique)

                            final-tag))))))))))

(defun supertag-tag-delete (id &optional before-delete)
  "Delete a tag using the unified commit system.
ID is the unique identifier of the tag.
When BEFORE-DELETE is non-nil, call it with ID after operation hooks and
immediately before the Store mutation.
Returns the deleted tag data."


(let ((previous (supertag-tag-get id)))
    (when previous
      (supertag-ops-commit
       :operation :delete
       :collection :tags
       :id id
       :previous previous
       :perform (lambda ()
                  (when before-delete
                    (funcall before-delete id))
                  (supertag-store-remove-entity :tags id)

                  nil)))))

(defun supertag-tag--referenced-ids (tag-ids)
  "Return TAG-IDS referenced by Store data or loaded view configuration.
TAG-IDS are explicit so validation still sees candidates already removed
from the Tag registry by an in-flight cleanup transaction."
  (let ((known (make-hash-table :test 'equal))
        (referenced (make-hash-table :test 'equal))
        (seen (make-hash-table :test 'eq)))
    (dolist (id tag-ids)
      (when (stringp id)
        (puthash id t known)))
    (cl-labels
        ((walk (value)
           (cond
            ((stringp value)
             (when (gethash value known)
               (puthash value t referenced)))
            ((hash-table-p value)
             (unless (gethash value seen)
               (puthash value t seen)
               (maphash (lambda (key item) (walk key) (walk item)) value)))
            ((consp value)
             (walk (car value))
             (walk (cdr value))))))
      (dolist (collection (supertag-store-collection-names))
        (unless (eq collection :tags)
          (walk (supertag-store-get-collection collection))))

      ;; Pending field records are a list root, outside the collection scan.
      (walk (gethash :legacy-fields supertag--store))
      (when (fboundp 'supertag-view-config-list)
        (walk (supertag-view-config-list))))
    (let (ids)
      (maphash (lambda (id _value)
                 (push id ids))
               referenced)
      (sort ids #'string<))))

(defun supertag-tag-orphaned-ids ()
  "Return sorted Tag IDs with no data or loaded configuration references.
The scan is intentionally conservative: an exact Tag ID anywhere outside
the Tag registry counts as a reference."
  (let ((tags (supertag-store-get-collection :tags))
        ids)
    (maphash (lambda (id value)
               (when value (push id ids)))
             tags)
    (sort (cl-set-difference
           ids (supertag-tag--referenced-ids ids) :test #'equal)
          #'string<)))

(defun supertag-tag-delete-orphans (tag-ids)
  "Delete TAG-IDS only when every ID is still an orphan.
No Org file is edited.  The full set is rechecked immediately before the
transaction so a stale preview cannot delete a newly referenced Tag.
Return the number of deleted Tag entities."
  (let* ((ids (delete-dups (copy-sequence tag-ids)))
         (orphans (supertag-tag-orphaned-ids))
         (blocked (cl-set-difference ids orphans :test #'equal)))
    (when blocked
      (user-error "Refusing to delete referenced or schema Tag(s): %s"
                  (string-join blocked ", ")))
    (supertag-with-transaction
      (dolist (id ids)
        (supertag-tag-delete
         id
         (lambda (current-id)
           (unless (member current-id (supertag-tag-orphaned-ids))
             (user-error "Tag is no longer orphaned: %s" current-id)))))
      (let ((post-hook-blocked
             (delete-dups
              (append (supertag-tag--referenced-ids ids)
                      (cl-remove-if-not #'supertag-tag-get ids)))))
        (when post-hook-blocked
          (user-error "Cleanup hooks retained or referenced Tag(s): %s"
                      (string-join post-hook-blocked ", ")))))
    (length ids)))



(cl-defun supertag-ops-add-tag-to-node (node-id tag-id &key create-if-needed)
  "High-level operation to add a tag to a node.
This non-interactive function ensures the tag exists (creating it
if CREATE-IF-NEEDED is non-nil) and then updates the node's `:tags'
membership.  A slash path is the complete tag name.

It does NOT modify the buffer.
Returns t if the membership was added or already exists, nil otherwise."
  (when (and node-id (not (string-empty-p tag-id)))
    (supertag-with-transaction
      (unless (supertag-node-get node-id)
        (user-error "Node '%s' does not exist" node-id))
      (let* ((resolved-id
              (or (and (supertag-tag-get tag-id) tag-id)
                  (supertag-tag-resolve-occurrence tag-id)))
             (existing (and resolved-id (supertag-tag-get resolved-id))))
        ;; 1. Ensure tag definition exists.
        (when (and create-if-needed (not existing))
          (setq existing
                (supertag-tag-create
                 `(:name ,tag-id)))
          (setq resolved-id (plist-get existing :id)))

        ;; 2. If the tag exists, update node membership.
        (if (and resolved-id (supertag-tag-get resolved-id))
            (progn
              (supertag-node-add-tag node-id resolved-id)
              t)
          nil)))))

;; 3.2 Field Operations

(defun supertag-sanitize-tag-name (name)
  "Sanitize a string into a valid tag name.
Removes leading/trailing whitespace, a leading '#', and converts
internal whitespace to single underscores."
  (if (or (null name) (string-empty-p name))
      (error "Tag name cannot be empty")
    (let* ((clean-name (substring-no-properties name))
           (trimmed (string-trim clean-name))
           (no-hash (if (string-prefix-p "#" trimmed)
                        (substring trimmed 1)
                      trimmed))
           (sanitized (replace-regexp-in-string "\\s-+" "_" no-hash)))
      (if (string-empty-p sanitized)
          (error "Invalid tag name: %s" name)
        sanitized))))

;;; Cross-file Tag text writes

(defun supertag-view-helper-rename-tag-text-in-buffer (old-tag-name new-tag-name)
  "Rename OLD-TAG-NAME to NEW-TAG-NAME in inline tags and FILETAGS.
Returns the total number of instances renamed."
  (save-excursion
    (goto-char (point-min))
    (let ((renamed-count 0))
      (while (re-search-forward supertag-inline-tag-regexp nil t)
        (when (and (string= (match-string-no-properties 2) old-tag-name)
                   (not (or (save-excursion
                              (goto-char (match-beginning 0))
                              (org-in-src-block-p))
                            (save-excursion
                              (goto-char (match-beginning 0))
                              (beginning-of-line)
                              (looking-at-p "^[ \t]*#\\+")))))
          (replace-match new-tag-name t t nil 2)
          (setq renamed-count (1+ renamed-count))))
      (goto-char (point-min))
      (let ((case-fold-search t)
            (pattern
             (concat "\\(^\\|[[:space:]:]\\)\\("
                     (regexp-quote old-tag-name)
                     "\\)\\([[:space:]:]\\|$\\)")))
        (while (re-search-forward "^#\\+FILETAGS:[ \t]*\\(.*\\)$" nil t)
          (let ((begin (match-beginning 1))
                (end (copy-marker (match-end 1))))
            (save-restriction
              (narrow-to-region begin end)
              (goto-char (point-min))
              (while (re-search-forward pattern nil t)
                (let ((prefix (match-string-no-properties 1))
                      (suffix (match-string-no-properties 3)))
                  (replace-match (concat prefix new-tag-name suffix) t t)
                  ;; Revisit a consumed separator so adjacent tokens match.
                  (unless (string-empty-p suffix)
                    (backward-char)))
                (setq renamed-count (1+ renamed-count))))
            (set-marker end nil))))
      renamed-count)))

(defun supertag-view-helper-rename-tag-text-in-files (old-tag-name new-tag-name files)
  "Rename all occurrences of #OLD-TAG-NAME to #NEW-TAG-NAME in specified FILES.
OLD-TAG-NAME is the current tag name.
NEW-TAG-NAME is the new tag name.
FILES is a list of file paths.
Returns the total number of instances renamed."
  (let ((total-renamed 0))
    (dolist (file files)
      (when (and file (file-exists-p file))
        (with-current-buffer (find-file-noselect file)
          (save-excursion
            (let ((renamed-count
                   (supertag-view-helper-rename-tag-text-in-buffer
                    old-tag-name new-tag-name)))
              (when (> renamed-count 0)
                (save-buffer)
                (setq total-renamed (+ total-renamed renamed-count))
                (message "Renamed %s instances from #%s to #%s in %s"
                         renamed-count old-tag-name new-tag-name
                         (file-name-nondirectory file))))))))
    ;; Ensure we always return a number, never nil
    (or total-renamed 0)))

;;; Tag merge and namespace rename

(defvar supertag-query-saved nil)
(defvar supertag--view-configs (make-hash-table :test 'eq))

(defconst supertag-tag-merge--missing (make-symbol "supertag-tag-merge-missing"))

(defconst supertag-tag-merge--multi-value-types
  '(:options :tag :node-reference)
  "Field types whose existing schema permits multiple stored values.")

(defconst supertag-tag-merge--tag-slot-keys
  '(:tag :tags :tag-id :target-tag :source-tag :scope-tag :base-tag
    :from-tag :to-tag)
  "Structured plist keys whose values are tag identifiers.")

(defun supertag-tag-merge--unique (items)
  "Return ITEMS without duplicates, preserving order."
  (let ((seen (make-hash-table :test 'equal)) result)
    (dolist (item items (nreverse result))
      (unless (gethash item seen)
        (puthash item t seen)
        (push item result)))))


(defun supertag-tag-merge--affected-nodes (source-ids)
  "Return node plists whose `:tags' intersect SOURCE-IDS."
  (let (nodes)
    (maphash
     (lambda (node-id raw-node)
       (let ((node (supertag--ensure-plist raw-node)))
         (when (cl-intersection (or (plist-get node :tags) '()) source-ids
                                :test #'equal)
           (push (plist-put (copy-sequence node) :id node-id) nodes))))
     (supertag-store-get-collection :nodes))
    (nreverse nodes)))

(defun supertag-tag-merge--canonical-token (tag-id)
  "Return TAG-ID's canonical Org occurrence token."
  (supertag-sanitize-tag-name
   (plist-get (supertag--ensure-plist (supertag-tag-get tag-id)) :name)))

(defun supertag-tag-merge--file-token-rewrites
    (nodes source-ids target-token)
  "Return exact Org token rewrites for NODES into TARGET-TOKEN."
  (let (tokens)
    (dolist (node nodes)
      (dolist (token (plist-get node :tag-occurrences))
        (when (member (ignore-errors (supertag-tag-resolve-occurrence token))
                      source-ids)
          (push token tokens))))
    (dolist (source source-ids)
      (push (supertag-tag-merge--canonical-token source) tokens))
    (mapcar (lambda (token) (cons token target-token))
            (supertag-tag-merge--unique (nreverse tokens)))))

(defun supertag-tag-merge--file-conflicts (nodes)
  "Return preflight conflicts for source files referenced by NODES."
  (let (conflicts)
    (dolist (node nodes)
      (let ((file (plist-get node :file)))
        (cond
         ((or (not (stringp file)) (string-empty-p file) (not (file-exists-p file)))
          (push (list :kind :missing-file :node-id (plist-get node :id) :file file)
                conflicts))
         ((not (file-writable-p file))
          (push (list :kind :unwritable-file :node-id (plist-get node :id) :file file)
                conflicts))
         ((when-let* ((buffer (get-file-buffer file)))
            (buffer-modified-p buffer))
          (push (list :kind :unsaved-buffer :node-id (plist-get node :id) :file file)
                conflicts)))))
    (nreverse conflicts)))

(defun supertag-tag-merge--replace-tag-value (value source-ids target-id)
  "Replace SOURCE-IDS in structured VALUE with TARGET-ID."
  (cond
   ((stringp value) (if (member value source-ids) target-id value))
   ((listp value)
    (supertag-tag-merge--unique
     (mapcar (lambda (item)
               (supertag-tag-merge--replace-tag-value item source-ids target-id))
             value)))
   (t value)))

(defun supertag-tag-merge--plist-p (value)
  "Return non-nil when VALUE has a keyword plist shape."
  (and (consp value)
       (keywordp (car value))
       (zerop (% (length value) 2))))

(defun supertag-tag-merge--rewrite-structured (form source-ids target-id)
  "Rewrite SOURCE-IDS in structured FORM to TARGET-ID."
  (cond
   ((atom form) form)
   ((memq (car form) '(has-tag tag))
    (cons (car form)
          (cons (supertag-tag-merge--replace-tag-value
                 (cadr form) source-ids target-id)
                (mapcar (lambda (item)
                          (supertag-tag-merge--rewrite-structured item source-ids target-id))
                        (cddr form)))))
   ((memq (car form) '(has-any-tag has-all-tags))
    (cons (car form)
          (supertag-tag-merge--unique
           (mapcar (lambda (item)
                     (supertag-tag-merge--replace-tag-value item source-ids target-id))
                   (cdr form)))))
   ((supertag-tag-merge--plist-p form)
    (let (result)
      (while form
        (let ((key (pop form))
              (value (pop form)))
          (setq result
                (append result
                        (list key
                              (if (memq key supertag-tag-merge--tag-slot-keys)
                                  (supertag-tag-merge--replace-tag-value
                                   value source-ids target-id)
                                (supertag-tag-merge--rewrite-structured
                                 value source-ids target-id)))))))
      result))
   (t
    (mapcar (lambda (item)
              (supertag-tag-merge--rewrite-structured item source-ids target-id))
            form))))

(defun supertag-tag-merge--string-mentions-source-p (string source-ids)
  "Return non-nil when STRING mentions one of SOURCE-IDS."
  (cl-some (lambda (source)
             (string-match-p (regexp-quote source) string))
           source-ids))

(defun supertag-tag-merge--saved-query-changes (source-ids target-id)
  "Return saved-query updates and warnings for SOURCE-IDS and TARGET-ID."
  (let (updates warnings)
    (when (boundp 'supertag-query-saved)
      (dolist (entry supertag-query-saved)
        (let ((name (car entry)) (text (cdr entry)))
          (when (and (stringp text)
                     (supertag-tag-merge--string-mentions-source-p text source-ids))
            (condition-case err
                (pcase-let* ((`(,form . ,end) (read-from-string text))
                             (tail (substring text end))
                             (rewritten (supertag-tag-merge--rewrite-structured
                                         form source-ids target-id)))
                  (if (not (string-match-p "\\`[[:space:]]*\\'" tail))
                      (push (list :kind :free-text-query :name name :text text) warnings)
                    (unless (equal form rewritten)
                      (push (list :name name :old text :new (prin1-to-string rewritten))
                            updates))))
              (error
               (push (list :kind :free-text-query :name name :text text
                           :error (error-message-string err))
                     warnings)))))))
    (cons (nreverse updates) (nreverse warnings))))

(defun supertag-tag-merge-plan (tag-ids target-id)
  "Build and return a tag merge plan without mutating data.
TAG-IDS are the tags participating in the merge.  TARGET-ID may name one
of them, another existing tag, or a new tag."
  (let* ((participants
          (supertag-tag-merge--unique
           (mapcar (lambda (id)
                     (unless (stringp id) (error "Invalid tag id: %S" id))
                     (let ((token (supertag-sanitize-tag-name id)))
                       (or (and (supertag-tag-get token) token)
                           (supertag-tag-resolve-occurrence token)
                           (error "Tag '%s' does not exist" id))))
                   tag-ids)))
         (target-name (supertag-sanitize-tag-name target-id))
         (existing-target
          (or (and (supertag-tag-get target-name) target-name)
              (supertag-tag-resolve-occurrence target-name)))
         (canonical-target-name
          (if existing-target
              (supertag-tag-merge--canonical-token existing-target)
            target-name))
         (stable-mode (cl-every #'supertag-tag-stable-id-p participants))
         (target (or existing-target
                     (and stable-mode (supertag-tag--new-stable-id))
                     target-name)))
    (unless (>= (length participants) 2)
      (error "Tag merge requires at least two participating tags"))
    (let* ((target-exists-p (and existing-target t))
           (source-ids (if (member target participants)
                           (remove target participants)
                         participants)))
      (let* ((nodes (supertag-tag-merge--affected-nodes source-ids))
             (files (supertag-tag-merge--unique
                     (delq nil (mapcar (lambda (node) (plist-get node :file)) nodes))))
             (target-token
              (if target-exists-p
                  (supertag-tag-merge--canonical-token target)
                target-name)))

        (pcase-let* ((`(,query-updates . ,query-warnings)
                       (supertag-tag-merge--saved-query-changes source-ids target)))
          (list :participants participants
                :source-ids source-ids
                :target-id target
                :target-name canonical-target-name
                :target-token target-token
                :target-exists-p target-exists-p
                :nodes nodes
                :files files
                :file-token-rewrites
                (supertag-tag-merge--file-token-rewrites
                 nodes source-ids target-token)
                :saved-query-updates query-updates
                :conflicts (supertag-tag-merge--file-conflicts nodes)
                :warnings query-warnings))))))

(defun supertag-tag-merge--rewrite-node-tags (tags source-ids target-id)
  "Replace SOURCE-IDS in TAGS with TARGET-ID and deduplicate."
  (supertag-tag-merge--unique
   (mapcar (lambda (tag-id) (if (member tag-id source-ids) target-id tag-id))
           tags)))


(defun supertag-tag-merge--rewrite-nodes (plan)
  "Rewrite affected node tag lists from PLAN."
  (let ((sources (plist-get plan :source-ids))
        (target (plist-get plan :target-id))
        (token-rewrites (plist-get plan :file-token-rewrites)))
    (dolist (node (plist-get plan :nodes))
      (let ((node-id (plist-get node :id)))
        (supertag-node-update
         node-id
         (lambda (current)
           (let ((copy (copy-sequence current)))
             (setq copy
                   (plist-put
                    copy :tags
                    (supertag-tag-merge--rewrite-node-tags
                     (or (plist-get current :tags) '()) sources target)))
             (when (plist-member current :tag-occurrences)
               (setq copy
                     (plist-put
                      copy :tag-occurrences
                      (supertag-tag-merge--unique
                       (mapcar
                        (lambda (token)
                          (or (cdr (assoc token token-rewrites)) token))
                        (plist-get current :tag-occurrences))))))
             copy)))))))


(defun supertag-tag-merge--delete-sources (plan)
  "Remove source definitions from PLAN."
  (dolist (source (plist-get plan :source-ids))
    (supertag-tag-delete source)))

(defun supertag-tag-merge--rewrite-relations (source-ids target-id)
  "Rewrite relation endpoints and identities from SOURCE-IDS to TARGET-ID."
  (let ((relations (supertag-store-get-collection :relations))
        (result (make-hash-table :test 'equal))
        unaffected affected)
    (maphash
     (lambda (_id relation)
       (if (or (member (plist-get relation :from) source-ids)
               (member (plist-get relation :to) source-ids))
           (push relation affected)
         (push relation unaffected)))
     relations)
    (dolist (relation (append unaffected affected))
      (let* ((copy (copy-tree relation))
             (from (supertag-tag-merge--replace-tag-value
                    (plist-get copy :from) source-ids target-id))
             (to (supertag-tag-merge--replace-tag-value
                  (plist-get copy :to) source-ids target-id))
             (type (plist-get copy :type))
             (kind (supertag-relation-kind copy))
             (field-id (plist-get copy :field-id))
             (link-definition-id (plist-get copy :link-definition-id))
             (id (supertag-generate-relation-id
                  from to type kind field-id link-definition-id)))
        (setq copy (plist-put copy :from from))
        (setq copy (plist-put copy :to to))
        (setq copy (plist-put copy :id id))
        (unless (gethash id result)
          (puthash id copy result))))
    (supertag-update (list :relations) result)))

(defun supertag-tag-merge--rewrite-automations (source-ids target-id)
  "Rewrite SOURCE-IDS to TARGET-ID in stored automations."
  (let ((automations (supertag-store-get-collection :automations)) updates)
    (maphash
     (lambda (id automation)
       (let ((rewritten (supertag-tag-merge--rewrite-structured
                         automation source-ids target-id)))
         (unless (equal automation rewritten)
           (push (cons id rewritten) updates))))
     automations)
    (dolist (entry updates)
      (supertag-store-put-entity :automations (car entry) (cdr entry) t))
    (length updates)))

(defun supertag-tag-merge--copy-view-configs ()
  "Return a deep copy of loaded view configs, or nil when unavailable."
  (when (and (boundp 'supertag--view-configs)
             (hash-table-p supertag--view-configs))
    (let ((copy (make-hash-table :test (hash-table-test supertag--view-configs))))
      (maphash (lambda (key value) (puthash key (copy-tree value) copy))
               supertag--view-configs)
      copy)))

(defun supertag-tag-merge--rewrite-view-configs (source-ids target-id)
  "Rewrite SOURCE-IDS to TARGET-ID in loaded view configurations."
  (when (and (boundp 'supertag--view-configs)
             (hash-table-p supertag--view-configs))
    (maphash
     (lambda (key config)
       (puthash key
                (supertag-tag-merge--rewrite-structured config source-ids target-id)
                supertag--view-configs))
     supertag--view-configs)))

(defun supertag-tag-merge--apply-query-updates (updates)
  "Apply saved query UPDATES, rejecting stale source text."
  (when (and updates (boundp 'supertag-query-saved))
    (dolist (update updates)
      (let* ((name (plist-get update :name))
             (cell (assoc name supertag-query-saved)))
        (unless (and cell (equal (cdr cell) (plist-get update :old)))
          (error "Saved query '%s' changed after merge preview" name))
        (setcdr cell (plist-get update :new))))))

(defun supertag-tag-merge--snapshot-files (files)
  "Copy FILES to a temporary recovery directory."
  (when files
    (let ((dir (make-temp-file "supertag-tag-merge-backup" t))
          snapshots
          (index 0))
      (dolist (file files)
        (let ((backup (expand-file-name (number-to-string index) dir)))
          (copy-file file backup t t)
          (push (cons file backup) snapshots)
          (setq index (1+ index))))
      (list :dir dir :files (nreverse snapshots)))))

(defun supertag-tag-merge--restore-files (snapshot)
  "Restore files from SNAPSHOT and refresh visiting buffers."
  (dolist (entry (plist-get snapshot :files))
    (copy-file (cdr entry) (car entry) t t)
    (when-let* ((buffer (get-file-buffer (car entry))))
      (with-current-buffer buffer
        (revert-buffer t t t)))))

(defun supertag-tag-merge--delete-snapshot (snapshot)
  "Delete temporary SNAPSHOT data."
  (when-let* ((dir (plist-get snapshot :dir)))
    (ignore-errors (delete-directory dir t))))

(defun supertag-tag-merge--rebuild-derived-state ()
  "Rebuild caches and indexes touched by a tag merge."
  (supertag-index-rebuild-all))

(defun supertag-tag-merge--rewrite-files (plan)
  "Rewrite source tag text in PLAN's Org files and return change count."
  (let ((total 0)
        (files (plist-get plan :files)))
    (dolist (rewrite (plist-get plan :file-token-rewrites) total)
      (setq total
            (+ total
               (or (supertag-view-helper-rename-tag-text-in-files
                    (car rewrite) (cdr rewrite) files)
                   0))))))

(defun supertag-tag-merge-execute (plan)
  "Execute a conflict-free tag merge PLAN.
Signals before writing when PLAN contains conflicts.  Store changes roll
back through `supertag-with-transaction'; Org files and loaded registries
are restored from snapshots if any later step fails."
  (when (plist-get plan :conflicts)
    (error "Tag merge has %d unresolved conflict(s)"
           (length (plist-get plan :conflicts))))
  (let* ((fresh-file-conflicts
          (supertag-tag-merge--file-conflicts (plist-get plan :nodes)))
         (query-before (and (boundp 'supertag-query-saved)
                            (copy-tree supertag-query-saved)))
         (views-before (supertag-tag-merge--copy-view-configs))
         (snapshot nil)
         (keep-snapshot nil))
    (when fresh-file-conflicts
      (error "Tag merge file preflight failed: %S" fresh-file-conflicts))
    (setq snapshot (supertag-tag-merge--snapshot-files (plist-get plan :files)))
    (unwind-protect
        (condition-case err
            (let ((file-changes
                   (supertag-with-transaction
                     (unless (plist-get plan :target-exists-p)
                       (supertag-tag-create (list :id (plist-get plan :target-id)
                                                  :name (plist-get plan :target-name))))

                     (supertag-tag-merge--rewrite-nodes plan)

                     (supertag-tag-merge--delete-sources plan)
                     (supertag-tag-merge--rewrite-relations
                      (plist-get plan :source-ids) (plist-get plan :target-id))
                     (supertag-tag-merge--rewrite-automations
                      (plist-get plan :source-ids) (plist-get plan :target-id))
                     (supertag-tag-merge--rewrite-view-configs
                      (plist-get plan :source-ids) (plist-get plan :target-id))
                     (supertag-tag-merge--apply-query-updates
                      (plist-get plan :saved-query-updates))
                     (let ((count (supertag-tag-merge--rewrite-files plan)))
                       ;; A cache/index failure is still a merge failure, so keep
                       ;; it inside the store transaction and restore the files.
                       (supertag-tag-merge--rebuild-derived-state)
                       count))))
              (list :status :merged
                    :target-id (plist-get plan :target-id)
                    :source-ids (plist-get plan :source-ids)
                    :node-count (length (plist-get plan :nodes))
                    :file-change-count file-changes
                    :warnings (plist-get plan :warnings)))
          (error
           (let (restore-error)
             (when snapshot
               (condition-case file-error
                   (supertag-tag-merge--restore-files snapshot)
                 (error
                  (setq restore-error file-error)
                  (setq keep-snapshot t))))
             (when (boundp 'supertag-query-saved)
               (setq supertag-query-saved query-before))
             (when (and (boundp 'supertag--view-configs) views-before)
               (setq supertag--view-configs views-before))
             (ignore-errors (supertag-tag-merge--rebuild-derived-state))
             (if restore-error
                 (error "Tag merge failed (%s), and file recovery failed (%s).  Backups kept at %s"
                        (error-message-string err)
                        (error-message-string restore-error)
                        (plist-get snapshot :dir))
               (signal (car err) (cdr err))))))
      (unless keep-snapshot
        (supertag-tag-merge--delete-snapshot snapshot)))))

;;; --- Tag rekey ---

(defun supertag-tag-rename--mapped (value mapping)
  "Return VALUE's replacement from MAPPING, or VALUE when unchanged."
  (or (cdr (assoc value mapping)) value))

(defun supertag-tag-rename--rewrite-values (value mapping)
  "Recursively rewrite exact tag identifiers in VALUE using MAPPING."
  (cond
   ((stringp value)
    (supertag-tag-rename--mapped value mapping))
   ((hash-table-p value)
    (let ((copy (make-hash-table :test (hash-table-test value))))
      (maphash
       (lambda (key item)
         (puthash key
                  (supertag-tag-rename--rewrite-values item mapping)
                  copy))
       value)
      copy))
   ((consp value)
    (mapcar
     (lambda (item)
       (supertag-tag-rename--rewrite-values item mapping))
     value))
   (t value)))

(defun supertag-tag-rename--rewrite-structured (form mapping)
  "Rewrite tag identifiers in structured FORM according to MAPPING."
  (cond
   ((atom form) form)
   ((memq (car form) '(has-tag tag))
    (cons (car form)
          (cons (supertag-tag-rename--mapped (cadr form) mapping)
                (mapcar
                 (lambda (item)
                   (supertag-tag-rename--rewrite-structured item mapping))
                 (cddr form)))))
   ((memq (car form) '(has-any-tag has-all-tags))
    (cons (car form)
          (mapcar
           (lambda (item)
             (supertag-tag-rename--mapped item mapping))
           (cdr form))))
   ((supertag-tag-merge--plist-p form)
    (let (result)
      (while form
        (let ((key (pop form))
              (value (pop form)))
          (setq result
                (append
                 result
                 (list
                  key
                  (if (memq key supertag-tag-merge--tag-slot-keys)
                      (cond
                       ((stringp value)
                        (supertag-tag-rename--mapped value mapping))
                       ((listp value)
                        (mapcar
                         (lambda (item)
                           (supertag-tag-rename--mapped item mapping))
                         value))
                       (t value))
                    (supertag-tag-rename--rewrite-structured
                     value mapping)))))))
      result))
   (t
    (mapcar
     (lambda (item)
       (supertag-tag-rename--rewrite-structured item mapping))
     form))))

(defun supertag-tag-rename--saved-query-changes (mapping)
  "Return (UPDATES . CONFLICTS) for saved queries touched by MAPPING."
  (let ((sources (mapcar #'car mapping))
        updates conflicts)
    (when (boundp 'supertag-query-saved)
      (dolist (entry supertag-query-saved)
        (let ((name (car entry))
              (text (cdr entry)))
          (when (and (stringp text)
                     (supertag-tag-merge--string-mentions-source-p
                      text sources))
            (condition-case err
                (pcase-let* ((`(,form . ,end) (read-from-string text))
                             (tail (substring text end))
                             (rewritten
                              (supertag-tag-rename--rewrite-structured
                               form mapping)))
                  (if (string-match-p "\\`[[:space:]]*\\'" tail)
                      (unless (equal form rewritten)
                        (push (list :name name :old text
                                    :new (prin1-to-string rewritten))
                              updates))
                    (push (list :kind :free-text-query
                                :name name :text text)
                          conflicts)))
              (error
               (push (list :kind :invalid-saved-query
                           :name name :text text
                           :error (error-message-string err))
                     conflicts)))))))
    (cons (nreverse updates) (nreverse conflicts))))

(cl-defun supertag-tag-rename-plan (old-id new-id)
  "Build a conflict-checked rekey plan for OLD-ID as NEW-ID."
  (let* ((old (supertag-sanitize-tag-name old-id))
         (new (supertag-sanitize-tag-name new-id)))
    (unless (supertag-tag-get old)
      (error "Tag '%s' not found" old))
    (when (equal old new)
      (error "Tag '%s' already has that name" old))
    (let* ((sources (list old))
           (mapping (list (cons old new)))
           (collision-conflicts
            (when (supertag-tag-get new)
              (list (list :kind :tag-id-collision :target-id new))))
           (nodes (supertag-tag-merge--affected-nodes sources))
           (file-backed-nodes
            (cl-remove-if-not
             (lambda (node) (stringp (plist-get node :file)))
             nodes))
           (files
            (supertag-tag-merge--unique
             (mapcar (lambda (node) (plist-get node :file))
                     file-backed-nodes)))
           (query-result
            (supertag-tag-rename--saved-query-changes mapping)))
      (list :old-id old
            :target-id new
            :mapping mapping
            :nodes nodes
            :files files
            :saved-query-updates (car query-result)
            :conflicts
            (append collision-conflicts
                    (supertag-tag-merge--file-conflicts file-backed-nodes)
                    (cdr query-result))))))

(defun supertag-tag-rename--rewrite-tags (mapping)
  "Rekey tag entities using MAPPING."
  (let ((result (make-hash-table :test 'equal)))
    (maphash
     (lambda (tag-id raw-tag)
       (let* ((new-id (supertag-tag-rename--mapped tag-id mapping))
              (tag
               (supertag-tag-rename--rewrite-structured
                (copy-tree (supertag--ensure-plist raw-tag))
                mapping)))
         (setq tag
               (plist-put tag :extends
                          (supertag-tag-rename--mapped
                           (plist-get tag :extends) mapping)))
         (when (assoc tag-id mapping)
           (setq tag (plist-put tag :id new-id))
           (setq tag (plist-put tag :name new-id)))

         (when (gethash new-id result)
           (error "Tag rename produced duplicate id '%s'" new-id))
         (puthash new-id tag result)))
     (supertag-store-get-collection :tags))
    (supertag-update '(:tags) result)))

(defun supertag-tag-rename--rewrite-nodes (mapping)
  "Rewrite node tag lists using MAPPING."
  (let* ((nodes (supertag-store-get-collection :nodes))
         (result (copy-hash-table nodes)))
    (maphash
     (lambda (node-id raw-node)
       (let* ((node (copy-tree (supertag--ensure-plist raw-node)))
              (tags (plist-get node :tags))
              (rewritten
               (mapcar
                (lambda (tag-id)
                  (supertag-tag-rename--mapped tag-id mapping))
                tags)))
         (unless (equal tags rewritten)
           (puthash node-id
                    (plist-put node :tags
                               (supertag-tag-merge--unique rewritten))
                    result))))
     nodes)
    (supertag-update '(:nodes) result)))

(defun supertag-tag-rename--rewrite-relations (mapping)
  "Rewrite relation endpoints and deterministic IDs using MAPPING."
  (let ((result (make-hash-table :test 'equal)))
    (maphash
     (lambda (_relation-id raw-relation)
       (let* ((relation
               (supertag-tag-rename--rewrite-structured
                (copy-tree raw-relation) mapping))
              (from (supertag-tag-rename--mapped
                     (plist-get relation :from) mapping))
              (to (supertag-tag-rename--mapped
                   (plist-get relation :to) mapping))
              (type (plist-get relation :type))
              (new-id
               (supertag-generate-relation-id
                from to type
                (supertag-relation-kind relation)
                (plist-get relation :field-id)
                (plist-get relation :link-definition-id))))
         (setq relation (plist-put relation :from from))
         (setq relation (plist-put relation :to to))
         (setq relation (plist-put relation :id new-id))
         (when (gethash new-id result)
           (error "Tag rename produced duplicate relation '%s'" new-id))
         (puthash new-id relation result)))
     (supertag-store-get-collection :relations))
    (supertag-update '(:relations) result)))


(defun supertag-tag-rename--rewrite-store-configs (mapping)
  "Rewrite structured tag references in Store configuration collections."
  (dolist (collection '(:automations :boards))
    (let ((bucket (supertag-store-get-collection collection))
          (result (make-hash-table :test 'equal)))
      (maphash
       (lambda (id value)
         (puthash id
                  (supertag-tag-rename--rewrite-structured
                   value mapping)
                  result))
       bucket)
      (supertag-update (list collection) result))))

(defun supertag-tag-rename--rewrite-view-configs (mapping)
  "Rewrite tag references in loaded view configurations."
  (when (and (boundp 'supertag--view-configs)
             (hash-table-p supertag--view-configs))
    (maphash
     (lambda (id config)
       (puthash id
                (supertag-tag-rename--rewrite-structured
                 config mapping)
                supertag--view-configs))
     supertag--view-configs)))

(defun supertag-tag-rename--rewrite-files (plan)
  "Apply PLAN's tag mapping to its Org files."
  (let ((total 0)
        (files (plist-get plan :files)))
    (dolist (entry (plist-get plan :mapping) total)
      (setq total
            (+ total
               (supertag-view-helper-rename-tag-text-in-files
                (car entry) (cdr entry) files))))))

(defun supertag-tag-rename-execute (plan)
  "Execute conflict-free tag rename PLAN with rollback."
  (when (plist-get plan :conflicts)
    (error "Tag rename has %d conflict(s): %S"
           (length (plist-get plan :conflicts))
           (plist-get plan :conflicts)))
  (when-let* ((fresh-conflicts
               (supertag-tag-merge--file-conflicts
                (cl-remove-if-not
                 (lambda (node) (stringp (plist-get node :file)))
                 (plist-get plan :nodes)))))
    (error "Tag rename file preflight failed: %S" fresh-conflicts))
  (let* ((mapping (plist-get plan :mapping))
         (query-before (and (boundp 'supertag-query-saved)
                            (copy-tree supertag-query-saved)))
         (views-before (supertag-tag-merge--copy-view-configs))
         (snapshot (supertag-tag-merge--snapshot-files
                    (plist-get plan :files)))
         (keep-snapshot nil))
    (unwind-protect
        (condition-case err
            (let ((file-changes
                   (supertag-with-transaction
                     (supertag-tag-rename--rewrite-tags mapping)
                     (supertag-tag-rename--rewrite-nodes mapping)
                     (supertag-tag-rename--rewrite-relations mapping)


                     (supertag-tag-rename--rewrite-store-configs mapping)
                     (supertag-tag-rename--rewrite-view-configs mapping)
                     (supertag-tag-merge--apply-query-updates
                      (plist-get plan :saved-query-updates))
                     (let ((count
                            (supertag-tag-rename--rewrite-files plan)))
                       (supertag-tag-merge--rebuild-derived-state)
                       count))))
              (list :status :renamed
                    :target-id (plist-get plan :target-id)
                    :mapping mapping
                    :node-count (length (plist-get plan :nodes))
                    :file-change-count file-changes))
          (error
           (let (restore-error)
             (when snapshot
               (condition-case file-error
                   (supertag-tag-merge--restore-files snapshot)
                 (error
                  (setq restore-error file-error)
                  (setq keep-snapshot t))))
             (when (boundp 'supertag-query-saved)
               (setq supertag-query-saved query-before))
             (when (and (boundp 'supertag--view-configs) views-before)
               (setq supertag--view-configs views-before))
             (ignore-errors (supertag-tag-merge--rebuild-derived-state))
             (if restore-error
                 (error
                  "Tag rename failed (%s), file recovery failed (%s); backups kept at %s"
                  (error-message-string err)
                  (error-message-string restore-error)
                  (plist-get snapshot :dir))
               (signal (car err) (cdr err))))))
      (unless keep-snapshot
        (supertag-tag-merge--delete-snapshot snapshot)))))

;;; Tag display: plain faces and SVG

(defvar supertag-view-helper--font-lock-keywords
  '((supertag-view-helper--font-lock-matcher
     (0 (supertag-view-helper--matched-tag-face) t)))
  "Font-lock keywords for highlighting inline tags.")

(defvar supertag-view-svg-tag--font-lock-keywords
  '((supertag-view-helper--font-lock-matcher
     (0 (supertag-svg-tag--match-handler) t)))
  "Font-lock keywords for SVG tag rendering.")

;;;----------------------------------------------------------------------
;;; Constants and Configuration
;;;----------------------------------------------------------------------

(defvar supertag-view-helper--valid-tag-chars nil
  "Character class used to detect inline tags.
This string is spliced directly into [] expressions, so \"^\" negates the set.
Anything except whitespace-like characters and another # counts as part of the tag,
allowing slashes (as ordinary name characters) and arbitrary unicode/emoji symbols.")

;; Always refresh the value so reloading this file picks up updates.
;; Full-width hash and CJK punctuation terminate a tag name, matching
;; `supertag-inline-tag-regexp'.
(setq supertag-view-helper--valid-tag-chars
      (concat "^[:space:]#" supertag-inline-tag-terminator-chars))

(defgroup supertag-view-style nil
  "Customization options for supertag inline tag styling."
  :group 'supertag)

(defcustom supertag-view-style-tag-face-properties
  '(:foreground "snow3")
  "Face properties for inline supertags.
This should be a plist of face attributes."
  :type '(plist :key-type symbol :value-type sexp)
  :group 'supertag-view-style)

(defcustom supertag-view-style-auto-enable t
  "Whether to automatically enable supertag-view-style-mode in org buffers."
  :type 'boolean
  :group 'supertag-view-style)

(defun supertag-view-helper--inline-tag-range-at (position)
  "Return the range-aware prose Tag match starting at POSITION."
  (save-match-data
    (save-excursion
      (goto-char position)
      (let* ((context (org-element-context))
             (type (org-element-type context))
             (heading (org-element-lineage context '(headline) t)))
        (when (and (memq type '(headline paragraph))
                   (not (org-element-lineage
                         context '(drawer property-drawer) t))
                   (not (and heading
                             (org-element-property :commentedp heading))))
          (cl-find position
                   (supertag-transform-inline-tag-matches-in-region
                    (line-beginning-position) (line-end-position) nil type)
                   :key #'car :test #'=))))))

(defun supertag-view-helper--font-lock-matcher (limit)
  "Find the next range-aware prose Tag before LIMIT."
  (catch 'match
    (while (re-search-forward supertag-inline-tag-regexp limit t)
      (let* ((tag-start (1- (match-beginning 2)))
             (range (supertag-view-helper--inline-tag-range-at tag-start)))
        (when range
          (set-match-data (list (nth 0 range) (nth 1 range)))
          (throw 'match t))))
    nil))

;;;----------------------------------------------------------------------
;;; Minor Mode Definition and Public API
;;;----------------------------------------------------------------------

;;;###autoload
(define-minor-mode supertag-view-style-mode
  "Minor mode for styling supertag inline tags.

When `supertag-svg-tag-enable' is non-nil, uses SVG pill badges.
Otherwise uses face-based rendering via `supertag-inline-face'."
  :lighter " Tag-Style"
  :group 'supertag-view-style
  (if supertag-view-style-mode
      (progn
        ;; Allow font-lock to manage the `display' property for SVG rendering
        (make-local-variable 'font-lock-extra-managed-props)
        (cl-pushnew 'display font-lock-extra-managed-props)
        (font-lock-add-keywords nil (supertag-view-helper--get-font-lock-keywords) t)
        (supertag-view-helper--refresh-fontification))
    (font-lock-remove-keywords nil supertag-view-helper--font-lock-keywords)
    (when (bound-and-true-p supertag-view-svg-tag--font-lock-keywords)
      (font-lock-remove-keywords nil supertag-view-svg-tag--font-lock-keywords))
    (supertag-view-helper--refresh-fontification)))

(defun supertag-view-helper--get-font-lock-keywords ()
  "Return the appropriate font-lock keywords based on current config.
Prefers SVG keywords when `supertag-svg-tag-enable' is non-nil."
  (if (and (bound-and-true-p supertag-svg-tag-enable)
           (bound-and-true-p supertag-view-svg-tag--font-lock-keywords)
           (fboundp 'svg-create))
      supertag-view-svg-tag--font-lock-keywords
    supertag-view-helper--font-lock-keywords))

(defun supertag-view-helper--refresh-fontification ()
  "Refresh font-lock fontification in the current buffer."
  (if (fboundp 'font-lock-flush)
      (font-lock-flush)
    (font-lock-fontify-buffer)))

(defun supertag-view-helper--auto-enable ()
  "Auto-enable supertag-view-style-mode in org buffers if configured."
  (when supertag-view-style-auto-enable
    (supertag-view-style-mode 1)))

(defun supertag-view-helper--enable-existing-org-buffers ()
  "Auto-enable inline tag styling in already existing Org buffers."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'org-mode)
                 (not supertag-view-style-mode))
        (supertag-view-helper--auto-enable)))))

;;;----------------------------------------------------------------------
;;; Face Definitions and Font-lock Integration
;;;----------------------------------------------------------------------

(defface supertag-inline-face
  `((t ,supertag-view-style-tag-face-properties))
  "Face for supertag inline tags."
  :group 'supertag-view-style)

(defcustom supertag-view-style-unresolved-tag-face-properties
  '(:inherit shadow :underline t)
  "Face properties for inline tag tokens with no registered tag.
This should be a plist of face attributes."
  :type '(plist :key-type symbol :value-type sexp)
  :group 'supertag-view-style)

(defface supertag-unresolved-tag-face
  `((t ,supertag-view-style-unresolved-tag-face-properties))
  "Face for inline tag tokens that resolve to no registered tag.
A token that merely looks like a tag must not render like a live one;
this face makes an unregistered or ambiguous token visibly different."
  :group 'supertag-view-style)

(defun supertag-view-helper--matched-tag-face ()
  "Return the face for the inline tag just matched by the matcher.
The match data covers the marker and the name.  A token owned by a
registered Semantic Tag gets `supertag-inline-face'; an unregistered or
ambiguous token gets `supertag-unresolved-tag-face'."
  (let ((name (buffer-substring-no-properties
               (1+ (match-beginning 0)) (match-end 0))))
    (if (and (fboundp 'supertag-tag-resolve-occurrence)
             (ignore-errors (supertag-tag-resolve-occurrence name)))
        'supertag-inline-face
      'supertag-unresolved-tag-face)))


;;;----------------------------------------------------------------------
;;; Customization
;;;----------------------------------------------------------------------

(defgroup supertag-view-svg-tag nil
  "SVG tag rendering for supertag inline #tags."
  :group 'supertag)

(defcustom supertag-svg-tag-enable t
  "When non-nil, render #tags as SVG pill badges.
When nil, falls back to face-based rendering via `supertag-inline-face'."
  :type 'boolean
  :group 'supertag-view-svg-tag)

(defcustom supertag-svg-tag-style 'colored
  "Visual style of SVG tags.
`colored' uses a deterministic pastel color per tag name.
`neutral' uses a subtle gray pill like typical note apps."
  :type '(choice (const :tag "Colored per-tag" colored)
                 (const :tag "Neutral gray pill" neutral))
  :group 'supertag-view-svg-tag)

(defcustom supertag-svg-tag-padding-x 8
  "Horizontal padding (px) inside the SVG tag."
  :type 'integer
  :group 'supertag-view-svg-tag)

(defcustom supertag-svg-tag-radius 100
  "Corner radius (px) of SVG tag badges.
Values larger than half the badge height are capped, so the default
creates a fully rounded pill."
  :type 'integer
  :group 'supertag-view-svg-tag)

(defcustom supertag-svg-tag-stroke-width 0
  "Stroke width for SVG tag borders.
Set to 0 to draw no border."
  :type 'number
  :group 'supertag-view-svg-tag)

(defcustom supertag-svg-tag-font-scale 0.68
  "Font size scale factor relative to the frame character height."
  :type 'number
  :group 'supertag-view-svg-tag)

(defcustom supertag-svg-tag-font-family nil
  "Explicit SVG font family, or nil to use the default face family.
Pin a single-width family when librsvg/pango selects a different face
from Emacs for the default family."
  :type '(choice (const :tag "Default face family" nil) string)
  :group 'supertag-view-svg-tag)

(defcustom supertag-svg-tag-min-column-em 0.6
  "Minimum width per display column, in units of the SVG font size.
Pango-CoreText family lookup in librsvg can select a 0.6 em extended
face from a super TTC such as Iosevka, while Emacs measures 0.5 em.
The 0.6 floor covers common monospaced families such as Menlo, DejaVu
and Iosevka Extended; CJK uses two columns (1.2 em, at least 1 em).
Set nil to disable the floor, for example when Emacs was started with
PANGOCAIRO_BACKEND=fc.  Nonpositive values also disable it.
This is a bounded fallback for common monospaced fonts and the current
samples, not a renderer measurement.  Fonts wider than 0.6 em per column
(such as SF Mono at 0.615 em) rely on side padding for the excess; very
long tags may still clip.  Increase this value or pin a single-width
family with `supertag-svg-tag-font-family' in that case."
  :type '(choice (const :tag "No floor" nil) number)
  :group 'supertag-view-svg-tag)

(defcustom supertag-svg-tag-show-hash nil
  "When non-nil, include the leading '#' in the SVG badge.
When nil, only the tag name is shown."
  :type 'boolean
  :group 'supertag-view-svg-tag)

(defcustom supertag-svg-tag-font-weight "500"
  "Font weight used inside SVG tags (e.g. \"normal\", \"500\", \"bold\")."
  :type 'string
  :group 'supertag-view-svg-tag)

(defcustom supertag-svg-tag-color-alpha 1.0
  "Opacity of the colored style background (0 = invisible, 1 = opaque)."
  :type 'number
  :group 'supertag-view-svg-tag)

;;;----------------------------------------------------------------------
;;; Color generation
;;;----------------------------------------------------------------------

(defun supertag-svg-tag--is-light-theme-p ()
  "Return non-nil if the current frame has a light background."
  (eq (frame-parameter nil 'background-mode) 'light))

(defun supertag-svg-tag--hash-to-index (str max)
  "Hash STR to an integer in [0, MAX)."
  (mod (abs (sxhash str)) max))

(defun supertag-svg-tag--hsl-color (hue saturation lightness)
  "Return a #rrggbb string from HUE (0-360), SATURATION and LIGHTNESS (0-1)."
  (apply #'color-rgb-to-hex
         (append (color-hsl-to-rgb (/ hue 360.0) saturation lightness)
                 '(2))))

(defun supertag-svg-tag--hsl-rgba (hue saturation lightness alpha)
  "Return an rgba(...) string from HUE, SATURATION, LIGHTNESS and ALPHA."
  (let ((rgb (color-hsl-to-rgb (/ hue 360.0) saturation lightness)))
    (format "rgba(%d,%d,%d,%s)"
            (round (* (nth 0 rgb) 255))
            (round (* (nth 1 rgb) 255))
            (round (* (nth 2 rgb) 255))
            alpha)))

(defun supertag-svg-tag--neutral-colors ()
  "Return (bg border fg) for the neutral gray style."
  (if (supertag-svg-tag--is-light-theme-p)
      (list "#f3f4f6" "#f3f4f6" "#374151")
    (list "#374151" "#374151" "#f3f4f6")))

(defun supertag-svg-tag--colored-colors (tag-name)
  "Return (bg border fg) for the colored style based on TAG-NAME."
  (let* ((idx (supertag-svg-tag--hash-to-index tag-name 20))
         (hue (* idx 18))
         (light-p (supertag-svg-tag--is-light-theme-p))
         (sat (if light-p 0.78 0.65))
         (lit (if light-p 0.82 0.40))
         (bg (supertag-svg-tag--hsl-rgba hue sat lit supertag-svg-tag-color-alpha))
         (border (supertag-svg-tag--hsl-color hue 0.65 (if light-p 0.68 0.48)))
         (fg (if light-p "#1e293b" "#f8fafc")))
    (list bg border fg)))

(defun supertag-svg-tag--get-colors (tag-name)
  "Return (bg border fg) color triple for TAG-NAME."
  (if (eq supertag-svg-tag-style 'neutral)
      (supertag-svg-tag--neutral-colors)
    (supertag-svg-tag--colored-colors tag-name)))

;;;----------------------------------------------------------------------
;;; SVG tag builder
;;;----------------------------------------------------------------------

(defvar supertag-svg-tag--cache (make-hash-table :test 'equal)
  "Cache of SVG images keyed by their visual inputs.")

(defun supertag-svg-tag--char-width ()
  "Return a usable character width in pixels."
  (if (display-graphic-p)
      (max 1 (frame-char-width))
    8))

(defun supertag-svg-tag--char-height ()
  "Return a usable character height in pixels."
  (if (display-graphic-p)
      (max 1 (frame-char-height))
    16))

(defun supertag-svg-tag--font-size-px ()
  "Return the pixel font size used for SVG tag text."
  (round (* (supertag-svg-tag--char-height) supertag-svg-tag-font-scale)))

(defun supertag-svg-tag--base-font-px ()
  "Return the default GUI font's positive pixel size, or nil."
  (when (display-graphic-p)
    (let ((size (ignore-errors (aref (font-info (face-font 'default)) 2))))
      (when (and (integerp size) (> size 0)) size))))

(defun supertag-svg-tag--text-pixel-width (text)
  "Estimate TEXT width using the SVG/default font pixel size ratio.
Accounts for CJK/double-width characters via `string-width'."
  (let ((font-size-px (supertag-svg-tag--font-size-px))
        (base-px (or (supertag-svg-tag--base-font-px)
                     (supertag-svg-tag--char-height))))
    (max 1 (ceiling (* (string-width text)
                       (supertag-svg-tag--char-width)
                       (/ (float font-size-px) base-px)))
         (if (and (numberp supertag-svg-tag-min-column-em)
                  (> supertag-svg-tag-min-column-em 0))
             (ceiling (* (string-width text) font-size-px
                         supertag-svg-tag-min-column-em))
           0))))

(defun supertag-svg-tag--default-font-family ()
  "Return the best available font family string for SVG."
  (if (and (stringp supertag-svg-tag-font-family)
           (> (length supertag-svg-tag-font-family) 0))
      supertag-svg-tag-font-family
    (let ((family (face-attribute 'default :family nil 'default)))
      (if (or (not family) (eq family 'unspecified))
          "sans-serif"
        family))))

(defun supertag-svg-tag--make-svg (text display-text)
  "Create an SVG image for tag TEXT, showing DISPLAY-TEXT.
Returns an Emacs image object suitable for the `display' text property."
  (let* ((char-h (supertag-svg-tag--char-height))
         (font-size-px (supertag-svg-tag--font-size-px))
         (text-w (supertag-svg-tag--text-pixel-width display-text))
         (pad-x supertag-svg-tag-padding-x)
         (img-h (max char-h (round (* char-h 1.15))))
         (img-w (+ text-w (* 2 pad-x)))
         (radius (min supertag-svg-tag-radius (/ img-h 2)))
         (colors (supertag-svg-tag--get-colors text))
         (bg (nth 0 colors))
         (border-clr (nth 1 colors))
         (fg (nth 2 colors))
         (svg (svg-create img-w img-h)))
    ;; Pill/capsule background
    (svg-rectangle svg 0 0 img-w img-h
                   :rx radius :ry radius
                   :fill bg
                   :stroke border-clr
                   :stroke-width supertag-svg-tag-stroke-width)
    ;; Vertically centered label
    (svg-text svg display-text
              :x (/ img-w 2)
              :y (/ img-h 2)
              :font-family (supertag-svg-tag--default-font-family)
              :font-size font-size-px
              :fill fg
              :text-anchor "middle"
              :dominant-baseline "central"
              :font-weight supertag-svg-tag-font-weight)
    (svg-image svg :scale 1 :ascent 'center)))

(defun supertag-svg-tag--get-cached (tag-name)
  "Get or create a cached SVG image for TAG-NAME."
  (let* ((display-text (if supertag-svg-tag-show-hash
                           tag-name
                         (if (string-prefix-p "#" tag-name)
                             (substring tag-name 1)
                           tag-name)))
         (key (list display-text
                    (supertag-svg-tag--default-font-family)
                    supertag-svg-tag-min-column-em
                    supertag-svg-tag-padding-x
                    supertag-svg-tag-font-weight
                    (supertag-svg-tag--base-font-px)
                    (supertag-svg-tag--char-width)
                    (supertag-svg-tag--char-height)
                    supertag-svg-tag-font-scale
                    supertag-svg-tag-style
                    (frame-parameter nil 'background-mode)
                    supertag-svg-tag-color-alpha)))
    (or (gethash key supertag-svg-tag--cache)
        (let ((img (supertag-svg-tag--make-svg tag-name display-text)))
          (puthash key img supertag-svg-tag--cache)
          img))))

(defun supertag-svg-tag--clear-cache ()
  "Clear the SVG image cache (call after theme changes)."
  (clrhash supertag-svg-tag--cache)
  (message "SVG tag cache cleared"))

;;;----------------------------------------------------------------------
;;; Font-lock integration
;;;----------------------------------------------------------------------

(defun supertag-svg-tag--match-handler ()
  "Font-lock match handler for #tag patterns.
Returns the appropriate display spec for the matched tag."
  (let ((tag (match-string 0)))
    (if (and supertag-svg-tag-enable
             (display-graphic-p)
             (fboundp 'svg-create))
        `(face nil display ,(supertag-svg-tag--get-cached tag))
      'supertag-inline-face)))


;;;----------------------------------------------------------------------
;;; Theme change hook
;;;----------------------------------------------------------------------

(defun supertag-svg-tag--on-theme-change (&rest _)
  "Clear SVG cache and refresh font-lock on theme change."
  (supertag-svg-tag--clear-cache)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when supertag-view-style-mode
        (supertag-view-helper--refresh-fontification)))))

(defun supertag-svg-tag--enable ()
  "Enable SVG tag rendering for supertag."
  (setq supertag-svg-tag-enable t)
  (supertag-svg-tag--refresh-all-buffers)
  (message "SVG tag rendering enabled"))

(defun supertag-svg-tag--disable ()
  "Disable SVG tag rendering, revert to face-based."
  (setq supertag-svg-tag-enable nil)
  (supertag-svg-tag--refresh-all-buffers)
  (message "SVG tag rendering disabled"))

;;;###autoload
(defun supertag-toggle-tag-style ()
  "Toggle SVG tag rendering on/off."
  (interactive)
  (if supertag-svg-tag-enable
      (supertag-svg-tag--disable)
    (supertag-svg-tag--enable)))

(defun supertag-svg-tag--refresh-all-buffers ()
  "Toggle between SVG and face keywords in all active mode buffers."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when supertag-view-style-mode
        ;; Remove both keyword sets, then add back the right one
        (font-lock-remove-keywords nil supertag-view-helper--font-lock-keywords)
        (font-lock-remove-keywords nil supertag-view-svg-tag--font-lock-keywords)
        (font-lock-add-keywords nil (supertag-view-helper--get-font-lock-keywords) t)
        (supertag-view-helper--refresh-fontification)))))

;;; Tag membership, Org text rules and compensated member writes

(defun supertag-capture--tag-membership-present-p (node-id tag-id)
  "Return non-nil when TAG-ID is present in NODE-ID's projected tags."
  (member tag-id (plist-get (supertag-node-get node-id) :tags)))

(defun supertag-capture-add-tags-to-nodes (node-ids tags &optional position)
  "Create TAGS when needed and add them to every NODE-ID in NODE-IDS.

All Tag occurrences for one node are saved and projected together.  Each node
is handled in one Store transaction, and a late failure restores any Org edit
before returning an error.  POSITION has the meaning accepted by
`supertag-service-org-add-tag'.  Return the stable Semantic Tag IDs in order."
  (unless node-ids
    (user-error "No nodes were supplied for capture Tags"))
  (unless (and (listp tags)
               tags
               (cl-every (lambda (tag)
                           (and (stringp tag) (not (string-empty-p tag))))
                         tags))
    (user-error "Capture Tags must be a non-empty list of names"))
  (let* ((tag-inputs
          (cl-delete-duplicates
           (mapcar (lambda (tag)
                     (cons tag (supertag-sanitize-tag-name tag)))
                   tags)
           :test (lambda (left right)
                   (string= (cdr left) (cdr right)))))
         (tokens (mapcar #'cdr tag-inputs))
         (tag-ids
          (mapcar
           (lambda (input)
             (let ((tag (car input))
                   (token (cdr input)))
               (or (and (supertag-tag-get tag) tag)
                   (supertag-tag-resolve-occurrence tag)
                   (supertag-tag-resolve-occurrence token))))
           tag-inputs))
         (tag-label (string-join tokens ", ")))
    (dolist (node-id node-ids)
      (unless (supertag-node-get node-id)
        (user-error "Node '%s' does not exist; Tags '%s' were not added"
                    node-id tag-label))
      (let* ((marker (supertag-node-location-find node-id))
             (buffer (and marker (marker-buffer marker)))
             (before-tick
              (and buffer
                   (with-current-buffer buffer
                     (buffer-chars-modified-tick)))))
        (unless (buffer-live-p buffer)
          (user-error "Node '%s' has no readable Org location" node-id))
        ;; Resolve the provider before any mutation or saver interception.
        ;; A first autoload inside cl-letf would replace the intercepted cell.
        (let ((definition
               (symbol-function 'supertag-service-org-save-and-project-current-node)))
          (when (autoloadp definition)
            (autoload-do-load
             definition 'supertag-service-org-save-and-project-current-node)))
        ;; Complete Sync loading before mutation or saver capture.
        (let ((definition (symbol-function 'supertag-sync--parse-file-header)))
          (when (autoloadp definition)
            (autoload-do-load definition 'supertag-sync--parse-file-header)))
        (condition-case cause
            (with-current-buffer buffer
              ;; Store rollback cannot undo a saved Org edit.  Keep the buffer
              ;; edit recoverable until the membership assertion has passed.
              (atomic-change-group
                (setq tag-ids
                      (supertag-with-transaction
                        (let* ((resolved-ids
                                (cl-mapcar
                                 (lambda (token existing-id)
                                   (or existing-id
                                       (plist-get
                                        (supertag-tag-create
                                         `(:name ,token))
                                        :id)))
                                 tokens tag-ids))
                               (save-and-project
                                (symbol-function
                                 'supertag-service-org-save-and-project-current-node))
                               projection-needed)
                          ;; Reuse the Org service's mutation logic for every
                          ;; occurrence, but defer its commit seam until all
                          ;; edits for this node have been composed.
                          (cl-letf
                              (((symbol-function
                                 'supertag-service-org-save-and-project-current-node)
                                (lambda (_node-id)
                                  (setq projection-needed t))))
                            (dolist (resolved-id resolved-ids)
                              (supertag-service-org-add-tag
                               node-id resolved-id position)))
                          ;; Existing physical occurrences may require repair
                          ;; even when none of the buffer edits changed text.
                          (when
                              (or projection-needed
                                  (cl-some
                                   (lambda (resolved-id)
                                     (not
                                      (supertag-capture--tag-membership-present-p
                                       node-id resolved-id)))
                                   resolved-ids))
                            (funcall save-and-project node-id))
                          (dolist (resolved-id resolved-ids)
                            (unless
                                (and
                                 (supertag-tag-get resolved-id)
                                 (supertag-capture--tag-membership-present-p
                                  node-id resolved-id))
                              (error
                               "membership projection did not contain every Tag")))
                          resolved-ids)))))
          (error
           ;; `atomic-change-group' has restored the pre-call buffer here.  If
           ;; the service changed it before failing, make that restoration
           ;; durable and reconcile the original Projection once more.
           (let ((compensation-error
                  (when
                      (with-current-buffer buffer
                        (/= before-tick (buffer-chars-modified-tick)))
                    (condition-case compensation-cause
                        (progn
                          (org-with-point-at
                              (or (supertag-node-location-find node-id)
                                  marker)
                            (supertag-service-org-save-and-project-current-node
                             node-id))
                          nil)
                      (error compensation-cause)))))
             (if compensation-error
                 (user-error
                  (concat "Could not register Tags '%s' on node '%s': %s; "
                          "restoring the Org file also failed: %s")
                  tag-label node-id (error-message-string cause)
                  (error-message-string compensation-error))
               (user-error
                "Could not register Tags '%s' on node '%s': %s"
                tag-label node-id (error-message-string cause))))))))
    tag-ids))

(defun supertag-capture-replace-tag-on-node (node-id old-tag new-tag)
  "Replace OLD-TAG with NEW-TAG on NODE-ID and return the new stable ID.
Create NEW-TAG only inside the node's Store transaction.  Retain the Org
edit until membership is verified, and compensate a saved edit on failure."
  (unless (and (stringp new-tag) (not (string-empty-p new-tag)))
    (user-error "Capture Tag must be a non-empty name"))
  (unless (supertag-node-get node-id)
    (user-error "Node '%s' does not exist; Tag '%s' was not replaced"
                node-id old-tag))
  (let* ((token (supertag-sanitize-tag-name new-tag))
         (tag-label token)
         (old-id (or (and (supertag-tag-get old-tag) old-tag)
                     (supertag-tag-resolve-occurrence old-tag)
                     (user-error "Unknown Tag '%s'" old-tag)))
         (marker (supertag-node-location-find node-id))
         (buffer (and marker (marker-buffer marker)))
         (before-tick (and buffer (with-current-buffer buffer
                                    (buffer-chars-modified-tick)))))
    (unless (buffer-live-p buffer)
      (user-error "Node '%s' has no readable Org location" node-id))
    (condition-case cause
        (with-current-buffer buffer
          (barf-if-buffer-read-only)
          (atomic-change-group
            (supertag-with-transaction
              (let ((new-id
                     (or (and (supertag-tag-get new-tag) new-tag)
                         (supertag-tag-resolve-occurrence new-tag)
                         (supertag-tag-resolve-occurrence token)
                         (plist-get (supertag-tag-create (list :name token)) :id))))
                (supertag-service-org-replace-tag node-id old-id new-id)
                (unless (and (supertag-capture--tag-membership-present-p node-id new-id)
                             (not (supertag-capture--tag-membership-present-p node-id old-id)))
                  (error "membership projection did not replace the Tag"))
                new-id))))
      (error
       ;; `atomic-change-group' has restored the pre-call buffer here.  If
       ;; the service changed it before failing, make that restoration
       ;; durable and reconcile the original Projection once more.
       (let ((compensation-error
              (when
                  (with-current-buffer buffer
                    (/= before-tick (buffer-chars-modified-tick)))
                (condition-case compensation-cause
                    (progn
                      (org-with-point-at
                          (or (supertag-node-location-find node-id)
                              marker)
                        (supertag-service-org-save-and-project-current-node
                         node-id))
                      nil)
                  (error compensation-cause)))))
         (if compensation-error
             (user-error
              (concat "Could not register Tags '%s' on node '%s': %s; "
                      "restoring the Org file also failed: %s")
              tag-label node-id (error-message-string cause)
              (error-message-string compensation-error))
           (user-error
            "Could not register Tags '%s' on node '%s': %s"
            tag-label node-id (error-message-string cause))))))))

(defun supertag-capture-add-tag-to-nodes (node-ids tag &optional position)
  "Create TAG when needed and add it to every NODE-ID in NODE-IDS.
POSITION has the meaning accepted by `supertag-service-org-add-tag'.  Return
the stable Semantic Tag ID."
  (car (supertag-capture-add-tags-to-nodes node-ids (list tag) position)))

(defun supertag-node-add-tag (node-id tag-id)
  "Add a tag to a node.
NODE-ID is the unique identifier of the node.
TAG-ID is the unique identifier of the tag.
Returns the updated node data."
  (supertag-node-update
   node-id
   (lambda (node)
     (when node
       (let* ((tags (plist-get node :tags))
              (present (and tags (member tag-id tags))))
         (unless present
           (let* ((copy (copy-sequence node))
                  (new-tags (cons tag-id (or tags '()))))
             (plist-put copy :tags new-tags)

             copy)))))))

(defun supertag-node-remove-tag (node-id tag-id)
  "Remove a tag from a node.
NODE-ID is the unique identifier of the node.
TAG-ID is the unique identifier of the tag.
Returns the updated node data."
  (let ((removed-p nil)
        (result nil))
    ;; First, update the node's tag list
    (setq result
          (supertag-node-update
           node-id
           (lambda (node)
             (when node
               (let* ((tags (plist-get node :tags))
                      (filtered (remove tag-id (or tags '()))))
                 (if (equal filtered tags)
                     node
                   (setq removed-p t)
                   (let ((copy (copy-sequence node)))
                     (plist-put copy :tags filtered))))))))
    ;; If a tag was actually removed, clear all its field values on this node
    (when removed-p
      )
    result))

(defun supertag-node-has-tag-p (node-id tag-id)
  "Check if a node has a specific tag.
NODE-ID is the unique identifier of the node.
TAG-ID is the unique identifier of the tag.
Returns t if the node has the tag, otherwise nil."
  (let ((node (supertag-node-get node-id)))
    (when node
      (let ((tags (plist-get node :tags)))
        (and tags (member tag-id tags))))))

(defun supertag-node-toggle-tag (node-id tag-id)
  "Toggle the tag status of a node.
NODE-ID is the unique identifier of the node.
TAG-ID is the unique identifier of the tag.
If the node has the tag, it is removed; otherwise, it is added.
Returns the updated node data."
  (if (supertag-node-has-tag-p node-id tag-id)
      (supertag-node-remove-tag node-id tag-id)
    (supertag-node-add-tag node-id tag-id)))

(defun supertag-service-org--semantic-tag-id (tag)
  "Return TAG as a Semantic Tag ID, or nil when it is unknown."
  (and (stringp tag)
       (or (and (supertag-tag-get tag) tag)
           (supertag-tag-resolve-occurrence tag))))

(defun supertag-service-org--tag-token (tag)
  "Return the canonical Org occurrence token for TAG."
  (let* ((id (or (supertag-service-org--semantic-tag-id tag)
                 (user-error "Unknown Tag '%s'" tag)))
         (entity (supertag-tag-get id)))
    (supertag-sanitize-tag-name (plist-get entity :name))))

(defun supertag-service-org--token-identifies-p (token tag-id)
  "Return non-nil when occurrence TOKEN resolves to TAG-ID."
  (equal tag-id (ignore-errors (supertag-tag-resolve-occurrence token))))

(defun supertag-service-org--tag-membership-present-p (node-id tag-id)
  "Return non-nil when TAG-ID is present in NODE-ID's projected tags."
  (member tag-id (supertag-service-org--node-tags node-id)))

(defun supertag-service-org--filetags ()
  "Return the current buffer's file-level tag tokens."
  (plist-get (supertag-sync--parse-file-header) :file-tags))

(defun supertag-service-org--set-filetags (tags)
  "Replace the current buffer's #+FILETAGS value with TAGS."
  (goto-char (point-min))
  (let ((value (mapconcat (lambda (tag) (concat ":" tag)) tags "")))
    (if (re-search-forward "^#\\+FILETAGS:\\s-*.*$" nil t)
        (if tags
            (replace-match (concat "#+FILETAGS: " value ":") t t)
          (delete-region (line-beginning-position)
                         (min (point-max) (1+ (line-end-position)))))
      (when tags
        (insert (concat "#+FILETAGS: " value ":\n"))))))

(defun supertag-service-org-add-tag (node-id tag-name &optional position)
  "Add TAG-NAME to NODE-ID's Org source, save, then reproject.
POSITION may be `beginning', `end', or a marker in the node buffer."
  (let* ((tag-id (or (supertag-service-org--semantic-tag-id tag-name)
                     (user-error "Unknown Tag '%s'" tag-name)))
         (token (supertag-service-org--tag-token tag-id))
         (repair-projection
          (not (supertag-service-org--tag-membership-present-p
                node-id tag-id))))
    (supertag-service-org--update-buffer-and-resync
     node-id
     (lambda ()
       (if (zerop (or (plist-get (supertag-node-get node-id) :level) 1))
           (let ((tags (supertag-service-org--filetags)))
             (unless (member token tags)
               (supertag-service-org--set-filetags (append tags (list token)))))
         (unless (member token (supertag-node-tag-occurrences-at-point))
           (pcase position
             ('beginning
              (org-back-to-heading t)
              (forward-word)
              (when (org-get-todo-state) (forward-word)))
             ((pred markerp)
              (when (eq (marker-buffer position) (current-buffer))
                (goto-char position)
                (when (org-at-heading-p)
                  (end-of-line))))
             (_ (end-of-line)))
           (supertag-view-helper-insert-tag-text token))))
     repair-projection)))

(defun supertag-service-org-remove-tag (node-id tag-name &optional repair-projection)
  "Remove TAG-NAME from NODE-ID's Org source, save, then reproject.
REPAIR-PROJECTION explicitly authorizes repairing an unchanged Org edit."
  (let ((tag-id (or (supertag-service-org--semantic-tag-id tag-name)
                    (user-error "Unknown Tag '%s'" tag-name))))
    (supertag-service-org--update-buffer-and-resync
     node-id
     (lambda ()
       (if (zerop (or (plist-get (supertag-node-get node-id) :level) 1))
           (supertag-service-org--set-filetags
            (cl-remove-if
             (lambda (token)
               (supertag-service-org--token-identifies-p token tag-id))
             (supertag-service-org--filetags)))
         (dolist (token (supertag-node-tag-occurrences-at-point))
           (when (supertag-service-org--token-identifies-p token tag-id)
             (supertag-view-helper-remove-tag-text token)))))
     repair-projection)))

(defun supertag-service-org-replace-tag (node-id old-tag-name new-tag-name &optional repair-projection)
  "Replace OLD-TAG-NAME with NEW-TAG-NAME in Org, then reproject NODE-ID.
REPAIR-PROJECTION explicitly authorizes repairing an unchanged Org edit."
  (let ((old-id (or (supertag-service-org--semantic-tag-id old-tag-name)
                    (user-error "Unknown Tag '%s'" old-tag-name)))
        (new-token (supertag-service-org--tag-token new-tag-name)))
    (supertag-service-org--update-buffer-and-resync
     node-id
     (lambda ()
       (if (zerop (or (plist-get (supertag-node-get node-id) :level) 1))
           (supertag-service-org--set-filetags
            (mapcar (lambda (tag)
                      (if (supertag-service-org--token-identifies-p tag old-id)
                          new-token
                        tag))
                    (supertag-service-org--filetags)))
         (dolist (token (supertag-node-tag-occurrences-at-point))
           (when (supertag-service-org--token-identifies-p token old-id)
             (supertag-view-helper-rename-tag-text-in-node
              token new-token)))))
     repair-projection)))

(defun supertag-view-helper-at-tag-line-p ()
  "Check if the current line is a tag line (contains #tags)."
  (save-excursion
    (beginning-of-line)
    (looking-at-p (concat "^[ \t]*#[" supertag-view-helper--valid-tag-chars "]+"))))

(defun supertag-view-helper-insert-tag-text (tag-name &optional position)
  "Insert tag text with intelligent spacing.
TAG-NAME is the tag name to display.
POSITION is optional insertion position.
This function works in any location within a node - heading or content area."
  (when position (goto-char position))
  (let* ((prev-char (char-before))
         (next-char (char-after))
         (at-tag-line (supertag-view-helper-at-tag-line-p))
         ;; Need space before if previous char exists and is not whitespace
         (need-space-before
          (and prev-char
               (not (memq prev-char '(?\s ?\t ?\n)))
               (or at-tag-line
                   ;; Check for alphanumeric or punctuation that needs separation
                   (and (>= prev-char ?a) (<= prev-char ?z))
                   (and (>= prev-char ?A) (<= prev-char ?Z))
                   (and (>= prev-char ?0) (<= prev-char ?9))
                   ;; Include common punctuation that should be separated
                   (memq prev-char '(?. ?, ?\; ?: ?! ?\? ?\)))
                   ;; Chinese/Japanese/Korean characters
                   (and (>= prev-char ?\u4e00) (<= prev-char ?\u9fff)))))
         ;; Need space after only if next char exists and is alphanumeric or chinese
         (need-space-after
          (and next-char
               (not (eq next-char ?\n))
               (not (memq next-char '(?\s ?\t ?. ?, ?\; ?: ?! ?\?)))
               (or (and (>= next-char ?a) (<= next-char ?z))
                   (and (>= next-char ?A) (<= next-char ?Z))
                   (and (>= next-char ?0) (<= next-char ?9))
                   ;; Chinese/Japanese/Korean characters
                   (and (>= next-char ?\u4e00) (<= next-char ?\u9fff))))))

    ;; Insert space before tag if needed
    (when need-space-before
      (insert " "))
    ;; Insert the tag
    (insert (concat "#" tag-name))

    ;; Insert space after tag if needed
    (when need-space-after
      (insert " "))))

(defun supertag-view-helper-remove-tag-text (tag-name)
  "Remove all occurrences of #TAG-NAME from the current node.
TAG-NAME is the tag name to remove."
  (save-excursion
    (org-back-to-heading t)
    (let ((subtree-end (save-excursion
                         (if (outline-next-heading) (point) (point-max))))
          (case-fold-search nil)
          (removed-count 0))
      (beginning-of-line)
      (while (re-search-forward supertag-inline-tag-regexp subtree-end t)
        (when (equal tag-name (match-string-no-properties 2))
          (delete-region (1- (match-beginning 2)) (match-end 2))
          (setq subtree-end (- subtree-end (1+ (length tag-name))))
          (setq removed-count (1+ removed-count))))
      removed-count)))

(defun supertag-view-helper-rename-tag-text-in-node (old-tag-name new-tag-name)
  "Rename #OLD-TAG-NAME to #NEW-TAG-NAME within the current node."
  (save-excursion
    (org-back-to-heading t)
    (let ((beg (point))
          (end (save-excursion
                 (if (outline-next-heading) (point) (point-max))))
          (renamed-count 0))
      (narrow-to-region beg end)
      (goto-char (point-min))
      (while (re-search-forward supertag-inline-tag-regexp nil t)
        (when (and (equal old-tag-name (match-string-no-properties 2))
                   (not (or (save-excursion
                              (goto-char (match-beginning 0))
                              (org-in-src-block-p))
                            (save-excursion
                              (goto-char (match-beginning 0))
                              (beginning-of-line)
                              (looking-at-p "^[ \t]*#\\+")))))
          (replace-match new-tag-name t t nil 2)
          (setq renamed-count (1+ renamed-count))))
      (widen)
      renamed-count)))

;;; Tag input and Org placement

(cl-defun supertag-ui-read-tag
    (prompt &optional (tag-ids nil tag-ids-supplied-p) allow-new allow-empty
            allow-namespace)
  "Read one Tag ID with hierarchy display names in completion.
PROMPT is the minibuffer prompt.  TAG-IDS defaults to every stored Tag
ID.  When ALLOW-NEW is non-nil, a valid new ID may be returned.  When
ALLOW-EMPTY is non-nil, empty input returns nil.  ALLOW-NAMESPACE is
accepted for backward compatibility but no longer creates virtual IDs."
  (ignore allow-namespace)
  (let* ((descriptors (supertag-query-tag-descriptors))
         (display-by-id (make-hash-table :test 'equal)))
    (dolist (entry descriptors)
      (puthash (plist-get entry :id) (plist-get entry :display) display-by-id))
    (let* ((known-tags
            (if tag-ids-supplied-p
                (sort (delete-dups (copy-sequence tag-ids)) #'string<)
              (mapcar (lambda (entry) (plist-get entry :id)) descriptors)))
           (candidate-map
            (mapcar
             (lambda (id)
               (cons (propertize
                      (or (gethash id display-by-id) id)
                      'supertag-tag-id id)
                     id))
             known-tags))
           (candidates (mapcar #'car candidate-map))
           (completion-extra-properties
            '(:affixation-function supertag-tag-affixate-candidates))
           (answer (completing-read
                    prompt
                    (if allow-empty (cons "" candidates) candidates)
                    nil (not allow-new))))
      (cond
       ((string-empty-p answer)
        (if allow-empty nil (user-error "A tag is required")))
       ((or (get-text-property 0 'supertag-tag-id answer)
            (assoc answer candidate-map))
        (or (get-text-property 0 'supertag-tag-id answer)
            (cdr (assoc answer candidate-map))))
       (allow-new answer)
       (t (user-error "Unknown tag '%s'" answer))))))

(defun supertag-ui-read-tags (prompt &optional tag-ids allow-new initial-tags)
  "Read zero or more Tag IDs with parent-aware completion.
PROMPT, TAG-IDS and ALLOW-NEW have the meaning used by
`supertag-ui-read-tag'.  INITIAL-TAGS are kept and omitted from later
choices."
  (let ((known-tags (or tag-ids (supertag-view-api-list-tag-ids)))
        (selected (copy-sequence initial-tags))
        choice)
    (while
        (let ((remaining
               (cl-set-difference known-tags selected :test #'equal)))
          (setq choice
                (unless (and (null remaining) (not allow-new))
                  (supertag-ui-read-tag
                   (if selected
                       (format "%s(selected: %s) "
                               prompt (string-join selected ", "))
                     prompt)
                   remaining allow-new t))))
      (unless (member choice selected)
        (setq selected (append selected (list choice)))))
    selected))

(defun supertag-ui--read-tag-field (current-value)
  "Read tag field value with multi-selection support.
CURRENT-VALUE is the existing value (can be string or list).
Returns a comma-separated string of selected tags."
  (let* ((all-tags (supertag-view-api-list-tag-ids))
         (current-tags (cond
                        ((stringp current-value)
                         (if (string-empty-p current-value)
                             nil
                           (split-string current-value "," t "[ \t\n\r]+")))
                        ((listp current-value) current-value)
                        (t nil)))
         (selected-tags '())
         (continue t))
    (while continue
      (let* ((remaining-tags (cl-remove-if (lambda (tag) (member tag selected-tags)) all-tags))
             (prompt (if selected-tags
                         (format "Selected: %s. Add another tag (or empty to finish): "
                                 (string-join selected-tags ", "))
                       "Select tag (or empty to finish): "))
             (choice (if remaining-tags
                         (supertag-ui-read-tag
                          prompt remaining-tags nil t)
                       "")))
        (if (or (null choice) (string-empty-p choice))
            (setq continue nil)
          (push choice selected-tags))))

    ;; Allow manual input via comma-separated string as fallback
    (when (and (null selected-tags) (not (string-empty-p (or current-value ""))))
      (let ((manual-input (read-string "Enter tags (comma-separated) or leave empty: "
                                       (if (stringp current-value) current-value ""))))
        (unless (string-empty-p manual-input)
          (setq selected-tags (split-string manual-input "," t "[ \t\n\r]+")))))

    ;; Return as comma-separated string for storage
    (if selected-tags
        (string-join (nreverse selected-tags) ",")
      "")))

(defun supertag-capture--get-from-tags-prompt (args)
  "Prompt for org-capture tags with completion on existing tags."
  (let* ((prompt (car args))
         (props (cdr args))
         (initial-input (plist-get props :initial-input))
         (all-tags (supertag-view-api-list-tag-ids))
         (initial-tags
          (when (and (stringp initial-input)
                     (not (string-empty-p initial-input)))
            (split-string initial-input "," t "[ \t\n\r]+"))))
    (supertag-ui-read-tags prompt all-tags t initial-tags)))

(defun supertag-view-api-list-tag-ids ()
  "Return canonical tag IDs (sorted)."
  (sort (mapcar (lambda (tag) (plist-get tag :id))
                (supertag-query-tag-descriptors))
        #'string<))

(defun supertag-view-helper-find-tag-insertion-point ()
  "Find the best position to insert tags in the current node.
Returns the position where tags should be inserted."
  (save-excursion
    (org-back-to-heading t)
    (let ((drawer-end (supertag-view-helper--find-drawer-end))
          (existing-tag-line (supertag-view-helper--find-existing-tag-line)))
      (cond
       ;; If there's already a tag line, position at the end of it
       (existing-tag-line
        (goto-char existing-tag-line)
        (end-of-line)
        (point))

       ;; If there's a drawer, position after it
       (drawer-end
        (goto-char drawer-end)
        (unless (bolp) (forward-line 1))
        ;; Skip empty lines after drawer
        (while (and (not (eobp))
                    (not (org-at-heading-p))
                    (looking-at-p "^[ \t]*$"))
          (forward-line 1))
        (beginning-of-line)
        (point))

       ;; No drawer, position directly after headline
       (t
        (end-of-line)
        (insert "\n")
        (beginning-of-line)
        (point))))))

(defun supertag-view-helper--find-drawer-end ()
  "Find the end position of the current node's drawer."
  (when (and (eq major-mode 'org-mode)
             (fboundp 'org-element-at-point))
    (save-excursion
      (org-back-to-heading t)
      (forward-line 1)
      (let ((end-pos nil)
            (section-end (save-excursion
                          (org-end-of-subtree t t)
                          (point))))
        ;; Find the end position of the last drawer
        (while (and (< (point) section-end)
                   (not (org-at-heading-p)))
          (let ((element (org-element-at-point)))
            (cond
             ;; Property drawer
             ((eq (org-element-type element) 'property-drawer)
              (setq end-pos (org-element-property :end element))
              (goto-char end-pos))
             ;; Other drawers
             ((eq (org-element-type element) 'drawer)
              (setq end-pos (org-element-property :end element))
              (goto-char end-pos))
             ;; Other elements, continue forward
             (t
              (forward-line 1)))))
        end-pos))))

(defun supertag-view-helper--find-existing-tag-line ()
  "Find the position of an existing tag line in the current node."
  (save-excursion
    (org-back-to-heading t)
    (let ((drawer-end (supertag-view-helper--find-drawer-end))
          (section-end (save-excursion
                        (org-end-of-subtree t t)
                        (point)))
          (tag-line-pos nil))
      ;; Start searching from the drawer end position, or from the heading if no drawer
      (goto-char (or drawer-end (progn (end-of-line) (point))))
      (forward-line 1)

      ;; Search for lines containing #tags within the node range
      (while (and (< (point) section-end)
                 (not (org-at-heading-p))
                 (not tag-line-pos))
        (beginning-of-line)
        ;; Check if the current line contains #tags (but not comment lines)
        (when (and (looking-at-p (concat "^[ \t]*#[" supertag-view-helper--valid-tag-chars "]+"))
                  (not (looking-at-p "^[ \t]*#\\+")))  ; Exclude org keywords
          (setq tag-line-pos (point)))
        (forward-line 1))

      tag-line-pos)))

(defun supertag-view-helper-tag-at-point-bounds ()
  "Return (NAME BEG . END) for the inline tag at point, or nil."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (let ((origin (point))
            (line-end (line-end-position)))
        (goto-char (line-beginning-position))
        (catch 'tag
          (while (supertag-view-helper--font-lock-matcher line-end)
            (when (and (<= (match-beginning 0) origin)
                       (< origin (match-end 0)))
              (throw 'tag (cl-list* (substring (match-string-no-properties 0) 1)
                                (match-beginning 0) (match-end 0))))))))))

(defun supertag-view-helper-get-tag-at-point ()
  "Get the inline supertag name at point.
Returns the tag name (without #) if found, nil otherwise."
  (car (supertag-view-helper-tag-at-point-bounds)))

;;; Shared Tag and Link completion: one local/global mode.

(defgroup supertag-completion nil
  "Completion settings for supertag."
  :group 'supertag
  :prefix "supertag-completion-")

(defcustom supertag-completion-auto-enable t
  "Whether to automatically enable tag completion in org-mode buffers.
When non-nil, `global-supertag-ui-completion-mode' will be enabled by default."
  :type 'boolean
  :group 'supertag-completion)

(defvar-local supertag-completion--last-unregistered-hint nil
  "Last unregistered tag token already hinted about in this buffer.
Prevents repeating the \"not registered\" echo message on every
boundary character typed after the same token.")

(defun supertag-completion--get-all-tags ()
  "Get all available tag names from the supertag store."
  (condition-case err
      (cl-remove-if-not #'supertag-transform-inline-tag-name-p
                        (mapcar (lambda (entry) (plist-get entry :id))
                                (supertag-query-tag-descriptors)))
    (error
     (message "supertag-completion: Failed to get tags: %S" err)
     '())))

(defun supertag-completion--get-node-tags (node-id)
  "Get resolved Semantic Tags currently applied to NODE-ID."
  (supertag-query-node-tags node-id))

(defun supertag-completion--get-all-tag-occurrences ()
  "Return sorted unique Org Tag Occurrences from projected nodes."
  (cl-remove-if-not #'supertag-transform-inline-tag-name-p
                    (supertag-query-tag-occurrences)))

(defun supertag-completion--valid-tag-char-p (char)
  "Return non-nil if CHAR should be considered part of a tag name.
Anything except whitespace/control characters, the (full-width) hash,
and full-width punctuation counts as valid.  This keeps completion
flexible enough for emoji while letting CJK punctuation end a tag the
way ASCII whitespace does."
  (and char
       (not (memq char '(?\s ?\t ?\n ?\r ?#)))
       (not (seq-position supertag-inline-tag-terminator-chars char))))

(defun supertag-completion--get-prefix-bounds ()
  "Find the bounds of a tag prefix at point, if any.
Returns (START . END) where START is right after the # character.
Handles edge cases: cursor right after # (empty prefix), mid-word, etc."
  (save-excursion
    (let* ((end (point))
           (start nil))

      ;; Walk backwards over valid tag characters
      (while (and (> (point) (point-min))
                  (supertag-completion--valid-tag-char-p
                   (char-before (point))))
        (backward-char))

      ;; Check if we're right after a (full-width) # character
      (when (and (> (point) (point-min))
                 (memq (char-before (point)) '(?# ?＃)))
        ;; start = right after # (where tag name begins or would begin)
        (setq start (point)))

      ;; Only return bounds if we found a # before the prefix
      (when start
        (cons start end)))))

(defun supertag-completion--decorate-candidate (candidate)
  "Attach Tag identity to CANDIDATE."
  (let* ((tag (supertag--ensure-plist (supertag-tag-get candidate)))
         (name (supertag-sanitize-tag-name
                (or (plist-get tag :name) candidate))))
    (propertize name 'supertag-tag-id candidate)))

(defun supertag-completion--restore-prefix (prefix)
  "Replace the current completion token with PREFIX."
  (when-let* ((bounds (and prefix (supertag-completion--get-prefix-bounds))))
    (delete-region (car bounds) (cdr bounds))
    (goto-char (car bounds))
    (insert prefix)))

(defun supertag-completion--display-sort (candidates)
  "Place `[New]' after the first existing item in CANDIDATES."
  (let ((new (cl-find-if
              (lambda (candidate)
                (get-text-property 0 'is-new-tag candidate))
              candidates)))
    (if (not new)
        candidates
      (let ((existing (delq new (copy-sequence candidates))))
        (if existing
            (cons (car existing) (cons new (cdr existing)))
          (list new))))))

(defun supertag-completion--get-completion-table (prefix)
  "Return real Tag candidates and an explicit new-Tag action for PREFIX.
Slashes are ordinary tag-name characters and create no parent entity.
Selecting an existing candidate preserves its stable Tag ID.  New actions
carry a hidden final marker so unfinished input is not an exact match."
  (let* ((safe-prefix (or prefix ""))
         (node-id (org-id-get))
         (current-tags (when node-id (supertag-completion--get-node-tags node-id)))
         (semantic-tags (supertag-completion--get-all-tags))
         (unresolved-occurrences
          (seq-remove #'supertag-tag-resolve-occurrence
                      (supertag-completion--get-all-tag-occurrences)))
         (all-candidates
          (append
           (mapcar #'supertag-completion--decorate-candidate semantic-tags)
           (mapcar (lambda (token)
                     (propertize token 'supertag-tag-occurrence token))
                   unresolved-occurrences)))
         (available-tags
          (if current-tags
              (seq-remove
               (lambda (tag)
                 (let ((key (or (get-text-property 0 'supertag-tag-id tag)
                                (get-text-property 0 'supertag-tag-occurrence tag))))
                   (and key (member key current-tags))))
               all-candidates)
            all-candidates))
         (new-name safe-prefix)
         (should-add-new
          (and (not (string-empty-p safe-prefix))
               (supertag-transform-inline-tag-name-p new-name)
               (not (supertag-tag-resolve-occurrence new-name semantic-tags)))))
    (if should-add-new
        (let ((candidate (concat safe-prefix "\u200b")))
          (add-text-properties
           0 (length candidate)
           (list 'is-new-tag t 'new-tag-name new-name)
           candidate)
          (put-text-property (1- (length candidate)) (length candidate)
                             'display "" candidate)
          (append available-tags (list candidate)))
      available-tags)))

(defun supertag-completion--post-completion-action (selected-string)
  "Post-completion action invoked after the UI inserts SELECTED-STRING.
Display aliases are replaced with their canonical Org token before writing."
  (let* ((is-new (get-text-property 0 'is-new-tag selected-string))
         (prefix (get-text-property 0 'new-tag-name selected-string))
         (selected-name
          (replace-regexp-in-string
           "\u200b\\'" "" (substring-no-properties selected-string)))
         (selected-id (get-text-property 0 'supertag-tag-id selected-string))
         (new-name (get-text-property 0 'new-tag-name selected-string))
         (original-node-id (org-id-get))
         (normalized-token-p nil)
         (heading-position
          (save-excursion
            (when (ignore-errors (org-back-to-heading t) t)
              (copy-marker (point))))))

    (condition-case err
        (when-let* ((node-id (and (supertag-transform-inline-tag-name-p selected-name)
                                  (or original-node-id
                                      (supertag-node-identity-ensure-at-point)))))
          ;; Semantic Tag creation may precede the write, but membership never does.
          (let* ((tag-id
                 (or selected-id
                     (and is-new
                          (plist-get
                           (supertag-tag-create
                            `(:name ,new-name))
                           :id))))
                 (tag (supertag--ensure-plist (supertag-tag-get tag-id)))
                 (occurrence-token
                  (supertag-sanitize-tag-name (plist-get tag :name))))
            (unless (supertag-tag-get tag-id)
              (user-error "Tag '%s' does not exist" selected-name))
            (when-let* ((bounds (supertag-completion--get-prefix-bounds)))
              (delete-region (car bounds) (cdr bounds))
              (goto-char (car bounds))
              ;; A full-width trigger commits as the canonical half-width
              ;; token; scanners treat `#' as the canonical marker.
              (when (eq (char-before) ?＃)
                (delete-char -1)
                (insert "#"))
              (insert occurrence-token))
            (setq normalized-token-p t)
            (insert " ")
            (supertag-service-org-save-and-project-current-node node-id)
            (if is-new
                (message "New tag '%s' created and added to node %s"
                         occurrence-token node-id)
              (message "Tag '%s' added to node %s" occurrence-token node-id))))
      (error
       (unless normalized-token-p
         (supertag-completion--restore-prefix prefix))
       (when (and (not original-node-id) heading-position
                  (not normalized-token-p))
         (save-excursion
           (goto-char heading-position)
           (org-entry-delete (point) "ID")))
       (signal (car err) (cdr err))))))

(defun supertag-completion-at-point ()
  "Main `completion-at-point` function using the classic, compatible API."
  (when-let ((bounds (supertag-completion--get-prefix-bounds)))
    (let* ((start (car bounds))
           (end (cdr bounds))
           (prefix (buffer-substring-no-properties start end)))

      (list start end
            ;; 1. The completion table. Returns a custom completion function
            ;;    that always includes [Create New Tag] in results.
            ;;    Built to handle all completion actions for corfu/company compatibility.
            (lambda (str pred action)
              (let* ((live-bounds
                      (and (not (minibufferp))
                           (supertag-completion--get-prefix-bounds)))
                     (live-prefix
                      (if live-bounds
                          (buffer-substring-no-properties
                           (car live-bounds) (cdr live-bounds))
                        prefix))
                     (candidates
                      (supertag-completion--get-completion-table live-prefix))
                     (existing-candidates
                      (seq-remove
                       (lambda (candidate)
                         (or (get-text-property 0 'is-new-tag candidate)
                             (get-text-property 0 'supertag-tag-conflict
                                                candidate)
                             (get-text-property 0 'supertag-tag-occurrence
                                                candidate)))
                       candidates)))
                (cond
                 ;; Handle boundaries (corfu/company compatibility)
                 ((eq (car-safe action) 'boundaries) nil)
                 ;; Return metadata (both corfu and company use this for display)
                 ((eq action 'metadata)
                  '(metadata
                    (category . supertag-tag)
                    (display-sort-function . supertag-completion--display-sort)
                    (cycle-sort-function . identity)
                    (affixation-function . supertag-tag-affixate-candidates)
                    (company-kind
                     . (lambda (cand)
                         (cond
                          ((get-text-property 0 'is-new-tag cand) 'snippet)
                          ((get-text-property 0 'supertag-tag-conflict cand)
                           'text)
                          ((get-text-property 0 'supertag-tag-occurrence cand)
                           'text)
                          (t 'keyword))))
                    (annotation-function
                     . (lambda (cand)
                         (cond
                          ((get-text-property 0 'supertag-tag-conflict cand)
                           (propertize "  [Conflict]" 'face 'error))
                          ((get-text-property 0 'is-new-tag cand)
                           (propertize "  [New]" 'face 'warning))
                          ((get-text-property 0 'supertag-tag-occurrence cand)
                           (propertize "  [Unresolved]" 'face 'shadow)))))))
               ;; Return all candidates (for display).
               ;; Two gotchas to handle here:
               ;;
               ;; 1. orderless enumerates by calling TABLE with STR=""
               ;;    and filters with its own regexp. Gating the
               ;;    new-tag candidate on STR being non-empty makes it
               ;;    invisible to orderless.
               ;; 2. corfu caches CAPF data for the duration of the
               ;;    popup session and re-calls only the TABLE function
               ;;    on subsequent keystrokes — not the outer
               ;;    `supertag-completion-at-point'. A closure over
               ;;    `prefix' therefore freezes at popup-open time, so
               ;;    "#zz" expanded to "#zzzfr" still shows the
               ;;    "zz  [Create New Tag]" candidate instead of
               ;;    "zzzfr  [Create New Tag]".
               ;;
               ;; Solution: re-read the prefix from the live buffer on
               ;; every TABLE call. `get-prefix-bounds' walks backward
               ;; from point to the leading `#', so the value is always
               ;; current. Fall back to the captured PREFIX (mainly for
               ;; non-interactive callers and tests).
                 ((eq action t)
                  (complete-with-action t candidates str pred))
               ;; Test for exact match. NEVER report the user input as an
               ;; exact match against the "[Create New Tag]" candidate
               ;; — that would convince the UI that completion is done
               ;; and it would auto-commit the labeled candidate.
                 ((eq action 'lambda)
                  (test-completion str existing-candidates pred))
               ;; Try completion (return common prefix or t if unique).
               ;; CRITICAL: if the only matching candidate is our
               ;; new-tag entry, returning t (or the bare prefix as a
               ;; "complete" match) lets corfu commit it silently
               ;; without showing the popup. Force the popup by
               ;; pretending the completion has not finished.
                 ((null action)
                  (or (try-completion str existing-candidates pred)
                      ;; No existing Tag matches. Keep the popup open so
                      ;; the user can explicitly select the [New] row.
                      str))
                 ;; Boundaries and other actions.
                 (t
                  (complete-with-action action candidates str pred)))))

            ;; 2. The leading # already identifies this completion context.
            ;;    Bypass generic UI prefix thresholds so completion can start
            ;;    before the user has typed two or three tag characters.
            :company-prefix-length t

            ;; 3. EXCLUSIVE: tell completion-at-point that once we are
            ;;    inside a #tag context, no other CAPF should run.
            ;;    Without this, cape-dabbrev / cape-keyword / pcomplete
            ;;    get appended to our candidate list, their candidates
            ;;    can override our annotation/metadata, and the
            ;;    "[Create New Tag]" entry gets hidden or stripped of
            ;;    its label by the cape merging layer.
            :exclusive 'yes

            ;; 4. A SINGLE, UNIFIED :exit-function. This is also
            ;;    universally understood by all completion frameworks.
            :exit-function
            (lambda (selected-string status)
              ;; Only an explicit completion commits. A nil status is a
              ;; cancelled/incremental exit, never permission to create.
              (when (and (memq status '(finished exact sole))
                         (or (get-text-property 0 'supertag-tag-id
                                                selected-string)
                             (get-text-property 0 'is-new-tag selected-string)
                             (get-text-property 0 'supertag-tag-conflict
                                                selected-string)))
                (supertag-completion--post-completion-action selected-string)))))))

(defun supertag-completion--auto-record-on-boundary ()
  "Record an existing `#tag' right behind point after its delimiter.
Unknown text is never registered here; new Tags require selecting the
CAPF `[New]' candidate."
  (when (and (derived-mode-p 'org-mode)
             (not (supertag-completion--valid-tag-char-p (char-before)))
             (> (point) 2)
             ;; The char just before the separator must be a valid tag
             ;; char — otherwise we are not on a tag boundary.
             (supertag-completion--valid-tag-char-p (char-before (1- (point)))))
    (save-excursion
      (backward-char) ; step over the separator we just typed
      (when-let* ((bounds (supertag-completion--get-prefix-bounds))
                  (prefix (buffer-substring-no-properties
                           (car bounds) (cdr bounds)))
                  (_ (supertag-transform-inline-tag-name-p prefix)))
        (let ((tag-id (ignore-errors
                        (supertag-tag-resolve-occurrence prefix))))
          (if (null tag-id)
              ;; The token looks like a tag but is not registered.  Say so
              ;; once per token: silently leaving it unstyled and unrecorded
              ;; reads as success to the user.
              (unless (equal prefix
                             supertag-completion--last-unregistered-hint)
                (setq supertag-completion--last-unregistered-hint prefix)
                (message
                 "Tag '%s' is not registered — select [New] in completion or M-x supertag-add-tag to create it"
                 prefix))
            (condition-case err
                (let ((node-id (supertag-node-identity-ensure-at-point)))
                  (when node-id
                    (let ((node-tags
                           (supertag-completion--get-node-tags node-id)))
                      (unless (member tag-id node-tags)
                        (supertag-service-org-save-and-project-current-node
                         node-id)))))
              (error
               (message "supertag-completion: auto-record failed: %S"
                        err)))))))))

;;;###autoload
(defun supertag-completion-setup ()
  "Set up tag and create-or-link completion for Supertag."
  (add-hook 'completion-at-point-functions
            #'supertag-completion-at-point nil t)
  ;; Added after the Tag CAPF so this reference CAPF is checked first.  Each
  ;; function is exclusive only inside its own explicit syntax (# or [[).
  (add-hook 'completion-at-point-functions
            #'supertag-tag--reference-completion-at-point nil t)
  (add-hook 'post-self-insert-hook
            #'supertag-completion--auto-record-on-boundary nil t))

;;;###autoload
(define-minor-mode supertag-ui-completion-mode
  "Enhanced tag completion for supertag."
  :lighter " ST-C"
  (if supertag-ui-completion-mode
      (supertag-completion-setup)
    (remove-hook 'completion-at-point-functions
                 #'supertag-completion-at-point t)
    (remove-hook 'completion-at-point-functions
                 #'supertag-tag--reference-completion-at-point t)
    (remove-hook 'post-self-insert-hook
                 #'supertag-completion--auto-record-on-boundary t)))

;;;###autoload
(defun supertag-ui-completion-enable ()
  "Enable tag completion in org-mode buffers."
  (when (derived-mode-p 'org-mode)
    (supertag-ui-completion-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-supertag-ui-completion-mode
  supertag-ui-completion-mode
  supertag-ui-completion-enable)

(defun supertag-completion-debug ()
  "Dump the full completion pipeline for the `#prefix' at point.
Run this with the cursor sitting just after a `#typedprefix' (do not
delete or move anything) and paste the contents of *Messages* back to
the maintainer. The output shows: the detected bounds, the live prefix,
the full candidate list our CAPF returns, and what
`completion-all-completions' under your active `completion-styles' keeps
after filtering — i.e. exactly what the popup should display."
  (let ((bounds (supertag-completion--get-prefix-bounds)))
    (if (not bounds)
        (message "[supertag-debug] No #prefix bounds at point (no leading #?).")
      (let* ((start (car bounds))
             (end (cdr bounds))
             (prefix (buffer-substring-no-properties start end))
             (table (supertag-completion--get-completion-table prefix))
             (first (car table))
             (styles completion-styles)
             (md (let ((capf (supertag-completion-at-point)))
                   (when capf
                     (funcall (nth 2 capf) prefix nil 'metadata))))
             (filtered (completion-all-completions
                        prefix table nil (length prefix) md)))
        ;; completion-all-completions returns a partial list with the
        ;; final cdr possibly set to a base-size integer; normalize.
        (let ((flat (let (acc (c filtered))
                      (while (consp c)
                        (push (car c) acc)
                        (setq c (cdr c)))
                      (nreverse acc))))
          (message "[supertag-debug] ─────────────────────────────")
          (message "[supertag-debug] prefix bounds : %S..%S" start end)
          (message "[supertag-debug] live prefix   : %S" prefix)
          (message "[supertag-debug] completion-styles: %S" styles)
          (message "[supertag-debug] raw candidates  : %d total" (length table))
          (message "[supertag-debug]   [0] %S  is-new-tag=%S name=%S"
                   (substring-no-properties (or first ""))
                   (and first (get-text-property 0 'is-new-tag first))
                   (and first (get-text-property 0 'new-tag-name first)))
          (message "[supertag-debug]   first 5 raw  : %S"
                   (mapcar #'substring-no-properties (cl-subseq table 0 (min 5 (length table)))))
          (message "[supertag-debug] after-filter   : %d candidates"
                   (length flat))
          (message "[supertag-debug]   first 5 kept : %S"
                   (mapcar #'substring-no-properties (cl-subseq flat 0 (min 5 (length flat)))))
          (message "[supertag-debug] new-tag in raw? : %s"
                   (if (cl-some (lambda (c)
                                  (get-text-property 0 'is-new-tag c))
                                table)
                       "YES" "no"))
          (message "[supertag-debug] new-tag in kept?: %s"
                   (if (cl-some (lambda (c)
                                  (get-text-property 0 'is-new-tag c))
                                flat)
                       "YES" "NO  ← filter dropped it"))
          (message "[supertag-debug] candidate width : %d chars (corfu-max-width may truncate)"
                   (length (substring-no-properties (or first ""))))
          (message "[supertag-debug] corfu installed?: %s%s"
                   (if (featurep 'corfu) "yes" "no")
                   (if (boundp 'corfu-max-width)
                       (format ", corfu-max-width=%S" corfu-max-width)
                     ""))
          (message "[supertag-debug] cape installed? : %s" (if (featurep 'cape) "yes" "no"))
          (message "[supertag-debug] marginalia?     : %s" (if (and (boundp 'marginalia-mode) marginalia-mode) "ON" "off"))
          (message "[supertag-debug] capf-functions  : %S"
                   (mapcar (lambda (f) (if (symbolp f) f 'lambda))
                           completion-at-point-functions))
          (message "[supertag-debug] ─────────────────────────────"))))))

;;; Explicit Tag management and Stream Tag selection.

(defcustom supertag-batch-tag-insert-position 'end
  "Where to insert tags when adding tags in batch mode.
- 'end: Insert tags at the end of the heading (default)
- 'beginning: Insert tags at the beginning of the heading (after the stars and TODO keyword if any)"
  :type '(choice (const :tag "End of heading" end)
                 (const :tag "Beginning of heading" beginning))
  :group 'supertag)

(defcustom supertag-capture-tag-position 'end
  "Where to place tags when creating a headline via capture.
- 'end: Keep tags after the title (default, preserves current behavior).
- 'beginning: Insert tags immediately after the leading stars/TODO keyword."
  :type '(choice (const :tag "End of headline" end)
                 (const :tag "Beginning of headline" beginning))
  :group 'supertag)

(defun supertag-tag-change--collect (tag-id)
  "Read TAG-ID's live occurrences, grouped as (FILE ENTRIES).
Each entry is (NODE-ID TITLE TOKENS LINE-TEXT).  Empty TOKENS denotes a
Store membership whose source requires explicit save/projection repair."
  (let (groups)
    (dolist (pair (supertag-find-nodes-by-tag tag-id))
      (let* ((id (car pair)) (node (cdr pair))
             (file (plist-get node :file))
             (entry
              (supertag-service-org--with-node-buffer
               id
               (lambda ()
                 (let* ((file-node (zerop (or (plist-get node :level) 1)))
                        (tokens
                         (cl-remove-if-not
                          (lambda (token)
                            (supertag-service-org--token-identifies-p token tag-id))
                          (save-excursion
                            (if file-node (supertag-service-org--filetags)
                              (supertag-node-tag-occurrences-at-point))))))
                   (list
                    id (or (plist-get node :title) id) tokens
                    (if file-node
                        (progn
                          (let ((case-fold-search t))
                            (re-search-forward "^#\\+FILETAGS:" nil t))
                          (buffer-substring-no-properties
                           (line-beginning-position) (line-end-position)))
                      (let ((limit (save-excursion
                                     (forward-line 1)
                                     (if (re-search-forward org-outline-regexp-bol nil t)
                                         (match-beginning 0) (point-max))))
                            lines)
                        (while (supertag-view-helper--font-lock-matcher limit)
                          (when (and (member (substring (match-string-no-properties 0) 1) tokens)
                                     (not (save-excursion
                                            (beginning-of-line)
                                            (looking-at-p "^[ \t]*#\\+"))))
                            (push (buffer-substring-no-properties
                                   (line-beginning-position) (line-end-position)) lines)))
                        (string-join (delete-dups (nreverse lines)) "\n    "))))))))
             (group (assoc file groups)))
        (unless group
          (setq group (list file nil))
          (push group groups))
        (setcar (cdr group) (cons entry (cadr group)))))
    (dolist (group groups)
      (setcar (cdr group)
              (sort (cadr group) (lambda (a b) (string< (car a) (car b))))))
    (sort groups (lambda (a b) (string< (car a) (car b))))))

(defun supertag-tag-change-preview (tag-id &optional new-name display heading)
  "Preview TAG-ID's live occurrences without changing Org or its projection.
NEW-NAME is the rename token, or nil for deletion.  DISPLAY shows the preview.
HEADING is an optional first line describing an existing merge target.
Return the grouped collection used to render the preview."
  (let ((groups (supertag-tag-change--collect tag-id))
        (buffer (get-buffer-create "*Supertag Tag Change*"))
        (token-count 0) (node-count 0) (pending-count 0))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (when heading (insert heading "\n\n"))
        (dolist (group groups)
          (insert (format "%s\n" (car group)))
          (dolist (entry (cadr group))
            (cl-incf node-count)
            (cl-incf token-count (length (nth 2 entry)))
            (unless (nth 2 entry) (cl-incf pending-count))
            (insert (format "  %s [%s]：%s → %s\n    %s\n"
                            (nth 1 entry) (car entry)
                            (if (nth 2 entry) (string-join (nth 2 entry) ", ")
                              "待保存/待投影")
                            (or new-name "删除") (nth 3 entry))))
          (insert "\n"))
        (insert (format "%d 个 token / %d 节点 / %d 文件；待保存/待投影 %d\n"
                        token-count node-count (length groups) pending-count)))
      (special-mode)
      (goto-char (point-min)))
    (when display (pop-to-buffer buffer))
    groups))

(defun supertag-tag-rename (&optional old-id new-name)
  "Preview and confirm renaming OLD-ID in Org, then update its projection.
NEW-NAME supplies the proposed name; confirmation is still required.
On failure, earlier nodes remain committed; preview and confirm again to resume.
Preview is always shown before confirmation, whatever the caller."
  (interactive)
  (let* ((old (or old-id (supertag-ui-read-tag
                         "Tag to rename: " (supertag-view-api-list-tag-ids) nil nil)))
         (old-id (and old (not (string-empty-p old))
                      (or (supertag-service-org--semantic-tag-id old)
                          (user-error "Unknown Tag '%s'" old))))
         (name (and old-id (or new-name (read-string (format "New name for '%s': " old))))))
    (when (and name (not (string-empty-p name)))
      (let* ((token (supertag-sanitize-tag-name name))
             (target-id (supertag-tag-resolve-occurrence token))
             (_ (when (equal target-id old-id)
                  (user-error "'%s' already names tag '%s'" name old-id)))
             (actual (if target-id (supertag-service-org--tag-token target-id) token))
             (groups (supertag-tag-change-preview
                      old-id actual t
                      (and target-id
                           (format "并入已有标签 %s（token %s）" target-id actual))))
             (count (apply #'+ (mapcar (lambda (group) (length (cadr group))) groups))))
        (when (yes-or-no-p
               (if target-id
                   (format "Merge '%s' into existing tag '%s' (token '%s') in %d nodes / %d files? "
                           old target-id actual count (length groups))
                 (format "Rename '%s' to '%s' in %d nodes / %d files? "
                         old actual count (length groups))))
          (unless (and (equal target-id (supertag-tag-resolve-occurrence token))
                       (or (null target-id)
                           (equal actual (supertag-service-org--tag-token target-id))))
            (user-error "Tag resolution changed; preview again"))
          (let ((new-id (or target-id
                            (plist-get (supertag-tag-create (list :name token)) :id))))
            (dolist (group groups)
              (dolist (entry (cadr group))
                (supertag-service-org-replace-tag
                 (car entry) old-id new-id (null (nth 2 entry)))))
            (when (and (not (equal old-id new-id))
                       (not (supertag-find-nodes-by-tag old-id)))
              (supertag-tag-delete old-id))
            new-id))))))

(cl-defun supertag-tag-set-parent
    (&optional (tag-id nil tag-id-supplied-p) (parent-id nil parent-id-supplied-p))
  "Set TAG-ID's `:extends' parent to PARENT-ID, or clear it.
Interactively, TAG-ID defaults to the inline tag at point, falling back to
`supertag-ui-read-tag'.  PARENT-ID is then read the same way, with an extra
\"(none)\" candidate that clears the parent.  Cycle and existence validation
come from `supertag-tag-update'; a bad request signals `user-error'."
  (interactive)
  (let* ((tag-id
          (if tag-id-supplied-p
              tag-id
            (or (let ((at-point (supertag-view-helper-get-tag-at-point)))
                  (and at-point (supertag-service-org--semantic-tag-id at-point)))
                (supertag-ui-read-tag
                 "Tag: " (supertag-view-api-list-tag-ids) nil nil))))
         (none-label "(none)")
         (parent-id
          (if parent-id-supplied-p
              parent-id
            (let ((answer
                   (supertag-ui-read-tag
                    (format "Parent for '%s': " tag-id)
                    (cons none-label
                          (remove tag-id (supertag-view-api-list-tag-ids)))
                    nil nil)))
              (unless (equal answer none-label) answer)))))
    (supertag-tag-update tag-id (lambda (tag) (plist-put tag :extends parent-id)))
    (message (if parent-id
                 (format "Tag '%s' now extends '%s'." tag-id parent-id)
               (format "Tag '%s' has no parent." tag-id)))
    parent-id))

(defun supertag-delete-tag-everywhere (&optional tag-name skip-confirm)
  "Preview and confirm removing TAG-NAME from Org and its projection.
Only delete the old entity after no projected node owns it.
Preview is always shown before confirmation, whatever the caller.
When SKIP-CONFIRM is non-nil, the caller already obtained confirmation."
  (interactive)
  (let* ((name (or tag-name (supertag-ui-read-tag
                            "Delete tag permanently: " (supertag-view-api-list-tag-ids) nil nil)))
         (id (and name (not (string-empty-p name))
                  (or (supertag-service-org--semantic-tag-id name)
                      (user-error "Unknown Tag '%s'" name)))))
    (when id
      (let* ((groups (supertag-tag-change-preview
                      id nil t))
             (count (apply #'+ (mapcar (lambda (group) (length (cadr group))) groups))))
        (when (or skip-confirm
                  (yes-or-no-p (format "Delete '%s' in %d nodes / %d files? " name count (length groups))))
          (dolist (group groups)
            (dolist (entry (cadr group))
              (supertag-service-org-remove-tag (car entry) id (null (nth 2 entry)))))
          (unless (supertag-find-nodes-by-tag id) (supertag-tag-delete id))
          t)))))

;;;###autoload
(defun supertag-cleanup-orphaned-tags ()
  "Select and delete unreferenced, schema-free Tag entities.
Candidates are computed conservatively.  Nothing is deleted until the
user selects Tags and confirms; Org files are never edited."
  (interactive)
  (let ((candidates (supertag-tag-orphaned-ids)))
    (if (null candidates)
        (message "No orphaned Tags found.")
      (let ((selected
             (supertag-ui-read-tags
              "Select orphaned Tag to delete: " candidates nil)))
        (when selected
          (if (yes-or-no-p
               (format "Delete %d orphaned Tag(s): %s? "
                       (length selected) (string-join selected ", ")))
              (message "Deleted %d orphaned Tag(s)."
                       (supertag-tag-delete-orphans selected))
            (message "Orphaned Tag cleanup cancelled.")))))))

(defun supertag-view--read-tag ()
  "Read a tag query and include explicit descendants when present."
  (let* ((tag-ids (supertag-view-api-list-tag-ids))
         (tag (supertag-ui-read-tag "Tag: " tag-ids nil nil)))
    (append (list :type :tag :value tag)
            (when (supertag-view-api-tag-descendants tag)
              '(:include-descendants t)))))

(defun supertag-view-api-tag-descendants (tag-name)
  "Return Tag IDs that transitively extend TAG-NAME."
  (supertag-find-tag-descendants tag-name))

;;; Add Tag command; shared Node location remains a lazy commands provider.

(defun supertag-ui--get-nodes-in-region (beg end)
  "Extract all node IDs from Org headings within the region BEG to END.
Returns a list of node IDs. Creates IDs for headings that don't have one.
Only includes headings whose starting position is within [BEG, END)."
  (let ((node-ids '()))
    (save-excursion
      (goto-char beg)
      ;; Move to the beginning of the first heading in or after BEG
      (unless (org-at-heading-p)
        (org-next-visible-heading 1))

      ;; Collect all headings that start within the region
      (while (and (not (eobp))
                  (org-at-heading-p)
                  (< (point) end))  ; Heading must start before END
        (let ((heading-start (point))
              (node-id (supertag-node-identity-ensure-at-point)))
          ;; Only include if heading starts within region
          (when (>= heading-start beg)
            (push node-id node-ids)))
        (org-next-visible-heading 1)))
    (nreverse node-ids)))

(defun supertag-add-tag (&optional beg end)
  "Interactively add a tag to node(s).
If region is active (BEG and END provided), add tag to all nodes in the region.
Otherwise, add tag to the node at point.
This command handles tag creation, linking, and smart insertion
of the inline #tag text into the buffer. Can be used both at headings
and within node content area.

If you prefix your input with '=' (e.g. '=ref'), it will be treated as a literal
new tag name, bypassing fuzzy completion matching."
  (interactive
   (when (use-region-p)
     (list (region-beginning) (region-end))))

  (let* ((batch-mode (and beg end))
         (current-marker (copy-marker (point)))
         (node-ids (if batch-mode
                       ;; Batch mode: get all nodes in region
                       (supertag-ui--get-nodes-in-region beg end)
                     ;; Single mode: get node at point
                     (let ((node-id (supertag-ui--get-containing-node-at-point)))
                       (unless node-id
                         (user-error "Point is not inside a Supertag node"))
                       ;; Ensure the node exists in the database before proceeding.
                       (unless (supertag-node-get node-id)
                         (supertag-node-sync-at-point))
                       (list node-id))))
         (all-tags (supertag-view-api-list-tag-ids))
         (raw-name (or (supertag-ui-read-tag
                        (format "Add tag to %d node(s) (use =tagname for exact match): "
                                (length node-ids))
                        all-tags t t)
                       ""))
         (literal-tag (and (> (length raw-name) 0) (eq (aref raw-name 0) ?=))))

    (unless node-ids
      (user-error "No nodes found to add tag to."))

    (when (and raw-name (not (string-empty-p raw-name)))
      (let* ((tag-name (if literal-tag
                          (substring raw-name 1) ; Remove the '=' prefix
                        raw-name))
             (token (supertag-sanitize-tag-name tag-name))
             (tag-id (or (and (supertag-tag-get token) token)
                         (supertag-tag-resolve-occurrence token))))
        (when (or tag-id
                  (yes-or-no-p
                   (if literal-tag
                       (format "Create new tag '%s' and add to %d node(s)? "
                               token (length node-ids))
                     (format "Tag '%s' does not exist. Create and add it to %d node(s)? "
                             token (length node-ids)))))
          (dolist (node-id node-ids)
            (unless (supertag-node-get node-id)
              (when-let* ((marker (supertag-ui--find-node-marker node-id)))
                (with-current-buffer (marker-buffer marker)
                  (goto-char marker)
                  (supertag-node-sync-at-point)))))
          (setq tag-id
                (supertag-capture-add-tag-to-nodes
                 node-ids token
                 (if batch-mode
                     supertag-batch-tag-insert-position
                   current-marker)))
          (message "Tag '%s' added to %d node(s)." tag-id (length node-ids)))))))

;;; Remove Tag command and the sole raw-membership selector.
(defun supertag-remove-tag-from-node ()
  "Interactively remove a tag from the current node.
Can be used both at headings and within node content areas."
  (interactive)
  (let* ((node-id (supertag-ui--get-containing-node-at-point))
     (tag-id (supertag-ui-select-tag-on-node node-id)))
      (when tag-id
        (supertag-service-org-remove-tag node-id tag-id)
        (message "Tag '%s' removed from node %s." tag-id node-id))))

(defun supertag-ui-select-tag-on-node (node-id)
  "Interactively select a tag from the ones associated with NODE-ID.
Returns the selected tag ID (a string), or nil if canceled."
  (let* ((node (supertag-node-get node-id))
         (tags (and node (plist-get node :tags))))
    (unless tags
      (user-error "Node has no tags to select from."))
    (supertag-ui-read-tag "Select tag: " tags nil nil)))

;;; Inline tag writes, token merging and membership reads.

(defun supertag--merge-and-sanitize-tags (tags-1 tags-2)
    "Merge two tag lists and sanitize names.
Returns a de-duplicated list preserving order preference of TAGS-1."
    (let* ((sanitize #'(lambda (s) (and s (supertag-sanitize-tag-name s))))
           (a (delq nil (mapcar sanitize tags-1)))
           (b (delq nil (mapcar sanitize tags-2)))
           (seen (make-hash-table :test 'equal))
           (out '()))
      (dolist (tag a)
        (unless (gethash tag seen)
          (push tag out)
          (puthash tag tag seen)))
      (dolist (tag b)
        (unless (gethash tag seen)
          (push tag out)
          (puthash tag tag seen)))
      (nreverse out)))

(defun supertag--format-inline-tags (tags)
    "Return TAGS in Supertag's inline #tag write format.
The result has a leading space when TAGS is non-empty, else an empty string."
    (let ((inline-part
           (when tags
             (mapconcat (lambda (tag) (concat "#" tag)) tags " "))))
      (if inline-part (concat " " inline-part) "")))

(defun supertag-view-api-nodes-by-tag (tag-name &optional include-descendants)
  "Return node IDs that have TAG-NAME.
When INCLUDE-DESCENDANTS is non-nil, include transitive `:extends' descendants."
  (supertag-query-node-ids-by-tag tag-name include-descendants))

;;; Tag directory, identity and display adapters

(defun supertag-view-api-list-tags ()
  "Return tag names (sorted)."
  (sort (delete-dups
         (mapcar (lambda (tag) (plist-get tag :name))
                 (supertag-query-tag-descriptors)))
        #'string<))

(defun supertag-view-api-tag-id (tag-name)
  "Return tag ID for TAG-NAME, or nil."
  (unless (and (stringp tag-name) (not (string-empty-p tag-name)))
    (error "TAG-NAME must be a non-empty string"))
  (or (and (supertag-tag-get tag-name) tag-name)
      (supertag-tag-resolve-occurrence tag-name)))

(defun supertag-view--resolve-node-tags (node-id)
  "Compatibility wrapper returning the Semantic Tag IDs for NODE-ID."
  (when (and node-id (stringp node-id))
    (supertag-query-node-tags node-id)))

(defun supertag-view-helper-format-tag-value (value)
  "Format tag VALUE with the shared role faces."
  (require 'supertag-view-framework)
  (if (or (null value) (string-empty-p (format "%s" value)))
      (propertize "[No tags]" 'face 'supertag-view-mute)
    (let ((tags (if (stringp value)
                    (split-string value "," t "[ \t\n\r]+")
                  (if (listp value) value (list (format "%s" value)))))
          (border (face-foreground 'supertag-view-rule nil t)))
      (mapconcat
       (lambda (tag)
         (propertize (concat "#" (string-trim tag))
                     'face (list 'supertag-view-accent
                                 `(:weight bold :box (:line-width 1 :color ,border)))))
       tags " "))))

;;; Tag entity ensure and hierarchy adapters

(defun supertag--normalize-tag-id (name)
    "Return NAME's resolved Tag ID or its sanitized tag name."
    (let ((sanitized (supertag-sanitize-tag-name name)))
      (or (supertag-tag-resolve-occurrence sanitized) sanitized)))

(defun supertag--create-tag-entities (tag-names)
  "Create tag entities for TAG-NAMES and return their IDs.
Ensures tags are created only once and returns existing tag IDs.
IMPORTANT: This function NEVER modifies existing tags - it only creates new ones."
  (let ((tag-ids '()))
    (dolist (tag-name tag-names)
      (let* ((sanitized-name (supertag-sanitize-tag-name tag-name))
             (tag-id (supertag-tag-resolve-occurrence sanitized-name))
             (existing-tag (and tag-id (supertag-tag-get tag-id))))
        ;; CRITICAL: Only create if tag doesn't exist
        ;; Never modify existing tags to preserve their field definitions
        (unless existing-tag
          (setq tag-id
                (plist-get (supertag-tag-create (list :name sanitized-name)) :id)))
        (push tag-id tag-ids)))
    (nreverse tag-ids)))

(defun supertag-find-tag-descendants (tag-name)
  "Return stored tag IDs that are `:extends' descendants of TAG-NAME."
  (let ((tag-id (or (and (supertag-tag-get tag-name) tag-name)
                    (supertag-tag-resolve-occurrence tag-name)
                    tag-name)))
    (supertag-tag-descendants tag-id)))

(defun supertag-query-tag-children (tag-id)
  "Return Tag IDs whose `:extends' parent is TAG-ID."
  (let (result)
    (maphash
     (lambda (id raw-tag)
       (when (equal (plist-get (supertag--ensure-plist raw-tag) :extends)
                    tag-id)
         (push id result)))
     (supertag-store-get-collection :tags))
    (sort result #'string<)))

;;; Display lifecycle: all definitions above are complete before activation.

(add-hook 'org-mode-hook #'supertag-view-helper--auto-enable)
(when (boundp 'enable-theme-functions)
  (add-hook 'enable-theme-functions #'supertag-svg-tag--on-theme-change))
;; Refresh manually enabled buffers even with auto-enable=nil.  The second
;; pass only enables inactive Org buffers, never installing twice per buffer.
(supertag-svg-tag--refresh-all-buffers)
(supertag-view-helper--enable-existing-org-buffers)

(provide 'supertag-tag)
;;; supertag-tag.el ends here
