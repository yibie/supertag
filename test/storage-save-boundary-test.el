;;; storage-save-boundary-test.el --- Save/commit boundaries -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'document-fixture)

(ert-deftest supertag-storage-reindex-saves-once-after-commit ()
  "Real orphan GC joins reindex; saving happens only after commit."
  (supertag-document-test-with-vault
    (let ((supertag-sync-orphan-grace-seconds 0)
          (supertag-sync-max-delete-ratio 1.0)
          saves)
      (supertag-store-put-entity :nodes "orphan"
                                '(:id "orphan" :type :node :file nil :orphaned-at (0 0)))
      (cl-letf (((symbol-function 'supertag-save-store)
                 (lambda (&rest _) (push supertag--transaction-active saves) t)))
        (should (eq 'complete (plist-get (supertag-reindex-org) :status))))
      (should-not (supertag-store-get-entity :nodes "orphan"))
      (should (equal '(nil) saves)))))

(ert-deftest supertag-storage-failed-reindex-does-not-save-gc ()
  "A failure after orphan deletion rolls it back without persisting it."
  (supertag-document-test-with-vault
    (let ((supertag-sync-orphan-grace-seconds 0)
          (supertag-sync-max-delete-ratio 1.0)
          saves)
      (supertag-store-put-entity :nodes "orphan"
                                '(:id "orphan" :type :node :file nil :orphaned-at (0 0)))
      (cl-letf (((symbol-function 'supertag-save-store)
                 (lambda (&rest _) (cl-incf saves)))
                ((symbol-function 'supertag-index-rebuild-all)
                 (lambda () (error "Post-GC failure"))))
        (setq saves 0)
        (should (eq 'failed (plist-get (supertag-reindex-org) :status))))
      (should (supertag-store-get-entity :nodes "orphan"))
      (should (= 0 saves)))))

(ert-deftest supertag-storage-save-isolates-after-save-subscribers ()
  "A failing subscriber cannot undo a durable save or skip the next one."
  (supertag-document-test-with-vault
    (let* ((supertag-db--dirty t)
           (supertag-persistence-after-save-hook nil)
           (second-ran nil)
           (first (lambda () (error "Subscriber failure")))
           (second (lambda () (setq second-ran t))))
      (setq supertag-persistence-after-save-hook (list first second))
      (supertag--record-store-origin :ok)
      (should-not (supertag--persistence-guard-violations))
      (should (supertag-save-store))
      (should second-ran)
      (should-not (supertag-dirty-p))
      (should (gethash "document-node"
                       (gethash :nodes (supertag--persistence--try-read-store
                                        supertag-db-file)))))))


(ert-deftest supertag-storage-cleanup-remains-callable-after-ui-load ()
  "Interactive cleanup confirms once after UI loading."
  (if (equal (getenv "SUPERTAG_SYA_STAGE") "before")
      (require 'supertag-ui-commands)
    (require 'supertag-services-sync))
  (supertag-document-test-with-vault
    (let (validated collected (asked 0))
      (cl-letf (((symbol-function 'supertag-sync-validate-nodes)
                 (lambda (&rest _) (setq validated t)))
                ((symbol-function 'supertag-sync-garbage-collect-orphaned-nodes)
                 (lambda () (setq collected t) 0))
                ((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (cl-incf asked) t)))
        (let ((noninteractive nil))
          (call-interactively #'supertag-sync-cleanup-database)))
      (should (= asked 1))
      (should validated)
      (should collected))))

(ert-deftest supertag-storage-cleanup-cancel-and-noninteractive ()
  (supertag-document-test-with-vault
    (let ((asked 0) (validated 0) (collected 0))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (cl-incf asked) nil))
                ((symbol-function 'supertag-sync-validate-nodes)
                 (lambda (&rest _) (cl-incf validated)))
                ((symbol-function 'supertag-sync-garbage-collect-orphaned-nodes)
                 (lambda () (cl-incf collected) 0)))
        ;; Emulate an interactive Emacs while retaining the real call stack.
        (let ((noninteractive nil))
          (should-not (call-interactively #'supertag-sync-cleanup-database)))
        (should (= asked 1))
        (should (= validated 0))
        (should (= collected 0))
        (supertag-sync-cleanup-database)
        (should (= asked 1))
        (should (= validated 1))
        (should (= collected 1))))))

(ert-deftest supertag-storage-reindex-real-disk-rollback-and-retry ()
  "Failed GC leaves the durable baseline intact; a retry commits deletion."
  (supertag-document-test-with-vault
    (let ((supertag-db--dirty t)
          (supertag-persistence-after-save-hook nil)
          (supertag-sync-orphan-grace-seconds 0)
          (supertag-sync-max-delete-ratio 1.0)
          (rebuild (symbol-function 'supertag-index-rebuild-all))
          (fail-once t))
      (supertag-store-put-entity :nodes "orphan"
                                '(:id "orphan" :type :node :file nil :orphaned-at (0 0)))
      (supertag--record-store-origin :ok)
      (should (supertag-save-store))
      (cl-flet ((disk-node (id)
                  (gethash id (gethash :nodes
                                      (supertag--persistence--try-read-store
                                       supertag-db-file)))))
        (should (disk-node "orphan"))
        (should (disk-node "document-node"))
        (cl-letf (((symbol-function 'supertag-index-rebuild-all)
                   (lambda ()
                     (if fail-once
                         (progn (setq fail-once nil) (error "Post-GC failure"))
                       (funcall rebuild)))))
          (should (eq 'failed (plist-get (supertag-reindex-org) :status)))
          (should (disk-node "orphan"))
          (should (disk-node "document-node"))
          (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
          (should-not (disk-node "orphan"))
          (should (disk-node "document-node")))))))

(ert-deftest supertag-storage-reindex-preserves-nonprojected-collections ()
  (supertag-document-test-with-vault
    (let ((collections '(:sync-conflicts :automations :views :meta)))
      (dolist (collection collections)
        (supertag-store-put-entity collection "preserved" '(:name "preserved" :value "fact")))
      (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
      (dolist (collection collections)
        (should (equal '(:name "preserved" :value "fact")
                       (supertag-store-get-entity collection "preserved")))))))

(ert-deftest supertag-storage-load-retires-only-queries ()
  (supertag-document-test-with-vault
    (let ((supertag-db--dirty t)
          (supertag-persistence-after-save-hook nil)
          (supertag-db-auto-migrate nil)
          (before (make-hash-table :test 'eq)))
      ;; Explicit unknown legacy roots must survive when auto-migration is off.
      (dolist (key '(:fields :field-values :field-provenance :field-definitions :tag-field-associations))
        (puthash key (make-hash-table :test 'equal) supertag--store))
      (puthash :version supertag-data-version supertag--store)
      (dolist (collection '(:queries :embeds))
        (let ((bucket (make-hash-table :test 'equal)))
          (puthash "legacy" '(:id "legacy" :value "retained") bucket)
          (puthash collection bucket supertag--store)))
      ;; These eight deployed-schema collections have no active producer in
      ;; the current loading chain.  Constructing valid deployment contracts
      ;; would require archived ontology/Link Definition code; keep their
      ;; empty counts covered without claiming a nonempty round-trip here.
      ;; :link-definitions, :ontology-bindings, :ontology-modules,
      ;; :ontology-migrations, :ontology-functions, :ontology-actions,
      ;; :ontology-policies, :ontology-action-executions.
      ;; Remaining shapes follow canonical-serialization-test (nested field
      ;; tables), Automation records, and conflicts.el's frozen record shape.
      (dolist (entry
               '((:tags "sentinel-tag" (:id "sentinel-tag" :name "Sentinel"))
                 (:relations "sentinel-link" (:id "sentinel-link" :type :document-link
                    :from "document-node" :to "document-node" :relation-name "supports"))
                 (:field-definitions "sentinel-field" (:id "sentinel-field" :name "Sentinel" :type :string))
                 (:tag-field-associations "sentinel-tag" ((:field-id "sentinel-field" :order 0)))
                 (:boards "sentinel-board" (:id "sentinel-board" :name "Sentinel" :nodes nil :edges nil))
                 (:views "sentinel-view" (:id "sentinel-view" :view-id stream :input nil :state nil))
                 (:automations "sentinel-rule" (:id "sentinel-rule" :name "Sentinel"
                    :trigger :on-node-create :condition nil :actions nil :enabled nil))
                 (:sync-conflicts "sentinel-conflict" (:id "sentinel-conflict" :collection :nodes
                    :entity-id "document-node" :key :title :ours "Ours" :theirs "Theirs"
                    :base "Base" :kind :field-conflict :detected-at nil))
                 (:meta "sentinel" (:value "retained"))))
        (puthash (nth 1 entry) (nth 2 entry) (gethash (car entry) supertag--store)))
      ;; The real document fixture already supplies a nonempty :nodes record.
      (let ((fields (make-hash-table :test 'equal))
            (values (make-hash-table :test 'equal))
            (provenance (make-hash-table :test 'equal)))
        (puthash "sentinel-field" "value" values)
        (puthash "sentinel-tag" (copy-hash-table values) fields)
        (puthash "sentinel-field" '(:source :manual) provenance)
        (puthash "document-node" fields (gethash :fields supertag--store))
        (puthash "document-node" values (gethash :field-values supertag--store))
        (puthash "document-node" provenance (gethash :field-provenance supertag--store)))
      (dolist (collection (remq :queries (copy-sequence supertag--store-collections)))
        (puthash collection (copy-hash-table (gethash collection supertag--store)) before))
      (supertag--record-store-origin :ok)
      (should-not (supertag--persistence-guard-violations))
      (supertag-save-store)
      (should (string-match-p ":queries" (supertag-document-test-disk supertag-db-file)))
      (supertag-load-store)
      (should-not (gethash :queries supertag--store))
      (should-not (memq :queries supertag--store-collections))
      (maphash
       (lambda (collection bucket)
         (let ((actual (gethash collection supertag--store)))
           (should (= (hash-table-count bucket) (hash-table-count actual)))
           (maphash (lambda (id value)
                      (should (equal (supertag--persistence--canonicalize-value value)
                                     (supertag--persistence--canonicalize-value
                                      (gethash id actual)))))
                    bucket)))
       before)
      (should (equal '(:id "legacy" :value "retained")
                     (gethash "legacy" (gethash :embeds supertag--store))))
      (setq supertag-db--dirty t)
      (supertag-save-store)
      (let ((disk (supertag-document-test-disk supertag-db-file)))
        (should-not (string-match-p ":queries" disk))
        (should (string-match-p ":embeds" disk)))
      ;; Read the second saved file afresh, not the previous in-memory Store.
      (setq supertag--store nil)
      (supertag-load-store)
      (should-not (gethash :queries supertag--store))
      (maphash
       (lambda (collection bucket)
         (let ((actual (gethash collection supertag--store)))
           (should (= (hash-table-count bucket) (hash-table-count actual)))
           (maphash (lambda (id value)
                      (should (equal (supertag--persistence--canonicalize-value value)
                                     (supertag--persistence--canonicalize-value
                                      (gethash id actual)))))
                    bucket)))
       before))))

(provide 'storage-save-boundary-test)

(defconst supertag-storage-test--source-root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(defun supertag-storage-test--cold-retirement (entry)
  "Check ENTRY's real cold source load in a separate isolated Emacs."
  (let* ((root supertag-storage-test--source-root)
         (temporary (make-temp-file "supertag-storage-cold-" t))
         (program (or (getenv "EMACS_BIN")
                      (expand-file-name invocation-name invocation-directory)))
         (dependencies
          (or (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t)
              (mapcar (lambda (name)
                        (file-name-directory
                         (or (locate-library name)
                             (error "Cold-load setup: missing %s dependency" name))))
                      '("ht" "dash"))))
         (process-environment (copy-sequence process-environment))
         (form
          `(unwind-protect
               (progn
                 (setq user-emacs-directory ,(file-name-as-directory temporary)
                       supertag-data-directory ,(expand-file-name "data/" temporary)
                       supertag--base-data-directory supertag-data-directory
                       supertag-db-file ,(expand-file-name "data/store.el" temporary)
                       supertag-db-backup-directory ,(expand-file-name "backups/" temporary)
                       supertag-sync-state-file ,(expand-file-name "sync.el" temporary)
                       supertag-sync--state-source supertag-sync-state-file
                       org-id-locations-file ,(expand-file-name "ids" temporary)
                       supertag-sync-directories nil
                       supertag-active-sync-directory nil
                       load-prefer-newer t)
                 (when (or (featurep ',entry) (featurep 'supertag-ops-batch))
                   (error "Cold-load setup: preloaded entry or batch"))
                 (when (directory-files ,root nil "\\.elc\\'")
                   (error "Cold-load setup: root bytecode present"))
                 ;; Main's late-load branch would otherwise initialize the DB.
                 (let ((after-init-time nil))
                   (load ,(expand-file-name (concat (symbol-name entry) ".el") root) nil nil t))
                 (unless (featurep ',entry) (error "Entry failed to provide feature"))
                 (princ ,(format "ENTRY-LOADED:%s\n" entry))
                 (when (featurep 'supertag-ops-batch)
                   (error "Retired feature still loaded: supertag-ops-batch"))
                 (dolist (symbol '(supertag-batch-create supertag-batch-update supertag-batch-delete))
                   (when (fboundp symbol) (error "Retired API still bound: %s" symbol)))
                 (dolist (loaded load-history)
                   (when (and (stringp (car loaded))
                              (string-match-p "supertag-ops-batch\\.el" (car loaded)))
                     (error "Retired module in load-history: %s" (car loaded))))
                 (unless (macrop 'supertag-with-transaction)
                   (error "Retained transaction macro missing"))
                 ;; Relation API is lazy for Sync; main retains its original observation time.
                 (when (eq ',entry 'supertag-services-sync)
                   (unless (equal (getenv "SUPERTAG_LC_STAGE") "before")
                     (when (or (featurep 'supertag-link)
                               (cl-find-if
                                (lambda (row)
                                  (and (stringp (car row))
                                       (equal (file-name-base (car row)) "supertag-link")))
                                load-history))
                       (error "Sync unexpectedly loaded Link before projection"))
                     (dolist (symbol '(supertag-relation-named-document-link-p
                                       supertag-relation-document-link-p
                                       supertag-relation-find-between
                                       supertag-relation-project-document-link
                                       supertag-relation-find-by-from
                                       supertag-relation-find-by-to
                                       supertag-relation-delete))
                       (unless (and (fboundp symbol)
                                    (autoloadp (symbol-function symbol))
                                    (equal (nth 1 (symbol-function symbol)) "supertag-link"))
                         (error "Wrong lazy Relation provider: %s" symbol))))
                   (let ((supertag--store nil))
                     (supertag--ensure-store)
                     (supertag-store-put-entity :nodes "lc-storage-source"
                                               '(:id "lc-storage-source" :title "Source"))
                     (supertag-store-put-entity :nodes "lc-storage-target"
                                               '(:id "lc-storage-target" :title "Target"))
                     (let ((counters (list :references-created 0)))
                       (supertag--process-node-references
                        '(:id "lc-storage-source" :ref-to ("lc-storage-target")) counters)
                       (unless (and (= 1 (plist-get counters :references-created))
                                    (= 1 (length (supertag-relation-find-between
                                                  "lc-storage-source" "lc-storage-target"
                                                  :reference :document-link))))
                         (error "Sync first real projection failed")))
                     (unless (equal (getenv "SUPERTAG_LC_STAGE") "before")
                       (unless (and (featurep 'supertag-link)
                                    (equal (symbol-file 'supertag-relation-create 'defun)
                                           ,(expand-file-name "supertag-link.el" root)))
                         (error "Relation provider did not execute during projection"))))
                   (princ "LC-STORAGE-PROJECTION-DONE\n"))
                 (dolist (symbol '(supertag-node-create supertag-node-update supertag-node-delete
                                   supertag-tag-create supertag-tag-update supertag-tag-delete
                                   supertag-relation-create supertag-relation-update supertag-relation-delete))
                   (unless (fboundp symbol) (error "Retained operation missing: %s" symbol)))
                 (when (file-exists-p ,(expand-file-name "supertag-ops-batch.el" root))
                   (error "Retired source file still exists"))
                 (princ ,(format "RETIREMENT-PASS:%s\n" entry)))
             ;; Run even on load/retirement errors; never save on child exit.
             (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil))))
    (unwind-protect
        (with-temp-buffer
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity dependencies path-separator) path-separator))
          (let* ((args (append '("-Q" "--batch")
                               (apply #'append (mapcar (lambda (dir) (list "-L" dir)) dependencies))
                               (list "-L" root "--eval"
                                     (prin1-to-string
                                      `(condition-case problem
                                           ,form
                                         (error
                                          (princ (format "COLD-ERROR:%S\n" problem))
                                          (kill-emacs 1)))))))
                 (status (apply #'call-process program nil t nil args))
                 (output (buffer-string)))
            (unless (and (equal status 0)
                         (string-match-p (regexp-quote (format "ENTRY-LOADED:%s\n" entry)) output)
                         (string-match-p (regexp-quote (format "RETIREMENT-PASS:%s\n" entry)) output))
              (ert-fail (format "Cold %s exit=%S\n%s" entry status output)))))
      (delete-directory temporary t))))

(ert-deftest supertag-storage-sync-cold-load-retires-generic-batch ()
  (supertag-storage-test--cold-retirement 'supertag-services-sync))

(ert-deftest supertag-storage-main-cold-load-retires-generic-batch ()
  (supertag-storage-test--cold-retirement 'supertag))

;;; V2-SYNC-A: independent commands, cold entry and transaction boundaries.
(defconst supertag-storage-test--sya-program ";;; -*- lexical-binding: t; -*-\n(require 'ert)\n(require 'cl-lib)\n(let* ((tree (getenv \"SYA_TREE\")) (tmp (getenv \"SYA_TMP\"))\n       (case (getenv \"SYA_CASE\")) (phase (getenv \"SYA_PHASE\"))\n       (before (equal (getenv \"SUPERTAG_SYA_STAGE\") \"before\"))\n       (root (expand-file-name \"org/\" tmp)) (file (expand-file-name \"note.org\" root))\n       (state-file (expand-file-name \"data/sync-state.el\" tmp))\n       (generated (expand-file-name \"autoloads.el\" tree))\n       (data (expand-file-name \"data/\" tmp))\n       (names '(supertag-sync-force-resync-file supertag-sync-force-resync-current-file supertag-sync-status))\n       (messages nil) (real-message (symbol-function 'message))\n       (counters-seen nil) (events nil) (asked 0))\n  (setq user-emacs-directory (file-name-as-directory tmp)\n        default-directory (file-name-as-directory tmp) after-init-time nil\n        load-prefer-newer t supertag-data-directory data\n        supertag-db-file (expand-file-name \"store.el\" data)\n        supertag-db-backup-directory (expand-file-name \"backups/\" data)\n        supertag-sync-state-file state-file org-id-locations-file (expand-file-name \"ids\" tmp)\n        supertag-sync-directories (list root) supertag-active-sync-directory nil\n        supertag-sync-directories-mode 'unified supertag-sync-auto-start nil\n        supertag-file-id-source 'disabled supertag-tag-auto-enable nil)\n  (make-directory root t)\n  (cl-labels ((bytes (path) (when (file-exists-p path)\n                            (with-temp-buffer (insert-file-contents-literally path) (buffer-string))))\n              (write-note (title)\n                (with-temp-file file\n                  (insert (format \"* %s\\n:PROPERTIES:\\n:ID: sya-a\\n:END:\\nBody\\n* Beta\\n:PROPERTIES:\\n:ID: sya-b\\n:END:\\nBody\\n\" title))))\n              (graph (marker)\n                (princ (format \"SYA-GRAPH %s %S\\n\" marker\n                               (mapcar (lambda (f) (cons f (featurep f)))\n                                       '(supertag-services-sync supertag-ui-commands supertag-services-ui\n                                         supertag-node supertag-tag supertag-link supertag-query supertag-service-org supertag)))))\n              (force ()\n                (cl-letf (((symbol-function 'yes-or-no-p)\n                           (lambda (&rest _) (cl-incf asked) t)))\n                  (supertag-sync-force-resync-file file))))\n    (unwind-protect\n        (cl-letf (((symbol-function 'message)\n                   (lambda (format-string &rest args)\n                     (when format-string (push (apply #'format-message format-string args) messages))\n                     (apply real-message format-string args))))\n          (if (equal phase \"generate\")\n              (progn\n                (require 'loaddefs-gen)\n                (loaddefs-generate\n                 (list tree) generated\n                 (cl-remove-if (lambda (p) (member (file-name-nondirectory p)\n                                                  '(\"supertag-services-sync.el\" \"supertag-ui-commands.el\")))\n                               (directory-files tree t \"\\\\.el\\\\'\")) nil nil t)\n                (let (forms)\n                  (with-temp-buffer\n                    (insert-file-contents generated) (goto-char (point-min))\n                    (condition-case nil\n                        (while t (let ((f (read (current-buffer))))\n                                   (when (eq (car-safe f) 'autoload) (push f forms))))\n                      (end-of-file nil)))\n                  (dolist (name (cdr names))\n                    (let ((hits (cl-remove-if-not (lambda (f) (eq (cadr (cadr f)) name)) forms)))\n                      (should (= 1 (length hits)))\n                      (should (equal (if before \"supertag-ui-commands\" \"supertag-services-sync\") (nth 2 (car hits))))\n                      (should (eq t (nth 4 (car hits))))))\n                  (should-not (cl-find (car names) forms :key (lambda (f) (cadr (cadr f))))))\n                (princ (format \"SYA-DONE %s/%s\\n\" case phase)))\n            (write-note \"Alpha\")\n            (cond\n             ((string-prefix-p \"consumer-\" case)\n              (let ((feature (if (equal case \"consumer-supertag\") 'supertag (intern (concat \"supertag-\" (substring case 9))))))\n                (should-not (featurep feature))\n                (require feature) (graph 'consumer-entry)\n                (pcase feature\n                  ('supertag-concept\n                   (should-not (supertag-concept-node-p '(:id \"sya-a\" :level 0)))\n                   (should (equal '(\"A\" \"B\") (supertag-concept--split-aliases \"A, B\"))))\n                  ('supertag-ai\n                   (puthash \"sya-a\" '(:status failed :message \"SYA failure\" :candidates nil) supertag-ai--candidates)\n                   (with-temp-buffer (supertag-ai-insert-section \"sya-a\")\n                                     (should (string-match-p \"SYA failure\" (buffer-string)))))\n                  ('supertag-mention\n                   (should (= 1 (length (supertag-mention-service-scan-content \"Alpha here [[id:x][Alpha]]\" '(\"Alpha\"))))))\n                  ('supertag-embark\n                   (with-temp-buffer\n                     (org-mode) (insert \"[[id:sya-a][Alpha]]\") (goto-char 4)\n                     (should (eq 'supertag-link (car (supertag-embark-target-finder))))))\n                  ('supertag\n                   (should-not supertag--initialized)\n                   (should (memq 'supertag-init emacs-startup-hook))\n                   (supertag-sync-status)))\n                (graph 'consumer-operation)))\n             ((equal case \"generated\")\n              (should-not (featurep 'supertag-services-sync))\n              (load generated nil nil t)\n              (should (autoloadp (symbol-function 'supertag-sync-status)))\n              (call-interactively 'supertag-sync-status)\n              (with-current-buffer (find-file-noselect file)\n                (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))\n                  (call-interactively 'supertag-sync-force-resync-current-file)))\n              (should (equal \"Alpha\" (plist-get (supertag-node-get \"sya-a\") :title)))\n              (should (file-exists-p state-file)) (graph 'generated-operation))\n             ((equal case \"menu\")\n              (require 'supertag-menu) (graph 'menu-entry)\n              (call-interactively 'supertag-menu--sync-status)\n              (let ((noninteractive nil))\n                (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (cl-incf asked) t)))\n                  (call-interactively 'supertag-menu--sync-cleanup)))\n              (should (= 1 asked))\n              (should (cl-some (lambda (s) (string-prefix-p \"Database cleanup complete\" s)) messages)))\n             (t\n              (require 'supertag-services-sync) (graph 'sync-cold)\n              (should-not (featurep 'supertag-ui-commands))\n              (if before\n                  (progn (dolist (n names) (should-not (fboundp n)))\n                         (require 'supertag-ui-commands))\n                (dolist (n names) (should (fboundp n))))\n              (princ (format \"SYA-ENTRY case=%s owner=%S\\n\" case (symbol-file 'supertag-sync-force-resync-file 'defun)))\n              (should (macrop 'supertag-with-transaction))\n              (should-not (commandp 'supertag-sync-force-resync-file))\n              (dolist (n (cdr names)) (should (commandp n)))\n              (dolist (n names)\n                (should (equal (if (and before (not (getenv \"SYA_OWNER_RED\"))) \"supertag-ui-commands.el\" \"supertag-services-sync.el\")\n                               (file-name-nondirectory (symbol-file n 'defun)))))\n              (unless before\n                (should-not (featurep 'supertag-ui-commands))\n                (should-not (locate-library \"supertag-ui-commands\"))\n                (should-not (cl-find-if (lambda (x) (and (stringp (car x))\n                                                       (equal \"supertag-ui-commands\" (file-name-base (car x))))) load-history)))\n              (if (equal case \"errors\")\n                  (let ((outside (expand-file-name \"outside.org\" tmp))\n                        (disk (bytes file)))\n                    (with-temp-file outside (insert \"* Outside\\n\"))\n                    (should-error (supertag-sync-force-resync-file (concat file \"-missing\")) :type 'user-error)\n                    (should-error (supertag-sync-force-resync-file outside) :type 'user-error)\n                    (with-temp-buffer (should-error (call-interactively 'supertag-sync-force-resync-current-file) :type 'user-error))\n                    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))\n                      (should-not (supertag-sync-force-resync-file file)))\n                    (should (equal disk (bytes file))) (should-not (file-exists-p state-file)))\n                (let ((real-process (symbol-function 'supertag-sync--process-single-file)))\n                  (cl-letf (((symbol-function 'supertag-sync--process-single-file)\n                             (lambda (path counts)\n                               (push counts counters-seen)\n                               (push (list 'process supertag--transaction-active (gethash path (supertag-sync--get-state-table))) events)\n                               (funcall real-process path counts))))\n                    (force)\n                    (should (equal \"Alpha\" (plist-get (supertag-node-get \"sya-a\") :title)))\n                    (should (= 2 (length (supertag-find-nodes-by-file file))))\n                    (let* ((state (supertag-sync--get-state-table))\n                           (state-disk (bytes state-file))\n                           (old-node (copy-tree (supertag-node-get \"sya-a\")))\n                           (file-before (bytes file)))\n                      (should (gethash file state)) (should state-disk)\n                      (pcase case\n                        (\"mid-process\"\n                         (write-note \"Changed\")\n                         (let ((real (symbol-function 'supertag-sync--reconcile-node)))\n                           (cl-letf (((symbol-function 'supertag-sync--reconcile-node)\n                                      (lambda (props &optional counts)\n                                        (prog1 (funcall real props counts)\n                                          (when (equal \"sya-a\" (plist-get props :id))\n                                            (should supertag--transaction-active)\n                                            (should (equal \"Changed\" (plist-get (supertag-node-get \"sya-a\") :title)))\n                                            (princ \"SYA-INJECT mid-process after-real-reconcile\\n\")\n                                            (error \"SYA mid-process\"))))))\n                             (should (equal '(error \"SYA mid-process\") (should-error (force))))))\n                         (should (equal old-node (supertag-node-get \"sya-a\")))\n                         (should-not (gethash file state))\n                         (should (equal state-disk (bytes state-file)))\n                         (should (string-match-p \"Changed\" (bytes file)))\n                         (should (= 2 (length (supertag-find-nodes-by-file file)))))\n                        (\"state-save\"\n                         (write-note \"Changed\")\n                         (let ((real (symbol-function 'write-region)))\n                           (cl-letf (((symbol-function 'write-region)\n                                      (lambda (start end path &rest args)\n                                        (if (equal path state-file)\n                                            (progn (should-not supertag--transaction-active)\n                                              (princ \"SYA-INJECT state-write after-real-process\\n\")\n                                              (error \"SYA state write\"))\n                                          (apply real start end path args)))))\n                             (should (equal '(error \"SYA state write\") (should-error (force))))))\n                         (should (equal \"Changed\" (plist-get (supertag-node-get \"sya-a\") :title)))\n                         (should (gethash file state)) (should (equal state-disk (bytes state-file))))\n                        (\"status\"\n                         (set-file-times file (time-add (current-time) 10))\n                         (should (equal (list file) (supertag-get-modified-files)))\n                         (call-interactively 'supertag-sync-status)\n                         (dolist (text '(\"Tracked files: 1\" \"Modified files: 1\" \"Auto-sync: INACTIVE\"))\n                           (should (member text messages)))\n                         (should (member (concat \"  - \" file) messages)))\n                        (_\n                         (write-note \"Changed\") (force)\n                         (should (equal \"Changed\" (plist-get (supertag-node-get \"sya-a\") :title)))\n                         (should (eq (car counters-seen) (cadr counters-seen)))\n                         (should (equal 2 (plist-get (car counters-seen) :nodes-created)))\n                         (should (equal 2 (plist-get (car counters-seen) :nodes-updated)))\n                         (should (eq state (supertag-sync--get-state-table)))))\n                      (princ (format \"SYA-ACTUAL case=%s node=%S counts=%S events=%S state=%S disk-change=%S\\n\"\n                                     case (supertag-node-get \"sya-a\") counters-seen events (gethash file state)\n                                     (not (equal file-before (bytes file)))))\n                      (should (cl-every (lambda (event) (and (nth 1 event) (null (nth 2 event)))) events))\n                      (when (getenv \"SYA_WRONG_OUTPUT\")\n                        (should (equal \"Impossible\" (plist-get (supertag-node-get \"sya-a\") :title)))))))\n              (graph 'real-operation))))\n            (princ (format \"SYA-DONE %s/%s\\n\" case phase))))\n      (dolist (s '(supertag-data-directory supertag-db-file supertag-db-backup-directory\n                   supertag-sync-state-file supertag-sync-directories supertag-active-sync-directory))\n        (remove-variable-watcher s 'supertag-config-guard--watch))\n      (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)\n      (dolist (b (buffer-list))\n        (when (buffer-file-name b) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))\n      (mapc #'cancel-timer (append timer-list timer-idle-list)))))\n")

(defun supertag-storage-test--sya-child (case)
  "Exercise CASE with real commands in fresh, temporary source processes."
  (let* ((tmp (make-temp-file "supertag-sya-" t))
         (tree (expand-file-name "tree/" tmp))
         (source (or (getenv "SUPERTAG_SYA_ROOT") supertag-storage-test--source-root))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (process-environment (copy-sequence process-environment))
         (default-directory tmp) (evidence (getenv "SUPERTAG_SYA_EVIDENCE")))
    (unwind-protect
        (progn
          (make-directory tree)
          (dolist (file (directory-files source t "\\.el\\'"))
            (copy-file file (expand-file-name (file-name-nondirectory file) tree)))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (setenv "SYA_TREE" tree) (setenv "SYA_TMP" tmp) (setenv "SYA_CASE" case)
          (dolist (phase (append (when (equal case "generated") '("generate")) '("execute")))
            (setenv "SYA_PHASE" phase)
            (let ((script (expand-file-name (concat phase ".el") tmp)))
              (with-temp-file script (insert supertag-storage-test--sya-program))
              (with-temp-buffer
                (let ((status (apply #'call-process program nil t nil
                                     (append '("-Q" "--batch")
                                             (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                             (list "-L" tree "-l" script)))))
                  (when evidence
                    (let ((out (expand-file-name (concat case "/") evidence)))
                      (make-directory out t)
                      (copy-file script (expand-file-name (concat phase ".el") out) t)
                      (write-region (point-min) (point-max) (expand-file-name (concat phase ".log") out) nil 'silent)
                      (with-temp-file (expand-file-name (concat phase ".exit") out) (insert (format "%s\n" status)))
                      (when (file-exists-p (expand-file-name "autoloads.el" tree))
                        (copy-file (expand-file-name "autoloads.el" tree) (expand-file-name "autoloads.el" out) t))))
                  (princ (buffer-string)) (should (equal 0 status))
                  (should (string-match-p (format "SYA-DONE %s/%s" case phase) (buffer-string))))))))
      (delete-directory tmp t))))

(ert-deftest supertag-storage-sya-projection () (supertag-storage-test--sya-child "projection"))

(ert-deftest supertag-storage-sya-mid-process () (supertag-storage-test--sya-child "mid-process"))

(ert-deftest supertag-storage-sya-state-save () (supertag-storage-test--sya-child "state-save"))

(ert-deftest supertag-storage-sya-status () (supertag-storage-test--sya-child "status"))

(ert-deftest supertag-storage-sya-errors () (supertag-storage-test--sya-child "errors"))

(ert-deftest supertag-storage-sya-generated () (supertag-storage-test--sya-child "generated"))

(ert-deftest supertag-storage-sya-menu () (supertag-storage-test--sya-child "menu"))

(ert-deftest supertag-storage-sya-consumer-concept () (supertag-storage-test--sya-child "consumer-concept"))

(ert-deftest supertag-storage-sya-consumer-ai () (supertag-storage-test--sya-child "consumer-ai"))

(ert-deftest supertag-storage-sya-consumer-mention () (supertag-storage-test--sya-child "consumer-mention"))

(ert-deftest supertag-storage-sya-consumer-embark () (supertag-storage-test--sya-child "consumer-embark"))

(ert-deftest supertag-storage-sya-consumer-supertag () (supertag-storage-test--sya-child "consumer-supertag"))

(defconst supertag-storage-test--sta-program ";;; -*- lexical-binding: t; -*-\n(require 'ert)\n(require 'cl-lib)\n;; Load genuine macro/special providers before reading the lexical test body.\n(pcase (getenv \"STA_CASE\")\n  ((or \"transactions\" \"suppression\") (require 'supertag-core-store))\n  (\"canonical\" (require 'supertag-core-store))\n  (\"notifications\" (require 'supertag-core-store)))\n(let* ((tree (getenv \"STA_TREE\")) (tmp (getenv \"STA_TMP\"))\n       (case (getenv \"STA_CASE\")))\n  (setq user-emacs-directory (file-name-as-directory tmp)\n        default-directory (file-name-as-directory tmp) after-init-time nil\n        load-prefer-newer t)\n  (cl-labels\n      ((entry () (princ (format \"STA-ENTRY %s current\\n\" case)))\n       (light ()\n         (dolist (f '(org supertag-node supertag-tag supertag-query\n                         supertag-core-transform supertag-core-change supertag))\n           (should-not (featurep f))))\n       (owner (symbol file)\n         (should (equal file (file-name-nondirectory (symbol-file symbol 'defun)))))\n       (actual (label value expected)\n         (princ (format \"STA-ACTUAL %s %S\\n\" label value))\n         (should (equal value (if (getenv \"STA_WRONG_OUTPUT\") :impossible expected)))))\n    (cond\n     ((equal case \"owner\")\n      (require 'supertag-core-store) (entry) (light)\n      (owner 'supertag-subscribe\n             \"supertag-core-store.el\")\n      (owner 'supertag-core-state-with-suppressed-notifications\n             \"supertag-core-store.el\")\n      (dolist (f '(supertag-core-state supertag-core-notify))\n        (should-not (featurep f)))\n      (dolist (name '(\"supertag-core-state\" \"supertag-core-notify\"))\n        (should-not (locate-library name))\n        (should-not (cl-find-if (lambda (item)\n                                 (and (stringp (car item))\n                                      (equal (file-name-base (car item)) name))) load-history)))\n      (require 'supertag-core-store)\n      (should (macrop 'supertag-with-transaction)))\n     ((equal case \"light-preset-reload\")\n      ;; Fresh preset cells are intentional caller configuration, not providers.\n      (let ((table (make-hash-table :test 'equal)) (store (make-hash-table :test 'equal)))\n        (set 'supertag--suppress-notifications :preset)\n        (set 'supertag--pending-changes '(:pending))\n        (set 'supertag--transaction-active :active)\n        (set 'supertag--transaction-log '(:log))\n        (set 'supertag--transaction-seen table)\n        (set 'supertag--subscribers table)\n        (set 'supertag--store store)\n        (require 'supertag-core-store)\n        (entry) (light)\n        (require 'supertag-core-store)\n        (should (eq table supertag--subscribers))\n        (should (eq store supertag--store))\n        (should (eq :preset supertag--suppress-notifications))\n        (should (equal '(:pending) supertag--pending-changes))\n        (should (eq :active supertag--transaction-active))\n        (should (equal '(:log) supertag--transaction-log))\n        (should (eq table supertag--transaction-seen))\n        (let* ((calls nil) (advised 0)\n               (callback (lambda (&rest args) (push args calls)))\n               (unsub (supertag-subscribe :probe callback))\n               (advice (lambda (&rest _) (cl-incf advised)))\n               (original (symbol-function 'supertag-emit-event))\n               (subscription-definition (symbol-function 'supertag-subscribe)))\n          (require 'supertag-core-store)\n          (should (eq original (symbol-function 'supertag-emit-event)))\n          (advice-add 'supertag-emit-event :before advice)\n          (unwind-protect\n              (progn\n                (load (expand-file-name \"supertag-core-store.el\" tree) nil nil t)\n                (should-not (eq subscription-definition (symbol-function 'supertag-subscribe)))\n                (should (eq table supertag--subscribers))\n                (should (eq store supertag--store))\n                (should (advice-member-p advice 'supertag-emit-event))\n                (supertag-emit-event :probe 1 2)\n                (should (equal '((1 2)) calls))\n                (should (= 1 advised))\n                (funcall unsub) (funcall unsub)\n                (supertag-emit-event :probe 3)\n                (should (equal '((1 2)) calls))\n                (should (= 2 advised)))\n            (advice-remove 'supertag-emit-event advice)))))\n     ((equal case \"notifications\")\n      (require 'supertag-core-store) (entry)\n      (let* ((supertag--subscribers (make-hash-table :test 'equal))\n             (calls nil)\n             (a (lambda (&rest args) (push (cons 'a args) calls)))\n             (b (lambda (&rest args) (push (cons 'b args) calls)))\n             (unsub (supertag-subscribe :probe a)))\n        (supertag-subscribe :probe a) (supertag-subscribe :probe b)\n        (supertag-notify :probe 1 \"x\")\n        (should (equal '((a 1 \"x\") (a 1 \"x\") (b 1 \"x\")) calls))\n        (funcall unsub) (setq calls nil)\n        (supertag-emit-event :probe 2)\n        (should (equal '((b 2)) calls))\n        (setq calls nil)\n        (supertag-subscribe '(:nodes \"n\") a)\n        (supertag-core-notify-handle-change '(:nodes \"n\") nil '(:title \"A\"))\n        (actual 'path calls '((a (:nodes \"n\") nil (:title \"A\"))))\n        (setq calls nil)\n        (dolist (signal '(error quit))\n          (let ((remove (supertag-subscribe :probe (lambda (&rest _) (signal signal '(\"injected\"))))))\n            (should (eq signal (condition-case cause (progn (supertag-emit-event :probe 9) nil)\n                                 (error (car cause)) (quit (car cause)))))\n            (should-not calls) (funcall remove)))))\n     ((equal case \"suppression\")\n      (require 'supertag-core-store) (entry)\n      (let ((supertag--store nil) (supertag--subscribers (make-hash-table :test 'equal))\n            (supertag--pending-changes nil) (supertag--suppress-notifications nil)\n            (paths nil) (generic nil))\n        (supertag-subscribe '(:nodes \"n\") (lambda (&rest args) (push args paths)))\n        (supertag-subscribe :store-changed (lambda (&rest args) (push args generic)))\n        (supertag-core-state-with-suppressed-notifications\n          (supertag-update '(:nodes \"n\") '(:title \"A\"))\n          (should (= 1 (length supertag--pending-changes)))\n          (should-not paths)\n          (supertag-core-state-with-suppressed-notifications\n            (supertag-update '(:nodes \"n\") '(:title \"B\"))\n            (should (= 1 (length supertag--pending-changes))))\n          (should (= 1 (length supertag--pending-changes))))\n        (should-not supertag--pending-changes) (should-not paths)\n        (should (= 2 (length generic)))\n        (let ((supertag--suppress-notifications t))\n          (supertag-core-notify-handle-change '(:nodes \"n\") '(:title \"B\") '(:title \"C\"))\n          (supertag--notify-batch-changes)\n          (should-not supertag--suppress-notifications))\n        (should (equal '(((:nodes \"n\") (:title \"B\") (:title \"C\"))) paths))\n        (setq paths nil)\n        (should (eq :return (supertag-with-transaction\n                             (supertag-update '(:nodes \"n\") '(:title \"D\")) :return)))\n        (should-not paths) (should-not supertag--pending-changes)\n        (should (= 3 (length generic)))\n        (dolist (failure '(error quit))\n          (should (eq failure (condition-case cause\n                                  (supertag-core-state-with-suppressed-notifications\n                                    (supertag-core-notify-handle-change '(:nodes \"n\") 1 2)\n                                    (signal failure '(\"injected\")))\n                                (error (car cause)) (quit (car cause)))))\n          (should-not supertag--suppress-notifications)\n          (should-not supertag--pending-changes))))\n     ((equal case \"transactions\")\n      (require 'supertag-core-store)\n       (require 'supertag-core-store) (entry)\n      (let ((supertag--store nil) (supertag--subscribers (make-hash-table :test 'equal))\n            (supertag--transaction-active nil) (supertag--transaction-log nil)\n            (supertag--transaction-seen nil) (rolled 0)\n            (supertag-after-transaction-rollback-hook nil))\n        (supertag-store-put-entity :nodes \"old\" '(:id \"old\" :title \"Old\" :tags (\"a\")))\n        (should (equal '(\"old\") (supertag-index-find-node-ids-by-tags '(\"a\"))))\n        (add-hook 'supertag-after-transaction-rollback-hook (lambda () (cl-incf rolled)))\n        (dolist (failure '(error quit))\n          (should\n           (eq failure\n               (condition-case cause\n                   (supertag-with-transaction\n                     (supertag-store-put-entity :nodes \"fresh\" '(:id \"fresh\" :tags (\"b\")))\n                     (supertag-update '(:nodes \"old\") '(:id \"old\" :title \"New\" :tags (\"b\")))\n                     (supertag-with-transaction (supertag-delete '(:nodes \"old\")))\n                     (should (= 2 (length supertag--transaction-log)))\n                     (should (equal '((:nodes \"old\") t (:id \"old\" :title \"Old\" :tags (\"a\")))\n                                    (car supertag--transaction-log)))\n                     (should (equal '((:nodes \"fresh\") nil nil) (cadr supertag--transaction-log)))\n                     (should (equal '(\"fresh\") (supertag-index-find-node-ids-by-tags '(\"b\"))))\n                     (signal failure '(\"injected\")))\n                 (error (car cause)) (quit (car cause)))))\n          (should-not (supertag-store-get-entity :nodes \"fresh\"))\n          (should (equal \"Old\" (plist-get (supertag-store-get-entity :nodes \"old\") :title)))\n          (should (equal '(\"old\") (supertag-index-find-node-ids-by-tags '(\"a\"))))\n          (should-not (supertag-index-find-node-ids-by-tags '(\"b\"))))\n        (should (= 2 rolled))\n        (should (eq :nested (supertag-with-transaction (supertag-with-transaction :nested))))\n        (let ((snapshot (supertag-store-get-collection :nodes)))\n          (should-error (supertag-with-transaction\n                          (supertag-update '(:nodes) '((\"replacement\" . (:id \"replacement\"))))\n                          (supertag-delete '(:nodes)) (error \"rollback collection\")))\n          (should (equal snapshot (supertag-store-get-collection :nodes))))\n        (let* ((supertag--transaction-active t) (supertag--transaction-log nil)\n               (supertag--transaction-seen nil) (value (list :nested (list 1 2))))\n          (supertag--transaction-record-old-value '(:nodes \"copy\") t value)\n          (setcar (cadr value) 9)\n          (should (equal '(:nested (1 2)) (nth 2 (car supertag--transaction-log)))))\n        (actual 'rollback-title (plist-get (supertag-store-get-entity :nodes \"old\") :title) \"Old\")))\n     ((equal case \"canonical\")\n      (require 'supertag-core-store) (entry)\n      (let ((supertag--store nil) (supertag--subscribers (make-hash-table :test 'equal))\n            (supertag-change--subscribers nil) (supertag-change--queue nil)\n            (events nil)\n            (envelope '(:authority :semantic :scope :fact :operation :sta\n                        :cardinality :single :affected ((:collection :nodes :count 1)))))\n        (supertag-change-subscribe (lambda (event) (push (list 'canonical (plist-get event :operation)) events)))\n        (supertag-subscribe :store-changed (lambda (&rest args) (push (cons 'legacy args) events)))\n        (should (eq :committed\n                    (supertag-change-commit envelope\n                      (lambda ()\n                        (supertag-update '(:nodes \"n\") '(:title \"A\"))\n                        (supertag-update '(:nodes \"n\") '(:title \"B\"))\n                        (should-not events) :committed))))\n        (should (equal '((legacy (:nodes \"n\") nil (:title \"B\")) (canonical :sta)) events))\n        (setq events nil)\n        (dolist (failure '(error quit))\n          (should (eq failure\n                      (condition-case cause\n                          (supertag-change-commit envelope\n                            (lambda () (supertag-update '(:nodes \"n\") '(:title \"C\"))\n                              (signal failure '(\"abort\"))))\n                        (error (car cause)) (quit (car cause))))))\n        (should-not events)\n        (should (equal '(:title \"B\") (supertag-get '(:nodes \"n\"))))\n        (let ((cb (lambda (&rest _) nil)))\n          (let ((off (supertag-change-subscribe cb)))\n            (should-error (supertag-subscribe :store-changed cb)) (funcall off))\n          (let ((off (supertag-subscribe :store-changed cb)))\n            (should-error (supertag-change-subscribe cb)) (funcall off)))\n        (let ((supertag-change--suppress-legacy-store-changed t) (other nil))\n          (supertag-subscribe :other (lambda (&rest args) (setq other args)))\n          (supertag-emit-event :store-changed '(:nodes \"n\") nil :hidden)\n          (supertag-emit-event :other :visible)\n          (should-not events) (should (equal '(:visible) other)))))\n     ((equal case \"compiled\")\n      (require 'bytecomp)\n      (let* ((caller (expand-file-name \"sta-caller.el\" tree))\n             (runner (expand-file-name \"sta-compiled-run.el\" tmp))\n             (mods '(\"supertag-core-store.el\")))\n        (with-temp-file caller\n          (insert \";;; -*- lexical-binding: t; -*-\\n\"\n                  (format \"(require '%s)\\n\" 'supertag-core-store)\n                  \"(defun sta-compiled-call ()\\n (let ((observed nil))\\n  (supertag-core-state-with-suppressed-notifications\\n   (setq observed supertag--suppress-notifications)\\n   (supertag-core-notify-handle-change '(:nodes \\\"n\\\") nil '(:title \\\"x\\\"))\\n   (unless (= 1 (length supertag--pending-changes)) (error \\\"pending missing\\\")))\\n  (unless observed (error \\\"special lost\\\"))\\n  (supertag-store-put-entity :nodes \\\"n\\\" '(:title \\\"old\\\"))\\n  (condition-case nil (supertag-with-transaction (supertag-update '(:nodes \\\"n\\\") '(:title \\\"new\\\")) (error \\\"abort\\\")) (error nil))\\n  (unless (equal '(:title \\\"old\\\") (supertag-get '(:nodes \\\"n\\\"))) (error \\\"rollback lost\\\"))\\n  (let ((calls nil)) (let ((off (supertag-subscribe :compiled (lambda (&rest args) (setq calls args)))))\\n   (supertag-notify :compiled 7) (funcall off) (supertag-notify :compiled 8)\\n   (unless (equal '(7) calls) (error \\\"closure lost\\\"))))\\n  :compiled-ok))\\n\"))\n        (dolist (mod (append mods (list \"sta-caller.el\")))\n          (should (byte-compile-file (expand-file-name mod tree)))\n          (should (file-exists-p (concat (expand-file-name mod tree) \"c\")))\n          (princ (format \"STA-COMPILED %s\\n\" (concat (expand-file-name mod tree) \"c\"))))\n        (with-temp-file runner\n          (insert (format \"(setq user-emacs-directory %S default-directory %S after-init-time nil)\\n\" tmp tmp))\n          (insert \"(require 'sta-caller nil t)\\n\"))\n        ;; Explicit compiled paths, genuinely fresh process, no test special declarations.\n        (with-temp-file runner\n          (insert (format \"(setq user-emacs-directory %S default-directory %S after-init-time nil)\\n\" tmp tmp))\n          (dolist (mod (append mods (list \"sta-caller.el\")))\n            (insert (format \"(load %S nil nil t)\\n\" (concat (expand-file-name mod tree) \"c\"))))\n          (insert \"(unless (eq :compiled-ok (sta-compiled-call)) (error \\\"compiled result\\\"))\\n(princ \\\"STA-COMPILED-DONE\\\\n\\\")\\n\"))\n        (entry)\n        (with-temp-buffer\n          (let ((status (call-process (or (getenv \"EMACS_BIN\") (expand-file-name invocation-name invocation-directory)) nil t nil\n                                      \"-Q\" \"--batch\" \"-L\" tree \"-l\" runner)))\n            (when-let* ((evidence (getenv \"SUPERTAG_STA_EVIDENCE\")))\n              (let ((out (expand-file-name \"compiled/artifacts/\" evidence)))\n                (make-directory out t)\n                (dolist (mod (append mods (list \"sta-caller.el\")))\n                  (copy-file (expand-file-name mod tree) (expand-file-name mod out) t)\n                  (copy-file (concat (expand-file-name mod tree) \"c\")\n                             (concat (expand-file-name mod out) \"c\") t))\n                (copy-file runner (expand-file-name \"runtime.el\" out) t)\n                (write-region (point-min) (point-max) (expand-file-name \"runtime.log\" out) nil 'silent)))\n            (princ (buffer-string)) (should (equal 0 status))\n            (should (string-match-p \"STA-COMPILED-DONE\" (buffer-string))))))))\n    (princ (format \"STA-DONE %s\\n\" case))))\n")

(defun supertag-storage-test--sta-child (case)
  "Run CASE against real source in an isolated fresh child process."
  (let* ((tmp (make-temp-file "supertag-sta-" t))
         (tree (expand-file-name "tree/" tmp))
         (source (or (getenv "SUPERTAG_STA_ROOT") supertag-storage-test--source-root))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (process-environment (copy-sequence process-environment))
         (default-directory tmp) (evidence (getenv "SUPERTAG_STA_EVIDENCE")))
    (unwind-protect
        (progn
          (make-directory tree)
          (dolist (f (directory-files source t "\\.el\\'")) (copy-file f (expand-file-name (file-name-nondirectory f) tree)))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (setenv "STA_TREE" tree) (setenv "STA_TMP" tmp) (setenv "STA_CASE" case)
          (let ((script (expand-file-name "child.el" tmp)))
            (with-temp-file script (insert supertag-storage-test--sta-program))
            (with-temp-buffer
              (let ((status (apply #'call-process program nil t nil
                                   (append '("-Q" "--batch")
                                           (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                           (list "-L" tree "-l" script)))))
                (when evidence
                  (let ((out (expand-file-name (concat case "/") evidence)))
                    (make-directory out t)
                    (copy-file script (expand-file-name "child.el" out) t)
                    (write-region (point-min) (point-max) (expand-file-name "child.log" out) nil 'silent)
                    (with-temp-file (expand-file-name "child.exit" out) (insert (format "%s\n" status)))))
                (princ (buffer-string))
                (should (equal 0 status))
                (should (string-match-p (format "STA-ENTRY %s " case) (buffer-string)))
                (should (string-match-p (format "STA-DONE %s" case) (buffer-string)))))))
      (delete-directory tmp t))))

(ert-deftest supertag-storage-sta-owner () (supertag-storage-test--sta-child "owner"))

(ert-deftest supertag-storage-sta-light-preset-reload () (supertag-storage-test--sta-child "light-preset-reload"))

(ert-deftest supertag-storage-sta-notifications () (supertag-storage-test--sta-child "notifications"))

(ert-deftest supertag-storage-sta-suppression () (supertag-storage-test--sta-child "suppression"))

(ert-deftest supertag-storage-sta-transactions () (supertag-storage-test--sta-child "transactions"))

(ert-deftest supertag-storage-sta-canonical () (supertag-storage-test--sta-child "canonical"))

(ert-deftest supertag-storage-sta-compiled () (supertag-storage-test--sta-child "compiled"))

;;; Current Store transaction contracts: cold loading, rollback and compiled calls.
(defconst supertag-storage-test--stb-program ";;; -*- lexical-binding: t; -*-\n(require 'ert)\n(require 'cl-lib)\n(setq user-emacs-directory (file-name-as-directory (getenv \"STB_TMP\"))\n      default-directory user-emacs-directory after-init-time nil load-prefer-newer t)\n;; Cold load observations precede lexical macro test bodies.\n(cond\n ((equal (getenv \"STB_CASE\") \"index-rollback\")\n  (require 'supertag-core-store)\n  (should-not (featurep 'supertag-core-index))\n  (should-not (featurep 'supertag-core-transform))\n  (should (memq 'supertag-index-rebuild-all supertag-after-transaction-rollback-hook))\n  (princ \"STB-STORE-FIRST retired-index=nil transform=nil callback=registered\\n\")\n  (let ((original supertag-after-transaction-rollback-hook))\n    (require 'supertag-core-store)\n    (should (eq original supertag-after-transaction-rollback-hook))))\n ((equal (getenv \"STB_CASE\") \"failures\")\n  (require 'supertag-core-store)))\n(let* ((case (getenv \"STB_CASE\")) (tree (getenv \"STB_TREE\"))\n       (tmp (getenv \"STB_TMP\")))\n  (cond\n   ((equal case \"entry\")\n    (require 'supertag-core-store)\n    (princ \"STB-ENTRY entry\\n\")\n    (dolist (feature '(supertag-core-transform org supertag-core-index supertag-core-change\n                      supertag-node supertag-tag supertag-query supertag))\n      (should-not (featurep feature)))\n    (dolist (symbol '(supertag--transaction-restore-entry supertag--transaction-rollback\n                      supertag--run-transaction-rollback-hooks supertag-with-transaction))\n      (should (fboundp symbol)))\n    (should (boundp 'supertag-after-transaction-rollback-hook))\n    (princ \"STB-OWNER-ENTRY provider-loaded\\n\")\n    (should (equal (file-name-nondirectory (symbol-file 'supertag-with-transaction 'defun))\n                   \"supertag-core-store.el\"))\n    ;; Read/evaluate after the genuine macro provider, no fake cold macro expansion.\n    (should (eq :ok (eval '(supertag-with-transaction\n                            (supertag-store-put-entity :nodes \"n\" '(:title \"A\")) :ok) t)))\n    (should-error (eval '(supertag-with-transaction\n                          (supertag-update '(:nodes \"n\") '(:title \"B\")) (error \"abort\")) t))\n    (should (equal '(:title \"A\") (supertag-get '(:nodes \"n\"))))\n    (require 'supertag-tag)\n    (should (equal '(\"alpha\" \"beta\") (supertag-transform-extract-inline-tags \"#alpha #beta\"))))\n   ((equal case \"reload\")\n    (let ((hook (list (lambda () nil))) (store (make-hash-table :test 'equal))\n          (pending (list :preset)) (calls 0))\n      (set 'supertag-after-transaction-rollback-hook hook)\n      (set 'supertag--store store) (set 'supertag--pending-changes pending)\n      (require 'supertag-core-store)\n      (princ \"STB-ENTRY reload\\n\")\n      (let ((macro (symbol-function 'supertag-with-transaction))\n            (function (symbol-function 'supertag--transaction-rollback))\n            (advice (lambda (&rest _) (cl-incf calls))))\n        (require 'supertag-core-store)\n        (should (eq macro (symbol-function 'supertag-with-transaction)))\n        (should (eq function (symbol-function 'supertag--transaction-rollback)))\n        (load (expand-file-name \"supertag-core-store.el\" tree) nil nil t)\n        (should-not (eq macro (symbol-function 'supertag-with-transaction)))\n        (should-not (eq function (symbol-function 'supertag--transaction-rollback)))\n        (setq macro (symbol-function 'supertag-with-transaction)\n              function (symbol-function 'supertag--transaction-rollback))\n        (advice-add 'supertag--run-transaction-rollback-hooks :before advice)\n        (unwind-protect\n            (progn\n              (require 'supertag-core-store)\n              (should (eq macro (symbol-function 'supertag-with-transaction)))\n              (should (eq function (symbol-function 'supertag--transaction-rollback)))\n              (should (advice-member-p advice 'supertag--run-transaction-rollback-hooks))\n              (should (eq (car supertag-after-transaction-rollback-hook) 'supertag-index-rebuild-all))\n              (should (eq hook (cdr supertag-after-transaction-rollback-hook)))\n              (should (eq store supertag--store))\n              (should (eq pending supertag--pending-changes))\n              (should-error (eval '(supertag-with-transaction\n                                    (supertag-store-put-entity :nodes \"n\" '(:title \"x\"))\n                                    (error \"abort\")) t))\n              (should (= 1 calls))\n              (should-not (supertag-get '(:nodes \"n\"))))\n          (advice-remove 'supertag--run-transaction-rollback-hooks advice)))))\n   ((equal case \"index-rollback\")\n    (princ (format \"STB-ENTRY %s\\n\" case))\n    (should (= 1 (cl-count 'supertag-index-rebuild-all supertag-after-transaction-rollback-hook)))\n    (load (expand-file-name \"supertag-core-store.el\" tree) nil nil t)\n    (require 'supertag-core-store)\n    (should (= 1 (cl-count 'supertag-index-rebuild-all supertag-after-transaction-rollback-hook)))\n    (let ((completed 0) (attempts 0)\n          (advice nil))\n      (setq advice (lambda (original &rest args)\n                     (cl-incf attempts)\n                     (unless (getenv \"STB_OMIT_HOOK\")\n                       (prog1 (apply original args) (cl-incf completed)))))\n      (supertag-store-put-entity :nodes \"n\" '(:id \"n\" :tags (\"old\")))\n      (should (equal '(\"n\") (supertag-index-find-node-ids-by-tags '(\"old\"))))\n      (advice-add 'supertag-index-rebuild-all :around advice)\n      (unwind-protect\n          (progn\n            (should-error\n             (supertag-with-transaction\n               (supertag-update '(:nodes \"n\") '(:id \"n\" :tags (\"new\")))\n               (should (equal '(\"n\") (supertag-index-find-node-ids-by-tags '(\"new\"))))\n               (error \"abort\")))\n            (princ (format \"STB-HOOK-ACTUAL attempts=%s completed=%s\\n\" attempts completed))\n            ;; Check before a lazy query can hide omission of the original callback.\n            (should (= 1 completed)) (should (= 1 attempts))\n            (let ((ids (supertag-index-find-node-ids-by-tags '(\"old\"))))\n              (princ (format \"STB-ACTUAL restored-index=%S\\n\" ids))\n              (should (equal ids (if (getenv \"STB_WRONG_OUTPUT\") '(\"impossible\") '(\"n\")))))\n            (should-not (supertag-index-find-node-ids-by-tags '(\"new\"))))\n        (advice-remove 'supertag-index-rebuild-all advice))))\n   ((equal case \"failures\")\n    (princ \"STB-ENTRY failures\\n\")\n    (let ((events nil)\n          (supertag-after-transaction-rollback-hook nil))\n      (setq supertag-after-transaction-rollback-hook\n            (list (lambda () (push :first events) (error \"first-hook\"))\n                  (lambda () (push :second events) (error \"second-hook\"))\n                  (lambda () (push :third events))))\n      (should (equal '(error \"first-hook\") (supertag--run-transaction-rollback-hooks)))\n      (should (equal '(:third :second :first) events))\n      (setq events nil supertag-after-transaction-rollback-hook\n            (list (lambda () (push :quit events) (signal 'quit nil))\n                  (lambda () (push :unreached events))))\n      (should (eq :quit (condition-case nil (supertag--run-transaction-rollback-hooks) (quit :quit))))\n      (should (equal '(:quit) events))\n      (setq supertag-after-transaction-rollback-hook nil)\n      (supertag-store-put-entity :nodes \"a\" '(:title \"old-a\"))\n      (supertag-store-put-entity :nodes \"b\" '(:title \"old-b\"))\n      (dolist (failure '(error quit))\n        (should (eq failure\n                    (condition-case cause\n                        (supertag-with-transaction\n                          (supertag-update '(:nodes \"a\") '(:title \"changed\"))\n                          (should (eq :nested (supertag-with-transaction :nested)))\n                          (signal failure '(\"body\")))\n                      (error (car cause)) (quit (car cause)))))\n        (should (equal '(:title \"old-a\") (supertag-get '(:nodes \"a\"))))\n        (should-not supertag--transaction-active)\n        (should-not supertag--pending-changes))\n      ;; Original narrow entry restorer executes once, then a later restore fails.\n      (let ((count 0) (hooks 0) (advice nil))\n        (setq supertag-after-transaction-rollback-hook (list (lambda () (cl-incf hooks))))\n        (setq advice (lambda (original entry)\n                       (cl-incf count)\n                       (if (= count 2) (error \"second-restore\") (funcall original entry))))\n        (advice-add 'supertag--transaction-restore-entry :around advice)\n        (unwind-protect\n            (progn\n              (should (equal '(error \"second-restore\")\n                             (condition-case cause\n                                 (supertag-with-transaction\n                                   (supertag-update '(:nodes \"a\") '(:title \"new-a\"))\n                                   (supertag-update '(:nodes \"b\") '(:title \"new-b\"))\n                                   (error \"body\")) (error cause))))\n              (should (= 2 count)) (should (= 0 hooks))\n              (should (equal '(:title \"old-b\") (supertag-get '(:nodes \"b\"))))\n              (should (equal '(:title \"new-a\") (supertag-get '(:nodes \"a\"))))\n              (should-not supertag--transaction-active)\n              (should-not supertag--transaction-log)\n              (should-not supertag--transaction-seen))\n          (advice-remove 'supertag--transaction-restore-entry advice)))))\n   ((equal case \"compiled\")\n    (require 'bytecomp)\n    (let* ((caller (expand-file-name \"stb-caller.el\" tree))\n           (runner (expand-file-name \"compiled-run.el\" tmp))\n           (modules '(\"supertag-core-store.el\" \"stb-caller.el\")))\n      (with-temp-file caller\n        (insert \";;; -*- lexical-binding: t; -*-\\n\" \"(require 'supertag-core-store)\\n\"\n                \"(defun stb-compiled-run ()\\n (let ((seen nil))\\n\"\n                \" (supertag-core-state-with-suppressed-notifications (setq seen supertag--suppress-notifications) (supertag-core-notify-handle-change '(:nodes \\\"n\\\") nil 1) (unless (= 1 (length supertag--pending-changes)) (error \\\"pending\\\")))\\n (unless seen (error \\\"special\\\"))\\n\"\n                \" (supertag-store-put-entity :nodes \\\"n\\\" '(:title \\\"old\\\"))\\n\"\n                \" (dolist (failure '(error quit))\\n (unless (eq failure (condition-case cause (supertag-with-transaction (supertag-update '(:nodes \\\"n\\\") '(:title \\\"new\\\")) (unless (eq :nested (supertag-with-transaction :nested)) (error \\\"nested\\\")) (signal failure '(\\\"body\\\"))) (error (car cause)) (quit (car cause)))) (error \\\"signal\\\"))\\n (unless (equal '(:title \\\"old\\\") (supertag-get '(:nodes \\\"n\\\"))) (error \\\"rollback\\\")))\\n :ok))\\n\"))\n      (dolist (name modules)\n        (should (byte-compile-file (expand-file-name name tree)))\n        (should (file-exists-p (concat (expand-file-name name tree) \"c\"))))\n      (with-temp-file runner\n        (insert (format \"(setq user-emacs-directory %S default-directory %S after-init-time nil)\\n\" tmp tmp))\n        ;; Current actual caller only needs Store, not the parser/Org carrier.\n        (dolist (name modules)\n          (insert (format \"(load %S nil nil t)\\n\" (concat (expand-file-name name tree) \"c\"))))\n        (insert \"(when (or (featurep 'org) (featurep 'supertag-core-transform)) (error \\\"eager parser\\\"))\\n\")\n        (insert \"(unless (eq :ok (stb-compiled-run)) (error \\\"result\\\"))\\n(princ \\\"STB-COMPILED-DONE\\\\n\\\")\\n\"))\n      (princ \"STB-ENTRY compiled\\n\")\n      (with-temp-buffer\n        (let ((status (call-process (or (getenv \"EMACS_BIN\") (expand-file-name invocation-name invocation-directory)) nil t nil \"-Q\" \"--batch\" \"-L\" tree \"-l\" runner)))\n          (when-let* ((evidence (getenv \"SUPERTAG_STB_EVIDENCE\")))\n            (let ((out (expand-file-name \"compiled/artifacts/\" evidence)))\n              (make-directory out t)\n              (dolist (name modules)\n                (dolist (suffix '(\"\" \"c\"))\n                  (copy-file (concat (expand-file-name name tree) suffix)\n                             (concat (expand-file-name name out) suffix) t)))\n              (copy-file runner (expand-file-name \"runtime.el\" out) t)\n              (write-region (point-min) (point-max) (expand-file-name \"runtime.log\" out) nil 'silent)))\n          (princ (buffer-string)) (should (equal 0 status))\n          (should (string-match-p \"STB-COMPILED-DONE\" (buffer-string))))))))\n  (princ (format \"STB-DONE %s\\n\" case)))\n")

(defun supertag-storage-test--stb-child (case)
  "Run CASE against real source in an isolated fresh child process."
  (let* ((tmp (make-temp-file "supertag-stb-" t))
         (tree (expand-file-name "tree/" tmp))
         (source (or (getenv "SUPERTAG_STB_ROOT") supertag-storage-test--source-root))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (process-environment (copy-sequence process-environment))
         (default-directory tmp) (evidence (getenv "SUPERTAG_STB_EVIDENCE")))
    (unwind-protect
        (progn
          (make-directory tree)
          (dolist (f (directory-files source t "\\.el\\'")) (copy-file f (expand-file-name (file-name-nondirectory f) tree)))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (setenv "STB_TREE" tree) (setenv "STB_TMP" tmp) (setenv "STB_CASE" case)
          (let ((script (expand-file-name "child.el" tmp)))
            (with-temp-file script (insert supertag-storage-test--stb-program))
            (with-temp-buffer
              (let ((stbtus (apply #'call-process program nil t nil
                                   (append '("-Q" "--batch")
                                           (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                           (list "-L" tree "-l" script)))))
                (when evidence
                  (let ((out (expand-file-name (concat case "/") evidence)))
                    (make-directory out t)
                    (copy-file script (expand-file-name "child.el" out) t)
                    (write-region (point-min) (point-max) (expand-file-name "child.log" out) nil 'silent)
                    (with-temp-file (expand-file-name "child.exit" out) (insert (format "%s\n" stbtus)))))
                (princ (buffer-string))
                (should (equal 0 stbtus))
                (should (string-match-p (format "STB-ENTRY %s" case) (buffer-string)))
                (should (string-match-p (format "STB-DONE %s" case) (buffer-string)))))))
      (delete-directory tmp t))))

(ert-deftest supertag-storage-stb-entry () (supertag-storage-test--stb-child "entry"))

(ert-deftest supertag-storage-stb-reload () (supertag-storage-test--stb-child "reload"))

(ert-deftest supertag-storage-stb-index-rollback () (supertag-storage-test--stb-child "index-rollback"))

(ert-deftest supertag-storage-stb-failures () (supertag-storage-test--stb-child "failures"))

(ert-deftest supertag-storage-stb-compiled () (supertag-storage-test--stb-child "compiled"))

;;; V2-STORE-C isolated source/compiled ownership and mutation controls.
(defconst supertag-storage-test--stc-program ";;; -*- lexical-binding: t; -*-\n(require 'ert)\n(require 'cl-lib)\n(setq user-emacs-directory (file-name-as-directory (getenv \"STC_TMP\"))\n      default-directory user-emacs-directory after-init-time nil load-prefer-newer t)\n;; Genuine macro provider before reading lexical business bodies; cold entry/preset stay separate.\n(when (member (getenv \"STC_CASE\") '(\"relations\" \"nodes-query\" \"rollback\" \"optional\"))\n  (require 'supertag-core-store)\n  (when (equal (getenv \"SUPERTAG_STC_STAGE\") \"before\") (require 'supertag-core-index)))\n(let* ((case (getenv \"STC_CASE\")) (tree (getenv \"STC_TREE\")) (tmp (getenv \"STC_TMP\"))\n       (before (equal (getenv \"SUPERTAG_STC_STAGE\") \"before\")))\n  (cond\n   ((equal case \"entry\")\n    (require 'supertag-core-store)\n    (princ \"STC-ENTRY entry\\n\")\n    (dolist (f '(org supertag-core-transform supertag-core-index supertag-tag supertag-node\n                supertag-query supertag-automation supertag-link supertag supertag-core-persistence))\n      (should-not (featurep f)))\n    (should (eq (fboundp 'supertag-index-note-store-change) (not before)))\n    (should (eq (boundp 'supertag--index-source-revisions) (not before)))\n    (should (eq (not (null (memq 'supertag-index-rebuild-all supertag-after-transaction-rollback-hook))) (not before)))\n    (supertag-store-put-entity :nodes \"n\" '(:id \"n\" :tags (\"a\")))\n    (if before\n        (progn (require 'supertag-core-index)\n               (should (= 0 (gethash :nodes supertag--index-source-revisions 0))))\n      (should (= 1 (gethash :nodes supertag--index-source-revisions 0))))\n    (princ \"STC-OWNER-ENTRY real-index-provider\\n\")\n    (should (equal (file-name-nondirectory (symbol-file 'supertag-index-find-between 'defun))\n                   (if (and before (not (getenv \"STC_OWNER_RED\"))) \"supertag-core-index.el\" \"supertag-core-store.el\")))\n    (unless before\n      (should-not (locate-library \"supertag-core-index\"))\n      (should-not (cl-find-if (lambda (x) (and (stringp (car x))\n                                              (equal \"supertag-core-index\" (file-name-base (car x))))) load-history)))\n    (should (equal '(\"n\") (supertag-index-find-node-ids-by-tags '(\"a\"))))\n    (let ((token (supertag-index-source-token '(:nodes))))\n      (supertag-store-put-entity :tags \"t\" '(:id \"t\"))\n      (should (supertag-index-source-current-p token '(:nodes)))\n      (supertag-store-put-entity :nodes \"n\" '(:id \"n\" :tags (\"b\")))\n      (should-not (supertag-index-source-current-p token '(:nodes)))\n      (setq token (supertag-index-source-token '(:nodes)))\n      (setq supertag--store (copy-hash-table supertag--store))\n      (should-not (supertag-index-source-current-p token '(:nodes)))))\n   ((equal case \"preset-reload\")\n    (let* ((states '(supertag--index-relations-by-from supertag--index-relations-by-to\n                     supertag--index-relations-source-token supertag--index-nodes-by-tag\n                     supertag--index-node-ranks supertag--index-nodes-source-token\n                     supertag--index-source-revisions))\n           (objects (mapcar (lambda (_) (make-hash-table :test 'equal)) states))\n           (store (make-hash-table :test 'equal)) (custom (list (lambda () nil)))\n           (calls 0) (advice nil))\n      (cl-mapc #'set states objects)\n      (set 'supertag--store store) (set 'supertag-after-transaction-rollback-hook custom)\n      (when before\n        (require 'supertag-core-index)\n        (should-not (featurep 'supertag-core-store))\n        (should-not (featurep 'supertag-core-transform)))\n      (require 'supertag-core-store)\n      (princ \"STC-ENTRY preset-reload\\n\")\n      (cl-mapc (lambda (s o) (should (eq o (symbol-value s)))) states objects)\n      (should (eq store supertag--store))\n      (should (eq (car supertag-after-transaction-rollback-hook) 'supertag-index-rebuild-all))\n      (should (eq custom (cdr supertag-after-transaction-rollback-hook)))\n      (let ((function (symbol-function 'supertag-index-note-store-change)))\n        (require (if before 'supertag-core-index 'supertag-core-store))\n        (should (eq function (symbol-function 'supertag-index-note-store-change)))\n        (load (expand-file-name \"supertag-core-store.el\" tree) nil nil t)\n        (should (eq (eq function (symbol-function 'supertag-index-note-store-change)) before)))\n      (setq advice (lambda (&rest _) (cl-incf calls)))\n      (advice-add 'supertag-index-note-store-change :before advice)\n      (unwind-protect\n          (progn\n            (remove-hook 'supertag-after-transaction-rollback-hook 'supertag-index-rebuild-all)\n            (load (expand-file-name (if before \"supertag-core-index.el\" \"supertag-core-store.el\") tree) nil nil t)\n            (should (= 1 (cl-count 'supertag-index-rebuild-all supertag-after-transaction-rollback-hook)))\n            (should (eq custom (cdr supertag-after-transaction-rollback-hook)))\n            (cl-mapc (lambda (s o) (should (eq o (symbol-value s)))) states objects)\n            (should (advice-member-p advice 'supertag-index-note-store-change))\n            (supertag-store-put-entity :nodes \"n\" '(:id \"n\"))\n            (should (= 1 calls))\n            (should (= 1 (gethash :nodes supertag--index-source-revisions))))\n        (advice-remove 'supertag-index-note-store-change advice))))\n   ((equal case \"relations\")\n    (princ \"STC-ENTRY relations\\n\")\n    (let* ((one (list :id \"r1\" :from \"a\" :to \"b\" :type :document-link))\n           (two (list :id \"r2\" :from \"a\" :to \"c\" :type :other))\n           (rebuilds 0) (counter (lambda (&rest _) (cl-incf rebuilds))))\n      (supertag-store-put-entity :relations \"r1\" one)\n      ;; between genuinely cold ensures, same as from/to.\n      (should (eq one (car (supertag-index-find-between \"a\" \"b\" :document-link))))\n      (should-not (supertag-index-find-between \"a\" \"b\" :other))\n      (should (eq one (car (supertag-index-find-by-to \"b\"))))\n      (advice-add 'supertag-index-rebuild-relations :before counter)\n      (unwind-protect\n          (progn\n            (supertag-store-put-entity :relations \"r2\" two)\n            (supertag-index--on-relation-changed \"r2\" nil nil \"a\" \"c\")\n            (should (eq two (car (supertag-index-find-by-from \"a\" :other))))\n            (should (= 0 rebuilds))\n            ;; Skip one maintenance call: source advances by two, fast path must not claim current.\n            (supertag-store-put-entity :relations \"r3\" '(:id \"r3\" :from \"d\" :to \"e\" :type :other))\n            (supertag-store-put-entity :relations \"r4\" '(:id \"r4\" :from \"f\" :to \"e\" :type :other))\n            (supertag-index--on-relation-changed \"r4\" nil nil \"f\" \"e\")\n            (should (equal '(\"r3\" \"r4\") (sort (mapcar (lambda (x) (plist-get x :id)) (supertag-index-find-by-to \"e\")) #'string<)))\n            (should (= 1 rebuilds))\n            (supertag-store-remove-entity :relations \"r2\")\n            (supertag-index--on-relation-changed \"r2\" \"a\" \"c\" nil nil)\n            (should-not (supertag-index-find-between \"a\" \"c\"))\n            (should (= 1 rebuilds)))\n        (advice-remove 'supertag-index-rebuild-relations counter))))\n   ((equal case \"nodes-query\")\n    (princ \"STC-ENTRY nodes-query\\n\")\n    (supertag-store-put-entity :nodes \"second-name\" '(:id \"second-name\" :tags (\"t\" \"t\") :tag-occurrences (\"alias\")))\n    (supertag-store-put-entity :nodes \"first-name\" '(:id \"first-name\" :tags (\"u\") :tag-occurrences (\"alias\" \"alias\")))\n    (should (equal '(\"second-name\" \"first-name\") (supertag-index-find-node-ids-by-tags '(\"alias\" \"t\" \"alias\"))))\n    (supertag-store-put-entity :tags \"t\" '(:id \"t\" :name \"Task\" :aliases (\"alias\")))\n    (require 'supertag-query)\n    (let ((ids (supertag-index-get-nodes-by-tag \"t\")))\n      (princ (format \"STC-ACTUAL query=%S\\n\" ids))\n      (should (equal ids (if (getenv \"STC_WRONG_OUTPUT\") '(\"impossible\") '(\"second-name\")))))\n    (supertag-update '(:nodes \"first-name\") '(:id \"first-name\" :tags (\"t\")))\n    (should (equal '(\"second-name\" \"first-name\") (supertag-index-get-nodes-by-tag \"t\")))\n    (supertag-update '(:nodes) '((\"replacement\" . (:id \"replacement\" :tags (\"t\")))))\n    (should (equal '(\"replacement\") (supertag-index-get-nodes-by-tag \"t\"))))\n   ((equal case \"rollback\")\n    (princ \"STC-ENTRY rollback\\n\")\n    (should-not (featurep 'supertag-core-transform))\n    (dolist (f '(supertag-tag-index-clear supertag-tag-index-rebuild\n                supertag-automation-clear-rule-index supertag-rebuild-rule-index\n                supertag-schema-clear-global-field-caches supertag-schema-rebuild-global-field-caches))\n      (should-not (fboundp f)))\n    (let* ((calls 0) (counter (lambda (&rest _) (cl-incf calls))))\n      (supertag-store-put-entity :nodes \"n\" '(:id \"n\" :tags (\"old\")))\n      (should (equal '(\"n\") (supertag-index-find-node-ids-by-tags '(\"old\"))))\n      (when (getenv \"STC_OMIT_HOOK\")\n        (remove-hook 'supertag-after-transaction-rollback-hook 'supertag-index-rebuild-all))\n      (advice-add 'supertag-index-rebuild-all :before counter)\n      (unwind-protect\n          (progn\n            (should-error (supertag-with-transaction\n                            (supertag-update '(:nodes \"n\") '(:id \"n\" :tags (\"new\")))\n                            (should (equal '(\"n\") (supertag-index-find-node-ids-by-tags '(\"new\"))))\n                            (error \"abort\")))\n            (princ (format \"STC-HOOK-ACTUAL calls=%s\\n\" calls))\n            (should (= 1 calls))\n            (should (equal '(\"n\") (supertag-index-find-node-ids-by-tags '(\"old\"))))\n            (should-not (supertag-index-find-node-ids-by-tags '(\"new\"))))\n        (advice-remove 'supertag-index-rebuild-all counter))))\n   ((equal case \"optional\")\n    (princ \"STC-ENTRY optional\\n\")\n    ;; These are bounded optional capability probes, not real Tag/Automation business substitutes.\n    (let ((order nil) (fail nil))\n      (cl-letf (((symbol-function 'supertag-tag-index-clear) (lambda () (push 'tag-clear order)))\n                ((symbol-function 'supertag-tag-index-rebuild) (lambda () (push 'tag-build order)))\n                ((symbol-function 'supertag-schema-clear-global-field-caches) (lambda () (push 'schema-clear order)))\n                ((symbol-function 'supertag-schema-rebuild-global-field-caches) (lambda () (push 'schema-build order)))\n                ((symbol-function 'supertag-automation-clear-rule-index) (lambda () (push 'auto-clear order)))\n                ((symbol-function 'supertag-rebuild-rule-index) (lambda () (push 'auto-build order) (when fail (error \"auto-build-failure\")))))\n        (supertag-store-put-entity :nodes \"n\" '(:id \"n\" :tags (\"t\")))\n        (should (eq t (supertag-index-rebuild-all)))\n        (should (equal '(tag-clear schema-clear auto-clear tag-build schema-build auto-build) (reverse order)))\n        (setq order nil fail t)\n        (should (equal '(error \"auto-build-failure\") (condition-case e (supertag-index-rebuild-all) (error e))))\n        (should (equal '(tag-clear schema-clear auto-clear tag-build schema-build auto-build tag-clear schema-clear auto-clear) (reverse order)))\n        (should (= 0 (hash-table-count supertag--index-nodes-by-tag)))\n        (should-not supertag--index-nodes-source-token))))\n   ((equal case \"compiled\")\n    (require 'bytecomp)\n    (let* ((caller (expand-file-name \"stc-caller.el\" tree))\n           (runner (expand-file-name \"runtime.el\" tmp))\n           (modules (append '(\"supertag-core-store.el\") (when before '(\"supertag-core-index.el\")) '(\"stc-caller.el\"))))\n      (with-temp-file caller\n        (insert \";;; -*- lexical-binding: t; -*-\\n(require 'supertag-core-store)\\n\"\n                (if before \"(require 'supertag-core-index)\\n\" \"\")\n                \"(defun stc-compiled-call ()\\n (let ((calls 0) (counter nil))\\n (setq counter (lambda (&rest _) (cl-incf calls)))\\n (supertag-store-put-entity :nodes \\\"n\\\" '(:id \\\"n\\\" :tags (\\\"old\\\")))\\n (unless (equal '(\\\"n\\\") (supertag-index-find-node-ids-by-tags '(\\\"old\\\"))) (error \\\"initial\\\"))\\n (advice-add 'supertag-index-rebuild-all :before counter)\\n (unwind-protect (dolist (failure '(error quit))\\n (condition-case nil (supertag-with-transaction (supertag-update '(:nodes \\\"n\\\") '(:id \\\"n\\\" :tags (\\\"new\\\"))) (supertag-index-find-node-ids-by-tags '(\\\"new\\\")) (signal failure nil)) (error nil) (quit nil))\\n (unless (equal '(\\\"n\\\") (supertag-index-find-node-ids-by-tags '(\\\"old\\\"))) (error \\\"restored\\\")))\\n (advice-remove 'supertag-index-rebuild-all counter))\\n (unless (= calls 2) (error \\\"callback\\\")) :ok))\\n\"))\n      (dolist (n modules) (should (byte-compile-file (expand-file-name n tree))))\n      (with-temp-file runner\n        (insert (format \"(setq user-emacs-directory %S default-directory %S after-init-time nil)\\n\" tmp tmp))\n        (dolist (n modules) (insert (format \"(load %S nil nil t)\\n\" (concat (expand-file-name n tree) \"c\"))))\n        (insert \"(when (or (featurep 'org) (featurep 'supertag-core-transform)) (error \\\"eager\\\"))\\n(unless (eq :ok (stc-compiled-call)) (error \\\"result\\\"))\\n(princ \\\"STC-COMPILED-DONE\\\\n\\\")\\n\"))\n      (princ \"STC-ENTRY compiled\\n\")\n      (with-temp-buffer\n        (let ((status (call-process (or (getenv \"EMACS_BIN\") (expand-file-name invocation-name invocation-directory)) nil t nil \"-Q\" \"--batch\" \"-L\" tree \"-l\" runner)))\n          (when-let* ((evidence (getenv \"SUPERTAG_STC_EVIDENCE\")))\n            (let ((out (expand-file-name \"compiled/artifacts/\" evidence)))\n              (make-directory out t)\n              (dolist (n modules)\n                (dolist (suffix '(\"\" \"c\")) (copy-file (concat (expand-file-name n tree) suffix) (concat (expand-file-name n out) suffix) t)))\n              (copy-file runner (expand-file-name \"runtime.el\" out) t)\n              (write-region (point-min) (point-max) (expand-file-name \"runtime.log\" out) nil 'silent)))\n          (princ (buffer-string)) (should (equal 0 status))\n          (should (string-match-p \"STC-COMPILED-DONE\" (buffer-string))))))))\n  (princ (format \"STC-DONE %s\\n\" case)))\n")

(defun supertag-storage-test--stc-child (case)
  "Run CASE against real source in an isolated fresh child process."
  (let* ((tmp (make-temp-file "supertag-stc-" t))
         (tree (expand-file-name "tree/" tmp))
         (source (or (getenv "SUPERTAG_STC_ROOT") supertag-storage-test--source-root))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (process-environment (copy-sequence process-environment))
         (default-directory tmp) (evidence (getenv "SUPERTAG_STC_EVIDENCE")))
    (unwind-protect
        (progn
          (make-directory tree)
          (dolist (f (directory-files source t "\\.el\\'")) (copy-file f (expand-file-name (file-name-nondirectory f) tree)))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (setenv "STC_TREE" tree) (setenv "STC_TMP" tmp) (setenv "STC_CASE" case)
          (let ((script (expand-file-name "child.el" tmp)))
            (with-temp-file script (insert supertag-storage-test--stc-program))
            (with-temp-buffer
              (let ((stbtus (apply #'call-process program nil t nil
                                   (append '("-Q" "--batch")
                                           (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                           (list "-L" tree "-l" script)))))
                (when evidence
                  (let ((out (expand-file-name (concat case "/") evidence)))
                    (make-directory out t)
                    (copy-file script (expand-file-name "child.el" out) t)
                    (write-region (point-min) (point-max) (expand-file-name "child.log" out) nil 'silent)
                    (with-temp-file (expand-file-name "child.exit" out) (insert (format "%s\n" stbtus)))))
                (princ (buffer-string))
                (should (equal 0 stbtus))
                (should (string-match-p (format "STC-ENTRY %s" case) (buffer-string)))
                (should (string-match-p (format "STC-DONE %s" case) (buffer-string)))))))
      (delete-directory tmp t))))

(ert-deftest supertag-storage-stc-entry () (supertag-storage-test--stc-child "entry"))

(ert-deftest supertag-storage-stc-preset-reload () (supertag-storage-test--stc-child "preset-reload"))

(ert-deftest supertag-storage-stc-relations () (supertag-storage-test--stc-child "relations"))

(ert-deftest supertag-storage-stc-nodes-query () (supertag-storage-test--stc-child "nodes-query"))

(ert-deftest supertag-storage-stc-rollback () (supertag-storage-test--stc-child "rollback"))

(ert-deftest supertag-storage-stc-optional () (supertag-storage-test--stc-child "optional"))

(ert-deftest supertag-storage-stc-compiled () (supertag-storage-test--stc-child "compiled"))

;;; V2-STORE-D isolated source/compiled ownership and mutation controls.
(defconst supertag-storage-test--std-program ";;; -*- lexical-binding: t; -*-\n(require 'ert)\n(require 'cl-lib)\n(setq user-emacs-directory (file-name-as-directory (getenv \"STD_TMP\"))\n      default-directory user-emacs-directory after-init-time nil load-prefer-newer t)\n;; The mutation changes only the copied real suppression binding, never the repo.\n(when (getenv \"STD_OMIT_SUPPRESSION\")\n  (let ((file (expand-file-name (if (equal (getenv \"SUPERTAG_STD_STAGE\") \"before\") \"supertag-core-change.el\" \"supertag-core-store.el\") (getenv \"STD_TREE\"))))\n    (with-temp-buffer\n      (insert-file-contents file)\n      (goto-char (point-min))\n      (unless (search-forward \"(let ((supertag-change--suppress-legacy-store-changed t))\" nil t) (error \"mutation site missing\"))\n      (replace-match \"(let ((supertag-change--suppress-legacy-store-changed nil))\" t t)\n      (write-region (point-min) (point-max) file nil 'silent))))\n;; Real macro/special provider before the lexical bodies; fresh entry/preset remain unloaded.\n(when (member (getenv \"STD_CASE\") '(\"commits\" \"fifo\" \"failures\"))\n  (require 'supertag-core-store)\n  (when (equal (getenv \"SUPERTAG_STD_STAGE\") \"before\") (require 'supertag-core-change)))\n(defun std-envelope (operation)\n  (list :authority :semantic :scope :fact :operation operation :cardinality :batch\n        :affected '((:collection :nodes :count 2)) :metadata '(:label \"bounded\")))\n(let* ((case (getenv \"STD_CASE\")) (tree (getenv \"STD_TREE\")) (tmp (getenv \"STD_TMP\"))\n       (before (equal (getenv \"SUPERTAG_STD_STAGE\") \"before\")))\n  (cond\n   ((equal case \"entry\")\n    (should-not (featurep 'supertag-core-store))\n    (should-not (fboundp 'supertag-change-commit))\n    (should-not (boundp 'supertag-change--suppress-legacy-store-changed))\n    (let* ((cb (lambda (&rest _) nil)) (canonical (list cb))\n           (legacy (make-hash-table :test 'equal)) (other (lambda (&rest _) nil)))\n      (set 'supertag-change--subscribers canonical)\n      (set 'supertag--subscribers legacy)\n      (require 'supertag-core-store)\n      (princ \"STD-ENTRY entry\\n\")\n      (should (eq (fboundp 'supertag-change-commit) (not before)))\n      (should (eq (boundp 'supertag-change--suppress-legacy-store-changed) (not before)))\n      (dolist (f '(org supertag-core-transform supertag-core-change supertag-node supertag-tag supertag-query supertag-link supertag-automation supertag-core-persistence supertag))\n        (should-not (featurep f)))\n      (if before\n          (let ((off (supertag-subscribe :store-changed cb)))\n            (should (eq cb (car (gethash :store-changed legacy)))) (funcall off))\n        (should-error (supertag-subscribe :store-changed cb))\n        (should-not (gethash :store-changed legacy)))\n      (should (eq canonical (symbol-value 'supertag-change--subscribers)))\n      (should (eq legacy supertag--subscribers))\n      (funcall (supertag-subscribe :store-changed other))\n      (funcall (supertag-subscribe :other cb))\n      (when before (require 'supertag-core-change))\n      (princ \"STD-OWNER-ENTRY real-canonical-provider\\n\")\n      (should (equal (file-name-nondirectory (symbol-file 'supertag-change-commit 'defun))\n                     (if (and before (not (getenv \"STD_OWNER_RED\"))) \"supertag-core-change.el\" \"supertag-core-store.el\")))\n      (unless before\n        (should-not (locate-library \"supertag-core-change\"))\n        (should-not (cl-find-if (lambda (x) (and (stringp (car x)) (equal \"supertag-core-change\" (file-name-base (car x))))) load-history)))\n      (should (eq :ok (supertag-change-commit (std-envelope :entry)\n                         (lambda () (supertag-update '(:nodes \"n\") '(:title \"actual\")) :ok))))\n      (should (equal \"actual\" (plist-get (supertag-get '(:nodes \"n\")) :title)))))\n   ((equal case \"commits\")\n    (princ \"STD-ENTRY commits\\n\")\n    (let ((events nil) (record nil) (body-ran nil)\n          (capture (symbol-function 'supertag-change--capture-commit-record)))\n      (supertag-change-subscribe (lambda (event) (push (list 'canonical event) events)))\n      (supertag-subscribe :store-changed (lambda (&rest args) (push (cons 'legacy args) events)))\n      (cl-letf (((symbol-function 'supertag-change--capture-commit-record)\n                 (lambda () (setq record (funcall capture)))))\n        (should (eq :result\n                    (supertag-change-commit (std-envelope :write)\n                      (lambda ()\n                        (supertag-update '(:nodes \"a\") '(:title \"first\"))\n                        (supertag-update '(:nodes \"a\") '(:title \"final\"))\n                        (supertag-update '(:nodes \"b\") '(:title \"second\"))\n                        (princ (format \"STD-SUPPRESSION-ACTUAL during-body=%S\\n\" events))\n                        (should-not events)\n                        :result)))))\n      (setq events (nreverse events))\n      (princ (format \"STD-OUTPUT-ACTUAL kinds=%S\\n\" (mapcar #'car events)))\n      (should (equal (mapcar #'car events) (if (getenv \"STD_WRONG_OUTPUT\") '(impossible) '(canonical legacy legacy))))\n      (should (equal '((:nodes \"a\") (:nodes \"b\")) (mapcar (lambda (e) (plist-get e :path)) record)))\n      (should (equal '(:title \"final\") (plist-get (car record) :new)))\n      (should-not (plist-get (car record) :old-existed-p))\n      (should (equal '((legacy (:nodes \"a\") nil (:title \"final\")) (legacy (:nodes \"b\") nil (:title \"second\"))) (cdr events)))\n      (let ((public (cadar events)))\n        (should (= 1 (plist-get public :version)))\n        (should-not (supertag-change--contains-raw-diff-p public))\n        (should (equal '(:label \"bounded\") (plist-get public :metadata))))\n      (let ((count supertag-change--id-counter) (bridge supertag-change--bridge-commit-count))\n        (setq events nil)\n        (supertag-change-commit (std-envelope :noop) (lambda () (supertag-update '(:nodes \"a\") '(:title \"final\"))))\n        (should-not events) (should (= count supertag-change--id-counter)) (should (= bridge supertag-change--bridge-commit-count)))\n      (dolist (envelope (list nil (plist-put (std-envelope :bad) :authority :invalid)\n                             (plist-put (std-envelope :bad) :metadata '(:old \"raw\"))\n                             (plist-put (std-envelope :bad) :affected (make-list 33 '(:collection :nodes :count 1)))))\n        (should-error (supertag-change-commit envelope (lambda () (setq body-ran t)))))\n      (should-not body-ran)))\n   ((equal case \"fifo\")\n    (princ \"STD-ENTRY fifo\\n\")\n    (let ((trace nil) (outer-id nil) (inner-cause nil) (late-off nil) (duplicates 0))\n      (supertag-change-subscribe\n       (lambda (event)\n         (let ((op (plist-get event :operation)))\n           (push (list 'first op) trace)\n           (if (eq op :outer)\n               (progn\n                 (setq outer-id (plist-get event :change-id))\n                 (setq late-off (supertag-change-subscribe (lambda (e) (push (list 'late (plist-get e :operation)) trace))))\n                 (supertag-change-commit (std-envelope :inner) (lambda () (supertag-update '(:nodes \"inner\") '(:title \"I\")))))\n             (setq inner-cause (plist-get event :causation-id))))))\n      (supertag-change-subscribe (lambda (e) (push (list 'second (plist-get e :operation)) trace)))\n      (supertag-subscribe :store-changed (lambda (path &rest _) (push (list 'legacy (cadr path)) trace)))\n      (supertag-change-commit (std-envelope :outer) (lambda () (supertag-update '(:nodes \"outer\") '(:title \"O\"))))\n      (should (equal '((first :outer) (second :outer) (legacy \"outer\") (first :inner) (second :inner) (late :inner) (legacy \"inner\")) (nreverse trace)))\n      (should (equal outer-id inner-cause)) (should-not supertag-change--queue) (should-not supertag-change--dispatching)\n      (funcall late-off) (funcall late-off)\n      (let* ((cb (lambda (_) (cl-incf duplicates))) (off1 (supertag-change-subscribe cb)) (off2 (supertag-change-subscribe cb)))\n        (should (= 2 (cl-count cb supertag-change--subscribers :test #'eq)))\n        (should-error (supertag-subscribe :store-changed cb))\n        (supertag-change-commit (std-envelope :duplicate) (lambda () (supertag-update '(:nodes \"dup\") '(:title \"D\"))))\n        (should (= duplicates 2))\n        (funcall off1) (should-not (memq cb supertag-change--subscribers)) (funcall off1) (funcall off2)\n        (let ((off (supertag-subscribe :store-changed cb)))\n          (should-error (supertag-change-subscribe cb)) (funcall off) (funcall off)))))\n   ((equal case \"failures\")\n    (princ \"STD-ENTRY failures\\n\")\n    (dolist (failure '(error quit))\n      (should (eq failure (condition-case cause\n                             (supertag-change-commit (std-envelope :body) (lambda () (supertag-update '(:nodes \"body\") '(:title \"lost\")) (signal failure '(\"body\"))))\n                           (error (car cause)) (quit (car cause)))))\n      (should-not (supertag-get '(:nodes \"body\"))) (should-not supertag-change--queue) (should (= 0 supertag-change--bridge-commit-count)))\n    (let ((reached 0))\n      (supertag-change-subscribe (lambda (_) (error \"subscriber-error\")))\n      (supertag-change-subscribe (lambda (_) (cl-incf reached)))\n      (supertag-change-commit (std-envelope :error) (lambda () (supertag-update '(:nodes \"error\") '(:title \"kept\"))))\n      (should (= reached 1)) (should (= 1 (length supertag-change--subscriber-errors))))\n    (dolist (failure '(quit legacy-error))\n      (setq supertag-change--subscribers nil supertag-change--queue nil supertag--subscribers (make-hash-table :test 'equal))\n      (let ((trace nil) (bridge supertag-change--bridge-commit-count))\n        (supertag-change-subscribe\n         (lambda (event)\n           (let ((op (plist-get event :operation)))\n             (push (list 'first op) trace)\n             (when (eq op :outer)\n               (supertag-change-commit (std-envelope :inner) (lambda () (supertag-update (list :nodes (format \"inner-%s\" failure)) '(:title \"inner\"))))\n               (when (eq failure 'quit) (signal 'quit '(\"delivery\")))))))\n        (supertag-change-subscribe (lambda (e) (push (list 'second (plist-get e :operation)) trace)))\n        (supertag-subscribe :store-changed (lambda (path &rest _) (push (list 'legacy (cadr path)) trace) (when (equal (cadr path) \"first\") (error \"legacy-error\"))))\n        (should (eq (if (eq failure 'quit) 'quit 'error)\n                    (condition-case cause\n                        (supertag-change-commit (std-envelope :outer) (lambda () (supertag-update '(:nodes \"first\") (list :title failure)) (supertag-update '(:nodes \"second\") (list :title failure))))\n                      (error (car cause)) (quit (car cause)))))\n        (should (= 1 (length supertag-change--queue))) (should-not supertag-change--dispatching)\n        (should (= (+ bridge 2) supertag-change--bridge-commit-count))\n        (should (equal (if (eq failure 'quit) '((first :outer)) '((first :outer) (second :outer) (legacy \"first\"))) (reverse trace)))\n        (supertag-change--drain)\n        (should-not supertag-change--queue)\n        (should (equal (list (list 'legacy (format \"inner-%s\" failure)) '(second :inner) '(first :inner)) (cl-subseq trace 0 3)))\n        (should (equal (list :title failure) (supertag-get '(:nodes \"second\")))))))\n   ((equal case \"preset-reload\")\n    (let* ((vars '(supertag-change--subscribers supertag-change--queue supertag-change--dispatching\n                   supertag-change--delivering-change-id supertag-change--subscriber-errors supertag-change--id-counter\n                   supertag-change--suppress-legacy-store-changed supertag-change--bridge-commit-count\n                   supertag-change--bridge-total-path-count supertag-change--bridge-last-path-count supertag-change-bridge-debug))\n           (values (mapcar (lambda (s) (list s)) vars)))\n      (cl-mapc #'set vars values)\n      (require 'supertag-core-store)\n      (when before (require 'supertag-core-change))\n      (princ \"STD-ENTRY preset-reload\\n\")\n      (cl-mapc (lambda (s v) (should (eq v (symbol-value s)))) vars values)\n      (let ((cell (symbol-function 'supertag-change-subscribe)))\n        (require (if before 'supertag-core-change 'supertag-core-store)) (should (eq cell (symbol-function 'supertag-change-subscribe)))\n        (load (expand-file-name \"supertag-core-store.el\" tree) nil nil t)\n        (should (eq before (eq cell (symbol-function 'supertag-change-subscribe)))))\n      (cl-mapc (lambda (s v) (should (eq v (symbol-value s)))) vars values)\n      (setq supertag-change--subscribers nil)\n      (let* ((cb (lambda (_) nil)) (off (supertag-change-subscribe cb)) (calls 0) (advice (lambda (&rest _) (cl-incf calls))))\n        (advice-add 'supertag-change-subscribe :before advice)\n        (unwind-protect\n            (progn\n              (load (expand-file-name (if before \"supertag-core-change.el\" \"supertag-core-store.el\") tree) nil nil t)\n              (should (advice-member-p advice 'supertag-change-subscribe))\n              (funcall off) (funcall off) (should-not supertag-change--subscribers)\n              (funcall (supertag-change-subscribe cb)) (should (= 1 calls)))\n          (advice-remove 'supertag-change-subscribe advice)))))\n   ((equal case \"compiled\")\n    (require 'bytecomp)\n    (let* ((caller (expand-file-name \"std-caller.el\" tree)) (runner (expand-file-name \"runtime.el\" tmp))\n           (mods (append '(\"supertag-core-store.el\") (when before '(\"supertag-core-change.el\")) '(\"std-caller.el\"))))\n      (with-temp-file caller\n        (insert \";;; -*- lexical-binding: t; -*-\\n(require 'supertag-core-store)\\n\" (if before \"(require 'supertag-core-change)\\n\" \"\")\n                \"(defun std-compiled-run ()\\n (let ((events nil))\\n (supertag-subscribe :store-changed (lambda (&rest args) (push args events)))\\n (supertag-change-commit '(:authority :semantic :scope :fact :operation :compiled :cardinality :single :affected ((:collection :nodes :count 1))) (lambda () (supertag-update '(:nodes \\\"n\\\") '(:title \\\"kept\\\")) (when events (error \\\"early delivery\\\"))))\\n (unless (= 1 (length events)) (error \\\"event count\\\"))\\n (let ((supertag-change--suppress-legacy-store-changed t)) (supertag-emit-event :store-changed '(:nodes \\\"n\\\") nil :hidden))\\n (unless (= 1 (length events)) (error \\\"special lost\\\"))\\n (dolist (failure '(error quit))\\n (condition-case nil (supertag-change-commit '(:authority :semantic :scope :fact :operation :abort :cardinality :single :affected ((:collection :nodes :count 1))) (lambda () (supertag-update '(:nodes \\\"n\\\") '(:title \\\"lost\\\")) (signal failure nil))) (error nil) (quit nil))\\n (unless (equal '(:title \\\"kept\\\") (supertag-get '(:nodes \\\"n\\\"))) (error \\\"rollback\\\")))\\n (unless (= 1 (length events)) (error \\\"abort delivered\\\")) :ok))\\n\"))\n      (dolist (n mods) (should (byte-compile-file (expand-file-name n tree))))\n      (with-temp-file runner\n        (insert (format \"(setq user-emacs-directory %S default-directory %S after-init-time nil)\\n\" tmp tmp))\n        (dolist (n mods) (insert (format \"(load %S nil nil t)\\n\" (concat (expand-file-name n tree) \"c\"))))\n        (unless before (insert \"(when (or (featurep 'org) (featurep 'supertag-core-transform) (featurep 'supertag-core-change)) (error \\\"eager\\\"))\\n\"))\n        (insert \"(unless (eq :ok (std-compiled-run)) (error \\\"result\\\"))\\n(princ \\\"STD-COMPILED-DONE\\\\n\\\")\\n\"))\n      (princ \"STD-ENTRY compiled\\n\")\n      (with-temp-buffer\n        (let ((status (call-process (or (getenv \"EMACS_BIN\") (expand-file-name invocation-name invocation-directory)) nil t nil \"-Q\" \"--batch\" \"-L\" tree \"-l\" runner)))\n          (when-let* ((evidence (getenv \"SUPERTAG_STD_EVIDENCE\")))\n            (let ((out (expand-file-name \"compiled/artifacts/\" evidence)))\n              (make-directory out t)\n              (dolist (n mods) (dolist (suffix '(\"\" \"c\")) (copy-file (concat (expand-file-name n tree) suffix) (concat (expand-file-name n out) suffix) t)))\n              (copy-file runner (expand-file-name \"runtime.el\" out) t)\n              (write-region (point-min) (point-max) (expand-file-name \"runtime.log\" out) nil 'silent)))\n          (princ (buffer-string)) (should (= 0 status)) (should (string-match-p \"STD-COMPILED-DONE\" (buffer-string))))))))\n  (princ (format \"STD-DONE %s\\n\" case)))\n")

(defun supertag-storage-test--std-child (case)
  "Run CASE against real source in an isolated fresh child process."
  (let* ((tmp (make-temp-file "supertag-std-" t))
         (tree (expand-file-name "tree/" tmp))
         (source (or (getenv "SUPERTAG_STD_ROOT") supertag-storage-test--source-root))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (process-environment (copy-sequence process-environment))
         (default-directory tmp) (evidence (getenv "SUPERTAG_STD_EVIDENCE")))
    (unwind-protect
        (progn
          (make-directory tree)
          (dolist (f (directory-files source t "\\.el\\'")) (copy-file f (expand-file-name (file-name-nondirectory f) tree)))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (setenv "STD_TREE" tree) (setenv "STD_TMP" tmp) (setenv "STD_CASE" case)
          (let ((script (expand-file-name "child.el" tmp)))
            (with-temp-file script (insert supertag-storage-test--std-program))
            (with-temp-buffer
              (let ((stbtus (apply #'call-process program nil t nil
                                   (append '("-Q" "--batch")
                                           (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                           (list "-L" tree "-l" script)))))
                (when evidence
                  (let ((out (expand-file-name (concat case "/") evidence)))
                    (make-directory out t)
                    (copy-file script (expand-file-name "child.el" out) t)
                    (write-region (point-min) (point-max) (expand-file-name "child.log" out) nil 'silent)
                    (with-temp-file (expand-file-name "child.exit" out) (insert (format "%s\n" stbtus)))))
                (princ (buffer-string))
                (should (equal 0 stbtus))
                (should (string-match-p (format "STD-ENTRY %s" case) (buffer-string)))
                (should (string-match-p (format "STD-DONE %s" case) (buffer-string)))))))
      (delete-directory tmp t))))

(ert-deftest supertag-storage-std-entry () (supertag-storage-test--std-child "entry"))

(ert-deftest supertag-storage-std-commits () (supertag-storage-test--std-child "commits"))

(ert-deftest supertag-storage-std-fifo () (supertag-storage-test--std-child "fifo"))

(ert-deftest supertag-storage-std-failures () (supertag-storage-test--std-child "failures"))

(ert-deftest supertag-storage-std-preset-reload () (supertag-storage-test--std-child "preset-reload"))

(ert-deftest supertag-storage-std-compiled () (supertag-storage-test--std-child "compiled"))
