;;; supertag-migrate.el --- Version gated legacy data migration -*- lexical-binding: t; -*-
;; Commands: supertag-migrate-run, supertag-migrate-status,
;;           supertag-migrate-preview, supertag-migrate-apply.
;; Dependencies: cl-lib, subr-x, org, supertag-core-persistence (snapshot reader/saved Store),
;; supertag-service-org (confirmed property writer), supertag-tag (Tag reads and
;; `:extends' resolution); supertag-core-store through these owners.
(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'supertag-core-persistence)
(require 'supertag-service-org)
(require 'supertag-tag)
(declare-function supertag-tag-stable-id-p "supertag-tag" (value))

(defconst supertag-migrate--field-roots
  '(:fields :field-definitions :tag-field-associations :field-values :field-provenance))
(defvar supertag-migrate--last-error nil "Last migration failure, for the status report.")
(defvar supertag-migrate--last-snapshot nil "Verified snapshot for the last migration.")

(defun supertag-migrate--bytes (file)
  "Read FILE literally, without running any Lisp."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun supertag-migrate--snapshot (version)
  "Copy and verify the current DB before any migration of VERSION."
  (unless (file-exists-p supertag-db-file)
    (user-error "Save the loaded database before migrating"))
  (let* ((bytes (supertag-migrate--bytes supertag-db-file))
         (prefix (format "supertag-db-premigrate-%s-"
                         (replace-regexp-in-string "[^A-Za-z0-9]+" "-" version)))
         (existing (and (file-directory-p supertag-db-backup-directory)
                        (directory-files supertag-db-backup-directory t
                                         (concat "\\`" (regexp-quote prefix) ".*\\.el\\'"))))
         (matching (cl-find-if (lambda (f) (equal bytes (supertag-migrate--bytes f))) existing)))
    (or matching
        (progn
          (make-directory supertag-db-backup-directory t)
          (let ((file (make-temp-file
                       (expand-file-name (concat prefix (format-time-string "%Y%m%d-%H%M%S-"))
                                         supertag-db-backup-directory) nil ".el")))
            (copy-file supertag-db-file file t)
            (unless (and (equal bytes (supertag-migrate--bytes file))
                         (equal bytes (supertag-migrate--bytes supertag-db-file)))
              (error "Migration snapshot byte verification failed: %s" file))
            file)))))

