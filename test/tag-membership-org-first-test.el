;;; tag-membership-org-first-test.el --- Org-first Tag membership tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(when load-file-name
  (add-to-list 'load-path (file-name-directory load-file-name))
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))

(require 'ownership-fixture)
(require 'supertag-core-persistence)
(require 'supertag-tag)
(require 'supertag-service-org)
(require 'supertag-ui-commands)
(require 'supertag-automation)

(defun supertag-tag-membership-test--file-hash (file)
  "Return a byte-exact hash for FILE."
  (with-temp-buffer
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defmacro supertag-tag-membership-test--with-vault (&rest body)
  "Run BODY with a projected ownership fixture and isolated notifications."
  (declare (indent 0) (debug t))
  `(supertag-ownership-test-with-vault
     (let ((supertag-sync--state
            (list :sync-state (make-hash-table :test 'equal)))
           (supertag-sync--state-source
            (expand-file-name "sync-state.el" supertag-data-directory))
           (supertag-sync--deferred-files (make-hash-table :test 'equal))
           (supertag-sync--internal-modifications (make-hash-table :test 'equal))
           (supertag--subscribers (make-hash-table :test 'equal)))
       (cl-letf (((symbol-function 'supertag-sync-save-state) #'ignore))
         (should (eq 'complete (plist-get (supertag-reindex-org) :status))))
       (dolist (tag '("extra" "replacement" "automated"))
         (supertag-tag-create (list :id tag :name tag)))
       ,@body)))

(defun supertag-tag-membership-test--goto-node (file node-id)
  "Visit FILE and move to NODE-ID's heading."
  (let ((buffer (find-file-noselect file)))
    (with-current-buffer buffer
      (goto-char (point-min))
      (should (re-search-forward
               (format "^:ID:\\s-*%s$" (regexp-quote node-id)) nil t))
      (org-back-to-heading t))
    buffer))

(defun supertag-tag-membership-test--record-node-events (node-id order-cell)
  "Subscribe ORDER-CELL to projection events for NODE-ID."
  (supertag-subscribe
   :store-changed
   (lambda (path _old _new)
     (when (equal path (list :nodes node-id))
       (setcar order-cell (append (car order-cell) '(projection)))))))

(ert-deftest supertag-tag-membership-uses-node-tags-without-relations ()
  "Both tag mutation seams expose membership only through node `:tags'."
  (supertag-tag-membership-test--with-vault
    (should (supertag-ops-add-tag-to-node
             supertag-ownership-test-node-a "extra"))
    (supertag-node-add-tag supertag-ownership-test-node-b "extra")
    (dolist (node-id (list supertag-ownership-test-node-a
                           supertag-ownership-test-node-b))
      (should (member "extra" (supertag-query-node-tags node-id)))
      (should-not (supertag-relation-find-by-from node-id :node-tag)))))

(ert-deftest supertag-tag-membership-migration-retires-node-tag-projection ()
  "The 6.1 migration removes stale node-tag relations idempotently."
  (let ((supertag--store nil))
    (supertag--ensure-store)
    (puthash :version "6.0.0" supertag--store)
    (supertag-node-create '(:id "node" :title "Node" :tags ("kept")))
    (dolist (tag-id '("kept" "stale"))
      (supertag-tag-create (list :id tag-id :name tag-id)))
    (supertag-store-put-entity
     :relations "stale-node-tag"
     '(:id "stale-node-tag" :type :node-tag :from "node" :to "stale"))
    (should (equal '("kept") (supertag-query-node-tags "node")))
    (should (supertag--run-migrations supertag--store))
    (should-not
     (cl-loop for relation being the hash-values of
              (supertag-store-get-collection :relations)
              thereis (eq (plist-get relation :type) :node-tag)))
    (should (equal '("kept") (supertag-query-node-tags "node")))
    (should (equal "6.1.0" (gethash :version supertag--store)))
    (should (= 0 (supertag--retire-node-tag-projection supertag--store)))))

(ert-deftest supertag-tag-membership-save-failure-leaves-projection-unchanged ()
  "A failed Org save never creates membership projection."
  (supertag-tag-membership-test--with-vault
    (let* ((file (car files))
           (before-file (supertag-tag-membership-test--file-hash file))
           (before-node (supertag-node-get supertag-ownership-test-node-a))
           (before-occurrences (copy-sequence
                                (plist-get before-node :tag-occurrences)))
           (before-tags (copy-sequence (plist-get before-node :tags)))
           (buffer (supertag-tag-membership-test--goto-node
                    file supertag-ownership-test-node-a)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (should-error
               (cl-letf (((symbol-function 'save-buffer)
                          (lambda (&rest _) (error "deliberate save failure"))))
                 (supertag-service-org-add-tag
                  supertag-ownership-test-node-a "extra")))
              (should (buffer-modified-p))
              (should (search-forward "#extra" (line-end-position) t)))
            (should (equal before-file
                           (supertag-tag-membership-test--file-hash file)))
            (should-not
             (gethash (file-truename file)
                      supertag-sync--internal-modifications))
            (let ((after-node
                   (supertag-node-get supertag-ownership-test-node-a)))
              (should (equal before-occurrences
                             (plist-get after-node :tag-occurrences)))
              (should (equal before-tags (plist-get after-node :tags))))
            (should-not
             (supertag-relation-find-between
              supertag-ownership-test-node-a "extra" :node-tag)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest supertag-tag-membership-service-saves-before-one-projection-event ()
  "Add/change/remove save Org first and each project one node change."
  (supertag-tag-membership-test--with-vault
    (let* ((file (car files))
           (buffer (supertag-tag-membership-test--goto-node
                    file supertag-ownership-test-node-a))
           (order (list nil))
           (real-save (symbol-function 'save-buffer)))
      (unwind-protect
          (progn
            (supertag-tag-membership-test--record-node-events
             supertag-ownership-test-node-a order)
            (cl-letf (((symbol-function 'save-buffer)
                       (lambda (&rest args)
                         (setcar order (append (car order) '(save)))
                         (apply real-save args))))
              (supertag-service-org-add-tag
               supertag-ownership-test-node-a "extra"))
            (should (equal '(save projection) (car order)))
            (should (member "extra"
                            (plist-get
                             (supertag-node-get supertag-ownership-test-node-a)
                             :tag-occurrences)))
            (should (member "extra"
                            (plist-get
                             (supertag-node-get supertag-ownership-test-node-a)
                             :tags)))
            (should (member "extra"
                            (supertag-query-node-tags
                             supertag-ownership-test-node-a)))
            (should-not
             (supertag-relation-find-by-from
              supertag-ownership-test-node-a :node-tag))

            (setcar order nil)
            (cl-letf (((symbol-function 'save-buffer)
                       (lambda (&rest args)
                         (setcar order (append (car order) '(save)))
                         (apply real-save args))))
              (supertag-service-org-replace-tag
               supertag-ownership-test-node-a "extra" "replacement"))
            (should (equal '(save projection) (car order)))
            (should-not (member "extra"
                                (plist-get
                                 (supertag-node-get supertag-ownership-test-node-a)
                                 :tags)))
            (should (member "replacement"
                            (plist-get
                             (supertag-node-get supertag-ownership-test-node-a)
                             :tags)))

            (setcar order nil)
            (cl-letf (((symbol-function 'save-buffer)
                       (lambda (&rest args)
                         (setcar order (append (car order) '(save)))
                         (apply real-save args))))
              (supertag-service-org-remove-tag
               supertag-ownership-test-node-a "replacement"))
            (should (equal '(save projection) (car order)))
            (should-not (member "replacement"
                                (plist-get
                                 (supertag-node-get supertag-ownership-test-node-a)
                                 :tag-occurrences)))
            (should-not
             (supertag-relation-find-between
              supertag-ownership-test-node-a "replacement" :node-tag)))
        (kill-buffer buffer)))))

(ert-deftest supertag-tag-membership-writes-canonical-token-for-stable-id ()
  "The Org service never leaks a Stable Semantic Tag ID into source text."
  (supertag-tag-membership-test--with-vault
    (let* ((tag (supertag-tag-create '(:name "stable-entry")))
           (tag-id (plist-get tag :id))
           (file (car files))
           (buffer (supertag-tag-membership-test--goto-node
                    file supertag-ownership-test-node-a)))
      (unwind-protect
          (with-current-buffer buffer
            (supertag-service-org-add-tag
             supertag-ownership-test-node-a tag-id)
            (should (member "stable-entry"
                            (plist-get
                             (supertag-node-get supertag-ownership-test-node-a)
                             :tag-occurrences)))
            (should (member tag-id
                            (plist-get
                             (supertag-node-get supertag-ownership-test-node-a)
                             :tags)))
            (goto-char (point-min))
            (should (search-forward "#stable-entry" nil t))
            (goto-char (point-min))
            (should-not (search-forward tag-id nil t)))
        (kill-buffer buffer)))))

(ert-deftest supertag-tag-membership-existing-token-repairs-missing-projection ()
  "Automation repairs missing Store membership for an existing Org occurrence."
  (supertag-tag-membership-test--with-vault
    (let* ((node-id supertag-ownership-test-node-a)
           (file (car files))
           (buffer (supertag-tag-membership-test--goto-node file node-id)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (supertag-service-org-add-tag node-id "extra")
              (should (search-forward "#extra" (line-end-position) t)))
            ;; Reproduce an interrupted/stale Projection while preserving the
            ;; already-saved Org Fact.
            (supertag-node-remove-tag node-id "extra")
            (should-not (member "extra"
                                (plist-get (supertag-node-get node-id) :tags)))
            (should-not
             (supertag-relation-find-between node-id "extra" :node-tag))
            (with-current-buffer buffer
              (let ((before-tick (buffer-chars-modified-tick)))
                (supertag-automation-action-add-tag
                 node-id '(:tag "extra"))
                (should (eq before-tick (buffer-chars-modified-tick)))))
            (should (member "extra" (supertag-query-node-tags node-id)))
            (should-not
             (supertag-relation-find-by-from node-id :node-tag)))
        (kill-buffer buffer)))))

(ert-deftest supertag-tag-membership-ui-commands-use-org-first-path ()
  "Interactive add/change/remove retain one save-before-projection path."
  (supertag-tag-membership-test--with-vault
    (let* ((file (car files))
           (buffer (supertag-tag-membership-test--goto-node
                    file supertag-ownership-test-node-a))
           (order (list nil))
           (real-save (symbol-function 'save-buffer)))
      (unwind-protect
          (with-current-buffer buffer
            (supertag-tag-membership-test--record-node-events
             supertag-ownership-test-node-a order)
            (cl-letf (((symbol-function 'supertag-ui-read-tag)
                       (lambda (&rest _) "extra"))
                      ((symbol-function 'save-buffer)
                       (lambda (&rest args)
                         (setcar order (append (car order) '(save)))
                         (apply real-save args))))
              (supertag-add-tag))
            (should (equal '(save projection) (car order)))

            (setcar order nil)
            (cl-letf (((symbol-function 'supertag-ui-select-tag-on-node)
                       (lambda (_node-id) "extra"))
                      ((symbol-function 'supertag-ui-read-tag)
                       (lambda (&rest _) "replacement"))
                      ((symbol-function 'save-buffer)
                       (lambda (&rest args)
                         (setcar order (append (car order) '(save)))
                         (apply real-save args))))
              (supertag-change-tag-at-point))
            (should (equal '(save projection) (car order)))

            (setcar order nil)
            (cl-letf (((symbol-function 'supertag-ui-select-tag-on-node)
                       (lambda (_node-id) "replacement"))
                      ((symbol-function 'save-buffer)
                       (lambda (&rest args)
                         (setcar order (append (car order) '(save)))
                         (apply real-save args))))
              (supertag-remove-tag-from-node))
            (should (equal '(save projection) (car order))))
        (kill-buffer buffer)))))

(ert-deftest supertag-standalone-capture-tag-workflow-is-retired ()
  "Tag capture remains behind Org Capture and shared service boundaries."
  (should-not (fboundp 'supertag-capture)))

(ert-deftest supertag-capture-tag-registration-failure-is-not-silent ()
  "A failed Org membership rolls back a newly-created Semantic Tag and signals."
  (supertag-tag-membership-test--with-vault
    (cl-letf (((symbol-function 'supertag-service-org-add-tag)
               (lambda (&rest _) (error "deliberate membership failure"))))
      (should-error
       (supertag-capture-add-tag-to-nodes
        (list supertag-ownership-test-node-a) "capture-failed"))
      (should-not (supertag-tag-resolve-occurrence "capture-failed")))))

(ert-deftest supertag-capture-membership-assertion-restores-org-file ()
  "A late membership assertion cannot leave its saved Tag occurrence behind."
  (supertag-tag-membership-test--with-vault
    (let* ((file (car files))
           (buffer (supertag-tag-membership-test--goto-node
                    file supertag-ownership-test-node-a)))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function
                        'supertag-capture--tag-membership-present-p)
                       (lambda (&rest _) nil)))
              (should-error
               (supertag-capture-add-tag-to-nodes
                (list supertag-ownership-test-node-a) "capture-rollback")))
            (with-temp-buffer
              (insert-file-contents file)
              (should-not (search-forward "#capture-rollback" nil t)))
            (should-not
             (supertag-tag-resolve-occurrence "capture-rollback")))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest supertag-capture-bulk-tag-service-save-and-project-once ()
  "The capture service composes several Tag edits behind one commit seam."
  (supertag-tag-membership-test--with-vault
    (let* ((real-save-and-project
            (symbol-function
             'supertag-service-org-save-and-project-current-node))
           (save-and-project-count 0)
           tag-ids)
      (cl-letf
          (((symbol-function
             'supertag-service-org-save-and-project-current-node)
            (lambda (id)
              (cl-incf save-and-project-count)
              (funcall real-save-and-project id))))
        (setq tag-ids
              (supertag-capture-add-tags-to-nodes
               (list supertag-ownership-test-node-a)
               '("capture-one" "capture-two"))))
      (should (= 1 save-and-project-count))
      (should (= 2 (length tag-ids)))
      (dolist (tag-id tag-ids)
        (should (member tag-id
                        (supertag-query-node-tags
                         supertag-ownership-test-node-a))))
      (should-not
       (supertag-relation-find-by-from
        supertag-ownership-test-node-a :node-tag)))))

(ert-deftest supertag-tag-membership-automation-actions-project-once-after-save ()
  "Automation Tag actions use the same Org-first membership path."
  (supertag-tag-membership-test--with-vault
    (let* ((file (car files))
           (buffer (supertag-tag-membership-test--goto-node
                    file supertag-ownership-test-node-a))
           (order (list nil))
           (real-save (symbol-function 'save-buffer)))
      (unwind-protect
          (progn
            (supertag-tag-membership-test--record-node-events
             supertag-ownership-test-node-a order)
            (cl-letf (((symbol-function 'save-buffer)
                       (lambda (&rest args)
                         (setcar order (append (car order) '(save)))
                         (apply real-save args))))
              (supertag-automation-action-add-tag
               supertag-ownership-test-node-a '(:tag "automated")))
            (should (equal '(save projection) (car order)))
            (should (member "automated"
                            (plist-get
                             (supertag-node-get supertag-ownership-test-node-a)
                             :tags)))

            (setcar order nil)
            (cl-letf (((symbol-function 'save-buffer)
                       (lambda (&rest args)
                         (setcar order (append (car order) '(save)))
                         (apply real-save args))))
              (supertag-automation-action-remove-tag
               supertag-ownership-test-node-a '(:tag "automated")))
            (should (equal '(save projection) (car order)))
            (should-not (member "automated"
                                (plist-get
                                 (supertag-node-get supertag-ownership-test-node-a)
                                 :tags))))
        (kill-buffer buffer)))))

;;; --- Region-scoped Tag Occurrence reader ---

(defmacro supertag-tag-membership-test--with-org-file (text &rest body)
  "Visit a temp Org file containing TEXT and run BODY in its buffer.
An isolated Store is installed so projection has somewhere to resolve
occurrence tokens against."
  (declare (indent 1) (debug t))
  `(let* ((file (make-temp-file "supertag-occurrences" nil ".org" ,text))
          (supertag--store nil)
          (buffer (find-file-noselect file)))
     (unwind-protect
         (with-current-buffer buffer
           (org-mode)
           (supertag--ensure-store)
           ,@body)
       (with-current-buffer buffer (set-buffer-modified-p nil))
       (kill-buffer buffer)
       (delete-file file))))

(ert-deftest supertag-tag-membership-occurrences-match-whole-file-reader ()
  "The region reader agrees with the whole-file reader on every node.

`supertag-node-tag-occurrences-at-point' exists only to avoid projecting
the whole file for one node's occurrences, so on files where the slow
reader is correct -- every `:ID:' distinct -- the two must not diverge."
  (supertag-tag-membership-test--with-org-file
      (concat "* Alpha #one\n:PROPERTIES:\n:ID: ID-A\n:END:\nbody with #two here\n"
              "** Beta :native:\n:PROPERTIES:\n:ID: ID-B\n:END:\nplain body\n"
              "* Gamma\n:PROPERTIES:\n:ID: ID-C\n:END:\ntrailing #three\n")
    (goto-char (point-min))
    (let ((seen 0))
      (org-map-entries
       (lambda ()
         (setq seen (1+ seen))
         (should (equal (plist-get (supertag--parse-node-at-point) :tag-occurrences)
                        (supertag-node-tag-occurrences-at-point))))
       nil 'file)
      (should (= seen 3)))
    ;; And the values themselves are the node's own, not its neighbours'.
    (goto-char (point-min))
    (should (equal '("one" "two") (supertag-node-tag-occurrences-at-point)))))

(ert-deftest supertag-tag-membership-occurrences-read-the-node-under-point ()
  "Occurrences come from the heading at point even when `:ID:' is duplicated.

The whole-file reader resolves a node by searching the parsed file for its
ID, so with a duplicated `:ID:' it answers for whichever copy comes first
and every copy reports the same tags.  Reading only the region at point is
what makes the two copies distinguishable."
  (supertag-tag-membership-test--with-org-file
      (concat "* First copy #alpha\n:PROPERTIES:\n:ID: DUP-ID\n:END:\n"
              "* Second copy #beta\n:PROPERTIES:\n:ID: DUP-ID\n:END:\n")
    (goto-char (point-min))
    (should (equal '("alpha") (supertag-node-tag-occurrences-at-point)))
    (should (search-forward "Second copy" nil t))
    (org-back-to-heading t)
    (should (equal '("beta") (supertag-node-tag-occurrences-at-point)))
    ;; The reader this replaced answers "alpha" for both copies.
    (should (equal '("alpha") (plist-get (supertag--parse-node-at-point)
                                         :tag-occurrences)))))

(ert-deftest supertag-tag-membership-occurrences-stop-at-the-next-heading ()
  "A node owns its title line and its own body, and nothing past that."
  (supertag-tag-membership-test--with-org-file
      (concat "* Parent\n:PROPERTIES:\n:ID: ID-P\n:END:\nparent body\n"
              "** Child #childtag\n:PROPERTIES:\n:ID: ID-K\n:END:\nchild body\n")
    (goto-char (point-min))
    (should-not (supertag-node-tag-occurrences-at-point))
    (should (search-forward "Child" nil t))
    (org-back-to-heading t)
    (should (equal '("childtag") (supertag-node-tag-occurrences-at-point)))
    ;; Off a heading there is no node to read, matching the old reader.
    (goto-char (point-max))
    (should-not (supertag-node-tag-occurrences-at-point))))

;;; --- ID navigation inside the Org service ---

(ert-deftest supertag-tag-membership-goto-id-leaves-point-on-the-heading ()
  "Locating a node by ID moves point there, wherever point started.

The old Org service lookup used to run its search
inside `org-with-wide-buffer', which restores point, so it reported
success without ever moving.  Everything `supertag-service-org--with-node-buffer'
runs then operated on whatever heading point happened to sit on."
  (supertag-tag-membership-test--with-org-file
      (concat "* Alpha #one\n:PROPERTIES:\n:ID: ID-A\n:END:\nalpha body\n"
              "* Beta #two\n:PROPERTIES:\n:ID: ID-B\n:END:\nbeta body\n")
    ;; From inside another node's body.
    (goto-char (point-min))
    (should (search-forward "beta body" nil t))
    (should (supertag-node-location-goto-current-buffer "ID-A"))
    (should (org-at-heading-p))
    (should (equal "ID-A" (org-entry-get nil "ID")))
    ;; From another node's heading.
    (goto-char (point-min))
    (should (search-forward "* Beta" nil t))
    (org-back-to-heading t)
    (should (supertag-node-location-goto-current-buffer "ID-A"))
    (should (equal "ID-A" (org-entry-get nil "ID")))))

(ert-deftest supertag-tag-membership-goto-id-keeps-point-when-not-found ()
  "A failed ID lookup reports failure and leaves point where it was."
  (supertag-tag-membership-test--with-org-file
      "* Alpha\n:PROPERTIES:\n:ID: ID-A\n:END:\nalpha body\n"
    (goto-char (point-min))
    (should (search-forward "alpha body" nil t))
    (let ((before (point)))
      (should-not (supertag-node-location-goto-current-buffer "ID-MISSING"))
      (should (= before (point))))))

(ert-deftest supertag-tag-membership-with-node-buffer-runs-at-the-right-node ()
  "`--with-node-buffer' reaches its node even from a narrowed buffer.

The restriction it widens past is put back once the body has run, so
callers cannot silently un-narrow the user's buffer."
  (supertag-tag-membership-test--with-org-file
      (concat "* Alpha #one\n:PROPERTIES:\n:ID: ID-A\n:END:\nalpha body\n"
              "* Beta #two\n:PROPERTIES:\n:ID: ID-B\n:END:\nbeta body\n")
    (supertag-sync--process-single-file
     (file-truename (buffer-file-name))
     '(:nodes-created 0 :nodes-updated 0 :nodes-deleted 0))
    ;; Narrow to Beta, then ask for Alpha.
    (goto-char (point-min))
    (should (search-forward "* Beta" nil t))
    (org-back-to-heading t)
    (org-narrow-to-subtree)
    (let ((narrowed-min (point-min))
          (narrowed-max (point-max))
          (seen nil))
      (supertag-service-org--with-node-buffer
       "ID-A" (lambda () (setq seen (org-entry-get nil "ID"))))
      (should (equal "ID-A" seen))
      (should (= narrowed-min (point-min)))
      (should (= narrowed-max (point-max))))))

(provide 'tag-membership-org-first-test)

;;; tag-membership-org-first-test.el ends here
