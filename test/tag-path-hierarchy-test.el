;;; tag-path-hierarchy-test.el --- Explicit Tag hierarchy -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'supertag-api)
(require 'supertag-tag)
(require 'supertag-services-sync)

(defmacro supertag-path-test--with-store (&rest body)
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "supertag-path-" t))
          (supertag-data-directory tmp)
          (supertag--base-data-directory tmp)
          (supertag-db-file (expand-file-name "store.el" tmp))
          (supertag--store nil)
          (supertag--subscribers (make-hash-table :test 'equal)))
     (unwind-protect
         (progn (supertag--ensure-store) ,@body)
       (delete-directory tmp t))))

(ert-deftest supertag-path-hierarchy-comes-from-extends ()
  (supertag-path-test--with-store
    (let* ((media (plist-get (supertag-tag-create '(:name "media")) :id))
           (other (plist-get (supertag-tag-create '(:name "mediax")) :id))
           (book (plist-get (supertag-tag-create (list :name "book" :extends (list media))) :id))
           (note (plist-get (supertag-tag-create '(:name "note")) :id))
           (ref (plist-get (supertag-tag-create (list :name "ref" :extends (list note))) :id))
           (paper (plist-get (supertag-tag-create (list :name "paper" :extends (list ref))) :id)))
      (should (equal (list media) (supertag-tag-parents book)))
      (should (equal (list media) (supertag-tag-ancestors book)))
      (should (equal "media › book" (supertag-tag-display-name book)))
      (should (member book (supertag-tag-descendants media)))
      (should (member book (supertag-find-tag-descendants media)))
      (should-not (member book (supertag-tag-descendants other)))
      (should-not (member book (supertag-find-tag-descendants other)))
      (should (equal (list ref note) (supertag-tag-ancestors paper)))
      (should (equal "note › ref › paper" (supertag-tag-display-name paper)))
      (should (equal (sort (list paper ref) #'string<)
                     (supertag-tag-descendants note)))
      (should (equal (list book) (supertag-query-tag-children media))))))

(ert-deftest supertag-path-multi-parent-hierarchy ()
  (supertag-path-test--with-store
    (let* ((tools (plist-get (supertag-tag-create '(:name "tools")) :id))
           (topics (plist-get (supertag-tag-create '(:name "topics")) :id))
           (work (plist-get (supertag-tag-create (list :name "work" :extends (list topics)))
                            :id))
           (emacs (plist-get (supertag-tag-create
                              (list :name "emacs" :extends (list tools topics)))
                             :id)))
      ;; two direct parents, in stored order
      (should (equal (list tools topics) (supertag-tag-parents emacs)))
      ;; the transitive union is breadth-first and deduplicated
      (should (equal (list tools topics) (supertag-tag-ancestors emacs)))
      (should (equal "tools · topics › emacs" (supertag-tag-display-name emacs)))
      ;; both parents own the same descendant
      (should (equal (sort (list emacs work) #'string<)
                     (supertag-tag-descendants topics)))
      (should (equal (list emacs) (supertag-tag-descendants tools)))
      (should (member emacs (supertag-query-tag-children tools)))
      (should (member emacs (supertag-query-tag-children topics)))
      ;; a third parent appends; nothing is replaced
      (supertag-tag-add-parent emacs work)
      (should (equal (list tools topics work) (supertag-tag-parents emacs)))
      (should (equal "tools · topics · work › emacs"
                     (supertag-tag-display-name emacs)))
      ;; a cycle through any parent path is rejected and writes nothing
      (should-error (supertag-tag-add-parent topics emacs) :type 'user-error)
      (should-not (supertag-tag-parents topics))
      (should-error (supertag-tag-set-parent tools (list emacs)) :type 'user-error)
      (should-not (supertag-tag-parents tools))
      ;; clearing the parents is what nil means
      (should-not (supertag-tag-set-parent emacs nil))
      (should-not (supertag-tag-parents emacs))
      (should (equal "emacs" (supertag-tag-display-name emacs)))
      ;; several segments of one path are all created and linked
      (let* ((leaf (supertag-tag-ensure-path "tools/git/config"))
             (git (supertag-tag-resolve-occurrence "git")))
        (should (equal "config" (plist-get (supertag-tag-get leaf) :name)))
        (should (equal (list tools) (supertag-tag-parents git)))
        (should (equal (list git) (supertag-tag-parents leaf)))
        (should (equal (list git tools) (supertag-tag-ancestors leaf)))
        (should (equal "tools › git › config" (supertag-tag-display-name leaf))))
      ;; full-width `／' is the same separator
      (let ((shell (supertag-tag-ensure-path "tools／shell")))
        (should (equal "shell" (plist-get (supertag-tag-get shell) :name)))
        (should (equal (list tools) (supertag-tag-parents shell)))))))

(ert-deftest supertag-path-capf-offers-new-for-a-missing-parent-edge ()
  (supertag-path-test--with-store
    (let* ((topics (plist-get (supertag-tag-create '(:name "topics")) :id))
           (emacs (plist-get (supertag-tag-create '(:name "emacs")) :id)))
      ;; Both Tags exist but are unrelated: `[New]' completes the edge.
      (let* ((candidates (supertag-completion--get-completion-table "topics/emacs"))
             (candidate (cl-find-if (lambda (s) (get-text-property 0 'is-new-tag s))
                                    candidates)))
        (should candidate)
        (should (equal "topics › emacs"
                       (substring-no-properties
                        (car (car (supertag-tag-affixate-candidates (list candidate)))))))
        ;; Committing runs `supertag-tag-ensure-path' for the typed path; the
        ;; full buffer commit is covered by
        ;; `supertag-path-completion-creates-the-path-and-writes-the-leaf'.
        (supertag-tag-ensure-path "topics/emacs"))
      (should (equal (list topics) (supertag-tag-parents emacs)))
      ;; With the edge in place a path has nothing left to offer.
      (should-not (cl-find-if (lambda (s) (get-text-property 0 'is-new-tag s))
                              (supertag-completion--get-completion-table "topics/emacs")))
      (should emacs))))

(ert-deftest supertag-path-ensure-path-adds-a-parent-edge ()
  (supertag-path-test--with-store
    ;; Both ends exist already: the path only adds the missing edge.
    (let* ((topics (plist-get (supertag-tag-create '(:name "topics")) :id))
           (tools (plist-get (supertag-tag-create '(:name "tools")) :id))
           (emacs (plist-get (supertag-tag-create '(:name "emacs")) :id)))
      (should (equal emacs (supertag-tag-ensure-path "topics/emacs")))
      (should (equal (list topics) (supertag-tag-parents emacs)))
      ;; Idempotent: a second call adds nothing.
      (should (equal emacs (supertag-tag-ensure-path "topics/emacs")))
      (should (equal (list topics) (supertag-tag-parents emacs)))
      ;; An existing Tag keeps its parents; the path adds one more.
      (supertag-tag-add-parent emacs tools)
      (should (equal emacs (supertag-tag-ensure-path "topics/emacs")))
      (should (equal (list topics tools) (supertag-tag-parents emacs)))
      ;; A path with one segment is ordinary creation by token.
      (should (equal emacs (supertag-tag-ensure-path "emacs")))
      (should (equal "fresh" (plist-get (supertag-tag-get
                                         (supertag-tag-ensure-path "fresh"))
                                        :name)))
      (should-error (supertag-tag-ensure-path "topics//emacs") :type 'user-error)
      (should-error (supertag-tag-ensure-path "") :type 'user-error))))

(ert-deftest supertag-path-ensure-path-rolls-back-a-cycle ()
  (supertag-path-test--with-store
    (let ((tags-before (hash-table-count (supertag-store-get-collection :tags)))
          (dirty-before (supertag-dirty-p)))
      ;; `b' extends `a', so completing `side/b/a' would close a loop.
      (let* ((a (plist-get (supertag-tag-create '(:name "a")) :id))
             (b (plist-get (supertag-tag-create (list :name "b" :extends (list a))) :id)))
        (should-error (supertag-tag-ensure-path "side/b/a") :type 'user-error)
        ;; nothing was written, not even the new `side' segment
        (should-not (supertag-tag-resolve-occurrence "side"))
        (should (equal (list a) (supertag-tag-parents b)))
        (should (equal (+ 2 tags-before)
                       (hash-table-count (supertag-store-get-collection :tags))))
        (should (equal dirty-before (supertag-dirty-p)))))))

(ert-deftest supertag-path-validates-explicit-inheritance ()
  (supertag-path-test--with-store
    (let* ((media (plist-get (supertag-tag-create '(:name "media")) :id))
           (book (plist-get (supertag-tag-create (list :name "book" :extends (list media)))
                            :id)))
      (should-error (supertag-tag-create '(:name "orphan" :extends ("missing")))
                    :type 'user-error)
      (should-error (supertag-tag-create '(:name "wrong-type" :extends 42))
                    :type 'user-error)
      ;; `:extends' is a parent list; the single-parent string shape is gone.
      (should-error (supertag-tag-create '(:name "string-parent" :extends "media"))
                    :type 'user-error)
      (should-error (supertag-tag-update media
                                         (lambda (tag) (plist-put tag :extends book)))
                    :type 'user-error)
      (should-error (supertag-tag-update book
                                         (lambda (tag) (plist-put tag :extends 42)))
                    :type 'user-error)
      ;; A path separator belongs to `supertag-tag-ensure-path', not to a name.
      (should-error (supertag-tag-create '(:name "#media/book"))
                    :type 'user-error)
      (should-not (supertag-tag-resolve-occurrence "media/book")))))

(ert-deftest supertag-path-org-native-tags-require-explicit-import ()
  (with-temp-buffer
    (org-mode)
    (insert "* Note #book :ATTACH:@person:\n")
    (let ((headline (car (org-element-contents (org-element-parse-buffer)))))
      (let ((supertag-sync-import-org-tags nil))
        (should (equal '("book")
                       (plist-get (supertag-extractor--tags headline nil nil)
                                  :tag-occurrences))))
      (let ((supertag-sync-import-org-tags t))
        (should (equal '("book" "ATTACH" "@person")
                       (plist-get (supertag-extractor--tags headline nil nil)
                                  :tag-occurrences)))))))

(ert-deftest supertag-path-import-completes-the-hierarchy ()
  (supertag-path-test--with-store
    ;; A legacy `media/book' occurrence token resolves through the hierarchy it
    ;; names; the import creates the path and never rewrites the Org token.
    (let* ((leaf (car (supertag--create-tag-entities '("media/book"))))
           (media (supertag-tag-resolve-occurrence "media")))
      (should leaf)
      (should (equal "book" (plist-get (supertag-tag-get leaf) :name)))
      (should (equal (list media) (supertag-tag-parents leaf)))
      (should (equal '("book")
                     (mapcar (lambda (id) (plist-get (supertag-tag-get id) :name))
                             (supertag--create-tag-entities '("media/book")))))
      (should (equal "x/y" (supertag--normalize-tag-id "x/y"))))))

(ert-deftest supertag-path-membership-creates-path-name ()
  (supertag-path-test--with-store
    (supertag-store-put-entity :nodes "node" '(:id "node" :title "Node" :tags nil))
    (should (supertag-ops-add-tag-to-node "node" "media/book" :create-if-needed t))
    (let* ((leaf (supertag-tag-resolve-occurrence "book"))
           (media (supertag-tag-resolve-occurrence "media")))
      (should (equal "book" (plist-get (supertag-tag-get leaf) :name)))
      (should (equal (list media) (supertag-tag-parents leaf)))
      (should (member leaf (plist-get (supertag-node-get "node") :tags))))))

(ert-deftest supertag-path-stored-inheritance-is-active ()
  (supertag-path-test--with-store
    (let ((media (plist-get (supertag-tag-create '(:name "media")) :id)))
      (supertag-store-put-entity :tags "legacy"
                                (list :id "legacy" :name "legacy" :type :tag
                                      :extends (list media) :aliases '("book")))
      (supertag-tag-index-rebuild)
      (should (member "legacy" (supertag-tag-descendants media)))
      (should (equal '("legacy") (supertag-query-tag-children media)))
      (should (equal "legacy" (supertag-tag-resolve-occurrence "book")))
      (should (equal (list media) (plist-get (supertag-tag-get "legacy") :extends)))
      (should-not (plist-member (supertag-api-schema "legacy") :extends)))))

(ert-deftest supertag-path-completion-creates-the-path-and-writes-the-leaf ()
  (supertag-path-test--with-store
    (with-temp-buffer
      (org-mode)
      (setq buffer-file-name (expand-file-name "node.org" tmp))
      (insert "* Note\n:PROPERTIES:\n:ID: node\n:END:\n#media/book")
      (save-buffer)
      (let* ((candidates (supertag-completion--get-completion-table "media/book"))
             (candidate (cl-find-if (lambda (s) (get-text-property 0 'is-new-tag s)) candidates)))
        (should candidate)
        (should (equal "media/book" (get-text-property 0 'new-tag-name candidate)))
        (should (equal "media › book"
                       (substring-no-properties
                        (car (car (supertag-tag-affixate-candidates (list candidate)))))))
        (supertag-completion--post-completion-action candidate)
        (let ((leaf (supertag-tag-resolve-occurrence "book")))
          (should leaf)
          (should (equal "book" (supertag-service-org--tag-token leaf)))
          (should (equal (list (supertag-tag-resolve-occurrence "media"))
                         (supertag-tag-parents leaf)))
          ;; the typed path is replaced by the leaf token
          (should (string-match-p "#book" (buffer-string)))
          (should-not (string-match-p "#media/book" (buffer-string)))
          ;; a second pass has nothing left to create or link
          (should-not (cl-find-if (lambda (s) (get-text-property 0 'is-new-tag s))
                                  (supertag-completion--get-completion-table
                                   "media/book"))))))))


;;; D1 independent process: parent projection is setup, never the cold caller.
(require 'document-fixture)

(defconst supertag-path-test--member-functions
  '(supertag-capture--tag-membership-present-p supertag-capture-add-tags-to-nodes
    supertag-capture-replace-tag-on-node supertag-capture-add-tag-to-nodes
    supertag-node-add-tag supertag-node-remove-tag supertag-node-has-tag-p supertag-node-toggle-tag
    supertag-service-org--semantic-tag-id supertag-service-org--tag-token
    supertag-service-org--token-identifies-p supertag-service-org--tag-membership-present-p
    supertag-service-org--filetags supertag-service-org--set-filetags
    supertag-service-org-add-tag supertag-service-org-remove-tag supertag-service-org-replace-tag
    supertag-view-helper-at-tag-line-p supertag-view-helper-insert-tag-text
    supertag-view-helper-remove-tag-text supertag-view-helper-rename-tag-text-in-node))

(defun supertag-path-test--cold-member (operation)
  "Run OPERATION in a fresh process against a real parent-projected temporary file."
  (supertag-document-test-with-vault
    (with-current-buffer (find-file-noselect plain)
      (erase-buffer)
      (insert ":PROPERTIES:\n:ID: file-node\n:END:\n#+TITLE: File\n#+FILETAGS: :canonical:\nFile body\n* Second #canonical\n:PROPERTIES:\n:ID: second-node\n:END:\nSecond body\n** Child\nChild #untouched\n* Sibling\nSibling unchanged\n")
      (save-buffer))
    (supertag-tag-create '(:id "stable" :name "canonical" :aliases ("alias")))
    (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
    (let* ((root supertag-path-test--source-root)
           (snapshot (expand-file-name "projected.el" tmp))
           (dependencies (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
           (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
           (process-environment (copy-sequence process-environment))
           (child
            `(progn
               (require 'cl-lib)
               (require 'ert)
               (setq user-emacs-directory ,(expand-file-name "child/" tmp)
                     supertag-data-directory ,supertag-data-directory
                     supertag--base-data-directory ,supertag-data-directory
                     supertag-db-file ,supertag-db-file
                     supertag-db-backup-directory ,supertag-db-backup-directory
                     supertag-sync-state-file ,(expand-file-name "child-sync.el" tmp)
                     supertag-sync--state-source supertag-sync-state-file
                     org-id-locations-file ,(expand-file-name "child-ids" tmp)
                     org-id-track-globally nil
                     supertag-sync-directories nil supertag-active-sync-directory nil
                     supertag-automation--enabled nil supertag-automation-sync--enabled nil
                     auto-save-default nil make-backup-files nil load-prefer-newer t)
               (let ((after-init-time nil))
                 (load ,(expand-file-name (if (eq operation 'ops-first) (if (equal (getenv "SUPERTAG_LB_STAGE") "before") "supertag-ops-node.el" "supertag-node.el") "supertag-tag.el") root) nil nil t))
               (princ "D1-ENTRY-LOADED\n")
               (when (eq ',operation 'ops-first)
                 (dolist (symbol '(supertag-node-add-tag supertag-node-remove-tag
                                   supertag-node-has-tag-p supertag-node-toggle-tag))
                   (should (autoloadp (symbol-function symbol)))
                   (should (equal (nth 1 (symbol-function symbol)) "supertag-tag"))))
               (should (featurep 'supertag-service-org))
               (dolist (feature '(supertag-services-sync supertag-query supertag-services-query supertag-services-note-query
                                  supertag-services-ui supertag-ui-commands supertag-view-helper))
                 (should-not (featurep feature))
                 (should-not (cl-find-if
                              (lambda (row) (and (stringp (car row))
                                                 (equal (file-name-base (car row)) (symbol-name feature))))
                              load-history)))
               (should-not (bound-and-true-p supertag--initialized))
               (should-not (file-exists-p supertag-db-file))
               ;; Read the parent process's real projected data, not fabricated Nodes.
               (setq supertag--store (with-temp-buffer
                                      (insert-file-contents ,snapshot)
                                      (read (current-buffer))))
               (setq org-mode-hook nil enable-theme-functions nil)
               (cl-labels ((disk (path) (with-temp-buffer (insert-file-contents path) (buffer-string)))
                           (owner ()
                             (dolist (symbol ',supertag-path-test--member-functions)
                               (should (equal (symbol-file symbol 'defun)
                                              ,(expand-file-name "supertag-tag.el" root))))))
                 (pcase ',operation
                   ('owner
                    (owner)
                    (let ((after-init-time nil))
                      (dolist (entry (if (equal (getenv "SUPERTAG_VWD_STAGE") "before")
                                          '("supertag-view-helper.el" "supertag-node.el" "supertag-service-org.el")
                                        '("supertag-node.el" "supertag-service-org.el")))
                        (load (expand-file-name entry ,root) nil nil t)))
                    (owner))
                   ('ops-first
                    (supertag-node-add-tag "document-node" "stable")
                    (should (supertag-node-has-tag-p "document-node" "stable"))
                    (supertag-node-remove-tag "document-node" "stable")
                    (should-not (supertag-node-has-tag-p "document-node" "stable"))
                    (supertag-node-toggle-tag "document-node" "stable")
                    (should (supertag-node-has-tag-p "document-node" "stable"))
                    (supertag-node-toggle-tag "document-node" "stable")
                    (should-not (supertag-node-has-tag-p "document-node" "stable"))
                    (owner)
                    (let ((definition (symbol-function 'supertag-node-add-tag)))
                      (if (equal (getenv "SUPERTAG_LB_STAGE") "before")
                          (load ,(expand-file-name "supertag-ops-node.el" root) nil nil t)
                        (require 'supertag-node))
                      (should (eq definition (symbol-function 'supertag-node-add-tag))))
                    (owner))
                   ('provider-error
                    (let* ((before (disk ,file))
                           (store-before (prin1-to-string supertag--store))
                           (real (symbol-function 'autoload-do-load))
                           (real-create (symbol-function 'supertag-tag-create))
                           (definition (symbol-function 'supertag-sync--parse-file-header))
                           (creates 0) (hits 0))
                      ;; Current prerequisite is Sync, not the already loaded saver.
                      (should (featurep 'supertag-service-org))
                      (should (autoloadp definition))
                      (should (equal "supertag-services-sync" (nth 1 definition)))
                      (should-not (featurep 'supertag-services-sync))
                      (should-not (cl-find-if
                                   (lambda (row) (and (stringp (car row))
                                                      (equal (file-name-base (car row)) "supertag-services-sync")))
                                   load-history))
                      (should-not supertag--transaction-active)
                      (cl-letf (((symbol-function 'supertag-tag-create)
                                 (lambda (&rest args)
                                   (cl-incf creates)
                                   (apply real-create args)))
                                ((symbol-function 'autoload-do-load)
                                 (lambda (cell &optional name macro-only)
                                   (if (eq name 'supertag-sync--parse-file-header)
                                       (progn
                                         (cl-incf hits)
                                         (should (eq definition cell))
                                         (should (= creates 0))
                                         (should-not supertag--transaction-active)
                                         (error "D1 Sync prerequisite unavailable"))
                                     (funcall real cell name macro-only)))))
                        (should (equal '(error "D1 Sync prerequisite unavailable")
                                       (should-error (supertag-capture-add-tags-to-nodes
                                                      '("document-node") '("new/provider"))
                                                     :type 'error))))
                      (should (= hits 1))
                      (should (= creates 0))
                      (should-not supertag--transaction-active)
                      (should (equal before (disk ,file)))
                      (should (equal store-before (prin1-to-string supertag--store)))
                      (should-not (supertag-tag-resolve-occurrence "new/provider"))
                      (should (featurep 'supertag-service-org))
                      (should-not (featurep 'supertag-services-sync))
                      (should-not (cl-find-if
                                   (lambda (row) (and (stringp (car row))
                                                      (equal (file-name-base (car row)) "supertag-services-sync")))
                                   load-history))
                      (with-current-buffer (find-file-noselect ,file)
                        (should (equal before (buffer-string)))
                        (should-not (buffer-modified-p)))))
                   ('bulk
                    (let ((saves nil) (records nil) observer ids)
                      ;; Observe real provider functions only after its defuns exist.
                      (setq observer
                            (lambda (_loaded)
                              (when (featurep 'supertag-service-org)
                                (remove-hook 'after-load-functions observer)
                                (advice-add 'supertag-service-org--save-current-buffer :before
                                            (lambda () (push (buffer-file-name) saves)))
                                (advice-add 'supertag-service-org-save-and-record-tags-at-point :after
                                            (lambda (id)
                                              (should (equal (buffer-string) (disk (buffer-file-name))))
                                              (push id records))))))
                      (if (featurep 'supertag-service-org)
                          (funcall observer nil)
                        (add-hook 'after-load-functions observer))
                      (setq ids (supertag-capture-add-tags-to-nodes
                                 '("document-node" "second-node") '("alias" "media/book")))
                      (princ (format "D1-BULK-COUNTS saves=%S records=%S\n" saves records))
                      (should (equal (car ids) "stable"))
                      (should (= (length ids) 2))
                      (let ((leaf (supertag-tag-resolve-occurrence "book")))
                        (should leaf)
                        (should (equal (list (supertag-tag-resolve-occurrence "media"))
                                       (supertag-tag-parents leaf))))
                      (dolist (pair ',(list (cons "document-node" file) (cons "second-node" plain)))
                        (should (= 1 (cl-count (car pair) records :test #'equal)))
                        (should (= 1 (cl-count (cdr pair) saves :test #'equal)))
                        (should (equal (sort (copy-sequence ids) #'string<)
                                       (sort (copy-sequence (plist-get (supertag-node-get (car pair)) :tags)) #'string<)))
                        (with-current-buffer (find-file-noselect (cdr pair))
                          (should-not (buffer-modified-p))
                          (should (equal (buffer-string) (disk (cdr pair)))))))))
                 (when (memq ',operation '(replace remove file-replace file-remove))
                   (let* ((file-level (memq ',operation '(file-replace file-remove)))
                          (node (if file-level "file-node" "second-node"))
                          (suffix (substring (disk ,plain) (string-match "\\*\\* Child" (disk ,plain))))
                          (original-file-body (substring (disk ,plain) 0 (string-match "\\* Second" (disk ,plain)))))
                     (if (memq ',operation '(replace file-replace))
                         (supertag-capture-replace-tag-on-node node "alias" "work/new")
                       (supertag-service-org-remove-tag node "alias"))
                     (should-not (member "stable" (plist-get (supertag-node-get node) :tags)))
                     (when (memq ',operation '(replace file-replace))
                       (let ((leaf (supertag-tag-resolve-occurrence "new")))
                         (should (member leaf
                                         (plist-get (supertag-node-get node) :tags)))
                         (should (equal (list (supertag-tag-resolve-occurrence "work"))
                                        (supertag-tag-parents leaf)))))
                     (should (string-suffix-p suffix (disk ,plain)))
                     (unless file-level (should (string-prefix-p original-file-body (disk ,plain))))
                     (with-current-buffer (find-file-noselect ,plain)
                       (should-not (buffer-modified-p))
                       (should (equal (buffer-string) (disk ,plain))))))
                 (princ "D1-COLD-PASS\n")))))
      (with-temp-file snapshot (let ((print-length nil) (print-level nil)) (prin1 supertag--store (current-buffer))))
      (with-temp-buffer
        (make-directory (expand-file-name "child-home" tmp) t)
        ;; Pin the child cwd before HOME is repointed.
        (setq default-directory (file-truename default-directory))
        (setenv "HOME" (expand-file-name "child-home" tmp))
        (setenv "CFFIXED_USER_HOME" (getenv "HOME"))
        (setenv "EMACSLOADPATH" (concat (mapconcat #'identity dependencies path-separator) path-separator))
        (let* ((args (append '("-Q" "--batch")
                             (apply #'append (mapcar (lambda (dir) (list "-L" dir)) dependencies))
                             (list "-L" root "--eval"
                                   (prin1-to-string
                                    `(condition-case problem
                                         (unwind-protect ,child
                                           (setq emacs-startup-hook nil kill-emacs-hook nil
                                                 org-mode-hook nil enable-theme-functions nil))
                                       (error (princ (format "D1-COLD-ERROR:%S\n" problem))
                                              (kill-emacs 1)))))))
               (status (apply #'call-process program nil t nil args))
               (output (buffer-string)))
          (unless (and (equal status 0) (string-match-p "D1-ENTRY-LOADED" output)
                       (string-match-p "D1-COLD-PASS" output))
            (ert-fail (format "D1 cold %s exit=%S\n%s" operation status output)))
          (princ (format "D1 cold %s: exit=%S ENTRY-LOADED/PASS\n" operation status))
          (when (string-match "D1-BULK-COUNTS[^\n]*" output)
            (princ (concat (match-string 0 output) "\n"))))))))

(ert-deftest supertag-path-member-cold-owner-is-tag ()
  (supertag-path-test--cold-member 'owner))


(ert-deftest supertag-path-member-cold-ops-first ()
  (supertag-path-test--cold-member 'ops-first))

(ert-deftest supertag-path-member-cold-bulk ()
  (supertag-path-test--cold-member 'bulk))

(ert-deftest supertag-path-member-cold-replace ()
  (supertag-path-test--cold-member 'replace))

(ert-deftest supertag-path-member-cold-remove ()
  (supertag-path-test--cold-member 'remove))

(ert-deftest supertag-path-member-cold-file-replace ()
  (supertag-path-test--cold-member 'file-replace))

(ert-deftest supertag-path-member-cold-file-remove ()
  (supertag-path-test--cold-member 'file-remove))

(ert-deftest supertag-path-member-cold-provider-error-is-zero-write ()
  (supertag-path-test--cold-member 'provider-error))

(provide 'tag-path-hierarchy-test)

(defconst supertag-path-test--source-root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(defconst supertag-path-test--merge-functions
  '(supertag-tag-merge--unique
    supertag-tag-merge--affected-nodes
    supertag-tag-merge--canonical-token
    supertag-tag-merge--file-token-rewrites
    supertag-tag-merge--file-conflicts
    supertag-tag-merge--replace-tag-value
    supertag-tag-merge--plist-p
    supertag-tag-merge--rewrite-structured
    supertag-tag-merge--string-mentions-source-p
    supertag-tag-merge--saved-query-changes
    supertag-tag-merge-plan
    supertag-tag-merge--rewrite-node-tags
    supertag-tag-merge--rewrite-nodes
    supertag-tag-merge--delete-sources
    supertag-tag-merge--rewrite-relations
    supertag-tag-merge--rewrite-automations
    supertag-tag-merge--copy-view-configs
    supertag-tag-merge--rewrite-view-configs
    supertag-tag-merge--apply-query-updates
    supertag-tag-merge--snapshot-files
    supertag-tag-merge--restore-files
    supertag-tag-merge--delete-snapshot
    supertag-tag-merge--rebuild-derived-state
    supertag-tag-merge--rewrite-files
    supertag-tag-merge-execute
    supertag-tag-rename--mapped
    supertag-tag-rename--rewrite-values
    supertag-tag-rename--rewrite-structured
    supertag-tag-rename--saved-query-changes
    supertag-tag-rename-plan
    supertag-tag-rename--rewrite-tags
    supertag-tag-rename--rewrite-nodes
    supertag-tag-rename--rewrite-relations
    supertag-tag-rename--rewrite-store-configs
    supertag-tag-rename--rewrite-view-configs
    supertag-tag-rename--rewrite-files
    supertag-tag-rename-execute
    supertag-view-helper-rename-tag-text-in-buffer
    supertag-view-helper-rename-tag-text-in-files))

(defun supertag-path-test--cold-tag-load (entry &optional state-order)
  "Check ENTRY cold in an isolated Emacs, optionally exercising STATE-ORDER."
  (let* ((root supertag-path-test--source-root)
         (temporary (make-temp-file "supertag-tag-cold-" t))
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
               (let ((query-sentinel (list (cons "sentinel" "(tag \"keep\")")))
                     (view-sentinel (make-hash-table :test 'eq)))
                 (when ',state-order
                   (puthash 'sentinel '(:id sentinel :name "Keep" :tag "keep") view-sentinel)
                   (setq supertag-query-saved query-sentinel
                         supertag--view-configs view-sentinel))
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
                 (when (or (featurep ',entry) (featurep 'supertag-tag)
                           (featurep 'supertag-ops-tag)
                           (featurep 'supertag-core-tag-path)
                           (featurep 'supertag-ops-tag-merge))
                   (error "Cold-load setup: preloaded entry or Tag"))
                 (when (directory-files ,root nil "\\.elc\\'")
                   (error "Cold-load setup: root bytecode present"))
                 ;; Main's late-load branch would otherwise initialize the DB.
                 (let ((after-init-time nil))
                   (load ,(expand-file-name (concat (symbol-name entry) ".el") root) nil nil t))
                 (unless (featurep ',entry) (error "Entry failed to provide feature"))
                 (princ ,(format "ENTRY-LOADED:%s\n" entry))
                 (dolist (old '(supertag-ops-tag supertag-core-tag-path supertag-ops-tag-merge))
                   (when (featurep old)
                     (error "Retired Tag feature still loaded: %s" old))
                   (when (file-exists-p
                          (expand-file-name (concat (symbol-name old) ".el") ,root))
                     (error "Retired Tag source still exists: %s" old))
                   (dolist (loaded load-history)
                     (when (and (stringp (car loaded))
                                (equal (file-name-base (car loaded)) (symbol-name old)))
                       (error "Retired Tag module in load-history: %s" (car loaded)))))
                 ;; VWD: Node entry is observed before loading the separate Tag fixture.
                 (when (eq ',entry 'supertag-node)
                   (when (featurep 'supertag-tag)
                     (error "VWD Node cold unexpectedly loaded supertag-tag"))
                   (when (featurep 'supertag-view-framework)
                     (error "VWD Node cold unexpectedly loaded supertag-view-framework"))
                   (when (featurep 'supertag-view-helper)
                     (error "VWD Node cold unexpectedly loaded supertag-view-helper"))
                   (princ "VWD-NODE-COLD-BEFORE-TAG\n")
                   (require 'supertag-tag))
                 (unless (featurep 'supertag-tag)
                   (error "Consolidated Tag feature missing"))
                 (dolist (symbol ',supertag-path-test--merge-functions)
                   (unless (and (fboundp symbol)
                                (equal (symbol-file symbol 'defun)
                                       ,(expand-file-name "supertag-tag.el" root)))
                     (error "Merged function owner is not Tag: %s (%S)"
                            symbol (symbol-file symbol 'defun))))
                 (dolist (symbol '(supertag-tag-parents supertag-tag-ancestors
                                   supertag-tag-display-name supertag-tag-create
                                   supertag-tag-get supertag-tag-update supertag-tag-delete
                                   supertag-tag-resolve-occurrence supertag-tag-index-rebuild
                                   supertag-ops-add-tag-to-node supertag-sanitize-tag-name))
                   (unless (fboundp symbol) (error "Retained Tag operation missing: %s" symbol)))
                 (unless (equal (supertag-sanitize-tag-name "#my tag") "my_tag")
                   (error "Retained pure Tag operations changed"))
                 (when (eq ',entry 'supertag-tag)
                   (dolist (unexpected '(supertag supertag-services-sync supertag-services-ui
                                         supertag-ui-commands supertag-ui-completion
                                         supertag-view-node supertag-view-framework supertag-menu
                                         supertag-view-helper supertag-view-api))
                     (when (featurep unexpected)
                       (error "Standalone Tag unexpectedly loaded %s" unexpected)))
                   (dolist (loaded load-history)
                     (when (and (stringp (car loaded))
                                (member (file-name-base (car loaded))
                                        '("supertag-view-helper" "supertag-view-api"
                                          "supertag-view-framework" "supertag")))
                       (error "Standalone Tag unexpectedly traversed %s" (car loaded))))
                   (when (or (bound-and-true-p supertag--initialized)
                             (file-exists-p supertag-db-file))
                     (error "Standalone Tag unexpectedly initialized persistence")))
                 (when ',state-order
                   (unless (and (eq supertag-query-saved query-sentinel)
                                (eq supertag--view-configs view-sentinel))
                     (error "Initial load overwrote prebound registry"))
                   (let ((after-init-time nil))
                     (load ,(expand-file-name
                             (if (eq state-order 'tag-first)
                                 "supertag-view-framework.el" "supertag-tag.el") root)
                           nil nil t))
                   (unless (and (eq supertag-query-saved query-sentinel)
                                (equal supertag-query-saved '(("sentinel" . "(tag \"keep\")")))
                                (eq supertag--view-configs view-sentinel)
                                (equal (supertag-view-config-get 'sentinel)
                                       '(:id sentinel :name "Keep" :tag "keep")))
                     (error "Second load replaced or emptied shared registry"))
                   (supertag-view-config-register '(:id second :name "Second" :tag "keep"))
                   (unless (equal (gethash 'second view-sentinel)
                                  '(:id second :name "Second" :tag "keep"))
                     (error "Framework writes a different registry")))
                 (princ ,(format "TAG-LOAD-PASS:%s\n" entry)))
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
                         (string-match-p (regexp-quote (format "TAG-LOAD-PASS:%s\n" entry)) output))
              (ert-fail (format "Cold %s exit=%S\n%s" entry status output)))))
      (delete-directory temporary t))))

(ert-deftest supertag-path-sync-cold-load-uses-consolidated-tag ()
  (supertag-path-test--cold-tag-load 'supertag-services-sync))

(ert-deftest supertag-path-tag-cold-load-preserves-operations-without-ui ()
  (supertag-path-test--cold-tag-load 'supertag-tag))

(ert-deftest supertag-path-helper-cold-load-resolves-moved-tag-writers ()
  (supertag-path-test--cold-tag-load (if (equal (getenv "SUPERTAG_VWD_STAGE") "before") 'supertag-view-helper 'supertag-node)))

(ert-deftest supertag-path-tag-then-framework-preserves-prebound-registries ()
  (supertag-path-test--cold-tag-load 'supertag-tag 'tag-first))

(ert-deftest supertag-path-framework-then-tag-preserves-prebound-registries ()
  (supertag-path-test--cold-tag-load 'supertag-view-framework 'framework-first))

;;; D2 retained input and placement behavior; only user-input boundaries stubbed.
(defmacro supertag-path-test--input-store (&rest body)
  (declare (indent 0))
  `(supertag-path-test--with-store
     (supertag-tag-create '(:id "book-id" :name "media" :aliases ("reading")))
     (supertag-tag-create '(:id "work-id" :name "work"))
     (let* ((org-file (expand-file-name "unchanged.org" tmp))
            (facts (prin1-to-string supertag--store)))
       (with-temp-file org-file (insert "* Unchanged\nNo identity here.\n"))
       ,@body
       (should (equal facts (prin1-to-string supertag--store)))
       (should (equal "* Unchanged\nNo identity here.\n" (supertag-document-test-disk org-file)))
       (should-not (file-exists-p supertag-db-file)))))

(ert-deftest supertag-path-input-canonical-id-and-affixation ()
  (supertag-path-test--input-store
    (should (equal (supertag-view-api-list-tag-ids) '("book-id" "work-id")))
    (should (equal "book-id" (supertag-tag-resolve-occurrence "reading")))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt table _predicate require-match &rest _)
                 (let* ((candidates (all-completions "" table))
                        (candidate (car candidates))
                        (affix (plist-get completion-extra-properties :affixation-function)))
                   (should require-match)
                   (should (equal (mapcar #'substring-no-properties candidates) '("media" "work")))
                   (should (equal (get-text-property 0 'supertag-tag-id candidate) "book-id"))
                   (should (= 2 (length (funcall affix candidates))))
                   ;; Return plain canonical text, exercising candidate-map lookup.
                   "media"))))
      (should (equal "book-id" (supertag-ui-read-tag "Tag: "))))
    ;; Arbitrary alias text is not a read-tag candidate; don't claim otherwise.
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "reading")))
      (should-error (supertag-ui-read-tag "Tag: ") :type 'user-error))))

(ert-deftest supertag-path-input-supplied-nil-new-empty-and-slash-names ()
  (supertag-path-test--input-store
    (let ((calls 0))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table _predicate require-match &rest _)
                   (cl-incf calls)
                   (should-not require-match)
                   (should-not (all-completions "" table))
                   "new/path")))
        (should (equal "new/path" (supertag-ui-read-tag "New: " nil t))))
      (should (= calls 1)))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
      (should-not (supertag-ui-read-tag "Optional: " nil t t))
      (should-error (supertag-ui-read-tag "Required: " nil t nil) :type 'user-error))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "bad//path")))
      (should (equal "bad//path" (supertag-ui-read-tag "New: " nil t))))))

(ert-deftest supertag-path-input-multiple-and-capture-initial-preserved ()
  (supertag-path-test--input-store
    (let ((initial '("book-id")) (calls 0))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table _predicate _require-match &rest _)
                   (cl-incf calls)
                   (let ((names (all-completions "" table)))
                     (should-not (member "media" names))
                     (if (= calls 1) "work" "")))))
        (should (equal '("book-id" "work-id")
                       (supertag-ui-read-tags "More: " nil nil initial))))
      (should (equal initial '("book-id")))
      ;; Exhausting known choices stops without a second minibuffer read.
      (should (= calls 1)))
    (let ((answers '("work" "")) (calls 0))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table _predicate _require-match &rest _)
                   (cl-incf calls)
                   (should-not (member "media" (all-completions "" table)))
                   (prog1 (car answers) (setq answers (cdr answers))))))
        (should (equal '("book-id" "work-id")
                       (supertag-capture--get-from-tags-prompt
                        '("Capture: " :initial-input "book-id")))))
      (should (= calls 2)))))

(ert-deftest supertag-path-input-field-string-and-manual-fallback ()
  (supertag-path-test--input-store
    (let ((answers '("media" "")))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (prog1 (car answers) (setq answers (cdr answers))))))
        (should (equal "book-id" (supertag-ui--read-tag-field "work-id")))))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) ""))
              ((symbol-function 'read-string)
               (lambda (_prompt initial &rest _)
                 (should (equal initial "work-id"))
                 "book-id, work-id")))
      ;; Preserve the original fallback's nreverse order, not the docstring ideal.
      (should (equal "work-id,book-id" (supertag-ui--read-tag-field "work-id"))))))

(ert-deftest supertag-path-placement-drawer-tagline-and-heading-boundary ()
  (let ((org-mode-hook nil))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n:PROPERTIES:\n:ID: parent\n:END:\n\nBody\n#existing\n** Child\n#child\n* Sibling\n#sibling\n")
      (goto-char (point-min))
      (let ((limit (save-excursion (search-forward "** Child") (line-beginning-position))))
        (narrow-to-region (point-min) limit)
        (set-buffer-modified-p nil)
        (let* ((before (buffer-string)) (origin (point)) (low (point-min)) (high (point-max))
               (wanted (save-excursion (search-forward "#existing") (line-end-position)))
               (found (supertag-view-helper-find-tag-insertion-point)))
          (should (= found wanted))
          (should (= origin (point)))
          (should (= low (point-min))) (should (= high (point-max)))
          (should (equal before (buffer-string))) (should-not (buffer-modified-p)))))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n:PROPERTIES:\n:ID: parent\n:END:\n\nBody\n** Child\n#child\n* Sibling\n#sibling\n")
      (goto-char (point-min)) (set-buffer-modified-p nil)
      (let ((wanted (save-excursion (search-forward "Body") (line-beginning-position))))
        (should-not (supertag-view-helper--find-existing-tag-line))
        (should (= wanted (supertag-view-helper-find-tag-insertion-point)))
        (should-not (buffer-modified-p))))))

(ert-deftest supertag-path-placement-no-drawer-retains-newline-side-effect ()
  (let ((org-mode-hook nil))
    (with-temp-buffer
      (org-mode) (insert "* Parent\nBody\n** Child\nChild\n* Sibling\nSibling\n")
      (goto-char (point-min)) (set-buffer-modified-p nil)
      (let ((origin (point)) (found (supertag-view-helper-find-tag-insertion-point)))
        (should (= origin (point)))
        (should (= found (1+ (length "* Parent\n"))))
        (should (buffer-modified-p))
        (should (equal (buffer-string) "* Parent\n\nBody\n** Child\nChild\n* Sibling\nSibling\n"))))))

(ert-deftest supertag-path-placement-bounds-share-prose-matcher ()
  (let ((org-mode-hook nil))
    (with-temp-buffer
      (org-mode) (insert "* Heading #head\nBody #body [[id:target][#inside]] #after\n")
      (set-buffer-modified-p nil)
      (dolist (token '("head" "body" "after"))
        (goto-char (point-min)) (search-forward (concat "#" token)) (backward-char)
        (let* ((origin (point)) (bounds (supertag-view-helper-tag-at-point-bounds)))
          (should (equal token (car bounds)))
          (should (equal (concat "#" token) (buffer-substring-no-properties (cadr bounds) (cddr bounds))))
          (should (equal token (supertag-view-helper-get-tag-at-point)))
          (should (= origin (point)))))
      (goto-char (point-min)) (search-forward "#inside") (backward-char)
      (should-not (supertag-view-helper-tag-at-point-bounds))
      (should-not (buffer-modified-p)))))

(defconst supertag-path-test--input-functions
  '(supertag-ui-read-tag supertag-ui-read-tags supertag-ui--read-tag-field
    supertag-capture--get-from-tags-prompt supertag-view-api-list-tag-ids
    supertag-view-helper-find-tag-insertion-point supertag-view-helper--find-drawer-end
    supertag-view-helper--find-existing-tag-line supertag-view-helper-tag-at-point-bounds
    supertag-view-helper-get-tag-at-point))

(ert-deftest supertag-path-input-cold-tag-resolves-query-and-keeps-owners ()
  (let* ((root supertag-path-test--source-root)
         (tmp (make-temp-file "supertag-input-cold-" t))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (dependencies (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (process-environment (copy-sequence process-environment))
         (form
          `(unwind-protect
               (progn
                 (require 'cl-lib) (require 'ert)
                 (setq user-emacs-directory ,(file-name-as-directory tmp)
                       supertag-data-directory ,(expand-file-name "data/" tmp)
                       supertag--base-data-directory supertag-data-directory
                       supertag-db-file ,(expand-file-name "store.el" tmp)
                       supertag-db-backup-directory ,(expand-file-name "backups/" tmp)
                       supertag-sync-state-file ,(expand-file-name "sync.el" tmp)
                       supertag-sync--state-source supertag-sync-state-file
                       org-id-locations-file ,(expand-file-name "ids" tmp)
                       org-id-track-globally nil
                       supertag-sync-directories nil supertag-active-sync-directory nil
                       make-backup-files nil auto-save-default nil load-prefer-newer t)
                 (let ((after-init-time nil))
                   (load ,(expand-file-name "supertag-tag.el" root) nil nil t))
                 (princ "D2-ENTRY-LOADED\n")
                 (should (featurep 'supertag-service-org))
                 (dolist (feature '(supertag-query supertag-services-query supertag-services-note-query supertag-services-ui supertag-ui-commands
                                    supertag-services-sync supertag-view-api
                                    supertag-view-helper supertag))
                   (should-not (featurep feature))
                   (should-not (cl-find-if
                                (lambda (row) (and (stringp (car row))
                                                   (equal (file-name-base (car row)) (symbol-name feature))))
                                load-history)))
                 (should-not (bound-and-true-p supertag--initialized))
                 (should-not (file-exists-p supertag-db-file))
                 (dolist (symbol ',supertag-path-test--input-functions)
                   (unless (equal (symbol-file symbol 'defun)
                                  ,(expand-file-name "supertag-tag.el" root))
                     (error "D2 owner is not Tag: %s (%S)" symbol (symbol-file symbol 'defun))))
                 (supertag--ensure-store)
                 (supertag-tag-create '(:id "stable" :name "media" :aliases ("reading")))
                 (should-not (featurep 'supertag-query))
                 (should-not (featurep 'supertag-services-query))
                 (should-not (featurep 'supertag-services-note-query))
                 (let ((facts (prin1-to-string supertag--store)) (calls 0))
                   (cl-letf (((symbol-function 'completing-read)
                              (lambda (_prompt table _predicate require-match &rest _)
                                (cl-incf calls)
                                (should require-match)
                                (let ((candidates (all-completions "" table)))
                                  (should (equal (mapcar #'substring-no-properties candidates) '("media")))
                                  (should (equal "stable" (get-text-property 0 'supertag-tag-id (car candidates))))
                                  (should (= 1 (length (funcall (plist-get completion-extra-properties :affixation-function) candidates))))
                                  (car candidates)))))
                     (should (equal "stable" (supertag-ui-read-tag "Tag: "))))
                   (should (= calls 1))
                   (should (featurep 'supertag-query))
                   (should (equal (symbol-file 'supertag-query-tag-descriptors 'defun)
                                  ,(expand-file-name "supertag-query.el" root)))
                   (should (equal facts (prin1-to-string supertag--store)))
                   (should-not (file-exists-p supertag-db-file)))
                 (princ (format "D2-AFTER-READ features Query=%S UI=%S Sync=%S Org=%S\n"
                                (featurep 'supertag-query) (featurep 'supertag-services-ui)
                                (featurep 'supertag-services-sync) (featurep 'supertag-service-org)))
                 (let ((after-init-time nil))
                   (progn
                     (require 'supertag-query)
                     (require 'supertag-tag)
                     (require 'supertag-services-sync)
                     (supertag-node--prepare-cache-listener t)
                     (dolist (entry (if (equal (getenv "SUPERTAG_VWD_STAGE") "before")
                                        (if (equal (getenv "SUPERTAG_VWB_STAGE") "before")
                                            '("supertag-node.el"
                                              "supertag-view-api.el" "supertag-view-helper.el")
                                          '("supertag-node.el"
                                            "supertag-view-helper.el"))
                                      '("supertag-node.el")))
                       (load (expand-file-name entry ,root) nil nil t))))
                 (dolist (symbol ',supertag-path-test--input-functions)
                   (should (equal (symbol-file symbol 'defun)
                                  ,(expand-file-name "supertag-tag.el" root))))
                 (princ "D2-COLD-PASS\n"))
             (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil))))
    (unwind-protect
        (with-temp-buffer
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity dependencies path-separator) path-separator))
          (let* ((args (append '("-Q" "--batch")
                               (apply #'append (mapcar (lambda (dir) (list "-L" dir)) dependencies))
                               (list "-L" root "--eval"
                                     (prin1-to-string
                                      `(condition-case problem ,form
                                         (error (princ (format "D2-COLD-ERROR:%S\n" problem))
                                                (kill-emacs 1)))))))
                 (status (apply #'call-process program nil t nil args))
                 (output (buffer-string)))
            (unless (and (equal status 0) (string-match-p "D2-ENTRY-LOADED" output)
                         (string-match-p "D2-COLD-PASS" output))
              (ert-fail (format "D2 cold exit=%S\n%s" status output)))
            (princ "D2 cold exit0 ENTRY-LOADED/PASS\n")
            (when (string-match "D2-AFTER-READ[^\n]*" output)
              (princ (concat (match-string 0 output) "\n")))))
      (delete-directory tmp t))))

;;; D3 shared completion lifecycle and real Tag commit controls.
(defun supertag-path-test--capf-hooks (enabled)
  (dolist (pair '((completion-at-point-functions . supertag-tag--reference-completion-at-point)
                  (completion-at-point-functions . supertag-completion-at-point)
                  (post-self-insert-hook . supertag-completion--auto-record-on-boundary)))
    (should (= (if enabled 1 0) (cl-count (cdr pair) (symbol-value (car pair)))))))

(ert-deftest supertag-path-capf-shared-local-global-lifecycle ()
  (let ((a (generate-new-buffer " *D3 Org A*"))
        (b (generate-new-buffer " *D3 Org B*"))
        (text (generate-new-buffer " *D3 text*"))
        (supertag-completion-auto-enable nil)
        (was-global global-supertag-ui-completion-mode))
    (unwind-protect
        (progn
          (global-supertag-ui-completion-mode -1)
          (with-current-buffer a
            (org-mode)
            (setq-local completion-at-point-functions '(ignore))
            (setq supertag-completion--last-unregistered-hint "keep-A")
            (supertag-ui-completion-mode 1)
            (supertag-completion-setup)
            (supertag-path-test--capf-hooks t)
            (should (< (cl-position 'supertag-tag--reference-completion-at-point completion-at-point-functions)
                       (cl-position 'supertag-completion-at-point completion-at-point-functions)))
            (should (memq 'ignore completion-at-point-functions))
            (supertag-ui-completion-mode -1)
            (supertag-path-test--capf-hooks nil)
            (should (memq 'ignore completion-at-point-functions)))
          (with-current-buffer text (text-mode))
          (global-supertag-ui-completion-mode 1)
          (with-current-buffer a (supertag-path-test--capf-hooks t))
          (with-current-buffer b (org-mode) (supertag-path-test--capf-hooks t)
                               (setq supertag-completion--last-unregistered-hint "keep-B"))
          (with-current-buffer text (should-not supertag-ui-completion-mode))
          ;; Reload the real current provider, never fabricate mode definitions.
          (load (symbol-file 'supertag-completion-at-point 'defun) nil nil t)
          (with-current-buffer a
            (should (equal "keep-A" supertag-completion--last-unregistered-hint))
            (supertag-path-test--capf-hooks t))
          (with-current-buffer b
            (should (equal "keep-B" supertag-completion--last-unregistered-hint))
            (supertag-path-test--capf-hooks t))
          (should-not supertag-completion-auto-enable)
          (global-supertag-ui-completion-mode -1)
          (dolist (buffer (list a b))
            (with-current-buffer buffer (supertag-path-test--capf-hooks nil))))
      (global-supertag-ui-completion-mode -1)
      (mapc #'kill-buffer (list a b text))
      (when was-global (global-supertag-ui-completion-mode 1)))))

(ert-deftest supertag-path-capf-table-live-prefix-and-explicit-commit ()
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "stable" :name "canonical" :aliases ("alias")))
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max)) (insert "＃new/path")
      (let* ((capf (supertag-completion-at-point)) (table (nth 2 capf))
             (exit (plist-get (nthcdr 3 capf) :exit-function))
             (candidate (cl-find-if (lambda (s) (get-text-property 0 'is-new-tag s))
                                    (all-completions "" table))))
        (should candidate)
        (should (equal "new/path" (get-text-property 0 'new-tag-name candidate)))
        (should (equal "" (get-text-property (1- (length candidate)) 'display candidate)))
        (should (eq 'supertag-tag (completion-metadata-get (completion-metadata "" table nil) 'category)))
        (should-not (test-completion "new/path" table))
        (funcall exit candidate nil)
        (funcall exit candidate 'partial)
        ;; Nothing is created by a partial exit.
        (should-not (supertag-tag-resolve-occurrence "new/path"))
        (insert "/updated")
        (setq candidate (cl-find-if (lambda (s) (get-text-property 0 'is-new-tag s))
                                    (all-completions "" table)))
        (should (equal "new/path/updated" (get-text-property 0 'new-tag-name candidate)))
        (funcall exit candidate 'finished)
        (should-not (buffer-modified-p))
        (should (equal (buffer-string) (supertag-document-test-disk file)))
        ;; The whole typed path becomes the leaf token, and the node carries it.
        (should (string-match-p "#updated " (buffer-string)))
        (should-not (string-match-p "＃" (buffer-string)))
        (let* ((id (supertag-tag-resolve-occurrence "updated"))
               (path (supertag-tag-resolve-occurrence "path"))
               (new (supertag-tag-resolve-occurrence "new")))
          (should (member id (plist-get (supertag-node-get "document-node") :tags)))
          (should (equal (list path) (supertag-tag-parents id)))
          (should (equal (list new) (supertag-tag-parents path)))))
      (goto-char (point-max)) (insert "#can")
      (let* ((capf (supertag-completion-at-point))
             (table (nth 2 capf))
             (candidate (cl-find-if (lambda (s) (equal "stable" (get-text-property 0 'supertag-tag-id s)))
                                    (all-completions "" table))))
        (should (equal "canonical" candidate))
        (funcall (plist-get (nthcdr 3 capf) :exit-function) candidate 'exact)
        (should (member "stable" (plist-get (supertag-node-get "document-node") :tags))))
      (goto-char (point-max)) (insert "#")
      (should-not (cl-find-if (lambda (s) (equal "stable" (get-text-property 0 'supertag-tag-id s)))
                             (all-completions "" (nth 2 (supertag-completion-at-point))))))))

(ert-deftest supertag-path-capf-boundary-hints-and-real-known-projection ()
  (supertag-document-test-with-vault
    (let ((calls 0) (real-message (symbol-function 'message)))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (when (and (stringp format-string) (string-match-p "not registered" format-string))
                     (cl-incf calls))
                   (apply real-message format-string args))))
        (dotimes (_ 2)
          (with-temp-buffer
            (org-mode) (insert "* No ID\n#unknown ")
            (supertag-completion--auto-record-on-boundary)
            (supertag-completion--auto-record-on-boundary)
            (goto-char (point-min))
            (should-not (org-entry-get nil "ID"))))
        (should (= calls 2))
        (should-not (supertag-tag-resolve-occurrence "unknown"))))
    (supertag-tag-create '(:id "stable" :name "canonical"))
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max)) (insert "#canonical ")
      (supertag-completion--auto-record-on-boundary)
      (should (equal (buffer-string) (supertag-document-test-disk file)))
      (should-not (buffer-modified-p))
      (should (member "stable" (plist-get (supertag-node-get "document-node") :tags))))))

(defun supertag-path-test--capf-failed-commit (stage)
  (supertag-document-test-with-vault
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max)) (insert "#d3/failure")
      (let* ((disk (supertag-document-test-disk file))
             (capf (supertag-completion-at-point))
             (candidate (cl-find-if (lambda (s) (get-text-property 0 'is-new-tag s))
                                    (all-completions "" (nth 2 capf))))
             (seam (if (eq stage 'save) 'supertag-service-org--save-current-buffer
                     'supertag-sync--resolve-node-tag-occurrences)))
        (cl-letf (((symbol-function seam) (lambda (&rest _) (error "D3 injected"))))
          (should-error (funcall (plist-get (nthcdr 3 capf) :exit-function) candidate 'finished)))
        ;; The typed path survives as the draft, and the created hierarchy
        ;; stays too: only the membership write failed.
        (should (string-match-p "#failure " (buffer-string)))
        (let ((leaf (supertag-tag-resolve-occurrence "failure")))
          (should leaf)
          (should (equal (list (supertag-tag-resolve-occurrence "d3"))
                         (supertag-tag-parents leaf)))
          (should-not (member leaf
                              (plist-get (supertag-node-get "document-node") :tags))))
        (if (eq stage 'save)
            (progn (should (equal disk (supertag-document-test-disk file)))
                   (should (buffer-modified-p)))
          (should (equal (buffer-string) (supertag-document-test-disk file)))
          (should-not (buffer-modified-p)))
        (goto-char (point-min)) (should (equal "document-node" (org-entry-get nil "ID")))))))

(ert-deftest supertag-path-capf-save-failure-keeps-normalized-draft ()
  (supertag-path-test--capf-failed-commit 'save))

(ert-deftest supertag-path-capf-project-failure-keeps-durable-org ()
  (supertag-path-test--capf-failed-commit 'project))

;;; D3 fresh processes: ownership, first hook traversal and main initialization.
(defun supertag-path-test--completion-cold (scenario)
  (let* ((root supertag-path-test--source-root)
         (tmp (make-temp-file "supertag-completion-cold-" t))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (process-environment (copy-sequence process-environment))
         (form
          `(unwind-protect
               (progn
                 (require 'cl-lib) (require 'ert) (require 'org)
                 (setq user-emacs-directory ,(file-name-as-directory tmp)
                       supertag-data-directory ,(expand-file-name "data/" tmp)
                       supertag--base-data-directory supertag-data-directory
                       supertag-db-file ,(expand-file-name "store.el" tmp)
                       supertag-db-backup-directory ,(expand-file-name "backups/" tmp)
                       supertag-sync-state-file ,(expand-file-name "sync.el" tmp)
                       supertag-sync--state-source supertag-sync-state-file
                       org-id-locations-file ,(expand-file-name "ids" tmp)
                       org-id-track-globally nil supertag-sync-directories nil
                       supertag-active-sync-directory nil supertag-sync-auto-start nil
                       supertag-completion-auto-enable nil
                       make-backup-files nil auto-save-default nil load-prefer-newer t
                       after-init-time nil)
                 (let ((a (get-buffer-create " *D3 cold Org*"))
                       (b (get-buffer-create " *D3 cold text*")))
                   (with-current-buffer a (org-mode))
                   (with-current-buffer b (text-mode))
                   (load ,(expand-file-name "supertag-tag.el" root) nil nil t)
                   (princ "D3-ENTRY-LOADED\n")
                   (dolist (symbol '(supertag-completion-at-point supertag-completion-debug
                                     supertag-ui-completion-mode global-supertag-ui-completion-mode
                                     supertag-ui-completion-enable))
                     (unless (equal (symbol-file symbol 'defun) ,(expand-file-name "supertag-tag.el" root))
                       (error "D3 owner is not Tag: %S" symbol)))
                   (should-not global-supertag-ui-completion-mode)
                   (should-not (file-exists-p supertag-db-file))
                   (should (featurep 'supertag-service-org))
                   (dolist (feature '(supertag-link supertag-query supertag-services-query supertag-services-note-query supertag-services-ui
                                      supertag-services-sync supertag-ui-completion))
                     (should-not (featurep feature)))
                   (with-current-buffer a
                     (should-not supertag-ui-completion-mode)
                     (setq-local supertag-completion--last-unregistered-hint "prebound")
                     (supertag-ui-completion-mode 1)
                     (should-not (featurep 'supertag-link)))
                   (cond
                    ((eq ',scenario 'hash)
                     (supertag--ensure-store)
                     (supertag-tag-create '(:id "stable" :name "canonical"))
                     (with-current-buffer a
                       (insert "* Note\n#can")
                       (let (calls result)
                         ;; Walk the real hook list, preserving its short-circuit order.
                         (setq result (run-hook-wrapped 'completion-at-point-functions
                                       (lambda (fn) (push fn calls) (funcall fn))))
                         (should (equal (nreverse calls)
                                        '(supertag-tag--reference-completion-at-point supertag-completion-at-point)))
                         (should-not (featurep 'supertag-link))
                         (should (member "canonical" (all-completions "" (nth 2 result))))
                         (should (eq 'supertag-tag
                                     (completion-metadata-get (completion-metadata "" (nth 2 result) nil) 'category))))
                       (erase-buffer) (insert "* Note\n[[can")
                       (run-hook-wrapped 'completion-at-point-functions
                                         (lambda (fn) (funcall fn)))
                       (should (featurep 'supertag-link))
                       (should (equal "prebound" supertag-completion--last-unregistered-hint)))
                     (princ "D3-HASH Tag completion leaves Link cold; shorthand loads Link\n"))
                    (t
                     ;; Resolve real providers before isolating only non-mode IO/timers.
                     (require 'supertag-core-persistence)
                     (require 'supertag-services-sync)
                     (require 'supertag-automation)
                     (with-current-buffer a (supertag-ui-completion-mode -1))
                     (let ((calls nil))
                       (cl-letf (((symbol-function 'supertag-persistence-check-legacy-data-directory) #'ignore)
                                 ((symbol-function 'supertag-persistence-ensure-data-directory) #'ignore)
                                 ((symbol-function 'supertag-sync-load-state) #'ignore)
                                 ((symbol-function 'supertag-load-store)
                                  (lambda (&rest _) (push 'store calls)))
                                 ((symbol-function 'supertag-setup-all-timers) #'ignore)
                                 ((symbol-function 'supertag-scheduler-start) #'ignore))
                         (setq after-init-time (eq ',scenario 'late))
                         (load ,(expand-file-name "supertag.el" root) nil nil t)
                         (when (eq ',scenario 'delayed)
                           (should-not calls)
                           (should-not global-supertag-ui-completion-mode)
                           (with-current-buffer a (should-not supertag-ui-completion-mode))
                           (should (memq 'supertag-init emacs-startup-hook))
                           (supertag-init))
                         (should (equal calls '(store)))
                         (should global-supertag-ui-completion-mode)
                         (with-current-buffer a
                           (should supertag-ui-completion-mode)
                           (should (= 1 (cl-count 'supertag-completion-at-point completion-at-point-functions)))
                           (should (= 1 (cl-count 'supertag-tag--reference-completion-at-point completion-at-point-functions))))
                         (with-current-buffer b (should-not supertag-ui-completion-mode))
                         (with-temp-buffer (org-mode) (should supertag-ui-completion-mode))))))
                   (let ((after-init-time nil))
                     (progn
                       (require 'supertag-query)
                       (require 'supertag-tag)
                       (require 'supertag-services-sync)
                       (supertag-node--prepare-cache-listener t)
                       (dolist (entry '("supertag-services-sync.el" "supertag.el"))
                         (load (expand-file-name entry ,root) nil nil t))))
                   (should (equal (symbol-file 'supertag-completion-at-point 'defun)
                                  ,(expand-file-name "supertag-tag.el" root)))
                   (should-not (locate-library "supertag-ui-completion"))
                   (should-not (featurep 'supertag-ui-completion))
                   (should-not (cl-find-if (lambda (row) (and (stringp (car row))
                                                              (equal "supertag-ui-completion" (file-name-base (car row))))) load-history))
                   (princ (format "D3-COLD-PASS %S\n" ',scenario))))
             (when (fboundp 'global-supertag-ui-completion-mode)
               (global-supertag-ui-completion-mode -1))
             (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
             (mapc #'cancel-timer (append timer-list timer-idle-list)))))
    (unwind-protect
        (with-temp-buffer
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (let* ((status (apply #'call-process program nil t nil
                                (append '("-Q" "--batch")
                                        (apply #'append (mapcar (lambda (dir) (list "-L" dir)) deps))
                                        (list "-L" root "--eval"
                                              (prin1-to-string `(condition-case err ,form
                                                                   (error (princ (format "D3-ERROR %S\n" err)) (kill-emacs 1))))))))
                 (output (buffer-string)))
            (unless (and (equal status 0) (string-match-p "D3-ENTRY-LOADED" output)
                         (string-match-p "D3-COLD-PASS" output))
              (ert-fail (format "D3 %S exit=%S\n%s" scenario status output)))
            (princ (format "D3 cold %S exit0 ENTRY-LOADED/PASS\n" scenario))))
      (delete-directory tmp t))))

(ert-deftest supertag-path-capf-cold-tag-first-hash-hook-owns-modes ()
  (supertag-path-test--completion-cold 'hash))
(ert-deftest supertag-path-capf-cold-main-delays-real-mode-until-init ()
  (supertag-path-test--completion-cold 'delayed))
(ert-deftest supertag-path-capf-cold-main-late-init-enables-real-mode ()
  (supertag-path-test--completion-cold 'late))

;;; D4 fresh ownership and real command provider boundaries.
(defun supertag-path-test--d4-cold (entry)
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "old-id" :name "old"))
    (supertag-tag-create
     '(:id "child-id" :name "child" :extends ("old-id")))
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max)) (insert "#old\n") (save-buffer))
    (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
    (let* ((snapshot (expand-file-name "projection.el" tmp))
           (root supertag-path-test--source-root)
           (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
           (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
           (process-environment (copy-sequence process-environment))
           (form
            `(unwind-protect
                 (progn
                   (require 'cl-lib) (require 'ert) (require 'org)
                   (setq user-emacs-directory ,(expand-file-name "user/" tmp)
                         supertag-data-directory ,(expand-file-name "data/" tmp)
                         supertag--base-data-directory supertag-data-directory
                         supertag-db-file ,(expand-file-name "db.el" tmp)
                         supertag-db-backup-directory ,(expand-file-name "backups/" tmp)
                         supertag-sync-state-file ,(expand-file-name "sync.el" tmp)
                         supertag-sync--state-source supertag-sync-state-file
                         org-id-locations-file ,(expand-file-name "ids-child" tmp)
                         org-id-track-globally nil supertag-sync-directories nil
                         supertag-active-sync-directory nil after-init-time nil
                         make-backup-files nil auto-save-default nil load-prefer-newer t
                         supertag-batch-tag-insert-position 'beginning
                         supertag-capture-tag-position 'beginning)
                   (load (expand-file-name
                          (if (eq ',entry 'menu) "supertag-menu.el" "supertag-tag.el") ,root) nil nil t)
                   (princ "D4-ENTRY-LOADED\n")
                   (cl-labels
                       ((owners ()
                          (dolist (name '(supertag-tag-change--collect supertag-tag-change-preview
                                          supertag-tag-rename supertag-delete-tag-everywhere
                                          supertag-cleanup-orphaned-tags supertag-view--read-tag
                                          supertag-view-api-tag-descendants))
                            (unless (equal (symbol-file name 'defun) ,(expand-file-name "supertag-tag.el" root))
                              (error "D4 owner is not Tag: %S" name)))
                          (dolist (name '(supertag-batch-tag-insert-position supertag-capture-tag-position))
                            (should (equal (symbol-file name 'defvar) ,(expand-file-name "supertag-tag.el" root)))
                            (should (eq 'beginning (symbol-value name)))))
                        (facts ()
                          (list (prin1-to-string supertag--store)
                                (mapcar (lambda (path)
                                          (list (with-temp-buffer (insert-file-contents path) (buffer-string))
                                                (with-current-buffer (find-file-noselect path)
                                                  (list (buffer-string) (buffer-modified-p)))))
                                        (list ,file ,plain)))))
                     (if (eq ',entry 'menu)
                         (should-not (featurep 'supertag-tag))
                       (owners))
                     (unless (eq ',entry 'menu) (should (featurep 'supertag-service-org)))
                     (dolist (feature (append '(supertag-services-ui supertag-ui-commands supertag-view-framework
                                        supertag-view-api supertag-query supertag-services-query supertag-services-note-query supertag-services-sync supertag-core-scan)
                                              (when (eq ',entry 'menu) '(supertag-service-org))))
                       (should-not (featurep feature))
                       (should-not (cl-find-if (lambda (row) (and (stringp (car row))
                                                                (equal (symbol-name feature) (file-name-base (car row))))) load-history)))
                     (should-not (file-exists-p supertag-db-file))
                     (setq supertag--store (with-temp-buffer (insert-file-contents ,snapshot) (read (current-buffer))))
                     (if (eq ',entry 'owner)
                         (progn
                           (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "old")))
                             (let ((before (facts)))
                               (should (equal '(:type :tag :value "old-id" :include-descendants t)
                                              (supertag-view--read-tag)))
                               (should (equal before (facts)))))
                           (should (equal (symbol-file 'supertag-find-tag-descendants 'defun)
                                          ,(expand-file-name "supertag-tag.el" root)))
                           (should-not (featurep 'supertag-view-framework))
                           (should-not (featurep 'supertag-ui-commands))
                           (dolist (name (if (or (equal (getenv "SUPERTAG_SYA_STAGE") "before")
                                      (equal (getenv "SUPERTAG_VWB_STAGE") "before"))
                                  (if (equal (getenv "SUPERTAG_VWB_STAGE") "before")
                                      '("supertag-view-framework.el" "supertag-view-api.el" "supertag-ui-commands.el")
                                    '("supertag-view-framework.el" "supertag-ui-commands.el"))
                                '("supertag-view-framework.el")))
                             (load (expand-file-name name ,root) nil nil t))
                           (owners)
                           ;; The retained real add-tag command consumes the same
                           ;; prebound batch option; only user input is simulated.
                           (with-current-buffer (find-file-noselect ,file)
                             (goto-char (point-min))
                             (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "child")))
                               (supertag-add-tag (point-min) (point-max)))
                             ;; Frozen before places beginning after the first title word.
                             (should (string-prefix-p "* Property #child Node\n" (buffer-string)))
                             (should-not (buffer-modified-p))
                             (should (member "child-id" (plist-get (supertag-node-get "document-node") :tags)))))
                       (when (eq ',entry 'ui)
                         (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener t)))
                       (let ((selector (and (eq ',entry 'ui) (symbol-function 'supertag-ui-select-tag-on-node))))
                         (let ((before (facts)))
                           (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "old"))
                                     ((symbol-function 'read-string) (lambda (&rest _) "renamed"))
                                     ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
                             (if (eq ',entry 'menu) (call-interactively #'supertag-menu--rename-tag)
                               (supertag-tag-rename "old-id" "renamed"))
                             (should (equal before (facts)))
                             (if (eq ',entry 'menu) (call-interactively #'supertag-menu--delete-tag)
                               (supertag-delete-tag-everywhere "old-id"))
                             (should (equal before (facts)))))
                         (owners)
                         (should-not (featurep 'supertag-ui-commands))
                         (should (equal (symbol-file 'supertag-service-org--with-node-buffer 'defun)
                                        ,(expand-file-name "supertag-service-org.el" root)))
                         (should (equal (symbol-file 'supertag-node-tag-occurrences-at-point 'defun)
                                        ,(expand-file-name "supertag-services-sync.el" root)))
                         (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "old"))
                                   ((symbol-function 'read-string) (lambda (&rest _) "renamed"))
                                   ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                           (if (eq ',entry 'menu) (call-interactively #'supertag-menu--rename-tag)
                             (supertag-tag-rename "old-id" "renamed")))
                         (let ((new (supertag-tag-resolve-occurrence "renamed")))
                           (should new) (should-not (supertag-tag-get "old-id"))
                           (should (equal (list new) (plist-get (supertag-node-get "document-node") :tags)))
                           (with-current-buffer (find-file-noselect ,file)
                             (should-not (buffer-modified-p))
                             (should (string-match-p "#renamed" (buffer-string)))
                             (should (equal (buffer-string) (with-temp-buffer (insert-file-contents ,file) (buffer-string)))))
                           (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "renamed"))
                                     ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                             (if (eq ',entry 'menu) (call-interactively #'supertag-menu--delete-tag)
                               (supertag-delete-tag-everywhere new)))
                           (should-not (supertag-tag-get new))
                           (should-not (plist-get (supertag-node-get "document-node") :tags)))
                         (should-not (featurep 'supertag-ui-commands))
                         (when selector
                           (should (eq selector (symbol-function 'supertag-ui-select-tag-on-node))))))
                     (princ (format "D4-GRAPH %S: scan=%S org=%S sync=%S ui=%S commands=%S framework=%S\n"
                                    ',entry (featurep 'supertag-core-scan) (featurep 'supertag-service-org)
                                    (featurep 'supertag-services-sync) (featurep 'supertag-services-ui)
                                    (featurep 'supertag-ui-commands) (featurep 'supertag-view-framework)))
                     (princ "D4-COLD-PASS\n")))
               (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
               (mapc #'cancel-timer (append timer-list timer-idle-list)))))
      (with-temp-file snapshot (let ((print-length nil) (print-level nil)) (prin1 supertag--store (current-buffer))))
      (with-temp-buffer
        ;; Pin the child cwd before HOME is repointed.
        (setq default-directory (file-truename default-directory))
        (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
        (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
        (let* ((status (apply #'call-process program nil t nil
                              (append '("-Q" "--batch")
                                      (apply #'append (mapcar (lambda (dir) (list "-L" dir)) deps))
                                      (list "-L" root "--eval"
                                            (prin1-to-string `(condition-case err ,form
                                                                 (error (princ (format "D4-ERROR %S\n" err)) (kill-emacs 1))))))))
               (output (buffer-string)))
          (unless (and (equal status 0) (string-match-p "D4-ENTRY-LOADED" output)
                       (string-match-p "D4-COLD-PASS" output))
            (ert-fail (format "D4 %S exit=%S\n%s" entry status output)))
          (princ (format "D4 %S cold exit0 ENTRY-LOADED/PASS\n" entry))
          (when (string-match "D4-GRAPH[^\n]*" output) (princ (concat (match-string 0 output) "\n"))))))))

(ert-deftest supertag-path-command-cold-owner-config-and-stream-reader ()
  (supertag-path-test--d4-cold 'owner))
(ert-deftest supertag-path-command-cold-tag-real-rename-delete ()
  (supertag-path-test--d4-cold 'tag))
(ert-deftest supertag-path-command-services-ui-first-keeps-selector-owner ()
  (supertag-path-test--d4-cold 'ui))
(ert-deftest supertag-path-command-menu-only-real-lazy-wrappers ()
  (supertag-path-test--d4-cold 'menu))

;;; D5 old command behavior, before moving its implementation.
(if (equal (getenv "SUPERTAG_SYA_STAGE") "before")
      (require 'supertag-ui-commands)
    (require 'supertag-tag))
(defun supertag-path-test--add-input-timing (where)
  (dolist (action '(empty quit refuse))
    (supertag-document-test-with-vault
      (with-current-buffer (find-file-noselect plain)
        (goto-char (point-min))
        (when (eq where 'body) (forward-line 1))
        (let ((disk (supertag-document-test-disk plain)) seen id prompt-facts)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _)
                       (setq seen t id (save-excursion (goto-char (point-min)) (org-entry-get nil "ID")))
                       (should (stringp id))
                       (should (buffer-modified-p))
                       (should (equal disk (supertag-document-test-disk plain)))
                       (if (eq where 'heading) (should (supertag-node-get id))
                         (should-not (supertag-node-get id)))
                       (setq prompt-facts (list (buffer-string) (buffer-modified-p) (prin1-to-string supertag--store)))
                       (pcase action ('empty "") ('quit (signal 'quit nil)) (_ "=d5-refused"))))
                    ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
            (condition-case err
                (if (eq where 'region)
                    (supertag-add-tag (point-min) (point-max))
                  (supertag-add-tag))
              (quit (unless (eq action 'quit) (signal (car err) (cdr err))))))
          (should seen)
          (should (equal prompt-facts (list (buffer-string) (buffer-modified-p) (prin1-to-string supertag--store))))
          (should (equal disk (supertag-document-test-disk plain)))
          (should-not (supertag-tag-resolve-occurrence "d5-refused")))))))

(ert-deftest supertag-path-add-heading-id-and-projection-precede-prompt ()
  (supertag-path-test--add-input-timing 'heading))
(ert-deftest supertag-path-add-body-id-without-heading-projection-precedes-prompt ()
  (supertag-path-test--add-input-timing 'body))
(ert-deftest supertag-path-add-region-id-without-projection-precedes-prompt ()
  (supertag-path-test--add-input-timing 'region))

(ert-deftest supertag-path-add-real-canonical-and-literal-confirmation ()
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "stable" :name "canonical" :aliases ("alias")))
    (with-current-buffer (find-file-noselect file)
      (dolist (answer '("canonical" "=d5/new"))
        (goto-char (point-min))
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) answer))
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (supertag-add-tag))
        (should-not (buffer-modified-p))
        (should (equal (buffer-string) (supertag-document-test-disk file))))
      (should (equal "document-node" (save-excursion (goto-char (point-min)) (org-entry-get nil "ID"))))
      (let* ((new (supertag-tag-resolve-occurrence "new"))
             (parent (supertag-tag-resolve-occurrence "d5")))
        (should new)
        (should (equal (list parent) (supertag-tag-parents new)))
        (should (equal (sort (list "stable" new) #'string<)
                       (sort (copy-sequence (plist-get (supertag-node-get "document-node") :tags)) #'string<)))
        ;; The node carries the leaf token, never the typed path.
        (should (string-match-p "#new" (buffer-string)))
        (should-not (string-match-p "#d5/new" (buffer-string)))))))

(ert-deftest supertag-path-add-region-keeps-integer-bound-and-order ()
  (supertag-document-test-with-vault
    (with-current-buffer (find-file-noselect plain)
      (erase-buffer) (insert "* One\nA\n* Two\nB\n* Three\nC\n") (save-buffer)
      (let* ((end (save-excursion (goto-char (point-min)) (search-forward "* Two") (line-beginning-position)))
             (disk (supertag-document-test-disk plain))
             (ids (supertag-ui--get-nodes-in-region (point-min) end)))
        (should (= 1 (length ids)))
        (goto-char (point-min)) (should (equal (car ids) (org-entry-get nil "ID")))
        (search-forward "* Two") (should-not (org-entry-get nil "ID"))
        (search-forward "* Three") (should-not (org-entry-get nil "ID"))
        (should (equal disk (supertag-document-test-disk plain)))
        (should (buffer-modified-p))
        (should-not (supertag-node-get (car ids)))))))

(ert-deftest supertag-path-add-unprojected-region-uses-real-live-marker ()
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "stable" :name "canonical"))
    (let ((org-id-files nil))
      (with-current-buffer (find-file-noselect plain)
        (let ((disk (supertag-document-test-disk plain)))
          (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "canonical")))
            (supertag-add-tag (point-min) (point-max)))
          (goto-char (point-min))
          (let ((id (org-entry-get nil "ID")))
            (should id) (should (equal '("stable") (plist-get (supertag-node-get id) :tags))))
          (should-not (buffer-modified-p))
          (should-not (equal disk (supertag-document-test-disk plain)))
          (should (equal (buffer-string) (supertag-document-test-disk plain)))
          (should (string-match-p "#canonical" (buffer-string))))))))

;;; D5 separate fresh processes preserve the shared Node provider boundary.
(defun supertag-path-test--d5-cold (scenario)
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "stable" :name "canonical"))
    (let* ((snapshot (expand-file-name "projection.el" tmp))
           (root supertag-path-test--source-root)
           (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
           (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
           (process-environment (copy-sequence process-environment))
           (file-case (memq scenario '(file-in file-out missing-in missing-out)))
           (input-file (if (eq scenario 'batch) file plain)))
      (when file-case
        (with-temp-file plain
          (when (memq scenario '(file-in file-out))
            (insert ":PROPERTIES:\n:ID: d5-file-id\n:END:\n"))
          (insert "#+TITLE: D5 file\nFile body\n")))
      (with-temp-file snapshot
        (let ((print-length nil) (print-level nil)) (prin1 supertag--store (current-buffer))))
      (let ((form
             `(unwind-protect
                  (progn
                    (require 'cl-lib) (require 'ert) (require 'org)
                    (setq user-emacs-directory ,(expand-file-name "user/" tmp)
                          supertag-data-directory ,(expand-file-name "data/" tmp)
                          supertag--base-data-directory supertag-data-directory
                          supertag-db-file ,(expand-file-name "db.el" tmp)
                          supertag-db-backup-directory ,(expand-file-name "backups/" tmp)
                          supertag-sync-state-file ,(expand-file-name "sync-child.el" tmp)
                          supertag-sync--state-source supertag-sync-state-file
                          org-id-locations-file ,(expand-file-name "ids-child" tmp)
                          org-id-locations nil org-id-files nil org-id-track-globally nil
                          supertag-sync-directories nil supertag-active-sync-directory nil
                          supertag-file-id-source 'org-id after-init-time nil
                          make-backup-files nil auto-save-default nil load-prefer-newer t
                          supertag-batch-tag-insert-position 'beginning)
                    (load (expand-file-name
                           (if (eq ',scenario 'menu) "supertag-menu.el" "supertag-tag.el") ,root) nil nil t)
                    (princ "D5-ENTRY-LOADED\n")
                    (defun d5-owners ()
                      (dolist (name '(supertag-add-tag supertag-ui--get-nodes-in-region))
                        (unless (equal (symbol-file name 'defun) ,(expand-file-name "supertag-tag.el" root))
                          (error "D5 owner is not Tag: %S" name))))
                    (if (eq ',scenario 'menu) (should-not (featurep 'supertag-tag)) (d5-owners))
                    (unless (eq ',scenario 'menu) (should (featurep 'supertag-service-org)))
                    (dolist (feature (append '(supertag-ui-commands supertag-services-ui supertag-services-sync
                                       supertag-query supertag-services-query supertag-services-note-query supertag-link
                                       supertag-view-framework supertag-view-api)
                                             (when (eq ',scenario 'menu) '(supertag-service-org))))
                      (should-not (featurep feature))
                      (should-not (cl-find-if (lambda (row) (and (stringp (car row))
                                                               (equal (file-name-base (car row)) (symbol-name feature)))) load-history)))
                    (dolist (symbol '(supertag-node-sync-at-point supertag-sync--process-single-file))
                      (if (featurep 'supertag-node)
                          (progn (should (autoloadp (symbol-function symbol)))
                                 (should (equal "supertag-services-sync" (nth 1 (symbol-function symbol)))))
                        (should-not (fboundp symbol))))
                    (should-not (file-exists-p supertag-db-file))
                    (setq supertag--store (with-temp-buffer (insert-file-contents ,snapshot) (read (current-buffer)))
                          d5-observed nil d5-prompted nil d5-sync-events nil d5-sync-observers nil)
                    (defun d5-check-sync (&rest _)
                      (should (featurep 'supertag-services-sync))
                      (should-not (autoloadp (symbol-function 'supertag-node-sync-at-point)))
                      (should (equal (symbol-file 'supertag-node-sync-at-point 'defun)
                                     ,(expand-file-name "supertag-services-sync.el" root))))
                    (defun d5-node-owner (symbol)
                      (should-not (autoloadp (symbol-function symbol)))
                      (should (equal (symbol-file symbol 'defun) ,(expand-file-name "supertag-node.el" root))))
                    (defun d5-getter (&rest _)
                      (d5-node-owner 'supertag-ui--get-containing-node-at-point) (push 'getter d5-observed))
                    (defun d5-marker (&rest _)
                      (d5-node-owner 'supertag-ui--find-node-marker) (push 'marker d5-observed))
                    (defun d5-file-helper (&rest _)
                      (d5-node-owner 'supertag-ui--ensure-file-node-synced) (push 'file-helper d5-observed))
                    (defun d5-sync-observe (symbol original &rest args)
                      (d5-check-sync)
                      (let ((result (apply original args)))
                        (push (list symbol (length args) result) d5-sync-events)
                        (when (and (eq symbol 'supertag-sync--in-scope-path-p)
                                   (memq ',scenario '(file-in file-out missing-in missing-out)))
                          (push (if result 'in-scope 'out-of-scope) d5-observed))
                        result))
                    (defun d5-install-sync (loaded)
                      (when (and (stringp loaded) (equal "supertag-services-sync" (file-name-base loaded))
                                 (not d5-sync-observers))
                        (d5-check-sync)
                        (dolist (symbol '(supertag-sync--in-scope-path-p supertag-sync--process-single-file
                                          supertag-sync--parse-file-header supertag-sync--upsert-file-node
                                          supertag-sync-update-state supertag-node-sync-at-point))
                          (should-not (autoloadp (symbol-function symbol)))
                          (should (equal (symbol-file symbol 'defun) ,(expand-file-name "supertag-services-sync.el" root)))
                          (let ((observer (apply-partially #'d5-sync-observe symbol)))
                            (push (cons symbol observer) d5-sync-observers)
                            (advice-add symbol :around observer)))))
                    (defun d5-install-observers (loaded)
                      (when (and (stringp loaded) (equal "supertag-node" (file-name-base loaded)))
                        (advice-add 'supertag-ui--get-containing-node-at-point :before #'d5-getter)
                        (advice-add 'supertag-ui--find-node-marker :before #'d5-marker)
                        (advice-add 'supertag-ui--ensure-file-node-synced :before #'d5-file-helper)))
                    (add-hook 'after-load-functions #'d5-install-observers)
                    (add-hook 'after-load-functions #'d5-install-sync)
                    (when (featurep 'supertag-node) (d5-install-observers ,(expand-file-name "supertag-node.el" root)))
                    (when (featurep 'supertag-services-sync) (d5-install-sync ,(expand-file-name "supertag-services-sync.el" root)))
                    (when (eq ',scenario 'ui)
                      (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener t))
                      (should-not (featurep 'supertag-ui-commands)))
                    (when (eq ',scenario 'commands)
                      (if (equal (getenv "SUPERTAG_SYA_STAGE") "before")
      (load ,(expand-file-name "supertag-ui-commands.el" root) nil nil t)
    (require 'supertag-tag)))
                    (when (memq ',scenario '(file-in file-out missing-in missing-out))
                      (setq supertag-sync-directories
                            (list (if (memq ',scenario '(file-in missing-in))
                                      ,tmp (expand-file-name "outside-root/" ,tmp)))
                            supertag-sync-directories-mode 'unified))
                    (with-current-buffer (find-file-noselect ,input-file)
                      (org-mode) (goto-char (point-min))
                      (let ((disk (with-temp-buffer (insert-file-contents ,input-file) (buffer-string))))
                        (cl-letf (((symbol-function 'completing-read)
                                   (lambda (&rest _)
                                     (setq d5-prompted t)
                                     (when ,(and file-case t)
                                       (setq d5-prompt-node (copy-tree (supertag-node-get "d5-file-id"))))
                                     (unless (memq ',scenario '(batch marker))
                                       (should (memq 'getter d5-observed)))
                                     "canonical")))
                          (cond
                           ((memq ',scenario '(file-in file-out missing-in missing-out))
                            (should-error (supertag-add-tag) :type 'user-error))
                           ((memq ',scenario '(batch marker))
                            (supertag-add-tag (point-min) (point-max)))
                           ((eq ',scenario 'menu) (call-interactively #'supertag-menu--add-tag))
                           (t (call-interactively #'supertag-add-tag))))
                        (if ,(and file-case t)
                            (progn
                              (should (equal disk (buffer-string)))
                              (should (equal disk (with-temp-buffer (insert-file-contents ,input-file) (buffer-string))))
                              (should-not (buffer-modified-p))
                              (if (memq ',scenario '(missing-in missing-out))
                                  (should-not d5-prompted)
                                ;; Frozen before rejects this point-min file-level
                                ;; insertion and restores the exact projected node.
                                (should d5-prompted)
                                (should (equal d5-prompt-node (supertag-node-get "d5-file-id")))
                                (should-not (plist-get (supertag-node-get "d5-file-id") :tags))))
                          (should d5-prompted)
                          (should-not (buffer-modified-p))
                          (should (equal (buffer-string) (with-temp-buffer (insert-file-contents ,input-file) (buffer-string))))
                          (let* ((id (if ,(and file-case t) "d5-file-id"
                                       (save-excursion (goto-char (point-min)) (org-entry-get nil "ID"))))
                                 (node (supertag-node-get id)))
                            (should (equal '("stable") (plist-get node :tags)))))))
                    (d5-owners)
                    (should (eq 'beginning supertag-batch-tag-insert-position))
                    (cond
                     ((eq ',scenario 'batch)
                      (should-not (featurep 'supertag-ui-commands))
                      (should-not d5-observed))
                     ((eq ',scenario 'marker) (should (memq 'marker d5-observed)))
                     ((memq ',scenario '(file-in missing-in))
                      (should (memq 'in-scope d5-observed))
                      (should (assq 'supertag-sync--process-single-file d5-sync-events)))
                     ((memq ',scenario '(file-out missing-out))
                      (should (memq 'out-of-scope d5-observed))
                      (should-not (assq 'supertag-sync--process-single-file d5-sync-events))
                      (should (assq 'supertag-sync--upsert-file-node d5-sync-events)))
                     (t (should (memq 'getter d5-observed))))
                    (princ (format "D5-GRAPH %S commands=%S sync=%S observed=%S\n"
                                   ',scenario (featurep 'supertag-ui-commands) (featurep 'supertag-services-sync) d5-observed))
                    (princ "D5-COLD-PASS\n"))
                (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
                (remove-hook 'after-load-functions #'d5-install-observers)
                (remove-hook 'after-load-functions #'d5-install-sync)
                (dolist (pair d5-sync-observers) (advice-remove (car pair) (cdr pair)))
                (advice-remove 'supertag-ui--get-containing-node-at-point #'d5-getter)
                (advice-remove 'supertag-ui--find-node-marker #'d5-marker)
                (advice-remove 'supertag-ui--ensure-file-node-synced #'d5-file-helper)
                (mapc #'cancel-timer (append timer-list timer-idle-list)))))
        (with-temp-buffer
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (let* ((status (apply #'call-process program nil t nil
                                (append '("-Q" "--batch")
                                        (apply #'append (mapcar (lambda (dir) (list "-L" dir)) deps))
                                        (list "-L" root "--eval"
                                              (prin1-to-string `(condition-case err ,form
                                                                   (error (princ (format "D5-ERROR %S\n" err)) (kill-emacs 1))))))))
                 (output (buffer-string)))
            (unless (and (equal status 0) (string-match-p "D5-ENTRY-LOADED" output)
                         (string-match-p "D5-COLD-PASS" output))
              (ert-fail (format "D5 %S exit=%S\n%s" scenario status output)))
            (princ (format "D5 %S exit0 ENTRY-LOADED/PASS\n" scenario))
            (when (string-match "D5-GRAPH[^\n]*" output) (princ (concat (match-string 0 output) "\n")))))))))

(ert-deftest supertag-path-add-cold-single-and-menu-provider-order ()
  (dolist (scenario '(single menu)) (supertag-path-test--d5-cold scenario)))
(ert-deftest supertag-path-add-cold-batch-and-marker-provider-order ()
  (dolist (scenario '(batch marker)) (supertag-path-test--d5-cold scenario)))
(ert-deftest supertag-path-add-cold-existing-ui-and-commands-load-order ()
  (dolist (scenario '(ui commands)) (supertag-path-test--d5-cold scenario)))
(ert-deftest supertag-path-add-cold-file-identity-and-scope-boundaries ()
  (dolist (scenario '(file-in file-out missing-in missing-out)) (supertag-path-test--d5-cold scenario)))

;;; D6 preserve the main-entry hard selector and actual member removal.
(ert-deftest supertag-path-remove-heading-and-body-preserve-other-members ()
  (dolist (where '(heading body))
    (supertag-document-test-with-vault
      (supertag-tag-create '(:id "stable" :name "canonical"))
      (supertag-tag-create '(:id "keep" :name "retained"))
      (let ((other "* Other #canonical\n:PROPERTIES:\n:ID: other\n:END:\nOther body\n"))
        (with-temp-file file
          (insert "* Source #canonical #retained\n:PROPERTIES:\n:ID: source\n:END:\nBody #canonical\n" other))
        (supertag-reindex-org)
        (let ((entity (copy-tree (supertag-tag-get "stable")))
              (other-node (copy-tree (supertag-node-get "other"))))
          (with-current-buffer (find-file-noselect file)
            (goto-char (point-min))
            (when (eq where 'body) (search-forward "Body"))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt candidates &rest _)
                         (should (member "canonical" candidates)) "canonical")))
              (call-interactively #'supertag-remove-tag-from-node))
            (should-not (buffer-modified-p))
            (should (equal (buffer-string) (supertag-document-test-disk file)))
            (should (string-suffix-p other (buffer-string))))
          (should (equal '("keep") (plist-get (supertag-node-get "source") :tags)))
          (should (equal entity (supertag-tag-get "stable")))
          (should (equal other-node (supertag-node-get "other"))))))))

(ert-deftest supertag-path-remove-quit-and-empty-have-no-extra-tag-write ()
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "stable" :name "canonical"))
    (supertag-service-org-add-tag "document-node" "stable")
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (let ((disk (supertag-document-test-disk file))
            (store (prin1-to-string supertag--store)) caught)
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (signal 'quit nil))))
          (condition-case nil (supertag-remove-tag-from-node) (quit (setq caught t))))
        (should caught) (should (equal disk (buffer-string)))
        (should (equal disk (supertag-document-test-disk file)))
        (should (equal store (prin1-to-string supertag--store)))
        (should-not (buffer-modified-p))))
    (with-current-buffer (find-file-noselect plain)
      (goto-char (point-min))
      (let ((disk (supertag-document-test-disk plain)) prompted)
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (setq prompted t) "canonical")))
          (should-error (supertag-remove-tag-from-node) :type 'user-error))
        ;; The containing-node getter ensures a live ID; remove does not add
        ;; the explicit pre-prompt projection performed by add.
        (should (org-entry-get nil "ID"))
        (should-not (supertag-node-get (org-entry-get nil "ID")))
        (should-not prompted) (should (buffer-modified-p))
        (should (equal disk (supertag-document-test-disk plain)))
        (should-not (plist-get (supertag-node-get (org-entry-get nil "ID")) :tags))))))

(ert-deftest supertag-path-selector-hard-raw-input-and-real-canonical-read ()
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "stable" :name "canonical"))
    (let ((node (supertag-node-get "document-node")) observed)
      ;; Deliberately synthetic projection shape: this narrowly observes the
      ;; selector's argument contract, not malformed-data UI support.
      (plist-put node :tags '("unresolved" nil "stable"))
      (cl-letf (((symbol-function 'supertag-ui-read-tag)
                 (lambda (_prompt ids &rest _) (setq observed ids) "stable")))
        (should (equal "stable" (supertag-ui-select-tag-on-node "document-node"))))
      (should (equal '("unresolved" nil "stable") observed))
      (plist-put node :tags '("unresolved" "stable"))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt candidates &rest _)
                   (should (member "canonical" candidates))
                   (should (member "unresolved" candidates)) "canonical")))
        (should (equal "stable" (supertag-ui-select-tag-on-node "document-node"))))
      (plist-put node :tags nil)
      (should-error (supertag-ui-select-tag-on-node "document-node") :type 'user-error)
      (should-error (supertag-ui-select-tag-on-node "missing") :type 'user-error))))

;;; D6 independent processes: the authorized hard contract has one owner.
(defun supertag-path-test--d6-cold (entry)
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "stable" :name "canonical"))
    (supertag-tag-create '(:id "keep" :name "retained"))
    (with-temp-file file
      (insert "* Source #canonical #retained\n:PROPERTIES:\n:ID: source\n:END:\nBody\n* Other #canonical\n:PROPERTIES:\n:ID: other\n:END:\nOther body\n"))
    (supertag-reindex-org)
    (let* ((snapshot (expand-file-name "d6-projection.el" tmp))
           (root supertag-path-test--source-root)
           (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
           (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
           (process-environment (copy-sequence process-environment)))
      (with-temp-file snapshot
        (let ((print-length nil) (print-level nil)) (prin1 supertag--store (current-buffer))))
      (let ((form
             `(unwind-protect
                  (progn
                    (require 'cl-lib) (require 'ert) (require 'org)
                    (setq user-emacs-directory ,(expand-file-name "user/" tmp)
                          supertag-data-directory ,(expand-file-name "data/" tmp)
                          supertag--base-data-directory supertag-data-directory
                          supertag-db-file ,(expand-file-name "child-db.el" tmp)
                          supertag-db-backup-directory ,(expand-file-name "backups/" tmp)
                          supertag-sync-state-file ,(expand-file-name "child-sync.el" tmp)
                          supertag-sync--state-source supertag-sync-state-file
                          org-id-locations-file ,(expand-file-name "child-ids" tmp)
                          org-id-locations nil org-id-files nil org-id-track-globally nil
                          supertag-sync-directories nil supertag-active-sync-directory nil
                          after-init-time nil make-backup-files nil auto-save-default nil
                          load-prefer-newer t d6-provider-seen nil)
                    (if (memq ',entry '(ui ui-commands-ui))
                        (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener t))
                      (load (expand-file-name
                           ,(pcase entry ('menu "supertag-menu.el")
                              ((or 'commands 'commands-ui) (if (equal (getenv "SUPERTAG_SYA_STAGE") "before") "supertag-ui-commands.el" "supertag-tag.el"))
                              (_ "supertag-tag.el")) ,root) nil nil t))
                    (princ "D6-ENTRY-LOADED\n")
                    (defun d6-owners ()
                      (dolist (symbol '(supertag-remove-tag-from-node supertag-ui-select-tag-on-node))
                        (unless (equal (symbol-file symbol 'defun) ,(expand-file-name "supertag-tag.el" root))
                          (error "D6 owner is not Tag: %S" symbol))))
                    (when (memq ',entry '(tag menu))
                      (when (eq ',entry 'menu) (should-not (featurep 'supertag-tag)))
                      (unless (eq ',entry 'menu) (should (featurep 'supertag-service-org)))
                      (dolist (feature (append '(supertag-ui-commands supertag-services-ui supertag-services-sync
                                         supertag-query supertag-services-query supertag-services-note-query supertag-link
                                         supertag-view-framework supertag-view-api)
                                               (when (eq ',entry 'menu) '(supertag-service-org))))
                        (should-not (featurep feature))
                        (should-not (cl-find-if
                                     (lambda (row) (and (stringp (car row))
                                                       (equal (file-name-base (car row)) (symbol-name feature)))) load-history)))
                      (should-not (file-exists-p supertag-db-file))
                      (if (featurep 'supertag-node)
                          (progn (should (autoloadp (symbol-function 'supertag-node-sync-at-point)))
                                 (should (equal "supertag-services-sync" (nth 1 (symbol-function 'supertag-node-sync-at-point)))))
                        (should-not (fboundp 'supertag-node-sync-at-point))))
                    (setq supertag--store (with-temp-buffer (insert-file-contents ,snapshot) (read (current-buffer))))
                    (defun d6-contract ()
                      ;; Empty/missing nodes must error before any input.  On the
                      ;; old UI-only provider this is the authorized behavior red.
                      (cl-letf (((symbol-function 'completing-read)
                                 (lambda (&rest _) (ert-fail "empty selector prompted"))))
                        (should-error (supertag-ui-select-tag-on-node "missing") :type 'user-error))
                      (d6-owners)
                      (let* ((original (copy-tree (supertag-node-get "source")))
                             (raw '("unresolved" nil "stable")) seen)
                        (unwind-protect
                            (progn
                              (puthash "source" (plist-put (copy-tree original) :tags raw) (gethash :nodes supertag--store))
                              (cl-letf (((symbol-function 'supertag-ui-read-tag)
                                         (lambda (_prompt ids &rest _) (setq seen ids) "stable")))
                                (should (equal "stable" (supertag-ui-select-tag-on-node "source"))))
                              (should (equal raw seen))
                              (puthash "source" (plist-put (copy-tree original) :tags nil) (gethash :nodes supertag--store))
                              (should-error (supertag-ui-select-tag-on-node "source") :type 'user-error)
                              (puthash "source" (plist-put (copy-tree original) :tags '("unresolved" "stable")) (gethash :nodes supertag--store))
                              (cl-letf (((symbol-function 'completing-read)
                                         (lambda (_prompt candidates &rest _)
                                           (should (member "canonical" candidates))
                                           (should (member "unresolved" candidates)) "canonical")))
                                (should (equal "stable" (supertag-ui-select-tag-on-node "source")))))
                          (puthash "source" original (gethash :nodes supertag--store)))))
                    (when (eq ',entry 'tag) (d6-owners))
                    (unless (eq ',entry 'menu) (d6-contract))
                    (when (eq ',entry 'ui-commands-ui)
                      (if (equal (getenv "SUPERTAG_SYA_STAGE") "before")
      (load ,(expand-file-name "supertag-ui-commands.el" root) nil nil t)
    (require 'supertag-tag)) (d6-contract)
                      (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener t)) (d6-contract))
                    (when (eq ',entry 'commands-ui)
                      (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener t)) (d6-contract))
                    (unless (eq ',entry 'menu)
                      (load ,(expand-file-name "supertag-tag.el" root) nil nil t) (d6-contract))
                    (setq d6-provider-seen nil d6-sync-seen nil)
                    (defun d6-getter-observe (&rest _)
                      (should-not (autoloadp (symbol-function 'supertag-ui--get-containing-node-at-point)))
                      (should (equal (symbol-file 'supertag-ui--get-containing-node-at-point 'defun)
                                     ,(expand-file-name "supertag-node.el" root)))
                      (setq d6-provider-seen t))
                    (defun d6-sync-observe (&rest _)
                      (should (featurep 'supertag-services-sync))
                      (should-not
                       (autoloadp
                        (symbol-function 'supertag-service-org-save-and-record-tags-at-point)))
                      (should
                       (equal
                        (symbol-file 'supertag-service-org-save-and-record-tags-at-point 'defun)
                        ,(expand-file-name "supertag-service-org.el" root)))
                      (setq d6-sync-seen t))
                    (defun d6-sync-after-load (loaded)
                      (when (and (stringp loaded) (equal "supertag-services-sync" (file-name-base loaded)))
                        (advice-add 'supertag-service-org-save-and-record-tags-at-point :before #'d6-sync-observe)))
                    (defun d6-after-load (loaded)
                      (when (and (stringp loaded) (equal "supertag-node" (file-name-base loaded)))
                        (advice-add 'supertag-ui--get-containing-node-at-point :before #'d6-getter-observe)))
                    (if (featurep 'supertag-node)
                        (advice-add 'supertag-ui--get-containing-node-at-point :before #'d6-getter-observe)
                      (add-hook 'after-load-functions #'d6-after-load))
                    (if (featurep 'supertag-services-sync)
                        (d6-sync-after-load ,(expand-file-name "supertag-services-sync.el" root))
                      (add-hook 'after-load-functions #'d6-sync-after-load))
                    (let ((other ',(copy-tree (supertag-node-get "other")))
                          (entity ',(copy-tree (supertag-tag-get "stable"))))
                      (with-current-buffer (find-file-noselect ,file)
                        (goto-char (point-min))
                        (cl-letf (((symbol-function 'completing-read)
                                   (lambda (_prompt candidates &rest _)
                                     (should d6-provider-seen)
                                     (should (member "canonical" candidates)) "canonical")))
                          (call-interactively (if (eq ',entry 'menu)
                                                  #'supertag-menu--remove-tag #'supertag-remove-tag-from-node)))
                        (should-not (buffer-modified-p))
                        (should (equal (buffer-string) (with-temp-buffer (insert-file-contents ,file) (buffer-string)))))
                      (should (equal '("keep") (plist-get (supertag-node-get "source") :tags)))
                      (should (equal other (supertag-node-get "other")))
                      (should (equal entity (supertag-tag-get "stable"))))
                    (should d6-sync-seen)
                    (d6-owners)
                    (princ (format "D6-GRAPH %S commands=%S sync=%S node-getter-seen=%S\n"
                                   ',entry (featurep 'supertag-ui-commands) (featurep 'supertag-services-sync) d6-provider-seen))
                    (princ "D6-COLD-PASS\n"))
                (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
                (when (fboundp 'd6-after-load) (remove-hook 'after-load-functions #'d6-after-load))
                (when (fboundp 'd6-sync-after-load) (remove-hook 'after-load-functions #'d6-sync-after-load))
                (advice-remove 'supertag-ui--get-containing-node-at-point #'d6-getter-observe)
                (advice-remove 'supertag-service-org-save-and-record-tags-at-point #'d6-sync-observe)
                (mapc #'cancel-timer (append timer-list timer-idle-list)))))
        (with-temp-buffer
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (let* ((status (apply #'call-process program nil t nil
                                (append '("-Q" "--batch")
                                        (apply #'append (mapcar (lambda (dir) (list "-L" dir)) deps))
                                        (list "-L" root "--eval"
                                              (prin1-to-string `(condition-case err ,form
                                                                   (error (princ (format "D6-ERROR %S\n" err)) (kill-emacs 1))))))))
                 (output (buffer-string)))
            (unless (and (equal status 0) (string-match-p "D6-ENTRY-LOADED" output)
                         (string-match-p "D6-COLD-PASS" output))
              (ert-fail (format "D6 %S exit=%S\n%s" entry status output)))
            (princ (format "D6 %S exit0 ENTRY-LOADED/PASS\n" entry))
            (when (string-match "D6-GRAPH[^\n]*" output) (princ (concat (match-string 0 output) "\n")))))))))

(ert-deftest supertag-path-remove-cold-tag-and-commands-owners ()
  (dolist (entry '(tag commands commands-ui)) (supertag-path-test--d6-cold entry)))
(ert-deftest supertag-path-selector-cold-ui-hard-empty-and-reload-contract ()
  (dolist (entry '(ui ui-commands-ui)) (supertag-path-test--d6-cold entry)))
(ert-deftest supertag-path-remove-cold-menu-real-lazy-provider ()
  (supertag-path-test--d6-cold 'menu))

;;; D7 retained inline-write and token rules, exercised before migration.
(ert-deftest supertag-path-inline-write-format-and-token-merge-preserve-contract ()
  (should (equal " #a #b" (supertag--format-inline-tags '("a" "b"))))
  (should (equal "" (supertag--format-inline-tags nil)))
  (should (equal '("one" "two_words" "three")
                 (supertag--merge-and-sanitize-tags
                  '(" #one " nil "two words" "one") '("two_words" "three" nil))))
  (should-not (supertag--merge-and-sanitize-tags nil '(nil)))
  ;; Invalid non-nil names still reach the original sanitizer; do not silently drop them.
  (should-error (supertag--merge-and-sanitize-tags '("") nil))
  (should-error (supertag--merge-and-sanitize-tags '(" # ") nil)))

(ert-deftest supertag-path-inline-write-create-save-then-project ()
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "alpha-id" :name "alpha"))
    (supertag-tag-create '(:id "beta-id" :name "beta"))
    (let ((before (supertag-document-test-disk file))
          (real-save (symbol-function 'save-buffer))
          (real-project (symbol-function 'supertag-service-org--project-current-node))
          order id)
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args) (push 'save order) (apply real-save args)))
                ((symbol-function 'supertag-service-org--project-current-node)
                 (lambda (node-id) (push 'project order) (funcall real-project node-id))))
        (setq id (supertag-service-org-create-node file "D7" '("alpha" "beta")
                                                 '(:properties (("NOTE" . "kept")) :body "Own body\n"))))
      (should (equal '(save project) (nreverse order)))
      (should (stringp id))
      (let ((disk (supertag-document-test-disk file)) (node (supertag-node-get id)))
        (should (string-prefix-p before disk))
        (should (string-match-p (regexp-quote "* D7 #alpha #beta\n") disk))
        (should (string-match-p (concat ":ID:[ \t]+" (regexp-quote id) "[ \t]*\n") disk))
        (should (equal (sort (copy-sequence (plist-get node :tags)) #'string<) '("alpha-id" "beta-id")))
        (should (equal (file-truename file) (plist-get node :file)))
        (should (equal id (plist-get node :id)))
        (should (= 1 (plist-get node :level)))
        (should (equal "D7" (plist-get node :title)))
        (should (string-match-p "Own body" (plist-get node :content)))
        (with-current-buffer (find-file-noselect file)
          (should-not (buffer-modified-p)) (should (equal disk (buffer-string))))))))

;;; D7 Query first-use and loading graph in separate real processes.
(defun supertag-path-test--d7-cold (entry)
  (supertag-document-test-with-vault
    (dolist (props '((:id "parent-id" :name "topic")
                     (:id "child-id" :name "child" :extends ("parent-id"))
                     (:id "grand-id" :name "grand" :extends ("child-id"))))
      (supertag-tag-create props))
    (with-temp-file file
      (insert "* Parent #topic\n:PROPERTIES:\n:ID: p\n:END:\nP\n* Child #child\n:PROPERTIES:\n:ID: c\n:END:\nC\n* Grand #grand\n:PROPERTIES:\n:ID: g\n:END:\nG\n"))
    (supertag-reindex-org)
    (let* ((snapshot (expand-file-name "d7-projection.el" tmp))
           (root supertag-path-test--source-root)
           (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
           (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
           (process-environment (copy-sequence process-environment)))
      (with-temp-file snapshot
        (let ((print-length nil) (print-level nil)) (prin1 supertag--store (current-buffer))))
      (let ((form
             `(unwind-protect
                  (progn
                    (require 'cl-lib) (require 'ert) (require 'org)
                    (setq user-emacs-directory ,(expand-file-name "user/" tmp)
                          supertag-data-directory ,(expand-file-name "data/" tmp)
                          supertag--base-data-directory supertag-data-directory
                          supertag-db-file ,(expand-file-name "child-db.el" tmp)
                          supertag-db-backup-directory ,(expand-file-name "backups/" tmp)
                          supertag-sync-state-file ,(expand-file-name "child-sync.el" tmp)
                          supertag-sync--state-source supertag-sync-state-file
                          org-id-locations-file ,(expand-file-name "child-ids" tmp)
                          org-id-locations nil org-id-files nil org-id-track-globally nil
                          supertag-sync-directories nil supertag-active-sync-directory nil
                          after-init-time nil make-backup-files nil auto-save-default nil load-prefer-newer t)
                    (load (expand-file-name ,(pcase entry ('sync "supertag-services-sync.el")
                                               (_ "supertag-tag.el")) ,root) nil nil t)
                    (princ "D7-ENTRY-LOADED\n")
                    (defun d7-check ()
                      (dolist (symbol '(supertag--merge-and-sanitize-tags supertag--format-inline-tags
                                         supertag-view-api-nodes-by-tag))
                        (unless (equal (symbol-file symbol 'defun) ,(expand-file-name "supertag-tag.el" root))
                          (error "D7 function owner is not Tag: %S" symbol))))
                    (d7-check)
                    (when (eq ',entry 'tag)
                      (should (featurep 'supertag-service-org))
                      (dolist (feature '(supertag-query supertag-services-query supertag-services-note-query supertag-services-sync supertag-ui-commands
                                         supertag-services-ui supertag-view-api
                                         supertag-view-framework supertag))
                        (should-not (featurep feature))
                        (should-not (cl-find-if
                                     (lambda (row) (and (stringp (car row))
                                                       (equal (file-name-base (car row)) (symbol-name feature)))) load-history)))
                      (should-not (file-exists-p supertag-db-file))
                      (should (autoloadp (symbol-function 'supertag-query-node-ids-by-tag))))
                    (setq supertag--store (with-temp-buffer (insert-file-contents ,snapshot) (read (current-buffer))))
                    (let ((facts (prin1-to-string supertag--store)))
                      (should (equal '("p") (supertag-view-api-nodes-by-tag "parent-id" nil)))
                      (should (equal '("c" "g" "p")
                                     (sort (copy-sequence (supertag-view-api-nodes-by-tag "topic" t)) #'string<)))
                      (should-not (supertag-view-api-nodes-by-tag "missing" t))
                      (should-not (supertag-view-api-nodes-by-tag "" nil))
                      (should (equal facts (prin1-to-string supertag--store))))
                    (should (featurep 'supertag-query))
                    (should-not (autoloadp (symbol-function 'supertag-query-node-ids-by-tag)))
                    (should (equal (symbol-file 'supertag-query-node-ids-by-tag 'defun)
                                   ,(expand-file-name "supertag-query.el" root)))
                    (princ (format "D7-FIRST-QUERY %S Query=%S Sync=%S UI=%S\n"
                                   ',entry (featurep 'supertag-query)
                                   (featurep 'supertag-services-sync) (featurep 'supertag-services-ui)))
                    (dolist (name '("supertag-services-sync.el" "supertag-tag.el"))
                      (load (expand-file-name name ,root) nil nil t)
                      (d7-check))
                    (should (get 'supertag-sync 'group-documentation))
                    (princ "D7-COLD-PASS\n"))
                (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
                (mapc #'cancel-timer (append timer-list timer-idle-list)))))
        (with-temp-buffer
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (let* ((status (apply #'call-process program nil t nil
                                (append '("-Q" "--batch")
                                        (apply #'append (mapcar (lambda (dir) (list "-L" dir)) deps))
                                        (list "-L" root "--eval"
                                              (prin1-to-string `(condition-case err ,form
                                                                   (error (princ (format "D7-ERROR %S\n" err)) (kill-emacs 1))))))))
                 (output (buffer-string)))
            (unless (and (equal status 0) (string-match-p "D7-ENTRY-LOADED" output)
                         (string-match-p "D7-COLD-PASS" output))
              (ert-fail (format "D7 %S exit=%S\n%s" entry status output)))
            (princ (format "D7 %S exit0 ENTRY-LOADED/PASS\n" entry))
            (when (string-match "D7-FIRST-QUERY[^\n]*" output) (princ (concat (match-string 0 output) "\n")))))))))

(ert-deftest supertag-path-cold-tag-query-load-graph ()
  (supertag-path-test--d7-cold 'tag))
(ert-deftest supertag-path-cold-sync-first-query-load-graph ()
  (supertag-path-test--d7-cold 'sync))

;;; D8 original public read/display contracts, before ownership changes.
(ert-deftest supertag-path-adapter-real-directory-and-descriptor-selection ()
  (require 'supertag-tag)
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "z-id" :name "zulu" :aliases ("z-alias")))
    (supertag-tag-create '(:id "a-id" :name "alpha"))
    (let ((facts (prin1-to-string supertag--store)))
      (should (equal (sort (delete-dups (mapcar (lambda (row) (plist-get row :name))
                                               (supertag-query-tag-descriptors))) #'string<)
                     (supertag-view-api-list-tags)))
      (should (member "alpha" (supertag-view-api-list-tags)))
      (should-not (member "z-id" (supertag-view-api-list-tags)))
      (should-not (member "z-alias" (supertag-view-api-list-tags)))
      (should (equal facts (prin1-to-string supertag--store)))))
  ;; Deliberate provider descriptor seam: not a claim about normal Tag data.
  (cl-letf (((symbol-function 'supertag-query-tag-descriptors)
             (lambda () '((:name "z" :display "a")
                          (:name "a" :display "z") (:name "z" :display "b")))))
    (should (equal '("a" "z") (supertag-view-api-list-tags)))))

(ert-deftest supertag-path-adapter-tag-id-real-resolution-and-priority ()
  (require 'supertag-tag)
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "stable" :name "canonical" :aliases ("alias")))
    ;; Real creation rejects an alias claiming an existing ID; preserve that limit.
    (should-error (supertag-tag-create '(:id "other" :name "other-name" :aliases ("stable")))
                  :type 'user-error)
    (let ((facts (prin1-to-string supertag--store)))
      (dolist (value '("stable" "canonical" "alias"))
        (should (equal "stable" (supertag-view-api-tag-id value))))
      (should-not (supertag-view-api-tag-id "unknown"))
      (should-error (supertag-view-api-tag-id " ") :type 'error)
      (dolist (value '(nil 12 "")) (should-error (supertag-view-api-tag-id value) :type 'error))
      (should (equal facts (prin1-to-string supertag--store)))))
  ;; Explicit synthetic collision isolates old ID-first precedence, not creation policy.
  (supertag-path-test--with-store
    (supertag-store-put-entity :tags "stable" '(:id "stable" :name "canonical" :type :tag))
    (supertag-store-put-entity :tags "other" '(:id "other" :name "other-name" :aliases ("stable") :type :tag))
    (supertag-tag-index-rebuild)
    (should (equal "stable" (supertag-view-api-tag-id "stable")))))

(ert-deftest supertag-path-adapter-node-tags-real-read-and-input-guard ()
  (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener))
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "stable" :name "canonical"))
    (with-temp-file file
      (insert "* Node #canonical\n:PROPERTIES:\n:ID: d8-node\n:END:\nBody\n"))
    (supertag-reindex-org)
    (let ((facts (prin1-to-string supertag--store))
          (disk (supertag-document-test-disk file))
          (live (with-current-buffer (find-file-noselect file) (buffer-string)))
          (dirty (with-current-buffer (find-file-noselect file) (buffer-modified-p)))
          (real (symbol-function 'supertag-query-node-tags)) calls)
      (cl-letf (((symbol-function 'supertag-query-node-tags)
                 (lambda (id) (push id calls) (funcall real id))))
        (should-not (supertag-view--resolve-node-tags nil))
        (should-not (supertag-view--resolve-node-tags 42))
        (should-not calls)
        (should-not (supertag-view--resolve-node-tags ""))
        (should (equal '("") calls))
        (should-not (supertag-view--resolve-node-tags "missing"))
        (should (equal '("stable") (supertag-view--resolve-node-tags "d8-node"))))
      (should (equal facts (prin1-to-string supertag--store)))
      (should (equal disk (supertag-document-test-disk file)))
      (with-current-buffer (find-file-noselect file)
        (should (equal live (buffer-string))) (should (eq dirty (buffer-modified-p))))))
  ;; Synthetic projection input, distinct from D6's raw selector contract.
  (supertag-path-test--with-store
    (supertag-store-put-entity :nodes "n" '(:id "n" :tags ("unresolved" nil 7 "stable" "stable")))
    (let ((facts (prin1-to-string supertag--store)))
      (should (equal '("unresolved" "stable" "stable") (supertag-view--resolve-node-tags "n")))
      (should (equal facts (prin1-to-string supertag--store))))))

(ert-deftest supertag-path-adapter-formatter-real-colors-and-inputs ()
  (require (if (equal (getenv "SUPERTAG_VWD_STAGE") "before") 'supertag-view-helper 'supertag-tag))
  (dolist (value '(nil ""))
    (let ((result (supertag-view-helper-format-tag-value value)))
      (should (equal "[No tags]" result))
      (should (eq 'supertag-view-mute (get-text-property 0 'face result)))))
  (dolist (value '(" a, b " (" a " "b")))
    (let ((result (supertag-view-helper-format-tag-value value)))
      (should (equal "#a #b" result))
      (should (memq 'supertag-view-accent
                    (let ((face (get-text-property 0 'face result)))
                      (if (listp face) face (list face)))))
      (should-not (text-properties-at 2 result))))
  (should (equal "" (supertag-view-helper-format-tag-value ",,")))
  (should (equal "" (supertag-view-helper-format-tag-value " ")))
  (should (equal "##tag" (supertag-view-helper-format-tag-value "#tag")))
  (should (equal "#12" (supertag-view-helper-format-tag-value 12)))
  (should-error (supertag-view-helper-format-tag-value '(12)) :type 'wrong-type-argument))

;;; D8 fresh entry and first-use providers; no unload-based simulated cold state.
(defun supertag-path-test--d8-cold (operation)
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "stable" :name "canonical" :aliases ("alias")))
    (with-temp-file file
      (insert "* Node #canonical\n:PROPERTIES:\n:ID: d8-node\n:END:\nBody\n"))
    (supertag-reindex-org)
    (let* ((snapshot (expand-file-name "d8-projection.el" tmp))
           (root supertag-path-test--source-root)
           (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
           (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
           (process-environment (copy-sequence process-environment)))
      (with-temp-file snapshot
        (let ((print-length nil) (print-level nil)) (prin1 supertag--store (current-buffer))))
      (let ((form
             `(unwind-protect
                  (progn
                    (require 'cl-lib) (require 'ert) (require 'org)
                    (setq user-emacs-directory ,(expand-file-name "user/" tmp)
                          supertag-data-directory ,(expand-file-name "data/" tmp)
                          supertag--base-data-directory supertag-data-directory
                          supertag-db-file ,(expand-file-name "child-db.el" tmp)
                          supertag-db-backup-directory ,(expand-file-name "backups/" tmp)
                          supertag-sync-state-file ,(expand-file-name "child-sync.el" tmp)
                          supertag-sync--state-source supertag-sync-state-file
                          org-id-locations-file ,(expand-file-name "child-ids" tmp)
                          org-id-locations nil org-id-files nil org-id-track-globally nil
                          supertag-sync-directories nil supertag-active-sync-directory nil
                          after-init-time nil make-backup-files nil auto-save-default nil load-prefer-newer t
                          global-supertag-ui-completion-mode nil
                          supertag-view-style-auto-enable nil)
                    (load (expand-file-name ,(if (eq operation 'node-first)
                                                "supertag-node.el" "supertag-tag.el") ,root) nil nil t)
                    (princ "D8-ENTRY-LOADED\n")
                    (when (eq ',operation 'node-first)
                      (should (featurep 'supertag-node))
                      (should-not (featurep 'supertag-tag))
                      (should-not (featurep 'supertag-view-helper))
                      (should-not (featurep 'supertag-view-framework))
                      (princ "VWD-D8-NODE-COLD-BEFORE-TAG\n")
                      (require 'supertag-tag))
                    (defun d8-owners ()
                      (dolist (symbol '(supertag-view-api-list-tags supertag-view-api-tag-id
                                         supertag-view--resolve-node-tags supertag-view-helper-format-tag-value))
                        (unless (equal (symbol-file symbol 'defun) ,(expand-file-name "supertag-tag.el" root))
                          (error "D8 owner is not Tag: %S" symbol)))
                      (should-not global-supertag-ui-completion-mode)
                      (should-not supertag-view-style-auto-enable))
                    (d8-owners)
                    (unless (eq ',operation 'node-first)
                      (should (featurep 'supertag-service-org))
                      (dolist (feature '(supertag-view-helper supertag-view-api supertag-query supertag-services-query supertag-services-note-query
                                         supertag-services-ui supertag-ui-commands supertag-services-sync
                                         supertag-view-framework supertag))
                        (should-not (featurep feature))
                        (should-not (cl-find-if
                                     (lambda (row) (and (stringp (car row))
                                                       (equal (file-name-base (car row)) (symbol-name feature)))) load-history)))
                      (should-not (file-exists-p supertag-db-file))
                      (should-not (fboundp 'supertag-view-helper-insert-section-chip)))
                    (setq supertag--store (with-temp-buffer (insert-file-contents ,snapshot) (read (current-buffer))))
                    (let ((facts (prin1-to-string supertag--store))
                          (disk (with-temp-buffer (insert-file-contents ,file) (buffer-string))))
                      (if (eq ',operation 'query)
                          (progn
                            (should (equal '("canonical") (supertag-view-api-list-tags)))
                            (should (equal '("stable") (supertag-view--resolve-node-tags "d8-node")))
                            (should (equal "stable" (supertag-view-api-tag-id "alias")))
                            (dolist (symbol '(supertag-query-tag-descriptors supertag-query-node-tags))
                              (should-not (autoloadp (symbol-function symbol)))
                              (should (equal (symbol-file symbol 'defun)
                                             ,(expand-file-name "supertag-query.el" root))))
                            (should (featurep 'supertag-query))
                            (should-not (featurep 'supertag-view-helper)))
                        (let ((formatted (supertag-view-helper-format-tag-value
                                          ,(unless (eq operation 'empty) "canonical"))))
                          (should (equal (if (eq ',operation 'empty) "[No tags]" "#canonical")
                                         formatted))
                          (should (memq (if (eq ',operation 'empty)
                                            'supertag-view-mute
                                          'supertag-view-accent)
                                        (let ((face (get-text-property 0 'face formatted)))
                                          (if (listp face) face (list face))))))
                          (should (featurep 'supertag-view-framework))
                          (should (equal (symbol-file 'supertag-view-apply-palette 'defun)
                                         ,(expand-file-name "supertag-view-framework.el" root))))
                      (should (equal facts (prin1-to-string supertag--store)))
                      (should (equal disk (with-temp-buffer (insert-file-contents ,file) (buffer-string)))))
                    (princ (format "D8-FIRST %S helper=%S api=%S query=%S sync=%S ui=%S\n"
                                   ',operation (featurep 'supertag-view-helper) (featurep 'supertag-view-api)
                                   (featurep 'supertag-query) (featurep 'supertag-services-sync)
                                   (featurep 'supertag-services-ui)))
                    (progn
                      (require 'supertag-query)
                      (require 'supertag-tag)
                      (require 'supertag-services-sync)
                      (supertag-node--prepare-cache-listener t)
                      (d8-owners)
                      (dolist (carrier '("supertag-tag.el"))
                        (load (expand-file-name carrier ,root) nil nil t)
                        (d8-owners)))
                    (princ "D8-COLD-PASS\n"))
                (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
                (mapc #'cancel-timer (append timer-list timer-idle-list)))))
        (with-temp-buffer
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (let* ((status (apply #'call-process program nil t nil
                                (append '("-Q" "--batch")
                                        (apply #'append (mapcar (lambda (dir) (list "-L" dir)) deps))
                                        (list "-L" root "--eval"
                                              (prin1-to-string `(condition-case err ,form
                                                                   (error (princ (format "D8-ERROR %S\n" err)) (kill-emacs 1))))))))
                 (output (buffer-string)))
            (unless (and (equal status 0) (string-match-p "D8-ENTRY-LOADED" output)
                         (string-match-p "D8-COLD-PASS" output))
              (ert-fail (format "D8 %S exit=%S\n%s" operation status output)))
            (princ (format "D8 %S exit0 ENTRY-LOADED/PASS\n" operation))
            (when (string-match "D8-FIRST[^\n]*" output) (princ (concat (match-string 0 output) "\n")))))))))

(ert-deftest supertag-path-adapter-cold-query-owner-and-first-read ()
  (supertag-path-test--d8-cold 'query))
(ert-deftest supertag-path-adapter-cold-empty-color-provider ()
  (supertag-path-test--d8-cold 'empty))
(ert-deftest supertag-path-adapter-cold-nonempty-color-provider ()
  (supertag-path-test--d8-cold 'nonempty))
(ert-deftest supertag-path-adapter-cold-node-first-reload-owner ()
  (supertag-path-test--d8-cold 'node-first))

;;; D9 original entity/namespace contracts, measured before migration.
(ert-deftest supertag-path-entity-ensure-preserves-metadata-order-and-partial-failure ()
  (supertag-path-test--with-store
    (supertag-tag-create '(:id "stable" :name "canonical" :aliases ("alias")))
    (let* ((original (copy-tree (supertag-tag-get "stable")))
           (ids (supertag--create-tag-entities '("stable" "canonical" "alias" "new/child" "stable" "new/child")))
           (child (supertag-tag-resolve-occurrence "child")))
      (should (equal (list "stable" "stable" "stable" child "stable" child) ids))
      (should (equal original (supertag-tag-get "stable")))
      (should child)
      ;; stable + the `new' parent + the `child' leaf
      (should (= 3 (hash-table-count (supertag-store-get-collection :tags))))
      (should (equal (list (supertag-tag-resolve-occurrence "new"))
                     (supertag-tag-parents child)))
      (let ((facts (prin1-to-string supertag--store)))
        (should-not (supertag--create-tag-entities nil))
        (should (equal facts (prin1-to-string supertag--store))))
      ;; The loop is not a transaction: an invalid later item does not undo a prior create.
      (should-error (supertag--create-tag-entities '("partial/child" "")) :type 'error)
      (should (supertag-tag-resolve-occurrence "child"))
      (should (supertag-tag-resolve-occurrence "partial"))
      (should (equal original (supertag-tag-get "stable")))
      (let ((facts (prin1-to-string supertag--store)))
        (should-error (supertag--create-tag-entities '(" ")) :type 'error)
        (should (equal facts (prin1-to-string supertag--store)))))))

(ert-deftest supertag-path-normalize-retains-unknown-path-without-entity ()
  (supertag-path-test--with-store
    (supertag-tag-create '(:id "stable" :name "canonical" :aliases ("alias")))
    (let ((facts (prin1-to-string supertag--store)))
      (dolist (token '("stable" "canonical" "alias"))
        (should (equal "stable" (supertag--normalize-tag-id token))))
      (should (equal "future/path" (supertag--normalize-tag-id " #future/path ")))
      (should-not (supertag-tag-resolve-occurrence "future/path"))
      (dolist (token '("" " "))
        (should-error (supertag--normalize-tag-id token) :type 'error))
      (should (equal facts (prin1-to-string supertag--store))))))

(ert-deftest supertag-path-hierarchy-adapters-use-explicit-parents ()
  (supertag-path-test--with-store
    (supertag-tag-create '(:id "parent" :name "root" :aliases ("root-alias")))
    (dolist (props '((:id "child-a" :name "book" :extends ("parent"))
                     (:id "grand" :name "paper" :extends ("child-a"))
                     (:id "child-b" :name "article" :extends ("parent"))
                     (:id "other" :name "rootx")))
      (supertag-tag-create props))
    (let ((facts (prin1-to-string supertag--store)))
      (dolist (token '("parent" "root" "root-alias"))
        (should (equal '("child-a" "child-b" "grand")
                       (supertag-find-tag-descendants token))))
      (should (equal '("child-a" "child-b") (supertag-query-tag-children "parent")))
      (should-not (supertag-query-tag-children "root-alias"))
      (should (equal "root › book › paper" (supertag-tag-display-name "grand")))
      ;; A path separator cannot be part of a Tag name, so no adapter can
      ;; mistake a name for hierarchy.
      (should-error (supertag-tag-create '(:name "virtual/child")) :type 'user-error)
      (dolist (id '("missing" "child-b"))
        (should-not (supertag-find-tag-descendants id))
        (should-not (supertag-query-tag-children id)))
      (should (equal facts (prin1-to-string supertag--store))))))

;;; D9 independent entry: pure Tag calls vs actual Query node membership.
(defun supertag-path-test--d9-cold (entry)
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "parent" :name "root" :aliases ("root-alias")))
    (supertag-tag-create '(:id "child" :name "child" :extends ("parent")))
    (supertag-tag-create '(:id "grand" :name "grand" :extends ("child")))
    (with-temp-file file
      (insert "* Parent #root\n:PROPERTIES:\n:ID: p\n:END:\nP\n* Child #child\n:PROPERTIES:\n:ID: c\n:END:\nC\n* Grand #grand\n:PROPERTIES:\n:ID: g\n:END:\nG\n"))
    (supertag-reindex-org)
    (let* ((snapshot (expand-file-name "d9-projection.el" tmp))
           (root supertag-path-test--source-root)
           (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
           (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
           (process-environment (copy-sequence process-environment)))
      (with-temp-file snapshot
        (let ((print-length nil) (print-level nil)) (prin1 supertag--store (current-buffer))))
      (let ((form
             `(unwind-protect
                  (progn
                    (require 'cl-lib) (require 'ert) (require 'org)
                    (setq user-emacs-directory ,(expand-file-name "user/" tmp)
                          supertag-data-directory ,(expand-file-name "data/" tmp)
                          supertag--base-data-directory supertag-data-directory
                          supertag-db-file ,(expand-file-name "child-db.el" tmp)
                          supertag-db-backup-directory ,(expand-file-name "backups/" tmp)
                          supertag-sync-state-file ,(expand-file-name "child-sync.el" tmp)
                          supertag-sync--state-source supertag-sync-state-file
                          org-id-locations-file ,(expand-file-name "child-ids" tmp)
                          org-id-locations nil org-id-files nil org-id-track-globally nil
                          supertag-sync-directories nil supertag-active-sync-directory nil
                          after-init-time nil make-backup-files nil auto-save-default nil load-prefer-newer t
                          global-supertag-ui-completion-mode nil
                          supertag-view-style-auto-enable nil)
                    (load (expand-file-name ,(pcase entry ('scan "supertag-query.el")
                                               ('query "supertag-query.el")
                                               ('sync "supertag-services-sync.el") (_ "supertag-tag.el")) ,root) nil nil t)
                    (princ "D9-ENTRY-LOADED\n")
                    (defun d9-owners ()
                      (dolist (symbol '(supertag--normalize-tag-id supertag--create-tag-entities
                                         supertag-find-tag-descendants supertag-query-tag-children))
                        (unless (and (not (autoloadp (symbol-function symbol)))
                                     (equal (symbol-file symbol 'defun) ,(expand-file-name "supertag-tag.el" root)))
                          (error "D9 owner is not Tag: %S" symbol)))
                      (should-not global-supertag-ui-completion-mode)
                      (should-not supertag-view-style-auto-enable))
                    (defun d9-pure-load-graph ()
                      (should (featurep 'supertag-service-org))
                      (dolist (feature '(supertag-core-scan supertag-query supertag-services-query supertag-services-note-query supertag-services-sync
                                         supertag-services-ui supertag-ui-commands supertag-view-framework supertag))
                        (should-not (featurep feature))
                        (should-not (cl-find-if
                                     (lambda (row) (and (stringp (car row))
                                                       (equal (file-name-base (car row)) (symbol-name feature)))) load-history)))
                      (should-not (file-exists-p supertag-db-file)))
                    (if (memq ',entry '(query scan))
                        (progn
                          (dolist (feature '(supertag-tag supertag-node supertag-core-scan))
                            (should-not (featurep feature))
                            (should-not (cl-find-if
                                         (lambda (row) (and (stringp (car row))
                                                           (equal (file-name-base (car row)) (symbol-name feature)))) load-history)))
                          (should-not (bound-and-true-p supertag-view-style-mode))
                          (should-not (bound-and-true-p org-capture-after-finalize-hook))
                          (should-not (memq 'supertag-view-helper--auto-enable org-mode-hook))
                          (should-not (file-exists-p supertag-db-file)))
                      (d9-owners))
                    (when (eq ',entry 'tag) (d9-pure-load-graph))
                    (setq supertag--store (with-temp-buffer (insert-file-contents ,snapshot) (read (current-buffer))))
                    (when (memq ',entry '(query scan))
                      (let ((facts (prin1-to-string supertag--store))
                            (disk (with-temp-buffer (insert-file-contents ,file) (buffer-string))))
                        (should (equal '("p") (supertag-query-node-ids-by-tag "parent")))
                        (should (equal facts (prin1-to-string supertag--store)))
                        (should (equal disk (with-temp-buffer (insert-file-contents ,file) (buffer-string)))))
                      (d9-owners))
                    (let ((original (copy-tree (supertag-tag-get "parent")))
                          (facts (prin1-to-string supertag--store))
                          (nodes (prin1-to-string (supertag-store-get-collection :nodes)))
                          (disk (with-temp-buffer (insert-file-contents ,file) (buffer-string))))
                      (should (equal "parent" (supertag--normalize-tag-id "root-alias")))
                      (should (equal "future/path" (supertag--normalize-tag-id "future/path")))
                      (should (equal '("child" "grand") (supertag-find-tag-descendants "root-alias")))
                      (should (equal '("child") (supertag-query-tag-children "parent")))
                      (should (equal '("parent" "parent") (supertag--create-tag-entities '("root" "root-alias"))))
                      (should (equal facts (prin1-to-string supertag--store)))
                      (let* ((ids (supertag--create-tag-entities '("virtual/child" "virtual/child")))
                             (created (supertag-tag-resolve-occurrence "child"))
                             (virtual (supertag-tag-resolve-occurrence "virtual")))
                        (should created)
                        (should (equal (list created created) ids))
                        ;; the path's parent is real hierarchy, created once
                        (should virtual)
                        (should (member virtual (supertag-tag-parents created)))
                        (should (equal (list created) (supertag-query-tag-children virtual)))
                        (should (member created (supertag-find-tag-descendants "virtual"))))
                      (should (equal original (supertag-tag-get "parent")))
                      (should (equal nodes (prin1-to-string (supertag-store-get-collection :nodes))))
                      (should (equal disk (with-temp-buffer (insert-file-contents ,file) (buffer-string)))))
                    (when (eq ',entry 'tag) (d9-pure-load-graph))
                    (princ (format "D9-PURE %S scan=%S query=%S sync=%S\n" ',entry
                                   (featurep 'supertag-core-scan) (featurep 'supertag-query)
                                   (featurep 'supertag-services-sync)))
                    ;; Actual node membership remains a Query/scan/index operation.
                    (load (expand-file-name "supertag-query.el" ,root) nil nil t)
                    (let ((facts (prin1-to-string supertag--store)))
                      (should (equal '("p") (supertag-query-node-ids-by-tag "parent")))
                      (should (equal '("c" "g" "p")
                                     (sort (copy-sequence (supertag-query-node-ids-by-tag "root-alias" t)) #'string<)))
                      (should (equal '("c" "g" "p")
                                     (sort (mapcar #'car (supertag-find-nodes-by-tag "parent" t)) #'string<)))
                      (should (equal facts (prin1-to-string supertag--store))))
                    (should (equal (symbol-file 'supertag-index-get-nodes-by-tag 'defun)
                                   ,(expand-file-name "supertag-query.el" root)))
                    (should (featurep 'supertag-query))
                    (dolist (carrier '("supertag-query.el"
                                       "supertag-services-sync.el" "supertag-tag.el"))
                      (load (expand-file-name carrier ,root) nil nil t)
                      (d9-owners))
                    (princ "D9-COLD-PASS\n"))
                (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
                (mapc #'cancel-timer (append timer-list timer-idle-list)))))
        (with-temp-buffer
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (let* ((status (apply #'call-process program nil t nil
                                (append '("-Q" "--batch")
                                        (apply #'append (mapcar (lambda (dir) (list "-L" dir)) deps))
                                        (list "-L" root "--eval"
                                              (prin1-to-string `(condition-case err ,form
                                                                   (error (princ (format "D9-ERROR %S\n" err)) (kill-emacs 1))))))))
                 (output (buffer-string)))
            (unless (and (equal status 0) (string-match-p "D9-ENTRY-LOADED" output)
                         (string-match-p "D9-COLD-PASS" output))
              (ert-fail (format "D9 %S exit=%S\n%s" entry status output)))
            (princ (format "D9 %S exit0 ENTRY-LOADED/PASS\n" entry))
            (when (string-match "D9-PURE[^\n]*" output) (princ (concat (match-string 0 output) "\n")))))))))

(ert-deftest supertag-path-entity-cold-tag-only-pure-calls ()
  (supertag-path-test--d9-cold 'tag))
(ert-deftest supertag-path-entity-cold-scan-first-membership ()
  (supertag-path-test--d9-cold 'scan))
(ert-deftest supertag-path-entity-cold-query-first-membership ()
  (supertag-path-test--d9-cold 'query))
(ert-deftest supertag-path-entity-cold-sync-first-membership ()
  (supertag-path-test--d9-cold 'sync))

;;; V2-TAG-PARSER isolated source/compiled ownership and mutation controls.
(defconst supertag-path-test--tp-program ";;; -*- lexical-binding: t; -*-\n(require 'ert)\n(require 'cl-lib)\n(require 'subr-x)\n(setq user-emacs-directory (file-name-as-directory (getenv \"TP_TMP\"))\n      default-directory user-emacs-directory after-init-time nil load-prefer-newer t\n      supertag-data-directory (expand-file-name \"data/\" user-emacs-directory)\n      supertag--base-data-directory supertag-data-directory\n      supertag-db-file (expand-file-name \"store.el\" user-emacs-directory)\n      supertag-db-backup-directory (expand-file-name \"backups/\" user-emacs-directory)\n      supertag-sync-state-file (expand-file-name \"sync.el\" user-emacs-directory)\n      supertag-sync--state-source supertag-sync-state-file\n      org-id-locations-file (expand-file-name \"ids\" user-emacs-directory)\n      org-id-track-globally nil supertag-sync-directories nil supertag-active-sync-directory nil\n      supertag-view-style-auto-enable nil supertag-svg-tag-enable nil\n      make-backup-files nil auto-save-default nil)\n(defun tp-before () (equal (getenv \"SUPERTAG_TAG_PARSER_STAGE\") \"before\"))\n(defun tp-provider () (require (if (tp-before) 'supertag-core-transform 'supertag-tag)))\n(defun tp-names (matches) (mapcar #'caddr matches))\n(defun tp-disk (file) (with-temp-buffer (insert-file-contents-literally file) (buffer-string)))\n(defun tp-no-sync ()\n  (should-not (featurep 'supertag-services-sync))\n  (should-not (cl-find-if (lambda (x) (and (stringp (car x)) (equal \"supertag-services-sync\" (file-name-base (car x))))) load-history)))\n(defun tp-owner ()\n  (princ \"TP-OWNER-ENTRY actual-provider-and-match\\n\")\n  (dolist (symbol '(supertag-inline-tag-terminator-chars supertag-inline-tag-boundary-char-regexp\n                    supertag-inline-tag-boundary-regexp supertag-inline-tag-regexp\n                    supertag-transform-inline-tag-name-p supertag-transform--inline-tag-object-ranges\n                    supertag-transform--inline-tag-prose-end supertag-transform-inline-tag-matches-in-region\n                    supertag-transform-extract-inline-tags))\n    (should (equal (file-name-nondirectory (symbol-file symbol (if (string-prefix-p \"supertag-inline\" (symbol-name symbol)) 'defvar 'defun)))\n                   (if (and (tp-before) (not (getenv \"TP_OWNER_RED\"))) \"supertag-core-transform.el\" \"supertag-tag.el\")))))\n(defun tp-lexical ()\n  (tp-provider)\n  (princ \"TP-ENTRY lexical\\n\")\n  (let ((actual (supertag-transform-extract-inline-tags \"#root plain #tag　＃全角，中文#中文。 #a/b #a_b #x^2 #dup #dup #'quoted word#embedded https://x/y#fragment\")))\n    (princ (format \"TP-PARSE-ACTUAL %S\\n\" actual))\n    (should (equal actual (if (getenv \"TP_WRONG_OUTPUT\") '(\"impossible\") '(\"root\" \"tag\" \"全角\" \"中文\" \"a/b\" \"a_b\" \"x^2\" \"dup\" \"dup\")))))\n  (should (equal \"＃　，。；：！？、（）【】《》“”‘’\" supertag-inline-tag-terminator-chars))\n  (should (equal \"\\\\(?:[[:space:]]\\\\|\\\\cc\\\\|\\\\cj\\\\|\\\\ck\\\\|\\\\ch\\\\)\" supertag-inline-tag-boundary-char-regexp))\n  (should (equal \"\\\\(?:\\\\`\\\\|\\\\([[:space:]]\\\\)\\\\|\\\\cc\\\\|\\\\cj\\\\|\\\\ck\\\\|\\\\ch\\\\)\" supertag-inline-tag-boundary-regexp))\n  (should (equal (concat supertag-inline-tag-boundary-regexp \"[#＃]\\\\(\" supertag-inline-tag-name-inner-regexp supertag-inline-tag-name-last-regexp \"\\\\)\") supertag-inline-tag-regexp))\n  (should-not (supertag-transform-inline-tag-name-p nil))\n  (should-not (supertag-transform-inline-tag-name-p \"\"))\n  (should-not (supertag-transform-inline-tag-name-p \"'quote\"))\n  (should (supertag-transform-inline-tag-name-p \"a/b\"))\n  (should-not (supertag-transform-extract-inline-tags nil))\n  (should-not (supertag-transform-extract-inline-tags \"\"))\n  (should (equal '(\"x\" \"y\") (supertag-transform-extract-inline-tags \"#x\\n#y\"))))\n(defun tp-objects ()\n  (tp-provider)\n  (princ \"TP-ENTRY objects\\n\")\n  (let ((text \"* Title #head [[id:target][#link]] =#code= ~#verb~ #a_b #x^2\\nParagraph #para [[id:t][#hidden]] and #tail\\n\")\n        (facts (prin1-to-string supertag--store)))\n    (with-temp-buffer\n      (org-mode) (insert text) (set-buffer-modified-p nil)\n      (let* ((tree (org-element-parse-buffer)) (hl (car (org-element-map tree 'headline #'identity)))\n             (paragraph (car (org-element-map tree 'paragraph #'identity)))\n             (head-end (save-excursion (goto-char (point-min)) (line-end-position)))\n             (head (supertag-transform-inline-tag-matches-in-region (point-min) head-end hl))\n             (pb (org-element-property :begin paragraph)) (pe (org-element-property :end paragraph))\n             (with-element (supertag-transform-inline-tag-matches-in-region pb pe paragraph))\n             (secondary (supertag-transform-inline-tag-matches-in-region pb pe nil 'paragraph))\n             (ranges (supertag-transform--inline-tag-object-ranges (point-min) head-end hl))\n             (transparent (cl-find-if #'caddr ranges)) (opaque (cl-find-if-not #'caddr ranges)))\n        (princ (format \"TP-OBJECT-ACTUAL head=%S paragraph=%S ranges=%S\\n\" (tp-names head) (tp-names with-element) ranges))\n        (should (equal '(\"head\" \"a_b\" \"x^2\") (tp-names head)))\n        (should (equal '(\"para\" \"tail\") (tp-names with-element)))\n        (should (equal with-element secondary))\n        (dolist (match (append head with-element))\n          (should (equal (concat \"#\" (caddr match)) (buffer-substring-no-properties (car match) (cadr match)))))\n        (should transparent) (should opaque)\n        (should-not (supertag-transform--inline-tag-prose-end (car transparent) head-end ranges))\n        (should-not (supertag-transform--inline-tag-prose-end (car opaque) head-end ranges))\n        (should (= (car opaque) (supertag-transform--inline-tag-prose-end (1- (car opaque)) head-end ranges)))\n        (goto-char (point-max))\n        (let ((saved (point)))\n          (save-restriction\n            (narrow-to-region pb pe)\n            (should (equal secondary (supertag-transform-inline-tag-matches-in-region (point-min) (point-max)))))\n          (should (= saved (point))))\n        (should (equal text (buffer-substring-no-properties (point-min) (point-max))))\n        (should-not (buffer-modified-p))))\n    (should (equal facts (prin1-to-string supertag--store))))\n  (with-temp-buffer\n    (org-mode) (insert \"prefix\\n #one #two\\n\")\n    (goto-char (point-min)) (search-forward \"#one\")\n    (let ((start (- (point) 4)) (saved (point)))\n      (should (equal '(\"one\" \"two\") (tp-names (supertag-transform-inline-tag-matches-in-region start (point-max)))))\n      (should (= saved (point)))\n      (should (equal '(\"two\") (tp-names (supertag-transform-inline-tag-matches-in-region (1+ start) (point-max))))))))\n(defun tp-entry ()\n  (require 'org)\n  (should-not (featurep 'supertag-tag)) (tp-no-sync)\n  (should-not (boundp 'supertag-inline-tag-regexp))\n  (should-not (fboundp 'supertag-transform-inline-tag-matches-in-region))\n  (let* ((file (expand-file-name \"entry.org\" user-emacs-directory))\n         (text \"* Existing\\n:PROPERTIES:\\n:ID: tp-entry\\n:END:\\n#known [[id:other][#inside]]\\n\")\n         (plain (generate-new-buffer \" *tp-text*\")) (source nil))\n    (write-region text nil file nil 'silent)\n    (setq source (find-file-noselect file))\n    (with-current-buffer plain (text-mode) (insert text) (set-buffer-modified-p nil))\n    (unwind-protect\n        (progn\n          (tp-provider)\n          (princ \"TP-ENTRY entry\\n\")\n          (with-current-buffer source\n            (goto-char (point-min)) (search-forward \"#known\")\n            (should (equal '(\"known\") (tp-names (supertag-transform-inline-tag-matches-in-region (line-beginning-position) (line-end-position))))))\n          (tp-owner) (tp-no-sync)\n          (unless (tp-before)\n            (should-not (featurep 'supertag-core-transform))\n            (should-not (locate-library \"supertag-core-transform\"))\n            (should-not (cl-find-if (lambda (x) (and (stringp (car x)) (equal \"supertag-core-transform\" (file-name-base (car x))))) load-history)))\n          ;; Before only Transform provided the parser; display requires real Tag separately.\n          (require 'supertag-tag)\n          (supertag--ensure-store)\n          (puthash \"known\" '(:id \"known\" :name \"known\" :type :tag) (supertag-store-get-collection :tags))\n          (let ((facts (prin1-to-string supertag--store)))\n            (with-current-buffer source\n              (should-not supertag-view-style-mode)\n              (supertag-view-style-mode 1)\n              (font-lock-flush) (font-lock-ensure)\n              (goto-char (point-min)) (search-forward \"#known\")\n              (should (eq 'supertag-inline-face (get-text-property (- (point) 6) 'face)))\n              (goto-char (point-min)) (search-forward \"#inside\")\n              (should-not (eq 'supertag-inline-face (get-text-property (- (point) 7) 'face)))\n              (should (equal text (buffer-substring-no-properties (point-min) (point-max))))\n              (should-not (buffer-modified-p))\n              (supertag-view-style-mode -1))\n            (with-current-buffer plain (should-not supertag-view-style-mode))\n            (should (equal facts (prin1-to-string supertag--store))))\n          (tp-no-sync)\n          (should (equal text (tp-disk file))))\n      (dolist (b (list source plain)) (when (buffer-live-p b) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))))))\n(defun tp-cold-container (feature)\n  (should-not (featurep feature)) (should-not (featurep 'supertag-tag)) (tp-no-sync)\n  (require feature)\n  (princ (format \"TP-ENTRY %s\\n\" (getenv \"TP_CASE\")))\n  (should-not (featurep 'supertag-tag)) (tp-no-sync)\n  (should (eq (featurep 'supertag-core-transform) (tp-before)))\n  (should (eq (boundp 'supertag-inline-tag-regexp) (tp-before)))\n  (should (eq (fboundp 'supertag-transform-inline-tag-matches-in-region) (tp-before)))\n  (princ (format \"TP-CONTAINER-ACTUAL feature=%S org=%S parser=%S\\n\" feature (featurep 'org) (fboundp 'supertag-transform-inline-tag-matches-in-region)))\n  (tp-provider)\n  (with-temp-buffer (org-mode) (insert \"#actual [[id:x][#hidden]]\")\n    (should (equal '(\"actual\") (tp-names (supertag-transform-inline-tag-matches-in-region (point-min) (point-max))))))\n  (tp-no-sync))\n(defun tp-reload ()\n  (require 'org)\n  (dolist (s '(supertag-inline-tag-terminator-chars supertag-inline-tag-boundary-char-regexp supertag-inline-tag-boundary-regexp supertag-inline-tag-regexp)) (set s \"sentinel\"))\n  (tp-provider)\n  (princ \"TP-ENTRY reload\\n\")\n  (let* ((vars '(supertag-inline-tag-terminator-chars supertag-inline-tag-boundary-char-regexp supertag-inline-tag-boundary-regexp supertag-inline-tag-regexp))\n         (values (mapcar #'symbol-value vars)) (cell (symbol-function 'supertag-transform-extract-inline-tags)))\n    (should-not (member \"sentinel\" values))\n    (tp-provider) (should (eq cell (symbol-function 'supertag-transform-extract-inline-tags)))\n    (cl-mapc (lambda (s v) (should (eq (symbol-value s) v))) vars values)\n    (dolist (s vars) (set s \"mutated\"))\n    (load (expand-file-name (if (tp-before) \"supertag-core-transform.el\" \"supertag-tag.el\") (getenv \"TP_TREE\")) nil nil t)\n    (should-not (eq cell (symbol-function 'supertag-transform-extract-inline-tags)))\n    (should (equal values (mapcar #'symbol-value vars)))\n    (should (equal '(\"again\") (supertag-transform-extract-inline-tags \"#again\")))\n    (unless (tp-before)\n      (should-not supertag-view-style-auto-enable)\n      (should-not supertag-svg-tag-enable)\n      (should (= 1 (cl-count #'supertag-view-helper--auto-enable org-mode-hook)))))\n  (tp-no-sync))\n(defun tp-sync ()\n  (should-not (featurep 'supertag-services-sync))\n  (should-not (featurep 'supertag-tag))\n  (require 'supertag-services-sync)\n  (princ \"TP-ENTRY sync\\n\")\n  (let* ((file (expand-file-name \"sync.org\" user-emacs-directory))\n         (text \":PROPERTIES:\\n:ID: file-node\\n:END:\\n#+FILETAGS: :filetag:\\n* Title #head\\n:PROPERTIES:\\n:ID: actual-node\\n:END:\\n#body [[id:other][#hidden]] =#code=\\n\")\n         (calls nil) (header nil)\n         (header-advice (lambda (original &rest args) (setq header (apply original args))))\n         (advice (lambda (begin end &rest _) (push (list begin end (buffer-substring-no-properties begin end)) calls))))\n    (write-region text nil file nil 'silent)\n    (supertag--ensure-store)\n    (dolist (id '(\"head\" \"body\" \"filetag\")) (puthash id (list :id id :name id :type :tag) (supertag-store-get-collection :tags)))\n    (let ((facts (prin1-to-string supertag--store)))\n      (advice-add 'supertag-transform-inline-tag-matches-in-region :before advice)\n      (advice-add 'supertag-sync--parse-file-header :around header-advice)\n      (unwind-protect\n          (let* ((nodes (supertag--parse-org-nodes file)) (node (car nodes)))\n            (princ (format \"TP-SYNC-ACTUAL nodes=%S calls=%S\\n\" nodes calls))\n            (should (= 1 (length nodes)))\n            (should (equal \"actual-node\" (plist-get node :id)))\n            (should (equal \"file-node\" (plist-get node :parent-id)))\n            (should (equal \"file-node\" (plist-get header :id)))\n            (should (equal '(\"filetag\") (plist-get header :file-tags)))\n            (should (equal '(\"body\" \"head\") (sort (copy-sequence (plist-get node :tags)) #'string<)))\n            (should (cl-some (lambda (row) (string-match-p \"#head\" (caddr row))) calls))\n            (should (cl-some (lambda (row) (string-match-p \"#body\" (caddr row))) calls))\n            (should (equal text (tp-disk file)))\n            (should (equal facts (prin1-to-string supertag--store)))\n            (setq calls nil)\n            (write-region \"\" nil file nil 'silent)\n            (should-not (supertag--parse-org-nodes file))\n            (princ (format \"TP-EMPTY-ACTUAL calls=%S\\n\" calls))\n            (should-not calls))\n        (advice-remove 'supertag-transform-inline-tag-matches-in-region advice)\n        (advice-remove 'supertag-sync--parse-file-header header-advice)))))\n(defun tp-compiled ()\n  (require 'bytecomp)\n  (let* ((tree (getenv \"TP_TREE\")) (tmp (getenv \"TP_TMP\"))\n         (provider (if (tp-before) \"supertag-core-transform.el\" \"supertag-tag.el\"))\n         (caller (expand-file-name \"tp-caller.el\" tree)) (runner (expand-file-name \"runtime.el\" tmp))\n         (mods (list provider \"tp-caller.el\")))\n    (with-temp-file caller\n      (insert \";;; -*- lexical-binding: t; -*-\\n\" (format \"(require '%s)\\n\" (if (tp-before) 'supertag-core-transform 'supertag-tag))\n              \"(defun tp-compiled-call ()\\n (when (featurep 'supertag-services-sync) (error \\\"preheated Sync\\\"))\\n (unless (equal '(\\\"a\\\" \\\"b\\\") (supertag-transform-extract-inline-tags \\\"#a #b\\\")) (error \\\"lexical\\\"))\\n (with-temp-buffer (org-mode) (insert \\\"#yes [[id:n][#hidden]]\\\") (unless (equal '(\\\"yes\\\") (mapcar #'caddr (supertag-transform-inline-tag-matches-in-region (point-min) (point-max)))) (error \\\"objects\\\")))\\n (require 'supertag-services-sync)\\n (let ((file (expand-file-name \\\"compiled.org\\\" user-emacs-directory)))\\n (write-region \\\"* H #tag\\\\n:PROPERTIES:\\\\n:ID: compiled-node\\\\n:END:\\\\n\\\" nil file nil 'silent)\\n (unless (equal \\\"compiled-node\\\" (plist-get (car (supertag--parse-org-nodes file)) :id)) (error \\\"Sync\\\"))) :ok)\\n\"))\n    (dolist (n mods) (should (byte-compile-file (expand-file-name n tree))))\n    (with-temp-file runner\n      (insert (format \"(setq user-emacs-directory %S default-directory %S after-init-time nil supertag-view-style-auto-enable nil supertag-svg-tag-enable nil supertag-sync-directories nil org-id-locations-file %S org-id-track-globally nil)\\n\" tmp tmp (expand-file-name \"ids\" tmp)))\n      (insert \"(unwind-protect (progn\\n\")\n      (dolist (n mods) (insert (format \"(load %S nil nil t)\\n\" (concat (expand-file-name n tree) \"c\"))))\n      (insert \"(unless (eq :ok (tp-compiled-call)) (error \\\"result\\\")))\\n(setq kill-emacs-hook nil emacs-startup-hook nil org-mode-hook nil enable-theme-functions nil)\\n(mapc #'cancel-timer (append timer-list timer-idle-list)))\\n(princ \\\"TP-COMPILED-DONE\\\\n\\\")\\n\"))\n    (princ \"TP-ENTRY compiled\\n\")\n    (with-temp-buffer\n      (let ((status (call-process (or (getenv \"EMACS_BIN\") (expand-file-name invocation-name invocation-directory)) nil t nil \"-Q\" \"--batch\" \"-L\" tree \"-l\" runner)))\n        (when-let* ((evidence (getenv \"SUPERTAG_TP_EVIDENCE\")))\n          (let ((out (expand-file-name \"compiled/artifacts/\" evidence)))\n            (make-directory out t)\n            (dolist (n mods) (dolist (suffix '(\"\" \"c\")) (copy-file (concat (expand-file-name n tree) suffix) (concat (expand-file-name n out) suffix) t)))\n            (copy-file runner (expand-file-name \"runtime.el\" out) t)\n            (write-region (point-min) (point-max) (expand-file-name \"runtime.log\" out) nil 'silent)))\n        (princ (buffer-string)) (should (= 0 status)) (should (string-match-p \"TP-COMPILED-DONE\" (buffer-string)))))))\n(unwind-protect\n    (progn\n      (when (getenv \"TP_BOUNDARY_MUTANT\")\n        (let ((file (expand-file-name (if (tp-before) \"supertag-core-transform.el\" \"supertag-tag.el\") (getenv \"TP_TREE\"))))\n          (with-temp-buffer\n            (insert-file-contents file) (goto-char (point-min))\n            (unless (search-forward \"(concat supertag-inline-tag-boundary-regexp\\n\" nil t) (error \"mutation site missing\"))\n            (replace-match \"(concat \\\"\\\"\\n\" t t) (write-region (point-min) (point-max) file nil 'silent))))\n      (pcase (getenv \"TP_CASE\")\n        (\"lexical\" (tp-lexical)) (\"objects\" (tp-objects)) (\"entry\" (tp-entry))\n        (\"node\" (tp-cold-container 'supertag-node)) (\"persistence\" (tp-cold-container 'supertag-core-persistence))\n        (\"reload\" (tp-reload)) (\"sync\" (tp-sync)) (\"compiled\" (tp-compiled)))\n      (princ (format \"TP-DONE %s\\n\" (getenv \"TP_CASE\"))))\n  (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)\n  (mapc #'cancel-timer (append timer-list timer-idle-list)))\n")

(defun supertag-path-test--tp-child (case)
  "Run CASE against real source in an isolated fresh child process."
  (let* ((tmp (make-temp-file "supertag-tp-" t))
         (tree (expand-file-name "tree/" tmp))
         (source (or (getenv "SUPERTAG_TP_ROOT") supertag-path-test--source-root))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (process-environment (copy-sequence process-environment))
         (default-directory tmp) (evidence (getenv "SUPERTAG_TP_EVIDENCE")))
    (unwind-protect
        (progn
          (make-directory tree)
          (dolist (f (directory-files source t "\\.el\\'")) (copy-file f (expand-file-name (file-name-nondirectory f) tree)))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (setenv "TP_TREE" tree) (setenv "TP_TMP" tmp) (setenv "TP_CASE" case)
          (let ((script (expand-file-name "child.el" tmp)))
            (with-temp-file script (insert supertag-path-test--tp-program))
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
                (should (string-match-p (format "TP-ENTRY %s" case) (buffer-string)))
                (should (string-match-p (format "TP-DONE %s" case) (buffer-string)))))))
      (delete-directory tmp t))))

(ert-deftest supertag-path-tp-lexical () (supertag-path-test--tp-child "lexical"))

(ert-deftest supertag-path-tp-objects () (supertag-path-test--tp-child "objects"))

(ert-deftest supertag-path-tp-entry () (supertag-path-test--tp-child "entry"))

(ert-deftest supertag-path-tp-node () (supertag-path-test--tp-child "node"))

(ert-deftest supertag-path-tp-persistence () (supertag-path-test--tp-child "persistence"))

(ert-deftest supertag-path-tp-reload () (supertag-path-test--tp-child "reload"))

(ert-deftest supertag-path-tp-sync () (supertag-path-test--tp-child "sync"))

(ert-deftest supertag-path-tp-compiled () (supertag-path-test--tp-child "compiled"))

;;; V2-ORG-A: independent source/compiled loading and shared writer controls.
(defconst supertag-path-test--orga-root
  (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))
(defconst supertag-path-test--orga-program ";;; -*- lexical-binding: t; -*-\n(require 'ert)\n(require 'cl-lib)\n(require 'subr-x)\n(setq user-emacs-directory (file-name-as-directory (getenv \"OA_TMP\"))\n      default-directory user-emacs-directory after-init-time nil\n      supertag-data-directory (expand-file-name \"data/\" user-emacs-directory)\n      supertag--base-data-directory supertag-data-directory\n      supertag-db-file (expand-file-name \"store.el\" supertag-data-directory)\n      supertag-db-backup-directory (expand-file-name \"backups/\" supertag-data-directory)\n      supertag-sync-state-file (expand-file-name \"sync.el\" user-emacs-directory)\n      supertag-sync--state-source supertag-sync-state-file\n      supertag-sync-directories (list user-emacs-directory)\n      supertag-active-sync-directory user-emacs-directory\n      supertag-file-id-source 'org-roam\n      org-id-locations-file (expand-file-name \"ids\" user-emacs-directory)\n      org-id-track-globally nil make-backup-files nil auto-save-default nil\n      supertag-view-style-auto-enable nil supertag-svg-tag-enable nil)\n(defun oa-before () (equal (getenv \"SUPERTAG_ORGA_STAGE\") \"before\"))\n(defun oa-file () (expand-file-name \"nodes.org\" user-emacs-directory))\n(defun oa-disk (file) (with-temp-buffer (insert-file-contents-literally file) (buffer-string)))\n(defun oa-sync-ready ()\n  (should (featurep 'supertag-services-sync))\n  (should (boundp 'supertag-sync--is-full-rescan-p))\n  (should (equal \"supertag-services-sync\" (file-name-base (symbol-file 'supertag-node-sync-current-buffer)))))\n(defun oa-load-org ()\n  (if (string-prefix-p \"elc-\" (getenv \"OA_CASE\"))\n      (progn\n        (load (expand-file-name \"supertag-service-org.elc\" (getenv \"OA_TREE\")) nil t t)\n        (should (string-suffix-p \".elc\" (symbol-file 'supertag-service-org--update-buffer-and-resync))))\n    (require 'supertag-service-org)))\n(defun oa-prepare ()\n  (require 'supertag-services-sync)\n  (supertag--ensure-store)\n  (supertag-tag-create '(:id \"base\" :name \"base\" :aliases (\"alias-base\")))\n  (with-temp-file (oa-file)\n    (insert \":PROPERTIES:\\n:ID: file-node\\n:END:\\n#+FILETAGS: :base:\\n* Alpha #base\\n:PROPERTIES:\\n:ID: oa-a\\n:AUTHOR: Ada\\n:END:\\nText.\\n* Beta #base\\n:PROPERTIES:\\n:ID: oa-b\\n:END:\\nOther.\\n\"))\n  (with-temp-file (expand-file-name \"plain.org\" user-emacs-directory) (insert \"* Plain\\nBody.\\n\"))\n  (should (eq 'complete (plist-get (supertag-reindex-org) :status)))\n  (dolist (id '(\"file-node\" \"oa-a\" \"oa-b\")) (should (supertag-node-get id)))\n  (with-temp-file (expand-file-name \"seed.el\" user-emacs-directory)\n    (let ((print-circle t) (print-length nil) (print-level nil)) (prin1 supertag--store (current-buffer))))\n  (princ \"ORGA-PREPARE real-reindex-three-nodes\\n\"))\n(defun oa-entry ()\n  (should-not (boundp 'supertag-sync--is-full-rescan-p))\n  (when (getenv \"OA_PRESET_NIL\") (setq supertag-org-id-find-auto-enable nil))\n  (oa-load-org)\n  (princ \"ORGA-ENTRY actual-ServiceOrg\\n\")\n  (should-not (featurep 'supertag))\n  (dolist (feature '(supertag-node supertag-tag supertag-services-sync supertag-query))\n    (should (eq (and (oa-before) (not (getenv \"OA_ENTRY_RED\"))) (not (null (featurep feature))))))\n  (if (oa-before) (should (boundp 'supertag-sync--is-full-rescan-p))\n    (should-not (boundp 'supertag-sync--is-full-rescan-p))\n    (dolist (row '((supertag-node-get \"supertag-node\") (supertag-node-delete \"supertag-node\")\n                   (supertag-service-org-follow-id \"supertag-node\")\n                   (supertag--mark-internal-modification \"supertag-services-sync\")\n                   (supertag--clear-internal-modification \"supertag-services-sync\")\n                   (supertag--render-org-headline \"supertag-services-sync\")\n                   (supertag-node-sync-current-buffer \"supertag-services-sync\")))\n      (let ((cell (symbol-function (car row))))\n        (should (autoloadp cell)) (should (equal (cadr cell) (cadr row))) (should-not (nth 4 cell)))))\n  (princ (format \"ORGA-ORG-ID-host=%S preset=%S\\n\" (fboundp 'org-id-find) supertag-org-id-find-auto-enable))\n  (should (fboundp 'org-id-find))\n  (should (eq (not (null supertag-org-id-find-auto-enable))\n              (not (null (advice-member-p #'supertag-service-org--org-id-find-advice 'org-id-find)))))\n  (supertag-enable-org-id-find-integration)\n  (should supertag-org-id-find-auto-enable)\n  (setq supertag--initialized t)\n  (let ((marker (org-id-find \"oa-a\" 'marker)))\n    (should (markerp marker))\n    (should (equal (buffer-file-name (marker-buffer marker)) (oa-file)))\n    (with-current-buffer (marker-buffer marker)\n      (save-excursion (goto-char marker) (should (equal \"oa-a\" (org-entry-get nil \"ID\"))))))\n  (supertag-disable-org-id-find-integration)\n  (should-not supertag-org-id-find-auto-enable)\n  (should-not (advice-member-p #'supertag-service-org--org-id-find-advice 'org-id-find))\n  ;; Real native advice on an existing service, no fabricated Org host.\n  (let ((calls 0))\n    (let ((watch (lambda (&rest _) (cl-incf calls))))\n      (advice-add 'supertag-service-org--with-node-buffer :before watch)\n      (unwind-protect\n          (let ((cell (symbol-function 'supertag-service-org--with-node-buffer)))\n            (require 'supertag-service-org)\n            (should (eq cell (symbol-function 'supertag-service-org--with-node-buffer)))\n            (supertag-service-org--with-node-buffer \"oa-a\" (lambda () (oa-sync-ready)))\n            (should (= calls 1)))\n        (advice-remove 'supertag-service-org--with-node-buffer watch)))))\n\n(defun oa-wrapper ()\n  (oa-load-org)\n  (let ((sync-before (featurep 'supertag-services-sync))\n        (facts (prin1-to-string supertag--store)) (disk (oa-disk (oa-file))) called)\n    (dolist (row '((\"absent\" nil) (\"no-file\" (:id \"no-file\" :level 1 :file \"/nonexistent/orga-source\"))\n                   (\"bad-location\" (:id \"bad-location\" :level 1))))\n      (when (cadr row)\n        (let ((node (copy-tree (cadr row))))\n          (unless (plist-get node :file) (setq node (plist-put node :file (oa-file))))\n          (puthash (car row) node (gethash :nodes supertag--store)))))\n    (dolist (id '(\"absent\" \"no-file\" \"bad-location\"))\n      (should-error (supertag-service-org--with-node-buffer id (lambda () (setq called t))) :type 'user-error))\n    (should-not called) (should (eq sync-before (featurep 'supertag-services-sync)))\n    (remhash \"no-file\" (gethash :nodes supertag--store)) (remhash \"bad-location\" (gethash :nodes supertag--store))\n    (supertag-service-org--with-node-buffer \"oa-a\"\n      (lambda ()\n        (princ \"ORGA-WRAPPER-CALLBACK no-parser\\n\") (oa-sync-ready)\n        (should-not supertag-sync--is-full-rescan-p)\n        (should (equal \"oa-a\" (org-entry-get nil \"ID\"))) (setq called (point))))\n    (should (integerp called))\n    (let ((value (supertag-service-org--with-node-buffer \"file-node\" (lambda () (point)))))\n      (princ (format \"ORGA-ACTUAL file-position=%s\\n\" value))\n      (should (= value (if (getenv \"OA_OUTPUT_RED\") 999 1))))\n    (should (equal facts (prin1-to-string supertag--store))) (should (equal disk (oa-disk (oa-file))))))\n(defun oa-repair (dirty)\n  (should-not (boundp 'supertag-sync--is-full-rescan-p))\n  ;; Separate preset cases; the four default cases never initialize this flag.\n  (when (string-suffix-p \"preset\" (getenv \"OA_CASE\"))\n    (set 'supertag-sync--is-full-rescan-p 'preset))\n  (oa-load-org)\n  (princ (format \"ORGA-ENTRY repair dirty=%S provider=%s\\n\" dirty (symbol-file 'supertag-service-org--update-buffer-and-resync)))\n  (let ((file (oa-file)) (save-count 0) (project-count 0) (sync-flags nil) (editor-flags nil))\n    (with-current-buffer (find-file-noselect file)\n      (when dirty (goto-char (point-max)) (insert \"Unsaved draft.\\n\")))\n    (let ((watch-save (lambda (&rest _) (when (equal (buffer-file-name) file) (cl-incf save-count))))\n          (watch-project (lambda (&rest _)\n                           (oa-sync-ready) (push supertag-sync--is-full-rescan-p sync-flags)\n                           (cl-incf project-count))))\n      (advice-add 'save-buffer :before watch-save)\n      (advice-add 'supertag-service-org--project-current-node :before watch-project)\n      (unwind-protect\n          (supertag-service-org--update-buffer-and-resync\n           \"oa-a\" (lambda ()\n                     (princ \"ORGA-REPAIR-EDITOR before-let\\n\") (oa-sync-ready)\n                     (push supertag-sync--is-full-rescan-p editor-flags)) t)\n        (advice-remove 'save-buffer watch-save)\n        (advice-remove 'supertag-service-org--project-current-node watch-project)))\n    (should (equal editor-flags\n                   (list (and (string-suffix-p \"preset\" (getenv \"OA_CASE\")) 'preset))))\n    (should (equal sync-flags '(t)))\n    (should (= project-count 1)) (should (= save-count (if dirty 1 0)))\n    (should (boundp 'supertag-sync--is-full-rescan-p))\n    (should (eq supertag-sync--is-full-rescan-p\n                (and (string-suffix-p \"preset\" (getenv \"OA_CASE\")) 'preset)))\n    ;; A subsequent actual parser/reconcile read observes the outer binding.\n    (with-current-buffer (find-file-noselect file)\n      (goto-char (point-min)) (search-forward \":ID: oa-a\") (org-back-to-heading t)\n      (supertag-node-sync-at-point)\n      (should (equal \"Ada\" (plist-get (plist-get (supertag-node-get \"oa-a\") :properties) :AUTHOR)))\n      (should-not (buffer-modified-p)))\n    (should (eq dirty (not (null (string-match-p \"Unsaved draft\" (oa-disk file))))))))\n(defun oa-tags ()\n  (require 'supertag-tag)\n  (unless (oa-before) (should-not (featurep 'supertag-services-sync)))\n  (let ((file (oa-file)))\n    (dolist (id '(\"oa-a\" \"file-node\"))\n      (supertag-service-org-add-tag id \"base\")\n      (oa-sync-ready)\n      (supertag-service-org-remove-tag id \"base\")\n      (supertag-service-org-add-tag id \"base\"))\n    (supertag-tag-create '(:id \"other\" :name \"other\"))\n    (supertag-service-org-replace-tag \"oa-b\" \"base\" \"other\")\n    (should (member \"other\" (plist-get (supertag-node-get \"oa-b\") :tags)))\n    (should (string-match-p \"#other\" (oa-disk file)))\n    (let* ((disk (oa-disk file)) (store (prin1-to-string supertag--store))\n           (rows (supertag-tag-change--collect \"other\")))\n      (should rows) (should (equal disk (oa-disk file))) (should (equal store (prin1-to-string supertag--store))))))\n(defun oa-bulk ()\n  (require 'supertag-tag)\n  (should-not (featurep 'supertag-services-sync))\n  (let ((file (oa-file)) (saves 0) (records 0) (mutations 0) (parses 0) (resolved nil) new-id)\n    (let ((watch-create (lambda (&rest _)\n                          (princ \"ORGA-BULK-MUTATION before-tag-create\\n\")\n                          (oa-sync-ready) (should resolved) (cl-incf mutations)))\n          (watch-save (lambda (&rest _) (when (equal (buffer-file-name) file) (cl-incf saves)))))\n      (advice-add 'supertag-tag-create :before watch-create)\n      (advice-add 'save-buffer :before watch-save)\n      ;; Transparent loader advice observes real completion, not fboundp.\n      (cl-letf* ((original-load (symbol-function 'autoload-do-load))\n                 ((symbol-function 'autoload-do-load)\n                  (lambda (definition &rest rest)\n                    (prog1 (apply original-load definition rest)\n                      (when (and (featurep 'supertag-services-sync) (not resolved))\n                        (setq resolved t)\n                        (should (= parses 0)))))))\n        (let ((watch-record (lambda (&rest _) (cl-incf records)))\n              (watch-parse (lambda (&rest _) (cl-incf parses))))\n          (advice-add 'supertag-service-org-save-and-record-tags-at-point :before watch-record)\n          (advice-add 'supertag-sync--parse-file-header :before watch-parse)\n          (unwind-protect\n              (let ((ids (supertag-capture-add-tags-to-nodes '(\"oa-a\" \"oa-b\") '(\"alias-base\" \"new/path\"))))\n                (should (equal (car ids) \"base\"))\n                (setq new-id (cadr ids))\n                (should (supertag-tag-stable-id-p new-id))\n                (should (equal \"path\" (plist-get (supertag-tag-get new-id) :name)))\n                (should (equal (list (supertag-tag-resolve-occurrence \"new\"))\n                               (supertag-tag-parents new-id))))\n            (advice-remove 'supertag-service-org-save-and-record-tags-at-point watch-record)\n            (advice-remove 'supertag-sync--parse-file-header watch-parse)\n            (advice-remove 'supertag-tag-create watch-create)\n            (advice-remove 'save-buffer watch-save)))))\n    (should resolved) (should (= mutations 2)) (should (= saves 2)) (should (= records 2))\n    (dolist (id '(\"oa-a\" \"oa-b\")) (should (member new-id (plist-get (supertag-node-get id) :tags))))\n    (should (string-match-p \"#path\" (oa-disk file)))\n    (should-not (string-match-p \"#new/path\" (oa-disk file)))))\n(defun oa-load-failure (bypass)\n  (let ((disk (oa-disk (oa-file))) (facts (prin1-to-string supertag--store)))\n    (if (oa-before)\n        (progn (should (equal '(error \"ORGA injected Sync load failure\")\n                               (should-error (oa-load-org) :type 'error)))\n               (should-not (featurep 'supertag-service-org))\n               (princ \"ORGA-FAILURE before-require\\n\"))\n      (oa-load-org) (princ \"ORGA-ENTRY failure-current\\n\")\n      (if bypass\n          (let ((file (expand-file-name \"plain.org\" user-emacs-directory)))\n            (with-current-buffer (find-file-noselect file)\n              (goto-char (point-min))\n              (should (equal '(error \"ORGA injected Sync load failure\")\n                             (should-error (supertag-service-org-create-node-at-point) :type 'error)))\n              (let ((id (org-entry-get nil \"ID\")))\n                (should (stringp id)) (should-not (supertag-node-get id)))\n              (should (buffer-modified-p))\n              (should-not (string-match-p \":ID:\" (oa-disk file)))\n              (princ \"ORGA-FAILURE bypass-retained-ID-draft\\n\")))\n        (let (called)\n          (should-error (supertag-service-org--with-node-buffer \"missing\" (lambda () (setq called t))) :type 'user-error)\n          (should (equal '(error \"ORGA injected Sync load failure\")\n                         (should-error (supertag-service-org--with-node-buffer \"oa-a\" (lambda () (setq called t))) :type 'error)))\n          (should-not called) (princ \"ORGA-FAILURE current-after-valid-location\\n\"))))\n    (should (equal disk (oa-disk (oa-file)))) (should (equal facts (prin1-to-string supertag--store)))) )\n(defun oa-migrate ()\n  (should-not (featurep 'supertag-tag))\n  (require 'supertag-migrate)\n  (princ \"ORGA-ENTRY migrate\\n\")\n  ;; Direct fixture facts, no Tag creation before the first real status read.\n  (puthash \"bad id\" '(:id \"bad id\" :name \"Unstable\") (gethash :tags supertag--store))\n  (puthash \"tag-00000000000000000000000000000000\"\n           '(:id \"tag-00000000000000000000000000000000\" :name \"Stable\") (gethash :tags supertag--store))\n  (puthash \"conflict-tag\" '(:id \"conflict-tag\" :name \"different\" :aliases (\"new/conflict\")) (gethash :tags supertag--store))\n  (let ((pending (make-hash-table :test 'equal)))\n    (puthash \"base\" '(:path \"new/path\") pending)\n    (puthash :legacy-extends pending supertag--store))\n  (let* ((facts (prin1-to-string supertag--store)) (disk (oa-disk (oa-file)))\n         (status (supertag-migrate-status)) (plan (supertag-migrate--extends-plan)))\n    (princ (format \"ORGA-MIGRATE-ACTUAL unstable=%S plan=%S\\n\" (plist-get status :unstable-tags) plan))\n    (should (member \"bad id\" (plist-get status :unstable-tags)))\n    (should (member \"base\" (plist-get status :unstable-tags)))\n    (should-not (member \"tag-00000000000000000000000000000000\" (plist-get status :unstable-tags)))\n    (should (equal \"new/path\" (plist-get (car plan) :path)))\n    (should-not (plist-get (car plan) :conflict))\n    (supertag-migrate-preview)\n    (with-current-buffer \"*Supertag Field Migration*\"\n      (should (string-match-p \"new/path\" (buffer-string))))\n    (puthash \"base\" '(:path \"new/conflict\") (gethash :legacy-extends supertag--store))\n    (should (equal \"Path resolves to a different canonical name\"\n                   (plist-get (car (supertag-migrate--extends-plan)) :conflict)))\n    (puthash \"base\" '(:path \"new/path\") (gethash :legacy-extends supertag--store))\n    (should (equal facts (prin1-to-string supertag--store)))\n    (should (equal disk (oa-disk (oa-file))))))\n(let ((case (getenv \"OA_CASE\")))\n  (unwind-protect\n      (progn\n        (unless (member case '(\"prepare\" \"compile\"))\n          (setq supertag--store (with-temp-buffer\n                                 (insert-file-contents (expand-file-name \"seed.el\" user-emacs-directory))\n                                 (read (current-buffer)))))\n        (princ (format \"ORGA-CASE %s\\n\" case))\n        (pcase case\n          (\"prepare\" (oa-prepare))\n          (\"compile\" (require 'bytecomp)\n           (should (byte-compile-file (expand-file-name \"supertag-service-org.el\" (getenv \"OA_TREE\"))))\n           (should (file-exists-p (expand-file-name \"supertag-service-org.elc\" (getenv \"OA_TREE\")))))\n          (\"entry\" (oa-entry)) (\"entry-preset\" (setenv \"OA_PRESET_NIL\" \"1\") (oa-entry))\n          (\"wrapper\" (oa-wrapper))\n          ((or \"repair-clean\" \"elc-clean\" \"repair-preset\" \"elc-preset\") (oa-repair nil))\n          ((or \"repair-dirty\" \"elc-dirty\") (oa-repair t))\n          (\"tags\" (oa-tags)) (\"bulk\" (oa-bulk))\n          (\"load-failure\" (oa-load-failure nil)) (\"bypass-failure\" (oa-load-failure t))\n          (\"migrate\" (oa-migrate))\n          (_ (error \"Unknown case %s\" case)))\n        (princ (format \"ORGA-DONE %s\\n\" case)))\n    (setq kill-emacs-hook nil emacs-startup-hook nil after-init-hook nil\n          org-mode-hook nil enable-theme-functions nil disable-theme-functions nil)\n    (dolist (timer (append timer-list timer-idle-list)) (when (timerp timer) (cancel-timer timer)))))\n")
(defun supertag-path-test--orga-child (case)
  "Execute CASE in a fresh isolated process after separate real projection."
  (let* ((tmp (make-temp-file "supertag-orga-" t))
         (tree (expand-file-name "tree/" tmp))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (process-environment (copy-sequence process-environment))
         (default-directory tmp) (evidence (getenv "SUPERTAG_ORGA_EVIDENCE"))
         (script (expand-file-name "child.el" tmp)))
    (unwind-protect
        (progn
          (make-directory tree)
          (dolist (f (directory-files supertag-path-test--orga-root t "\\.el\\'"))
            (copy-file f (expand-file-name (file-name-nondirectory f) tree)))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (setenv "OA_TMP" tmp) (setenv "OA_TREE" tree)
          (with-temp-file script (insert supertag-path-test--orga-program))
          (cl-labels ((run (phase)
                        (setenv "OA_CASE" phase)
                        (with-temp-buffer
                          (let ((status (apply #'call-process program nil t nil
                                               (append '("-Q" "--batch")
                                                       (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                                       (list "-L" tree "-l" script)))))
                            (when evidence
                              (let ((out (expand-file-name (concat case "/") evidence)))
                                (make-directory out t)
                                (copy-file script (expand-file-name "child.el" out) t)
                                (write-region (point-min) (point-max) (expand-file-name (concat phase ".log") out) nil 'silent)
                                (with-temp-file (expand-file-name (concat phase ".exit") out) (insert (format "%s\n" status)))
                                (when (equal phase "compile")
                                  (dolist (suffix '(".el" ".elc"))
                                    (let ((f (expand-file-name (concat "supertag-service-org" suffix) tree)))
                                      (when (file-exists-p f) (copy-file f (expand-file-name (file-name-nondirectory f) out) t)))))))
                            (princ (buffer-string))
                            (should (equal 0 status))
                            (should (string-match-p (format "ORGA-DONE %s" phase) (buffer-string)))))))
            (run "prepare")
            ;; Test-only copied-provider failure/omission; never modify main.
            (when (member case '("load-failure" "bypass-failure"))
              (let ((f (expand-file-name "supertag-services-sync.el" tree)))
                (with-temp-buffer
                  (insert-file-contents f) (goto-char (point-min)) (forward-line 1)
                  (insert "(error \"ORGA injected Sync load failure\")\n")
                  (write-region (point-min) (point-max) f nil 'silent))))
            (when (getenv "OA_OMIT")
              (let* ((kind (getenv "OA_OMIT"))
                     (name (pcase kind ("wrapper" "supertag-service-org.el") ("bulk" "supertag-tag.el") ("migrate" "supertag-migrate.el")))
                     (needle (pcase kind
                               ("wrapper" "            ;; Resolve Sync before the callback can edit or bind rescan state.\n            (let ((definition\n                   (symbol-function 'supertag-node-sync-current-buffer)))\n              (when (autoloadp definition)\n                (autoload-do-load definition 'supertag-node-sync-current-buffer)))\n")
                               ("bulk" "        ;; Complete Sync loading before mutation or saver capture.\n        (let ((definition (symbol-function 'supertag-sync--parse-file-header)))\n          (when (autoloadp definition)\n            (autoload-do-load definition 'supertag-sync--parse-file-header)))\n")
                               ("migrate" "(require 'supertag-tag)\n")))
                     (f (expand-file-name name tree)))
                (with-temp-buffer
                  (insert-file-contents f) (goto-char (point-min))
                  (should (search-forward needle nil t))
                  (replace-match "" t t)
                  (should-not (search-forward needle nil t))
                  (write-region (point-min) (point-max) f nil 'silent))))
            (when (string-prefix-p "elc-" case) (run "compile"))
            (run case)))
      (delete-directory tmp t))))

(ert-deftest supertag-path-orga-entry ()
  (supertag-path-test--orga-child "entry"))

(ert-deftest supertag-path-orga-entry-preset ()
  (supertag-path-test--orga-child "entry-preset"))

(ert-deftest supertag-path-orga-wrapper ()
  (supertag-path-test--orga-child "wrapper"))

(ert-deftest supertag-path-orga-repair-clean ()
  (supertag-path-test--orga-child "repair-clean"))

(ert-deftest supertag-path-orga-repair-dirty ()
  (supertag-path-test--orga-child "repair-dirty"))

(ert-deftest supertag-path-orga-elc-clean ()
  (supertag-path-test--orga-child "elc-clean"))

(ert-deftest supertag-path-orga-elc-dirty ()
  (supertag-path-test--orga-child "elc-dirty"))

(ert-deftest supertag-path-orga-repair-preset ()
  (supertag-path-test--orga-child "repair-preset"))

(ert-deftest supertag-path-orga-elc-preset ()
  (supertag-path-test--orga-child "elc-preset"))

(ert-deftest supertag-path-orga-tags ()
  (supertag-path-test--orga-child "tags"))

(ert-deftest supertag-path-orga-bulk ()
  (supertag-path-test--orga-child "bulk"))

(ert-deftest supertag-path-orga-load-failure ()
  (supertag-path-test--orga-child "load-failure"))

(ert-deftest supertag-path-orga-bypass-failure ()
  (supertag-path-test--orga-child "bypass-failure"))

;;; ORG-A R1: direct timestamp helper before any wrapper or Org-mode use.
(defconst supertag-path-test--orga-r1-root
  (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))
(defconst supertag-path-test--orga-r1-program ";;; -*- lexical-binding: t; -*-\n(setq user-emacs-directory (file-name-as-directory (getenv \"ORGA_R1_HOME\"))\n      default-directory user-emacs-directory after-init-time nil\n      supertag-data-directory (expand-file-name \"data/\" user-emacs-directory)\n      supertag--base-data-directory supertag-data-directory\n      supertag-db-file (expand-file-name \"db.el\" supertag-data-directory)\n      supertag-db-backup-directory (expand-file-name \"backups/\" supertag-data-directory)\n      supertag-sync-state-file (expand-file-name \"sync.el\" user-emacs-directory)\n      supertag-sync--state-source supertag-sync-state-file\n      supertag-sync-directories (list user-emacs-directory)\n      supertag-active-sync-directory user-emacs-directory\n      supertag-file-id-source 'org-roam\n      org-id-locations-file (expand-file-name \"ids\" user-emacs-directory)\n      org-id-track-globally nil make-backup-files nil auto-save-default nil\n      supertag-view-style-auto-enable nil supertag-svg-tag-enable nil)\n(unwind-protect\n    (let* ((mode (getenv \"ORGA_R1_MODE\"))\n           (tree (getenv \"ORGA_R1_TREE\"))\n           (source (expand-file-name \"supertag-service-org.el\" tree))\n           (before (equal (getenv \"SUPERTAG_ORGA_R1_STAGE\") \"before\")))\n      (when (featurep 'org-element) (error \"R1 child unexpectedly preloaded OrgElement\"))\n      (dolist (feature '(supertag-service-org supertag-tag supertag-node supertag-query supertag-services-sync supertag))\n        (when (featurep feature) (error \"R1 child unexpectedly preloaded %s\" feature)))\n      (if (equal mode \"compile\")\n          (progn\n            (require 'bytecomp)\n            (unless (byte-compile-file source) (error \"R1 actual ServiceOrg compilation failed\"))\n            (unless (file-exists-p (concat source \"c\")) (error \"R1 actual elc missing\"))\n            (princ \"ORGA-R1-COMPILE-DONE actual-ServiceOrg\\n\"))\n        (load (if (equal mode \"elc\") (concat source \"c\") source) nil t t)\n        (let ((owner (symbol-file 'supertag-service-org--absolute-planning-timestamp-p)))\n          (princ (format \"ORGA-R1-ENTRY %s owner=%S OrgElement=%S parser=%S\\n\"\n                         mode owner (featurep 'org-element)\n                         (symbol-file 'org-element-timestamp-parser)))\n          (unless (equal owner (if (equal mode \"elc\") (concat source \"c\") source))\n            (error \"R1 wrong actual provider: %S\" owner)))\n        (dolist (feature '(supertag-node supertag-tag supertag-query supertag-services-sync))\n          (unless (eq (not (null (featurep feature))) before)\n            (error \"R1 %s loading changed: before=%S loaded=%S\" feature before (featurep feature))))\n        (when (or (featurep 'supertag)\n                  (and (boundp 'supertag--initialized) (symbol-value 'supertag--initialized)))\n          (error \"R1 unexpectedly initialized main\"))\n        ;; Call the actual unchanged helper directly: no Org mode or wrapper.\n        (let ((positive (supertag-service-org--absolute-planning-timestamp-p \"<2026-09-09 Wed>\"))\n              (invalid (supertag-service-org--absolute-planning-timestamp-p \"not-a-timestamp\"))\n              (range (supertag-service-org--absolute-planning-timestamp-p \"<2026-09-09 Wed>--<2026-09-10 Thu>\")))\n          (princ (format \"ORGA-R1-VALUES %s positive=%S invalid=%S range=%S\\n\" mode positive invalid range))\n          (unless (and (eq positive t) (null invalid) (null range))\n            (error \"R1 actual timestamp results changed\")))\n        (unless (featurep 'org-element) (error \"R1 OrgElement not actually loaded\"))\n        (unless before\n          (dolist (feature '(supertag-node supertag-tag supertag-query supertag-services-sync supertag))\n            (when (featurep feature) (error \"R1 pure parser loaded %s\" feature))))\n        (princ (format \"ORGA-R1-DONE %s\\n\" mode))))\n  (setq kill-emacs-hook nil emacs-startup-hook nil after-init-hook nil\n        org-mode-hook nil enable-theme-functions nil disable-theme-functions nil)\n  (dolist (timer (append timer-list timer-idle-list))\n    (when (timerp timer) (cancel-timer timer))))\n")
(ert-deftest supertag-path-orga-r1-cold-timestamp-source-and-elc ()
  "The direct timestamp helper works in fresh source and actual compiled entry."
  (let* ((tmp (make-temp-file "supertag-orga-r1-" t))
         (tree (expand-file-name "tree/" tmp))
         (home (expand-file-name "home/" tmp))
         (script (expand-file-name "child.el" tmp))
         (source-root (or (getenv "SUPERTAG_ORGA_R1_SOURCE") supertag-path-test--orga-r1-root))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (evidence (getenv "SUPERTAG_ORGA_R1_EVIDENCE"))
         (process-environment (copy-sequence process-environment))
         (default-directory tmp) outcomes)
    (unwind-protect
        (progn
          (make-directory tree) (make-directory home)
          (dolist (file (directory-files source-root t "\\.el\\'"))
            (copy-file file (expand-file-name (file-name-nondirectory file) tree)))
          (with-temp-file script (insert supertag-path-test--orga-r1-program))
          (setenv "HOME" home) (setenv "CFFIXED_USER_HOME" home)
          (setenv "ORGA_R1_HOME" home) (setenv "ORGA_R1_TREE" tree)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (cl-labels
              ((run (mode)
                 (setenv "ORGA_R1_MODE" mode)
                 (with-temp-buffer
                   (let ((status (apply #'call-process program nil t nil
                                        (append '("-Q" "--batch")
                                                (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                                (list "-L" tree "-l" script)))))
                     (when evidence
                       (make-directory evidence t)
                       (copy-file script (expand-file-name "child.el" evidence) t)
                       (write-region (point-min) (point-max) (expand-file-name (concat mode ".log") evidence) nil 'silent)
                       (with-temp-file (expand-file-name (concat mode ".exit") evidence) (insert (format "%s\n" status)))
                       (dolist (suffix '(".el" ".elc"))
                         (let ((f (expand-file-name (concat "supertag-service-org" suffix) tree)))
                           (when (file-exists-p f)
                             (copy-file f (expand-file-name (file-name-nondirectory f) evidence) t)))))
                     (princ (buffer-string))
                     (if (equal mode "compile")
                         (progn (should (equal 0 status))
                                (should (string-match-p "ORGA-R1-COMPILE-DONE actual-ServiceOrg" (buffer-string))))
                       ;; Run BOTH runtime variants even if the first one fails.
                       (push (list mode status
                                   (not (null (string-match-p (concat "ORGA-R1-ENTRY " mode) (buffer-string))))
                                   (not (null (string-match-p (concat "ORGA-R1-DONE " mode) (buffer-string))))) outcomes))))))
            (run "source") (run "compile") (run "elc"))
          (setq outcomes (nreverse outcomes))
          (princ (format "ORGA-R1-OUTCOMES %S\n" outcomes))
          (should (equal outcomes '(("source" 0 t t) ("elc" 0 t t)))))
      (delete-directory tmp t))))