(defun supertag-migrate--pairs (data)
  "Decode legacy mapping DATA into pairs without discarding unknown input."
  (cond ((hash-table-p data)
         (let (pairs) (maphash (lambda (k v) (push (cons k v) pairs)) data) (nreverse pairs)))
        ((null data) nil)
        ((and (proper-list-p data) (cl-every #'consp data)) data)
        ((and (proper-list-p data) (zerop (% (length data) 2)))
         (let (pairs) (while data (push (cons (pop data) (pop data)) pairs)) (nreverse pairs)))
        (t (list (cons :unparsed data)))))

(defun supertag-migrate--field-entry (node name value source tag &optional definition provenance)
  "Preserve one legacy VALUE and its origin as a pending property entry."
  (let* ((name (or (plist-get definition :name) name))
         (type (or (plist-get definition :type) :undefined))
         (entry (list :node node :name (format "%s" (or name ""))
                      :source source :tag tag :raw value)))
    (when definition (setq entry (plist-put entry :definition definition)))
    (when provenance (setq entry (plist-put entry :provenance provenance)))
    ;; Unknown containers are retained as :raw, never made into an Org value.
    (unless (or (eq name :unparsed) (hash-table-p value)
                (and (vectorp value) (not (stringp value)))
                (and (consp value) (not (proper-list-p value))))
      (condition-case nil
          (setq entry (plist-put entry :value (supertag-migrate--display type value)))
        (error nil)))
    entry))

(defun supertag-migrate--extract-fields (store)
  "Extract all legacy field sources in STORE, then retire their old roots."
  (let ((definitions (supertag-migrate--pairs (gethash :field-definitions store)))
        (provenance (supertag-migrate--pairs (gethash :field-provenance store)))
        ;; Track provenance by its original owner and field key.  Provenance
        ;; values are metadata and are not unique identities: two fields may
        ;; legitimately carry identical metadata.
        (emitted-provenance (make-hash-table :test 'equal))
        (used (make-hash-table :test 'equal))
        (entries (copy-sequence (gethash :legacy-fields store))))
    (cl-labels
        ((emit (node fid value source tag &optional prov)
           (let ((definition (cdr (assoc fid definitions))))
             (when definition (puthash fid t used))
             (push (supertag-migrate--field-entry node fid value source tag definition prov) entries)))
         (values-for (node data source &optional prov)
         (dolist (field (supertag-migrate--pairs data))
             (puthash (cons node (car field)) t emitted-provenance)
             (emit node (car field) (cdr field) source nil
                   (cdr (assoc (car field) (supertag-migrate--pairs prov)))))))
      (dolist (node (supertag-migrate--pairs (gethash :fields store)))
        (dolist (tag (supertag-migrate--pairs (cdr node)))
          (dolist (field (supertag-migrate--pairs (cdr tag)))
            (emit (car node) (car field) (cdr field) 'root (car tag)))))
      (dolist (node (supertag-migrate--pairs (gethash :field-values store)))
        (values-for (car node) (cdr node) 'global (cdr (assoc (car node) provenance)))))
    ;; Preserve provenance even if its value or node has already gone missing.
    (dolist (node provenance)
      (dolist (field (supertag-migrate--pairs (cdr node)))
        (unless (gethash (cons (car node) (car field)) emitted-provenance)
          (push (list :node (car node) :name (format "%s" (car field))
                      :source 'global :tag nil :kind :provenance :raw (cdr field)) entries))))
    (maphash
     (lambda (id node)
       (when (listp node)
         (dolist (key '(:fields :field-values))
           (dolist (field (supertag-migrate--pairs (plist-get node key)))
             (let ((definition (cdr (assoc (car field) definitions))))
               (when definition (puthash (car field) t used))
               (push (plist-put
                      (supertag-migrate--field-entry
                       id (car field) (cdr field) 'embedded nil definition
                       (plist-get node :field-provenance)) :container key) entries))))
         (when (and (plist-get node :field-provenance)
                    (not (or (plist-get node :fields) (plist-get node :field-values))))
           (push (list :node id :name "" :source 'embedded :tag nil
                       :kind :provenance :raw (plist-get node :field-provenance)) entries))
         (dolist (key '(:fields :field-values :field-provenance))
           (setq node (cl-loop for (k v) on node by #'cddr
                               unless (eq k key) append (list k v))))
         (puthash id node (gethash :nodes store))))
     (gethash :nodes store))
    (dolist (tag (supertag-migrate--pairs (gethash :tag-field-associations store)))
      (push (list :node nil :name "" :source 'association :tag (car tag)
                  :raw (cdr tag)) entries))
    (dolist (def definitions)
      (unless (gethash (car def) used)
        (push (list :node nil :name (format "%s" (car def)) :source 'association
                    :tag nil :kind :definition :raw (cdr def)) entries)))
    (if entries (puthash :legacy-fields (nreverse entries) store) (remhash :legacy-fields store))
    (dolist (key supertag-migrate--field-roots) (remhash key store))))

(defun supertag-migrate--normalize-extends-lists (store)
  "Rewrite every string Tag `:extends' in STORE into a one-element list.
DB-only and idempotent.  Tag `:extends' is a parent list; stores written
before 7.2.0 hold one parent ID as a plain string.  Return non-nil when any
Tag changed."
  (let ((tags (gethash :tags store))
        (changed nil))
    (when (hash-table-p tags)
      (maphash
       (lambda (id raw-tag)
         (let ((tag (and raw-tag (supertag--ensure-plist raw-tag))))
           (when (and tag (stringp (plist-get tag :extends)))
             (puthash id (plist-put tag :extends (list (plist-get tag :extends)))
                      tags)
             (setq changed t))))
       tags))
    changed))

(defun supertag-migrate--explain-extends (store)
  "Keep every legacy inheritance edge and explain its path or conflict."
  (let ((tags (gethash :tags store))
        (result (or (gethash :legacy-extends store) (make-hash-table :test 'equal))))
    (cl-labels ((path (id seen)
                 (when (member id seen) (error "Inheritance cycle at %s" id))
                 (let ((tag (gethash id tags)))
                   (unless tag (error "Missing parent %s" id))
                   (let ((name (or (plist-get tag :name) id))
                         ;; A Tag with several parents has no single path; the
                         ;; first stored parent names it.
                         (parent (car (supertag-tag--tag-parents tag))))
                     (if parent (concat (path parent (cons id seen)) "/" name) name)))))
      (maphash (lambda (id tag)
                 (when-let* ((parents (supertag-tag--tag-parents tag)))
                   (puthash id
                            (condition-case err
                                (list :parent (car parents) :path (path id nil))
                              (error (list :parent (car parents)
                                           :conflict (error-message-string err))))
                            result)))
               tags))
    (if (> (hash-table-count result) 0) (puthash :legacy-extends result store)
      (remhash :legacy-extends store))))

(defun supertag-migrate--legacy-extends-resolve (token tags)
  "Resolve TOKEN to a live Tag ID in TAGS: entity ID first, then `:name'
or alias (via `supertag-tag-resolve-occurrence', which already indexes both).
A ghost entry (a Tag ID present in TAGS with a nil value) never resolves,
even though its own ID stays indexed as an occurrence token."
  (when (stringp token)
    (let ((id (or (and (gethash token tags) token)
                  (condition-case nil (supertag-tag-resolve-occurrence token) (error nil)))))
      (and id (gethash id tags) id))))

(defun supertag-migrate--legacy-extends-cycle-p (child-id parent-id tags)
  "Non-nil when CHILD-ID extending PARENT-ID would create an `:extends' cycle.
Walks every parent path of PARENT-ID in TAGS, which already reflects any edge
this same migration pass applied to an earlier record."
  (let ((stack (list parent-id))
        (seen (list child-id)))
    (catch 'cycle
      (while stack
        (let ((current (pop stack)))
          (when (member current seen) (throw 'cycle t))
          (push current seen)
          (let ((tag (supertag--ensure-plist (gethash current tags))))
            (when tag
              (setq stack (append (supertag-tag--tag-parents tag) stack))))))
      nil)))

(defun supertag-migrate--apply-legacy-extends (store)
  "Resolve `:legacy-extends' records into real Tag `:extends' edges in STORE.
DB-only and idempotent.  For each pending record, the child key and the
`:parent' name are resolved to live Tag IDs (entity ID, then `:name'/alias).
A record whose child already lists that parent is dropped without writing.  A
record whose child and parent both resolve, and whose edge would not form a
cycle, has the parent appended to the child's `:extends' list -- an existing
different parent is no longer a conflict, because a Tag may have several -- and
is then dropped.  Everything else is kept, annotated with `:conflict', for
`supertag-migrate-status' to report under `:unresolved-extends'.  Return
non-nil when any record's disposition changed."
  (let ((pending (gethash :legacy-extends store))
        (tags (gethash :tags store))
        rows changed)
    (when (and pending (hash-table-p tags))
      (maphash (lambda (key entry) (push (cons key entry) rows)) pending)
      (dolist (row (nreverse rows))
        (let* ((key (car row)) (entry (cdr row))
               (child-id (supertag-migrate--legacy-extends-resolve key tags))
               (parent-name (plist-get entry :parent))
               (parent-id (and (stringp parent-name)
                                (supertag-migrate--legacy-extends-resolve parent-name tags)))
               (child-tag (and child-id (supertag--ensure-plist (gethash child-id tags))))
               (current (and child-tag (supertag-tag--tag-parents child-tag)))
               (present (and parent-id (member parent-id current)))
               (conflict
                (cond
                 ((not child-id) "Missing child tag")
                 ((not parent-id) "Missing parent tag")
                 ;; A stored cycle is reported even when the edge is already
                 ;; there; otherwise an identical edge is simply applied.
                 ((supertag-migrate--legacy-extends-cycle-p child-id parent-id tags)
                  "Would create an :extends cycle")
                 (present nil))))
          (cond
           (conflict
            (let ((updated (plist-put (copy-sequence entry) :conflict conflict)))
              (unless (equal updated entry) (setq changed t))
              (puthash key updated pending)))
           (present (remhash key pending) (setq changed t))
           (t
            (puthash child-id (plist-put child-tag :extends
                                         (append current (list parent-id)))
                     tags)
            (remhash key pending)
            (setq changed t)))))
      (when (= (hash-table-count pending) 0) (remhash :legacy-extends store)))
    changed))

(defun supertag-migrate--db-steps (store)
  "Perform DB-only steps before the version stamp; never write Org."
  (supertag--migrate-4x-to-5x store)
  (supertag--retire-node-tag-projection store)
  (supertag-migrate--normalize-extends-lists store)
  (maphash (lambda (id node)
             (when (listp node)
               (when (and (plist-get node :file-path) (not (plist-get node :file)))
                 (setq node (plist-put node :file (plist-get node :file-path))))
               (when (and (plist-get node :pos) (not (plist-get node :position)))
                 (setq node (plist-put node :position (plist-get node :pos))))
               (puthash id node (gethash :nodes store)))) (gethash :nodes store))
  (supertag-migrate--extract-fields store)
  (supertag-migrate--explain-extends store)
  (supertag-migrate--apply-legacy-extends store)
  (let (nil-ids)
    (maphash (lambda (id tag) (unless tag (push id nil-ids))) (gethash :tags store))
    (dolist (id nil-ids) (remhash id (gethash :tags store)))))

;;;###autoload
(defun supertag-migrate-run ()
  "Migrate the loaded database only after a verified snapshot; return success."
  (interactive)
  (let ((version (supertag--get-data-version supertag--store)) snapshot)
    (if (equal version supertag-data-version) t
      (condition-case err
          (progn
            (cond
             ((null version)
              (user-error "Database has no :version stamp, so its data version is unknown; refusing to guess (nothing was changed). Back it up and migrate manually once you know which release wrote it"))
             ((version< supertag-data-version version)
              (user-error "Data version %s is newer than this build (%s); upgrade Supertag instead of migrating"
                          version supertag-data-version))
             ((version<= "5.0.0" version) nil)
             (t (user-error "Unsupported data version %s; upgrade to Supertag 6.x first" version)))
            (when (supertag-dirty-p)
              (user-error "Save or discard pending Store changes before migration"))
            (setq snapshot (supertag-migrate--snapshot version)
                  supertag-migrate--last-snapshot snapshot)
            (supertag-migrate--db-steps supertag--store)
            (supertag-index-rebuild-all)
            ;; The last mutation of the migration, after every DB-only step.
            (puthash :version supertag-data-version supertag--store)
            (supertag-mark-dirty)
            (unless (and (supertag-save-store) (not (supertag-dirty-p)))
              (error "Migration save was deferred"))
            (setq supertag-migrate--last-error nil)
            (let ((fields (length (gethash :legacy-fields supertag--store)))
                  (extends (gethash :legacy-extends supertag--store)))
              (when (or (> fields 0) (and extends (> (hash-table-count extends) 0)))
                (message "Pending export: legacy fields=%d, child tags=%d; run M-x supertag-migrate-preview"
                         fields (if extends (hash-table-count extends) 0))))
            t)
        (error
         (when snapshot
           (unless (equal (supertag-migrate--bytes snapshot) (supertag-migrate--bytes supertag-db-file))
             (copy-file snapshot supertag-db-file t))
           (setq supertag--store
                 (supertag--persistence--canonicalize-store-root
                  (supertag--coerce-store-table (supertag--persistence--try-read-store snapshot))))
           (supertag--ensure-store)
           (supertag-clear-dirty)
           (supertag--record-store-origin :ok)
           (supertag-index-rebuild-all))
         (setq supertag-migrate--last-error (error-message-string err))
         (message "Migration stopped: %s; M-x supertag-migrate-status%s"
                  supertag-migrate--last-error (if snapshot (concat "; snapshot " snapshot) ""))
         nil)))))

;;;###autoload
(defun supertag-migrate-status ()
  "Report pending sources and identity problems without deleting anything."
  (interactive)
  (unless (hash-table-p supertag--store) (user-error "Load the database first"))
  (let ((names (make-hash-table :test 'equal)) duplicates invalid unstable ghosts roots)
    (maphash (lambda (id tag)
               (cond ((null tag) (push id ghosts))
                     (t
                      (push id (gethash (plist-get tag :name) names))
                      (unless (supertag-tag-stable-id-p id) (push id unstable)))))
             (gethash :tags supertag--store))
    (maphash (lambda (name ids) (when (cdr ids) (push (cons name ids) duplicates))) names)
    (maphash (lambda (id node)
               (unless (and node (plist-get node :file) (plist-get node :title)) (push id invalid))
               (dolist (tag-id (plist-get node :tags))
                 (unless (gethash tag-id (gethash :tags supertag--store))
                   (cl-pushnew tag-id ghosts :test #'equal))))
             (gethash :nodes supertag--store))
    (dolist (key supertag-migrate--field-roots)
      (unless (eq supertag--not-found (gethash key supertag--store supertag--not-found))
        (push key roots)))
    (let ((report (list :version (supertag--get-data-version supertag--store)
                        :fields (gethash :legacy-fields supertag--store)
                        :unresolved-extends (gethash :legacy-extends supertag--store)
                        :duplicates duplicates :invalid-nodes invalid :unstable-tags unstable
                        :ghost-tags ghosts :unexpected-roots roots
                        :error supertag-migrate--last-error :snapshot supertag-migrate--last-snapshot)))
      (when (called-interactively-p 'interactive)
        (with-output-to-temp-buffer "*Supertag Migration Status*" (pp report)))
      report)))

(defun supertag-migrate--group-fields ()
  "Group legacy entries by node while retaining each distinct source."
  (let ((groups (make-hash-table :test 'equal)) (i 0))
    (dolist (entry (gethash :legacy-fields supertag--store))
      (let* ((id (plist-get entry :node)) (table (gethash id groups)))
        (unless table (setq table (make-hash-table :test 'equal)) (puthash id table groups))
        (puthash (cl-incf i) entry table)))
    groups))

(defun supertag-migrate--format-date (value)
  "Best-effort formatting of VALUE as a date string."
  (cond
   ((null value) "")
   ((stringp value) value)
   ;; Emacs time list (high low micro pico)
   ((and (listp value) (= (length value) 4))
    (format-time-string "%Y-%m-%d" value))
   ;; Fallback
   (t (format "%s" value))))

(defun supertag-migrate--format-timestamp (value)
  "Best-effort formatting of VALUE as a timestamp string."
  (cond
   ((null value) "")
   ((stringp value) value)
   ;; Emacs time list (high low micro pico)
   ((and (listp value) (= (length value) 4))
    (format-time-string "%Y-%m-%d %H:%M" value))
   (t (format "%s" value))))

(defun supertag-migrate--display (type value)
  "Render VALUE of TYPE as a single-line Org property value."
  (replace-regexp-in-string
   "[\n\r]" " "
   (cond
    ((or (null value) (equal value "")) "")
    ((eq type :boolean) (if (member value '("false" false :false)) "false" "true"))
    ((eq type :date) (supertag-migrate--format-date value))
    ((eq type :timestamp) (supertag-migrate--format-timestamp value))
    ((eq type :node-reference)
     (mapconcat
      (lambda (id)
        (let ((title (plist-get (supertag-store-get-entity :nodes id) :title)))
          (if (and title (not (equal title "")))
              (format "[[id:%s][%s]]" id title)
            (format "[[id:%s]]" id))))
      (if (listp value) value (list value)) " "))
    ((listp value) (mapconcat (lambda (item) (format "%s" item)) value " "))
    (t (format "%s" value)))))

(defun supertag-migrate--references (form)
  "List field references within an Automation FORM, without evaluating it."
  (cond
   ((memq form '(:on-field-change field-equals field-changed
                 global-field-equals global-field-changed
                 supertag-field-set :update-field)) (list form))
   ((consp form) (append (supertag-migrate--references (car form))
                         (supertag-migrate--references (cdr form))))))

(defun supertag-migrate--collect ()
  "Read legacy facts and live Org into a migration report."
  (let (nodes skipped automations (write-count 0) (conflict-count 0) (node-count 0) (pending-count 0))
    (maphash
     (lambda (id fields)
       (let* ((node (supertag-store-get-entity :nodes id))
              (file (plist-get node :file))
              (candidates (make-hash-table :test 'equal)) writes conflicts pending completed)
         (if (not (and node (not (equal (plist-get node :level) 0))
                       file (file-exists-p file)))
             (push (list :id id :file file :reason :unlocatable) skipped)
           (maphash
            (lambda (fid entry)
              (let* ((name (plist-get entry :name))
                     (key (replace-regexp-in-string "[[:space:]:]" "_"
                                                    (upcase (format "%s" name))))
                     (display (plist-get entry :value))
                     (reason (cond ((not (plist-member entry :value)) :unparsed)
                                   ((equal key "") :empty-name)
                                   ((or (equal key "ID")
                                        (member key org-special-properties)) :reserved)
                                   ((equal display "") :empty-value))))
                (if reason
                    (push (list :id id :file file :field fid :key key :reason reason) skipped)
                  (puthash key (cons (cons (format "%s" name) display) (gethash key candidates)) candidates)))) fields)
           (condition-case nil
               (supertag-service-org--with-node-buffer
                id (lambda ()
                     (dolist (key (sort (hash-table-keys candidates) #'string<))
                       (let* ((entries (sort (gethash key candidates)
                                             (lambda (a b)
                                               (if (equal (car a) (car b))
                                                   (string< (cdr a) (cdr b))
                                                 (string< (car a) (car b))))))
                              (values (delete-dups (mapcar #'cdr entries)))
                              (value (car values))
                              (old (org-entry-get nil key)))
                         (cond
                          ((cdr values)
                           (push (list :type :key-conflict :key key :fields entries) conflicts))
                          ((equal old value)
                           (push (cons key value) completed)
                           (unless (and (not (buffer-modified-p))
                                        (equal value (plist-get (plist-get node :properties)
                                                                (intern (concat ":" key)))))
                             (push (cons key value) pending)))
                          (old (push (list :key key :org old :field value) conflicts))
                          (t (push (cons key value) writes)))))))
             (user-error
              (setq writes nil conflicts nil pending nil)
              (push (list :id id :file file :reason :unlocatable) skipped))))
         (setq write-count (+ write-count (length writes))
               conflict-count (+ conflict-count (length conflicts)))
         (setq pending-count (+ pending-count (length pending)))
         (when writes (setq node-count (1+ node-count)))
         (push (list :id id :file file :title (plist-get node :title)
                     :completed completed :writes (nreverse writes) :pending (nreverse pending) :conflicts (nreverse conflicts)) nodes)))
     (supertag-migrate--group-fields))
    (maphash
     (lambda (_id rule)
       (let (references)
         (dolist (part '(:trigger :condition :actions))
           (dolist (reference (delete-dups (supertag-migrate--references (plist-get rule part))))
             (push (cons part reference) references)))
         (when references
           (push (list :name (plist-get rule :name) :references (nreverse references)) automations))))
     (supertag-store-get-collection :automations))
    (list :nodes (sort nodes (lambda (a b)
                              (string< (format "%s/%s" (plist-get a :file) (plist-get a :id))
                                       (format "%s/%s" (plist-get b :file) (plist-get b :id)))))
          :skipped (nreverse skipped) :automations (nreverse automations)
          :pending-count pending-count :write-count write-count :node-count node-count :conflict-count conflict-count)))

;;;###autoload
(defun supertag-migrate-preview ()
  "Preview legacy fields against live Org without modifying either; return report."
  (interactive)
  (let ((report (supertag-migrate--collect))
        (buffer (get-buffer-create "*Supertag Field Migration*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t) last-file)
        (erase-buffer)
        (dolist (node (plist-get report :nodes))
          (unless (equal last-file (plist-get node :file))
            (setq last-file (plist-get node :file))
            (insert (format "\nFile %s\n" last-file)))
          (insert (format "%s [%s]\n" (plist-get node :title) (plist-get node :id)))
          (dolist (pair (plist-get node :writes))
            (insert (format "  %s = %s\n" (car pair) (cdr pair))))
          (dolist (pair (plist-get node :pending))
            (insert (format "  Pending save/projection %s = %s\n" (car pair) (cdr pair))))
          (dolist (conflict (plist-get node :conflicts))
            (if (eq (plist-get conflict :type) :key-conflict)
                (insert (format "  Key conflict %s: %S\n" (plist-get conflict :key)
                                (plist-get conflict :fields)))
              (insert (format "  Conflict %s: Org=%s field=%s\n"
                              (plist-get conflict :key) (plist-get conflict :org)
                              (plist-get conflict :field))))))
        (insert "\nSource records (uninterpreted original values are preserved)\n")
        (dolist (entry (gethash :legacy-fields supertag--store))
          (insert (format "%s node=%S tag=%S %s = %S\n"
                          (plist-get entry :source) (plist-get entry :node)
                          (plist-get entry :tag) (plist-get entry :name)
                          (if (plist-member entry :value) (plist-get entry :value)
                            (list :raw (plist-get entry :raw))))))
        (dolist (group '((:empty-name . "Empty name") (:empty-value . "Empty value (skipped)")
                         (:reserved . "Reserved key") (:unlocatable . "Unlocatable")))
          (insert (format "\n%s\n" (cdr group)))
          (dolist (item (plist-get report :skipped))
            (when (eq (plist-get item :reason) (car group))
              (insert (format "  %s %s %s\n" (plist-get item :file)
                              (plist-get item :id) (plist-get item :field))))))
        (insert "\nParent relationships to write (DB-only; written to tag :extends without confirmation)\n")
        (let ((pending (gethash :legacy-extends supertag--store)))
          (when pending
            (maphash
             (lambda (key entry)
               (if (plist-get entry :conflict)
                   (insert (format "  Unresolved %s -> %s: %s\n" key
                                   (or (plist-get entry :parent) "?")
                                   (plist-get entry :conflict)))
                 (insert (format "  %s → %s\n" key (or (plist-get entry :parent) "?")))))
             pending)))
        (insert "\nAutomation field references (edit manually)\n")
        (dolist (rule (plist-get report :automations))
          (insert (format "%s: %S\n" (plist-get rule :name) (plist-get rule :references))))
        (insert (format "\nMigration summary: keys=%d, nodes=%d, pending save/projection=%d, conflicts=%d, skipped=%d\n"
                        (plist-get report :write-count) (plist-get report :node-count)
                        (plist-get report :pending-count)
                        (plist-get report :conflict-count) (length (plist-get report :skipped)))))
      (special-mode))
    (when (called-interactively-p 'interactive) (pop-to-buffer buffer))
    report))


(defun supertag-migrate--property-key (entry)
  "Map ENTRY's name to the inherited Org property spelling."
  (replace-regexp-in-string "[[:space:]:]" "_" (upcase (plist-get entry :name))))

;;;###autoload
(defun supertag-migrate-apply ()
  "Confirm property export, resolve any pending `:legacy-extends' edges as a
fallback, then retire completed records."
  (interactive)
  (when (supertag-migrate--apply-legacy-extends supertag--store)
    (supertag-mark-dirty)
    (unless (supertag-save-store) (error "Migration bookkeeping save deferred")))
  (let ((report (supertag-migrate-preview)))
    (when (yes-or-no-p (format "Write migration data (keys=%d, pending save/projection=%d); save and reproject? "
                              (plist-get report :write-count) (plist-get report :pending-count)))
      (dolist (node (plist-get report :nodes))
        (let ((id (plist-get node :id)))
          (when (or (plist-get node :writes) (plist-get node :pending))
            (supertag-service-org--update-buffer-and-resync
             id (lambda ()
                  (dolist (pair (plist-get node :writes))
                    (unless (org-entry-get nil (car pair))
                      (org-entry-put nil (car pair) (cdr pair)))))
             (and (plist-get node :pending) t)))
          ;; Use the saved disk and projection, never a live draft, as completion.
          (let ((pairs (append (plist-get node :writes) (plist-get node :pending)
                               (plist-get node :completed)))
                (file (plist-get node :file)))
            (when (and pairs file (file-exists-p file))
              (with-temp-buffer
                (insert-file-contents file) (org-mode)
                (let (heading)
                  (goto-char (point-min))
                  (while (re-search-forward "^[ \t]*:ID:[ \t]+\\(.*?\\)[ \t]*$" nil t)
                    (when (and (equal (match-string 1) id) (org-at-property-p))
                      (save-excursion
                        (condition-case nil
                            (progn (org-back-to-heading t) (push (point) heading))
                          (error nil)))))
                  (when (= (length (delete-dups heading)) 1)
                    (goto-char (car heading))
                    (let ((remaining (gethash :legacy-fields supertag--store)))
                      (dolist (pair pairs)
                        (when (and (equal (org-entry-get nil (car pair)) (cdr pair))
                                   (equal (plist-get (plist-get (supertag-node-get id) :properties)
                                                     (intern (concat ":" (car pair)))) (cdr pair)))
                          (setq remaining
                                (cl-remove-if
                                 (lambda (entry)
                                   (and (equal (plist-get entry :node) id)
                                        (equal (supertag-migrate--property-key entry) (car pair))
                                        (equal (plist-get entry :value) (cdr pair)))) remaining))))
                      (unless (equal remaining (gethash :legacy-fields supertag--store))
                        (if remaining (puthash :legacy-fields remaining supertag--store)
                          (remhash :legacy-fields supertag--store))
                        (supertag-mark-dirty)
                        (supertag-save-store))))))))))
      (supertag-migrate-preview))))

(defun supertag-migrate--reset-runtime ()
  "Clear migration diagnostics at a vault boundary."
  (setq supertag-migrate--last-error nil
        supertag-migrate--last-snapshot nil))

(provide 'supertag-migrate)
;;; supertag-migrate.el ends here
