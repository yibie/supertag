;;; supertag-view-provenance-test.el --- Retained provenance contracts -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'supertag-core-store)
(require 'supertag-core-index)
(require 'supertag-ops-field)
(require 'supertag-view-helper)
;; Table is an explicit archive consumer of the shared provenance badge.
(require 'supertag-view-table)

(defmacro supertag-view-provenance-test--isolated (&rest body)
  "Run BODY with an empty Store, cleared indexes and quiet transactions."
  (declare (indent 0) (debug t))
  `(let ((supertag--store (make-hash-table :test #'equal))
         (supertag--transaction-active nil)
         (supertag--transaction-log nil)
         (supertag--subscribers (make-hash-table :test #'eq))
         (supertag-after-operation-hook nil)
         (supertag-ops-deferred-event-errors nil))
     (supertag--ensure-store)
     (supertag-index-clear-all)
     ,@body))

(defun supertag-view-provenance-test--install ()
  "Install one Tag, field and node carrying a content hash."
  (supertag-store-put-entity
   :tags "project"
   '(:id "project" :type :tag :name "Project" :aliases ("project")))
  (supertag-store-put-entity
   :field-definitions "summary"
   '(:id "summary" :name "Summary" :type :string :required nil))
  (supertag-store-put-entity
   :tag-field-associations "project"
   '((:field-id "summary" :order 0)))
  (supertag-store-put-entity
   :nodes "project-1"
   '(:id "project-1" :type :node :title "Alpha" :tags ("project")
     :hash "hash-v1")))

(ert-deftest supertag-view-provenance-backend-retains-agent-metadata ()
  "The retained field backend stores provenance independently of Node View."
  (supertag-view-provenance-test--isolated
    (supertag-view-provenance-test--install)
    (supertag-field-set
     "project-1" "project" "Summary" "agent text"
     '(:origin :agent :model "review-model" :source-hash "hash-v1"))
    (should (equal "agent text"
                   (supertag-field-get "project-1" "project" "Summary")))
    (let ((provenance
           (supertag-field-provenance "project-1" "project" "Summary")))
      (should (eq :agent (plist-get provenance :origin)))
      (should (equal "review-model" (plist-get provenance :model)))
      (should (equal "hash-v1" (plist-get provenance :source-hash))))))

(ert-deftest supertag-view-provenance-backend-confirm-retains-value ()
  "Backend confirmation keeps the value and records human provenance."
  (supertag-view-provenance-test--isolated
    (supertag-view-provenance-test--install)
    (supertag-field-set
     "project-1" "project" "Summary" "agent text"
     '(:origin :agent :source-hash "hash-v1"))
    (supertag-field-confirm "project-1" "project" "Summary")
    (should (equal "agent text"
                   (supertag-field-get "project-1" "project" "Summary")))
    (should (eq :human
                (plist-get
                 (supertag-field-provenance "project-1" "project" "Summary")
                 :origin)))))

(ert-deftest supertag-view-provenance-shared-badge-tracks-staleness ()
  "The shared archive badge distinguishes current and stale agent values."
  (supertag-view-provenance-test--isolated
    (supertag-view-provenance-test--install)
    (supertag-field-set
     "project-1" "project" "Summary" "agent text"
     '(:origin :agent :model "review-model" :source-hash "hash-v1"))
    (should (equal "⟨AI⟩"
                   (substring-no-properties
                    (supertag-view-helper-field-provenance-badge
                     "project-1" "project" "Summary"))))
    (supertag-store-put-entity
     :nodes "project-1"
     '(:id "project-1" :type :node :title "Alpha" :tags ("project")
       :hash "hash-v2"))
    (should (equal "⟨AI · outdated⟩"
                   (substring-no-properties
                    (supertag-view-helper-field-provenance-badge
                     "project-1" "project" "Summary"))))))

(ert-deftest supertag-view-provenance-explicit-table-uses-shared-badge ()
  "Explicit Table rendering retains the shared provenance marker contract."
  (supertag-view-provenance-test--isolated
    (supertag-view-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "plain")
    (should (equal "plain"
                   (supertag-view-table--mark-provenance
                    "plain" "project-1" "project" "Summary")))
    (supertag-field-set
     "project-1" "project" "Summary" "agent text"
     '(:origin :agent :source-hash "hash-v1"))
    (let* ((cell (supertag-view-table--mark-provenance
                  "agent text" "project-1" "project" "Summary"))
           (badge (supertag-view-helper-field-provenance-badge
                   "project-1" "project" "Summary")))
      (should (equal-including-properties
               (substring cell (length "agent text ")) badge)))))

(provide 'supertag-view-provenance-test)
;;; supertag-view-provenance-test.el ends here
