;;; node-identity-test.el --- Node identity boundary tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'document-fixture)
(require 'cl-lib)
(require 'org)

(when load-file-name
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)

(require 'supertag-service-org)
(require 'supertag-node)
(require 'supertag-link)
(if (equal (getenv "SUPERTAG_SYA_STAGE") "before")
      (require 'supertag-ui-commands)
    (require 'supertag-node))
(require 'supertag-tag)
(require 'supertag-automation)

(defconst node-identity-test--root
  (expand-file-name ".." (file-name-directory load-file-name))
  "Repository root used by source-boundary assertions.")

(defmacro node-identity-test--with-clean-env (&rest body)
  "Run BODY with an isolated Store and Org ID cache."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "supertag-node-identity-test" t))
          (supertag-data-directory tmp)
          (supertag-db-file (expand-file-name "supertag-db.el" tmp))
          (supertag-db-backup-directory (expand-file-name "backups" tmp))
          (supertag--store nil)
          (org-id-locations nil)
          (org-id-files nil)
          (org-id-locations-file (expand-file-name "org-id-locations" tmp)))
     (unwind-protect
         (progn
           (supertag--ensure-store)
           ,@body)
       (dolist (buffer (buffer-list))
         (when-let* ((file (buffer-file-name buffer)))
           (when (string-prefix-p tmp file)
             (kill-buffer buffer))))
       (ignore-errors (delete-directory tmp t)))))

(ert-deftest node-identity-capture-standalone-engine-is-retired ()
  "Normal loading does not define the standalone Capture engine or commands."
  (dolist (symbol '(supertag-capture-interactive-headline
                    supertag-capture-default-target-file
                    supertag-capture-read-target-file
                    supertag-capture-remember-target-file
                    supertag-capture-enrich-node
                    supertag-capture--get-from-static
                    supertag-capture--get-from-prompt
                    supertag-capture--get-from-clipboard
                    supertag-capture--get-from-region
                    supertag-capture--get-from-region-or-clipboard
                    supertag-capture--get-from-template-string
                    supertag-capture--get-from-function
                    supertag-capture--generate-get-spec
                    supertag-capture--get-from-static-grouped
                    supertag-capture--get-content
                    supertag-capture--parse-template-string
                    supertag-capture--normalize-tag-position
                    supertag-capture--process-spec
                    supertag-capture--select-headline-interactively
                    supertag-capture--resolve-target-location
                    supertag-capture--insert-node-into-buffer
                    supertag-services-sync-file
                    supertag-capture--reproject-existing-tag-occurrence
                    supertag-capture
                    supertag-capture-with-template))
    (ert-info ((format "Retired function: %s" symbol))
      (should-not (fboundp symbol)))))

(ert-deftest node-identity-capture-standalone-state-is-retired ()
  "Normal loading does not bind retired Capture configuration or state."
  (dolist (symbol '(supertag-capture-templates
                    supertag-capture-persist-last-target
                    supertag-capture-persisted-target-file
                    supertag-capture--session-target-file))
    (ert-info ((format "Retired variable: %s" symbol))
      (should-not (boundp symbol)))))

(ert-deftest node-identity-capture-surviving-services-remain-defined ()
  "Tag writers and opt-in org-capture integration remain available."
  (dolist (symbol '(supertag-capture--tag-membership-present-p
                    supertag-capture-add-tags-to-nodes
                    supertag-capture-add-tag-to-nodes
                    supertag-capture-replace-tag-on-node
                    supertag-capture--get-from-tags-prompt
                    supertag-capture-finalize-node-at-point
                    supertag-org-capture-after-finalize
                    supertag-enable-org-capture-integration
                    supertag-disable-org-capture-integration))
    (ert-info ((format "Surviving function: %s" symbol))
      (should (fboundp symbol)))))

(ert-deftest node-identity-org-capture-integration-is-disabled-by-default ()
  "Normal loading leaves org-capture integration opt-in."
  (should-not supertag-org-capture-auto-enable)
  (should-not (memq #'supertag-org-capture-after-finalize
                    org-capture-after-finalize-hook)))

(ert-deftest node-identity-org-capture-hook-registration-is-isolated ()
  "Enable and disable preserve other hooks and do not duplicate registration."
  (let ((supertag-org-capture-auto-enable nil)
        (org-capture-after-finalize-hook (list #'ignore)))
    (supertag-enable-org-capture-integration)
    (supertag-enable-org-capture-integration)
    (should supertag-org-capture-auto-enable)
    (should (= 1 (cl-count #'supertag-org-capture-after-finalize
                           org-capture-after-finalize-hook)))
    (should (memq #'ignore org-capture-after-finalize-hook))
    (supertag-disable-org-capture-integration)
    (supertag-disable-org-capture-integration)
    (should-not supertag-org-capture-auto-enable)
    (should (equal (list #'ignore) org-capture-after-finalize-hook))))

(ert-deftest node-identity-org-capture-opt-in-finalizes-real-entry ()
  "Real org-capture finalization persists and projects opt-in metadata."
  (dolist (property-key '(:property :field))
    (supertag-document-test-with-vault
      (let* ((target (expand-file-name "capture.org" tmp))
             (supertag-org-capture-auto-enable nil)
             (org-capture-after-finalize-hook nil)
             (org-capture-last-stored-marker (make-marker))
             (org-capture-plist nil)
             (org-capture-templates
              `(("s" "Supertag" entry (file ,target) "* Captured\nBody\n"
                 :supertag t
                 :supertag-template ((:tag "alpha" ,property-key "my:key"
                                      :value "value"))
                 :supertag-tags-prompt t)))
             prompt-count node-id)
        (with-temp-file target)
        (supertag-enable-org-capture-integration)
        (cl-letf (((symbol-function 'supertag-ui-read-tags)
                   (lambda (&rest _)
                     (setq prompt-count (1+ (or prompt-count 0)))
                     '("beta" "beta")))
                  ((symbol-function 'org-id-find)
                   (lambda (&rest _)
                     (ert-fail "org-capture integration consulted org-id-find"))))
          (unwind-protect
              (progn
                (org-capture nil "s")
                (should org-capture-mode)
                (org-capture-finalize))
            (when (bound-and-true-p org-capture-mode)
              (org-capture-kill)))
          (should (= 1 prompt-count))
          (should (markerp org-capture-last-stored-marker))
          (org-with-point-at org-capture-last-stored-marker
            (should (equal target (buffer-file-name)))
            (setq node-id (org-entry-get nil "ID"))
            (should (and (stringp node-id) (not (string-empty-p node-id))))
            (should (equal "value" (org-entry-get nil "MY_KEY")))
            (should (supertag-store-get-entity :nodes node-id))
            (should (supertag-node-location-find node-id))
            (should-not (buffer-modified-p)))
          (with-temp-buffer
            (insert-file-contents target)
            (org-mode)
            (goto-char (point-min))
            (should (equal node-id (org-entry-get nil "ID")))
            (should (equal "value" (org-entry-get nil "MY_KEY")))
            (dolist (tag '("alpha" "beta"))
              (should (= 2 (length (split-string
                                    (org-get-heading t t t t)
                                    (concat "#" tag)))))))
          (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
          (should (equal '("alpha" "beta")
                         (sort (mapcar (lambda (tag-id)
                                         (plist-get (supertag-tag-get tag-id) :name))
                                       (plist-get (supertag-node-get node-id) :tags))
                               #'string<))))))))

(ert-deftest node-identity-org-capture-without-opt-in-stays-ordinary ()
  "Real org-capture does not call Supertag finalization without :supertag."
  (supertag-document-test-with-vault
    (let* ((target (expand-file-name "ordinary-capture.org" tmp))
           (supertag-org-capture-auto-enable nil)
           (org-capture-after-finalize-hook nil)
           (org-capture-last-stored-marker (make-marker))
           (org-capture-plist nil)
           (org-capture-templates
            `(("o" "Ordinary" entry (file ,target) "* Ordinary capture\nBody\n")))
           (node-count (hash-table-count (supertag-store-get-collection :nodes))))
      (with-temp-file target)
      (supertag-enable-org-capture-integration)
      (cl-letf (((symbol-function 'supertag-capture-finalize-node-at-point)
                 (lambda (&rest _)
                   (ert-fail "Non-opt-in capture called Supertag finalization"))))
        (unwind-protect
            (progn
              (org-capture nil "o")
              (should org-capture-mode)
              (org-capture-finalize))
          (when (bound-and-true-p org-capture-mode)
            (org-capture-kill))))
      (org-with-point-at org-capture-last-stored-marker
        (should-not (org-entry-get nil "ID")))
      (should (equal "* Ordinary capture\nBody\n"
                     (supertag-document-test-disk target)))
      (should (= node-count
                 (hash-table-count (supertag-store-get-collection :nodes)))))))

(ert-deftest node-identity-persists-heading-id-without-location-cache ()
  "Creating a heading identity writes Org but does not register a location."
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "node.org" tmp)))
      (with-temp-file file
        (insert "* Node\n\nBody\n"))
      (with-current-buffer (find-file-noselect file)
        (org-mode)
        (goto-char (point-max))
        (cl-letf (((symbol-function 'supertag-node-identity-new)
                   (lambda () "node-id")))
          (should (equal "node-id"
                         (supertag-node-identity-ensure-at-point))))
        (should (equal "node-id" (org-entry-get nil "ID")))
        (should-not org-id-locations)
        (save-buffer))
      (with-temp-buffer
        (insert-file-contents file)
        (should (re-search-forward "^:ID:[ \t]+node-id$" nil t))))))

(ert-deftest node-location-finds-store-node-with-empty-org-id-cache ()
  "Store file plus in-file ID resolves without touching Org's cache."
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "node.org" tmp)))
      (with-temp-file file
        (insert "* Node\n:PROPERTIES:\n:ID:       node-id\n:END:\n"))
      (supertag-store-put-entity
       :nodes "node-id"
       `(:id "node-id" :title "Node" :file ,file :position 99999 :level 1))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (ert-fail "Store-first lookup consulted org-id-find"))))
        (let ((marker (supertag-node-location-find "node-id")))
          (should (markerp marker))
          (should (equal file (buffer-file-name (marker-buffer marker))))
          (with-current-buffer (marker-buffer marker)
            (should (equal "Node"
                           (org-get-heading t t t t)))))))))

(ert-deftest node-location-places-file-node-at-file-start ()
  "File-node navigation uses the Store projection and stays at point-min."
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "file-node.org" tmp)))
      (with-temp-file file
        (insert ":PROPERTIES:\n:ID:       file-id\n:END:\n#+TITLE: File\n"))
      (supertag-store-put-entity
       :nodes "file-id"
       `(:id "file-id" :title "File" :file ,file :position 99999 :level 0))
      (let ((marker (supertag-node-location-find "file-id")))
        (should (markerp marker))
        (should (= (marker-position marker) 1))))))

(ert-deftest node-location-navigates-file-node-identities-with-empty-cache ()
  "Org-ID and Denote file nodes share Store-first navigation."
  (require 'supertag-board)
  (require 'supertag-graph-ui)
  (node-identity-test--with-clean-env
    (let ((org-file (expand-file-name "org-file-node.org" tmp))
          (denote-file (expand-file-name "denote-file-node.org" tmp)))
      (with-temp-file org-file
        (insert ":PROPERTIES:\n:ID: org-file-id\n:END:\n#+TITLE: Org\n"))
      (with-temp-file denote-file
        (insert "#+TITLE: Denote\n#+IDENTIFIER: denote-file-id\n"))
      (supertag-store-put-entity
       :nodes "org-file-id"
       `(:id "org-file-id" :title "Org" :file ,org-file
         :position 99999 :level 0 :link-type id))
      (supertag-store-put-entity
       :nodes "denote-file-id"
       `(:id "denote-file-id" :title "Denote" :file ,denote-file
         :position 99999 :level 0 :link-type denote))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (ert-fail "File-node navigation consulted org-id-find")))
                ((symbol-function 'pop-to-buffer)
                 (lambda (buffer &rest _)
                   (set-buffer buffer)
                   buffer))
                ((symbol-function 'switch-to-buffer)
                 (lambda (buffer &rest _)
                   (set-buffer buffer)
                   buffer))
                ((symbol-function 'org-show-context) #'ignore)
                ((symbol-function 'select-frame-set-input-focus) #'ignore))
        (dolist (pair `(("org-file-id" . ,org-file)
                        ("denote-file-id" . ,denote-file)))
          (let ((node-id (car pair))
                (file (cdr pair)))
            (save-current-buffer
              (supertag-goto-node node-id)
              (should (equal file (buffer-file-name)))
              (should (= (point) (point-min))))
            (save-current-buffer
              (supertag-graph-ui--jump-to-node node-id)
              (should (equal file (buffer-file-name)))
              (should (= (point) (point-min))))
            (save-current-buffer
              (supertag-board--on-open-node `((id . ,node-id)))
              (should (equal file (buffer-file-name)))
              (should (= (point) (point-min))))))))))

(ert-deftest node-location-rejects-child-id-as-file-node-identity ()
  "A child heading ID cannot validate a stale file-node projection."
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "wrong-file-node.org" tmp)))
      (with-temp-file file
        (insert "* Child\n:PROPERTIES:\n:ID: file-id\n:END:\n"))
      (supertag-store-put-entity
       :nodes "file-id"
       `(:id "file-id" :title "File" :file ,file
         :position 1 :level 0 :link-type id))
      (should-not (supertag-node-location-find "file-id"))
      (should-not (supertag-node-location-file "file-id")))))

(ert-deftest node-location-confines-org-id-compatibility-fallback ()
  "Unprojected nodes may still use the boundary's explicit fallback."
  (node-identity-test--with-clean-env
    (with-temp-buffer
      (org-mode)
      (insert "* Node\n")
      (goto-char (point-min))
      (let ((expected (point-marker)))
        (cl-letf (((symbol-function 'org-id-find)
                   (lambda (id markerp)
                     (should (equal "legacy-id" id))
                     (should (eq 'marker markerp))
                     expected)))
          (should (eq expected
                      (supertag-node-location-find "legacy-id"))))))))

(ert-deftest node-location-does-not-fallback-for-broken-store-projection ()
  "Known nodes with broken locations fail closed instead of using stale cache."
  (node-identity-test--with-clean-env
    (let ((missing-file (expand-file-name "missing.org" tmp))
          (fallback-used nil))
      (supertag-store-put-entity
       :nodes "node-id"
       `(:id "node-id" :title "Node" :file ,missing-file :level 1))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (setq fallback-used t)
                   (point-marker))))
        (should-not (supertag-node-location-find "node-id"))
        (should-not fallback-used)))))

