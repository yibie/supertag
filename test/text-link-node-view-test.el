;;; text-link-node-view-test.el --- Configured text links in Node View -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)

(when load-file-name
  (add-to-list 'load-path (file-name-directory load-file-name))
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-services-sync)
(require 'supertag-automation)
(require 'supertag-query)
(require 'supertag-link)
(require 'supertag-view-node)

(defmacro supertag-text-link-test--with-vault (&rest body)
  "Run BODY with two real saved Org nodes and an isolated Store."
  (declare (indent 0) (debug t))
  `(let* ((tmp (file-name-as-directory
                (file-truename (make-temp-file "supertag-text-link-" t))))
          (source-file (expand-file-name "a-source.org" tmp))
          (third-file (expand-file-name "y-third.org" tmp))
          (target-file (expand-file-name "z-target.org" tmp))
          (supertag-data-directory (expand-file-name "data" tmp))
          (supertag-db-file (expand-file-name "store.el" supertag-data-directory))
          (supertag-db-backup-directory
           (expand-file-name "backups" supertag-data-directory))
          (supertag-sync-directories (list tmp))
          (supertag-active-sync-directory tmp)
          (supertag-text-link-relation-types '("supports" "opposes" "reinforces"))
          (supertag--store nil)
          (supertag-sync--state
           (list :sync-state (make-hash-table :test 'equal)))
          (supertag-sync--state-source
           (expand-file-name "sync-state.el" supertag-data-directory))
          (supertag-sync--deferred-files (make-hash-table :test 'equal))
          (supertag-sync--internal-modifications (make-hash-table :test 'equal))
          (supertag-automation-sync--enabled nil)
          (supertag-automation--event-queue nil))
     (unwind-protect
         (progn
           (with-temp-file source-file
             (insert "* Source\n:PROPERTIES:\n:ID: source-id\n"
                     ":SUPPORTS: [[id:target-id][property link]]\n:END:\n"
                     "[[id:target-id][ordinary]]\n"
                     "[[supports:target-id][supports once]]\n"
                     "[[supports:target-id][supports duplicate]]\n"
                     "[[opposes:target-id][opposes]]\n"
                     "#+BEGIN: generated\n[[reinforces:target-id][generated]]\n#+END:\n"))
           (with-temp-file target-file
             (insert "* Target\n:PROPERTIES:\n:ID: target-id\n:END:\n"))
           (with-temp-file third-file
             (insert "* Third\n:PROPERTIES:\n:ID: third-id\n:END:\n"))
           (supertag--ensure-store)
           (cl-letf (((symbol-function 'supertag-sync-save-state) #'ignore))
             (should (eq 'complete (plist-get (supertag-reindex-org) :status))))
           (clrhash supertag-sync--internal-modifications)
           ,@body)
       (dolist (buffer (buffer-list))
         (when-let* ((file (buffer-file-name buffer)))
           (when (file-in-directory-p file tmp)
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer))))
       (supertag-text-link-clear-registrations)
       (ignore-errors (delete-directory tmp t)))))

(defun supertag-text-link-test--save-body-through-async (file body)
  "Replace FILE's first-node body with BODY and process its real save queue."
  (cancel-function-timers #'supertag-async--worker)
  (supertag-async-init #'supertag-sync--async-processor)
  (setq supertag-async--timer :held-for-test)
  (with-current-buffer (find-file-noselect file)
            (org-mode)
            (goto-char (point-min))
            (re-search-forward "^:END:$")
            (forward-line 1)
            (delete-region (point) (point-max))
            (insert body)
            (let ((hook-calls 0))
              (setq-local after-save-hook nil)
              (add-hook 'after-save-hook
                        (lambda ()
                          (cl-incf hook-calls)
                          (supertag-sync--run-on-save))
                        nil t)
              (save-buffer)
              (should (= 1 hook-calls))))
  (should (equal (list (file-truename file)) supertag-async--queue))
  (setq supertag-async--timer nil)
  (supertag-async--worker)
  (should-not supertag-async--queue))

(defun supertag-text-link-test--relations ()
  "Return the three projected reference relations from the source fixture."
  (supertag-query-relations-from "source-id" :reference :document-link))

(ert-deftest supertag-text-link-projects-three-independent-same-endpoint-facts ()
  "Ordinary, supports and opposes links retain separate identities."
  (supertag-text-link-test--with-vault
    (let ((relations (supertag-text-link-test--relations)))
      (should (= 3 (length relations)))
      (should (= 3 (length (delete-dups
                            (mapcar (lambda (relation)
                                      (plist-get relation :id))
                                    relations)))))
      (should (equal '(nil "opposes" "supports")
                     (sort (mapcar (lambda (relation)
                                     (plist-get relation :relation-name))
                                   relations)
                           (lambda (left right)
                             (string< (or left "") (or right ""))))))
      (dolist (relation relations)
        (should (eq :reference (plist-get relation :type)))
        (should (eq :document-link (plist-get relation :kind)))
        (should (eq :org (plist-get relation :origin)))
        (should-not (plist-member relation :link-definition-id)))
      (should (= 0 (supertag-relation-cleanup-duplicates)))
      (should (= 3 (length (supertag-text-link-test--relations))))
      (let ((supports (car (supertag-query-named-links-from
                            "source-id" "supports"))))
        (should-error
         (supertag-relation-update
          (plist-get supports :id)
          (lambda (relation)
            (plist-put relation :relation-name "opposes"))))))))

(ert-deftest supertag-text-link-query-view-and-ordinary-aggregation-are-isolated ()
  "Named query and Node View show relations without inflating ordinary refs."
  (supertag-text-link-test--with-vault
    (should (equal '("opposes" "supports")
                   (sort (mapcar (lambda (relation)
                                   (plist-get relation :relation-name))
                                 (supertag-query-named-links-from "source-id"))
                         #'string<)))
    (should (= 1 (length
                  (supertag-reference-service-outgoing "source-id"))))
    (should (= 1 (plist-get (supertag-query-node "target-id") :ref-count)))
    (let ((detail (supertag-query-node-detail "source-id")))
      (should (equal '("target-id") (plist-get detail :refs-to)))
      (should (= 1 (plist-get detail :ref-count))))
    (should (equal '("target-id")
                   (supertag-view-node--get-references "source-id")))
    (should (equal '("source-id")
                   (supertag-view-node--get-referenced-by "target-id")))
    (with-temp-buffer
      (supertag-view-node-mode)
      (supertag-view-node--render-from-state
       (supertag-view-build-node-state "source-id"))
      (should (string-match-p "→ Target\n      supports →" (buffer-string)))
      (should (string-match-p "→ Target\n      opposes →" (buffer-string)))
      (should-not (string-match-p "Typed Links" (buffer-string))))
    (with-temp-buffer
      (supertag-view-node-mode)
      (supertag-view-node--render-from-state
       (supertag-view-build-node-state "target-id"))
      (should (string-match-p "→ Source\n      ← supports" (buffer-string)))
      (should (string-match-p "→ Source\n      ← opposes" (buffer-string))))))

(ert-deftest supertag-text-link-ordinary-create-count-ignores-named-existing ()
  "An existing named edge does not hide creation of an ordinary reference."
  (supertag-text-link-test--with-vault
    (let* ((ordinary (cl-find-if-not
                      #'supertag-relation-named-document-link-p
                      (supertag-text-link-test--relations)))
           (counters '(:references-created 0 :references-deleted 0)))
      (supertag-relation-delete (plist-get ordinary :id))
      (supertag--process-node-references
       '(:id "source-id" :ref-to ("target-id")) counters)
      (should (= 1 (plist-get counters :references-created)))
      (should (= 3 (length (supertag-text-link-test--relations)))))))

(ert-deftest supertag-text-link-rename-and-reindex-keep-kinds-independent ()
  "Renaming supports recreates only that edge, including after rebuild."
  (supertag-text-link-test--with-vault
    (with-current-buffer (find-file-noselect source-file)
      (org-mode)
      (goto-char (point-min))
      (while (re-search-forward "\\[\\[supports:" nil t)
        (replace-match "[[reinforces:"))
      (save-buffer))
    (supertag-sync--process-single-file
     source-file
     '(:nodes-created 0 :nodes-updated 0 :nodes-deleted 0
       :references-created 0 :references-deleted 0))
    (should-not (supertag-query-named-links-from "source-id" "supports"))
    (should (= 1 (length
                  (supertag-query-named-links-from "source-id" "reinforces"))))
    (should (= 1 (length
                  (supertag-query-named-links-from "source-id" "opposes"))))
    (should (= 1 (length
                  (supertag-reference-service-outgoing "source-id"))))
    (cl-letf (((symbol-function 'supertag-sync-save-state) #'ignore))
      (should (eq 'complete (plist-get (supertag-reindex-org) :status))))
    (should-not (supertag-query-named-links-from "source-id" "supports"))
    (should (= 1 (length
                  (supertag-query-named-links-from "source-id" "reinforces"))))
    (should (= 1 (length
                  (supertag-query-named-links-from "source-id" "opposes"))))))

(ert-deftest supertag-text-link-after-save-async-edits-are-independent ()
  "The daily save queue independently adds, retargets and removes both kinds."
  (supertag-text-link-test--with-vault
    (supertag-text-link-test--save-body-through-async
     source-file "[[id:target-id]]\n[[supports:target-id]]\n")
    (should (= 1 (length (supertag-query-ordinary-references-from "source-id"))))
    (should (= 1 (length (supertag-query-named-links-from
                          "source-id" "supports"))))

    (supertag-text-link-test--save-body-through-async
     source-file "[[id:target-id]]\n[[supports:third-id]]\n")
    (should (equal '("third-id")
                   (mapcar (lambda (relation) (plist-get relation :to))
                           (supertag-query-named-links-from
                            "source-id" "supports"))))

    (supertag-text-link-test--save-body-through-async
     source-file "[[supports:third-id]]\n")
    (should-not (supertag-query-ordinary-references-from "source-id"))
    (should (= 1 (length (supertag-query-named-links-from "source-id"))))

    (supertag-text-link-test--save-body-through-async
     source-file "[[id:target-id]]\n")
    (should (= 1 (length (supertag-query-ordinary-references-from "source-id"))))
    (should-not (supertag-query-named-links-from "source-id"))

    (supertag-text-link-test--save-body-through-async
     source-file "[[id:target-id]]\n")
    (should-not (supertag-query-named-links-from "source-id"))))

(ert-deftest supertag-text-link-unresolved-target-waits-for-rebuild ()
  "A missing target remains a descriptor without inventing a relation."
  (supertag-text-link-test--with-vault
    (supertag-text-link-test--save-body-through-async
     source-file "[[supports:missing-id]]\n")
    (should (equal '((:relation-name "supports" :target-id "missing-id"))
                   (plist-get (supertag-query-node "source-id") :named-links)))
    (should-not (supertag-query-named-links-from "source-id"))))

(ert-deftest supertag-text-link-follow-preserves-navigation-return ()
  "Following delegates the exact target and returns navigation's value."
  (let (seen)
    (cl-letf (((symbol-function 'supertag-goto-node)
               (lambda (node-id) (setq seen node-id) :native-result)))
      (should (eq :native-result
                  (supertag-text-link-follow "target-id" nil)))
      (should (equal "target-id" seen)))))

(ert-deftest supertag-text-link-follow-diagnoses-missing-node-and-file ()
  "Native Org opening reports missing projection identity and location."
  (let ((supertag-text-link-relation-types '("supports"))
        (supertag--store nil))
    (unwind-protect
        (progn
          (supertag--ensure-store)
          (supertag-text-link-refresh)
          (with-temp-buffer
            (org-mode)
            (insert "[[supports:missing-id]]")
            (goto-char (point-min))
            (should-error (org-open-at-point) :type 'user-error))
          (supertag-store-put-entity
           :nodes "no-file" '(:id "no-file" :title "No file" :type :node))
          (with-temp-buffer
            (org-mode)
            (insert "[[supports:no-file]]")
            (goto-char (point-min))
            (should-error (org-open-at-point) :type 'user-error)))
      (supertag-text-link-clear-registrations))))

(ert-deftest supertag-text-link-follow-opens-correct-real-target ()
  "Native Org opening delegates to the retained identity navigator."
  (supertag-text-link-test--with-vault
    (with-temp-buffer
      (org-mode)
      (insert "[[supports:target-id]]")
      (goto-char (point-min))
      (org-open-at-point)
      (should (equal (file-truename target-file)
                     (file-truename (buffer-file-name))))
      (should (equal "target-id" (org-entry-get nil "ID"))))))

(ert-deftest supertag-text-link-file-node-cold-header-and-embed-exclusion ()
  "File-level facts register cold and generated Embed links stay excluded."
  (let* ((tmp (file-name-as-directory
               (file-truename (make-temp-file "supertag-text-header-" t))))
         (source (expand-file-name "a-file.org" tmp))
         (target (expand-file-name "z-target.org" tmp))
         (supertag-data-directory (expand-file-name "data" tmp))
         (supertag-db-file (expand-file-name "store.el" supertag-data-directory))
         (supertag-sync-directories (list tmp))
         (supertag-active-sync-directory tmp)
         (supertag-file-id-source 'org-id)
         (supertag-text-link-relation-types '("supports"))
         (supertag--store nil)
         (supertag-sync--state (list :sync-state
                                     (make-hash-table :test 'equal)))
         (supertag-sync--deferred-files (make-hash-table :test 'equal))
         (supertag-sync--internal-modifications (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (supertag-text-link-clear-registrations)
          (with-temp-file source
            (insert ":PROPERTIES:\n:ID: file-source\n:END:\n"
                    "[[supports:target-id][real]]\n"
                    "#+begin_embed:\n[[supports:embed-only]]\n#+end_embed\n"))
          (with-temp-file target
            (insert ":PROPERTIES:\n:ID: target-id\n:END:\n"))
          (supertag--ensure-store)
          (cl-letf (((symbol-function 'supertag-sync-save-state) #'ignore))
            (should (eq 'complete (plist-get (supertag-reindex-org) :status))))
          (should (= 1 (length (supertag-query-named-links-from
                                "file-source" "supports"))))
          (should (equal "target-id"
                         (plist-get (car (supertag-query-named-links-from
                                          "file-source" "supports")) :to)))
          (should (equal '((:relation-name "supports" :target-id "target-id"))
                         (plist-get (supertag-query-node "file-source")
                                    :named-links)))
          (with-current-buffer (find-file-noselect source)
            (let ((before (buffer-string)))
              (goto-char (point-max))
              (insert "[[supports:third-id][draft]]\n")
              (let ((draft (buffer-string)))
                (supertag-node-sync-current-buffer "file-source")
                (should (equal draft (buffer-string)))
                (should (equal '("target-id" "third-id")
                               (mapcar (lambda (link)
                                         (plist-get link :target-id))
                                       (plist-get
                                        (supertag-query-node "file-source")
                                        :named-links)))))
              (erase-buffer)
              (insert before))))
      (dolist (buffer (buffer-list))
        (when-let* ((file (buffer-file-name buffer)))
          (when (file-in-directory-p file tmp)
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer))))
      (supertag-text-link-clear-registrations)
      (ignore-errors (delete-directory tmp t)))))

(ert-deftest supertag-text-link-property-key-alone-never-projects-name ()
  "A SUPPORTS property containing an ordinary ID link is not a named edge."
  (supertag-text-link-test--with-vault
    (supertag-text-link-test--save-body-through-async
     source-file "[[id:target-id]]\n")
    (should-not (supertag-query-named-links-from "source-id" "supports"))))

(ert-deftest supertag-text-link-reindex-is-read-only-and-automation-suppressed ()
  "Pure rebuild preserves Org bytes and semantic facts without Automation."
  (supertag-text-link-test--with-vault
    (let* ((before-source (with-temp-buffer
                            (insert-file-contents-literally source-file)
                            (buffer-string)))
           (before-target (with-temp-buffer
                            (insert-file-contents-literally target-file)
                            (buffer-string)))
           (semantic (supertag-relation-create
                      '(:type :related :from "source-id" :to "target-id"
                        :kind :semantic-edge :origin :semantic)))
           (automation-calls 0)
           (supertag-automation-sync--enabled t))
      (supertag-subscribe
       :store-changed
       (lambda (&rest _event)
         (when supertag-automation-sync--enabled
           (cl-incf automation-calls))))
      (cl-letf (((symbol-function 'supertag-sync-save-state) #'ignore))
        (should (eq 'complete (plist-get (supertag-reindex-org) :status))))
      (should supertag-automation-sync--enabled)
      (should (= 0 automation-calls))
      (should-not supertag-automation--event-queue)
      (should (supertag-relation-get (plist-get semantic :id)))
      (should (equal before-source
                     (with-temp-buffer
                       (insert-file-contents-literally source-file)
                       (buffer-string))))
      (should (equal before-target
                     (with-temp-buffer
                       (insert-file-contents-literally target-file)
                       (buffer-string)))))))

(ert-deftest supertag-text-link-registration-is-exact-owned-and-conflict-safe ()
  "Configured protocols register idempotently without taking third-party types."
  (let ((supertag-text-link-relation-types '("supports" "opposes")))
    (unwind-protect
        (progn
          (supertag-text-link-refresh)
          (should (assoc "supports" org-link-parameters))
          (supertag-text-link-refresh)
          (let ((owned (copy-tree (assoc "supports" org-link-parameters))))
            (setq supertag-text-link-relation-types '("opposes"))
            (supertag-text-link-refresh)
            (should-not (assoc "supports" org-link-parameters))
            (with-temp-buffer
              (org-mode)
              (insert "[[supports:target-id]]")
              (goto-char (point-min))
              (should-not (equal "supports"
                                 (org-element-property
                                  :type (org-element-context)))))
            (supertag-text-link-clear-registrations)
            (setq org-link-parameters
                  (cons '("supports" :follow ignore)
                        (assoc-delete-all "supports" org-link-parameters)))
            (setq supertag-text-link-relation-types '("opposes" "supports"))
            (should-error (supertag-text-link-refresh))
            (should-not (assoc "opposes" org-link-parameters))
            (should (equal '("supports" :follow ignore)
                           (assoc "supports" org-link-parameters)))
            (should owned)))
      (supertag-text-link-clear-registrations)
      (should (equal '("supports" :follow ignore)
                     (assoc "supports" org-link-parameters)))
      (setq org-link-parameters
            (assoc-delete-all "supports" org-link-parameters)))))

(ert-deftest supertag-text-link-protected-protocol-preflight-is-complete ()
  "Reserved/native protocols fail before a fresh name is registered."
  (dolist (protected '("fuzzy" "coderef" "custom-id" "radio"
                       "id" "file" "http"))
    (let ((supertag-text-link-relation-types (list "review-probe" protected)))
      (unwind-protect
          (progn
            (should-error (supertag-text-link-refresh))
            (should-not (assoc "review-probe" org-link-parameters)))
        (supertag-text-link-clear-registrations)))))

(provide 'text-link-node-view-test)
;;; text-link-node-view-test.el ends here
