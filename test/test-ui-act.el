;;; test-ui-act.el --- Tests for supertag-ui-act -*- lexical-binding: t; -*-
;; Run: emacs --batch -Q --eval '(package-initialize)' -L . -L test \
;;   -l test/test-ui-act.el --eval '(ert-run-tests-batch-and-exit)'

(require 'ert)
(require 'org)
(require 'supertag-ui-act)
(require 'supertag-ui-embark)
(require 'supertag-menu)
;; Load the reference module up front so tests can mock its functions
;; without a later lazy `require' overwriting the mocks.
(require 'supertag-link)

(ert-deftest supertag-act-region-target-offers-reference-actions ()
  "An active Org region is a target with reference actions."
  (with-temp-buffer
    (org-mode)
    (insert "* Heading\nSome important phrase here\n")
    (goto-char (point-min))
    (search-forward "important")
    (set-mark (match-beginning 0))
    (activate-mark)
    (transient-mark-mode 1)
    (let ((target (supertag-act--target-at-point)))
      (should (eq (plist-get target :kind) :region))
      (should (= (plist-get target :begin) (match-beginning 0)))
      (let ((labels (mapcar #'car (supertag-act--actions target))))
        (should (string-match-p "Add link" (car labels)))
        (should-not (cl-find-if
                     (lambda (label) (string-match-p "no prompt" label))
                     labels))
        (should (member "Add tag to node..." labels))))))

(ert-deftest supertag-act-region-default-runs-unified-add-link ()
  (with-temp-buffer
    (org-mode)
    (insert "* Heading\nselected text\n")
    (search-backward "selected")
    (set-mark (point))
    (search-forward "text")
    (activate-mark)
    (let* ((target (supertag-act--target-at-point))
           (action (cdar (supertag-act--actions target)))
           called)
      (cl-letf (((symbol-function 'supertag-add-link)
                 (lambda (&optional _named) (interactive) (setq called t)))
                ((symbol-function 'supertag-reference-link-region)
                 (lambda (&rest _) (ert-fail "retired region path called"))))
        (funcall action))
      (should called))))

(ert-deftest supertag-act-concept-target-carries-bounds ()
  "A concept mention target records the mention's bounds."
  (with-temp-buffer
    (insert "before TERM after")
    (let ((begin (progn (goto-char (point-min))
                        (search-forward "TERM") (match-beginning 0)))
          (end (match-end 0)))
      (put-text-property begin end 'supertag-concept-node-id "concept-1")
      (goto-char (1+ begin))
      (let ((target (supertag-act--target-at-point)))
        (should (eq (plist-get target :kind) :concept))
        (should (equal (plist-get target :node-id) "concept-1"))
        (should (= (plist-get target :begin) begin))
        (should (= (plist-get target :end) end))))))

(ert-deftest supertag-act-concept-link-action-materializes ()
  "Linking a mention occurrence goes through the single materializer."
  (with-temp-buffer
    (org-mode)
    (insert "* Source\nsee TERM here\n")
    (let ((begin (progn (goto-char (point-min))
                        (search-forward "TERM") (match-beginning 0)))
          (end (match-end 0))
          materialized)
      (put-text-property begin end 'supertag-concept-node-id "concept-1")
      (goto-char (1+ begin))
      (cl-letf (((symbol-function 'supertag-reference--commit-region)
                 (lambda (beg-marker end-marker target-id title)
                   (setq materialized (list (marker-position beg-marker)
                                            (marker-position end-marker)
                                            target-id title))))
                ((symbol-function 'supertag-reference-materialize)
                 (lambda (beg-marker end-marker target-id title)
                   (setq materialized (list (marker-position beg-marker)
                                            (marker-position end-marker)
                                            target-id title)))))
        (let* ((target (supertag-act--target-at-point))
               (labels-and-actions (supertag-act--actions target))
               (link (assoc "Link this occurrence (write physical link)"
                            labels-and-actions)))
          (should link)
          (funcall (cdr link))
          (should (equal materialized
                         (list begin end "concept-1" "TERM"))))))))

(ert-deftest supertag-act-heading-without-id-offers-creation ()
  "A heading without ID gets a create action instead of an error."
  (with-temp-buffer
    (org-mode)
    (insert "* Plain heading\n")
    (goto-char (point-min))
    (let* ((target (supertag-act--target-at-point))
           (labels (mapcar #'car (supertag-act--actions target))))
      (should (eq (plist-get target :kind) :node))
      (should-not (plist-get target :node-id))
      (should (string-match-p "Add heading to Supertag" (car labels)))
      ;; The immediate default action still refuses to create IDs.
      (should-error (supertag-act-dwim) :type 'user-error))))

(ert-deftest supertag-act-no-target-behavior ()
  "Without a target, `supertag-act' opens the menu and dwim errors."
  (with-temp-buffer
    (let (opened)
      (cl-letf (((symbol-function 'supertag-menu)
                 (lambda () (interactive) (setq opened t))))
        (supertag-act)
        (should opened))
      (should-error (supertag-act-dwim) :type 'user-error))))

(ert-deftest supertag-act-embark-finder-reports-target ()
  "The Embark finder exposes the object at point with its bounds."
  (with-temp-buffer
    (insert "TERM")
    (put-text-property (point-min) (point-max)
                       'supertag-concept-node-id "concept-1")
    (goto-char (point-min))
    (let ((found (supertag-embark-target-finder)))
      (should (eq (car found) 'supertag-object))
      (should (equal (cadr found) "node concept-1"))
      (should (equal (cddr found) (cons (point-min) (point-max)))))))

(ert-deftest supertag-act-embark-actions-use-the-found-complete-target ()
  "Embark actions consume the finder target instead of detecting point again."
  (with-temp-buffer
    (insert (propertize "Card" 'supertag-entity-id "node-1"))
    (goto-char (point-min))
    (supertag-embark-target-finder)
    (let ((cached (plist-get supertag-embark--target-cache :target))
          menu-target
          opened)
      (should (equal (plist-get cached :node-id) "node-1"))
      (should (eq (plist-get cached :origin) :view-entity))
      (cl-letf (((symbol-function 'supertag-act--target-at-point)
                 (lambda () (ert-fail "Embark action re-detected point")))
                ((symbol-function 'supertag-act--act-on-target)
                 (lambda (target) (setq menu-target target)))
                ((symbol-function 'supertag-goto-node)
                 (lambda (node-id &optional _) (setq opened node-id))))
        (supertag-embark-act)
        (should (eq menu-target cached))
        (supertag-embark-act-dwim)
        (should (equal opened "node-1"))))))

(ert-deftest supertag-act-embark-rejects-a-stale-target ()
  "A modified source buffer invalidates the cached Embark object."
  (with-temp-buffer
    (insert (propertize "Card" 'supertag-entity-id "node-1"))
    (goto-char (point-min))
    (supertag-embark-target-finder)
    (goto-char (point-max))
    (insert " changed")
    (should-error (supertag-embark-act-dwim) :type 'user-error)))

(ert-deftest supertag-act-recognizes-stable-view-node-properties ()
  "Stable IDs emitted by cards become node targets without view changes."
  (dolist (case '((supertag-entity-id . :view-entity)
                  (supertag-reference-node-id . :reference-card)
                  (supertag-source-id . :mention-source)))
    (with-temp-buffer
      (insert (propertize "Card" (car case) "node-1"))
      (goto-char (point-min))
      (let ((target (supertag-act--target-at-point)))
        (should (eq (plist-get target :kind) :node-reference))
        (should (eq (plist-get target :origin) (cdr case)))
        (should (equal (plist-get target :node-id) "node-1"))
        (should (= (plist-get target :begin) (point-min)))
        (should (= (plist-get target :end) (point-max)))))))

(ert-deftest supertag-act-ignores-unsupported-view-contexts ()
  "A context kind without actions falls through to the main menu."
  (with-temp-buffer
    (insert (propertize "Link definition"
                        'supertag-context
                        '(:type :link-definition
                          :link-definition-id "work/blocks")))
    (goto-char (point-min))
    (should-not (supertag-act--target-at-point))
    (let (opened)
      (cl-letf (((symbol-function 'supertag-menu)
                 (lambda () (interactive) (setq opened t))))
        (supertag-act)
        (should opened)))))

;;;----------------------------------------------------------------------
;;; Recognition and default-action contract
;;; (ported from the retired supertag-smart-key tests)
;;;----------------------------------------------------------------------

(ert-deftest supertag-act-retired-field-context-is-unavailable ()
  "Recognized legacy field contexts do not invoke archived editors."
  (with-temp-buffer
    (insert "status")
    (add-text-properties
     (point-min) (point-max)
     '(supertag-context t type :field-value tag-id "task"
       field-name "status" supertag-concept-node-id "concept-id"))
    (goto-char (point-min))
    (let (edited jumped)
      (cl-letf (((symbol-function 'supertag-view-node-edit-at-point)
                 (lambda () (interactive) (setq edited t)))
                ((symbol-function 'supertag-goto-node)
                 (lambda (&rest _) (setq jumped t))))
        (should-error (supertag-act-dwim) :type 'user-error)
        (should-not edited)
        (should-not jumped)))
    (erase-buffer)
    (insert (propertize "field" 'supertag-context
                        '(:type :field :tag-id "task" :field-name "status")))
    (goto-char (point-min))
    (let (edited)
      (cl-letf (((symbol-function 'supertag-schema--edit-field-definition-at-point)
                 (lambda () (interactive) (setq edited t))))
        (should-error (supertag-act-dwim) :type 'user-error)
        (should-not edited)))
    (erase-buffer)
    (insert (propertize "concept" 'supertag-context t
                        'supertag-concept-node-id "concept-id"))
    (goto-char (point-min))
    (let (opened)
      (cl-letf (((symbol-function 'supertag-goto-node)
                 (lambda (node-id &optional _) (setq opened node-id)))
                ((symbol-function 'supertag-view-node-edit-at-point)
                 (lambda () (interactive) (setq opened :edited))))
        (supertag-act-dwim)
        (should (equal opened "concept-id"))))))

(ert-deftest supertag-act-activates-concept-button-and-local-ret ()
  "Existing semantic properties and Emacs interaction primitives stay usable."
  (with-temp-buffer
    (insert (propertize "concept" 'supertag-concept-node-id "concept-id"))
    (goto-char (point-min))
    (let (opened)
      (cl-letf (((symbol-function 'supertag-goto-node)
                 (lambda (node-id &optional _) (setq opened node-id))))
        (supertag-act-dwim)
        (should (equal opened "concept-id"))
        (erase-buffer)
        (insert (propertize "node" 'supertag-node-id "node-id"))
        (goto-char (point-min))
        (supertag-act-dwim)
        (should (equal opened "node-id"))
        (erase-buffer)
        (insert (propertize "a" 'supertag-concept-node-id "concept-id"))
        (insert (propertize "b" 'supertag-ref-id "reference-id"))
        (goto-char (1- (point-max)))
        (supertag-act-dwim)
        (should (equal opened "reference-id"))
        (erase-buffer)
        (insert (propertize "a" 'supertag-context t 'type :field-value))
        (insert (propertize "b" 'supertag-ref-id "reference-id"))
        (goto-char (1- (point-max)))
        (supertag-act-dwim)
        (should (equal opened "reference-id"))))
    (erase-buffer)
    (let (pressed)
      (insert-text-button "button" 'action (lambda (_) (setq pressed :button)))
      (goto-char (point-min))
      (supertag-act-dwim)
      (should (eq pressed :button)))
    (erase-buffer)
    (let ((map (make-sparse-keymap))
          pressed)
      (define-key map (kbd "RET") (lambda () (interactive) (setq pressed :ret)))
      (insert (propertize "legacy link" 'keymap map))
      (goto-char (point-min))
      (supertag-act-dwim)
      (should (eq pressed :ret)))))

(ert-deftest supertag-act-retired-table-cells-are-unavailable ()
  "Recognized Table cells do not invoke archived navigation or editing."
  (with-temp-buffer
    (setq major-mode 'supertag-view-table-mode)
    (insert (propertize "title" 'entity-id "node-id"
                        'supertag-entity-id "node-id" 'col-key :title))
    (goto-char (point-min))
    (let (opened edited)
      (cl-letf (((symbol-function 'derived-mode-p)
                 (lambda (&rest modes) (memq 'supertag-view-table-mode modes)))
                ((symbol-function 'supertag-view-table-goto-node)
                 (lambda () (interactive) (setq opened t)))
                ((symbol-function 'supertag-view-table-edit-cell)
                 (lambda () (interactive) (setq edited t))))
        (should-error (supertag-act-dwim) :type 'user-error)
        (should-not opened)
        (should-not edited)
        (erase-buffer)
        (insert (propertize "status" 'entity-id "node-id"
                            'supertag-entity-id "node-id" 'col-key "status"))
        (goto-char (point-min))
        (setq opened nil)
        (should-error (supertag-act-dwim) :type 'user-error)
        (should-not edited)
        (should-not opened)))))

(ert-deftest supertag-act-retires-inline-tag-default-but-keeps-heading ()
  "Inline Tag default is unavailable; an Org heading still opens Node View."
  (with-temp-buffer
    (org-mode)
    (insert "* Paper #research\n:PROPERTIES:\n:ID: existing-id\n:END:\n")
    (let (table node-view)
      (cl-letf (((symbol-function 'supertag-view-table)
                 (lambda (source &rest _) (setq table source)))
                ((symbol-function 'supertag-view-node--show-side)
                 (lambda (node-id) (setq node-view node-id)))
                ((symbol-function 'supertag-view-node--focus-view) #'ignore))
        (search-backward "research")
        (should-error (supertag-act-dwim) :type 'user-error)
        (should-not table)
        (beginning-of-line)
        (supertag-act-dwim)
        (should (equal node-view "existing-id"))
        (setq node-view nil table nil)
        (end-of-line)
        (supertag-act-dwim)
        (should (equal node-view "existing-id"))
        (should-not table)))))

(ert-deftest supertag-act-node-view-does-not-create-id ()
  "Opening Node View on an untracked heading leaves Org text unchanged."
  (require 'supertag-view-node)
  (with-temp-buffer
    (org-mode)
    (insert "* Untracked heading\nBody\n")
    (goto-char (point-min))
    (let ((before (buffer-string))
          (supertag-view-node--enabled nil))
      (cl-letf (((symbol-function 'supertag-view-node--show-side) #'ignore)
                ((symbol-function 'supertag-view-node--focus-view) #'ignore))
        (should-error (supertag-view-node) :type 'user-error)
        (should-error (supertag-act-dwim) :type 'user-error))
      (should (equal (buffer-string) before))
      (should-not (org-entry-get nil "ID")))))

(ert-deftest supertag-act-does-not-treat-non-prose-hash-as-tag ()
  "Source blocks and Org priority markers are not implicit tag buttons."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src emacs-lisp\n#not-a-tag\n#+end_src\n")
    (search-backward "not-a-tag")
    (should-error (supertag-act-dwim) :type 'user-error))
  (with-temp-buffer
    (org-mode)
    (insert "* [#A] Priority\n:PROPERTIES:\n:ID: existing-id\n:END:\n")
    (search-backward "#A")
    (let (node-view table)
      (cl-letf (((symbol-function 'supertag-view-node--show-side)
                 (lambda (node-id) (setq node-view node-id)))
                ((symbol-function 'supertag-view-node--focus-view) #'ignore)
                ((symbol-function 'supertag-view-table)
                 (lambda (&rest _) (setq table t))))
        (supertag-act-dwim)
        (should (equal node-view "existing-id"))
        (should-not table)))))

(ert-deftest supertag-act-prefers-org-link-over-url-fragment ()
  "A URL fragment stays an Org link instead of becoming an inline tag."
  (with-temp-buffer
    (org-mode)
    (insert "https://example.test/page#section")
    (search-backward "section")
    (let (opened table)
      (cl-letf (((symbol-function 'org-open-at-point)
                 (lambda (&rest _) (setq opened t)))
                ((symbol-function 'supertag-view-table)
                 (lambda (&rest _) (setq table t))))
        (supertag-act-dwim)
        (should opened)
        (should-not table)))
    (erase-buffer)
    (insert (propertize "A" 'supertag-concept-node-id "concept-id"
                        'rear-nonsticky '(supertag-concept-node-id)))
    (let ((link-start (point)))
      (insert "[[id:node-id][Node]]")
      (goto-char link-start)
      (let (opened)
        (cl-letf (((symbol-function 'org-open-at-point)
                   (lambda (&rest _) (setq opened :link)))
                  ((symbol-function 'supertag-goto-node)
                   (lambda (&rest _) (setq opened :concept))))
          (supertag-act-dwim)
          (should (eq opened :link)))))))

(ert-deftest supertag-act-org-link-offers-copy-and-unlink ()
  "A bracket Org link can be copied or replaced by its displayed text."
  (with-temp-buffer
    (org-mode)
    (insert "See [[id:node-1][Shown words]].")
    (search-backward "Shown")
    (let* ((target (supertag-act--target-at-point))
           (actions (supertag-act--actions target))
           (copy (assoc "Copy Org link markup" actions))
           (unlink (assoc "Remove link, keep displayed text" actions))
           (kill-ring nil)
           (interprogram-cut-function nil))
      (should (eq (plist-get target :kind) :org-link))
      (should (equal (plist-get target :text)
                     "[[id:node-1][Shown words]]"))
      (should copy)
      (should unlink)
      (funcall (cdr copy))
      (should (equal (current-kill 0 t) "[[id:node-1][Shown words]]"))
      (funcall (cdr unlink))
      (should (equal (buffer-string) "See Shown words.")))))

(ert-deftest supertag-act-stops-inline-tag-at-org-object-boundary ()
  "The recognizer sees the same range-aware Tag ID as sync and font lock."
  (with-temp-buffer
    (org-mode)
    (insert "* T #outer[[id:n][label]] #ai_suggestions[[id:n][x]]\n")
    (let (source)
      (cl-letf (((symbol-function 'supertag-view-table)
                 (lambda (value &rest _) (setq source value))))
        (search-backward "outer")
        (should-error (supertag-act-dwim) :type 'user-error)
        (should-not source)
        (search-forward "label")
        (should-not (supertag-view-helper-get-tag-at-point))
        (search-forward "ai_suggestions")
        (backward-char (length "ai_suggestions"))
        (setq source nil)
        (should-error (supertag-act-dwim) :type 'user-error)
        (should-not source)
        (search-forward "[x]")
        (backward-char 2)
        (should-not (supertag-view-helper-get-tag-at-point))))))

(ert-deftest supertag-act-menu-offers-target-actions ()
  "The action menu lists per-target actions with the default first."
  (with-temp-buffer
    (org-mode)
    (insert "* Paper #paper\n")
    (search-backward "paper")
    (let (prompt choices renamed)
      (let ((completing-read-function
             (lambda (actual-prompt collection &rest _)
               (setq prompt actual-prompt
                     choices (mapcar #'car collection))
               "Rename tag...")))
        (cl-letf (((symbol-function 'supertag-tag-rename)
                   (lambda (tag-id) (setq renamed tag-id))))
          (supertag-act)
          (should (string-match-p "#paper" prompt))
          (should (equal renamed "paper"))
          (should (equal "All Supertag commands..." (car choices)))
          (should-not (member "Open tagged nodes (default)" choices))
          (should (member "Rename tag..." choices))
          (should (member "Delete tag everywhere..." choices))
          (should (member "All Supertag commands..." choices))))))
  (let ((tag-actions (mapcar #'car
                             (supertag-act--actions
                              '(:kind :tag :tag-id "paper"))))
        (node-actions (mapcar #'car
                              (supertag-act--actions
                               '(:kind :node :node-id "node-id")))))
    (should-not (equal tag-actions node-actions))
    (should (member "Add tag..." node-actions))
    (should-not (member "Add tag..." tag-actions))))

(ert-deftest supertag-act-tag-can-remove-itself-from-current-node ()
  "An inline tag action removes the exact tag from its existing node."
  (with-temp-buffer
    (org-mode)
    (insert "* Paper #paper\n:PROPERTIES:\n:ID: node-1\n:END:\n")
    (search-backward "paper")
    (let* ((target (supertag-act--target-at-point))
           (action (assoc "Remove this tag from current node"
                          (supertag-act--actions target)))
           removed)
      (should (equal (plist-get target :node-id) "node-1"))
      (should action)
      (cl-letf (((symbol-function 'supertag-service-org-remove-tag)
                 (lambda (node-id tag-id)
                   (setq removed (list node-id tag-id)))))
        (funcall (cdr action))
        (should (equal removed '("node-1" "paper")))))))

(ert-deftest supertag-act-mode-binds-dwim-and-action-menu ()
  "The minor mode keeps the frequent default action on lowercase s."
  (should (eq (lookup-key supertag-act-mode-map (kbd "C-c s"))
              #'supertag-act-dwim))
  (should (eq (lookup-key supertag-act-mode-map (kbd "C-c S"))
              #'supertag-act)))

(ert-deftest supertag-act-node-does-not-offer-retired-field-editors ()
  "Node actions do not advertise archived whole-page or quick field editors."
  (let ((labels (mapcar #'car
                        (supertag-act--actions
                         '(:kind :node :node-id "node-1")))))
    (should-not (member "Edit fields (whole page)..." labels))
    (should-not (member "Quick edit field..." labels))))

(defun supertag-test--transient-layout-commands (prefix)
  "Return every suffix command stored in PREFIX's transient layout."
  (let (commands)
    (cl-labels
        ((walk
          (form)
          (cond
           ((and (consp form) (eq (car form) 'transient-suffix))
            (when-let* ((command (plist-get (cdr form) :command)))
              (push command commands)))
           ((vectorp form) (mapc #'walk (append form nil)))
           ((consp form) (mapc #'walk form)))))
      (walk (get prefix 'transient--layout)))
    (nreverse commands)))

(defun supertag-test--transient-column-descriptions (prefix)
  "Return the column descriptions in PREFIX's transient layout."
  (let (descriptions)
    (cl-labels
        ((walk
          (form)
          (cond
           ((and (vectorp form)
                 (> (length form) 1)
                 (eq (aref form 0) 'transient-column))
            (push (plist-get (aref form 1) :description) descriptions))
           ((vectorp form) (mapc #'walk (append form nil)))
           ((consp form) (mapc #'walk form)))))
      (walk (get prefix 'transient--layout)))
    (nreverse descriptions)))

(ert-deftest supertag-menu-layout-has-no-ghost-commands ()
  "Every top-level or nested menu entry names a loaded command."
  (should
   (equal (supertag-test--transient-column-descriptions 'supertag-menu)
          '("记录 Capture & Write" "整理 Organize"
            "查找 Find & View" "维护 Maintain")))
  (let ((pending '(supertag-menu supertag-menu-more))
        seen)
    (while pending
      (let ((prefix (pop pending)))
        (unless (memq prefix seen)
          (push prefix seen)
          (ert-info ((format "Transient prefix %S" prefix))
            (should (fboundp prefix))
            (should (get prefix 'transient--layout)))
          (dolist (command (supertag-test--transient-layout-commands prefix))
            (ert-info ((format "Menu command %S from %S" command prefix))
              (should (fboundp command)))
            (when (get command 'transient--layout)
              (push command pending))))))))

(ert-deftest supertag-menu-does-not-offer-archived-visual-uis ()
  "Default menus do not advertise archived Board or Graph UIs."
  (let ((commands
         (supertag-test--transient-layout-commands
          'supertag-menu-find-more)))
    (should-not (memq 'supertag-board-mode commands))
    (should-not (memq 'supertag-graph-ui-open commands))))

(ert-deftest supertag-menu-and-act-have-no-archived-lazy-entry ()
  "Menus and Embark delegation cannot lazy-load retired standalone UIs."
  (let ((commands (append
                   (supertag-test--transient-layout-commands 'supertag-menu)
                   (supertag-test--transient-layout-commands
                    'supertag-menu-organize-more)
                   (supertag-test--transient-layout-commands
                    'supertag-menu-find-more)
                   (supertag-test--transient-layout-commands
                    'supertag-menu-maintain-more))))
    (dolist (command '(supertag-menu--view-table
                       supertag-menu--view-kanban
                       supertag-menu--view-schema
                       supertag-board-mode
                       supertag-graph-ui-open
                       supertag-menu--ontology-migration-preview
                       supertag-menu--ontology-migration-apply
                       supertag-menu--ontology-tool-list
                       supertag-menu--quick-edit-field
                       supertag-menu--edit-fields
                       supertag-menu--capture
                       supertag-menu--capture-with-template
                       supertag-menu--insert-embed
                       supertag-menu--convert-link-to-embed
                       supertag-menu--virtual-column-create
                       supertag-menu--virtual-column-edit
                       supertag-menu--virtual-column-delete
                       supertag-menu--virtual-column-list))
      (should-not (memq command commands))))
  (with-temp-buffer
    (insert (propertize "tag" 'supertag-context t
                        'type :tag 'tag-id "task"))
    (goto-char (point-min))
    (supertag-embark-target-finder)
    (cl-letf (((symbol-function 'require)
               (lambda (feature &rest _)
                 (when (memq feature '(supertag-view-schema
                                       supertag-view-table
                                       supertag-view-kanban))
                   (ert-fail "Retired UI was lazy-loaded")))))
      (should-error (supertag-embark-act-dwim) :type 'user-error))))

(provide 'test-ui-act)
;;; test-ui-act.el ends here
