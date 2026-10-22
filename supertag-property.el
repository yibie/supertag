;;; supertag-property.el --- Hints and completion in property drawers -*- lexical-binding: t; -*-

;; Commands: supertag-property-mode, global-supertag-property-mode.
;; Lisp entrypoints: supertag-property-usage, supertag-property-names,
;; supertag-property-key-info.
;; Dependencies: cl-lib, org, subr-x, supertag-core-store; optional Corfu
;; shows the candidates, and without it only the echo-area hint is active.

;;; Commentary:
;; A property is plain text in an Org drawer, and nothing in the drawer says
;; whether a key takes one of a few values or anything at all.  This file
;; answers that where the user types: with point on a property line the echo
;; area names the key's type and its options, and completion offers keys and
;; values.
;;
;; A closed key has allowed values declared the Org way, as KEY_ALL without
;; :ETC, in a drawer, a #+PROPERTY: line or `org-global-properties'.  Every
;; other key is open, and its candidates are the values the vault already
;; uses.  Closed is a convention: typing in a drawer is never blocked, the
;; hint only says so when a value is not among the options.
;;
;; Everything here reads the Store and the buffer.  Org writes the file, and
;; the sync that follows a save brings the Store up to date.

;;; Code:
(require 'cl-lib)
(require 'org)
(require 'subr-x)
(require 'supertag-core-store)

(defvar corfu-mode)

;;; Configuration
(defgroup supertag-property nil
  "Hints and completion in Org property drawers."
  :group 'supertag
  :prefix "supertag-property-")

(defcustom supertag-property-hints t
  "Whether Org buffers get property hints and completion.
When non-nil, `global-supertag-property-mode' turns on
`supertag-property-mode' in Org buffers, which also enables ElDoc there."
  :type 'boolean :group 'supertag-property)

(defcustom supertag-property-system-key-regexp
  "\\`\\(ID\\|CUSTOM_ID\\|CATEGORY\\|CREATED\\|REF_ID\\|SOURCE_FILE_PATH\\|\\(ARCHIVE\\|EXPORT\\|SUPERTAG\\)_.*\\)\\'"
  "Regexp matching property keys that programs maintain.
Such keys get no hint and never appear as candidates.  The keys in
`supertag-property-hand-written-keys' are user keys even when this matches."
  :type 'regexp :group 'supertag-property)

(defconst supertag-property-hand-written-keys '("SUPERTAG_ALIASES")
  "Property keys Supertag reads that the user writes by hand.
Completion offers them before any node uses them, in Supertag's own drawer
completion and, while `global-supertag-property-mode' is on, in Org's.")

(defcustom supertag-property-hint-max-values 6
  "How many used values the hint lists for an open key."
  :type 'natnum :group 'supertag-property)

(defcustom supertag-property-popup-commands
  '(self-insert-command org-self-insert-command
    delete-backward-char org-delete-backward-char backward-delete-char-untabify
    backward-kill-word kill-line org-kill-line
    corfu-insert corfu-complete)
  "Commands after which an empty property value offers its candidates.
Only edits count: moving point over an empty value shows nothing."
  :type '(repeat symbol) :group 'supertag-property)

;;; Property usage in the Store
(defun supertag-property--nodes ()
  "Return the node collection, or nil when the Store is not available."
  (ignore-errors (supertag-store-get-collection :nodes)))

(defun supertag-property--key-name (key)
  "Return the upper-case property name of KEY, a keyword or a string."
  (upcase (string-remove-prefix ":" (format "%s" key))))

(defun supertag-property--user-key-p (name)
  "Return non-nil when the user, not a program, maintains the key NAME."
  (let ((case-fold-search nil))
    (or (member name supertag-property-hand-written-keys)
        (not (string-match-p supertag-property-system-key-regexp name)))))

(defun supertag-property--by-count (table)
  "Return the keys of TABLE, a name to count hash table, most used first."
  (let (pairs)
    (maphash (lambda (name count) (push (cons name count) pairs)) table)
    (mapcar #'car (sort pairs (lambda (a b) (> (cdr a) (cdr b)))))))

(defun supertag-property-usage (&optional tags)
  "Return how the nodes of the vault use properties, as a plist.
:keys      hash table, key name to the number of nodes using it
:values    hash table, key name to a hash table of value to count
:tag-keys  hash table, key name to the number of nodes using it among the
           nodes that carry one of TAGS
Key names are upper-case strings.  Keys programs maintain, see
`supertag-property-system-key-regexp', are left out, values are trimmed
and blank values are not counted."
  (let ((keys (make-hash-table :test 'equal))
        (values (make-hash-table :test 'equal))
        (tag-keys (make-hash-table :test 'equal)))
    (when-let* ((nodes (supertag-property--nodes)))
      (maphash
       (lambda (_id node)
         (let ((shared (and tags (seq-intersection tags (plist-get node :tags)))))
           (cl-loop
            for (key value) on (plist-get node :properties) by #'cddr
            for name = (supertag-property--key-name key)
            when (supertag-property--user-key-p name)
            do (puthash name (1+ (gethash name keys 0)) keys)
            (when shared
              (puthash name (1+ (gethash name tag-keys 0)) tag-keys))
            (when (and (stringp value) (not (string-blank-p value)))
              (let ((seen (or (gethash name values)
                              (puthash name (make-hash-table :test 'equal) values)))
                    (text (string-trim value)))
                (puthash text (1+ (gethash text seen 0)) seen))))))
       nodes))
    (list :keys keys :values values :tag-keys tag-keys)))

(defun supertag-property-names ()
  "Return every property name the nodes of the vault use, sorted.
Unlike `supertag-property-usage' this keeps the names as the Store spells
them and includes the keys programs maintain."
  (let (names)
    (when-let* ((nodes (supertag-property--nodes)))
      (maphash (lambda (_id node)
                 (cl-loop for (key _value) on (plist-get node :properties) by #'cddr
                          do (push (string-remove-prefix ":" (format "%s" key)) names)))
               nodes))
    (sort (delete-dups names) #'string<)))

(defun supertag-property-key-info (key usage)
  "Return the type and the values of KEY at point, as a plist.
USAGE is the result of `supertag-property-usage'.
:type    `closed' or `open'
:options for a closed key the declared options in declared order; for an
         open key the values used more than once, most used first
:values  completion candidates: the options of a closed key, every
         declared or used value of an open key
:seen    hash table of value to count, or nil when the key has no values
:count   number of nodes using the key"
  (let* ((name (upcase key))
         (declared (let ((org-property-allowed-value-functions nil))
                     (ignore-errors (org-property-get-allowed-values nil key))))
         ;; Org drops :ETC and marks the first value `org-unrestricted'.
         (closed (and declared
                      (not (get-text-property 0 'org-unrestricted (car declared)))))
         (allowed (mapcar #'substring-no-properties declared))
         (seen (gethash name (plist-get usage :values)))
         (used (and seen (supertag-property--by-count seen))))
    (list :type (if closed 'closed 'open)
          :options (if closed allowed
                     (seq-filter (lambda (value) (> (gethash value seen) 1)) used))
          :values (if closed allowed
                    (delete-dups (append allowed used)))
          :seen seen
          :count (gethash name (plist-get usage :keys) 0))))

;;; The drawer at point
(defun supertag-property--in-drawer-p ()
  "Return non-nil when the line at point is inside a PROPERTIES drawer.
The drawer's first and last line do not count.  `org-get-property-block'
is not used: a half-typed line makes it miss the drawer."
  (save-excursion
    (forward-line 0)
    (let ((case-fold-search t)
          (edge "[ \t]*:\\(PROPERTIES\\|END\\):[ \t]*$"))
      (and (not (looking-at-p edge))
           (re-search-backward (concat "^" edge "\\|^\\*+ ") nil t)
           (string-equal-ignore-case (or (match-string 1) "") "PROPERTIES")))))

(defun supertag-property--value-line ()
  "Return (KEY VALUE BEG END) when point is on a property line in a drawer.
BEG and END bound the value.  BEG is nil while nothing follows the colon."
  (let ((line (save-excursion
                (forward-line 0)
                (and (looking-at
                      "[ \t]*:\\([^: \t\n]+\\):\\(?:\\([ \t]+\\)\\(.*?\\)\\)?[ \t]*$")
                     (list (match-string-no-properties 1)
                           (or (match-string-no-properties 3) "")
                           (match-end 2) (match-end 3))))))
    (and line (supertag-property--in-drawer-p) line)))

(defun supertag-property--drawer-keys ()
  "Return the upper-case keys already written in the drawer at point."
  (save-excursion
    (let ((case-fold-search t) keys)
      (when (re-search-backward "^[ \t]*:PROPERTIES:[ \t]*$" nil t)
        (forward-line 1)
        (while (and (looking-at "[ \t]*:\\([^: \t\n]*\\)\\(:\\)?")
                    (not (string-equal-ignore-case (match-string 1) "END")))
          (when (match-end 2) (push (upcase (match-string 1)) keys))
          (forward-line 1)))
      keys)))

(defun supertag-property--heading-tags ()
  "Return the tags of the heading at point.
These are the tags the Store records for its ID, the #tags written in its
title and its Org tags."
  (unless (org-before-first-heading-p)
    (let* ((id (ignore-errors (org-entry-get nil "ID")))
           (node (and id (when-let* ((nodes (supertag-property--nodes)))
                           (gethash id nodes))))
           (title (org-get-heading t t t t))
           (inline (let (found (start 0))
                     (while (string-match "#\\([[:alnum:]_/-]+\\)" title start)
                       ;; A nested tag #a/b/c is recorded as its leaf c.
                       (push (car (last (split-string (match-string 1 title) "/" t)))
                             found)
                       (setq start (match-end 0)))
                     found)))
      (delete-dups (append (seq-filter #'stringp (plist-get node :tags))
                           inline
                           (org-get-tags nil t))))))

;;; Hint
(defun supertag-property--type-label (info)
  "Return the name of the key type in INFO."
  (if (eq (plist-get info :type) 'closed) "closed" "open"))

(defun supertag-property-eldoc (&rest _)
  "Return the type and the options of the property key at point.
This is an ElDoc documentation function.  It returns nil away from a
property line and for the keys programs maintain."
  (pcase (supertag-property--value-line)
    ((and `(,key ,value . ,_)
          (guard (supertag-property--user-key-p (upcase key))))
     (let* ((info (supertag-property-key-info key (supertag-property-usage)))
            (closed (eq (plist-get info :type) 'closed))
            (options (plist-get info :options)))
       (concat key " · " (supertag-property--type-label info)
               (when options
                 (concat " · "
                         (if closed
                             (string-join options " ")
                           (string-join
                            (seq-take options supertag-property-hint-max-values)
                            " | "))))
               (when (and closed (not (string-empty-p value))
                          (not (member value options)))
                 (format " · %s is not an option" value)))))))

;;; Completion
(defun supertag-property--table (candidates)
  "Return a completion table of CANDIDATES that keeps their order."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action candidates string pred))))

(defun supertag-property-value-completion-at-point ()
  "Complete the value of the property at point.
A closed key offers its declared options, an open key the values in use."
  (pcase (supertag-property--value-line)
    ((and `(,key ,_ ,beg ,end)
          (guard (and beg (>= (point) beg)
                      (supertag-property--user-key-p (upcase key)))))
     (let* ((info (supertag-property-key-info key (supertag-property-usage)))
            (seen (plist-get info :seen)))
       (when-let* ((values (plist-get info :values)))
         (list beg (max end (point))
               (supertag-property--table values)
               :annotation-function
               (lambda (value)
                 (when-let* ((count (and seen (gethash value seen))))
                   (format "  %d" count)))
               :exclusive 'no))))))

(defun supertag-property-key-completion-at-point ()
  "Complete a property key being typed on a new drawer line.
Keys used by nodes sharing a tag with this heading come first, then every
other key in use, then the hand-written Supertag keys no node uses yet.
Each candidate shows its type and how many nodes use it.  Accepting one
inserts the colon and a space after it."
  (when-let* ((beg (let ((pos (point)))
                     (save-excursion
                       (forward-line 0)
                       (and (looking-at "[ \t]*:\\([^: \t\n]*\\)$")
                            (>= pos (match-beginning 1))
                            (match-beginning 1)))))
              ((supertag-property--in-drawer-p)))
    (let* ((usage (supertag-property-usage (supertag-property--heading-tags)))
           (tag-keys (plist-get usage :tag-keys))
           (have (supertag-property--drawer-keys))
           (keys (seq-remove
                  (lambda (name) (member name have))
                  (delete-dups
                   (append (supertag-property--by-count tag-keys)
                           (supertag-property--by-count (plist-get usage :keys))
                           supertag-property-hand-written-keys))))
           (buffer (current-buffer))
           (pos (point)))
      (list beg (point)
            (supertag-property--table keys)
            :annotation-function
            (lambda (name)
              (let ((info (with-current-buffer buffer
                            (save-excursion
                              (goto-char pos)
                              (supertag-property-key-info name usage)))))
                (format "  %s · %d" (supertag-property--type-label info)
                        (or (gethash name tag-keys) (plist-get info :count)))))
            :exit-function
            (lambda (_name status)
              (when (and (eq status 'finished) (eolp)
                         (not (memq (char-before) '(?: ?\s))))
                (insert ": ")))
            :exclusive 'no))))

(defun supertag-property--popup-wanted-p ()
  "Return non-nil when the empty value at point has candidates to choose from.
Point must end an empty value, and the key must have more than one option:
declared ones for a closed key, values used more than once for an open
key.  A free-text key therefore never qualifies."
  (pcase (supertag-property--value-line)
    ((and `(,key ,value ,beg . ,_)
          (guard (and beg (eolp) (string-empty-p value)
                      (supertag-property--user-key-p (upcase key)))))
     (cdr (plist-get (supertag-property-key-info key (supertag-property-usage))
                     :options)))))

(defun supertag-property--popup ()
  "Offer value candidates after an edit leaves point on an empty value.
This runs on `post-command-hook'."
  (when (and (memq this-command supertag-property-popup-commands)
             (bound-and-true-p corfu-mode)
             (not completion-in-region-mode))
    (ignore-errors
      (when (supertag-property--popup-wanted-p)
        (completion-at-point)))))

;;; Mode
;;;###autoload
(define-minor-mode supertag-property-mode
  "Hints and completion for the property drawers of this buffer.
With point on a property line the echo area names the key's type, closed
or open, and its options.  Completion offers property keys on a new
drawer line and values after a key."
  :lighter nil
  (if supertag-property-mode
      (progn
        (add-hook 'eldoc-documentation-functions #'supertag-property-eldoc nil t)
        (eldoc-mode 1)
        (add-hook 'completion-at-point-functions
                  #'supertag-property-value-completion-at-point -20 t)
        (add-hook 'completion-at-point-functions
                  #'supertag-property-key-completion-at-point -20 t)
        (add-hook 'post-command-hook #'supertag-property--popup nil t))
    (remove-hook 'eldoc-documentation-functions #'supertag-property-eldoc t)
    (remove-hook 'completion-at-point-functions
                 #'supertag-property-value-completion-at-point t)
    (remove-hook 'completion-at-point-functions
                 #'supertag-property-key-completion-at-point t)
    (remove-hook 'post-command-hook #'supertag-property--popup t)))

(defun supertag-property-enable ()
  "Turn on `supertag-property-mode' in an Org buffer when hints are wanted."
  (when (and supertag-property-hints (derived-mode-p 'org-mode))
    (supertag-property-mode 1)))

(defvar supertag-property--org-keys-added nil
  "The keys `supertag-property--offer-to-org' added to `org-default-properties'.")

(defun supertag-property--offer-to-org (on)
  "Offer the hand-written Supertag keys to Org's key completion when ON.
`org-set-property' completes `org-default-properties' and the keys already
in the buffer, so without this a key is offered only in a file that has
it.  Turning off removes only the keys this added, never one the user had."
  (if on
      (dolist (key supertag-property-hand-written-keys)
        (unless (member key org-default-properties)
          (push key supertag-property--org-keys-added)
          (setq org-default-properties
                (append org-default-properties (list key)))))
    (setq org-default-properties
          (seq-remove (lambda (key) (member key supertag-property--org-keys-added))
                      org-default-properties)
          supertag-property--org-keys-added nil)))

;;;###autoload
(define-globalized-minor-mode global-supertag-property-mode
  supertag-property-mode
  supertag-property-enable
  :group 'supertag-property
  ;; Not gated on `supertag-property-hints': this is Org's own completion,
  ;; not a Supertag hint.
  (supertag-property--offer-to-org global-supertag-property-mode))

(provide 'supertag-property)
;;; supertag-property.el ends here