(ert-deftest node-identity-ordinary-creation-works-with-empty-location-cache ()
  "The ordinary create command persists and projects identity without cache."
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "ordinary.org" tmp)))
      (with-temp-file file
        (insert "* Ordinary\n"))
      (with-current-buffer (find-file-noselect file)
        (org-mode)
        (goto-char (point-min))
        (cl-letf (((symbol-function 'supertag-node-identity-new)
                   (lambda () "ordinary-id"))
                  ((symbol-function 'org-id-find)
                   (lambda (&rest _)
                     (ert-fail "Ordinary creation consulted org-id-find"))))
          (should (equal "ordinary-id" (supertag-service-org-create-node-at-point)))
          (save-buffer)))
      (should (supertag-store-get-entity :nodes "ordinary-id"))
      (should (supertag-node-location-find "ordinary-id")))))

(ert-deftest node-identity-capture-works-with-empty-location-cache ()
  "Finalize ordinary Org text and project its identity without the ID cache."
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "capture.org" tmp)))
      (with-temp-file file
        (insert "* Captured\n:PROPERTIES:\n:ID: capture-id\n:END:\nBody\n"))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (ert-fail "Capture consulted org-id-find"))))
        (with-current-buffer (find-file-noselect file)
          (org-mode)
          (goto-char (point-min))
          (should (equal "capture-id"
                         (supertag-capture-finalize-node-at-point))))
        (should (supertag-store-get-entity :nodes "capture-id"))
        (should (supertag-node-location-find "capture-id"))))))

