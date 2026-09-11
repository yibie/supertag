;;; supertag-ai.el --- Review AI-extracted Org properties -*- lexical-binding: t; -*-

;; Commands: supertag-ai-extract-properties, supertag-ai-cancel-extraction,
;;   supertag-ai-extract-tag-properties, supertag-ai-cancel-batch, supertag-ai-plan-apply, supertag-ai-plan-toggle-skip, supertag-ai-plan-mode
;; Dependencies: cl-lib, subr-x, org, json, format-spec, button,
;; supertag-services-sync, supertag-service-org,
;; supertag-view-framework; superchat-runtime is optional, loaded by the user;
;; supertag-view-node refresh capabilities are used only when already available.

;;; Commentary:
;; Runtime proposes disposable candidates.  Only an explicit accept writes Org.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'json)
(require 'format-spec)
(require 'button)
(require 'supertag-services-sync)
(require 'supertag-service-org)
(require 'supertag-view-framework)

(declare-function superchat-runtime-submit "superchat-runtime" (request))
(declare-function supertag-view-node--refresh-view "supertag-view-node" ())
(declare-function supertag-view-node--buffer "supertag-view-node" ())
(defvar supertag-view-node--current-node-id)
(defvar supertag-ai--batch)

(defgroup supertag-ai nil "Review properties proposed by AI." :group 'supertag)
(defcustom supertag-ai-prompts
  '((extract-properties
     :system "Extract only facts explicitly stated in the body. Do not invent facts or repeat existing properties with equal values. Return at most 12 entries as one JSON object with uppercase property names and values shaped as {\"value\": \"text\", \"source\": \"verbatim body quote\"}. Use null for source if absent from the body. Output only JSON, with no surrounding prose."
     :user "Title: %t\nExisting properties:\n%p\nBody:\n%b"))
  "Named extraction prompts.  User templates expand %t, %p and %b."
  :type '(alist :key-type symbol :value-type plist) :group 'supertag-ai)
(defcustom supertag-ai-max-body-chars 8000
  "Maximum number of own-body characters sent for extraction."
  :type 'natnum :group 'supertag-ai)
(defcustom supertag-ai-timeout 60
  "Runtime request timeout in seconds."
  :type 'number :group 'supertag-ai)
(defvar supertag-ai--candidates (make-hash-table :test 'equal)
  "Disposable extraction entries keyed by node ID.  Never persisted.")

(defun supertag-ai--host-buffer ()
  "Return the persistent, non-Org Runtime host buffer."
  (get-buffer-create " *supertag-ai*"))

(defun supertag-ai--submit (request)
  "Submit REQUEST through the sole public transport boundary."
  (funcall 'superchat-runtime-submit request))

(defun supertag-ai--refresh (node-id)
  "Refresh a live Node View displaying NODE-ID, if present."
  (when (and (fboundp 'supertag-view-node--refresh-view)
             (fboundp 'supertag-view-node--buffer))
    (when-let* ((buffer (supertag-view-node--buffer)))
      (with-current-buffer buffer
        (when (and (boundp 'supertag-view-node--current-node-id)
                   (equal supertag-view-node--current-node-id node-id))
          (ignore-errors (supertag-view-node--refresh-view)))))))

(defun supertag-ai--context ()
  "Read title, standard properties and own body at the current heading."
  (let ((title (org-get-heading t t t t))
        (properties (cl-remove-if
                     (lambda (pair) (member (upcase (car pair))
                                            '("ID" "CUSTOM_ID" "CATEGORY")))
                     (org-entry-properties nil 'standard)))
        (begin (save-excursion (org-end-of-meta-data t) (point)))
        (end (save-excursion (outline-next-heading) (point))))
    (list :title title :properties properties
          :body (buffer-substring-no-properties (min begin end) end))))

;;;###autoload
(defun supertag-ai-extract-properties (&optional choose-prompt)
  "Extract property candidates for this heading; CHOOSE-PROMPT selects a template."
  (interactive "P")
  (unless (fboundp 'superchat-runtime-submit)
    (user-error "Supertag AI needs the superchat package loaded first (see README)"))
  (let* ((node-id
          (cond
           ((derived-mode-p 'org-mode)
            ;; These checks precede even the live ID write.
            (when (org-before-first-heading-p)
              (user-error "Extract properties works on a heading, not the file node"))
            (unless (and buffer-file-name (file-exists-p buffer-file-name))
              (user-error "Save this file before extracting properties"))
            (let ((id (supertag-ui--get-containing-node-at-point)))
              (unless (supertag-node-get id)
                (save-excursion
                  (org-back-to-heading t)
                  (supertag-node-sync-at-point)))
              id))
           ((and (boundp 'supertag-view-node--current-node-id)
                 supertag-view-node--current-node-id)
            supertag-view-node--current-node-id)
           (t (user-error "Extract properties needs an Org heading or Node View"))))
         (name (if choose-prompt
                   (intern (completing-read "Extraction prompt: "
                                            (mapcar (lambda (p) (symbol-name (car p)))
                                                    supertag-ai-prompts)
                                            nil t))
                 'extract-properties)))
    (supertag-ai--start node-id name)))

(defun supertag-ai--start (node-id name)
  "Submit an extraction for NODE-ID with prompt template NAME."
  (let ((old (gethash node-id supertag-ai--candidates)))
    (when (eq (plist-get old :status) 'pending)
      (user-error "Extraction already running for this node")))
  (let* ((template (alist-get name supertag-ai-prompts))
         (context (supertag-service-org--with-node-buffer node-id #'supertag-ai--context))
         (body (plist-get context :body))
         (truncated (> (length body) supertag-ai-max-body-chars))
         (sent-body (if truncated (substring body 0 supertag-ai-max-body-chars) body))
         (token (gensym "supertag-ai-"))
         (properties (plist-get context :properties))
         (prompt (format-spec
                  (plist-get template :user)
                  `((?t . ,(plist-get context :title))
                    (?p . ,(if properties
                               (mapconcat (lambda (p) (concat (car p) ": " (cdr p)))
                                          properties "\n")
                             "(none)"))
                    (?b . ,sent-body))))
         (entry (list :status 'pending :prompt name :started (float-time)
                      :existing properties :body sent-body :token token)))
    (when truncated (setq prompt (concat prompt "\n(truncated)")))
    (puthash node-id entry supertag-ai--candidates)
    (supertag-ai--refresh node-id)
    (condition-case err
        (let ((handle
               (supertag-ai--submit
                (list :type :llm-query :input "extract properties"
                      :prompt prompt :system-prompt (plist-get template :system)
                      :buffer (supertag-ai--host-buffer) :tools 'none
                      :record-conversation nil
                      :origin (list :surface 'supertag :node-id node-id :prompt name)
                      :timeout supertag-ai-timeout
                      :delivery-function
                      (lambda (response status tape-id)
                        (supertag-ai--deliver node-id response status tape-id token))))))
          ;; Delivery may have already run synchronously; retain its state.
          (when-let* ((current (gethash node-id supertag-ai--candidates))
                      (_ (eq (plist-get current :token) token)))
            (setq current (plist-put current :run-id (plist-get handle :run-id)))
            (puthash node-id (plist-put current :turn-id (plist-get handle :turn-id))
                     supertag-ai--candidates))
          (message "Supertag AI: extracting properties…"))
      (error
       ;; Reset or reentrant submission can replace this entry while submit runs.
       (when (eq token (plist-get (gethash node-id supertag-ai--candidates) :token))
         (puthash node-id (plist-put (plist-put entry :status 'failed)
                                    :message (error-message-string err))
                  supertag-ai--candidates)
         (supertag-ai--refresh node-id))
       (message "Supertag AI: %s" (error-message-string err))
       (signal (car err) (cdr err))))))


(defun supertag-ai--json-object (text)
  "Decode TEXT as an object, without extracting objects out of arrays or strings."
  (let ((json-text (string-trim text)) object parsed)
    (if (string-match "```\\(?:json\\)?[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)```" text)
        (setq json-text (string-trim (match-string 1 text)))
      (condition-case nil
          (setq object (json-parse-string json-text :object-type 'alist
                                          :null-object nil :false-object nil)
                parsed t)
        (json-parse-error nil))
      (unless parsed
        (let ((begin (string-match "{" text))
              (end (string-match "}[^}]*\\'" text)))
          (unless (and begin end (<= begin end)
                       (not (string-match-p "[][]" (concat (substring text 0 begin)
                                                         (substring text (1+ end))))))
            (user-error "Expected a JSON object"))
          (setq json-text (substring text begin (1+ end))))))
    (unless (string-prefix-p "{" json-text)
      (user-error "Expected a JSON object"))
    (if parsed object
      (json-parse-string json-text :object-type 'alist :null-object nil :false-object nil))))

(defun supertag-ai--normalize-whitespace (text)
  "Collapse whitespace in TEXT for literal quote verification."
  (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text)))

(defun supertag-ai--parse-candidates (text existing-alist &optional body)
  "Parse TEXT against EXISTING-ALIST and sent BODY; return candidates and drop count."
  (let* ((object (supertag-ai--json-object text))
         (seen (make-hash-table :test 'equal))
         (dropped 0) candidates)
    (dolist (pair object)
      (let* ((name (upcase (string-trim (symbol-name (car pair)))))
             (record (cdr pair))
             (value (and (listp record) (alist-get 'value record)))
             (source (and (listp record) (alist-get 'source record)))
             (current (cdr (assoc-string name existing-alist t)))
             (duplicate (gethash name seen)))
        (puthash name t seen)
        (when (numberp value) (setq value (number-to-string value)))
        (if (or duplicate (not (org--valid-property-p name))
                (member name '("ID" "CUSTOM_ID" "CATEGORY"))
                (member name org-special-properties)
                (not (stringp value)) (string-match-p "[\n\r]" value)
                (string-empty-p (string-trim value))
                (equal (string-trim value) current))
            (cl-incf dropped)
          (push (list :name name :value (string-trim value)
                      :source (and (stringp source) source)
                      :source-verified
                      (and (stringp source)
                           (not (string-empty-p (supertag-ai--normalize-whitespace source)))
                           (numberp (string-search (supertag-ai--normalize-whitespace source)
                                                  (supertag-ai--normalize-whitespace (or body "")))))
                      :current current)
                candidates))))
    (cl-values (nreverse candidates) dropped)))

(defun supertag-ai--deliver (node-id response status tape-id token)
  "Receive RESPONSE and terminal STATUS for NODE-ID from TAPE-ID and TOKEN."
  (let ((entry (gethash node-id supertag-ai--candidates))
        (batch (and (equal node-id (plist-get supertag-ai--batch :current))
                    supertag-ai--batch)))
    (cond
     ((not (and entry (eq (plist-get entry :token) token)))
      (message "Supertag AI: ignored a stale response for %s" node-id))
     ((eq (plist-get entry :status) 'cancelled)
      (message "Supertag AI: ignored a late response for cancelled %s" node-id))
     (t
      (condition-case err
        (if (eq status 'completed)
            (cl-multiple-value-bind (candidates dropped)
                (supertag-ai--parse-candidates response (plist-get entry :existing)
                                               (plist-get entry :body))
              (setq entry (plist-put entry :status 'done))
              (setq entry (plist-put entry :candidates candidates))
              (message "Supertag AI: %d candidates (%d dropped)" (length candidates) dropped))
          (setq entry (plist-put entry :status (if (eq status 'cancelled) 'cancelled 'failed)))
          (setq entry (plist-put entry :message response))
          (message "Supertag AI: %s: %s" (if (eq status 'cancelled) "cancelled" "failed") response))
      (error
       (setq entry (plist-put entry :status 'failed))
       (setq entry (plist-put entry :message (concat "Could not parse response: " (error-message-string err))))
       (setq entry (plist-put entry :raw response))
       (message "Supertag AI: %s" (plist-get entry :message))))
        (puthash node-id (plist-put entry :tape-id tape-id) supertag-ai--candidates)
        (supertag-ai--refresh node-id)
        (supertag-ai--batch-note node-id token batch)))))

(defun supertag-ai--retry (node-id)
  "Retry NODE-ID using its previous prompt."
  (let* ((entry (gethash node-id supertag-ai--candidates))
         (name (or (plist-get entry :prompt) 'extract-properties)))
    (remhash node-id supertag-ai--candidates)
    (supertag-ai--start node-id name)))

(defun supertag-ai-cancel (node-id)
  "Cancel the pending extraction for NODE-ID."
  (when-let* ((entry (gethash node-id supertag-ai--candidates)))
    (when (eq (plist-get entry :status) 'pending)
      (let ((token (plist-get entry :token))
            (batch (and (equal node-id (plist-get supertag-ai--batch :current))
                        supertag-ai--batch)))
        (when (and (plist-get entry :run-id) (fboundp 'superchat-runtime-cancel))
          (superchat-runtime-cancel (plist-get entry :run-id)))
        ;; Inline delivery may have finalized this request or replaced its owner.
        (when-let* ((current (gethash node-id supertag-ai--candidates))
                    (_ (eq token (plist-get current :token)))
                    (_ (eq (plist-get current :status) 'pending)))
          (puthash node-id (plist-put current :status 'cancelled) supertag-ai--candidates)
          (supertag-ai--refresh node-id)
          (supertag-ai--batch-note node-id token batch))))))

(defun supertag-ai-cancel-extraction ()
  "Cancel extraction for the node at point."
  (interactive)
  (let ((id (or (and (derived-mode-p 'supertag-view-node-mode)
                     supertag-view-node--current-node-id)
                (org-entry-get nil "ID"))))
    (unless (and id (eq (plist-get (gethash id supertag-ai--candidates) :status) 'pending))
      (user-error "No extraction running for this node"))
    (supertag-ai-cancel id)))

;;;; Batch extraction by tag (serial)

(defvar supertag-ai--batch nil
  "Active batch extraction: plist :tag :prompt :queue :current :done, or nil.")

(defun supertag-ai--tag-member-nodes (tag-id)
  "Return ids of headline nodes (level > 0) whose tags include TAG-ID."
  (let (ids)
    (maphash (lambda (id node)
               (when (and (member tag-id (plist-get node :tags))
                          (not (eql (plist-get node :level) 0)))
                 (push id ids)))
             (supertag-store-get-collection :nodes))
    (sort ids #'string<)))

(defvar supertag-ai--batch-draining nil
  "Batch whose queue is currently being drained, or nil.")

(defun supertag-ai--batch-advance ()
  "Drain the active batch until an asynchronous request owns its current slot."
  (let ((batch supertag-ai--batch))
    (when (and batch (not (eq batch supertag-ai--batch-draining)))
      (let ((supertag-ai--batch-draining batch))
        (while (and (eq batch supertag-ai--batch)
                    (null (plist-get batch :current))
                    (plist-get batch :queue))
          (let ((id (pop (plist-get batch :queue))))
            (if (eq (plist-get (gethash id supertag-ai--candidates) :status) 'pending)
                (message "Supertag AI: %s already extracting; skipped" id)
              ;; Inline delivery may clear this slot before --start returns.
              (plist-put batch :current id)
              (condition-case err
                  (supertag-ai--start id (plist-get batch :prompt))
                (error
                 (when (and (eq batch supertag-ai--batch)
                            (equal id (plist-get batch :current)))
                   (plist-put batch :current nil))
                 (message "Supertag AI: %s skipped: %s" id (error-message-string err)))))))
        (when (and (eq batch supertag-ai--batch)
                   (null (plist-get batch :current))
                   (null (plist-get batch :queue)))
          (let ((done (reverse (plist-get batch :done)))
                (tag (plist-get batch :tag)))
            (setq supertag-ai--batch nil)
            (message "Supertag AI: batch for #%s finished (%d node(s))" tag (length done))
            (when done (supertag-ai-plan-open done))))))))

(defun supertag-ai--batch-note (node-id token batch)
  "Finish NODE-ID only while TOKEN still owns its terminal entry and BATCH slot.
Callers retain TOKEN and BATCH before any cancellation or refresh can reenter."
  (let ((entry (gethash node-id supertag-ai--candidates)))
    (when (and batch (eq batch supertag-ai--batch)
               (equal node-id (plist-get batch :current))
               token (eq token (plist-get entry :token))
               (memq (plist-get entry :status) '(done failed cancelled)))
      (plist-put batch :current nil)
      (when (eq (plist-get entry :status) 'done)
        (plist-put batch :done (cons node-id (plist-get batch :done))))
      (supertag-ai--batch-advance))))

(defun supertag-ai-extract-tag-properties (&optional choose-prompt)
  "Extract property candidates for every node tagged with a chosen tag, one at a time.
CHOOSE-PROMPT selects a template as in `supertag-ai-extract-properties'."
  (interactive "P")
  (unless (fboundp 'superchat-runtime-submit)
    (user-error "Supertag AI needs the superchat package loaded first (see README)"))
  (when supertag-ai--batch
    (user-error "A batch extraction is already running; cancel it first"))
  (let* ((name (supertag-ui-read-tag "Extract properties for nodes tagged: "
                                     (supertag-view-api-list-tag-ids)))
         (tag-id (and name (supertag-tag-resolve-occurrence (supertag-sanitize-tag-name name))))
         (nodes (and tag-id (supertag-ai--tag-member-nodes tag-id)))
         (prompt (if choose-prompt
                     (intern (completing-read "Extraction prompt: "
                                              (mapcar (lambda (p) (symbol-name (car p)))
                                                      supertag-ai-prompts)
                                              nil t))
                   'extract-properties)))
    (unless tag-id (user-error "No such tag"))
    (unless nodes (user-error "No headline nodes are tagged #%s" tag-id))
    (when (yes-or-no-p (format "Extract properties for %d node(s) tagged #%s? "
                               (length nodes) tag-id))
      (setq supertag-ai--batch (list :tag tag-id :prompt prompt :queue nodes
                                     :current nil :done nil))
      (supertag-ai--batch-advance))))

(defun supertag-ai-cancel-batch ()
  "Stop the running batch extraction and cancel its in-flight request."
  (interactive)
  (unless supertag-ai--batch (user-error "No batch extraction is running"))
  (let ((current (plist-get supertag-ai--batch :current))
        (tag (plist-get supertag-ai--batch :tag)))
    (setq supertag-ai--batch nil)
    (when current (supertag-ai-cancel current))
    (message "Supertag AI: batch for #%s cancelled" tag)))

(defun supertag-ai-skip (node-id name)
  "Remove NAME from NODE-ID's candidates without writing facts."
  (when-let* ((entry (gethash node-id supertag-ai--candidates)))
    (puthash node-id
             (plist-put entry :candidates
                        (cl-remove name (plist-get entry :candidates)
                                   :key (lambda (c) (plist-get c :name)) :test #'equal))
             supertag-ai--candidates)
    (supertag-ai--refresh node-id)))

(defun supertag-ai--disk-value (node-id name)
  "Read NAME from the unique real heading with NODE-ID on disk.
Example ID text and ambiguous identities provide no persistence proof."
  (let ((file (plist-get (supertag-node-get node-id) :file)) headings)
    (with-temp-buffer
      (insert-file-contents file)
      (delay-mode-hooks (org-mode))
      (goto-char (point-min))
      (while (re-search-forward
              (concat "^[ \t]*:ID:[ \t]*" (regexp-quote node-id) "[ \t]*$") nil t)
        (save-excursion
          (when (org-at-property-p)
            (condition-case nil
                (progn
                  (org-back-to-heading t)
                  (when (equal (org-entry-get nil "ID") node-id)
                    (cl-pushnew (point) headings)))
              (error nil)))))
      (when (= (length headings) 1)
        (goto-char (car headings))
        (org-entry-get nil name)))))

(defun supertag-ai-accept (node-id name)
  "Accept NAME for NODE-ID only after checking the live baseline and disk value."
  (when-let* ((candidate (cl-find name (plist-get (gethash node-id supertag-ai--candidates) :candidates)
                                 :key (lambda (c) (plist-get c :name)) :test #'equal)))
    (condition-case err
        (let* ((value (plist-get candidate :value))
               (old (plist-get candidate :current))
               (live (supertag-service-org--with-node-buffer
                      node-id (lambda () (org-entry-get nil name)))))
          (when (equal live "") (setq live nil))
          (when (equal old "") (setq old nil))
          (if (and (not (equal live value)) (not (equal live old)))
              (progn
                (let ((cell (memq candidate
                                  (plist-get (gethash node-id supertag-ai--candidates) :candidates))))
                  (setf (plist-get candidate :previous) old
                        (plist-get candidate :current) live
                        (plist-get candidate :stale) t)
                  (setcar cell candidate))
                (supertag-ai--refresh node-id)
                (message "%s changed to %s since extraction; review again" name (or live "(none)"))
                nil)
            (unless (equal live value)
              (supertag-service-org-set-property node-id name value))
            (if (equal (supertag-ai--disk-value node-id name) value)
                (progn (supertag-ai-skip node-id name) t)
              (message "Supertag AI: %s is in the Org buffer but not saved yet; save %s, then accept again"
                       name (file-name-nondirectory (plist-get (supertag-node-get node-id) :file)))
              nil)))
      (error (message "Supertag AI: %s" (error-message-string err)) nil))))

(defun supertag-ai-accept-all (node-id)
  "Accept NODE-ID's candidates sequentially, stopping at the first failed write."
  (let ((candidates (plist-get (gethash node-id supertag-ai--candidates) :candidates)))
    (while (and candidates (supertag-ai-accept node-id (plist-get (car candidates) :name)))
      (setq candidates (cdr candidates)))))

(defun supertag-ai-discard (node-id)
  "Discard NODE-ID's in-memory extraction entry without writing facts."
  (remhash node-id supertag-ai--candidates)
  (supertag-ai--refresh node-id))

(defun supertag-ai-show-raw (node-id)
  "Show the raw failed response for NODE-ID."
  (let ((raw (plist-get (gethash node-id supertag-ai--candidates) :raw)))
    (with-current-buffer (get-buffer-create "*Supertag AI Raw*")
      (let ((inhibit-read-only t)) (erase-buffer) (insert (or raw "")))
      (special-mode)
      (pop-to-buffer (current-buffer)))))

(defun supertag-ai--button (label action node-id &optional name)
  "Insert LABEL invoking ACTION with NODE-ID and optional candidate NAME."
  (supertag-view-helper-insert-action-button
   label (lambda (button)
           (let ((data (button-get button 'supertag-ai-candidate)))
             (apply action data)))
   (if name (list node-id name) (list node-id)) label 'supertag-ai-candidate))

(defun supertag-ai-insert-section (node-id)
  "Insert NODE-ID's disposable extraction section, if present."
  (when-let* ((entry (gethash node-id supertag-ai--candidates)))
    (let ((candidates (plist-get entry :candidates)))
      (insert "\n")
      (supertag-view-helper-insert-section-chip "Property Candidates" (length candidates)
                                                   'supertag-view-chip2)
      (pcase (plist-get entry :status)
        ('pending
         (insert (propertize (format "  Extracting with prompt %s…\n" (plist-get entry :prompt))
                             'face 'supertag-view-mute))
         (supertag-ai--button "[Cancel]" #'supertag-ai-cancel node-id)
         (insert "\n"))
        ('cancelled
         (insert (propertize "  Cancelled.\n" 'face 'supertag-view-mute))
         (supertag-ai--button "[Discard]" #'supertag-ai-discard node-id)
         (insert "  ") (supertag-ai--button "[Retry]" #'supertag-ai--retry node-id)
         (insert "\n"))
        ('failed
         (insert (propertize (format "  Failed: %s\n" (plist-get entry :message))
                             'face 'supertag-view-mute))
         (supertag-ai--button "[Discard]" #'supertag-ai-discard node-id)
         (when (plist-get entry :raw)
           (insert "  ") (supertag-ai--button "[Show raw]" #'supertag-ai-show-raw node-id))
         (insert "\n"))
        ('done
         (if candidates
             (progn
               (dolist (candidate candidates)
                 (let* ((name (plist-get candidate :name))
                        (current (plist-get candidate :current))
                        (source (plist-get candidate :source))
                        (start (point)))
                   (insert (propertize
                            (format "  %s: %s%s\n" name
                                    (if current (concat current " → ") "")
                                    (plist-get candidate :value))
                            'face 'supertag-view-entry))
                   (when (plist-get candidate :stale)
                     (insert (propertize
                              (format "      changed since extraction: %s → %s\n"
                                      (or (plist-get candidate :previous) "(none)")
                                      (or current "(none)"))
                              'face 'supertag-view-mute)))
                   (supertag-view-helper-insert-excerpt
                    (if (plist-get candidate :source-verified)
                        source
                      (or source "Not found in the body")))
                   (insert "    ")
                   (supertag-ai--button "[Accept]" #'supertag-ai-accept node-id name)
                   (insert "  ")
                   (supertag-ai--button "[Skip]" #'supertag-ai-skip node-id name)
                   (insert "\n")
                   (add-text-properties start (point) '(line-spacing 0.15))))
               (supertag-ai--button "[Accept all]" #'supertag-ai-accept-all node-id)
               (insert "  ")
               (supertag-ai--button "[Discard all]" #'supertag-ai-discard node-id)
               (insert "\n"))
           (insert (propertize "  All candidates handled\n" 'face 'supertag-view-mute))
           (supertag-ai--button "[Discard]" #'supertag-ai-discard node-id)
           (insert "\n")))))))

;;;; Cross-node plan preview

(defconst supertag-ai-plan-buffer-name "*Supertag AI Plan*"
  "Buffer showing a cross-node property plan before it is applied.")

(defvar-local supertag-ai-plan--nodes nil
  "Node ids whose done candidates this plan covers, in display order.")

(defvar-local supertag-ai-plan--items nil
  "Exact plan snapshot: plists :node-id :name :value :current :file :skip.")

(defvar supertag-ai-plan-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "k") #'supertag-ai-plan-toggle-skip)
    (define-key map (kbd "a") #'supertag-ai-plan-apply)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `supertag-ai-plan-mode'.")

(define-derived-mode supertag-ai-plan-mode special-mode "Supertag-AI-Plan"
  "Review a cross-node property plan: k toggles skip, a applies, q quits.")

(defun supertag-ai--unsaved-file-p (node-id)
  "Return non-nil when NODE-ID's source file is visited by a modified buffer."
  (when-let* ((file (plist-get (supertag-node-get node-id) :file))
              (buffer (find-buffer-visiting file)))
    (buffer-modified-p buffer)))

(defun supertag-ai--plan-items (node-ids)
  "Snapshot the done candidates of NODE-IDS as plan items."
  (let (items)
    (dolist (id node-ids)
      (let ((entry (gethash id supertag-ai--candidates)))
        (when (eq (plist-get entry :status) 'done)
          (dolist (candidate (plist-get entry :candidates))
            (push (list :node-id (copy-sequence id)
                        :name (copy-sequence (plist-get candidate :name))
                        :value (copy-sequence (plist-get candidate :value))
                        :current (and (plist-get candidate :current)
                                      (copy-sequence (plist-get candidate :current)))
                        :verified (plist-get candidate :source-verified)
                        :file (and (plist-get (supertag-node-get id) :file)
                                   (copy-sequence (plist-get (supertag-node-get id) :file)))
                        :skip nil)
                  items)))))
    (nreverse items)))

(defun supertag-ai-plan-open (node-ids)
  "Open the plan buffer for NODE-IDS, grouped by file."
  (let* ((nodes (sort (copy-sequence node-ids)
                      (lambda (a b)
                        (string< (or (plist-get (supertag-node-get a) :file) "")
                                 (or (plist-get (supertag-node-get b) :file) "")))))
         (items (supertag-ai--plan-items nodes)))
    (with-current-buffer (get-buffer-create supertag-ai-plan-buffer-name)
      (supertag-ai-plan-mode)
      (setq supertag-ai-plan--nodes nodes
            supertag-ai-plan--items items)
      (supertag-ai-plan--render)
      (pop-to-buffer (current-buffer)))))

(defun supertag-ai-plan--render ()
  "Redraw the plan buffer from its snapshot, keeping point where it was."
  (let ((inhibit-read-only t) (line (line-number-at-pos)) file node)
    (erase-buffer)
    (insert (format "Property plan: %d candidate(s) across %d node(s)\n"
                    (length supertag-ai-plan--items) (length supertag-ai-plan--nodes)))
    (insert "k: toggle skip on a candidate line   a: apply the plan as shown   q: quit\n")
    (dolist (item supertag-ai-plan--items)
      (unless (equal file (plist-get item :file))
        (setq file (plist-get item :file))
        (insert (format "\n%s\n" (abbreviate-file-name (or file "(no file)")))))
      (unless (equal node (plist-get item :node-id))
        (setq node (plist-get item :node-id))
        (insert (format "  %s\n" (or (plist-get (supertag-node-get node) :title) node))))
      (insert (propertize
               (format "    %s %s: %s%s%s\n"
                       (if (plist-get item :skip) "[skip]" "[write]")
                       (plist-get item :name)
                       (if (plist-get item :current) (concat (plist-get item :current) " → ") "")
                       (plist-get item :value)
                       (if (plist-get item :verified) "" "  (unverified)"))
               'supertag-ai-plan-item item)))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun supertag-ai-plan-toggle-skip ()
  "Toggle skipping the candidate on this line."
  (interactive)
  (let ((item (get-text-property (line-beginning-position) 'supertag-ai-plan-item)))
    (unless item (user-error "Not on a candidate line"))
    (plist-put item :skip (not (plist-get item :skip)))
    (supertag-ai-plan--render)))

(defun supertag-ai-plan-apply ()
  "Apply the plan exactly as shown; anything that changed meanwhile is left unwritten."
  (interactive)
  (let ((written 0) (skipped 0) (changed 0) (unsaved 0))
    (dolist (item supertag-ai-plan--items)
      (let* ((id (plist-get item :node-id))
             (name (plist-get item :name))
             (candidate (cl-find name (plist-get (gethash id supertag-ai--candidates) :candidates)
                                 :key (lambda (c) (plist-get c :name)) :test #'equal)))
        (cond
         ((plist-get item :skip) (cl-incf skipped))
         ((not (and candidate
                    (equal (plist-get candidate :value) (plist-get item :value))
                    (equal (plist-get candidate :current) (plist-get item :current))
                    (equal (plist-get (supertag-node-get id) :file)
                           (plist-get item :file))))
          (cl-incf changed)
          (message "Supertag AI: plan changed for %s %s; not written" id name))
         ((supertag-ai--unsaved-file-p id)
          (cl-incf unsaved)
          (message "Supertag AI: unsaved file for %s; not written" id))
         ((supertag-ai-accept id name) (cl-incf written))
         (t (cl-incf changed)))))
    (setq supertag-ai-plan--items (supertag-ai--plan-items supertag-ai-plan--nodes))
    (supertag-ai-plan--render)
    (message "Supertag AI plan: %d written, %d skipped, %d plan changed, %d unsaved file"
             written skipped changed unsaved)))

(defun supertag-ai--reset-runtime ()
  "Invalidate disposable AI state before cancelling requests at a vault boundary."
  (let (runs)
    (maphash (lambda (_id entry)
               (when (and (eq (plist-get entry :status) 'pending)
                          (plist-get entry :run-id))
                 (push (plist-get entry :run-id) runs)))
             supertag-ai--candidates)
    ;; Cancellation may deliver inline.  No old token or plan may survive it.
    (setq supertag-ai--batch nil)
    (clrhash supertag-ai--candidates)
    (when-let* ((plan (get-buffer supertag-ai-plan-buffer-name)))
      (with-current-buffer plan
        (setq supertag-ai-plan--nodes nil
              supertag-ai-plan--items nil)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "Property plan expired after runtime reset; extract again.\n"))))
    (when (fboundp 'superchat-runtime-cancel)
      (dolist (run (delete-dups runs))
        (condition-case err
            (superchat-runtime-cancel run)
          (error (message "Supertag AI: cancellation failed: %s"
                          (error-message-string err))))))))

(provide 'supertag-ai)
;;; supertag-ai.el ends here
