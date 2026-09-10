;;; ownership-fixture.el --- Shared ownership-separation test fixture -*- lexical-binding: t; -*-

;;; Commentary:
;; A deterministic two-file Vault plus the mixed Store state needed by the
;; ownership-separation phase.  Tests can fingerprint Semantic Facts before
;; and after a reindex without mistaking Document Projections for owned data.

;;; Code:

(require 'legacy-field-fixture)
(require 'cl-lib)
(require 'ht)
(require 'supertag-core-store)
(require 'supertag-core-persistence)

(defvar supertag-query-saved nil)
(defvar supertag-sync-directories nil)
(defvar supertag-active-sync-directory nil)

(defconst supertag-ownership-test-semantic-collections
  '(:tags
    :field-definitions
    :tag-field-associations
    :field-values
    :boards
    :automations)
  "Store collections owned by the Semantic Store in the phase fixture.")

(defconst supertag-ownership-test-node-a "ownership-node-a")
(defconst supertag-ownership-test-node-b "ownership-node-b")
(defconst supertag-ownership-test-document-link "ownership-document-link")
(defconst supertag-ownership-test-semantic-edge "ownership-semantic-edge")

(defun supertag-ownership-test-create-vault (directory)
  "Create the deterministic two-file ownership fixture in DIRECTORY.
Return the two absolute file names in stable order."
  (let ((project-file (expand-file-name "project.org" directory))
        (reference-file (expand-file-name "reference.org" directory)))
    (make-directory directory t)
    (with-temp-file project-file
      (insert "* Project Alpha #project\n"
              ":PROPERTIES:\n"
              ":ID:       ownership-node-a\n"
              ":CREATED:  [2026-08-12 Wed 09:00]\n"
              ":END:\n"
              "Keeps one physical [[id:ownership-node-b][Document Link]].\n"))
    (with-temp-file reference-file
      (insert "* Reference Beta #reference\n"
              ":PROPERTIES:\n"
              ":ID:       ownership-node-b\n"
              ":CREATED:  [2026-08-11 Tue 18:00]\n"
              ":END:\n"
              "The second fixture node.\n"))
    (list project-file reference-file)))

(defun supertag-ownership-test-populate-store (files)
  "Reset and populate the phase fixture Store for FILES.
FILES must be the project/reference pair returned by
`supertag-ownership-test-create-vault'."
  (pcase-let ((`(,project-file ,reference-file) files)
              (stamp (encode-time 0 0 9 12 8 2026 t)))
    (setq supertag--store nil
          supertag-query-saved
          '(("active-projects" . "(and (tag \"project\") (field \"status\" \"active\"))")))
    (supertag--ensure-store)
    (supertag-store-put-entity
     :nodes supertag-ownership-test-node-a
     (list :id supertag-ownership-test-node-a :type :node
           :title "Project Alpha" :content "Keeps one physical Document Link."
           :file project-file :position 1 :tags '("project")
           :ref-to (list supertag-ownership-test-node-b)))
    (supertag-store-put-entity
     :nodes supertag-ownership-test-node-b
     (list :id supertag-ownership-test-node-b :type :node
           :title "Reference Beta" :content "The second fixture node."
           :file reference-file :position 1 :tags '("reference")
           :ref-from (list supertag-ownership-test-node-a) :ref-count 1))
    (dolist (tag '(("project" "Project") ("reference" "Reference")))
      (supertag-store-put-entity
       :tags (car tag)
       (list :id (car tag) :type :tag :name (cadr tag) :extends nil
             :fields nil :created-at stamp :modified-at stamp)))
    (supertag-test-legacy-definition
     "status" '(:id "status" :name "Status" :type :enum
                 :options ("active" "done") :default "active"))
    (supertag-store-put-entity
     :tag-field-associations "project" '((:field-id "status" :order 0)))
    (supertag-test-legacy-value supertag-ownership-test-node-a "status" "active")
    ;; :kind/:origin make the ownership distinction explicit in this fixture;
    ;; production migration to these shapes belongs to task007/task015.
    (supertag-store-put-entity
     :relations supertag-ownership-test-document-link
     (list :id supertag-ownership-test-document-link :type :reference
           :from supertag-ownership-test-node-a :to supertag-ownership-test-node-b
           :kind :document-link :origin :org :created-at stamp))
    (supertag-store-put-entity
     :relations supertag-ownership-test-semantic-edge
     (list :id supertag-ownership-test-semantic-edge :type :supports
           :from supertag-ownership-test-node-b :to supertag-ownership-test-node-a
           :kind :semantic-edge :origin :semantic :created-at stamp))
    (supertag-store-put-entity
     :boards "ownership-board"
     (list :id "ownership-board" :title "Ownership Board"
           :node-placements (list (cons supertag-ownership-test-node-a
                                        '(:x 10 :y 20 :width 180 :height 120)))
           :board-edges nil :groups nil :viewport '(:x 0 :y 0 :zoom 1.0)
           :created-at stamp :modified-at stamp))
    (supertag-store-put-entity
     :automations "ownership-automation"
     (list :id "ownership-automation" :name "Mark active projects"
           :trigger :on-tag-added :condition '(:tag "project")
           :actions '((:type :set-field :field "status" :value "active"))
           :enabled t :created-at stamp :modified-at stamp))
    files))

(defun supertag-ownership-test--semantic-relations ()
  "Return only explicitly semantic relations from the live fixture Store."
  (let ((result (ht-create)))
    (maphash
     (lambda (id relation)
       (when (eq (plist-get relation :origin) :semantic)
         (puthash id relation result)))
     (supertag-store-get-collection :relations))
    result))

(defun supertag-ownership-test-semantic-snapshot ()
  "Return a deterministic snapshot of all fixture Semantic Facts.
Document nodes and Document Links are intentionally excluded."
  (let ((snapshot (ht-create)))
    (dolist (collection supertag-ownership-test-semantic-collections)
      (puthash collection (supertag-store-get-collection collection) snapshot))
    (puthash :semantic-edges (supertag-ownership-test--semantic-relations) snapshot)
    ;; Saved queries are Customize-backed until ownership task027 migrates them.
    (puthash :saved-queries supertag-query-saved snapshot)
    (supertag--persistence--canonicalize-value snapshot)))

(defun supertag-ownership-test-semantic-fingerprint (&optional snapshot)
  "Return a SHA-256 fingerprint for SNAPSHOT or the live Semantic Facts."
  (let ((print-circle t)
        (print-escape-nonascii t)
        (print-length nil)
        (print-level nil))
    (secure-hash
     'sha256
     (prin1-to-string
      (or snapshot (supertag-ownership-test-semantic-snapshot))))))

(defmacro supertag-ownership-test-with-vault (&rest body)
  "Run BODY with an isolated, populated ownership fixture Vault."
  (declare (indent 0) (debug t))
  `(let* ((tmp (file-name-as-directory
                (make-temp-file "supertag-ownership-test" t)))
          (vault (expand-file-name "vault" tmp))
          (supertag-data-directory (expand-file-name "data" tmp))
          (supertag-db-file (expand-file-name "supertag-db.el" supertag-data-directory))
          (supertag-db-backup-directory (expand-file-name "backups" supertag-data-directory))
          (supertag-sync-directories (list vault))
          (supertag-active-sync-directory vault)
          (supertag--store nil)
          (supertag-query-saved nil)
          (files (supertag-ownership-test-create-vault vault)))
     (unwind-protect
         (progn
           (supertag-ownership-test-populate-store files)
           ,@body)
       (ignore-errors (delete-directory tmp t)))))

(provide 'ownership-fixture)

;;; ownership-fixture.el ends here