(ert-deftest node-identity-capture-finalize-org-tags-and-properties ()
  "Finalize tags survive saving and rebuilding the projection."
  (dolist (case '((nil ((:tag "alpha")) ("alpha"))
                  (nil ((:tag "alpha" :property "my:key" :value "value")) ("alpha"))
                  (nil ((:tag "alpha") (:tag "beta") (:tag "alpha")) ("alpha" "beta"))
                  (" #alpha" ((:tag "alpha")) ("alpha"))))
    (supertag-document-test-with-vault
      (with-current-buffer (find-file-noselect plain)
        (goto-char (point-min))
        (end-of-line)
        (insert (or (car case) ""))
        (let ((id (supertag-capture-finalize-node-at-point (cadr case))))
          (should (equal id (org-entry-get nil "ID")))
          (when (plist-get (car (cadr case)) :property)
            (should (equal "value" (org-entry-get nil "MY_KEY"))))
          (let ((heading (org-get-heading t t t t)))
            (dolist (tag (nth 2 case))
              (should (= 2 (length (split-string heading (concat "#" tag)))))))
          (save-buffer)
          (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
          (should (equal (sort (copy-sequence (nth 2 case)) #'string<)
                         (sort (mapcar (lambda (tag-id)
                                         (plist-get (supertag-tag-get tag-id) :name))
                                       (plist-get (supertag-node-get id) :tags))
                               #'string<))))))))

(ert-deftest node-identity-capture-finalize-preflights-all-specs ()
  "Invalid late specs cannot create identity or alter existing facts."
  (dolist (bad '((:property "ID" :value "other")
                 (:field "id" :value "other")
                 (:property "TODO" :value "other")
                 (:tag "") (:tag nil) (:tag 42)))
    (supertag-document-test-with-vault
      (dolist (path (list file plain))
        (with-current-buffer (find-file-noselect path)
          (goto-char (point-min))
          (let ((before (buffer-string))
                (disk (supertag-document-test-disk path))
                (count (hash-table-count (supertag-store-get-collection :nodes)))
                (dirty (buffer-modified-p)))
            (should-error
             (supertag-capture-finalize-node-at-point
              (list '(:property "GOOD" :value "no-write") '(:tag "no-write") bad))
             :type 'user-error)
            (should (equal before (buffer-string)))
            (should (equal disk (supertag-document-test-disk path)))
            (should (eq dirty (buffer-modified-p)))
            (should (= count (hash-table-count (supertag-store-get-collection :nodes))))))))))

(ert-deftest node-identity-completion-works-with-empty-location-cache ()
  "Completion persists, projects, and resolves an ID-less file-backed node."
  (node-identity-test--with-clean-env
    (let* ((file (expand-file-name "completion.org" tmp))
           (tag (supertag-tag-create '(:name "diary")))
           (tag-id (plist-get tag :id))
           node-id)
      (with-temp-file file
        (insert "* Node #diary"))
      (with-current-buffer (find-file-noselect file)
        (org-mode)
        (goto-char (point-max))
        (let ((candidate (propertize "diary" 'supertag-tag-id tag-id)))
          (cl-letf (((symbol-function 'org-id-find)
                     (lambda (&rest _)
                       (ert-fail "Completion consulted org-id-find"))))
            (supertag-completion--post-completion-action candidate)))
        (goto-char (point-min))
        (setq node-id (org-entry-get nil "ID"))
        (should (stringp node-id))
        (should (equal node-id
                       (plist-get (supertag-node-get node-id) :id)))
        (save-buffer))
      (should (equal (format "[[id:%s][Node]]" node-id)
                     (supertag-node-format-link node-id "Node")))
      (let ((marker (supertag-node-location-find node-id)))
        (should (markerp marker))
        (should (equal file (buffer-file-name (marker-buffer marker))))))))

(ert-deftest node-location-opens-org-id-link-with-empty-location-cache ()
  "Org id links follow the Store projection without Org's location cache."
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "node.org" tmp)))
      (with-temp-file file
        (insert "* Node\n:PROPERTIES:\n:ID:       node-id\n:END:\n"))
      (supertag-store-put-entity
       :nodes "node-id"
       `(:id "node-id" :title "Node" :file ,file :level 1))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (ert-fail "Org link lookup consulted org-id-find")))
                ((symbol-function 'supertag-sync--in-sync-scope-p)
                 (lambda (_) t))
                ((symbol-function 'pop-to-buffer)
                 (lambda (buffer &rest _)
                   (set-buffer buffer)
                   buffer))
                ((symbol-function 'org-show-context) #'ignore)
                ((symbol-function 'recenter) #'ignore))
        (should (supertag-service-org-follow-id "node-id"))
        (should (equal "Node" (org-get-heading t t t t)))))))

(ert-deftest node-location-ui-graph-and-board-use-store-with-empty-cache ()
  "Direct, graph, and board navigation share Store-first lookup."
  (require 'supertag-board)
  (require 'supertag-graph-ui)
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "navigation.org" tmp)))
      (with-temp-file file
        (insert "* Node\n:PROPERTIES:\n:ID:       node-id\n:END:\n"))
      (supertag-store-put-entity
       :nodes "node-id"
       `(:id "node-id" :title "Node" :file ,file :position 99999 :level 1))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (ert-fail "Navigation consulted org-id-find")))
                ((symbol-function 'pop-to-buffer)
                 (lambda (buffer &rest _)
                   (set-buffer buffer)
                   buffer))
                ((symbol-function 'switch-to-buffer)
                 (lambda (buffer &rest _)
                   (set-buffer buffer)
                   buffer))
                ((symbol-function 'org-show-context) #'ignore)
                ((symbol-function 'select-frame-set-input-focus) #'ignore))
        (save-current-buffer
          (supertag-goto-node "node-id")
          (should (equal "node-id" (org-entry-get nil "ID"))))
        (save-current-buffer
          (supertag-graph-ui--jump-to-node "node-id")
          (should (equal "node-id" (org-entry-get nil "ID"))))
        (save-current-buffer
          (supertag-board--on-open-node '((id . "node-id")))
          (should (equal "node-id" (org-entry-get nil "ID"))))))))

(ert-deftest node-location-automation-uses-store-file-with-empty-cache ()
  "Automation resolves the source file through the location boundary."
  (node-identity-test--with-clean-env
    (let ((source-file (expand-file-name "source.org" tmp))
          (target-file (expand-file-name "target.org" tmp))
          moved)
      (with-temp-file source-file
        (insert "* Node\n:PROPERTIES:\n:ID:       node-id\n:END:\n"))
      (with-temp-file target-file)
      (supertag-store-put-entity
       :nodes "node-id"
       `(:id "node-id" :title "Node" :file ,source-file :level 1))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (ert-fail "Automation consulted org-id-find")))
                ((symbol-function 'supertag-service-org-move-node-to-file)
                 (lambda (id file &rest _)
                   (setq moved (list id file))
                   t)))
        (supertag-automation-action-move-node
         "node-id" (list :target-file target-file))
        (should (equal (list "node-id" target-file) moved))))))

(ert-deftest node-location-automation-signals-broken-store-projection ()
  "Automation signals for both missing files and missing in-file IDs."
  (node-identity-test--with-clean-env
    (let ((target-file (expand-file-name "target.org" tmp))
          (missing-file (expand-file-name "missing.org" tmp))
          (wrong-file (expand-file-name "wrong.org" tmp))
          errors
          moved)
      (with-temp-file target-file)
      (with-temp-file wrong-file
        (insert "* Different node\n:PROPERTIES:\n:ID: other-id\n:END:\n"))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (ert-fail "Broken Store projection consulted org-id-find")))
                ((symbol-function 'supertag-service-org-move-node-to-file)
                 (lambda (&rest _)
                   (setq moved t))))
        (dolist (file (list missing-file wrong-file))
          (supertag-store-put-entity
           :nodes "node-id"
           `(:id "node-id" :title "Node" :file ,file :level 1))
          (push (should-error
                 (supertag-automation-action-move-node
                  "node-id" (list :target-file target-file))
                 :type 'user-error)
                errors)))
      (should-not moved)
      (should (= 2 (length errors)))
      (dolist (err errors)
        (should (equal "Cannot resolve source for node node-id"
                       (error-message-string err)))))))

(ert-deftest node-location-board-reports-missing-node ()
  "Board navigation and mutation emit diagnostics for missing locations."
  (require 'supertag-board)
  (require 'supertag-graph-ui)
  (let (messages)
    (cl-letf (((symbol-function 'supertag-node-location-find) #'ignore)
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (supertag-board--on-open-node '((id . "missing-id")))
      (supertag-board--on-update-title
       '((nodeId . "missing-id") (title . "Title"))))
    (should (member "supertag-board: Cannot find node missing-id" messages))
    (should (member
             "supertag-board: Cannot update title for missing-id" messages))))

(ert-deftest node-identity-boundary-is-the-only-runtime-org-id-owner ()
  "Production feature modules do not bypass the identity/location boundary."
  (let* ((root node-identity-test--root)
         (boundary (expand-file-name "supertag-service-org.el" root))
         (pattern
          "(\\s-*org-id-\\(?:new\\|get-create\\|find\\(?:-id-\\(?:file\\|in-file\\)\\)?\\|goto\\|add-location\\)\\_>")
         violations)
    (dolist (file (directory-files root t "\\`supertag-.*\\.el\\'"))
      (unless (equal file boundary)
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (when (re-search-forward pattern nil t)
            (push (file-name-nondirectory file) violations)))))
    (should-not violations)))

(provide 'node-identity-test)
;;; node-identity-test.el ends here

;;; NODE-E independent standard Capture lifecycle and provider controls.
(defun node-identity-test--capture-cold (stage scenario preset)
  (let* ((tmp (make-temp-file "supertag-node-e-" t))
         (root node-identity-test--root)
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (process-environment (copy-sequence process-environment))
         (script (expand-file-name "cold.el" tmp))
         (body '(progn
  (require 'cl-lib)
  (require 'ert)
  (setq user-emacs-directory (file-name-as-directory ne-tmp)
        supertag-data-directory (expand-file-name "data/" ne-tmp)
        supertag--base-data-directory supertag-data-directory
        supertag-db-file (expand-file-name "store.el" supertag-data-directory)
        supertag-db-backup-directory (expand-file-name "backups/" ne-tmp)
        supertag-sync-state-file (expand-file-name "sync.el" ne-tmp)
        supertag-sync--state-source supertag-sync-state-file
        supertag-sync-directories (list ne-tmp) supertag-sync-directories-mode 'unified
        org-id-locations-file (expand-file-name "ids" ne-tmp)
        org-id-locations nil org-id-files nil org-id-track-globally nil
        org-mode-hook nil after-init-time nil supertag-view-style-auto-enable nil
        org-capture-after-finalize-hook (list #'ignore)
        make-backup-files nil auto-save-default nil load-prefer-newer t)
  (unless (eq ne-preset 'unbound)
    (setq supertag-org-capture-auto-enable ne-preset))
  (defun ne-disk (file)
    (with-temp-buffer (insert-file-contents file) (buffer-string)))
  (defun ne-own-functions (owner)
    (dolist (symbol '(supertag-capture-finalize-node-at-point supertag-org-capture-after-finalize
                      supertag-enable-org-capture-integration supertag-disable-org-capture-integration))
      (unless (equal (symbol-file symbol 'defun) (expand-file-name owner ne-root))
        (error "NODE-E owner mismatch %S=%S" symbol (symbol-file symbol 'defun)))
      (should-not (commandp symbol)))
    (should (equal (symbol-file 'supertag-org-capture-auto-enable 'defvar)
                   (expand-file-name owner ne-root))))
  (defun ne-pure-node ()
    (should (featurep 'supertag-service-org))
    (dolist (feature '(supertag-tag supertag-services-sync supertag-services-ui
                       supertag-ui-commands supertag-query supertag-services-query supertag-services-note-query supertag))
      (should-not (featurep feature))
      (should-not (cl-find-if (lambda (row) (and (stringp (car row))
                                                 (equal (file-name-base (car row)) (symbol-name feature)))) load-history)))
    (should-not (file-exists-p supertag-db-file)))
  (load (expand-file-name "supertag-node.el" ne-root) nil nil t)
  (princ (format "NODE-E-ENTRY stage=%S case=%S preset=%S\n" ne-stage ne-case ne-preset))
  (ne-pure-node)
  (if (eq ne-case 'owner)
      (progn
        (ne-own-functions "supertag-node.el")
        (should-not (file-exists-p (expand-file-name "supertag-services-capture.el" ne-root)))
        (should-not (locate-library "supertag-services-capture"))
        (should-not (featurep 'supertag-services-capture)))
    (if (eq ne-stage 'before)
        (progn
          (should-not (fboundp 'supertag-capture-finalize-node-at-point))
          (should (equal '(ignore) org-capture-after-finalize-hook))
          (if (eq ne-preset 'unbound)
              (should-not (boundp 'supertag-org-capture-auto-enable))
            (should (eq ne-preset supertag-org-capture-auto-enable)))
          (load (expand-file-name "supertag-services-capture.el" ne-root) nil nil t)
          (ne-own-functions "supertag-services-capture.el"))
      (ne-own-functions "supertag-node.el")
      (dolist (symbol '(supertag-capture-add-tags-to-nodes supertag-capture-add-tag-to-nodes
                        supertag-capture--get-from-tags-prompt))
        (should (autoloadp (symbol-function symbol)))
        (should (equal "supertag-tag" (nth 1 (symbol-function symbol)))))
      (should (autoloadp (symbol-function 'supertag-node-sync-at-point))))
    (should (eq (eq ne-preset t) supertag-org-capture-auto-enable))
    (should (equal "Capture-related configuration and integration for Supertag."
                   (get 'supertag-capture 'group-documentation)))
    (should (memq #'ignore org-capture-after-finalize-hook))
    (should (= (if (eq ne-preset t) 1 0)
               (cl-count #'supertag-org-capture-after-finalize org-capture-after-finalize-hook)))
    (dolist (symbol '(supertag-capture supertag-capture-with-template supertag-capture--get-from-clipboard))
      (should-not (fboundp symbol)))
    (pcase ne-case
      ('lifecycle
       (supertag-enable-org-capture-integration)
       (supertag-enable-org-capture-integration)
       (should (= 1 (cl-count #'supertag-org-capture-after-finalize org-capture-after-finalize-hook)))
       (load (expand-file-name (if (eq ne-stage 'before) "supertag-services-capture.el" "supertag-node.el") ne-root) nil nil t)
       (should (= 1 (cl-count #'supertag-org-capture-after-finalize org-capture-after-finalize-hook)))
       (supertag-disable-org-capture-integration)
       (supertag-disable-org-capture-integration)
       (should (equal '(ignore) org-capture-after-finalize-hook))
       (should-not supertag-org-capture-auto-enable)
       (add-hook 'org-capture-after-finalize-hook #'supertag-org-capture-after-finalize)
       (load (expand-file-name (if (eq ne-stage 'before) "supertag-services-capture.el" "supertag-node.el") ne-root) nil nil t)
       (should-not supertag-org-capture-auto-enable)
       (should (= 1 (cl-count #'supertag-org-capture-after-finalize org-capture-after-finalize-hook)))
       (should (memq #'ignore org-capture-after-finalize-hook)))
      ('pending
       (let* ((file (expand-file-name "pending.org" ne-tmp))
              (org-capture-templates `(("n" "Node" entry (file ,file) "* Pending\nBody\n" :supertag t)))
              (callback (symbol-function 'supertag-org-capture-after-finalize)))
         (with-temp-file file)
         (supertag--ensure-store)
         (let ((facts (prin1-to-string supertag--store)))
           (supertag-enable-org-capture-integration)
           (org-capture nil "n") (should org-capture-mode)
           (supertag-disable-org-capture-integration)
           (org-capture-finalize)
           (should (equal facts (prin1-to-string supertag--store)))
           (with-current-buffer (find-file-noselect file)
             (goto-char (point-min)) (should-not (org-entry-get nil "ID"))
             (let ((disk (ne-disk file))
                   (org-capture-plist '(:supertag t))
                   (org-capture-last-stored-marker (point-marker)))
               (unwind-protect
                   (progn
                     (funcall callback)
                     (should-not supertag-org-capture-auto-enable)
                     (should (org-entry-get nil "ID"))
                     (should (supertag-node-get (org-entry-get nil "ID")))
                     (should (buffer-modified-p))
                     (should (equal disk (ne-disk file)))
                     (setq org-capture-plist nil)
                     (let ((text (buffer-string)) (store (prin1-to-string supertag--store)))
                       (funcall callback)
                       (should (equal text (buffer-string)))
                       (should (equal store (prin1-to-string supertag--store)))))
                 (set-marker org-capture-last-stored-marker nil)))))))
      ('markers
       (supertag--ensure-store)
       (let* ((file (expand-file-name "markers.org" ne-tmp))
              (dead-buffer (generate-new-buffer " *node-e-dead*"))
              (dead (with-current-buffer dead-buffer (point-marker)))
              (detached (make-marker)))
         (kill-buffer dead-buffer)
         (with-temp-file file (insert "* Safe\nBody\n"))
         (with-current-buffer (find-file-noselect file)
           (let ((text (buffer-string)) (disk (ne-disk file))
                 (facts (prin1-to-string supertag--store))
                 (dirty (buffer-modified-p)))
             (dolist (opt '(nil t))
               (dolist (marker (list nil 42 detached dead))
                 (let ((org-capture-plist (and opt '(:supertag t)))
                       (org-capture-last-stored-marker marker) caught)
                   (condition-case err (supertag-org-capture-after-finalize)
                     (error (setq caught err)))
                   (if (and opt (markerp marker))
                       (progn (should (eq 'wrong-type-argument (car caught)))
                              (princ (format "NODE-E-MARKER %S\n" caught)))
                     (should-not caught))
                   (should (equal text (buffer-string)))
                   (should (equal disk (ne-disk file)))
                   (should (equal facts (prin1-to-string supertag--store)))
                   (should (eq dirty (buffer-modified-p))))))))))
      (_
       (let* ((file (expand-file-name "entry.org" ne-tmp))
              (content "* Entry\nBody\n")
              (saved 0) (answers (list "alpha" "")) id)
         (with-temp-file file (insert content))
         (supertag--ensure-store)
         (switch-to-buffer (find-file-noselect file)) (goto-char (point-min))
         (let ((save-original (symbol-function 'save-buffer)))
           (cl-letf (((symbol-function 'save-buffer)
                      (lambda (&rest args) (cl-incf saved) (apply save-original args)))
                     ((symbol-function 'completing-read)
                      (lambda (prompt &rest _)
                        (should (stringp prompt)) (should answers) (pop answers))))
             (setq id
                   (pcase ne-case
                     ('bare (supertag-capture-finalize-node-at-point))
                     ('property (supertag-capture-finalize-node-at-point '((:property "my:key" :value "value"))))
                     ('field (supertag-capture-finalize-node-at-point '((:field "my:key" :value "value"))))
                     ('tags (supertag-capture-finalize-node-at-point '((:tag "alpha") (:tag "alpha"))))
                     ('prompt
                      (let ((org-capture-plist '(:supertag t :supertag-tags-prompt t))
                            (org-capture-last-stored-marker (point-marker)))
                        (unwind-protect (supertag-org-capture-after-finalize)
                          (set-marker org-capture-last-stored-marker nil)))
                      (org-entry-get nil "ID"))))))
         (should id) (should (equal id (org-entry-get nil "ID")))
         (should (supertag-node-get id))
         (should (featurep 'supertag-services-sync))
         (should (featurep 'supertag-tag))
         (should-not (autoloadp (symbol-function 'supertag-node-sync-at-point)))
         (dolist (symbol '(supertag-capture-add-tags-to-nodes supertag-capture-add-tag-to-nodes supertag-capture--get-from-tags-prompt))
           (should-not (autoloadp (symbol-function symbol)))
           (should (equal (symbol-file symbol 'defun) (expand-file-name "supertag-tag.el" ne-root))))
         (if (memq ne-case '(tags prompt))
             (progn
               (should (= 1 saved))
               (should-not (buffer-modified-p))
               (should (plist-get (supertag-node-get id) :tags))
               (should (string-match-p (regexp-quote id) (ne-disk file))))
           (should (= 0 saved))
           (should (buffer-modified-p))
           (should (equal content (ne-disk file))))
         (when (memq ne-case '(property field))
           (should (equal "value" (org-entry-get nil "MY_KEY")))
           (should (equal "value" (plist-get (plist-get (supertag-node-get id) :properties) :MY_KEY)))))))
    (princ (format "NODE-E-BUSINESS %S/%S/%S PASS\n" ne-stage ne-case ne-preset)))
  (princ "NODE-E-PASS\n"))))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert ";;; -*- lexical-binding: t; -*-\n")
            (prin1 `(setq ne-root ,root ne-tmp ,tmp ne-stage ',stage ne-case ',scenario ne-preset ',preset) (current-buffer))
            (insert "\n")
            (let ((print-length nil) (print-level nil))
              (prin1 `(condition-case err
                          (unwind-protect ,body
                            (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil
                                  org-capture-after-finalize-hook nil enable-theme-functions nil)
                            (mapc #'cancel-timer (append timer-list timer-idle-list))
                            (dolist (buffer (buffer-list))
                              (when (and (buffer-file-name buffer)
                                         (file-in-directory-p (buffer-file-name buffer) ne-tmp))
                                (with-current-buffer buffer
                                  (set-buffer-modified-p nil) (kill-buffer buffer)))))
                        (error (princ (format "NODE-E-ERROR %S\n" err)) (kill-emacs 1))) (current-buffer))))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (with-temp-buffer
            (let ((status (apply #'call-process program nil t nil
                                 (append '("-Q" "--batch")
                                         (apply #'append (mapcar (lambda (dir) (list "-L" dir)) deps))
                                         (list "-L" root "-l" script)))))
              (unless (and (equal status 0) (string-match-p "NODE-E-ENTRY" (buffer-string))
                           (string-match-p "NODE-E-PASS" (buffer-string)))
                (ert-fail (format "NODE-E %S/%S/%S exit=%S\n%s" stage scenario preset status (buffer-string))))
              (dolist (line (split-string (buffer-string) "\n" t))
                (when (string-prefix-p "NODE-E-" line) (princ (concat line "\n")))))))
      (delete-directory tmp t))))

(ert-deftest node-identity-capture-cold-preset-reload ()
  (dolist (preset '(unbound nil t))
    (node-identity-test--capture-cold 'after 'lifecycle preset)))
(ert-deftest node-identity-capture-pending-disable-and-explicit-late-callback ()
  (node-identity-test--capture-cold 'after 'pending nil))
(ert-deftest node-identity-capture-invalid-marker-original-boundary ()
  (node-identity-test--capture-cold 'after 'markers nil))
(ert-deftest node-identity-capture-bare-property-field-cold-save-boundary ()
  (dolist (spec '(bare property field))
    (node-identity-test--capture-cold 'after spec nil)))
(ert-deftest node-identity-capture-tags-first-provider-real-save ()
  (node-identity-test--capture-cold 'after 'tags nil))
(ert-deftest node-identity-capture-prompt-first-provider-real-input ()
  (node-identity-test--capture-cold 'after 'prompt nil))

(ert-deftest node-identity-capture-node-entry-owner-and-retirement ()
  (node-identity-test--capture-cold 'after 'owner nil))

;;; ORG-IDENTITY: current shared identity and registration boundaries.
(defun node-identity-test--shared-org-child (label preset body)
  "Execute BODY in a fresh process; only the protocol-host control uses a seam."
  (let* ((tmp (make-temp-file "supertag-org-identity-" t))
         (script (expand-file-name "child.el" tmp))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (evidence (getenv "SUPERTAG_ORG_IDENTITY_EVIDENCE")))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert ";;; -*- lexical-binding: t; -*-\n")
            (prin1
             `(progn
                (require 'cl-lib) (require 'ert) (require 'org) (require 'org-id)
                (setq user-emacs-directory ,(file-name-as-directory tmp)
                      supertag-data-directory ,tmp supertag--base-data-directory ,tmp
                      supertag-db-file ,(expand-file-name "store.el" tmp)
                      org-id-locations-file ,(expand-file-name "ids" tmp)
                      org-id-locations nil org-id-files nil org-id-track-globally nil
                      after-init-time nil org-mode-hook nil find-file-hook nil
                      supertag-sync-directories nil supertag-active-sync-directory nil
                      make-backup-files nil auto-save-default nil load-prefer-newer t
                      supertag-node-location-org-id-fallback ,preset
                      supertag-org-id-open-link-auto-enable ,preset)
                (let ((oi-root ,node-identity-test--root) (oi-tmp ,tmp))
                  (condition-case error-data
                      (unwind-protect
                          (progn
                            (princ (format "ORG-IDENTITY-BEGIN %s preset=%S host=%S\n"
                                           ,label ,preset (fboundp 'org-id-open-link)))
                            ,body
                            (princ ,(format "ORG-IDENTITY-DONE %s\n" label)))
                        (setq kill-emacs-hook nil emacs-startup-hook nil org-mode-hook nil)
                        (dolist (timer (append timer-list timer-idle-list)) (cancel-timer timer)))
                    (error (princ (format "ORG-IDENTITY-ERROR %S\n" error-data))
                           (kill-emacs 1))))) (current-buffer)))
          (with-temp-buffer
            (let ((code (apply #'call-process program nil t nil
                               (append '("-Q" "--batch")
                                       (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                       (list "-L" node-identity-test--root "-l" script)))))
              (when evidence
                (make-directory evidence t)
                (copy-file script (expand-file-name (concat label ".el") evidence) t)
                (write-region (point-min) (point-max) (expand-file-name (concat label ".log") evidence) nil 'silent))
              (princ (buffer-string))
              (should (equal code 0))
              (should (string-match-p (regexp-quote (concat "ORG-IDENTITY-DONE " label)) (buffer-string))))))
      (delete-directory tmp t))))

(ert-deftest node-identity-shared-org-fresh-location-and-preset ()
  "Use real Org text and explicit Store facts without Node/Sync preloading."
  (dolist (preset '(nil t))
    (node-identity-test--shared-org-child
     (format "location-%S" preset) preset
     `(progn
        (require 'supertag-service-org)
        (princ "ORG-IDENTITY-ENTRY ServiceOrg\n")
        (should (eq ,preset supertag-node-location-org-id-fallback))
        (should-not (featurep 'supertag-service-node-identity))
        (should-not (locate-library "supertag-service-node-identity"))
        (dolist (symbol '(supertag-node-identity-new supertag-node-identity-ensure-at-point
                          supertag-node-location--id-property-position supertag-node-location--heading-position
                          supertag-node-location--file-drawer-end supertag-node-location--file-org-id
                          supertag-node-location--file-denote-id supertag-node-location--file-identity-matches-p
                          supertag-node-location--position supertag-node-location-goto-current-buffer
                          supertag-node-location--store-marker supertag-node-location-find supertag-node-location-file))
          (should-not (autoloadp (symbol-function symbol)))
          (should (equal (symbol-file symbol 'defun) (expand-file-name "supertag-service-org.el" oi-root))))
        (let* ((file (expand-file-name "identity.org" oi-tmp))
               (text ":PROPERTIES:\n:ID: oi-file\n:END:\n#+TITLE: Identity\n* Target\n:PROPERTIES:\n:ID: oi-node\n:END:\nBody\n* Other\nOther body\n"))
          (with-temp-file file (insert text))
          (supertag--ensure-store)
          (supertag-store-put-entity :nodes "oi-node" (list :id "oi-node" :file file :level 1 :position 99999))
          (supertag-store-put-entity :nodes "oi-file" (list :id "oi-file" :file file :level 0 :link-type 'id))
          (supertag-store-put-entity :nodes "oi-broken" (list :id "oi-broken" :file file :level 1))
          (let ((facts (prin1-to-string supertag--store)) (ids (copy-tree org-id-locations)))
            (with-current-buffer (find-file-noselect file)
              (goto-char (point-max))
              (should (supertag-node-location-goto-current-buffer "oi-node"))
              (should (equal (org-entry-get nil "ID") "oi-node"))
              (should (equal "oi-node" (supertag-node-identity-ensure-at-point "oi-node")))
              (should-error (supertag-node-identity-ensure-at-point "conflict") :type 'user-error)
              (should (= (marker-position (supertag-node-location-find "oi-node")) (point)))
              (should (equal file (supertag-node-location-file "oi-node")))
              (should (= 1 (marker-position (supertag-node-location-find "oi-file"))))
              (should-not (supertag-node-location-find "oi-broken"))
              (should-not (buffer-modified-p))
              (should (equal text (buffer-string))))
            (should (stringp (supertag-node-identity-new)))
            (should (equal ids org-id-locations))
            (should (equal facts (prin1-to-string supertag--store)))
            (should (equal text (with-temp-buffer (insert-file-contents file) (buffer-string))))))
        (dolist (feature '(supertag-node supertag-tag supertag-services-sync supertag-query supertag))
          (should-not (featurep feature)))
        (should-not (file-exists-p supertag-db-file))))))

(ert-deftest node-identity-shared-org-require-reload-and-native-advice-seam ()
  "A supplied host is an existence seam, not this Emacs's native Org command."
  (dolist (preset '(nil t))
    (node-identity-test--shared-org-child
     (format "advice-%S" preset) preset
     `(let ((foreign-calls 0))
        (princ "ORG-IDENTITY-HOST-EXISTENCE-SEAM native-advice\n")
        (fset 'org-id-open-link (lambda (&rest args) (cons 'original args)))
        (let ((foreign (lambda (original &rest args)
                         (cl-incf foreign-calls) (apply original args))))
          (advice-add 'org-id-open-link :around foreign)
          (require 'supertag-service-org)
          (princ "ORG-IDENTITY-ENTRY native-advice seam\n")
          (should (eq ,preset (not (null (advice-member-p #'supertag-service-org--org-id-open-link-advice 'org-id-open-link)))))
          (should (advice-member-p foreign 'org-id-open-link))
          (let ((cell (symbol-function 'supertag-node-location-find)))
            (require 'supertag-service-org)
            (should (eq cell (symbol-function 'supertag-node-location-find))))
          (should (equal '(original "unknown" extra) (org-id-open-link "unknown" 'extra)))
          (should (= 1 foreign-calls))
          (load (expand-file-name "supertag-service-org.el" oi-root) nil nil t)
          (should (eq ,preset supertag-node-location-org-id-fallback))
          (should (eq ,preset supertag-org-id-open-link-auto-enable))
          (supertag-enable-org-id-open-link-integration)
          (supertag-enable-org-id-open-link-integration)
          (load (expand-file-name "supertag-service-org.el" oi-root) nil nil t)
          (let ((count 0))
            (advice-mapc (lambda (ad _props) (when (eq ad #'supertag-service-org--org-id-open-link-advice) (cl-incf count))) 'org-id-open-link)
            (should (= count 1)))
          (supertag-disable-org-id-open-link-integration)
          (load (expand-file-name "supertag-service-org.el" oi-root) nil nil t)
          (should-not (advice-member-p #'supertag-service-org--org-id-open-link-advice 'org-id-open-link))
          (should (advice-member-p foreign 'org-id-open-link))
          (should (equal '(original "unknown" extra) (org-id-open-link "unknown" 'extra)))
          (should (= 2 foreign-calls))
          (dolist (feature '(supertag-node supertag-tag supertag-services-sync supertag-query supertag))
            (should-not (featurep feature))))))))
