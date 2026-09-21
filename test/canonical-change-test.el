;;; canonical-change-test.el --- Canonical Change skeleton contracts -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(when load-file-name
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-change)
(require 'supertag-board-ops)

(defmacro supertag-change-test--with-env (&rest body)
  "Run BODY with isolated Store, transaction, and Canonical Change state."
  (declare (indent 0) (debug t))
  `(let ((supertag--store nil)
         (supertag--transaction-active nil)
         (supertag--transaction-log nil)
         (supertag--transaction-seen nil)
         (supertag--suppress-notifications nil)
         (supertag--pending-changes nil)
         (supertag--subscribers (make-hash-table :test 'equal))
         (supertag-change--subscribers nil)
         (supertag-change--queue nil)
         (supertag-change--dispatching nil)
         (supertag-change--delivering-change-id nil)
         (supertag-change--subscriber-errors nil)
         (supertag-change--id-counter 0)
         (supertag-change--bridge-commit-count 0)
         (supertag-change--bridge-total-path-count 0)
         (supertag-change--bridge-last-path-count 0)
         (supertag-change-bridge-debug nil))
     (supertag--ensure-store)
     ,@body))

(defun supertag-change-test--envelope (operation &rest overrides)
  "Return a valid envelope for OPERATION with OVERRIDES applied."
  (let ((envelope
         (list :authority :semantic
               :scope :fact
               :operation operation
               :subject '(:kind :node :id "node")
               :cardinality :single
               :affected '((:collection :nodes :count 1))
               :metadata nil)))
    (while overrides
      (setq envelope (plist-put envelope (pop overrides) (pop overrides))))
    envelope))

(defun supertag-change-test--put-node (id title &optional emit-event-p)
  "Put a minimal node Projection for ID and TITLE."
  (supertag-store-put-entity
   :nodes id (list :id id :type :node :title title :file "/tmp/node.org")
   emit-event-p))

(ert-deftest supertag-change-validates-v1-envelope ()
  "Authority/scope/cardinality and bounded public summaries are explicit."
  (supertag-change-test--with-env
    (dolist (authority '(:document :semantic :operational))
      (should (eq :no-op
                  (supertag-change-commit
                   (supertag-change-test--envelope
                    :validate :authority authority)
                   (lambda () :no-op)))))
    (should-error
     (supertag-change-commit
      (supertag-change-test--envelope :bad :authority :projection)
      #'ignore))
    (should-error
     (supertag-change-commit
      (supertag-change-test--envelope :bad :scope :unknown)
      #'ignore))
    (should-error
     (supertag-change-commit
      (supertag-change-test--envelope :bad :cardinality :many)
      #'ignore))
    (should-error
     (supertag-change-commit
      (supertag-change-test--envelope :bad :metadata '(:paths ("secret")))
      #'ignore))
    (should-error
     (supertag-change-commit
      (supertag-change-test--envelope
       :bad :affected
       (make-list 33 '(:collection :nodes :count 1)))
      #'ignore))))

(ert-deftest supertag-change-publishes-once-after-real-commit ()
  "A real mutation publishes once after transaction state is cleared."
  (supertag-change-test--with-env
    (let (changes active-during-delivery)
      (supertag-change-subscribe
       (lambda (change)
         (push change changes)
         (setq active-during-delivery supertag--transaction-active)
         (should (supertag-store-get-entity :nodes "node"))))
      (should (eq :body-result
                  (supertag-change-commit
                   (supertag-change-test--envelope :node-created)
                   (lambda ()
                     (supertag-change-test--put-node "node" "Node")
                     :body-result))))
      (should-not active-during-delivery)
      (should (= 1 (length changes)))
      (let ((change (car changes)))
        (should (= 1 (plist-get change :version)))
        (should (stringp (plist-get change :change-id)))
        (should-not (plist-get change :causation-id))
        (should (eq :semantic (plist-get change :authority)))
        (should (eq :fact (plist-get change :scope)))
        (should (eq :node-created (plist-get change :operation)))))))

(ert-deftest supertag-change-no-op-and-rollback-publish-zero ()
  "Equal writes and failed bodies publish neither Canonical nor legacy."
  (supertag-change-test--with-env
    (supertag-change-test--put-node "node" "Before")
    (let ((canonical-count 0)
          (legacy-count 0)
          (same (copy-tree (supertag-store-get-entity :nodes "node"))))
      (supertag-change-subscribe
       (lambda (_change) (cl-incf canonical-count)))
      (supertag-subscribe
       :store-changed
       (lambda (&rest _args) (cl-incf legacy-count)))
      (supertag-change-commit
       (supertag-change-test--envelope :node-unchanged)
       (lambda ()
         (supertag-store-put-entity :nodes "node" same)))
      (should (= 0 canonical-count))
      (should (= 0 legacy-count))
      (should-error
       (supertag-change-commit
        (supertag-change-test--envelope :node-updated)
        (lambda ()
          (supertag-change-test--put-node "node" "After" t)
          (supertag-change-test--put-node "new" "Transient" t)
          (error "deliberate body failure"))))
      (should (= 0 canonical-count))
      (should (= 0 legacy-count))
      (should (equal '(:legacy-subscriber-count 1
                       :bridged-commit-count 0
                       :total-path-count 0
                       :last-commit-path-count 0)
                     (supertag-change-bridge-diagnostics)))
      (should-not (supertag-store-get-entity :nodes "new"))
      (should (equal "Before"
                     (plist-get (supertag-store-get-entity :nodes "node")
                                :title))))))

(ert-deftest supertag-change-bridges-private-first-touch-record-in-order ()
  "Bridge emits exact final first-touch values after the Canonical Change."
  (supertag-change-test--with-env
    (supertag-change-test--put-node "existing" "Before")
    (let* ((old (copy-tree (supertag-store-get-entity :nodes "existing")))
           (updated (copy-tree old))
           (created '(:id "created" :type :node :title "Created"
                      :file "/tmp/created.org"))
           trace published legacy-events)
      (setq updated (plist-put updated :title "After"))
      (supertag-change-subscribe
       (lambda (change)
         (setq published change)
         (push :canonical trace)))
      (supertag-subscribe
       :store-changed
       (lambda (path old-value new-value)
         (push (list (copy-tree path)
                     (copy-tree old-value)
                     (copy-tree new-value))
               legacy-events)
         (push (list :legacy (copy-tree path)) trace)))
      (supertag-change-commit
       (supertag-change-test--envelope
        :nodes-updated
        :cardinality :batch
        :affected '((:collection :nodes :count 2)))
       (lambda ()
         ;; Both writes would emit immediate legacy events outside the seam.
         (supertag-update '(:nodes "existing") updated)
         (supertag-update '(:nodes "created") created)))
      (should
       (equal '(:canonical
                (:legacy (:nodes "existing"))
                (:legacy (:nodes "created")))
              (nreverse trace)))
      (should
       (equal (list (list '(:nodes "existing") old updated)
                    (list '(:nodes "created") nil created))
              (nreverse legacy-events)))
      (should-not (supertag-change--contains-raw-diff-p published))
      (should-not supertag-change--queue)
      (should (equal '(:legacy-subscriber-count 1
                       :bridged-commit-count 1
                       :total-path-count 2
                       :last-commit-path-count 2)
                     (supertag-change-bridge-diagnostics))))))

(ert-deftest supertag-change-nested-subscriber-commit-is-fifo-nonreentrant ()
  "A subscriber-derived commit waits until every current subscriber returns."
  (supertag-change-test--with-env
    (let (trace changes in-first reentered)
      (supertag-change-subscribe
       (lambda (change)
         (when in-first
           (setq reentered t))
         (push change changes)
         (push (list (plist-get change :operation) :first-begin) trace)
         (when (eq :outer (plist-get change :operation))
           (let ((in-first t))
             (supertag-change-commit
              (supertag-change-test--envelope
               :inner :subject '(:kind :node :id "inner"))
              (lambda ()
                (supertag-change-test--put-node "inner" "Inner")))))
         (push (list (plist-get change :operation) :first-end) trace)))
      (supertag-change-subscribe
       (lambda (change)
         (push (list (plist-get change :operation) :second) trace)))
      (supertag-change-commit
       (supertag-change-test--envelope :outer)
       (lambda ()
         (supertag-change-test--put-node "node" "Outer")))
      (should-not reentered)
      (should
       (equal '((:outer :first-begin)
                (:outer :first-end)
                (:outer :second)
                (:inner :first-begin)
                (:inner :first-end)
                (:inner :second))
              (nreverse trace)))
      (let* ((ordered (nreverse changes))
             (outer (nth 0 ordered))
             (inner (nth 1 ordered)))
        (should (equal (plist-get outer :change-id)
                       (plist-get inner :causation-id)))))))

(ert-deftest supertag-change-nested-commits-do-not-interleave-batches ()
  "Nested commits from Canonical and legacy delivery wait for the full batch."
  (supertag-change-test--with-env
    (let (trace changes spawned-canonical spawned-legacy)
      (supertag-change-subscribe
       (lambda (change)
         (push change changes)
         (push (list (plist-get change :operation) :canonical) trace)
         (when (and (eq :outer (plist-get change :operation))
                    (not spawned-canonical))
           (setq spawned-canonical t)
           (supertag-change-commit
            (supertag-change-test--envelope
             :inner-canonical :subject '(:kind :node :id "inner-canonical"))
            (lambda ()
              (supertag-change-test--put-node
               "inner-canonical" "Inner canonical" t))))))
      (supertag-subscribe
       :store-changed
       (lambda (path _old _new)
         (push (list (cadr path) :legacy) trace)
         (when (and (equal path '(:nodes "outer-a"))
                    (not spawned-legacy))
           (setq spawned-legacy t)
           (supertag-change-commit
            (supertag-change-test--envelope
             :inner-legacy :subject '(:kind :node :id "inner-legacy"))
            (lambda ()
              (supertag-change-test--put-node
               "inner-legacy" "Inner legacy" t))))))
      (supertag-change-commit
       (supertag-change-test--envelope
        :outer :cardinality :batch
        :affected '((:collection :nodes :count 2)))
       (lambda ()
         (supertag-change-test--put-node "outer-a" "Outer A" t)
         (supertag-change-test--put-node "outer-b" "Outer B" t)))
      (should
       (equal '((:outer :canonical)
                ("outer-a" :legacy)
                ("outer-b" :legacy)
                (:inner-canonical :canonical)
                ("inner-canonical" :legacy)
                (:inner-legacy :canonical)
                ("inner-legacy" :legacy))
              (nreverse trace)))
      (let* ((ordered (nreverse changes))
             (outer (nth 0 ordered)))
        (should (= 3 (length ordered)))
        (dolist (inner (cdr ordered))
          (should (equal (plist-get outer :change-id)
                         (plist-get inner :causation-id))))))))

(ert-deftest supertag-change-and-legacy-store-topics-are-exclusive ()
  "A callback chooses one change topic; other legacy subscriptions still work."
  (supertag-change-test--with-env
    (let ((callback (lambda (&rest _args)))
          (other-count 0)
          (path-count 0)
          (canonical-count 0))
      ;; Canonical first, then legacy must fail without changing subscriptions.
      (let ((unsubscribe (supertag-change-subscribe callback)))
        (should-error (supertag-subscribe :store-changed callback))
        (should (= 1 (length supertag-change--subscribers)))
        (funcall unsubscribe))
      ;; Legacy first, then Canonical must fail symmetrically.
      (let ((unsubscribe (supertag-subscribe :store-changed callback)))
        (should-error (supertag-change-subscribe callback))
        (should (= 1 (length (gethash :store-changed supertag--subscribers))))
        (funcall unsubscribe))
      ;; Generic non-change topics and data-path subscriptions remain legal.
      (supertag-subscribe
       :other-topic (lambda (&rest _args) (cl-incf other-count)))
      (supertag-subscribe
       '(:nodes "direct") (lambda (&rest _args) (cl-incf path-count)))
      (supertag-change-subscribe
       (lambda (_change) (cl-incf canonical-count)))
      (supertag-emit-event :other-topic :payload)
      (supertag-core-notify-handle-change '(:nodes "direct") nil :value)
      ;; An unmigrated direct Store write remains immediate and one-way.
      (let ((legacy-count 0))
        (supertag-subscribe
         :store-changed (lambda (&rest _args) (cl-incf legacy-count)))
        (supertag-update '(:nodes "direct")
                         '(:id "direct" :type :node :title "Direct"))
        (should (= 1 legacy-count)))
      (should (= 1 other-count))
      (should (= 2 path-count))
      (should (= 0 canonical-count)))))

(ert-deftest supertag-board-create-is-the-canonical-tracer-writer ()
  "Board creation keeps its shape and legacy payload after Canonical commit."
  (supertag-change-test--with-env
    (let* ((fixed-time '(27000 12345 0 0))
           (original-put (symbol-function 'supertag-store-put-entity))
           (write-count 0)
           trace change legacy-event board)
      (supertag-change-subscribe
       (lambda (published)
         (setq change published)
         (push :canonical trace)))
      (supertag-subscribe
       :store-changed
       (lambda (path old-value new-value)
         (setq legacy-event
               (list (copy-tree path)
                     (copy-tree old-value)
                     (copy-tree new-value)))
         (push :legacy trace)))
      (cl-letf (((symbol-function 'org-id-uuid) (lambda () "board-1"))
                ((symbol-function 'current-time) (lambda () fixed-time))
                ((symbol-function 'supertag-store-put-entity)
                 (lambda (&rest args)
                   (cl-incf write-count)
                   (apply original-put args))))
        (setq board (supertag-board-create "Roadmap")))
      (should
       (equal `(:id "board-1"
                :title "Roadmap"
                :node-placements nil
                :board-edges nil
                :groups nil
                :viewport (:x 0 :y 0 :zoom 1.0)
                :created-at ,fixed-time
                :modified-at ,fixed-time)
              board))
      (should (equal board (supertag-store-get-entity :boards "board-1")))
      (should (= 1 write-count))
      (should (equal '(:canonical :legacy) (nreverse trace)))
      (should (eq :board-created (plist-get change :operation)))
      (should (eq :semantic (plist-get change :authority)))
      (should (eq :fact (plist-get change :scope)))
      (should (eq :single (plist-get change :cardinality)))
      (should
       (equal (list '(:boards "board-1") nil board) legacy-event))
      ;; A failure after the Store write rolls board creation back and emits
      ;; neither topic; the successful bridge counters remain unchanged.
      (let ((trace-before (copy-sequence trace))
            (diagnostics-before (supertag-change-bridge-diagnostics)))
        (cl-letf (((symbol-function 'org-id-uuid) (lambda () "board-error"))
                  ((symbol-function 'current-time) (lambda () fixed-time))
                  ((symbol-function 'supertag-store-put-entity)
                   (lambda (&rest args)
                     (prog1 (apply original-put args)
                       (error "deliberate board Store failure")))))
          (should-error (supertag-board-create "Broken")))
        (should-not (supertag-store-get-entity :boards "board-error"))
        (should (equal trace-before trace))
        (should (equal diagnostics-before
                       (supertag-change-bridge-diagnostics)))))))

(ert-deftest supertag-change-isolates-subscriber-errors ()
  "One subscriber failure neither blocks later subscribers nor rolls back."
  (supertag-change-test--with-env
    (let ((later-count 0))
      (supertag-change-subscribe
       (lambda (_change) (error "deliberate subscriber failure")))
      (supertag-change-subscribe
       (lambda (_change) (cl-incf later-count)))
      (supertag-change-commit
       (supertag-change-test--envelope :node-created)
       (lambda ()
         (supertag-change-test--put-node "node" "Committed")))
      (should (= 1 later-count))
      (should (= 1 (length supertag-change--subscriber-errors)))
      (should (equal "Committed"
                     (plist-get (supertag-store-get-entity :nodes "node")
                                :title))))))

(ert-deftest supertag-change-batch-event-is-bounded-summary ()
  "Batch changes expose counts, never the private first-touch path list."
  (supertag-change-test--with-env
    (let (published)
      (supertag-change-subscribe (lambda (change) (setq published change)))
      (supertag-change-commit
       (supertag-change-test--envelope
        :reindex
        :authority :document
        :scope :projection
        :subject '(:kind :reindex)
        :cardinality :batch
        :affected '((:collection :nodes :count 5000)
                    (:collection :relations :count 12000)))
       (lambda ()
         (supertag-change-test--put-node "node" "Projected")))
      (should (eq :batch (plist-get published :cardinality)))
      (should (= 5000
                 (plist-get (car (plist-get published :affected)) :count)))
      (should-not (supertag-change--contains-raw-diff-p published))
      (should-not (plist-member published :commit-record)))))

(ert-deftest supertag-change-rejects-an-ambient-transaction ()
  "The isolated skeleton cannot falsely publish before an outer commit."
  (supertag-change-test--with-env
    (supertag-with-transaction
      (should-error
       (supertag-change-commit
        (supertag-change-test--envelope :nested-transaction)
        (lambda ()
          (supertag-change-test--put-node "node" "Impossible")))))
    (should-not (supertag-store-get-entity :nodes "node"))))

(provide 'canonical-change-test)
;;; canonical-change-test.el ends here
