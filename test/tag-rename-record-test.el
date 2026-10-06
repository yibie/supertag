;;; tag-rename-record-test.el --- Rename keeps the Tag record -*- lexical-binding: t; -*-
;; A Tag is an entity with an opaque stable ID; `:name' and `:aliases' are its
;; occurrence tokens.  Renaming must keep that entity, so aliases, description,
;; parents, child `:extends' edges, node membership and every stored reference
;; survive.  A legacy Tag whose ID is its own name is rekeyed once; a rename
;; onto an existing Tag is a merge that repoints every reference first.
(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-tag)
(require 'supertag-services-sync)
(require 'supertag-automation)

(defconst supertag-tag-rename-record--text
  (concat ":PROPERTIES:\n:ID: file-node\n:END:\n"
          "#+FILETAGS: :old:\n"
          "* Hashed #old\n:PROPERTIES:\n:ID: hashed\n:END:\nbody #old here\n"
          "* Query block\n"
          "#+BEGIN_SRC supertag-query-block\n(tag \"old\")\n#+END_SRC\n")
  "Fixture Org text: FILETAGS, a projected heading and a query block.")

(defmacro supertag-tag-rename-record--vault (&rest body)
  "Run BODY on a temp vault with the record fixture and no leaked view configs."
  (declare (indent 0) (debug t))
  `(supertag-document-test-with-vault
     (with-current-buffer (find-file-noselect file)
       (erase-buffer)
       (insert supertag-tag-rename-record--text)
       (save-buffer))
     (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
     (let ((supertag--view-configs (make-hash-table :test 'eq))
           (supertag-query-saved nil))
       (unwind-protect
           (progn ,@body)
         (when (get-buffer "*Supertag Tag Change*")
           (kill-buffer "*Supertag Tag Change*"))))))

(defun supertag-tag-rename-record--create-old ()
  "Create parent, `old' and a child Tag and return (OLD PARENT CHILD).
`old' carries a stable ID, an alias, a description and a parent."
  (let ((parent (plist-get (supertag-tag-create '(:name "parent")) :id))
        (id (plist-get (supertag-tag-create '(:name "old" :aliases ("oldie"))) :id)))
    (supertag-tag-update id (lambda (tag) (plist-put tag :description "The old one")))
    (supertag-tag-add-parent id parent)
    (let ((child (plist-get (supertag-tag-create (list :name "child"
                                                       :extends (list id)))
                            :id)))
      ;; The Tags exist only now, so bring the fixture headings into their
      ;; projected membership before a test measures it.
      (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
      (list id parent child))))

(defun supertag-tag-rename-record--rule (name token &optional condition)
  "Create an Automation rule NAME triggered by `(:on-tag-added TOKEN)'.
CONDITION is an optional rule condition.  Return the rule ID."
  (plist-get (supertag-automation-create
              (list :name name
                    :trigger (list :on-tag-added token)
                    :condition condition
                    :actions (list (list :action :update-property
                                         :params (list :property :PRIORITY
                                                       :value "A")))))
             :id))

(defun supertag-tag-rename-record--rename (old token &optional on-confirm)
  "Rename OLD to TOKEN with confirmation stubbed; ON-CONFIRM runs first."
  (cl-letf (((symbol-function 'yes-or-no-p)
             (lambda (&rest _) (when on-confirm (funcall on-confirm)) t)))
    (supertag-tag-rename old token)))

(defun supertag-tag-rename-record--rule-by-id (rule-id)
  "Return RULE-ID's stored rule, or nil."
  (supertag-automation-get rule-id))

(defun supertag-tag-rename-record--tags (node-id)
  "Return NODE-ID's projected Tag IDs."
  (plist-get (supertag-node-get node-id) :tags))

(defun supertag-tag-rename-record--preview-text ()
  "Return the current `*Supertag Tag Change*' preview text."
  (with-current-buffer (get-buffer-create "*Supertag Tag Change*")
    (buffer-string)))

;;; --- The plain rename keeps the whole record -----------------------------

(ert-deftest supertag-tag-rename-record-keeps-the-tag-record ()
  "A plain rename changes `:name' only; the rest of the record survives."
  (supertag-tag-rename-record--vault
    (let* ((ids (supertag-tag-rename-record--create-old))
           (id (nth 0 ids))
           (parent (nth 1 ids))
           (child (nth 2 ids))
           (rule (supertag-tag-rename-record--rule "sets priority" "old"))
           ;; A hand-written condition may spell the Tag as a symbol.
           (symbol-rule (supertag-tag-rename-record--rule
                         "symbol condition" "old" '(has-tag old))))
      (should (= 2 (length (supertag-find-nodes-by-tag id))))
      (should (equal id (supertag-tag-rename-record--rename id "new")))
      ;; The same entity, renamed in place.
      (should (supertag-tag-get id))
      (should (equal "new" (plist-get (supertag-tag-get id) :name)))
      (should (equal "The old one" (plist-get (supertag-tag-get id) :description)))
      (should (equal (list parent) (supertag-tag-parents id)))
      (should (member "oldie" (plist-get (supertag-tag-get id) :aliases)))
      (should (equal id (supertag-tag-resolve-occurrence "oldie")))
      (should-not (supertag-tag-resolve-occurrence "old"))
      ;; The child edge and node membership still name the same ID.
      (should (equal (list id) (supertag-tag-parents child)))
      (dolist (node-id '("file-node" "hashed"))
        (should (equal (list id) (supertag-tag-rename-record--tags node-id))))
      ;; A name-based trigger follows the new name; the rule is still there.
      (should (equal (list :on-tag-added "new")
                     (plist-get (supertag-tag-rename-record--rule-by-id rule) :trigger)))
      (should (equal '(has-tag new)
                     (plist-get (supertag-tag-rename-record--rule-by-id symbol-rule)
                                :condition)))
      ;; The text carries the new token everywhere.
      (let ((disk (supertag-document-test-disk file)))
        (should (string-match-p ":new:" disk))
        (should (string-match-p "\\* Hashed #new" disk))
        (should (string-match-p "body #new here" disk))
        (should-not (string-match-p "#old\\b" disk))))))

(ert-deftest supertag-tag-rename-record-keeps-id-references ()
  "An ID-shaped reference needs no rewrite when the ID is kept."
  (supertag-tag-rename-record--vault
    (let* ((id (nth 0 (supertag-tag-rename-record--create-old)))
           (rule (supertag-tag-rename-record--rule "id trigger" id))
           (view (progn (require 'supertag-view-framework)
                        (supertag-view-config-register (list :id 'rename-record
                                                             :valid-for (list id)))
                        'rename-record)))
      (setq supertag-query-saved (list (cons "id-query" (format "(tag \"%s\")" id))))
      (should (equal id (supertag-tag-rename-record--rename id "new")))
      (should (equal (list :on-tag-added id)
                     (plist-get (supertag-tag-rename-record--rule-by-id rule) :trigger)))
      (should (equal (list id)
                     (plist-get (supertag-view-config-get view) :valid-for)))
      (should (equal (format "(tag \"%s\")" id) (cdr (assoc "id-query" supertag-query-saved)))))))

;;; --- Legacy Tag: ID equals the old name ----------------------------------

(ert-deftest supertag-tag-rename-record-rekeys-a-legacy-tag ()
  "A Tag whose ID is its old name gets a fresh ID and every reference follows."
  (supertag-tag-rename-record--vault
    (supertag-tag-create '(:id "legacy" :name "legacy"))
    (with-current-buffer (find-file-noselect file)
      (erase-buffer)
      (insert (concat ":PROPERTIES:\n:ID: file-node\n:END:\n"
                      "#+FILETAGS: :legacy:\n"
                      "* Hashed #legacy\n:PROPERTIES:\n:ID: hashed\n:END:\nbody #legacy here\n"))
      (save-buffer))
    (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
    (let ((child (plist-get (supertag-tag-create (list :name "child" :extends (list "legacy")))
                            :id))
          (rule (supertag-tag-rename-record--rule "legacy rule" "legacy")))
      (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
      (should (= 2 (length (supertag-find-nodes-by-tag "legacy"))))
      (setq supertag-query-saved (list (cons "legacy-query" "(tag \"legacy\")")))
      (require 'supertag-view-framework)
      (supertag-view-config-register (list :id 'legacy-view :valid-for (list "legacy")))
      (let ((new-id (supertag-tag-rename-record--rename "legacy" "renamed")))
        (should new-id)
        (should-not (equal new-id "legacy"))
        (should (supertag-tag-stable-id-p new-id))
        (should-not (supertag-tag-get "legacy"))
        (should-not (supertag-tag-resolve-occurrence "legacy"))
        (should (equal "renamed" (plist-get (supertag-tag-get new-id) :name)))
        ;; Membership moved with the record.
        (dolist (node-id '("file-node" "hashed"))
          (should (equal (list new-id) (supertag-tag-rename-record--tags node-id))))
        (should (equal (list new-id) (supertag-tag-parents child)))
        (should (equal (list :on-tag-added new-id)
                       (plist-get (supertag-tag-rename-record--rule-by-id rule) :trigger)))
        (should (equal (format "(tag \"%s\")" new-id)
                       (cdr (assoc "legacy-query" supertag-query-saved))))
        (should (equal (list new-id)
                       (plist-get (supertag-view-config-get 'legacy-view) :valid-for)))
        (let ((disk (supertag-document-test-disk file)))
          (should (string-match-p ":renamed:" disk))
          (should (string-match-p "\\* Hashed #renamed" disk))
          (should-not (string-match-p "#legacy" disk)))))))

;;; --- Merge ---------------------------------------------------------------

(ert-deftest supertag-tag-rename-record-merge-repoints-references ()
  "A merge repoints child Tags and stored references, then drops the source."
  (supertag-tag-rename-record--vault
    (let* ((ids (supertag-tag-rename-record--create-old))
           (source (nth 0 ids))
           (parent (nth 1 ids))
           (child (nth 2 ids))
           (target (plist-get (supertag-tag-create '(:name "Canonical"
                                                     :aliases ("destination")))
                              :id))
           (rule (supertag-tag-rename-record--rule "source rule" source))
           preview)
      (supertag-tag-update target (lambda (tag) (plist-put tag :description "Target one")))
      (supertag-tag-add-parent target parent)
      (setq supertag-query-saved (list (cons "source-query" (format "(tag \"%s\")" source))))
      (require 'supertag-view-framework)
      (supertag-view-config-register (list :id 'merge-view :valid-for (list source)))
      (should (equal target
                     (supertag-tag-rename-record--rename
                      source "destination"
                      (lambda () (setq preview (supertag-tag-rename-record--preview-text))))))
      (should-not (supertag-tag-get source))
      ;; The target keeps what was its own.
      (should (equal "Canonical" (plist-get (supertag-tag-get target) :name)))
      (should (equal "Target one" (plist-get (supertag-tag-get target) :description)))
      (should (equal (list parent) (supertag-tag-parents target)))
      ;; The source's private tokens now resolve to the target.
      (should (equal target (supertag-tag-resolve-occurrence "oldie")))
      (should (equal target (supertag-tag-resolve-occurrence "old")))
      ;; Child edges and stored references point at the target.
      (should (equal (list target) (supertag-tag-parents child)))
      (should (equal (list :on-tag-added target)
                     (plist-get (supertag-tag-rename-record--rule-by-id rule) :trigger)))
      (should (equal (format "(tag \"%s\")" target)
                     (cdr (assoc "source-query" supertag-query-saved))))
      (should (equal (list target)
                     (plist-get (supertag-view-config-get 'merge-view) :valid-for)))
      (dolist (node-id '("file-node" "hashed"))
        (should (equal (list target) (supertag-tag-rename-record--tags node-id))))
      ;; The preview said what the source loses before anything was written.
      (should (string-match-p "source loses" preview))
      (should (string-match-p "Canonical" (supertag-document-test-disk file))))))

;;; --- Partial rewrite ------------------------------------------------------

(ert-deftest supertag-tag-rename-record-partial-keeps-both-tokens ()
  "An aborted file leaves the Tag resolvable under both tokens."
  (supertag-tag-rename-record--vault
    (let* ((id (nth 0 (supertag-tag-rename-record--create-old)))
           (result (supertag-tag-rename-record--rename
                    id "new"
                    (lambda ()
                      ;; Change the file after the preview so its write aborts.
                      (with-current-buffer (find-file-noselect file)
                        (goto-char (point-max))
                        (insert "Late #old"))))))
      (should result)
      ;; The record is untouched: same entity, still named `old', now holding
      ;; the new token too.
      (should (equal "old" (plist-get (supertag-tag-get id) :name)))
      (should (equal result (supertag-tag-resolve-occurrence "old")))
      (should (equal result (supertag-tag-resolve-occurrence "new")))
      (should (string-match-p "NOT RENAMED" (supertag-tag-rename-record--preview-text)))
      ;; Resuming with the same name finishes the rename.
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-min))
        (while (re-search-forward "Late #old" nil t) (replace-match ""))
        (save-buffer))
      (should (equal result (supertag-tag-rename-record--rename id "new")))
      (should (equal "new" (plist-get (supertag-tag-get id) :name)))
      (should-not (supertag-tag-resolve-occurrence "old")))))

;;; --- Automation must not fire --------------------------------------------

(ert-deftest supertag-tag-rename-record-does-not-fire-tag-triggers ()
  "A tag-trigger rule never runs because of a rename."
  (supertag-tag-rename-record--vault
    (let* ((id (nth 0 (supertag-tag-rename-record--create-old)))
           (fired 0)
           (execute (symbol-function 'supertag-automation-sync--execute-tag-trigger)))
      (supertag-tag-rename-record--rule "rename must not fire" id)
      (cl-letf (((symbol-function 'supertag-automation-sync--execute-tag-trigger)
                 (lambda (node-id tag-name op)
                   (cl-incf fired)
                   (funcall execute node-id tag-name op))))
        (supertag-tag-rename-record--rename id "new")
        (should (= 0 fired))
        ;; Control: the same call is reached for a genuine tag addition.
        (supertag-automation-sync--process-tag-change "hashed" :added id)
        (should (= 1 fired))))))

;;; --- The user's buffer is left alone -------------------------------------

(ert-deftest supertag-tag-rename-record-preserves-point-and-narrowing ()
  "An already open Org buffer keeps point, mark and narrowing."
  (supertag-tag-rename-record--vault
    (let* ((id (nth 0 (supertag-tag-rename-record--create-old)))
           (buffer (find-file-noselect file))
           before-point before-mark)
      (with-current-buffer buffer
        (goto-char (point-min))
        (narrow-to-region (point-min) (save-excursion
                                        (goto-char (point-min))
                                        (search-forward "body #old here")
                                        (line-end-position)))
        (goto-char (+ (point-min) 12))
        (set-mark (point-min))
        (setq before-point (point) before-mark (mark t)))
      (supertag-tag-rename-record--rename id "new")
      (with-current-buffer buffer
        (should (buffer-narrowed-p))
        (should (= before-point (point)))
        (should (= before-mark (mark t)))
        (should (= (point-min) 1)))
      (should-not (buffer-modified-p buffer))
      ;; The query block outside the narrowing was rewritten too.
      (should (string-search "(tag \"new\")" (supertag-document-test-disk file))))))

;;; --- Blockers and buffer hygiene -----------------------------------------

(ert-deftest supertag-tag-rename-record-reports-a-missing-source-file ()
  "A source file that no longer exists is a blocker, not a halfway failure."
  (supertag-tag-rename-record--vault
    (let* ((id (nth 0 (supertag-tag-rename-record--create-old)))
           (missing (expand-file-name "gone.org" (file-name-directory file))))
      (should (equal (list (cons missing "file is missing"))
                     (supertag-tag-rename--blockers id (list (list :file missing))))))))

(ert-deftest supertag-tag-rename-record-kills-only-buffers-it-opened ()
  "A file the command opened is closed; a buffer already open stays open."
  (supertag-tag-rename-record--vault
    (let* ((id (nth 0 (supertag-tag-rename-record--create-old)))
           (other (expand-file-name "other.org" (file-name-directory file)))
           (open-before (find-file-noselect file)))
      (with-temp-file other
        (insert "* Other #old\n:PROPERTIES:\n:ID: other-node\n:END:\nBody\n"))
      (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
      (should-not (get-file-buffer other))
      (supertag-tag-rename-record--rename id "new")
      (should-not (get-file-buffer other))
      (should (eq open-before (get-file-buffer file)))
      (should (string-match-p "\\* Other #new" (supertag-document-test-disk other))))))

;;; --- The preview lists the record and its references ----------------------

(ert-deftest supertag-tag-rename-record-preview-lists-references ()
  "The preview names the record, child Tags, rules, queries and query blocks."
  (supertag-tag-rename-record--vault
    (let* ((ids (supertag-tag-rename-record--create-old))
           (id (nth 0 ids)))
      (supertag-tag-rename-record--rule "preview rule" id)
      (setq supertag-query-saved
            (list (cons "preview-query" (format "(tag \"%s\")" id))))
      (require 'supertag-view-framework)
      (supertag-view-config-register (list :id 'preview-view :valid-for (list id)))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (should-not (supertag-tag-rename id "new")))
      (with-current-buffer "*Supertag Tag Change*"
        (let ((text (buffer-string)))
          (should (string-match-p "RECORD" text))
          (should (string-match-p "carries over" text))
          (should (string-match-p "child Tags (1): child" text))
          (should (string-match-p "preview rule" text))
          (should (string-match-p "saved queries (1): preview-query" text))
          (should (string-match-p "view configs (1)" text))
          ;; The query block is a change, listed with its file and line.
          (should (string-match-p "1 query block(s)" text))
          (should (string-search "12  [query block]  (tag \"old\")" text))
          (should (string-search "node.org\n" text))))
      ;; A declined preview wrote nothing.
      (should (supertag-tag-get id))
      (should (supertag-tag-resolve-occurrence "old"))
      (should-not (supertag-tag-resolve-occurrence "new")))))

;;; --- Supertag query text inside Org files --------------------------------

(defconst supertag-tag-rename-record--mixed-query-text
  (concat ":PROPERTIES:\n:ID: file-node\n:END:\n"
          "* Queries\n"
          "#+BEGIN_SRC supertag-query-block :results raw\n"
          "  ;; keep this comment\n"
          "\t(and (tag \"old\")     ; inline comment\n"
          "\t     (term \"old\")\n"
          "\t     (property \"TITLE\" \"old\")\n"
          "\t     (after \"-30d\"))\n"
          "#+END_SRC\n\n"
          "#+RESULTS:\n| old | untouched |\n\n"
          "#+BEGIN: supertag-query :query \"(or (tag \\\"old\\\") (has-tag \\\"old\\\"))\" :sort modified\n"
          "| old | generated |\n"
          "#+END:\n\n"
          "* Broken\n"
          "#+BEGIN_SRC supertag-query-block\n"
          "(tag \"old\"\n"
          "#+END_SRC\n")
  "A src block, a dynamic block, a `#+RESULTS:' section and a broken block.")

(defconst supertag-tag-rename-record--mixed-query-expected
  (concat ":PROPERTIES:\n:ID: file-node\n:END:\n"
          "* Queries\n"
          "#+BEGIN_SRC supertag-query-block :results raw\n"
          "  ;; keep this comment\n"
          "\t(and (tag \"new\")     ; inline comment\n"
          "\t     (term \"old\")\n"
          "\t     (property \"TITLE\" \"old\")\n"
          "\t     (after \"-30d\"))\n"
          "#+END_SRC\n\n"
          "#+RESULTS:\n| old | untouched |\n\n"
          "#+BEGIN: supertag-query :query \"(or (tag \\\"new\\\") (has-tag \\\"new\\\"))\" :sort modified\n"
          "| old | generated |\n"
          "#+END:\n\n"
          "* Broken\n"
          "#+BEGIN_SRC supertag-query-block\n"
          "(tag \"old\"\n"
          "#+END_SRC\n")
  "The mixed fixture after a successful rename: only the literals changed.")

(defun supertag-tag-rename-record--query-text (token)
  "Return an Org file whose only Tag reference is a query for TOKEN."
  (concat ":PROPERTIES:\n:ID: file-node\n:END:\n"
          "* Queries\n"
          "#+BEGIN_SRC supertag-query-block\n"
          (format "(tag \"%s\")\n" token)
          "#+END_SRC\n"))

(defmacro supertag-tag-rename-record--query-vault (text &rest body)
  "Run BODY on a vault whose fixture file holds TEXT."
  (declare (indent 1) (debug t))
  `(supertag-document-test-with-vault
     (with-current-buffer (find-file-noselect file)
       (erase-buffer)
       (insert ,text)
       (save-buffer))
     (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
     (let ((supertag--view-configs (make-hash-table :test 'eq))
           (supertag-query-saved nil))
       (unwind-protect
           (progn ,@body)
         (when (get-buffer "*Supertag Tag Change*")
           (kill-buffer "*Supertag Tag Change*"))))))

(ert-deftest supertag-tag-rename-record-query-rewrites-src-and-dynamic-blocks ()
  "A src query body and a dynamic block's `:query' are both rewritten."
  (supertag-tag-rename-record--query-vault
      supertag-tag-rename-record--mixed-query-text
    (supertag-tag-create '(:name "old"))
    (supertag-tag-rename-record--rename (supertag-tag-resolve-occurrence "old") "new")
    (let ((disk (supertag-document-test-disk file)))
      (should (string-search "(and (tag \"new\")" disk))
      (should (string-search ":query \"(or (tag \\\"new\\\") (has-tag \\\"new\\\"))\"" disk))
      ;; The broken block is byte-identical and still names the old token.
      (should (string-search "(tag \"old\"\n#+END_SRC" disk)))))

(ert-deftest supertag-tag-rename-record-query-keeps-non-tag-strings ()
  "A term string and a property value equal to the token are not rewritten."
  (supertag-tag-rename-record--query-vault
      supertag-tag-rename-record--mixed-query-text
    (supertag-tag-create '(:name "old"))
    (supertag-tag-rename-record--rename (supertag-tag-resolve-occurrence "old") "new")
    (let ((disk (supertag-document-test-disk file)))
      (should (string-search "(term \"old\")" disk))
      (should (string-search "(property \"TITLE\" \"old\")" disk))
      (should (string-search "(after \"-30d\")" disk)))))

(ert-deftest supertag-tag-rename-record-query-preserves-formatting ()
  "Only the replaced literals change; everything else is byte for byte.
Comments, tabs, the odd indentation, the `#+RESULTS:' table and the generated
rows must all come back exactly as they were written."
  (supertag-tag-rename-record--query-vault
      supertag-tag-rename-record--mixed-query-text
    (supertag-tag-create '(:name "old"))
    (supertag-tag-rename-record--rename (supertag-tag-resolve-occurrence "old") "new")
    (should (equal supertag-tag-rename-record--mixed-query-expected
                   (supertag-document-test-disk file)))))

(ert-deftest supertag-tag-rename-record-query-unparseable-stays-manual ()
  "A block whose query does not read is left alone and listed by hand."
  (supertag-tag-rename-record--query-vault
      supertag-tag-rename-record--mixed-query-text
    (supertag-tag-create '(:name "old"))
    (let ((shown nil))
      (supertag-tag-rename-record--rename
       (supertag-tag-resolve-occurrence "old") "new"
       (lambda () (setq shown (supertag-tag-rename-record--preview-text))))
      (should (string-match-p "not changed, edit by hand" shown))
      (should (string-match-p "node\\.org:[0-9]+" shown)))))

(ert-deftest supertag-tag-rename-record-query-ready-file-counts-as-a-change ()
  "A file with a query block but no tag occurrence is still a change."
  (supertag-tag-rename-record--query-vault
      (supertag-tag-rename-record--query-text "old")
    (supertag-tag-create '(:name "old"))
    (let* ((id (supertag-tag-resolve-occurrence "old"))
           (shown nil))
      (should-not (supertag-find-nodes-by-tag id))
      (supertag-tag-rename-record--rename
       id "new"
       (lambda () (setq shown (supertag-tag-rename-record--preview-text))))
      (should (string-match-p "1 query block(s)" shown))
      (should (string-search "[query block]  (tag \"old\")" shown))
      (should (string-search "(tag \"new\")" (supertag-document-test-disk file))))))

(ert-deftest supertag-tag-rename-record-query-ready-file-blocks-on-draft ()
  "An unsaved query-only file blocks the rename before anything is written."
  (supertag-tag-rename-record--query-vault
      (supertag-tag-rename-record--query-text "old")
    (supertag-tag-create '(:name "old"))
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (insert "Draft"))
    (let ((id (supertag-tag-resolve-occurrence "old")))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (ert-fail "A blocked rename must not confirm"))))
        (should-not (supertag-tag-rename id "new")))
      (should (supertag-tag-resolve-occurrence "old"))
      (should-not (supertag-tag-resolve-occurrence "new"))
      (with-current-buffer "*Supertag Tag Change*"
        (should (string-match-p "BLOCKED" (buffer-string)))
        (should (string-match-p "unsaved changes" (buffer-string)))))))

(ert-deftest supertag-tag-rename-record-query-ready-file-aborts-when-changed ()
  "A query-only file edited after the preview keeps its old query text."
  (supertag-tag-rename-record--query-vault
      (supertag-tag-rename-record--query-text "old")
    (supertag-tag-create '(:name "old"))
    (let ((id (supertag-tag-resolve-occurrence "old")))
      (supertag-tag-rename-record--rename
       id "new"
       (lambda ()
         ;; Change the block itself after the preview; the recorded literal no
         ;; longer matches, so the whole file must be left alone.
         (with-current-buffer (find-file-noselect file)
           (goto-char (point-min))
           (search-forward "(tag \"old\")")
           (replace-match "(tag \"older\")"))))
      (with-current-buffer (find-file-noselect file)
        (should (buffer-modified-p))
        (should (string-search "(tag \"older\")" (buffer-string))))
      ;; The disk still holds the previewed text; nothing was committed.
      (should (string-search "(tag \"old\")" (supertag-document-test-disk file)))
      (should (string-match-p "NOT RENAMED" (supertag-tag-rename-record--preview-text))))))

(ert-deftest supertag-tag-rename-record-query-rekey-follows-the-new-id ()
  "A legacy Tag's ID written in a query follows the fresh ID."
  (supertag-tag-rename-record--query-vault
      (supertag-tag-rename-record--query-text "legacy")
    (supertag-tag-create '(:id "legacy" :name "legacy"))
    (let ((new-id (supertag-tag-rename-record--rename "legacy" "renamed")))
      (should (supertag-tag-stable-id-p new-id))
      (should (string-search (format "(tag \"%s\")" new-id)
                             (supertag-document-test-disk file)))
      (should-not (string-search "(tag \"legacy\")"
                                 (supertag-document-test-disk file))))))

(ert-deftest supertag-tag-rename-record-query-merge-uses-the-canonical-token ()
  "A merged Tag's query text names the target's canonical token."
  (supertag-tag-rename-record--query-vault
      (supertag-tag-rename-record--query-text "old")
    (supertag-tag-create '(:name "old"))
    (supertag-tag-create '(:name "Canonical" :aliases ("destination")))
    (supertag-tag-rename-record--rename
     (supertag-tag-resolve-occurrence "old") "destination")
    (should (string-search "(tag \"Canonical\")"
                           (supertag-document-test-disk file)))
    (should-not (string-search "(tag \"old\")"
                               (supertag-document-test-disk file)))))

(ert-deftest supertag-tag-rename-record-query-counts-in-the-message ()
  "The final message says how many query blocks were rewritten."
  (supertag-tag-rename-record--query-vault
      (supertag-tag-rename-record--query-text "old")
    (supertag-tag-create '(:name "old"))
    (let ((id (supertag-tag-resolve-occurrence "old"))
          (messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (when (stringp format-string)
                     (push (apply #'format format-string args) messages)))))
        (supertag-tag-rename-record--rename id "new"))
      (should (cl-some (lambda (text) (string-match-p "1 query block(s)" text))
                       messages)))))

;;; --- The user's windows after the command ---------------------------------

(defun supertag-tag-rename-record--window-state ()
  "Return (SELECTED-WINDOW-BUFFER CURRENT-BUFFER WINDOW-COUNT)."
  (list (buffer-name (window-buffer (selected-window)))
        (buffer-name (current-buffer))
        (length (window-list))))

(defmacro supertag-tag-rename-record--with-user-window (&rest body)
  "Run BODY with one selected scratch window, then clean the buffer up."
  (declare (indent 0) (debug t))
  `(let ((scratch (get-buffer-create "*rename-window-scratch*")))
     (unwind-protect
         (progn
           (switch-to-buffer scratch)
           (delete-other-windows)
           ,@body)
       (when (buffer-live-p scratch) (kill-buffer scratch)))))

(ert-deftest supertag-tag-rename-record-confirmed-restores-the-user-window ()
  "A completed rename leaves the selected window, buffer and layout alone."
  (supertag-tag-rename-record--vault
    (let ((id (nth 0 (supertag-tag-rename-record--create-old))))
      (supertag-tag-rename-record--with-user-window
        (let ((before (supertag-tag-rename-record--window-state)))
          (supertag-tag-rename-record--rename id "new")
          (should (equal before (supertag-tag-rename-record--window-state)))
          (should (= 1 (length (window-list)))))))))

(ert-deftest supertag-tag-rename-record-declined-restores-the-user-window ()
  "A declined confirmation leaves the selected window, buffer and layout alone."
  (supertag-tag-rename-record--vault
    (let ((id (nth 0 (supertag-tag-rename-record--create-old))))
      (supertag-tag-rename-record--with-user-window
        (let ((before (supertag-tag-rename-record--window-state)))
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
            (should-not (supertag-tag-rename id "new")))
          (should (equal before (supertag-tag-rename-record--window-state)))
          (should (= 1 (length (window-list)))))))))

(ert-deftest supertag-tag-rename-record-blocked-keeps-the-preview-unselected ()
  "A blocked rename shows the preview but never takes focus."
  (supertag-tag-rename-record--vault
    (let ((id (nth 0 (supertag-tag-rename-record--create-old))))
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-max))
        (insert "Unrelated draft"))
      (supertag-tag-rename-record--with-user-window
        (let ((before (supertag-tag-rename-record--window-state)))
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (&rest _) (ert-fail "A blocked rename must not confirm"))))
            (should-not (supertag-tag-rename id "new")))
          ;; The preview is visible for reading, the user's window keeps focus.
          (should (get-buffer-window "*Supertag Tag Change*"))
          (should (equal (car before)
                         (buffer-name (window-buffer (selected-window)))))
          (should (equal (cadr before) (buffer-name (current-buffer))))
          (should (= 2 (length (window-list)))))))))

;;; tag-rename-record-test.el ends here
