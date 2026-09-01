;;; supertag-field-provenance-test.el --- Tests for field-value provenance -*- lexical-binding: t; -*-

;; Covers the provenance sidecar attached to global field values:
;; `:field-provenance' records who asserted a value (:agent or :human),
;; when, from which model, and against which source-node hash.  Values
;; themselves stay scalar in `:field-values'; provenance never changes a
;; value, and a value written without provenance carries none.

(require 'ert)
(require 'cl-lib)
(require 'supertag-core-store)
(require 'supertag-core-schema)
(require 'supertag-core-persistence)
(require 'supertag-ops-field)
(require 'supertag-ops-global-field)
(require 'supertag-ops-tag)
(require 'supertag-ops-node)

(defmacro supertag-field-provenance-test--isolated (&rest body)
  "Run BODY with an empty Store and quiet transaction state."
  (declare (indent 0) (debug t))
  `(let ((supertag--store (make-hash-table :test #'equal))
         (supertag--transaction-active nil)
         (supertag--transaction-log nil)
         (supertag--subscribers (make-hash-table :test #'eq))
         (supertag-after-operation-hook nil)
         (supertag-ops-deferred-event-errors nil))
     (supertag--ensure-store)
     ,@body))

(defun supertag-field-provenance-test--install ()
  "Install one Tag with two global fields and one node carrying a hash."
  (supertag-store-put-entity
   :tags "project"
   '(:id "project" :type :tag :name "Project" :extends nil))
  (supertag-store-put-entity
   :field-definitions "status"
   '(:id "status" :name "Status" :type :options
     :options ("idea" "active" "done") :required nil))
  (supertag-store-put-entity
   :field-definitions "summary"
   '(:id "summary" :name "Summary" :type :string :required nil))
  (supertag-store-put-entity
   :tag-field-associations "project"
   '((:field-id "status" :order 0) (:field-id "summary" :order 1)))
  (supertag-store-put-entity
   :nodes "project-1"
   '(:id "project-1" :type :node :title "One" :tags ("project")
     :hash "hash-v1")))

(defun supertag-field-provenance-test--agent (&optional hash)
  "Return an agent provenance plist bound to HASH (default hash-v1)."
  (list :origin :agent :model "test-model"
        :source-hash (or hash "hash-v1")))

;;; --- Recording ---

(ert-deftest supertag-field-provenance-set-records-agent-provenance ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "An agent wrote this"
                        (supertag-field-provenance-test--agent))
    (let ((record (supertag-field-provenance "project-1" "project" "Summary")))
      (should (eq :agent (plist-get record :origin)))
      (should (equal "test-model" (plist-get record :model)))
      (should (equal "hash-v1" (plist-get record :source-hash)))
      (should (stringp (plist-get record :at)))
      ;; The value itself is untouched by provenance.
      (should (equal "An agent wrote this"
                     (supertag-field-get "project-1" "project" "Summary"))))))

(ert-deftest supertag-field-provenance-set-without-provenance-records-nothing ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "plain")
    (should-not (supertag-field-provenance "project-1" "project" "Summary"))))

(ert-deftest supertag-field-provenance-changed-value-without-provenance-clears-record ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "agent text"
                        (supertag-field-provenance-test--agent))
    ;; A sync/automation/legacy writer that says nothing about origin
    ;; invalidates the agent claim: the stored value is no longer the
    ;; agent's projection.
    (supertag-field-set "project-1" "project" "Summary" "other text")
    (should-not (supertag-field-provenance "project-1" "project" "Summary"))))

(ert-deftest supertag-field-provenance-same-value-without-provenance-keeps-record ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "agent text"
                        (supertag-field-provenance-test--agent))
    (supertag-field-set "project-1" "project" "Summary" "agent text")
    (should (eq :agent (plist-get (supertag-field-provenance
                                   "project-1" "project" "Summary")
                                  :origin)))))

(ert-deftest supertag-field-provenance-same-value-with-provenance-updates-record ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "agent text"
                        (supertag-field-provenance-test--agent "hash-v1"))
    ;; Re-extraction after the node changed: same value, new source hash.
    (supertag-field-set "project-1" "project" "Summary" "agent text"
                        (supertag-field-provenance-test--agent "hash-v2"))
    (should (equal "hash-v2"
                   (plist-get (supertag-field-provenance
                               "project-1" "project" "Summary")
                              :source-hash)))))

(ert-deftest supertag-field-provenance-rejects-unknown-origin-and-keys ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    (should-error (supertag-field-set "project-1" "project" "Summary" "x"
                                      '(:origin :robot)))
    (should-error (supertag-field-set "project-1" "project" "Summary" "x"
                                      '(:origin :agent :flavour "vanilla")))
    (should-error (supertag-field-set "project-1" "project" "Summary" "x"
                                      '(:model "m")))
    ;; Nothing was written by the failed calls.
    (should-not (supertag-field-get "project-1" "project" "Summary"))
    (should-not (supertag-field-provenance "project-1" "project" "Summary"))))

(ert-deftest supertag-field-provenance-normalizes-previous-field-value ()
  "`:previous' is provenance data and may carry any valid field shape."
  (let ((record
         (supertag-field-normalize-provenance
          '(:origin :agent :model "m" :previous ("old" "values")))))
    (should (equal '("old" "values") (plist-get record :previous)))
    (should (plist-member record :previous))))

(ert-deftest supertag-field-provenance-set-many-accepts-provenance ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    (supertag-field-set-many
     "project-1"
     (list (list :tag "project" :field "Status" :value "active"
                 :provenance (supertag-field-provenance-test--agent))
           (list :tag "project" :field "Summary" :value "human")))
    (should (eq :agent (plist-get (supertag-field-provenance
                                   "project-1" "project" "Status")
                                  :origin)))
    (should-not (supertag-field-provenance "project-1" "project" "Summary"))))

;;; --- Confirmation and staleness ---

(ert-deftest supertag-field-provenance-confirm-upgrades-to-human ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    (supertag-field-set "project-1" "project" "Status" "active"
                        (supertag-field-provenance-test--agent))
    (let ((record (supertag-field-confirm "project-1" "project" "Status")))
      (should (eq :human (plist-get record :origin)))
      (should (stringp (plist-get record :at)))
      (should-not (plist-get record :model)))
    (should (eq :human (plist-get (supertag-field-provenance
                                   "project-1" "project" "Status")
                                  :origin)))
    ;; Confirming never touches the value.
    (should (equal "active" (supertag-field-get "project-1" "project" "Status")))))

(ert-deftest supertag-field-provenance-confirm-requires-a-value ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    (should-error (supertag-field-confirm "project-1" "project" "Status"))))

(ert-deftest supertag-field-provenance-stale-p-follows-node-hash ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "text"
                        (supertag-field-provenance-test--agent "hash-v1"))
    (should-not (supertag-field-stale-p "project-1" "project" "Summary"))
    ;; The document changed underneath the agent's extraction.
    (supertag-store-put-entity
     :nodes "project-1"
     '(:id "project-1" :type :node :title "One" :tags ("project")
       :hash "hash-v2"))
    (should (supertag-field-stale-p "project-1" "project" "Summary"))
    ;; Human confirmation turns the projection into a fact.
    (supertag-field-confirm "project-1" "project" "Summary")
    (should-not (supertag-field-stale-p "project-1" "project" "Summary"))))

(ert-deftest supertag-field-provenance-stale-p-is-nil-without-hashes ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    ;; Agent record without a source hash: nothing to compare.
    (supertag-field-set "project-1" "project" "Summary" "text"
                        '(:origin :agent :model "m"))
    (should-not (supertag-field-stale-p "project-1" "project" "Summary"))
    ;; Plain value: never stale.
    (supertag-field-set "project-1" "project" "Status" "done")
    (should-not (supertag-field-stale-p "project-1" "project" "Status"))))

;;; --- Lifecycle: removal, deletion, rollback, persistence ---

(ert-deftest supertag-field-provenance-remove-clears-record ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "text"
                        (supertag-field-provenance-test--agent))
    (supertag-field-remove "project-1" "project" "Summary")
    (should-not (supertag-field-provenance "project-1" "project" "Summary"))))

(ert-deftest supertag-field-provenance-node-delete-drops-bucket ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "text"
                        (supertag-field-provenance-test--agent))
    (supertag-node-delete "project-1")
    (should-not (gethash "project-1"
                         (supertag-store-get-collection :field-provenance)))))

(ert-deftest supertag-field-provenance-global-field-delete-prunes-records ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "text"
                        (supertag-field-provenance-test--agent))
    (supertag-global-field-delete "summary" t)
    (should-not (supertag-store-get-field-provenance "project-1" "summary"))))

(ert-deftest supertag-field-provenance-rollback-restores-record ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "before"
                        (supertag-field-provenance-test--agent "hash-v1"))
    (should-error
     (supertag-with-transaction
       (supertag-field-set "project-1" "project" "Summary" "after"
                           (supertag-field-provenance-test--agent "hash-v2"))
       (error "boom")))
    (should (equal "before" (supertag-field-get "project-1" "project" "Summary")))
    (should (equal "hash-v1"
                   (plist-get (supertag-field-provenance
                               "project-1" "project" "Summary")
                              :source-hash)))))

(ert-deftest supertag-field-provenance-survives-canonical-persistence ()
  (supertag-field-provenance-test--isolated
    (supertag-field-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "text"
                        (supertag-field-provenance-test--agent))
    (let* ((dir (make-temp-file "supertag-provenance-" t))
           (file (expand-file-name "supertag-db.el" dir))
           (supertag-db-verify-after-save t))
      (unwind-protect
          (progn
            (supertag--persistence-write-store-atomically file)
            (let ((supertag--store
                   (supertag--persistence--canonicalize-store-root
                    (supertag--coerce-store-table
                     (supertag--persistence--try-read-store file)))))
              (supertag--ensure-store)
              (should (equal "text"
                             (supertag-field-get "project-1" "project" "Summary")))
              (let ((record (supertag-field-provenance
                             "project-1" "project" "Summary")))
                (should (eq :agent (plist-get record :origin)))
                (should (equal "hash-v1" (plist-get record :source-hash))))))
        (delete-directory dir t)))))

(provide 'supertag-field-provenance-test)
;;; supertag-field-provenance-test.el ends here
