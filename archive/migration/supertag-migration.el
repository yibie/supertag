;;; supertag-migration.el --- Standalone data migration script  -*- lexical-binding: t; -*-

;;; Commentary:
;; This file contains a self-contained function to migrate data from the
;; old `org-supertag-db.el` format to the new data-centric architecture.
;; It is broken into smaller helper functions to ensure correctness and readability.

;;; Code:

(require 'ht)
(require 'cl-lib)
(require 'sha1)      ; For secure-hash
(require 'org)
(require 'org-element)
(require 'subr-x)
(require 'supertag-core-store)
(require 'supertag-core-persistence)
(require 'supertag-ops-node)
(require 'supertag-service-node-identity)
(require 'supertag-ops-relation)
(require 'supertag-ops-tag)
(require 'supertag-view-helper)
(require 'supertag-services-sync)
(require 'org)
(require 'org-element)

(defvar supertag-query-saved)
(defvar supertag--view-configs)

(declare-function supertag-tag-merge--plist-p
                  "supertag-ops-tag-merge" (value))
(declare-function supertag-tag-merge--string-mentions-source-p
                  "supertag-ops-tag-merge" (string source-ids))
(declare-function supertag-tag-path-rename--rewrite-structured
                  "supertag-ops-tag-merge" (form mapping))
(declare-function supertag-tag-path-rename--rewrite-values
                  "supertag-ops-tag-merge" (value mapping))
(declare-function supertag-tag-merge--snapshot-files
                  "supertag-ops-tag-merge" (files))
(declare-function supertag-tag-merge--restore-files
                  "supertag-ops-tag-merge" (snapshot))
(declare-function supertag-tag-merge--delete-snapshot
                  "supertag-ops-tag-merge" (snapshot))

;;; --- Helper Functions ---

(defun supertag-migrate--sanitize-tag-name (name)
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

(defun supertag-migrate--generate-relation-id (from-id to-id type)
  "Generate a deterministic relation ID using SHA1.
Uses the same format as the current system."
  (format "rel-%s" (secure-hash 'sha1 (format "%s|%s|%s" from-id to-id type))))

(defun supertag-migrate--unescape-string (str)
  "Convert escaped octal sequences back to UTF-8 characters.
Input like '\\346\\265\\201\\351\\207\\217' becomes '流量'."
  (when (stringp str)
    (with-temp-buffer
      (insert str)
      (goto-char (point-min))
      ;; Replace octal escape sequences
      (while (re-search-forward "\\\\\\([0-7]\\{3\\}\\)" nil t)
        (let* ((octal-str (match-string 1))
               (char-code (string-to-number octal-str 8))
               (char (if (and (>= char-code 32) (<= char-code 126))
                         ;; ASCII range
                         (char-to-string char-code)
                       ;; For non-ASCII, we need to handle as bytes and decode
                       (char-to-string char-code))))
          (replace-match char)))
      ;; Try to decode the result as UTF-8 if it contains high bytes
      (let ((result (buffer-string)))
        (condition-case nil
            (decode-coding-string result 'utf-8)
          (error result))))))

(defun supertag-migrate--clean-plist-strings (plist)
  "Recursively clean escaped strings in a plist."
  (when plist
    (let ((result '()))
      (while plist
        (let ((key (car plist))
              (value (cadr plist)))
          (push key result)
          (push (cond
                 ((stringp value)
                  (supertag-migrate--unescape-string value))
                 ((listp value)
                  (mapcar (lambda (item)
                            (if (stringp item)
                                (supertag-migrate--unescape-string item)
                              item))
                          value))
                 (t value))
                result)
          (setq plist (cddr plist))))
      (nreverse result))))

(defun supertag-migrate--ensure-node-location-data (node-props)
  "Ensure node has necessary location data for jumping.
Migrates old field names (:file-path -> :file, :pos -> :position) and
returns updated node properties with required location fields."
  (let ((file (plist-get node-props :file))
        (position (plist-get node-props :position))
        (raw-value (plist-get node-props :raw-value))
        (file-path (plist-get node-props :file-path))
        (pos (plist-get node-props :pos)))

    ;; Migrate old field names to new ones
    (when (and file-path (not file))
      (setq node-props (plist-put node-props :file file-path))
      (setq file file-path))

    (when (and pos (not position))
      (setq node-props (plist-put node-props :position pos))
      (setq position pos))

    ;; If we don't have :raw-value but have :title, copy it
    (unless raw-value
      (let ((title (plist-get node-props :title)))
        (when title
          (setq node-props (plist-put node-props :raw-value title)))))

    ;; Warn only if we still don't have location data after migration attempt
    (unless file
      (message "Warning: Node missing :file attribute, navigation may not work"))
    (unless position
      (message "Warning: Node missing :position attribute, navigation may not work"))

    node-props))

(defun supertag-migrate--safely-load-data (file)
  "Read FILE and extract `org-supertag-db--object` and `org-supertag-db--link`.
This function works by evaluating the entire file in a lexical context
where the hash-table variables are pre-defined."
  (let ((org-supertag-db--object (ht-create))
        (org-supertag-db--link (ht-create))
        (org-supertag-db--embeds (ht-create)))
    (with-temp-buffer
      ;; Force UTF-8 encoding for reading
      (let ((coding-system-for-read 'utf-8-unix)
            (buffer-file-coding-system 'utf-8-unix))
        (insert-file-contents file))
      (set-buffer-file-coding-system 'utf-8-unix)
      (goto-char (point-min))
      (let ((eof (cons 'eof nil)))
        (while (not (eobp))
          (let ((form (condition-case nil
                          (read (current-buffer))
                        (end-of-file eof))))
            (unless (eq form eof)
              ;; Eval each form. This will populate the lexically bound hash tables.
              (eval form t))))))
    (list org-supertag-db--object org-supertag-db--link org-supertag-db--embeds)))

(defun ht-deep-copy-table (table)
  "Create a deep copy of hash TABLE.
This function recursively copies nested hash tables."
  (let ((copy (ht-create)))
    (maphash
     (lambda (key value)
       (puthash key
                (if (hash-table-p value)
                    (ht-deep-copy-table value)
                  value)
                copy))
     table)
    copy))

(defun supertag-migrate--backup-db (file-to-backup)
  "Create a timestamped backup of the specified database file."
  (when (and file-to-backup (file-exists-p file-to-backup))
    (let ((backup-file (format "%s.bak-%s"
                               file-to-backup
                               (format-time-string "%Y%m%d-%H%M%S"))))
      (copy-file file-to-backup backup-file t)
      (message "Old database backed up to: %s" backup-file))))

;; ------------------------------------------------------------------
;; Legacy :tag: migration (optional utility)
;; ------------------------------------------------------------------

(defun supertag--detect-headline-tag-style (headline)
  "Detect tag style used on HEADLINE element. Returns 'inline, 'org, 'both or 'none."
  (let* ((raw (org-element-property :raw-value headline))
         (org-tags (org-element-property :tags headline))
         (has-inline (and raw (string-match-p "#[^[:space:]#]+" raw)))
         (has-org (and org-tags (> (length org-tags) 0))))
    (cond
     ((and has-inline has-org) 'both)
     (has-inline 'inline)
     (has-org 'org)
     (t 'none))))

(defun supertag--rewrite-headline-tags (headline style)
  "Rewrite HEADLINE tags to STYLE. Returns plist (:changedp t :begin BEG :end END) or nil."
  (let* ((beg (org-element-property :begin headline))
         (end (save-excursion (goto-char beg) (end-of-line) (point)))
         (level (org-element-property :level headline))
         (title (org-element-property :raw-value headline))
         (tags (org-element-property :tags headline))
         (clean-title (string-trim (replace-regexp-in-string ":[[:alnum:]_@#%]+:" ""
                                       (replace-regexp-in-string "#[^[:space:]#]+" "" title))))
         (inline-part (when tags (mapconcat (lambda (tag) (concat "#" tag)) tags " ")))
         (org-part (when tags (concat ":" (mapconcat #'identity tags ":") ":")))
         (new-line (pcase style
                     ('inline (format "%s %s%s"
                                      (make-string level ?*) clean-title
                                      (if inline-part (concat " " inline-part) "")))
                     ('org    (format "%s %s%s"
                                      (make-string level ?*) clean-title
                                      (if org-part (concat " " org-part) "")))
                     ('both   (format "%s %s%s%s"
                                      (make-string level ?*) clean-title
                                      (if inline-part (concat " " inline-part) "")
                                      (if org-part (concat " " org-part) "")))
                     (_ nil))))
    (when new-line
      (save-excursion
        (goto-char beg)
        (delete-region beg end)
        (insert new-line))
      (list :changedp t :begin beg :end (save-excursion (goto-char beg) (end-of-line) (point))))))

(defun supertag-migration--backup-file (file)
  "Create a unique adjacent backup for FILE. Return backup path."
  (let ((backup
         (make-temp-file
          (expand-file-name
           (format ".%s.supertag-migration-" (file-name-nondirectory file))
           (file-name-directory file))
          nil ".bak")))
    (copy-file file backup t t)
    backup))

(defun supertag-migration--restore-backup (file backup)
  "Restore FILE from BACKUP. Return t on success."
  (when (and (file-exists-p backup))
    (copy-file backup file t t)
    (when-let* ((buffer (find-buffer-visiting file)))
      (with-current-buffer buffer
        (let ((inhibit-message t))
          (revert-buffer t t t))))
    t))

(defconst supertag-migration--reciprocal-buffer
  "*Supertag Reciprocal Link Migration*"
  "Preview buffer for ambiguous reciprocal links.")

(defun supertag-migration--link-owner (link file-header)
  "Return LINK's persistent source ID and title.
FILE-HEADER supplies the owner for links outside every headline."
  (let ((parent (org-element-property :parent link)))
    (while (and parent (not (eq (org-element-type parent) 'headline)))
      (setq parent (org-element-property :parent parent)))
    (if parent
        (list (org-element-property :ID parent)
              (org-element-property :raw-value parent))
      (list (plist-get file-header :id)
            (plist-get file-header :title)))))

(defun supertag-migration--scan-reference-occurrences (file)
  "Return persistent directed reference occurrences physically in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (delay-mode-hooks (org-mode))
    (let* ((file (file-truename file))
           (file-hash (secure-hash 'sha256 (current-buffer)))
           (file-header (supertag-sync--parse-file-header))
           (ast (org-element-parse-buffer))
           occurrences)
      (org-element-map ast 'link
        (lambda (link)
          (when-let* ((target (car (supertag--extract-refs (list link))))
                      (owner (supertag-migration--link-owner link file-header))
                      (source (car owner)))
            (let* ((begin (org-element-property :begin link))
                   (end (- (org-element-property :end link)
                           (or (org-element-property :post-blank link) 0)))
                   (text (buffer-substring-no-properties begin end))
                   (id (secure-hash
                        'sha256
                        (prin1-to-string
                         (list file file-hash source target begin end text))))
                   (source-title (or (cadr owner) source))
                   (target-title
                    (or (plist-get (supertag-node-get target) :title) target)))
              (push
               (list :id id :from source :to target :file file
                     :begin begin :end end
                     :line (line-number-at-pos begin t)
                     :text text :file-hash file-hash
                     :source-title source-title :target-title target-title
                     :label
                     (format "Delete %s → %s (%s:%d) [%s]"
                             source-title target-title
                             (file-name-nondirectory file)
                             (line-number-at-pos begin t)
                             (substring id 0 8)))
               occurrences)))))
      (nreverse occurrences))))

(defun supertag-migration--reciprocal-candidates (files)
  "Return exact mutual directed link occurrences from FILES."
  (let ((directions (make-hash-table :test 'equal)) occurrences)
    (dolist (file files)
      (setq occurrences
            (nconc occurrences
                   (supertag-migration--scan-reference-occurrences file))))
    (dolist (item occurrences)
      (puthash (cons (plist-get item :from) (plist-get item :to)) t directions))
    (sort
     (cl-remove-if-not
      (lambda (item)
        (let ((from (plist-get item :from))
              (to (plist-get item :to)))
          (and (not (equal from to))
               (gethash (cons to from) directions))))
      occurrences)
     (lambda (left right)
       (let ((left-key (cons (plist-get left :file) (plist-get left :begin)))
             (right-key (cons (plist-get right :file) (plist-get right :begin))))
         (or (string< (car left-key) (car right-key))
             (and (equal (car left-key) (car right-key))
                  (< (cdr left-key) (cdr right-key)))))))))

(defun supertag-migration--show-reciprocal-preview (report)
  "Display read-only reciprocal migration REPORT."
  (with-current-buffer (get-buffer-create supertag-migration--reciprocal-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "Ambiguous Reciprocal Link Migration\n\n"
              "A mutual pair does not prove which link was an old automatic backlink.\n"
              "Nothing is selected or deleted by default.\n\n")
      (if (eq 'preview (plist-get report :status))
          (progn
            (insert (format "%d candidate occurrence(s):\n\n"
                            (plist-get report :candidate-count)))
            (dolist (item (plist-get report :candidates))
              (insert "[ ] " (plist-get item :label) "\n"
                      "    " (plist-get item :text) "\n")))
        (insert (format "Preview aborted: snapshot is %s.\n"
                        (plist-get report :snapshot-status)))
        (dolist (error (plist-get report :errors))
          (insert (format "  %s\n" error))))
      (goto-char (point-min))
      (special-mode))
    (display-buffer (current-buffer)))
  report)

;;;###autoload
(defun supertag-migration-preview-reciprocal-links (&optional displayp)
  "Preview exact link occurrences participating in mutual directed pairs.
The scan is read-only.  Mutuality is only a candidate signal: this command
does not infer ownership and does not select anything for deletion."
  (interactive (list t))
  (let* ((snapshot (supertag-sync--snapshot-build))
         (snapshot-status (plist-get snapshot :status))
         (files (sort (mapcar #'file-truename
                              (copy-sequence (plist-get snapshot :files)))
                      #'string<))
         report)
    (if (not (eq snapshot-status 'complete))
        (setq report
              (list :status 'aborted :snapshot-status snapshot-status
                    :files-scanned 0 :candidate-count 0 :candidates nil
                    :errors (plist-get snapshot :errors)))
      (condition-case err
          (let ((candidates
                 (supertag-migration--reciprocal-candidates files)))
            (setq report
                  (list :status 'preview :snapshot-status snapshot-status
                        :files-scanned (length files)
                        :candidate-count (length candidates)
                        :candidates candidates :errors nil)))
        (error
         (setq report
               (list :status 'aborted :snapshot-status snapshot-status
                     :files-scanned 0 :candidate-count 0 :candidates nil
                     :errors (list (error-message-string err)))))))
    (if displayp
        (supertag-migration--show-reciprocal-preview report)
      report)))

(defun supertag-migration--restore-state-table (table snapshot)
  "Replace TABLE contents with SNAPSHOT."
  (clrhash table)
  (maphash (lambda (key value) (puthash key value table)) snapshot))

(defun supertag-migration--selected-candidates (report candidate-ids)
  "Resolve CANDIDATE-IDS against REPORT, or return nil if stale."
  (let ((wanted (delete-dups (copy-sequence candidate-ids))) selected)
    (dolist (id wanted)
      (when-let* ((item (cl-find id (plist-get report :candidates)
                                 :key (lambda (candidate)
                                        (plist-get candidate :id))
                                 :test #'equal)))
        (push item selected)))
    (when (= (length wanted) (length selected))
      (nreverse selected))))

;;;###autoload
(defun supertag-migration-execute-reciprocal-links (report candidate-ids)
  "Delete exact CANDIDATE-IDS selected from preview REPORT.
Return a report plist.  Empty or stale selections abort without writes.
Every affected Org file is backed up before the first deletion; file and
Store changes are restored if projection fails."
  (if (null candidate-ids)
      (list :status 'aborted :reason 'no-selection :removed 0)
    (let* ((fresh (supertag-migration-preview-reciprocal-links))
           (original (supertag-migration--selected-candidates report candidate-ids))
           (selected (and original
                          (supertag-migration--selected-candidates fresh candidate-ids))))
      (if (or (not (eq 'preview (plist-get fresh :status)))
              (null original) (null selected))
          (list :status 'aborted :reason 'stale-preview :removed 0)
        (let* ((files (delete-dups (mapcar (lambda (item) (plist-get item :file))
                                           selected)))
               (state-table (supertag-sync--get-state-table))
               (state-before (copy-hash-table state-table))
               (deferred-before (copy-hash-table supertag-sync--deferred-files))
               (internal-before
                (copy-hash-table supertag-sync--internal-modifications))
               (snapshot-before (copy-tree (supertag-sync--snapshot-get)))
               (counters '(:nodes-created 0 :nodes-updated 0 :nodes-deleted 0
                           :references-created 0 :references-deleted 0))
               buffers opened backups report-result)
          (unwind-protect
              (condition-case err
                  (progn
                    ;; Refuse to overwrite user edits and validate every exact range
                    ;; before creating snapshots or touching any file.
                    (dolist (file files)
                      (let* ((existing (find-buffer-visiting file))
                             (buffer (or existing (find-file-noselect file))))
                        (unless existing (push buffer opened))
                        (with-current-buffer buffer
                          (when (buffer-modified-p)
                            (error "Unsaved edits in %s" file))
                          (unless (verify-visited-file-modtime buffer)
                            (revert-buffer t t t))
                          (dolist (item (cl-remove-if-not
                                         (lambda (candidate)
                                           (equal file (plist-get candidate :file)))
                                         selected))
                            (unless (and (<= (plist-get item :end) (point-max))
                                         (equal (plist-get item :text)
                                                (buffer-substring-no-properties
                                                 (plist-get item :begin)
                                                 (plist-get item :end))))
                              (error "Stale link occurrence in %s" file))))
                        (push (cons file buffer) buffers)))
                    (dolist (file files)
                      (push (cons file (supertag-migration--backup-file file)) backups))
                    (supertag-with-transaction
                      (dolist (pair buffers)
                        (let ((file (car pair)))
                          (with-current-buffer (cdr pair)
                            (save-restriction
                              (widen)
                              (dolist
                                  (item
                                   (sort
                                    (cl-remove-if-not
                                     (lambda (candidate)
                                       (equal file (plist-get candidate :file)))
                                     (copy-sequence selected))
                                    (lambda (left right)
                                      (> (plist-get left :begin)
                                         (plist-get right :begin)))))
                                (delete-region (plist-get item :begin)
                                               (plist-get item :end))))
                            (supertag--mark-internal-modification file)
                            (save-buffer))))
                      (let ((supertag-sync--is-full-rescan-p t))
                        (dolist (file files)
                          (supertag-sync--process-single-file file counters)))
                      (supertag-sync--rebuild-reference-caches))
                    (setq report-result
                          (list :status 'complete :removed (length selected)
                                :files-changed (length files)
                                :backups (nreverse backups))))
                (error
                 (let (restore-errors)
                   (dolist (pair backups)
                     (condition-case restore-error
                         (supertag-migration--restore-backup (car pair) (cdr pair))
                       (error
                        (push (error-message-string restore-error) restore-errors))))
                   (supertag-migration--restore-state-table state-table state-before)
                   (setq supertag-sync--deferred-files deferred-before
                         supertag-sync--internal-modifications internal-before)
                   (supertag-sync--snapshot-set snapshot-before)
                   (when restore-errors
                     (error "Migration and recovery failed; backups: %S; errors: %S"
                            backups (nreverse restore-errors)))
                   (setq report-result
                         (list :status 'failed :removed 0
                               :files-changed 0 :backups (nreverse backups)
                               :errors (list (error-message-string err)))))))
            (dolist (buffer opened)
              (when (buffer-live-p buffer) (kill-buffer buffer))))
          report-result)))))

;;;###autoload
(defun supertag-migrate-reciprocal-links ()
  "Preview and explicitly select ambiguous reciprocal links to delete."
  (interactive)
  (let* ((preview (supertag-migration-preview-reciprocal-links))
         (candidates (plist-get preview :candidates)))
    (supertag-migration--show-reciprocal-preview preview)
    (cond
     ((not (eq 'preview (plist-get preview :status))) preview)
     ((null candidates)
      (message "Supertag: no reciprocal link candidates found")
      (list :status 'aborted :reason 'no-candidates :removed 0))
     (t
      (let* ((labels (mapcar (lambda (item) (plist-get item :label)) candidates))
             (chosen-labels
              (completing-read-multiple
               "Delete exact link occurrences (none by default): " labels nil t))
             (chosen
              (cl-remove-if-not
               (lambda (item) (member (plist-get item :label) chosen-labels))
               candidates)))
        (cond
         ((null chosen)
          (list :status 'aborted :reason 'no-selection :removed 0))
         ((not (yes-or-no-p
                (format "Delete %d selected link occurrence(s)? " (length chosen))))
          (list :status 'aborted :reason 'confirmation-declined :removed 0))
         (t
          (let ((result
                 (supertag-migration-execute-reciprocal-links
                  preview (mapcar (lambda (item) (plist-get item :id)) chosen))))
            (message "Supertag reciprocal migration: %s, %d removed"
                     (plist-get result :status) (or (plist-get result :removed) 0))
            result))))))))

(defun supertag-migrate-legacy-tags-file (file &optional dry-run)
  "Migrate org native :tag: in FILE to inline #tags. Returns report plist.
When DRY-RUN is non-nil, do not modify the file; only report changes."
  (unless (file-exists-p file)
    (error "File not found: %s" file))
  (let ((changed 0) (errors '()) (backups '()) (headlines 0))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char (point-min))
        (let ((ast (org-element-parse-buffer)))
          (org-element-map ast 'headline
            (lambda (hl)
              (setq headlines (1+ headlines))
              (let ((style (supertag--detect-headline-tag-style hl)))
                (when (memq style '(org both))
                  (condition-case err
                      (unless dry-run
                        ;; Ensure single backup per file
                        (unless (assoc file backups)
                          (push (cons file (supertag-migration--backup-file file)) backups))
                        (when (supertag--rewrite-headline-tags hl 'inline)
                          (setq changed (1+ changed))))
                    (error (push (format "%s" err) errors))))))
          (unless dry-run (save-buffer)))))
    (list :file file :changed changed :headlines headlines :backups (mapcar #'cdr backups) :errors errors))))

(defun supertag-migrate-legacy-tags-directory (dir &optional dry-run)
  "Migrate all .org files in DIR (recursively). Returns report plist."
  (let ((files (directory-files-recursively dir "\\.org$" t))
        (total 0) (changed 0) (errors '()) (reports '()) (backups '()))
    (dolist (f files)
      (setq total (1+ total))
      (let ((r (supertag-migrate-legacy-tags-file f dry-run)))
        (setq changed (+ changed (plist-get r :changed)))
        (setq reports (cons r reports))
        (setq backups (append backups (plist-get r :backups)))
        (setq errors (append errors (plist-get r :errors)))))
    (list :files (length files) :changed changed :reports (nreverse reports) :backups backups :errors errors)))

(defun supertag-migrate--process-data (old-objects old-links old-embeds)
  "Process old data and return a new store and indexes."
  (let ((store (ht-create))
        (nodes-ht (ht-create))
        (tags-ht (ht-create))
        (fields-ht (ht-create))
        (relations-ht (ht-create))
        (embeds-ht (ht-create))
        (id-mapping (ht-create)))  ; Track old-id -> new-id mappings

    (puthash :nodes nodes-ht store)
    (puthash :tags tags-ht store)
    (puthash :fields fields-ht store)
    (puthash :relations relations-ht store)
    (when old-embeds
      (puthash :embeds embeds-ht store))

    ;; Process objects
    (maphash
     (lambda (id props)
       (let ((type (plist-get props :type))
             ;; Clean escaped strings in the properties
             (cleaned-props (supertag-migrate--clean-plist-strings props)))
         (cond ((eq type :node)
                ;; Preserve existing node-id to maintain file consistency
                (let* ((enhanced-props (supertag-migrate--ensure-node-location-data cleaned-props))
                       (final-props (plist-put enhanced-props :id id)))
                  ;; Handle tags stored directly on the node object's :tags property.
                  (let ((old-tags (plist-get final-props :tags)))
                    (if (listp old-tags)
                        ;; If :tags exists and is a list, sanitize the tag names
                        ;; into the new ID format and replace the property.
                        (let ((new-tags-list
                               (delq nil
                                     (mapcar (lambda (tag-name)
                                               (when (and (stringp tag-name) (not (string-empty-p tag-name)))
                                                 (let ((sanitized-tag (supertag-migrate--sanitize-tag-name tag-name)))
                                                   ;; CRITICAL: Ensure a corresponding tag definition exists in the central registry.
                                                   ;; If not, create a minimal one on-demand, preserving any existing fields.
                                                   (unless (gethash sanitized-tag tags-ht)
                                                     (puthash sanitized-tag
                                                              `(:id ,sanitized-tag
                                                                :name ,tag-name
                                                                :type :tag
                                                                :fields nil
                                                                :extends nil)
                                                              tags-ht))
                                                   sanitized-tag)))
                                             old-tags))))
                          (setq final-props (plist-put final-props :tags new-tags-list)))
                      ;; If :tags is not a list or is nil, remove it to ensure clean data.
                      (setq final-props (plist-remove final-props :tags))))
                  (message "Migrating node (preserving ID): %s" id)
                  (puthash id final-props nodes-ht)
                  ;; No ID mapping needed since we preserve the original ID
                  (puthash id id id-mapping)))
               ((eq type :tag)
                ;; Convert old tag-id to semantic name format
                (let* ((tag-name (or (plist-get cleaned-props :name) id))
                       (new-tag-id (supertag-migrate--sanitize-tag-name tag-name))
                       ;; Preserve existing fields and extends, or set to nil if not present
                       (fields (plist-get cleaned-props :fields))
                       (extends (plist-get cleaned-props :extends))
                       (final-props (plist-put
                                    (plist-put
                                     (plist-put cleaned-props :id new-tag-id)
                                     :fields (or fields nil))
                                    :extends (or extends nil))))
                  (message "Migrating tag: %s -> %s (fields: %s, extends: %s)"
                          id new-tag-id
                          (if fields "yes" "no")
                          (if extends "yes" "no"))
                  (puthash new-tag-id final-props tags-ht)
                  ;; Store mapping for updating relations later
                  (puthash id new-tag-id id-mapping)))
               (t (message "Skipping unknown object type: %s" type)))))
     old-objects)

    ;; Process embeds if they exist
    (when old-embeds
      (maphash
       (lambda (id props)
         (puthash id props embeds-ht))
       old-embeds))

    ;; Process links
    (maphash
     (lambda (link-id link-props)
       (let* ((type (plist-get link-props :type))
              (from (plist-get link-props :from))
              (to (plist-get link-props :to)))
         (pcase type
           (:node-tag
            ;; Map old IDs to new IDs
            (let* ((new-from (gethash from id-mapping from))
                   (new-to (gethash to id-mapping to))
                   (node-data (gethash new-from nodes-ht)))
              ;; Ensure both node and tag exist before creating the link.
              (when (and node-data new-to)
                (puthash new-from
                         (plist-put node-data :tags (cl-adjoin new-to (plist-get node-data :tags)))
                         nodes-ht))))
           (:node-field
            ;; Map old IDs to new IDs
            (let* ((new-from (gethash from id-mapping from))
                   (old-tag-id (plist-get link-props :tag-id))
                   (new-tag-id (gethash old-tag-id id-mapping))
                   (value (plist-get link-props :value)))
              ;; Ensure the node, the associated tag, and the value all exist.
              (when (and new-from to new-tag-id value)
                (let ((node-fields (gethash new-from fields-ht (ht-create))))
                  (puthash new-from node-fields fields-ht)
                  (let ((tag-fields (gethash new-tag-id node-fields (ht-create))))
                    (puthash new-tag-id tag-fields node-fields)
                    (puthash to value tag-fields))))))
           (:node-ref
            ;; Map old IDs to new IDs
            (let* ((new-from (gethash from id-mapping from))
                   (new-to (gethash to id-mapping to))
                   (node-data (gethash new-from nodes-ht)))
              (when (and node-data new-to)
                (puthash new-from
                         (plist-put node-data :refs (cl-adjoin new-to (plist-get node-data :refs)))
                         nodes-ht))))
           (_
            ;; Map old IDs to new IDs for relations
            (let* ((new-from (gethash from id-mapping from))
                   (new-to (gethash to id-mapping to)))
              ;; Only create the relation if both endpoints were successfully migrated.
              (when (and new-from new-to)
                (let* ((new-rel-id (supertag-migrate--generate-relation-id new-from new-to type))
                       (updated-props (plist-put (plist-put link-props :from new-from) :to new-to)))
                  (message "Migrating relation: %s -> %s" link-id new-rel-id)
                  (puthash new-rel-id updated-props relations-ht))))))))
     old-links)

    ;; Return the new store
    store))

(defun supertag-migrate--build-indexes (store)
  "Build all performance indexes from the STORE."
  (unless (hash-table-p store)
    (error "Invalid store: expected hash table, got %s" (type-of store)))

  (let ((indexes (ht-create))
        (nodes-ht (gethash :nodes store)))

    ;; Validate nodes-ht
    (unless (hash-table-p nodes-ht)
      (error "Invalid nodes hash table: expected hash table, got %s" (type-of nodes-ht)))

    (puthash :tags (ht-create) indexes)
    (puthash :words (ht-create) indexes)
    (puthash :dates (ht-create) indexes)

    (let ((tag-idx (gethash :tags indexes))
          (word-idx (gethash :words indexes))
          (date-idx (gethash :dates indexes)))

      ;; Only proceed if nodes-ht is valid and not empty
      (when (and (hash-table-p nodes-ht) (> (hash-table-count nodes-ht) 0))
        (maphash
         (lambda (node-id node-data)
           ;; 1. Build tag index
           (let ((tags (plist-get node-data :tags)))
             (when tags
               (dolist (tag tags)
                 (when tag
                   (let ((nodes-list (gethash tag tag-idx '())))
                     (unless (member node-id nodes-list)
                       (puthash tag (cons node-id nodes-list) tag-idx)))))))

           ;; 2. Build word index from title and content
           (dolist (text (list (plist-get node-data :title)
                               (plist-get node-data :content)))
             (when (stringp text)
               (dolist (word (split-string (downcase text) "[^[:word:]]+" t))
                 (when (> (length word) 2)
                   (let ((nodes-list (gethash word word-idx '())))
                     (unless (member node-id nodes-list)
                       (puthash word (cons node-id nodes-list) word-idx)))))))

           ;; 3. Build date index
           (let ((created (plist-get node-data :created-at))
                 (modified (plist-get node-data :modified-at)))
             (when created
               (let ((date-map (gethash :created-at date-idx (ht-create))))
                 (puthash :created-at date-map date-idx)
                 (puthash node-id created date-map)))
             (when modified
               (let ((date-map (gethash :modified-at date-idx (ht-create))))
                 (puthash :modified-at date-map date-idx)
                 (puthash node-id modified date-map)))))
         nodes-ht)))
    indexes))

(defun supertag-migrate--save-new-db (store indexes)
  "Save the new STORE and INDEXES to the conventional file location."
  (let* ((default-dir (expand-file-name "supertag" user-emacs-directory))
         (new-db-file (expand-file-name "supertag-db.el" default-dir)))
    (make-directory default-dir t)
    (message "Saving new database to %s..." new-db-file)
    (with-temp-file new-db-file
      ;; Use the most robust method to ensure UTF-8 output, by controlling
      ;; the buffer-local coding system, the file-writing coding system,
      ;; and the printer's escaping behavior.
      (let ((buffer-file-coding-system 'utf-8-unix)
            (coding-system-for-write 'utf-8-unix)
            (coding-system-for-read 'utf-8-unix)
            (print-escape-nonascii nil)
            (print-escape-multibyte nil)
            (print-escape-control-characters nil)
            (print-quoted-char-oneline nil)
            (print-escape-newlines nil)
            (print-continuous-numbering nil)
            (print-gensym nil))
        (setq-local buffer-file-coding-system 'utf-8-unix)
        (setq-local coding-system-for-write 'utf-8-unix)
        (let ((print-level nil)
              (print-length nil)
              (print-circle nil)
              (print-escape-nonascii nil)
              (print-escape-multibyte nil)
              (print-escape-control-characters nil)
              (print-quoted-char-oneline nil)
              (print-escape-newlines nil)
              (print-continuous-numbering nil)
              (print-gensym nil))
          (insert ";;; supertag.db --- Data store for Supertag\n")
          (insert ";;; -*- coding: utf-8 -*-\n\n")
          ;; Output store data directly as hash table (compatible with supertag-store.el)
          (insert ";; supertag--store data\n")
          (prin1 (ht-deep-copy-table store) (current-buffer))
          (insert "\n\n")
          ;; Output index data directly as hash table
          (insert ";; supertag--store-indexes data\n")
          (prin1 (ht-deep-copy-table indexes) (current-buffer))
          (insert "\n"))))
    (message "Data migration successfully completed!")
    (message "New database file is at: %s" new-db-file)))

;; ------------------------------------------------------------------
;; Global field model migration (modern store -> global fields)
;; ------------------------------------------------------------------

(defcustom supertag-migration-log-buffer "*supertag-migration*"
  "Buffer name for migration logs."
  :type 'string
  :group 'supertag-migration)

(defcustom supertag-migration-dry-run t
  "When non-nil, migration commands default to dry-run (no writes)."
  :type 'boolean
  :group 'supertag-migration)

(defvar supertag-migration--stats nil
  "Plist of migration stats for the current run.")

(defun supertag-migration--log (fmt &rest args)
  "Log formatted message to `supertag-migration-log-buffer'."
  (with-current-buffer (get-buffer-create supertag-migration-log-buffer)
    (goto-char (point-max))
    (insert (apply #'format (concat fmt "\n") args))))

(defun supertag-migration--reset-stats ()
  "Reset migration stats."
  (setq supertag-migration--stats
        '(:fields-created 0
          :associations-created 0
          :values-migrated 0
          :conflicts nil
          :skipped 0))
  (supertag-migration--log "Stats reset: %S" supertag-migration--stats))

(defun supertag-migration--increment (key &optional delta)
  "Increment KEY in stats by DELTA (default 1)."
  (let* ((delta (or delta 1))
         (current (plist-get supertag-migration--stats key)))
    (setq supertag-migration--stats
          (plist-put supertag-migration--stats key (+ (or current 0) delta)))))

(defun supertag-migration--record-conflict (item)
  "Record conflict ITEM in stats."
  (let* ((entry (if (and item (listp item))
                    item
                  (list :reason :unspecified :raw item)))
         (existing (plist-get supertag-migration--stats :conflicts))
         (updated (cons entry existing)))
    (setq supertag-migration--stats
          (plist-put supertag-migration--stats :conflicts updated))
    (supertag-migration--log "Conflict recorded entry=%S updated=%S" entry updated)))

(defun supertag-migration--dry-run-p (&optional force)
  "Return t when dry-run is active, unless FORCE is non-nil."
  (and (not force)
       (or supertag-migration-dry-run
           (bound-and-true-p current-prefix-arg))))




(defconst supertag-migration--invalid-association
  (list :supertag-invalid-association)
  "Sentinel returned for a malformed global field association.")

(defun supertag-migration--stable-value (value)
  "Return deterministic representation of VALUE for audit output."
  (supertag--persistence--canonicalize-value value))

(defun supertag-migration--stable-equal-p (left right)
  "Return non-nil when LEFT and RIGHT have equal canonical contents."
  (equal (supertag-migration--stable-value left)
         (supertag-migration--stable-value right)))

(defun supertag-migration--audit-definition-plist (definition)
  "Return DEFINITION as a plist, or nil when it has no valid mapping shape."
  (cond
   ((hash-table-p definition)
    (let (result)
      (maphash (lambda (key value)
                 (setq result (plist-put result key value)))
               definition)
      result))
   ((and (listp definition)
         (proper-list-p definition)
         (zerop (% (length definition) 2))
         (cl-loop for (key _) on definition by #'cddr
                  always (keywordp key)))
    definition)))


(defun supertag-migration--report-sort-key (value)
  "Return a stable printed sort key for VALUE."
  (let ((print-circle t)
        (print-escape-nonascii t)
        (print-length nil)
        (print-level nil))
    (prin1-to-string (supertag-migration--stable-value value))))

(defun supertag-migration--sort-report-items (items)
  "Return ITEMS sorted by deterministic printed representation."
  (sort items
        (lambda (left right)
          (string< (supertag-migration--report-sort-key left)
                   (supertag-migration--report-sort-key right)))))

(defun supertag-migration--sorted-table-entries (data)
  "Return DATA's key/value entries in deterministic key order.
Legacy alist and flat key/value shapes are accepted without changing DATA."
  (let ((table (if (hash-table-p data)
                   data
                 (supertag--legacy-field-coerce-table data)))
        result)
    (maphash (lambda (key value) (push (cons key value) result)) table)
    (sort result
          (lambda (left right)
            (string< (supertag-migration--report-sort-key (car left))
                     (supertag-migration--report-sort-key (car right)))))))

(defun supertag-migration--fingerprint (value)
  "Return a deterministic SHA-256 fingerprint for VALUE."
  (secure-hash 'sha256 (supertag-migration--report-sort-key value)))

(defun supertag-migration--file-sha256 (file)
  "Return FILE's SHA-256 digest, or nil when FILE does not exist."
  (when (and (stringp file) (file-regular-p file))
    (with-temp-buffer
      (insert-file-contents-literally file)
      (secure-hash 'sha256 (current-buffer)))))


;;;###autoload


;;; --- Stable Semantic Tag ID audit ---

(defconst supertag-migration--stable-tag-collections
  '(:tags :nodes :relations :link-definitions :fields :field-definitions
    :tag-field-associations :field-values :boards :automations)
  "Collections whose Tag references task017 must migrate atomically.")

(defun supertag-migration--stable-tag-id-p (value)
  "Return non-nil when VALUE has the stable Semantic Tag ID shape."
  (and (stringp value)
       (string-match-p "\\`tag-[0-9a-f]\\{32\\}\\'" value)))

(defun supertag-migration--proposed-stable-tag-id (old-id)
  "Return the deterministic stable Semantic Tag ID proposed for OLD-ID."
  (if (supertag-migration--stable-tag-id-p old-id)
      old-id
    (concat
     "tag-"
     (substring
      (secure-hash 'sha256
                   (encode-coding-string
                    (concat "org-supertag:semantic-tag:v1:" old-id)
                    'utf-8 t))
      0 32))))

(defun supertag-migration--legacy-tag-display-path (tag-id)
  "Return TAG-ID's pre-task017 ID-based display path."
  (let ((current tag-id)
        (seen (make-hash-table :test 'equal))
        parts cycle)
    (while (and current (not cycle))
      (if (gethash current seen)
          (setq cycle t)
        (puthash current t seen)
        (let* ((tag (supertag--ensure-plist (supertag-tag-get current)))
               (parent (plist-get tag :extends)))
          (push (if parent (supertag-tag-path-leaf current) current) parts)
          (setq current parent))))
    (if cycle tag-id (string-join parts "/"))))

(defun supertag-migration--mapping-value (value mapping)
  "Return VALUE rewritten by old-to-stable MAPPING when present."
  (or (cdr (assoc value mapping)) value))

(defun supertag-migration--string-leaves (value)
  "Return every string leaf in VALUE in deterministic order."
  (let (result)
    (cl-labels
        ((walk (item)
           (cond
            ((stringp item) (push item result))
            ((hash-table-p item)
             (dolist (entry (supertag-migration--sorted-table-entries item))
               (walk (cdr entry))))
            ((consp item)
             (walk (car item))
             (walk (cdr item))))))
      (walk value))
    (sort (delete-dups result) #'string<)))

(defun supertag-migration--rewrite-tag-structured (form mapping)
  "Rewrite exact Tag IDs in structured FORM using MAPPING.
This includes the existing tag slots and query objects shaped as
`(:type :tag :value TAG-ID)'."
  (let ((rewritten
         (supertag-tag-path-rename--rewrite-structured form mapping)))
    (cl-labels
        ((walk (item)
           (cond
            ((atom item) item)
            ((supertag-tag-merge--plist-p item)
             (let ((tag-query-p (eq (plist-get item :type) :tag)) result)
               (while item
                 (let ((key (pop item)) (value (pop item)))
                   (setq result
                         (append result
                                 (list key
                                       (if (and tag-query-p (eq key :value))
                                           (supertag-tag-path-rename--rewrite-values
                                            value mapping)
                                         (walk value)))))))
               result))
            (t (mapcar #'walk item)))))
      (walk rewritten))))

(defun supertag-migration--audit-saved-tag-queries (mapping)
  "Return (REFERENCE-MAPPINGS . CONFLICTS) for saved queries and MAPPING."
  (let ((source-ids (mapcar #'car mapping)) references conflicts)
    (dolist (entry supertag-query-saved)
      (let ((name (car entry)) (text (cdr entry)))
        (when (and (stringp text)
                   (supertag-tag-merge--string-mentions-source-p
                    text source-ids))
          (condition-case err
              (pcase-let* ((`(,form . ,end) (read-from-string text))
                           (tail (substring text end))
                           (rewritten
                            (supertag-migration--rewrite-tag-structured
                             form mapping)))
                (if (string-match-p "\\`[[:space:]]*\\'" tail)
                    (unless (equal form rewritten)
                      (push (list :kind :saved-query :owner-id name
                                  :old-value text
                                  :stable-value (prin1-to-string rewritten))
                            references))
                  (push (list :reason :saved-query-unmappable :owner-id name
                              :value text)
                        conflicts)))
            (error
             (push (list :reason :saved-query-unmappable :owner-id name
                         :value text :error (error-message-string err))
                   conflicts))))))
    (cons references conflicts)))

(defun supertag-migration--audit-stable-tag-identities ()
  "Return proposed identities, alias reverse map, and identity conflicts."
  (let ((alias-claims (make-hash-table :test 'equal))
        (stable-claims (make-hash-table :test 'equal))
        mappings conflicts)
    (dolist (entry
             (supertag-migration--sorted-table-entries
              (supertag-store-get-collection :tags)))
      (let* ((old-id (car entry))
             (tag (supertag-migration--audit-definition-plist (cdr entry)))
             (stored-id (and tag (plist-get tag :id)))
             (name (and tag (plist-get tag :name)))
             (raw-aliases (and tag (plist-get tag :aliases)))
             (stable-id (and (stringp old-id)
                             (supertag-migration--proposed-stable-tag-id old-id)))
             aliases)
        (unless (and tag (stringp old-id) (stringp name)
                     (not (string-empty-p name)))
          (push (list :reason :invalid-tag :old-id old-id
                      :value (supertag-migration--stable-value (cdr entry)))
                conflicts))
        (when (and tag (not (equal old-id stored-id)))
          (push (list :reason :tag-key-id-mismatch :old-id old-id
                      :stored-id stored-id)
                conflicts))
        (when (and raw-aliases
                   (not (and (proper-list-p raw-aliases)
                             (cl-every #'stringp raw-aliases))))
          (push (list :reason :invalid-aliases :old-id old-id
                      :aliases (supertag-migration--stable-value raw-aliases))
                conflicts))
        (when (and tag (stringp old-id) (stringp name) stable-id)
          (dolist (candidate
                   (append (list old-id name
                                 (supertag-migration--legacy-tag-display-path old-id)
                                 (supertag-tag-display-path old-id))
                           (and (proper-list-p raw-aliases) raw-aliases)))
            (when (stringp candidate)
              (condition-case err
                  (push (supertag-sanitize-tag-name candidate) aliases)
                (error
                 (push (list :reason :invalid-alias :old-id old-id
                             :alias candidate
                             :error (error-message-string err))
                       conflicts)))))
          (setq aliases (sort (delete-dups aliases) #'string<))
          (puthash stable-id
                   (cons old-id (gethash stable-id stable-claims))
                   stable-claims)
          (dolist (alias aliases)
            (puthash alias (cons old-id (gethash alias alias-claims))
                     alias-claims))
          (push (list :old-id old-id :stable-id stable-id
                      :canonical-name name :aliases aliases
                      :legacy-field-count
                      (if (proper-list-p (plist-get tag :fields))
                          (length (plist-get tag :fields)) 0))
                mappings))))
    (dolist (entry (supertag-migration--sorted-table-entries alias-claims))
      (let ((owners (sort (delete-dups (copy-sequence (cdr entry))) #'string<)))
        (when (> (length owners) 1)
          (push (list :reason :alias-conflict :alias (car entry)
                      :old-tag-ids owners)
                conflicts))))
    (dolist (entry (supertag-migration--sorted-table-entries stable-claims))
      (let ((owners (sort (delete-dups (copy-sequence (cdr entry))) #'string<)))
        (when (> (length owners) 1)
          (push (list :reason :stable-id-conflict :stable-id (car entry)
                      :old-tag-ids owners)
                conflicts))))
    (setq mappings (supertag-migration--sort-report-items mappings))
    (list :tag-mappings mappings
          :reverse-mappings
          (supertag-migration--sort-report-items
           (mapcar (lambda (item)
                     (list :stable-id (plist-get item :stable-id)
                           :old-id (plist-get item :old-id)))
                   mappings))
          :alias-mappings
          (supertag-migration--sort-report-items
           (apply #'append
                  (mapcar
                   (lambda (item)
                     (mapcar
                      (lambda (alias)
                        (list :alias alias
                              :old-id (plist-get item :old-id)
                              :stable-id (plist-get item :stable-id)))
                      (plist-get item :aliases)))
                   mappings)))
          :alias-claims alias-claims
          :conflicts (supertag-migration--sort-report-items conflicts))))

(defun supertag-migration--audit-stable-tag-inheritance (mapping)
  "Return inheritance mappings and conflicts for old-to-stable MAPPING."
  (let ((tags (supertag-store-get-collection :tags))
        (cycle-keys (make-hash-table :test 'equal))
        edges conflicts)
    (dolist (entry (supertag-migration--sorted-table-entries tags))
      (let* ((child (car entry))
             (tag (supertag-migration--audit-definition-plist (cdr entry)))
             (parent (and tag (plist-get tag :extends))))
        (when parent
          (if (and (stringp parent) (assoc parent mapping))
              (push (list :old-child-id child
                          :stable-child-id
                          (supertag-migration--mapping-value child mapping)
                          :old-parent-id parent
                          :stable-parent-id
                          (supertag-migration--mapping-value parent mapping))
                    edges)
            (push (list :reason :missing-parent :old-tag-id child
                        :parent-id parent)
                  conflicts)))))
    (dolist (entry (supertag-migration--sorted-table-entries tags))
      (let ((current (car entry)) path done)
        (while (and (stringp current) (not done))
          (if-let* ((position (cl-position current path :test #'equal)))
              (let* ((cycle (sort (copy-sequence
                                   (cl-subseq path 0 (1+ position)))
                                  #'string<))
                     (key (string-join cycle "\0")))
                (unless (gethash key cycle-keys)
                  (puthash key t cycle-keys)
                  (push (list :reason :inheritance-cycle
                              :old-tag-ids cycle)
                        conflicts))
                (setq done t))
            (push current path)
            (let* ((tag (gethash current tags))
                   (parent (and (listp tag) (plist-get tag :extends))))
              (if (and parent (gethash parent tags))
                  (setq current parent)
                (setq done t)))))))
    (list :inheritance-mappings
          (supertag-migration--sort-report-items edges)
          :conflicts (supertag-migration--sort-report-items conflicts))))

(defun supertag-migration--audit-stable-tag-references
    (mapping alias-claims)
  "Return every reference rewrite and unresolved owner for MAPPING.
ALIAS-CLAIMS maps occurrence tokens to their current Semantic Tag owners."
  (require 'supertag-ops-tag-merge)
  (let ((tags (supertag-store-get-collection :tags))
        references unresolved conflicts schema-mappings)
    (dolist (entry
             (supertag-migration--sorted-table-entries
              (supertag-store-get-collection :tag-field-associations)))
      (let ((old-id (car entry)))
        (if (assoc old-id mapping)
            (let ((item (list :kind :schema :old-tag-id old-id
                              :stable-tag-id
                              (supertag-migration--mapping-value old-id mapping)
                              :field-associations
                              (supertag-migration--stable-value (cdr entry)))))
              (push item schema-mappings)
              (push item references))
          (push (list :reason :schema-missing-tag :old-tag-id old-id)
                conflicts))))
    (dolist (node-entry
             (supertag-migration--sorted-table-entries
              (supertag-store-get-collection :fields)))
      (dolist (tag-entry
               (supertag-migration--sorted-table-entries (cdr node-entry)))
        (let ((old-id (car tag-entry)))
          (if (assoc old-id mapping)
              (push (list :kind :legacy-field-bucket
                          :owner-id (car node-entry) :old-id old-id
                          :stable-id
                          (supertag-migration--mapping-value old-id mapping)
                          :value-sha256
                          (supertag-migration--fingerprint (cdr tag-entry)))
                    references)
            (push (list :reason :legacy-field-bucket-missing-tag
                        :node-id (car node-entry) :old-tag-id old-id)
                  conflicts)))))
    (dolist (tag-entry
             (supertag-migration--sorted-table-entries tags))
      (let ((fields (plist-get
                     (supertag-migration--audit-definition-plist
                      (cdr tag-entry))
                     :fields)))
        (when (proper-list-p fields)
          (dolist (definition fields)
            (when (and (listp definition)
                       (eq (plist-get definition :type) :tag)
                       (plist-member definition :default))
              (let* ((value (plist-get definition :default))
                     (rewritten
                      (supertag-tag-path-rename--rewrite-values value mapping)))
                (dolist (old-id (supertag-migration--string-leaves value))
                  (unless (assoc old-id mapping)
                    (push (list :reason :legacy-tag-field-default-missing-tag
                                :old-tag-id (car tag-entry)
                                :field-name (plist-get definition :name)
                                :missing-tag-id old-id)
                          conflicts)))
                (unless (equal value rewritten)
                  (push (list :kind :legacy-tag-field-default
                              :owner-id (car tag-entry)
                              :field-name (plist-get definition :name)
                              :old-value
                              (supertag-migration--stable-value value)
                              :stable-value
                              (supertag-migration--stable-value rewritten))
                        references))))))))
    (dolist (entry
             (supertag-migration--sorted-table-entries
              (supertag-store-get-collection :nodes)))
      (let* ((node-id (car entry))
             (node (supertag-migration--audit-definition-plist (cdr entry)))
             (raw-tags (and node (plist-get node :tags)))
             (raw-occurrences (and node (plist-get node :tag-occurrences)))
             (raw-unresolved (and node (plist-get node :unresolved-tags))))
        (dolist (slot-value `((:tags . ,raw-tags)
                              (:tag-occurrences . ,raw-occurrences)
                              (:unresolved-tags . ,raw-unresolved)))
          (when (and (cdr slot-value)
                     (not (and (proper-list-p (cdr slot-value))
                               (cl-every #'stringp (cdr slot-value)))))
            (push (list :reason :invalid-node-tag-list :node-id node-id
                        :slot (car slot-value)
                        :value (supertag-migration--stable-value
                                (cdr slot-value)))
                  conflicts)))
        (dolist (old-id (and (proper-list-p raw-tags)
                             (cl-remove-if-not #'stringp raw-tags)))
          (if (assoc old-id mapping)
              (push (list :kind :node-membership :owner-id node-id
                          :old-id old-id :stable-id
                          (supertag-migration--mapping-value old-id mapping))
                    references)
            (push (list :reason :membership-missing-tag :node-id node-id
                        :old-tag-id old-id)
                  conflicts)))
        (dolist (token
                 (sort
                  (delete-dups
                   (append
                    (and (proper-list-p raw-occurrences)
                         (cl-remove-if-not #'stringp raw-occurrences))
                    (and (proper-list-p raw-unresolved)
                         (cl-remove-if-not #'stringp raw-unresolved))))
                  #'string<))
          (let* ((normalized
                  (condition-case nil
                      (supertag-sanitize-tag-name token)
                    (error nil)))
                 (owners (and normalized
                              (sort (delete-dups
                                     (copy-sequence
                                      (gethash normalized alias-claims)))
                                    #'string<))))
            (if (= (length owners) 1)
                (let ((old-id (car owners)))
                  (push (list :kind :tag-occurrence :owner-id node-id
                              :token token :old-id old-id :stable-id
                              (supertag-migration--mapping-value old-id mapping))
                        references))
              (push (list :node-id node-id :token token
                          :reason (if owners :ambiguous-alias
                                    :unknown-alias)
                          :old-tag-ids owners)
                    unresolved))))))
    (dolist (entry
             (supertag-migration--sorted-table-entries
              (supertag-store-get-collection :relations)))
      (let* ((id (car entry))
             (relation (supertag-migration--audit-definition-plist (cdr entry)))
             (from (and relation (plist-get relation :from)))
             (to (and relation (plist-get relation :to)))
             (new-from (supertag-migration--mapping-value from mapping))
             (new-to (supertag-migration--mapping-value to mapping)))
        (when (or (not (equal from new-from)) (not (equal to new-to)))
          (push (list :kind :relation :owner-id id
                      :old-from from :stable-from new-from
                      :old-to to :stable-to new-to
                      :stable-owner-id
                      (supertag-generate-relation-id
                       new-from new-to (plist-get relation :type)
                       (plist-get relation :kind)
                       (plist-get relation :field-id)
                       (plist-get relation :link-definition-id)))
                references))
        (when (and relation
                   (or (eq (plist-get relation :type) :node-tag)
                       (eq (plist-get relation :kind) :tag-membership))
                   (not (gethash to tags)))
          (push (list :reason :membership-relation-missing-tag
                      :relation-id id :old-tag-id to)
                conflicts))))
    (dolist (entry
             (supertag-migration--sorted-table-entries
              (supertag-store-get-collection :link-definitions)))
      (let* ((id (car entry))
             (definition
              (supertag-migration--audit-definition-plist (cdr entry)))
             (from (and definition (plist-get definition :from-tag-id)))
             (to (and definition (plist-get definition :to-tag-id)))
             (new-from (and (stringp from)
                            (supertag-migration--mapping-value from mapping)))
             (new-to (and (stringp to)
                          (supertag-migration--mapping-value to mapping))))
        (unless (and definition (stringp from) (assoc from mapping))
          (push (list :reason :link-definition-missing-source-tag
                      :link-definition-id id :old-tag-id from)
                conflicts))
        (unless (and definition (stringp to) (assoc to mapping))
          (push (list :reason :link-definition-missing-target-tag
                      :link-definition-id id :old-tag-id to)
                conflicts))
        (when (and definition
                   (or (not (equal from new-from))
                       (not (equal to new-to))))
          (push (list :kind :link-definition-endpoints
                      :owner-id id
                      :old-from-tag-id from
                      :stable-from-tag-id new-from
                      :old-to-tag-id to
                      :stable-to-tag-id new-to)
                references))))
    (dolist (node-entry
             (supertag-migration--sorted-table-entries
              (supertag-store-get-collection :field-values)))
      (when (hash-table-p (cdr node-entry))
        (dolist (field-entry
                 (supertag-migration--sorted-table-entries (cdr node-entry)))
          (when (eq (plist-get
                     (supertag-store-get-field-definition (car field-entry)) :type)
                    :tag)
            (let* ((value (cdr field-entry))
                   (rewritten
                    (supertag-tag-path-rename--rewrite-values value mapping)))
              (dolist (old-id (supertag-migration--string-leaves value))
                (unless (assoc old-id mapping)
                  (push (list :reason :tag-field-missing-tag
                              :node-id (car node-entry)
                              :field-id (car field-entry)
                              :old-tag-id old-id)
                        conflicts)))
              (unless (equal value rewritten)
                (push (list :kind :tag-field-value
                            :owner-id (car node-entry)
                            :field-id (car field-entry)
                            :old-value (supertag-migration--stable-value value)
                            :stable-value
                            (supertag-migration--stable-value rewritten))
                      references)))))))
    (dolist (entry
             (supertag-migration--sorted-table-entries
              (supertag-store-get-collection :field-definitions)))
      (let ((definition
             (supertag-migration--audit-definition-plist (cdr entry))))
        (when (and (eq (plist-get definition :type) :tag)
                   (plist-member definition :default))
          (let* ((value (plist-get definition :default))
                 (rewritten
                  (supertag-tag-path-rename--rewrite-values value mapping)))
            (dolist (old-id (supertag-migration--string-leaves value))
              (unless (assoc old-id mapping)
                (push (list :reason :tag-field-default-missing-tag
                            :field-id (car entry) :old-tag-id old-id)
                      conflicts)))
            (unless (equal value rewritten)
              (push (list :kind :tag-field-default :owner-id (car entry)
                          :old-value (supertag-migration--stable-value value)
                          :stable-value
                          (supertag-migration--stable-value rewritten))
                    references))))))
    (dolist (collection-kind '((:automations . :automation) (:boards . :board)))
      (dolist (entry
               (supertag-migration--sorted-table-entries
                (supertag-store-get-collection (car collection-kind))))
        (let ((rewritten
               (supertag-migration--rewrite-tag-structured
                (copy-tree (cdr entry)) mapping)))
          (unless (equal (cdr entry) rewritten)
            (push (list :kind (cdr collection-kind) :owner-id (car entry)
                        :old-value (supertag-migration--stable-value (cdr entry))
                        :stable-value
                        (supertag-migration--stable-value rewritten))
                  references)))))
    (pcase-let ((`(,query-references . ,query-conflicts)
                 (supertag-migration--audit-saved-tag-queries mapping)))
      (setq references (append query-references references))
      (dolist (conflict query-conflicts)
        (push conflict conflicts)))
    (when (hash-table-p supertag--view-configs)
      (dolist (entry
               (supertag-migration--sorted-table-entries supertag--view-configs))
        (let ((rewritten
               (supertag-migration--rewrite-tag-structured
                (copy-tree (cdr entry)) mapping)))
          (unless (equal (cdr entry) rewritten)
            (push (list :kind :view :owner-id (car entry)
                        :old-value (supertag-migration--stable-value (cdr entry))
                        :stable-value
                        (supertag-migration--stable-value rewritten))
                  references)))))
    (list :schema-mappings
          (supertag-migration--sort-report-items schema-mappings)
          :reference-mappings
          (supertag-migration--sort-report-items references)
          :unresolved-occurrences
          (supertag-migration--sort-report-items unresolved)
          :conflicts (supertag-migration--sort-report-items conflicts))))

(defun supertag-migration--stable-tag-backup-report ()
  "Return a read-only backup plan for Stable Semantic Tag migration."
  (let ((report (let (counts)
    (dolist (collection supertag--store-collections)
      (let ((bucket (supertag-store-get-collection collection)))
        (push (cons collection
                    (if (hash-table-p bucket) (hash-table-count bucket) 0))
              counts)))
    (list :scope :full-database
          :database-file (and (boundp 'supertag-db-file)
                              (stringp supertag-db-file)
                              (expand-file-name supertag-db-file))
          :database-file-exists
          (and (boundp 'supertag-db-file) (stringp supertag-db-file)
               (file-regular-p supertag-db-file))
          :database-file-sha256
          (and (boundp 'supertag-db-file) (stringp supertag-db-file)
               (supertag-migration--file-sha256 supertag-db-file))
          :store-dirty (and (boundp 'supertag-db--dirty) supertag-db--dirty t)
          :required-before-apply t
          :collections supertag--store-collections
          :migration-collections
          supertag-migration--stable-tag-collections
          :collection-counts (nreverse counts)
          :store-sha256 (supertag-migration--fingerprint supertag--store)))))
    (setq report
          (plist-put report :migration-collections
                     supertag-migration--stable-tag-collections))
    (setq report
          (plist-put
           report :loaded-configs
           (list :saved-query-count (length supertag-query-saved)
                 :saved-query-sha256
                 (supertag-migration--fingerprint supertag-query-saved)
                 :view-count
                 (if (hash-table-p supertag--view-configs)
                     (hash-table-count supertag--view-configs) 0)
                 :view-sha256
                 (and (hash-table-p supertag--view-configs)
                      (supertag-migration--fingerprint
                       supertag--view-configs))
                 :strategy :serialize-exact-loaded-values
                 :backup-required t)))
    report))

(defun supertag-migration--build-stable-tag-audit ()
  "Build the deterministic, read-only Stable Semantic Tag migration report."
  (let* ((identity (supertag-migration--audit-stable-tag-identities))
         (mappings (plist-get identity :tag-mappings))
         (mapping (mapcar (lambda (item)
                            (cons (plist-get item :old-id)
                                  (plist-get item :stable-id)))
                          mappings))
         (inheritance
          (supertag-migration--audit-stable-tag-inheritance mapping))
         (references
          (supertag-migration--audit-stable-tag-references
           mapping (plist-get identity :alias-claims)))
         (conflicts
          (supertag-migration--sort-report-items
           (append (plist-get identity :conflicts)
                   (plist-get inheritance :conflicts)
                   (plist-get references :conflicts))))
         (unresolved (plist-get references :unresolved-occurrences)))
    (list :safe-to-apply (and (null conflicts) (null unresolved))
          :tag-mappings mappings
          :reverse-mappings (plist-get identity :reverse-mappings)
          :alias-mappings (plist-get identity :alias-mappings)
          :inheritance-mappings
          (plist-get inheritance :inheritance-mappings)
          :schema-mappings (plist-get references :schema-mappings)
          :reference-mappings (plist-get references :reference-mappings)
          :unresolved-occurrences unresolved
          :conflicts conflicts
          :coverage
          (list :tags (length mappings)
                :aliases (length (plist-get identity :alias-mappings))
                :inheritance
                (length (plist-get inheritance :inheritance-mappings))
                :schema (length (plist-get references :schema-mappings))
                :references (length (plist-get references :reference-mappings))
                :unresolved (length unresolved)
                :blocked (+ (length conflicts) (length unresolved)))
          :backup (supertag-migration--stable-tag-backup-report))))

(defun supertag-migration--stable-tag-mapping (audit)
  "Return AUDIT's old-to-stable alist."
  (mapcar (lambda (item)
            (cons (plist-get item :old-id) (plist-get item :stable-id)))
          (plist-get audit :tag-mappings)))

(defun supertag-migration--unique-backup-path (stem suffix)
  "Return an unused backup path using STEM and SUFFIX."
  (let ((path (expand-file-name (concat stem suffix)
                                supertag-db-backup-directory)))
    (if (file-exists-p path)
        (make-temp-file
         (expand-file-name (concat stem "-") supertag-db-backup-directory)
         nil suffix)
      path)))

(defun supertag-migration--write-config-backup (file queries views)
  "Atomically write QUERIES and VIEWS to FILE."
  (let ((temp (make-temp-file (concat file ".tmp")))
        success)
    (unwind-protect
        (progn
          (with-temp-buffer
            (let ((print-circle t)
                  (print-length nil)
                  (print-level nil)
                  (print-escape-nonascii t))
              (prin1 (list :saved-queries queries :loaded-views views)
                     (current-buffer)))
            (insert "\n")
            (let ((write-region-inhibit-fsync nil))
              (write-region (point-min) (point-max) temp nil 'silent)))
          (rename-file temp file t)
          (setq success t))
      (unless success (ignore-errors (delete-file temp))))))

(defun supertag-migration--backup-stable-tag-cutover ()
  "Create full Store, on-disk database, and loaded-config backups."
  (make-directory supertag-db-backup-directory t)
  (let* ((stamp (format-time-string "%Y%m%d-%H%M%S"))
         (stem (format "supertag-prestable-tags-%s" stamp))
         (store (supertag-migration--unique-backup-path stem ".el"))
         (database
          (and (stringp supertag-db-file) (file-exists-p supertag-db-file)
               (supertag-migration--unique-backup-path
                (concat stem "-database") ".el")))
         (configs
          (supertag-migration--unique-backup-path
           (concat stem "-configs") ".el"))
         (views (and (hash-table-p supertag--view-configs)
                     (supertag-tag-merge--copy-view-configs))))
    (supertag--persistence-write-store-atomically store)
    (when database (copy-file supertag-db-file database t t))
    (supertag-migration--write-config-backup
     configs (copy-tree supertag-query-saved) views)
    (list :store store :database database :configs configs)))

(defun supertag-migration--stable-tag-definitions (audit mapping)
  "Return rekeyed Tag definitions described by AUDIT and MAPPING."
  (let ((result (make-hash-table :test 'equal)))
    (dolist (item (plist-get audit :tag-mappings) result)
      (let* ((old-id (plist-get item :old-id))
             (stable-id (plist-get item :stable-id))
             (tag (copy-tree (supertag--ensure-plist
                              (supertag-tag-get old-id))))
             (extends (plist-get tag :extends))
             (fields (plist-get tag :fields)))
        (setq tag (plist-put tag :id stable-id))
        (setq tag (plist-put tag :aliases (plist-get item :aliases)))
        (when extends
          (setq tag (plist-put tag :extends
                               (supertag-migration--mapping-value
                                extends mapping))))
        (when (proper-list-p fields)
          (setq tag
                (plist-put
                 tag :fields
                 (mapcar
                  (lambda (definition)
                    (let ((copy (copy-tree definition)))
                      (if (and (listp copy)
                               (eq (plist-get copy :type) :tag)
                               (plist-member copy :default))
                          (plist-put
                           copy :default
                           (supertag-tag-path-rename--rewrite-values
                            (plist-get copy :default) mapping))
                        copy)))
                  fields))))
        (when (gethash stable-id result)
          (error "Stable Tag migration produced duplicate ID '%s'" stable-id))
        (puthash stable-id tag result)))))

(defun supertag-migration--rekey-table (table mapping)
  "Return TABLE copied with keys rewritten by MAPPING."
  (let ((result (make-hash-table :test (hash-table-test table))))
    (maphash
     (lambda (key value)
       (let ((new-key (supertag-migration--mapping-value key mapping)))
         (when (gethash new-key result)
           (error "Stable Tag migration produced duplicate owner '%s'" new-key))
         (puthash new-key (copy-tree value) result)))
     table)
    result))

(defun supertag-migration--rewrite-stable-tag-nodes (mapping)
  "Rewrite derived node membership using MAPPING; keep occurrence tokens."
  (let ((result (make-hash-table :test 'equal)))
    (maphash
     (lambda (node-id raw-node)
       (let* ((node (copy-tree (supertag--ensure-plist raw-node)))
              (occurrences (plist-get node :tag-occurrences))
              (resolved
               (if (proper-list-p occurrences)
                   (delq nil (mapcar #'supertag-tag-resolve-occurrence occurrences))
                 (mapcar (lambda (id)
                           (supertag-migration--mapping-value id mapping))
                         (or (plist-get node :tags) '()))))
              (unresolved
               (and (proper-list-p occurrences)
                    (cl-remove-if #'supertag-tag-resolve-occurrence occurrences))))
         (setq node (plist-put node :tags (delete-dups resolved)))
         (setq node (plist-put node :unresolved-tags unresolved))
         (puthash node-id node result)))
     (supertag-store-get-collection :nodes))
    (supertag-update '(:nodes) result)))

(defun supertag-migration--rewrite-stable-tag-relations (mapping)
  "Rewrite relation endpoints and deterministic IDs using MAPPING."
  (let ((result (make-hash-table :test 'equal)))
    (maphash
     (lambda (_id raw-relation)
       (let* ((relation
               (supertag-migration--rewrite-tag-structured
                (copy-tree raw-relation) mapping))
              (from (supertag-migration--mapping-value
                     (plist-get relation :from) mapping))
              (to (supertag-migration--mapping-value
                   (plist-get relation :to) mapping))
              (id (supertag-generate-relation-id
                   from to (plist-get relation :type)
                   (plist-get relation :kind)
                   (plist-get relation :field-id)
                   (plist-get relation :link-definition-id))))
         (setq relation (plist-put relation :id id))
         (setq relation (plist-put relation :from from))
         (setq relation (plist-put relation :to to))
         (when (gethash id result)
           (error "Stable Tag migration produced duplicate relation '%s'" id))
         (puthash id relation result)))
     (supertag-store-get-collection :relations))
    (supertag-update '(:relations) result)))

(defun supertag-migration--rewrite-stable-tag-link-definitions (mapping)
  "Rewrite Link Definition endpoint Tag IDs using MAPPING."
  (let ((result (make-hash-table :test 'equal)))
    (maphash
     (lambda (id raw-definition)
       (let* ((definition (copy-tree raw-definition))
              (from (plist-get definition :from-tag-id))
              (to (plist-get definition :to-tag-id)))
         (unless (and (stringp from) (assoc from mapping))
           (error "Link Definition '%s' references unmapped source Tag '%S'"
                  id from))
         (unless (and (stringp to) (assoc to mapping))
           (error "Link Definition '%s' references unmapped target Tag '%S'"
                  id to))
         (setq definition
               (plist-put definition :from-tag-id
                          (supertag-migration--mapping-value from mapping)))
         (setq definition
               (plist-put definition :to-tag-id
                          (supertag-migration--mapping-value to mapping)))
         (puthash id definition result)))
     (supertag-store-get-collection :link-definitions))
    (supertag-update '(:link-definitions) result)))

(defun supertag-migration--rewrite-stable-tag-legacy-fields (mapping)
  "Rekey migration-only legacy field buckets using MAPPING."
  (let ((result (make-hash-table :test 'equal)))
    (maphash
     (lambda (node-id tag-table)
       (puthash node-id
                (if (hash-table-p tag-table)
                    (supertag-migration--rekey-table tag-table mapping)
                  tag-table)
                result))
     (supertag-store-get-collection :fields))
    (supertag-update '(:fields) result)))

(defun supertag-migration--rewrite-stable-tag-definitions (mapping)
  "Rewrite Tag-typed global field defaults using MAPPING."
  (let ((result (make-hash-table :test 'equal)))
    (maphash
     (lambda (id raw-definition)
       (let ((definition (copy-tree raw-definition)))
         (when (and (eq (plist-get definition :type) :tag)
                    (plist-member definition :default))
           (setq definition
                 (plist-put
                  definition :default
                  (supertag-tag-path-rename--rewrite-values
                   (plist-get definition :default) mapping))))
         (puthash id definition result)))
     (supertag-store-get-collection :field-definitions))
    (supertag-update '(:field-definitions) result)))

(defun supertag-migration--rewrite-stable-tag-values (mapping)
  "Rewrite Tag-typed global field values using MAPPING."
  (let ((result (copy-hash-table
                 (supertag-store-get-collection :field-values))))
    (maphash
     (lambda (node-id field-table)
       (when (hash-table-p field-table)
         (let ((copy (copy-hash-table field-table)))
           (maphash
            (lambda (field-id value)
              (when (eq (plist-get
                         (supertag-store-get-field-definition field-id) :type)
                        :tag)
                (puthash field-id
                         (supertag-tag-path-rename--rewrite-values value mapping)
                         copy)))
            field-table)
           (puthash node-id copy result))))
     (supertag-store-get-collection :field-values))
    (supertag-update '(:field-values) result)))

(defun supertag-migration--rewrite-stable-tag-configs (mapping)
  "Rewrite Store, saved-query, and loaded-view Tag references using MAPPING."
  (dolist (collection '(:boards :automations))
    (let ((result (make-hash-table :test 'equal)))
      (maphash
       (lambda (id value)
         (puthash id
                  (supertag-migration--rewrite-tag-structured
                   (copy-tree value) mapping)
                  result))
       (supertag-store-get-collection collection))
      (supertag-update (list collection) result)))
  (setq supertag-query-saved
        (mapcar
         (lambda (entry)
           (pcase-let* ((`(,form . ,end) (read-from-string (cdr entry)))
                        (tail (substring (cdr entry) end)))
             (unless (string-match-p "\\`[[:space:]]*\\'" tail)
               (error "Saved query '%s' changed after audit" (car entry)))
             (cons (car entry)
                   (prin1-to-string
                    (supertag-migration--rewrite-tag-structured form mapping)))))
         supertag-query-saved))
  (when (hash-table-p supertag--view-configs)
    (maphash
     (lambda (id config)
       (puthash id
                (supertag-migration--rewrite-tag-structured
                 (copy-tree config) mapping)
                supertag--view-configs))
     supertag--view-configs)))

(defun supertag-migration--tag-token-file-count (file old-token new-token)
  "Return OLD-TOKEN occurrences in FILE without writing it.
NEW-TOKEN is used only to exercise the exact production rewrite path."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((org-mode-hook nil)
          (org-inhibit-startup t))
      (org-mode)
      (supertag-view-helper-rename-tag-text-in-buffer
       old-token new-token))))

(defun supertag-migration-audit-tag-token-rewrite (old-token new-token)
  "Return a read-only plan for rewriting OLD-TOKEN to NEW-TOKEN in Org.
Both tokens must resolve uniquely to the same Stable Semantic Tag."
  (let* ((old (supertag-sanitize-tag-name old-token))
         (new (supertag-sanitize-tag-name new-token))
         (old-id (ignore-errors (supertag-tag-resolve-occurrence old)))
         (new-id (ignore-errors (supertag-tag-resolve-occurrence new)))
         (snapshot (supertag-sync--snapshot-build))
         (status (plist-get snapshot :status))
         files counts conflicts)
    (unless (eq status 'complete)
      (push (list :reason :incomplete-vault-snapshot
                  :status status :errors (plist-get snapshot :errors))
            conflicts))
    (unless old-id
      (push (list :reason :unresolved-old-token :token old) conflicts))
    (unless new-id
      (push (list :reason :unresolved-new-token :token new) conflicts))
    (when (and old-id new-id (not (equal old-id new-id)))
      (push (list :reason :different-tag-owners
                  :old-token old :old-id old-id
                  :new-token new :new-id new-id)
            conflicts))
    (when (equal old new)
      (push (list :reason :same-token :token old) conflicts))
    (when (eq status 'complete)
      (dolist (file (sort (copy-sequence (plist-get snapshot :files)) #'string<))
        (cond
         ((not (file-readable-p file))
          (push (list :reason :unreadable-file :file file) conflicts))
         ((and (get-file-buffer file)
               (buffer-modified-p (get-file-buffer file)))
          (push (list :reason :modified-buffer :file file) conflicts))
         (t
          (condition-case err
              (let ((count
                     (supertag-migration--tag-token-file-count file old new)))
                (when (> count 0)
                  (push file files)
                  (push (cons file count) counts)))
            (error
             (push (list :reason :scan-failed :file file
                         :error (error-message-string err))
                   conflicts)))))))
    (setq files (nreverse files)
          counts (nreverse counts)
          conflicts (nreverse conflicts))
    (list :safe-to-apply (null conflicts)
          :old-token old :new-token new :tag-id old-id
          :files files
          :file-occurrences counts
          :occurrences (apply #'+ (mapcar #'cdr counts))
          :conflicts conflicts)))

(defun supertag-migration--add-ids-to-file (file)
  "Add :ID: properties to headings in FILE that don't have one.
Returns a plist with (:ids-added N)."
  (let ((ids-added 0)
        (existing-buffer (find-buffer-visiting file))
        (buffer (condition-case nil
                   (find-file-noselect file t)
                 (error nil))))

    (unless buffer
      (error "Cannot open file: %s" file))

    (with-current-buffer buffer
      (save-excursion
        (org-mode)  ; Ensure org-mode is active
        (goto-char (point-min))

        ;; Visit each heading
        (while (re-search-forward org-heading-regexp nil t)
          (when (org-at-heading-p)
            (let ((existing-id (org-entry-get nil "ID")))
              (unless existing-id
                ;; No ID exists, add one
                (supertag-node-identity-ensure-at-point)
                (cl-incf ids-added))))))

      ;; Save the buffer if we modified it
      (when (> ids-added 0)
        (save-buffer))

      ;; Close buffer if we opened it
      (unless existing-buffer
        (kill-buffer buffer)))

    (list :ids-added ids-added)))

(provide 'supertag-migration)

;;; supertag-migration.el ends here
