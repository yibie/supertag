;;; supertag-view-provenance-test.el --- Tests for provenance in views -*- lexical-binding: t; -*-

;; Covers how Node View and Table View surface field-value provenance:
;; the ⟨AI⟩ / ⟨AI · outdated⟩ badge on a field line, the Table View cell
;; marker, the `c' confirmation command, the `x' rejection command, batch
;; review, and human provenance recorded by interactive edits.

(require 'ert)
(require 'cl-lib)
(require 'supertag-core-store)
(require 'supertag-core-index)
(require 'supertag-ops-field)
(require 'supertag-api)
(require 'supertag-view-node)
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
  "Install one Tag with reviewable fields and one node carrying a hash."
  (supertag-store-put-entity
   :tags "project"
   '(:id "project" :type :tag :name "Project" :aliases ("project") :extends nil))
  (supertag-store-put-entity
   :field-definitions "summary"
   '(:id "summary" :name "Summary" :type :string :required nil))
  (supertag-store-put-entity
   :field-definitions "status"
   '(:id "status" :name "Status" :type :string :required nil))
  (supertag-store-put-entity
   :tag-field-associations "project"
   '((:field-id "summary" :order 0) (:field-id "status" :order 1)))
  (supertag-store-put-entity
   :nodes "project-1"
   '(:id "project-1" :type :node :title "Alpha" :tags ("project")
     :hash "hash-v1")))

(defun supertag-view-provenance-test--tag-block ()
  "Render the project tag block for project-1 and return the buffer text."
  (with-temp-buffer
    (supertag-view-node--insert-tag-block
     "project" (supertag-tag-get-all-fields "project") "project-1")
    (buffer-string)))

;;; --- Node View badge ---

(ert-deftest supertag-view-provenance-node-view-badges-agent-values ()
  (supertag-view-provenance-test--isolated
    (supertag-view-provenance-test--install)
    ;; Plain value: no badge.
    (supertag-field-set "project-1" "project" "Summary" "plain")
    (should-not (string-match-p "⟨AI" (supertag-view-provenance-test--tag-block)))
    ;; Agent value bound to the current hash: ⟨AI⟩.
    (supertag-field-set "project-1" "project" "Summary" "agent text"
                        '(:origin :agent :model "m" :source-hash "hash-v1"))
    (let ((text (supertag-view-provenance-test--tag-block)))
      (should (string-match-p "agent text ⟨AI⟩" text))
      (should-not (string-match-p "outdated" text)))
    ;; The node text changed since: outdated.
    (supertag-store-put-entity
     :nodes "project-1"
     '(:id "project-1" :type :node :title "Alpha" :tags ("project")
       :hash "hash-v2"))
    (should (string-match-p "⟨AI · outdated⟩"
                            (supertag-view-provenance-test--tag-block)))
    ;; Confirmed: badge gone, value kept.
    (supertag-field-confirm "project-1" "project" "Summary")
    (let ((text (supertag-view-provenance-test--tag-block)))
      (should (string-match-p "agent text" text))
      (should-not (string-match-p "⟨AI" text)))))

(ert-deftest supertag-view-provenance-badge-stays-outside-value-column ()
  (supertag-view-provenance-test--isolated
    (supertag-view-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "agent text"
                        '(:origin :agent :source-hash "hash-v1"))
    (with-temp-buffer
      (supertag-view-node--insert-tag-block
       "project" (supertag-tag-get-all-fields "project") "project-1")
      (goto-char (point-min))
      (search-forward "⟨AI⟩")
      ;; The badge is not part of the editable value column.
      (should-not (get-text-property (1- (point)) 'supertag-value-column))
      (should (string-match-p
               "x rejects"
               (get-text-property (1- (point)) 'help-echo)))
      (search-backward "agent text")
      (should (get-text-property (point) 'supertag-value-column)))))

;;; --- Confirmation command ---

(ert-deftest supertag-view-provenance-confirm-at-point-upgrades-value ()
  (supertag-view-provenance-test--isolated
    (supertag-view-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "agent text"
                        '(:origin :agent :source-hash "hash-v1"))
    (let (refreshed)
      (cl-letf (((symbol-function 'supertag-view-node--refresh-view)
                 (lambda () (setq refreshed t)))
                ((symbol-function 'supertag-view-node--goto-field)
                 (lambda (&rest _) t)))
        (with-temp-buffer
          (setq-local supertag-view-node--current-node-id "project-1")
          (supertag-view-node--insert-tag-block
           "project" (supertag-tag-get-all-fields "project") "project-1")
          (goto-char (point-min))
          (search-forward "agent text")
          (supertag-view-node-confirm-field-at-point)
          (should refreshed)
          (should (eq :human (plist-get (supertag-field-provenance
                                         "project-1" "project" "Summary")
                                        :origin)))
          (should (equal "agent text"
                         (supertag-field-get "project-1" "project" "Summary")))
          ;; Confirming again is a no-op.
          (supertag-view-node-confirm-field-at-point)
          (should (eq :human (plist-get (supertag-field-provenance
                                         "project-1" "project" "Summary")
                                        :origin))))))))

(ert-deftest supertag-view-provenance-confirm-outside-a-field-does-nothing ()
  (supertag-view-provenance-test--isolated
    (supertag-view-provenance-test--install)
    (with-temp-buffer
      (setq-local supertag-view-node--current-node-id "project-1")
      (insert "no context here")
      (goto-char (point-min))
      (supertag-view-node-confirm-field-at-point)
      (should-not (supertag-field-provenance "project-1" "project" "Summary")))))

;;; --- Rejection command ---

(ert-deftest supertag-view-provenance-reject-at-point-restores-previous-value ()
  (supertag-view-provenance-test--isolated
    (supertag-view-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "before")
    ;; Exercise the real agent producer.  Rejection must be able to restore
    ;; the human value without a test-only provenance write.
    (supertag-api-set-field "project-1" "Summary" "agent text"
                            :origin :agent :source-hash "hash-v1")
    (let (refreshed)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                ((symbol-function 'supertag-view-node--refresh-view)
                 (lambda () (setq refreshed t)))
                ((symbol-function 'supertag-view-node--goto-field)
                 (lambda (&rest _) t)))
        (with-temp-buffer
          (setq-local supertag-view-node--current-node-id "project-1")
          (supertag-view-node--insert-tag-block
           "project" (supertag-tag-get-all-fields "project") "project-1")
          (goto-char (point-min))
          (search-forward "agent text")
          (supertag-view-node-reject-field-at-point)))
      (should refreshed)
      (should (equal "before"
                     (supertag-field-get "project-1" "project" "Summary")))
      (should (eq :human
                  (plist-get (supertag-field-provenance
                              "project-1" "project" "Summary")
                             :origin))))))

(ert-deftest supertag-view-provenance-reject-at-point-clears-without-previous ()
  (supertag-view-provenance-test--isolated
    (supertag-view-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "agent text"
                        '(:origin :agent :source-hash "hash-v1"))
    (let (refreshed)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                ((symbol-function 'supertag-view-node--refresh-view)
                 (lambda () (setq refreshed t)))
                ((symbol-function 'supertag-view-node--goto-field)
                 (lambda (&rest _) t)))
        (with-temp-buffer
          (setq-local supertag-view-node--current-node-id "project-1")
          (supertag-view-node--insert-tag-block
           "project" (supertag-tag-get-all-fields "project") "project-1")
          (goto-char (point-min))
          (search-forward "agent text")
          (supertag-view-node-reject-field-at-point)))
      (should refreshed)
      (should-not (supertag-field-get "project-1" "project" "Summary"))
      (should-not (supertag-field-provenance
                   "project-1" "project" "Summary")))))

(ert-deftest supertag-view-provenance-reject-cancel-keeps-agent-value ()
  (supertag-view-provenance-test--isolated
    (supertag-view-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "agent text"
                        '(:origin :agent :source-hash "hash-v1"))
    (let (refreshed)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
                ((symbol-function 'supertag-view-node--refresh-view)
                 (lambda () (setq refreshed t))))
        (with-temp-buffer
          (setq-local supertag-view-node--current-node-id "project-1")
          (supertag-view-node--insert-tag-block
           "project" (supertag-tag-get-all-fields "project") "project-1")
          (goto-char (point-min))
          (search-forward "agent text")
          (supertag-view-node-reject-field-at-point)))
      (should-not refreshed)
      (should (equal "agent text"
                     (supertag-field-get "project-1" "project" "Summary")))
      (should (eq :agent
                  (plist-get (supertag-field-provenance
                              "project-1" "project" "Summary")
                             :origin))))))

;;; --- Batch review and discoverability ---

(ert-deftest supertag-view-provenance-review-confirms-and-rejects-in-order ()
  (supertag-view-provenance-test--isolated
    (supertag-view-provenance-test--install)
    (supertag-field-set "project-1" "project" "Status" "agent status"
                        '(:origin :agent :source-hash "hash-v1"))
    (supertag-field-set "project-1" "project" "Summary" "agent summary"
                        '(:origin :agent :source-hash "hash-v1"))
    (supertag-store-put-field-provenance
     "project-1" "summary"
     (plist-put (supertag-field-provenance
                 "project-1" "project" "Summary")
                :previous "old summary"))
    (let ((choices '(?c ?x))
          refreshed)
      (cl-letf (((symbol-function 'read-char-choice)
                 (lambda (&rest _) (pop choices)))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                ((symbol-function 'supertag-view-node--refresh-view)
                 (lambda () (setq refreshed t))))
        (with-temp-buffer
          (setq-local supertag-view-node--current-node-id "project-1")
          (let ((result (supertag-view-node-review-ai-fields)))
            (should (equal 1 (plist-get result :confirmed)))
            (should (equal 1 (plist-get result :rejected)))
            (should-not (plist-get result :errors)))))
      (should refreshed)
      (should (eq :human
                  (plist-get (supertag-field-provenance
                              "project-1" "project" "Status")
                             :origin)))
      (should (equal "old summary"
                     (supertag-field-get "project-1" "project" "Summary"))))))

(ert-deftest supertag-view-provenance-review-all-confirms-every-agent-field ()
  (supertag-view-provenance-test--isolated
    (supertag-view-provenance-test--install)
    (dolist (field '("Status" "Summary"))
      (supertag-field-set "project-1" "project" field "agent"
                          '(:origin :agent :source-hash "hash-v1")))
    (let (refreshed)
      (cl-letf (((symbol-function 'read-char-choice) (lambda (&rest _) ?a))
                ((symbol-function 'supertag-view-node--refresh-view)
                 (lambda () (setq refreshed t))))
        (with-temp-buffer
          (setq-local supertag-view-node--current-node-id "project-1")
          (let ((result (supertag-view-node-review-ai-fields)))
            (should (equal 2 (plist-get result :confirmed)))
            (should-not (plist-get result :errors)))))
      (should refreshed)
      (dolist (field '("Status" "Summary"))
        (should (eq :human
                    (plist-get (supertag-field-provenance
                                "project-1" "project" field)
                               :origin)))))))

(ert-deftest supertag-view-provenance-node-help-and-footer-explain-review-keys ()
  (should (eq (lookup-key supertag-view-node-mode-map (kbd "c"))
              #'supertag-view-node-confirm-field-at-point))
  (should (eq (lookup-key supertag-view-node-mode-map (kbd "x"))
              #'supertag-view-node-reject-field-at-point))
  (should (eq (lookup-key supertag-view-node-mode-map (kbd "C"))
              #'supertag-view-node-review-ai-fields))
  (let ((help (documentation #'supertag-view-node-mode))
        footer)
    (should (string-match-p "⟨AI⟩ means an agent wrote" help))
    (cl-letf (((symbol-function 'supertag-view-node--insert-simple-header)
               #'ignore)
              ((symbol-function 'supertag-view-node--insert-simple-metadata-section)
               #'ignore)
              ((symbol-function 'supertag-view-node--insert-ontology-capabilities-section)
               #'ignore)
              ((symbol-function 'supertag-view-reference-insert-sections)
               #'ignore)
              ((symbol-function 'supertag-view-mention-insert-section)
               #'ignore)
              ((symbol-function 'supertag-view-link-insert-section)
               #'ignore)
              ((symbol-function 'supertag-view-node--insert-semantic-relations-section)
               #'ignore)
              ((symbol-function 'supertag-view-node--activate-links-in-buffer)
               #'ignore)
              ((symbol-function 'supertag-view-helper-insert-simple-footer)
               (lambda (&rest lines) (setq footer lines))))
      (with-temp-buffer
        (supertag-view-node--render-from-state
         '(:id "project-1" :node (:title "Alpha")))))
    (should (string-match-p "\\[c\\] Confirm AI" (car footer)))
    (should (string-match-p "\\[x\\] Reject AI" (car footer)))))

;;; --- Table View marker ---

(ert-deftest supertag-view-provenance-node-and-table-share-the-same-badge ()
  "Node and Table render identical provenance badges, including tooltips."
  (supertag-view-provenance-test--isolated
    (supertag-view-provenance-test--install)
    (supertag-field-set
     "project-1" "project" "Summary" "agent text"
     '(:origin :agent :model "review-model" :at "2026-08-31"
       :source-hash "hash-v1"))
    (dolist (hash '("hash-v1" "hash-v2"))
      (supertag-store-put-entity
       :nodes "project-1"
       `(:id "project-1" :type :node :title "Alpha" :tags ("project")
         :hash ,hash))
      (let* ((node-badge
              (supertag-view-node--provenance-badge
               "project-1" "project" "Summary"))
             (table-cell
              (supertag-view-table--mark-provenance
               "agent text" "project-1" "project" "Summary"))
             (table-badge (substring table-cell (length "agent text "))))
        (should (equal-including-properties node-badge table-badge))))))

(ert-deftest supertag-view-provenance-table-marks-agent-cells ()
  (supertag-view-provenance-test--isolated
    (supertag-view-provenance-test--install)
    (supertag-field-set "project-1" "project" "Summary" "plain")
    (should (equal "plain"
                   (supertag-view-table--mark-provenance
                    "plain" "project-1" "project" "Summary")))
    (supertag-field-set "project-1" "project" "Summary" "agent text"
                        '(:origin :agent :source-hash "hash-v1"))
    (should (string-match-p "\\`agent text ⟨AI⟩\\'"
                            (supertag-view-table--mark-provenance
                             "agent text" "project-1" "project" "Summary")))
    (supertag-store-put-entity
     :nodes "project-1"
     '(:id "project-1" :type :node :title "Alpha" :tags ("project")
       :hash "hash-v2"))
    (should (string-match-p "⟨AI · outdated⟩"
                            (supertag-view-table--mark-provenance
                             "agent text" "project-1" "project" "Summary")))
    ;; Non-field columns and missing context are left alone.
    (should (equal "x" (supertag-view-table--mark-provenance "x" nil "project" "Summary")))
    (should (equal "x" (supertag-view-table--mark-provenance "x" "project-1" "project" nil)))
    (should (equal "x" (supertag-view-table--mark-provenance "x" "project-1" "project" "file")))))

(provide 'supertag-view-provenance-test)
;;; supertag-view-provenance-test.el ends here
