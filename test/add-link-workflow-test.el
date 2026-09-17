;;; add-link-workflow-test.el --- Unified Add Link workflow -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'org)
(when load-file-name
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))
(require 'supertag-core-store)
(require 'supertag-node)
(require 'supertag-link)
(require 'supertag-service-org)
(require 'supertag-services-sync)
(require 'supertag-service-org)
(require 'supertag-link)
(require 'supertag-view-node)

(defconst supertag-add-link-test--root
  (expand-file-name ".." (file-name-directory load-file-name)))

(defmacro supertag-add-link-test--isolated (&rest body)
  "Run BODY with isolated Store, Org identity and temporary files."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "supertag-add-link-test-" t))
          (supertag-data-directory tmp)
          (supertag-db-file (expand-file-name "db.el" tmp))
          (supertag-db-backup-directory (expand-file-name "backup" tmp))
          (supertag-sync-directories (list tmp))
          (supertag-sync-directories-mode 'unified)
          (supertag--store nil) (supertag--store-origin nil)
          (org-id-locations nil) (org-id-files nil)
          (org-id-locations-file (expand-file-name "org-id" tmp))
          (supertag-text-link-relation-types nil)
          (supertag-text-link--session-types nil))
     (unwind-protect
         (progn (supertag--ensure-store) ,@body)
       (ignore-errors (supertag-text-link-reset-session))
       (dolist (buffer (buffer-list))
         (when-let ((file (buffer-file-name buffer)))
           (when (string-prefix-p tmp file) (kill-buffer buffer))))
       (ignore-errors (delete-directory tmp t)))))

(defun supertag-add-link-test--write-node (file id title &optional body)
  "Write and project one identified node to FILE."
  (with-temp-file file
    (insert (format "* %s\n:PROPERTIES:\n:ID: %s\n:END:\n%s\n"
                    title id (or body ""))))
  (with-current-buffer (find-file-noselect file)
    (org-mode) (goto-char (point-min)) (supertag-node-sync-at-point)))

(defun supertag-add-link-test--file-string (file)
  "Return FILE's current disk text."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(ert-deftest supertag-add-link-formatter-preserves-ordinary-and-exact-type ()
  (supertag-add-link-test--isolated
    (supertag-node-create '(:id "heading" :title "Heading" :type :node))
    (supertag-node-create '(:id "file" :title "File" :type :node :link-type denote))
    (should (equal "[[id:heading][Text]]" (supertag-node-format-link "heading" "Text")))
    (should (equal "[[denote:file][Text]]" (supertag-node-format-link "file" "Text")))
    (should (equal "[[supports:heading][Text]]"
                   (supertag-node-format-link "heading" "Text" "supports")))))

(ert-deftest supertag-add-link-session-name-registers-without-changing-config ()
  (supertag-add-link-test--isolated
    (supertag-text-link-accept-session-type "supports")
    (should (member "supports" (supertag-text-link-relation-types)))
    (should-not supertag-text-link-relation-types)
    (should (assoc "supports" org-link-parameters))
    (supertag-text-link-refresh)
    (should (assoc "supports" org-link-parameters))))

(ert-deftest supertag-add-link-complete-template-writes-one-node-save ()
  (supertag-add-link-test--isolated
    (let ((file (expand-file-name "concepts.org" tmp)) (saves 0))
      (cl-letf (((symbol-function 'save-buffer)
                 (let ((real (symbol-function 'save-buffer)))
                   (lambda (&rest args) (cl-incf saves) (apply real args)))))
        (let ((id (supertag-service-org-create-node
                   file "Fresh" '("claim")
                   '(:properties (("STAGE" . "ready"))
                     :body "First paragraph.\n\n** Evidence\nBody."
                     :create-file t))))
          (should (stringp id))
          (should (= 1 saves))
          (with-temp-buffer
            (insert-file-contents file)
            (should (re-search-forward "^\\* Fresh #claim$" nil t))
            (should (re-search-forward "^:STAGE:[ \t]+ready$" nil t))
            (should-not (re-search-forward "SUPERTAG_CONCEPT" nil t))
            (should (re-search-forward "^\\*\\* Evidence$" nil t))
            (should-not (re-search-forward "^:ID:" nil t))))))))

(ert-deftest supertag-add-link-template-validation-precedes-file-creation ()
  (supertag-add-link-test--isolated
    (let ((file (expand-file-name "concepts.org" tmp)))
      (should-error
       (supertag-service-org-create-node
        file "Bad" nil '(:properties (("ID" . "injected")) :create-file t))
       :type 'user-error)
      (should-not (file-exists-p file)))))

(ert-deftest supertag-add-link-materializer-checks-requested-identity ()
  (supertag-add-link-test--isolated
    (let ((file (expand-file-name "source.org" tmp)))
      (supertag-add-link-test--write-node file "source" "Source" "Here")
      (supertag-node-create '(:id "target" :title "Target" :type :node))
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-max))
        (let ((beg (copy-marker (point))) (end (copy-marker (point) t)))
          (unwind-protect
              (progn
                (supertag-text-link-accept-session-type "supports")
                (supertag-reference-materialize beg end "target" "Selected words" "supports")
                (should (save-excursion (goto-char (point-min))
                         (re-search-forward "\\[\\[supports:target\\]\\[Selected words\\]\\]" nil t)))
                (let ((relations (supertag-relation-find-between "source" "target" :reference)))
                  (should (= 1 (length relations)))
                  (should (equal "supports" (plist-get (car relations) :relation-name)))))
            (set-marker beg nil) (set-marker end nil)))))))

(ert-deftest supertag-add-link-ordinary-check-rejects-named-only-projection ()
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/tmp/supertag-add-link-source.org")
    (insert "text")
    (let ((beg (copy-marker (point-min)))
          (end (copy-marker (point-max) t)))
      (cl-letf (((symbol-function 'save-buffer) #'ignore)
                ((symbol-function 'supertag-ui--reproject-containing-node) #'ignore)
                ((symbol-function 'supertag-relation-find-between)
                 (lambda (&rest _)
                   '((:type :reference :kind :document-link :origin :org
                      :relation-name "supports")))))
        (should-error
         (supertag-ui--replace-region-with-reference
          beg end "source" "target" "text")
         :type 'supertag-link-error)))))

(ert-deftest supertag-add-link-command-preserves-region-description ()
  (supertag-add-link-test--isolated
    (let ((file (expand-file-name "source.org" tmp)))
      (supertag-add-link-test--write-node file "source" "Source" "original words")
      (supertag-node-create '(:id "target" :title "Canonical title" :type :node))
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-min)) (search-forward "original words")
        (set-mark (match-beginning 0)) (goto-char (match-end 0))
        (setq mark-active t transient-mark-mode t)
        (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                   (lambda (&rest _)
                     (cons "Canonical title"
                           (propertize "Canonical title"
                                      'supertag-reference-node-id "target"
                                      'supertag-reference-title "Canonical title")))))
          (supertag-add-link nil))
        (should (save-excursion (goto-char (point-min))
                 (re-search-forward "\\[\\[id:target\\]\\[original words\\]\\]" nil t)))))))

(ert-deftest supertag-add-link-command-named-save-query-and-node-view ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "target.org" tmp)))
      (supertag-add-link-test--write-node source "source" "Source" "claim")
      (supertag-add-link-test--write-node target "target" "Target")
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-max))
        (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                   (lambda (&rest _)
                     (cons "Target"
                           (propertize "Target"
                                      'supertag-reference-node-id "target"
                                      'supertag-reference-title "Target"))))
                  ((symbol-function 'supertag-reference--read-link-type)
                   (lambda () "supports")))
          (supertag-add-link t)))
      (should (= 1 (length (supertag-query-named-links-from
                            "source" "supports"))))
      (with-temp-buffer
        (supertag-view-node--render-from-state
         (supertag-view-build-node-state "source"))
        (should (string-match-p "supports" (buffer-string)))
        (should (string-match-p "Target" (buffer-string)))))))

(ert-deftest supertag-add-link-cancel-precedes-source-or-target-writes ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "concepts.org" tmp)))
      (with-temp-file source (insert "* Source\nDraft text.\n"))
      (let ((before (with-temp-buffer
                      (insert-file-contents-literally source)
                      (buffer-string))))
        (with-current-buffer (find-file-noselect source)
          (org-mode) (goto-char (point-max))
          (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                     (lambda (&rest _) (user-error "cancelled"))))
            (should-error (supertag-add-link nil) :type 'user-error)))
        (should-not (file-exists-p target))
        (with-temp-buffer
          (insert-file-contents-literally source)
          (should (equal before (buffer-string))))))))

(ert-deftest supertag-add-link-template-cancel-precedes-source-identity ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp)))
      (with-temp-file source (insert "* Source\nnew target\n"))
      (with-current-buffer (find-file-noselect source)
        (org-mode) (goto-char (point-max))
        (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                   (lambda (&rest _)
                     (cons "New"
                           (propertize "New [Create]"
                                      'supertag-reference-create-title "New"))))
                  ((symbol-function 'supertag-template-read)
                   (lambda () (user-error "template cancelled"))))
          (should-error (supertag-add-link nil) :type 'user-error)))
      (with-temp-buffer
        (insert-file-contents source)
        (should-not (re-search-forward "^:ID:" nil t))))))

(ert-deftest supertag-add-link-relation-cancel-precedes-source-identity ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp)))
      (with-temp-file source (insert "* Source\nlink here\n"))
      (supertag-node-create '(:id "target" :title "Target" :type :node))
      (with-current-buffer (find-file-noselect source)
        (org-mode) (goto-char (point-max))
        (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                   (lambda (&rest _)
                     (cons "Target"
                           (propertize "Target"
                                      'supertag-reference-node-id "target"
                                      'supertag-reference-title "Target"))))
                  ((symbol-function 'supertag-reference--read-link-type)
                   (lambda () (user-error "relation cancelled"))))
          (should-error (supertag-add-link t) :type 'user-error)))
      (should-not supertag-text-link--session-types)
      (with-temp-buffer
        (insert-file-contents source)
        (should-not (re-search-forward "^:ID:" nil t))))))

(ert-deftest supertag-add-link-explicit-create-never-reuses-same-title ()
  (supertag-add-link-test--isolated
    (let ((file (expand-file-name "concepts.org" tmp))
          (ids '("first-id" "second-id")))
      (with-temp-file file)
      (cl-letf (((symbol-function 'supertag-node-identity-new)
                 (lambda () (pop ids))))
        (let ((first (supertag-service-org-create-node file "Same" nil))
              (second (supertag-service-org-create-node file "Same" nil)))
          (should (equal '("first-id" "second-id") (list first second))))))))

(ert-deftest supertag-add-link-explicit-create-candidate-bypasses-same-title ()
  (supertag-add-link-test--isolated
    (supertag-node-create '(:id "existing" :title "Same" :type :node))
    (let ((selected (propertize "Same [Create]"
                                'supertag-reference-create-title "Same"))
          created)
      (cl-letf (((symbol-function 'supertag-reference--create-from-template)
                 (lambda (title _template)
                   (setq created title)
                   "fresh")))
        (should (equal '("fresh" . "Same")
                       (supertag-reference--resolve-or-create
                        "Same" selected nil '(:preset t)))))
      (should (equal "Same" created)))))

(ert-deftest supertag-add-link-source-failure-reports-retained-target ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "concepts.org" tmp))
          payload)
      (supertag-add-link-test--write-node source "source" "Source" "text")
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-max))
        (let ((real-save (symbol-function 'save-buffer)) (fail t))
          (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                   (lambda (&rest _)
                     (cons "Fresh"
                           (propertize "Fresh [Create]"
                                      'supertag-reference-create-title "Fresh"))))
                  ((symbol-function 'supertag-template-read)
                   (lambda () (list :key "c" :name "Concept"
                                    :target-file target :tags nil
                                    :properties nil :body "")))
                  ((symbol-function 'supertag-node-identity-new)
                   (lambda () "retained-id"))
                  ((symbol-function 'supertag-reference--read-link-type)
                   (lambda () "supports"))
                  ((symbol-function 'save-buffer)
                   (lambda (&rest args)
                     (if (and fail (equal (buffer-file-name) source))
                         (progn (setq fail nil) (error "source save failed"))
                       (apply real-save args)))))
            (condition-case data
                (supertag-add-link t)
              (supertag-link-error (setq payload (cdr data))))
            (should (equal :source-save (plist-get payload :stage)))
            (should (equal "retained-id" (plist-get payload :target-id)))
            (should (file-exists-p target))
            (should (supertag-node-get "retained-id"))
            (should-not (member "supports" supertag-text-link--session-types))
            (apply (plist-get payload :retry) (plist-get payload :retry-args))))
        (should (= 1 (length (supertag-relation-find-between
                              "source" "retained-id" :reference))))))))

(ert-deftest supertag-add-link-is-the-only-interactive-reference-entry ()
  (should (commandp 'supertag-add-link))
  (dolist (symbol '(supertag-add-reference supertag-add-reference-and-create
                    supertag-reference-insert supertag-reference-link-region
                    supertag-reference-create-or-link))
    (should-not (commandp symbol))))

(ert-deftest supertag-add-link-configured-name-survives-fresh-reindex-and-view ()
  (let* ((tmp (make-temp-file "supertag-add-link-restart-" t))
         (source (expand-file-name "source.org" tmp))
         (target (expand-file-name "target.org" tmp))
         (program (expand-file-name invocation-name invocation-directory)))
    (unwind-protect
        (progn
          (with-temp-file source
            (insert "* Source\n:PROPERTIES:\n:ID: source\n:END:\n"
                    "[[supports:target][supports target]]\n"))
          (with-temp-file target
            (insert "* Target\n:PROPERTIES:\n:ID: target\n:END:\n"))
          (with-temp-buffer
            (let ((status
                   (call-process
                    program nil t nil "-Q" "--batch"
                    "--eval"
                    (format
                     "%S"
                     `(progn
                        (require 'package)
                        (setq user-emacs-directory ,tmp
                              supertag-data-directory ,(expand-file-name "data" tmp)
                              supertag-db-file ,(expand-file-name "db.el" tmp)
                              supertag-db-backup-directory ,(expand-file-name "backup" tmp)
                              supertag-sync-state-file ,(expand-file-name "sync.el" tmp)
                              org-id-locations-file ,(expand-file-name "org-id" tmp)
                              supertag-sync-directories (list ,tmp)
                              supertag-sync-directories-mode 'unified
                              supertag-text-link-relation-types '("supports"))
                        (package-initialize)
                        (add-to-list 'load-path ,supertag-add-link-test--root)
                        (require 'supertag-services-sync)
                        (require 'supertag-query)
                        (require 'supertag-view-node)
                        (supertag--ensure-store)
                        (supertag-reindex-org)
                        (unless (= 1 (length (supertag-query-named-links-from
                                              "source" "supports")))
                          (error "Configured relation missing after restart"))
                        (with-temp-buffer
                          (supertag-view-node--render-from-state
                           (supertag-view-build-node-state "source"))
                          (unless (string-match-p "supports" (buffer-string))
                            (error "Configured relation missing in Node View"))))))))
              (unless (zerop status)
                (ert-fail (buffer-string))))))
      (ignore-errors (delete-directory tmp t)))))

(ert-deftest supertag-add-link-reader-offers-explicit-create-for-same-title ()
  (supertag-add-link-test--isolated
    (supertag-node-create '(:id "existing" :title "Same" :type :node))
    (let (offered)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered (mapcar #'car collection))
                   (or (car (cl-find-if
                             (lambda (entry)
                               (get-text-property
                                0 'supertag-reference-create-title (cdr entry)))
                             collection))
                       ""))))
        (let ((result (supertag-reference--read-candidate "Same" nil)))
          (should (get-text-property
                   0 'supertag-reference-create-title (cdr result)))))
      (should (cl-some (lambda (label)
                         (string-match-p "Create new" label))
                       offered)))))

(ert-deftest supertag-add-link-public-reader-creates-same-title-fresh-node ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "concepts.org" tmp))
          (ids '("fresh-id")))
      (supertag-add-link-test--write-node source "source" "Source" "Same")
      (supertag-add-link-test--write-node target "existing" "Same")
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-min))
        (search-forward "Same")
        (set-mark (match-beginning 0))
        (activate-mark)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt collection &rest _)
                     (cond
                      ((string-prefix-p "Reference" prompt)
                       (car (cl-find-if
                             (lambda (entry)
                               (get-text-property
                                0 'supertag-reference-create-title (cdr entry)))
                             collection)))
                      ((string-prefix-p "Creation template" prompt)
                       (caar collection))
                      (t (ert-fail (format "Unexpected prompt: %s" prompt))))))
                  ((symbol-function 'supertag-node-identity-new)
                   (lambda () (or (pop ids) (ert-fail "extra identity")))))
          (let ((supertag-creation-templates
                 (list (list :key "c" :name "Concept" :target-file target
                             :tags nil :properties nil :body ""))))
            (should (equal "fresh-id" (supertag-add-link nil))))))
      (with-temp-buffer
        (insert-file-contents target)
        (should (= 2 (how-many "^\\* Same$" (point-min) (point-max)))))
      (should (string-match-p "\\[\\[id:fresh-id\\]\\[Same\\]\\]"
                              (supertag-add-link-test--file-string source))))))

(ert-deftest supertag-add-link-standalone-template-uses-active-vault ()
  (let* ((tmp (make-temp-file "supertag-template-vault-" t))
         (vault-a (expand-file-name "a" tmp))
         (vault-b (expand-file-name "b" tmp))
         (program (expand-file-name invocation-name invocation-directory)))
    (unwind-protect
        (progn
          (make-directory vault-a)
          (make-directory vault-b)
          (with-temp-buffer
            (let ((status
                   (call-process
                    program nil t nil "-Q" "--batch" "--eval"
                    (format
                     "%S"
                     `(progn
                        (require 'package)
                        (setq user-emacs-directory ,tmp
                              supertag-sync-directories (list ,vault-a ,vault-b)
                              supertag-sync-directories-mode 'vaults
                              supertag-active-sync-directory ,vault-b)
                        (package-initialize)
                        (add-to-list 'load-path ,supertag-add-link-test--root)
                        (require 'supertag-service-org)
                        (when (featurep 'supertag)
                          (error "Root package loaded unexpectedly"))
                        (unless (equal ,(expand-file-name
                                         "concepts.org" (file-truename vault-b))
                                       (supertag-template--default-file))
                          (error "Wrong standalone vault target")))))))
              (unless (zerop status) (ert-fail (buffer-string))))))
      (ignore-errors (delete-directory tmp t)))))

(ert-deftest supertag-add-link-template-rejects-stale-active-vault ()
  (let* ((tmp (make-temp-file "supertag-template-stale-vault-" t))
         (configured (expand-file-name "configured" tmp))
         (stale (expand-file-name "stale" tmp))
         (program (expand-file-name invocation-name invocation-directory)))
    (unwind-protect
        (progn
          (make-directory configured)
          (make-directory stale)
          (with-temp-buffer
            (let ((status
                   (call-process
                    program nil t nil "-Q" "--batch" "--eval"
                    (format
                     "%S"
                     `(progn
                        (require 'package)
                        (setq user-emacs-directory ,tmp
                              package-enable-at-startup nil)
                        (package-initialize)
                        (add-to-list 'load-path ,supertag-add-link-test--root)
                        (setq supertag-sync-directories (list ,configured)
                              supertag-sync-directories-mode 'vaults
                              supertag-active-sync-directory ,stale
                              supertag-concept-default-file nil)
                        (require 'supertag-service-org)
                        (let ((actual (supertag-template--default-file)))
                          (let ((after-init-time nil))
                            (require 'supertag))
                          (unless (equal
                                   ,(expand-file-name
                                     "concepts.org" (file-truename configured))
                                   actual)
                            (error "Stale active vault was selected: %S via %S"
                                   actual
                                   (locate-library
                                    "supertag-service-org")))
                          (unless (equal
                                   (file-name-directory actual)
                                   (supertag-vault--effective-root))
                            (error "Root and standalone vault selection differ"))))))))
              (unless (zerop status) (ert-fail (buffer-string))))))
      (ignore-errors (delete-directory tmp t)))))

(ert-deftest supertag-add-link-vault-selection-is-shared-with-root-authority ()
  (supertag-add-link-test--isolated
    (let* ((vault-a (expand-file-name "a" tmp))
           (vault-b (expand-file-name "b" tmp))
           (stale (expand-file-name "stale" tmp))
           (directories (list vault-a vault-b)))
      (dolist (directory (append directories (list stale)))
        (make-directory directory))
      (should (equal
               (list (supertag-vault-selection-normalize-path vault-a))
               (supertag-vault-selection-effective-directories
                'vaults directories stale)))
      (should (equal
               (list (supertag-vault-selection-normalize-path vault-b))
               (supertag-vault-selection-effective-directories
                'vaults directories vault-b)))
      (should (equal directories
                     (supertag-vault-selection-effective-directories
                      'unified directories stale))))))

(ert-deftest supertag-add-link-command-preserves-raw-region-whitespace ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          captured)
      (supertag-add-link-test--write-node
       source "source" "Source" "alpha  beta\n  gamma")
      (supertag-node-create '(:id "target" :title "Target" :type :node))
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-min))
        (search-forward "alpha")
        (set-mark (match-beginning 0))
        (search-forward "gamma")
        (activate-mark)
        (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                   (lambda (&rest _)
                     (cons "Target"
                           (propertize "Target"
                                      'supertag-reference-node-id "target"
                                      'supertag-reference-title "Target"))))
                  ((symbol-function 'supertag-reference-materialize)
                   (lambda (_beg _end _id description &optional _type)
                     (setq captured description))))
          (supertag-add-link nil)))
      (should (equal "alpha  beta\n  gamma" captured)))))

(ert-deftest supertag-add-link-template-rejects-child-identity-before-mutation ()
  (supertag-add-link-test--isolated
    (let ((file (expand-file-name "concepts.org" tmp)))
      (with-temp-file file (insert "#+title: Existing\n"))
      (let ((before (with-temp-buffer
                      (insert-file-contents file)
                      (buffer-string))))
        (should-error
         (supertag-service-org-create-node
          file "Fresh" nil
          '(:body "Prose.\n\n** Child\n:PROPERTIES:\n:ID: injected\n:END:\n"
            :create-file t))
         :type 'user-error)
        (should (equal before
                       (with-temp-buffer
                         (insert-file-contents file)
                         (buffer-string)))))))

(ert-deftest supertag-add-link-template-preflights-native-properties ()
  (supertag-add-link-test--isolated
    (dolist (properties '((("END" . "bad"))
                          (("ITEM" . "bad"))
                          (("TODO" . "NOT-A-TODO"))))
      (let ((file (expand-file-name
                   (format "bad-%s.org" (caar properties)) tmp)))
        (with-temp-file file (insert "#+title: Existing\n"))
        (let ((before (with-temp-buffer
                        (insert-file-contents file)
                        (buffer-string))))
          (should-error
           (supertag-service-org-create-node
            file "Fresh" nil
            (list :properties properties :body "Body" :create-file t))
           :type 'user-error)
          (should (equal before
                         (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string))))))))))

(ert-deftest supertag-add-link-template-allows-prose-code-and-unidentified-child ()
  (supertag-add-link-test--isolated
    (let ((file (expand-file-name "concepts.org" tmp)))
      (with-temp-file file)
      (should
       (supertag-service-org-create-node
        file "Fresh" nil
        '(:body "Prose :ID: example.\n\n#+begin_src org\n** code example\n:ID: sample\n#+end_src\n\n** Real child\nNo identity."
          :create-file t)))
      (let ((text (supertag-add-link-test--file-string file)))
        (should (string-match-p "Prose :ID: example" text))
        (should (string-match-p "#\\+begin_src org" text))
        (should (string-match-p "^\\*\\* Real child$" text))))))

(ert-deftest supertag-add-link-failed-target-does-not-register-session-name ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "concepts.org" tmp)))
      (supertag-add-link-test--write-node source "source" "Source" "text")
      (supertag-text-link-accept-session-type "kept")
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-max))
        (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                   (lambda (&rest _)
                     (cons "Fresh"
                           (propertize "Fresh [Create]"
                                      'supertag-reference-create-title "Fresh"))))
                  ((symbol-function 'supertag-template-read)
                   (lambda () (list :key "c" :name "Concept"
                                    :target-file target :tags nil
                                    :properties '(("END" . "bad"))
                                    :body "")))
                  ((symbol-function 'supertag-reference--read-link-type)
                   (lambda () "supports")))
          (should-error (supertag-add-link t) :type 'user-error)))
      (should-not (member "supports" supertag-text-link--session-types))
      (should (member "kept" supertag-text-link--session-types)))))

(ert-deftest supertag-add-link-validates-file-level-source-read-only ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp)))
      (with-temp-file source
        (insert ":PROPERTIES:\n:ID: file-source\n:END:\nprose\n"))
      (with-current-buffer (find-file-noselect source)
        (org-mode)
        (goto-char (point-max))
        (let ((marker (point-marker)))
          (unwind-protect
              (should (supertag-reference--validate-source marker))
            (set-marker marker nil)))))))

(ert-deftest supertag-add-link-idless-heading-source-is-read-only-until-selection ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp)))
      (with-temp-file source (insert "* Source\ntext\n"))
      (with-current-buffer (find-file-noselect source)
        (org-mode)
        (goto-char (point-max))
        (let ((marker (point-marker)))
          (unwind-protect
              (progn
                (should (supertag-reference--validate-source marker))
                (should-not (org-entry-get nil "ID" nil)))
            (set-marker marker nil)))))))

(ert-deftest supertag-add-link-idless-heading-existing-target-gets-source-id ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "target.org" tmp)))
      (with-temp-file source (insert "* Source\ntext\n"))
      (supertag-add-link-test--write-node target "target" "Target")
      (with-current-buffer (find-file-noselect source)
        (org-mode)
        (goto-char (point-max))
        (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                   (lambda (&rest _)
                     (cons "Target"
                           (propertize "Target"
                                      'supertag-reference-node-id "target"
                                      'supertag-reference-title "Target")))))
          (should (equal "target" (supertag-add-link nil))))
        (goto-char (point-min))
        (should (org-entry-get nil "ID" nil)))
      (should (string-match-p "\\[\\[id:target\\]\\[Target\\]\\]"
                              (supertag-add-link-test--file-string source))))))

(ert-deftest supertag-add-link-idless-heading-new-target-and-cancel-boundaries ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "concepts.org" tmp)))
      (with-temp-file source (insert "* Source\ntext\n"))
      (with-current-buffer (find-file-noselect source)
        (org-mode)
        (goto-char (point-max))
        (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                   (lambda (&rest _) (signal 'quit nil))))
          (let ((cancelled nil))
            (condition-case nil
                (supertag-add-link nil)
              (quit (setq cancelled t)))
            (should cancelled)))
        (goto-char (point-min))
        (should-not (org-entry-get nil "ID" nil))
        (goto-char (point-max))
        (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                   (lambda (&rest _)
                     (cons "Fresh"
                           (propertize "Fresh  [Create new node]"
                                      'supertag-reference-create-title "Fresh"))))
                  ((symbol-function 'supertag-template-read)
                   (lambda () (list :key "c" :name "Concept"
                                    :target-file target :tags nil
                                    :properties nil :body ""))))
          (let (failure result)
            (condition-case data
                (setq result (supertag-add-link nil))
              (supertag-link-error (setq failure (cdr data))))
            (should-not failure)
            (should (stringp result))))
        (goto-char (point-min))
        (should (org-entry-get nil "ID" nil)))
      (should (file-exists-p target)))))

(ert-deftest supertag-add-link-template-rejects-sibling-identity-before-mutation ()
  (supertag-add-link-test--isolated
    (let ((file (expand-file-name "concepts.org" tmp)))
      (with-temp-file file (insert "#+title: Existing\n"))
      (let ((before (supertag-add-link-test--file-string file)))
        (should-error
         (supertag-service-org-create-node
          file "Fresh" nil
          '(:body "Intro.\n\n* Sibling\n:PROPERTIES:\n:ID: duplicate\n:END:\n"
            :create-file t))
         :type 'user-error)
        (should (equal before (supertag-add-link-test--file-string file)))))))

(ert-deftest supertag-add-link-template-allows-unidentified-sibling ()
  (supertag-add-link-test--isolated
    (let ((file (expand-file-name "concepts.org" tmp)))
      (should
       (supertag-service-org-create-node
        file "Fresh" nil
        '(:body "Intro.\n\n* Sibling\nOrdinary prose and =:ID:= example.\n"
          :create-file t)))
      (let ((text (supertag-add-link-test--file-string file)))
        (should (string-match-p "^\\* Sibling$" text))
        (should (string-match-p "Ordinary prose and =:ID:= example" text))))))

(ert-deftest supertag-add-link-public-template-persists-complete-content ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "concepts.org" tmp)))
      (supertag-add-link-test--write-node source "source" "Source" "selection")
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-min))
        (search-forward "selection")
        (set-mark (match-beginning 0))
        (activate-mark)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt collection &rest _)
                     (cond
                      ((string-prefix-p "Reference" prompt)
                       (car (cl-find-if
                             (lambda (entry)
                               (get-text-property
                                0 'supertag-reference-create-title (cdr entry)))
                             collection)))
                      ((string-prefix-p "Creation template" prompt)
                       (caar collection))
                      (t (ert-fail (format "Unexpected prompt: %s" prompt))))))
                  ((symbol-function 'supertag-node-identity-new)
                   (lambda () "public-template-id")))
          (let ((supertag-creation-templates
                 (list (list :key "n" :name "Note" :target-file target
                             :tags '("claim")
                             :properties '(("STAGE" . "ready"))
                             :body "Intro.\n\n** Child\nChild body."))))
            (should (equal "public-template-id" (supertag-add-link nil))))))
      (let ((text (supertag-add-link-test--file-string target)))
        (should (string-match-p "^\\* selection #claim$" text))
        (should (string-match-p "^:STAGE:[ \t]+ready$" text))
        (should (string-match-p "^:ID:[ \t]+public-template-id$" text))
        (should (string-match-p "^Intro\\.$" text))
        (should (string-match-p "^\\*\\* Child$" text))
        (with-temp-buffer
          (insert text)
          (should (= 1 (how-many "^:ID:" (point-min) (point-max))))))
      (should (= 1 (length (supertag-relation-find-between
                            "source" "public-template-id" :reference))))
      (with-temp-buffer
        (supertag-view-node--render-from-state
         (supertag-view-build-node-state "source"))
        (should (string-match-p "selection" (buffer-string)))))))

(ert-deftest supertag-add-link-public-command-supports-file-level-source ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "target.org" tmp)))
      (with-temp-file source
        (insert ":PROPERTIES:\n:ID: file-source\n:END:\nprose\n"))
      (supertag-add-link-test--write-node target "target" "Target")
      (with-current-buffer (find-file-noselect source)
        (org-mode)
        (goto-char (point-max))
        (supertag-ui--ensure-file-node-synced source)
        (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                   (lambda (&rest _)
                     (cons "Target"
                           (propertize "Target"
                                      'supertag-reference-node-id "target"
                                      'supertag-reference-title "Target")))))
          (should (equal "target" (supertag-add-link nil)))))
      (should (string-match-p "\\[\\[id:target\\]\\[Target\\]\\]"
                              (supertag-add-link-test--file-string source)))
      (should (= 1 (length (supertag-relation-find-between
                            "file-source" "target" :reference)))))))

(ert-deftest supertag-add-link-source-save-error-is-retryable-without-duplicate ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp)) payload)
      (supertag-add-link-test--write-node source "source" "Source" "text")
      (supertag-node-create '(:id "target" :title "Target" :type :node))
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-max))
        (let ((real-save (symbol-function 'save-buffer)) (failures 2))
          (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                     (lambda (&rest _)
                       (cons "Target"
                             (propertize "Target"
                                        'supertag-reference-node-id "target"
                                        'supertag-reference-title "Target"))))
                    ((symbol-function 'save-buffer)
                     (lambda (&rest args)
                       (if (> failures 0)
                           (progn (cl-decf failures) (error "source save"))
                         (apply real-save args)))))
            (condition-case data
                (supertag-add-link nil)
              (supertag-link-error (setq payload (cdr data))))
            (should (eq :source-save (plist-get payload :stage)))
            (should (equal source (plist-get payload :file)))
            (should (equal "source" (plist-get payload :source-id)))
            (should (equal "target" (plist-get payload :target-id)))
            (should (buffer-modified-p))
            (should-not (supertag-reference-recovery-complete-p payload))
            (should-error
             (apply (plist-get payload :retry)
                    (plist-get payload :retry-args)))
            (should-not (supertag-reference-recovery-complete-p payload))
            (should (equal "target"
                           (apply (plist-get payload :retry)
                                  (plist-get payload :retry-args))))
            (should (supertag-reference-recovery-complete-p payload)))))
      (let ((text (supertag-add-link-test--file-string source)))
        (with-temp-buffer
          (insert text)
          (should (= 1 (how-many "\\[\\[id:target\\]"
                                 (point-min) (point-max)))))))))

(ert-deftest supertag-add-link-source-projection-error-retries-saved-fact ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp)) payload)
      (supertag-add-link-test--write-node source "source" "Source" "text")
      (supertag-node-create '(:id "target" :title "Target" :type :node))
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-max))
        (let ((real-project (symbol-function 'supertag-ui--reproject-containing-node))
              (fail t))
          (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                     (lambda (&rest _)
                       (cons "Target"
                             (propertize "Target"
                                        'supertag-reference-node-id "target"
                                        'supertag-reference-title "Target"))))
                    ((symbol-function 'supertag-reference--read-link-type)
                     (lambda () "supports"))
                    ((symbol-function 'supertag-ui--reproject-containing-node)
                     (lambda (id)
                       (if fail (progn (setq fail nil) (error "source project"))
                         (funcall real-project id)))))
            (condition-case data
                (supertag-add-link t)
              (supertag-link-error (setq payload (cdr data))))
            (should (eq :source-project (plist-get payload :stage)))
            (should (equal source (plist-get payload :file)))
            (should (equal "source" (plist-get payload :source-id)))
            (should (equal "target" (plist-get payload :target-id)))
            (should-not (buffer-modified-p))
            (should (member "supports" supertag-text-link--session-types))
            (should-not (supertag-reference-recovery-complete-p payload))
            (should (equal "target"
                           (apply (plist-get payload :retry)
                                  (plist-get payload :retry-args))))
            (should (supertag-reference-recovery-complete-p payload)))))
      (should (= 1 (length (supertag-query-named-links-from
                            "source" "supports")))))))

(ert-deftest supertag-add-link-recovery-operations-are-isolated ()
  (supertag-add-link-test--isolated
    (let ((one (expand-file-name "one.org" tmp))
          (two (expand-file-name "two.org" tmp)) payload-one payload-two)
      (supertag-add-link-test--write-node one "one" "One" "text")
      (supertag-add-link-test--write-node two "two" "Two" "text")
      (supertag-node-create '(:id "target" :title "Target" :type :node))
      (dolist (entry `((,one . payload-one) (,two . payload-two)))
        (with-current-buffer (find-file-noselect (car entry))
          (goto-char (point-max))
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest _) (error "source save"))))
            (condition-case data
                (supertag-reference-materialize-at-point "target" "Target")
              (supertag-link-error
               (if (eq (cdr entry) 'payload-one)
                   (setq payload-one (cdr data))
                 (setq payload-two (cdr data))))))))
      (should-not (eq (plist-get payload-one :recovery-operation)
                      (plist-get payload-two :recovery-operation)))
      (should-not (supertag-reference-recovery-complete-p payload-one))
      (should-not (supertag-reference-recovery-complete-p payload-two))
      (should (equal "target"
                     (apply (plist-get payload-one :retry)
                            (plist-get payload-one :retry-args))))
      (should (supertag-reference-recovery-complete-p payload-one))
      (should-not (supertag-reference-recovery-complete-p payload-two)))))

(ert-deftest supertag-add-link-source-save-retry-stages-later-projection-failure ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp)) payload retry-payload)
      (supertag-add-link-test--write-node source "source" "Source" "text")
      (supertag-node-create '(:id "target" :title "Target" :type :node))
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-max))
        (let ((real-save (symbol-function 'save-buffer))
              (real-project
               (symbol-function 'supertag-reference-retry-source-projection))
              (save-fail t)
              (project-fail t))
          (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                     (lambda (&rest _)
                       (cons "Target"
                             (propertize "Target"
                                        'supertag-reference-node-id "target"
                                        'supertag-reference-title "Target"))))
                    ((symbol-function 'supertag-reference--read-link-type)
                     (lambda () "supports"))
                    ((symbol-function 'save-buffer)
                     (lambda (&rest args)
                       (if save-fail
                           (progn (setq save-fail nil) (error "source save"))
                         (apply real-save args))))
                    ((symbol-function 'supertag-reference-retry-source-projection)
                     (lambda (&rest args)
                       (if project-fail
                           (progn (setq project-fail nil)
                                  (error "retry projection"))
                         (apply real-project args)))))
            (condition-case data
                (supertag-add-link t)
              (supertag-link-error (setq payload (cdr data))))
            (should (eq :source-save (plist-get payload :stage)))
            (condition-case data
                (apply (plist-get payload :retry)
                       (plist-get payload :retry-args))
              (supertag-link-error (setq retry-payload (cdr data))))
            (should-not (supertag-reference-recovery-complete-p payload))
            (should (eq :source-project (plist-get retry-payload :stage)))
            (should (equal "source" (plist-get retry-payload :source-id)))
            (should (equal "target" (plist-get retry-payload :target-id)))
            (should (equal source (plist-get retry-payload :file)))
            (should (plist-get retry-payload :cause))
            (should (eq (plist-get payload :recovery-operation)
                        (plist-get retry-payload :recovery-operation)))
            (should (member "supports" supertag-text-link--session-types))
            (should (equal "target"
                           (apply (plist-get retry-payload :retry)
                                  (plist-get retry-payload :retry-args))))
            (should (supertag-reference-recovery-complete-p payload))
            (should (supertag-reference-recovery-complete-p retry-payload)))))
      (should (= 1 (length (supertag-query-named-links-from
                            "source" "supports"))))
      (with-temp-buffer
        (insert-file-contents source)
        (should (= 1 (how-many "\\[\\[supports:target\\]"
                               (point-min) (point-max))))))))

(ert-deftest supertag-add-link-target-save-error-retries-same-created-id ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "concepts.org" tmp)) payload)
      (supertag-add-link-test--write-node source "source" "Source" "text")
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-max))
        (let ((real-save (symbol-function 'save-buffer)) (fail t))
          (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                     (lambda (&rest _)
                       (cons "Fresh"
                             (propertize "Fresh [Create]"
                                        'supertag-reference-create-title "Fresh"))))
                    ((symbol-function 'supertag-template-read)
                     (lambda () (list :key "c" :name "Concept"
                                      :target-file target :tags nil
                                      :properties nil :body "")))
                    ((symbol-function 'supertag-reference--read-link-type)
                     (lambda () "supports"))
                    ((symbol-function 'supertag-node-identity-new)
                     (lambda () "retained-target"))
                    ((symbol-function 'save-buffer)
                     (lambda (&rest args)
                       (if (and fail (equal (buffer-file-name) target))
                           (progn (setq fail nil) (error "target save"))
                         (apply real-save args)))))
            (condition-case data
                (supertag-add-link t)
              (supertag-link-error (setq payload (cdr data))))
            (should (eq :target-save (plist-get payload :stage)))
            (should (equal "retained-target" (plist-get payload :node-id)))
            (should (equal target (plist-get payload :file)))
            (should (plist-get payload :cause))
            (should-not (member "supports" supertag-text-link--session-types))
            (should (equal "retained-target"
                           (apply (plist-get payload :retry)
                                  (plist-get payload :retry-args)))))))
      (with-temp-buffer
        (insert-file-contents target)
        (should (= 1 (how-many "^:ID:[ \t]+retained-target$"
                               (point-min) (point-max))))))))

(ert-deftest supertag-add-link-target-projection-error-retries-durable-node ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "concepts.org" tmp)) payload)
      (supertag-add-link-test--write-node source "source" "Source" "text")
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-max))
        (let ((real-project
               (symbol-function 'supertag-service-org--project-current-node))
              (fail t))
          (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                     (lambda (&rest _)
                       (cons "Fresh"
                             (propertize "Fresh [Create]"
                                        'supertag-reference-create-title "Fresh"))))
                    ((symbol-function 'supertag-template-read)
                     (lambda () (list :key "c" :name "Concept"
                                      :target-file target :tags nil
                                      :properties nil :body "")))
                    ((symbol-function 'supertag-reference--read-link-type)
                     (lambda () "supports"))
                    ((symbol-function 'supertag-node-identity-new)
                     (lambda () "durable-target"))
                    ((symbol-function 'supertag-service-org--project-current-node)
                     (lambda (id)
                       (if (and fail (equal id "durable-target"))
                           (progn (setq fail nil) (error "target project"))
                         (funcall real-project id)))))
            (condition-case data
                (supertag-add-link t)
              (supertag-link-error (setq payload (cdr data))))
            (should (eq :target-project (plist-get payload :stage)))
            (should (equal "durable-target" (plist-get payload :node-id)))
            (should (equal target (plist-get payload :file)))
            (should-not (member "supports" supertag-text-link--session-types))
            (should (string-match-p "durable-target"
                                    (supertag-add-link-test--file-string target)))
            (apply (plist-get payload :retry) (plist-get payload :retry-args)))))
      (should (supertag-node-get "durable-target")))))

(ert-deftest supertag-add-link-capf-uses-staged-target-save-boundary ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "concepts.org" tmp)) payload)
      (supertag-add-link-test--write-node source "source" "Source" "[[Fresh")
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-max))
        (search-backward "[[Fresh")
        (let ((open-marker (copy-marker (point)))
              (real-save (symbol-function 'save-buffer)))
          (unwind-protect
              (cl-letf (((symbol-function 'supertag-template-read)
                         (lambda () (list :key "c" :name "Concept"
                                          :target-file target :tags nil
                                          :properties nil :body "")))
                        ((symbol-function 'supertag-node-identity-new)
                         (lambda () "capf-target"))
                        ((symbol-function 'save-buffer)
                         (lambda (&rest args)
                           (if (equal (buffer-file-name) target)
                               (error "capf target save")
                             (apply real-save args)))))
                (condition-case data
                    (supertag-reference--post-completion
                     (propertize "Fresh [Create]"
                                'supertag-reference-create-title "Fresh")
                     'finished open-marker)
                  (supertag-link-error (setq payload (cdr data)))))
            (set-marker open-marker nil)))
      (should (eq :target-save (plist-get payload :stage)))
      (should (equal "capf-target" (plist-get payload :node-id)))))))


(ert-deftest supertag-delete-link-removes-whole-element-and-projects ()
  (supertag-add-link-test--isolated
    (let ((source (expand-file-name "source.org" tmp)))
      (supertag-add-link-test--write-node (expand-file-name "one.org" tmp) "one" "One")
      (supertag-add-link-test--write-node (expand-file-name "two.org" tmp) "two" "Two")
      (supertag-add-link-test--write-node source "source" "Source"
                                        "[[id:one][Discarded description]]\n[[id:two][Retained description]]")
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-min))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt candidates &rest _)
                     (should (equal "Delete link to: " prompt))
                     (car (rassoc "one" candidates)))))
          (call-interactively #'supertag-delete-link))
        (should-not (string-match-p "id:one\\|Discarded description" (buffer-string)))
        (should (string-match-p (regexp-quote "[[id:two][Retained description]]") (buffer-string)))
        (should-not (buffer-modified-p))
        (should (equal (buffer-string) (supertag-add-link-test--file-string source)))))
    (should (equal '("two")
                   (mapcar (lambda (r) (plist-get r :to))
                           (cl-remove-if-not #'supertag-relation-document-link-p
                                             (supertag-relation-find-by-from "source" :reference)))))))

(ert-deftest supertag-delete-link-retires-old-symbols ()
  (should (commandp 'supertag-delete-link))
  (should-not (fboundp 'supertag-remove-reference))
  (should-not (fboundp 'supertag-ui-select-reference-to-remove)))

(ert-deftest supertag-delete-link-preserves-adjacent-text-and-second-occurrence ()
  (dolist (case '(("A [[id:x][one]]   B" "A B" nil)
                  ("A[[id:x][one]]B" "AB" nil)
                  ("A [[id:x][one]] B [[id:x][two]] C" "A B [[id:x][two]] C" t)))
    (supertag-add-link-test--isolated
      (let ((file (expand-file-name "source.org" tmp)))
        (supertag-add-link-test--write-node (expand-file-name "x.org" tmp) "x" "Target")
        (supertag-add-link-test--write-node file "source" "Source" (car case))
        (with-current-buffer (find-file-noselect file)
          (goto-char (point-min))
          (cl-letf (((symbol-function 'supertag-link--read-link-to-delete) (lambda (_) "x")))
            (call-interactively #'supertag-delete-link))
          (org-end-of-meta-data t)
          (should (equal (concat (cadr case) "\n")
                         (buffer-substring-no-properties (point) (point-max))))
          (should-not (buffer-modified-p))
          (should (equal (buffer-string) (supertag-add-link-test--file-string file))))
        (should (eq (nth 2 case)
                    (not (null (cl-find-if
                                #'supertag-relation-document-link-p
                                (supertag-relation-find-between "source" "x" :reference))))))))))

(provide 'add-link-workflow-test)
;;; add-link-workflow-test.el ends here

(ert-deftest supertag-add-link-cold-shared-capf-real-existing-exit ()
  "A fresh hook traversal loads Link and commits its real CAPF selection."
  (supertag-add-link-test--isolated
    (let* ((source (expand-file-name "source.org" tmp))
           (target (expand-file-name "target.org" tmp))
           (snapshot (expand-file-name "projected.el" tmp))
           (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
           (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
           (process-environment (copy-sequence process-environment)))
      ;; Only the parent builds the real Org/projected fixture.  The child has
      ;; never loaded Link or Sync when it first walks completion hooks.
      (supertag-add-link-test--write-node source "source" "Source" "Body")
      (supertag-add-link-test--write-node target "target" "Target" "Target body")
      (with-temp-file snapshot
        (let ((print-length nil) (print-level nil)) (prin1 supertag--store (current-buffer))))
      (with-temp-buffer
        ;; Pin the child cwd before HOME is repointed.
        (setq default-directory (file-truename default-directory))
        (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
        (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
        (let* ((form
                `(unwind-protect
                     (progn
                       (require 'cl-lib) (require 'ert) (require 'org)
                       (setq user-emacs-directory ,(file-name-as-directory tmp)
                             supertag-data-directory ,tmp supertag--base-data-directory ,tmp
                             supertag-db-file ,(expand-file-name "db.el" tmp)
                             supertag-db-backup-directory ,(expand-file-name "backups/" tmp)
                             supertag-sync-state-file ,(expand-file-name "sync.el" tmp)
                             supertag-sync--state-source supertag-sync-state-file
                             org-id-locations-file ,(expand-file-name "ids" tmp)
                             org-id-track-globally nil after-init-time nil
                             supertag-sync-directories nil supertag-active-sync-directory nil
                             make-backup-files nil auto-save-default nil load-prefer-newer t)
                       (load ,(expand-file-name "supertag-tag.el" supertag-add-link-test--root) nil nil t)
                       (princ "D3-LINK-ENTRY-LOADED\n")
                       (should-not (featurep 'supertag-link))
                       (should-not (featurep 'supertag-services-sync))
                       (setq supertag--store (with-temp-buffer (insert-file-contents ,snapshot) (read (current-buffer))))
                       (let ((target-before (with-temp-buffer (insert-file-contents ,target) (buffer-string))))
                         (with-current-buffer (find-file-noselect ,source)
                           (org-mode) (goto-char (point-max)) (insert "[[Tar")
                           (supertag-ui-completion-mode 1)
                           (should-not (featurep 'supertag-link))
                           (let* ((calls nil)
                                  (capf (run-hook-wrapped 'completion-at-point-functions
                                          (lambda (fn) (push fn calls) (funcall fn))))
                                  (selected (cl-find-if
                                             (lambda (s) (equal "target" (get-text-property 0 'supertag-reference-node-id s)))
                                             (all-completions "" (nth 2 capf)))))
                             (should (equal calls '(supertag-tag--reference-completion-at-point)))
                             (should (featurep 'supertag-link))
                             (should selected)
                             ;; Emulate completion's text replacement, then call
                             ;; the actual CAPF exit closure and production writer.
                             (delete-region (nth 0 capf) (nth 1 capf))
                             (insert selected)
                             (funcall (plist-get (nthcdr 3 capf) :exit-function) selected 'finished)
                             (should-not (buffer-modified-p))
                             (should (string-match-p (regexp-quote "[[id:target][Target]]") (buffer-string)))
                             (should (equal (buffer-string) (with-temp-buffer (insert-file-contents ,source) (buffer-string))))
                             (should (member "target" (plist-get (supertag-node-get "source") :ref-to)))
                             (let ((facts (prin1-to-string supertag--store)) (text (buffer-string)))
                               (goto-char (point-max))
                               (supertag-completion--auto-record-on-boundary)
                               (should (equal facts (prin1-to-string supertag--store)))
                               (should (equal text (buffer-string)))))
                           (supertag-ui-completion-mode -1)
                           (should-not (memq 'supertag-completion-at-point completion-at-point-functions))
                           (should-not (memq 'supertag-tag--reference-completion-at-point completion-at-point-functions)))
                         (should (equal target-before (with-temp-buffer (insert-file-contents ,target) (buffer-string)))))
                       (princ "D3-LINK-PASS real hook/table/exit/save/project; target unchanged\n"))
                   (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
                   (mapc #'cancel-timer (append timer-list timer-idle-list))))
               (status (apply #'call-process program nil t nil
                              (append '("-Q" "--batch")
                                      (apply #'append (mapcar (lambda (dir) (list "-L" dir)) deps))
                                      (list "-L" supertag-add-link-test--root "--eval"
                                            (prin1-to-string `(condition-case err ,form
                                                                 (error (princ (format "D3-LINK-ERROR %S\n" err)) (kill-emacs 1))))))))
               (output (buffer-string)))
          (unless (and (equal status 0) (string-match-p "D3-LINK-ENTRY-LOADED" output)
                       (string-match-p "D3-LINK-PASS" output))
            (ert-fail (format "D3 Link exit=%S\n%s" status output)))
          (princ "D3 Link fresh exit0 real hook/table/exit/save/project PASS\n"))))))

;;; LINK-A: fresh processes distinguish load timing from real writer behavior.
(defun supertag-add-link-test--la-child (name body &optional preset)
  "Run BODY after a fresh Link ENTRY with real, parent-projected Org facts."
  (supertag-add-link-test--isolated
    (let* ((source (expand-file-name "source.org" tmp))
           (target (expand-file-name "target.org" tmp))
           (snapshot (expand-file-name "facts.el" tmp))
           (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
           (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
           (process-environment (copy-sequence process-environment)))
      (supertag-add-link-test--write-node source "source" "Source" "Body")
      (supertag-add-link-test--write-node target "target" "Target" "Target body")
      (with-temp-file snapshot
        (let ((print-length nil) (print-level nil)) (prin1 supertag--store (current-buffer))))
      ;; Pin the child cwd before HOME is repointed.
      (setq default-directory (file-truename default-directory))
      (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
      (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
      (let ((form
             `(unwind-protect
                  (progn
                    (require 'cl-lib) (require 'ert) (require 'org)
                    (setq user-emacs-directory ,(file-name-as-directory tmp)
                          supertag-data-directory ,tmp supertag--base-data-directory ,tmp
                          supertag-db-file ,(expand-file-name "db.el" tmp)
                          supertag-db-backup-directory ,(expand-file-name "backups" tmp)
                          supertag-sync-state-file ,(expand-file-name "sync.el" tmp)
                          supertag-sync--state-source supertag-sync-state-file
                          org-id-locations-file ,(expand-file-name "ids" tmp)
                          org-id-track-globally nil after-init-time nil
                          supertag-sync-directories (list ,tmp)
                          supertag-sync-directories-mode 'unified
                          make-backup-files nil auto-save-default nil load-prefer-newer t)
                    ,preset
                    (load ,(expand-file-name "supertag-link.el" supertag-add-link-test--root) nil nil t)
                    (princ ,(format "LA-%s-ENTRY\n" name))
                    (princ (format "LA-LOAD sync=%S session-bound=%S helper=%S\n"
                                   (featurep 'supertag-services-sync)
                                   (boundp 'supertag-text-link--session-types)
                                   (featurep 'supertag-view-helper)))
                    (setq supertag--store (with-temp-buffer (insert-file-contents ,snapshot) (read (current-buffer))))
                    (let ((source ,source) (target ,target) (tmp ,tmp)
                          (la-root ,supertag-add-link-test--root)
                          (before (equal (getenv "SUPERTAG_LINK_A_STAGE") "before")))
                      (cl-flet ((disk (file) (with-temp-buffer (insert-file-contents file) (buffer-string))))
                        ,@body))
                    (princ ,(format "LA-%s-DONE\n" name)))
                (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
                (mapc #'cancel-timer (append timer-list timer-idle-list)))))
        (with-temp-buffer
          (let ((status (apply #'call-process program nil t nil
                               (append '("-Q" "--batch")
                                       (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                       (list "-L" supertag-add-link-test--root "--eval"
                                             (prin1-to-string
                                              `(condition-case err ,form
                                                 (error (princ (format "LA-ERROR %S\n" err)) (kill-emacs 1)))))))))
            (princ (buffer-string))
            (unless (and (equal status 0)
                         (string-match-p (format "LA-%s-ENTRY" name) (buffer-string))
                         (string-match-p (format "LA-%s-DONE" name) (buffer-string)))
              (ert-fail (format "LA child %s exit=%S\n%s" name status (buffer-string))))))))))

(ert-deftest supertag-add-link-la-boundary ()
  (supertag-add-link-test--la-child
   "boundary"
   '((should (featurep 'supertag-service-org))
     (dolist (feature '(supertag-services-sync supertag-ui-commands
                       supertag-view-helper supertag-services-ui supertag-view-api supertag-tag))
       (should-not (featurep feature))
       (should-not (cl-find-if (lambda (entry)
                                (and (stringp (car entry))
                                     (equal (file-name-nondirectory (car entry))
                                            (concat (symbol-name feature) ".el")))) load-history)))
     (if (equal (getenv "SUPERTAG_LD_STAGE") "before")
         (should-not (boundp 'supertag-text-link--session-types))
       (should (boundp 'supertag-text-link--session-types))
       (should-not supertag-text-link--session-types))
     (should-not (bound-and-true-p global-supertag-ui-completion-mode))
     (should (featurep 'supertag-node)) (should (featurep 'supertag-query))
     (dolist (pair (append
                    (when (equal (getenv "SUPERTAG_CA_STAGE") "before")
                      '((supertag-service-org--promote-check-retained-target . "supertag-service-org")))
                    '((supertag-service-org-create-node . "supertag-service-org"))
                    (when (equal (getenv "SUPERTAG_CA_STAGE") "before")
                      '((supertag-service-org-promote-call-source . "supertag-service-org")
                        (supertag-service-org-promote-check-source-stage . "supertag-service-org")
                        (supertag-service-org-promote-source-state . "supertag-service-org")
                        (supertag-service-org-promote-target . "supertag-service-org")
                        (supertag-service-org-promote-target-guard . "supertag-service-org")))
                    '((supertag-service-org-retry-node-projection . "supertag-service-org")
                      (supertag-text-link-candidates . "supertag-services-sync")
                      (supertag-text-link-validate-type . "supertag-services-sync")
                      (supertag-text-link-accept-session-type . "supertag-services-sync")
                      (supertag-text-link-refresh . "supertag-services-sync"))
                    (if (or before (equal (getenv "SUPERTAG_VWC_STAGE") "before"))
                        '((supertag-view-helper-insert-section-chip . "supertag-view-helper"))
                      '((supertag-view-helper-insert-section-chip . "supertag-view-framework")))))
       (if (and (not (equal (getenv "SUPERTAG_LD_STAGE") "before"))
                (memq (car pair) '(supertag-text-link-candidates
                                  supertag-text-link-validate-type
                                  supertag-text-link-accept-session-type
                                  supertag-text-link-refresh)))
           (progn
             (should-not (autoloadp (symbol-function (car pair))))
             (should (equal (symbol-file (car pair) 'defun)
                            (expand-file-name "supertag-link.el" la-root))))
         (if (memq (car pair) '(supertag-service-org-create-node
                               supertag-service-org-retry-node-projection))
             (progn
               (should-not (autoloadp (symbol-function (car pair))))
               (should (equal (symbol-file (car pair) 'defun)
                              (expand-file-name "supertag-service-org.el" la-root))))
           (should (autoloadp (symbol-function (car pair))))
           (should (equal (cadr (symbol-function (car pair))) (cdr pair)))))))))

(ert-deftest supertag-add-link-la-ordinary ()
  (supertag-add-link-test--la-child
   "ordinary"
   '((let ((resolve-count 0) (validation-count 0)
           (target-before (disk target)))
       (unless before (if (equal (getenv "SUPERTAG_LD_STAGE") "before")
         (should-not (boundp 'supertag-text-link--session-types))
       (should (boundp 'supertag-text-link--session-types))
       (should-not supertag-text-link--session-types)))
       (advice-add 'supertag-text-link-validate-type :before
                   (lambda (&rest _) (cl-incf validation-count)))
       (advice-add 'supertag-reference--resolve-or-create :before
                   (lambda (&rest _)
                     (cl-incf resolve-count)
                     (princ "LA-ORDINARY-RESOLVE\n")
                     (if (equal (getenv "SUPERTAG_LD_STAGE") "before")
                         (should (featurep 'supertag-services-sync))
                       (should-not (autoloadp (symbol-function 'supertag-text-link-validate-type)))
                       (should (equal (symbol-file 'supertag-text-link-validate-type 'defun)
                                      (expand-file-name "supertag-link.el" la-root))))
                     (princ (format "LD-RESOLVE sync=%S sync-history=%S\n"
                                    (featurep 'supertag-services-sync)
                                    (and (cl-find-if
                                          (lambda (entry)
                                            (and (stringp (car entry))
                                                 (equal (file-name-nondirectory (car entry))
                                                        "supertag-services-sync.el")))
                                          load-history) t)))
                     (should (boundp 'supertag-text-link--session-types))
                     (should (= 0 validation-count))))
       (with-current-buffer (find-file-noselect source)
         (goto-char (point-max))
         (cl-letf (((symbol-function 'completing-read)
                    (lambda (_prompt collection &rest _)
                      (car (cl-find-if (lambda (entry)
                                        (equal "target" (get-text-property 0 'supertag-reference-node-id (cdr entry)))) collection)))))
           (should (equal "target" (supertag-add-link))))
         (should-not (buffer-modified-p))
         (should (equal (buffer-string) (disk source)))
         (should (= 1 (how-many (regexp-quote "[[id:target][Target]]") (point-min) (point-max)))))
       (should (= 1 resolve-count))
       (should (member "target" (plist-get (supertag-node-get "source") :ref-to)))
       (should (equal target-before (disk target)))
       ;; Native advice survives provider availability (pending in LD-before),
       ;; without invoking validation merely to load it; its cell stays stable.
       (let ((cell (symbol-function 'supertag-text-link-validate-type)))
         (should (equal "supports" (supertag-text-link-validate-type "supports")))
         (should (= 1 validation-count))
         (should (eq cell (symbol-function 'supertag-text-link-validate-type))))))))

(ert-deftest supertag-add-link-la-public-retry ()
  (supertag-add-link-test--la-child
   "retry"
   '((let ((old (disk source)) payload)
       (unless before (if (equal (getenv "SUPERTAG_LD_STAGE") "before")
         (should-not (boundp 'supertag-text-link--session-types))
       (should (boundp 'supertag-text-link--session-types))
       (should-not supertag-text-link--session-types)))
       (with-current-buffer (find-file-noselect source)
         (goto-char (point-max))
         (cl-letf (((symbol-function 'save-buffer) (lambda (&rest _) (error "LA actual save failure"))))
           (condition-case err
               (supertag-reference-materialize-at-point "target" "Target")
             (supertag-link-error (setq payload (cdr err)))))
         (should (eq :source-save (plist-get payload :stage)))
         (should (buffer-modified-p))
         (should (equal old (disk source)))
         (should-not (supertag-reference-recovery-complete-p payload))
         (unless before (if (equal (getenv "SUPERTAG_LD_STAGE") "before")
         (should-not (boundp 'supertag-text-link--session-types))
       (should (boundp 'supertag-text-link--session-types))
       (should-not supertag-text-link--session-types)))
         (princ "LA-RETRY-ORIGINAL-PAYLOAD\n")
         (should (equal "target" (apply (plist-get payload :retry) (plist-get payload :retry-args))))
         (should (supertag-reference-recovery-complete-p payload))
         (should-not (buffer-modified-p))
         (should (equal (disk source) (buffer-string)))
         (should (= 1 (how-many (regexp-quote "[[id:target][Target]]") (point-min) (point-max))))
         (should (member "target" (plist-get (supertag-node-get "source") :ref-to))))))))

(ert-deftest supertag-add-link-la-cancel-and-invalid ()
  (dolist (mode '(candidate template named invalid))
    (supertag-add-link-test--la-child
     (symbol-name mode)
     `((let ((facts (prin1-to-string supertag--store)) (old (disk source)))
         (with-current-buffer (find-file-noselect source)
           (goto-char (if (eq ',mode 'invalid) (point-min) (point-max)))

           (cl-letf ((buffer-file-name (unless (eq ',mode 'invalid) buffer-file-name))
                     ((symbol-function 'completing-read)
                      (lambda (prompt collection &rest _)
                        (cond
                         ((eq ',mode 'candidate) (signal 'quit nil))
                         ((and (eq ',mode 'template) (string-prefix-p "Reference" prompt)) "Novel")
                         ((string-prefix-p "Create a new" prompt) (car collection))
                         ((string-prefix-p "Reference" prompt)
                          (car (cl-find-if (lambda (entry) (equal "target" (get-text-property 0 'supertag-reference-node-id (cdr entry)))) collection)))
                         (t (signal 'quit nil))))))
             (if (eq ',mode 'invalid)
                 (should-error (supertag-add-link) :type 'user-error)
               (should (condition-case nil (progn (supertag-add-link (eq ',mode 'named)) nil) (quit t)))))
           (should (equal old (buffer-string))) (should-not (buffer-modified-p)))
         (should (equal old (disk source))) (should (equal facts (prin1-to-string supertag--store)))
         (unless (or before (eq ',mode 'named))
           (should-not (featurep 'supertag-services-sync))))))))

(ert-deftest supertag-add-link-la-named-and-new ()
  (dolist (mode '(named new))
    (supertag-add-link-test--la-child
     (symbol-name mode)
     `((let* ((created (expand-file-name "created.org" tmp))
              (supertag-creation-templates (list (list :key "n" :name "Note" :target-file created :body "Created body"))))
         (with-current-buffer (find-file-noselect source)
           (goto-char (point-max))
           (cl-letf (((symbol-function 'completing-read)
                      (lambda (prompt collection &rest _)
                        (cond
                         ((string-prefix-p "Reference" prompt)
                          (if (eq ',mode 'new) "Novel"
                            (car (cl-find-if (lambda (entry) (equal "target" (get-text-property 0 'supertag-reference-node-id (cdr entry)))) collection))))
                         ((string-prefix-p "Create a new" prompt) (car collection))
                         ((string-prefix-p "Creation template" prompt) (caar collection))
                         (t "supports")))))
             (let ((id (supertag-add-link (eq ',mode 'named))))
               (should (supertag-node-get id))
               (if (eq ',mode 'named)
                   (should (= 1 (length (supertag-query-named-links-from "source" "supports"))))
                 (should (member id (plist-get (supertag-node-get "source") :ref-to))))
               (if (eq ',mode 'new)
                   (progn (should (string-match-p "Created body" (disk created)))
                          (should (equal created (plist-get (supertag-node-get id) :file))))
                 (should (string-match-p (regexp-quote "[[supports:target][Target]]") (disk source)))
                 (should (member "supports" supertag-text-link--session-types)))))
           (should-not (buffer-modified-p)) (should (equal (disk source) (buffer-string)))))))))

(ert-deftest supertag-add-link-la-display-and-preset ()
  (supertag-add-link-test--la-child
   "display"
   '((let ((facts (prin1-to-string supertag--store)) (old (disk source)))
       (unless before (should-not (featurep 'supertag-view-helper)))
       (with-temp-buffer
         (supertag-view-reference-insert-sections "source")
         (should (string-empty-p (buffer-string)))
         (erase-buffer)
         (supertag-view-reference--insert-card '(:node-id "target" :title "Target" :location "target.org" :snippet "Target body"))
         (should (featurep (if (or before (equal (getenv "SUPERTAG_VWC_STAGE") "before")) 'supertag-view-helper 'supertag-view-framework)))
         (goto-char (point-min)) (search-forward "Target")
         (should (equal "target" (get-text-property (1- (point)) 'supertag-node-id)))
         (let ((button (button-at (1- (point)))))
           (should button) (button-activate button)
           (should (equal target (buffer-file-name)))
           (should (equal "target" (org-entry-get nil "ID")))))
       (should (equal old (disk source))) (should (equal facts (prin1-to-string supertag--store))))))
  (supertag-add-link-test--la-child
   "preset"
   '((should (= supertag-reference-context-length 123))
     (should (equal supertag-reference-history '("kept")))
     (should (equal supertag-text-link--session-types '("supports")))
     (supertag-text-link-candidates)
     (should (equal supertag-text-link--session-types '("supports"))))
   '(setq supertag-reference-context-length 123 supertag-reference-history '("kept")
          supertag-text-link--session-types '("supports"))))

;;; LINK-B: formatter ownership and real first-use loading, isolated from LA.
(defun supertag-add-link-test--lb-child (entry name body)
  "Run BODY after real ENTRY in a new process, checking explicit phase markers."
  (let* ((tmp (make-temp-file "supertag-link-b-" t))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (process-environment (copy-sequence process-environment))
         (form
          `(unwind-protect
               (progn
                 (require 'cl-lib) (require 'ert) (require 'org)
                 (setq user-emacs-directory ,(file-name-as-directory tmp)
                       supertag-data-directory ,tmp supertag--base-data-directory ,tmp
                       supertag-db-file ,(expand-file-name "db.el" tmp)
                       supertag-db-backup-directory ,(expand-file-name "backups" tmp)
                       supertag-sync-state-file ,(expand-file-name "sync.el" tmp)
                       supertag-sync--state-source supertag-sync-state-file
                       org-id-locations-file ,(expand-file-name "ids" tmp)
                       org-id-locations nil org-id-files nil org-id-track-globally nil
                       after-init-time nil org-mode-hook nil enable-theme-functions nil
                       supertag-sync-directories nil supertag-active-sync-directory nil
                       make-backup-files nil auto-save-default nil load-prefer-newer t)
                 (let ((root ,supertag-add-link-test--root) (tmp ,tmp)
                       (lb-before (equal (getenv "SUPERTAG_LB_STAGE") "before")) events)
                   (cl-labels
                       ((absent (features)
                          (dolist (feature features)
                            (should-not (featurep feature))
                            (should-not (cl-find-if
                                         (lambda (row) (and (stringp (car row))
                                                           (equal (file-name-base (car row)) (symbol-name feature))))
                                         load-history))))
                        (disk (file) (with-temp-buffer (insert-file-contents file) (buffer-string)))
                        (observe (file)
                          (when (and (stringp file) (string-prefix-p root file))
                            (push (file-name-base file) events))))
                     (add-hook 'after-load-functions #'observe)
                     (unwind-protect
                         (progn
                           (load (expand-file-name ,entry root) nil nil t)
                           (princ ,(format "LINK-B-ENTRY %s\n" name))
                           ,@body
                           (princ (format "LINK-B-LOADS %S\n" (reverse events)))
                           (princ ,(format "LINK-B-PASS %s\n" name)))
                       (remove-hook 'after-load-functions #'observe)))))
             (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
             (mapc #'cancel-timer (append timer-list timer-idle-list)))))
    (unwind-protect
        (with-temp-buffer
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (let ((exit (apply #'call-process program nil t nil
                             (append '("-Q" "--batch")
                                     (apply #'append (mapcar (lambda (dir) (list "-L" dir)) deps))
                                     (list "-L" supertag-add-link-test--root "--eval"
                                           (prin1-to-string
                                            `(condition-case err ,form
                                               (error (princ (format "LINK-B-ERROR %S\n" err)) (kill-emacs 1)))))))))
            (princ (buffer-string))
            (unless (and (equal exit 0)
                         (string-match-p (format "LINK-B-ENTRY %s" name) (buffer-string))
                         (string-match-p (format "LINK-B-PASS %s" name) (buffer-string)))
              (ert-fail (format "LINK-B child %s exit=%S\n%s" name exit (buffer-string))))))
      (delete-directory tmp t))))

(ert-deftest supertag-add-link-lb-values-read-only ()
  (supertag-add-link-test--lb-child
   "supertag-link.el" "values"
   '((supertag--ensure-store)
     (dolist (row '(("native.[+]" :id "native.[+]" :title "Native")
                     ("ds" :id "ds" :link-type denote)
                     ("dt" :id "dt" :link-type "denote")
                     ("unknown" :id "unknown" :link-type "custom")))
       (supertag-store-put-entity :nodes (car row) (cdr row)))
     (let* ((file (expand-file-name "read.org" tmp))
            (text "* Read\n:PROPERTIES:\n:ID: native.[+]\n:END:\nBody\n")
            (facts (prin1-to-string supertag--store)) (ids (copy-tree org-id-locations)))
       (with-temp-file file (insert text))
       (with-current-buffer (find-file-noselect file)
         (goto-char (point-max)) (insert "Unsaved visible draft")
         (let ((live (buffer-string)) (dirty (buffer-modified-p)))
           (should (equal "id" (supertag-node-link-type "native.[+]")))
           (should (equal "denote" (supertag-node-link-type "ds")))
           (should (equal "denote" (supertag-node-link-type "dt")))
           (should (equal "id" (supertag-node-link-type "unknown")))
           (should (equal "id" (supertag-node-link-type "missing")))
           (princ "LINK-B-VALUES-NIL-TITLE\n")
           (should (equal "[[id:native.[+]][native.[+]]]" (supertag-node-format-link "native.[+]")))
           (should (equal "[[id:missing][missing]]" (supertag-node-format-link "missing")))
           (should (equal "[[denote:ds][Shown]]" (supertag-node-format-link "ds" "Shown")))
           (should (equal "[[denote:dt][Shown]]" (supertag-node-format-link "dt" "Shown" nil)))
           (should (equal "[[id:native.[+]][]]" (supertag-node-format-link "native.[+]" "")))
           (should (equal "[[:ds][Shown]]" (supertag-node-format-link "ds" "Shown" "")))
           (should (equal "[[supports:ds][Shown]]" (supertag-node-format-link "ds" "Shown" "supports")))
           (let ((pattern (supertag-node-link-pattern "native.[+]")))
             (should (string-match-p pattern "[[id:native.[+]][Shown]]"))
             (should-not (string-match-p pattern "[[id:nativeX+][Shown]]")))
           (should (string-match-p (supertag-node-link-pattern "dt") "[[denote:dt][Shown]]"))
           (should-not (string-match-p (supertag-node-link-pattern "dt") "[[supports:dt][Shown]]"))
           (should (equal live (buffer-string))) (should (eq dirty (buffer-modified-p)))))
       (should (equal text (disk file)))
       (should (equal facts (prin1-to-string supertag--store)))
       (should (equal ids org-id-locations))
       (should-not (file-exists-p supertag-db-file))))))

(ert-deftest supertag-add-link-lb-query-first-row ()
  (supertag-add-link-test--lb-child
   "supertag-query.el" "query-row"
   '((absent '(supertag-node supertag-link supertag-tag supertag-services-sync
               supertag-service-org supertag-view-helper supertag-services-ui supertag-ui-commands))
     (should-not supertag--store) (should-not (file-exists-p supertag-db-file))
     (supertag--ensure-store)
     (let ((a '(:id "a" :title "Alpha Needle" :properties (:AUTHOR "Ada")))
           (b '(:id "b" :title "Beta Needle" :link-type denote :properties (:AUTHOR "Grace"))))
       (supertag-store-put-entity :nodes "a" a)
       (supertag-store-put-entity :nodes "b" b)
       (let ((facts (prin1-to-string supertag--store)) (ids (copy-tree org-id-locations)))
         ;; Do not inspect the formatter cell before this call: an omitted
         ;; provider must fail execution here, not a metadata assertion.
         (princ "LINK-B-FIRST-REAL-ROW\n")
         (should (equal '("[[id:a][Alpha Needle]]" "" "Ada")
                        (supertag-query-block--row a '("AUTHOR"))))
         (should (equal '("[[denote:b][Beta Needle]]" "" "Grace")
                        (supertag-query-block--row b '("AUTHOR"))))
         (should (equal (symbol-file 'supertag-node-format-link 'defun)
                        (expand-file-name (if lb-before "supertag-ops-node.el" "supertag-link.el") root)))
         (should-not (autoloadp (symbol-function 'supertag-node-format-link)))
         (if lb-before (should-not (featurep 'supertag-link)) (should (featurep 'supertag-link)))
         (should (featurep 'supertag-service-org))
         (absent '(supertag-tag supertag-services-sync supertag-view-helper supertag-services-ui supertag-ui-commands))
         (let ((rows (supertag-query-block--headers-and-rows
                      "(term \"Needle\")" '(:sort "title" :order "asc" :columns "AUTHOR"))))
           (should (equal '(("Node" "Tags" "AUTHOR")
                            ("[[id:a][Alpha Needle]]" "" "Ada")
                            ("[[denote:b][Beta Needle]]" "" "Grace")) rows)))
         (let ((rendered (supertag-query-block--render "(term \"Needle\")" '(:columns "AUTHOR"))))
           (should (string-match-p (regexp-quote "[[id:a][Alpha Needle]]") rendered))
           (should (string-match-p (regexp-quote "[[denote:b][Beta Needle]]") rendered))
           (should (string-match-p "Grace" rendered)))
         (with-current-buffer (supertag-query-block--render-results '(term "Needle"))
           (should (eq major-mode 'org-mode)) (should view-mode) (should buffer-read-only)
           (should (string-match-p (regexp-quote "[[id:a][Alpha Needle]]") (buffer-string)))
           (should (string-match-p (regexp-quote "[[denote:b][Beta Needle]]") (buffer-string))))
         (should (equal facts (prin1-to-string supertag--store))) (should (equal ids org-id-locations))
         (should-not (file-exists-p supertag-db-file)))))))

(ert-deftest supertag-add-link-lb-query-provider-metadata ()
  (supertag-add-link-test--lb-child
   "supertag-query.el" "query-provider"
   '((absent '(supertag-link supertag-node supertag-tag supertag-services-sync))
     (should (autoloadp (symbol-function 'supertag-node-format-link)))
     (should (equal (cadr (symbol-function 'supertag-node-format-link))
                    (if lb-before "supertag-ops-node" "supertag-link"))))))

(ert-deftest supertag-add-link-lb-entries-stay-link-cold ()
  (dolist (entry '("supertag-node.el" "supertag-tag.el" "supertag-services-sync.el"))
    (supertag-add-link-test--lb-child
     entry entry
     '((absent '(supertag-link))
       (unless lb-before (absent '(supertag-ops-node)))
       (should (equal (symbol-file 'supertag-node-get 'defun) (expand-file-name "supertag-node.el" root)))
       (should-not (file-exists-p supertag-db-file))))))

(ert-deftest supertag-add-link-lb-owner-retired-carrier ()
  (supertag-add-link-test--lb-child
   "supertag-link.el" "owner"
   '((dolist (symbol '(supertag-node-link-type supertag-node-format-link supertag-node-link-pattern))
       (should (equal (symbol-file symbol 'defun) (expand-file-name "supertag-link.el" root))))
     (should-not (file-exists-p (expand-file-name "supertag-ops-node.el" root)))
     (should (featurep 'supertag-service-org))
     (absent '(supertag-ops-node supertag-services-sync supertag-tag supertag-ui-commands supertag-services-ui supertag-view-helper))
     (if (equal (getenv "SUPERTAG_LD_STAGE") "before")
         (should-not (boundp 'supertag-text-link--session-types))
       (should (boundp 'supertag-text-link--session-types))
       (should-not supertag-text-link--session-types))
     (should-not (bound-and-true-p global-supertag-ui-completion-mode)))))

;;; LINK-C: independent real relation execution, before/current generations.
(defconst supertag-add-link-test--lc-program
  '(progn
     (require 'cl-lib) (require 'ert)
     (setq user-emacs-directory (file-name-as-directory lc-tmp)
           supertag-data-directory lc-tmp supertag--base-data-directory lc-tmp
           supertag-db-file (expand-file-name "db.el" lc-tmp)
           supertag-db-backup-directory (expand-file-name "backups" lc-tmp)
           supertag-sync-state-file (expand-file-name "sync.el" lc-tmp)
           supertag-sync--state-source supertag-sync-state-file
           org-id-locations-file (expand-file-name "ids" lc-tmp)
           org-id-track-globally nil org-id-files nil org-id-locations nil
           after-init-time nil org-mode-hook nil find-file-hook nil
           supertag-sync-directories nil supertag-active-sync-directory nil
           supertag-view-style-auto-enable nil supertag-org-capture-auto-enable nil
           make-backup-files nil auto-save-default nil load-prefer-newer t)
     (defvar lc-events nil)
     (defun lc-load-observer (file)
       (when (and (stringp file) (string-prefix-p lc-root file))
         (push (file-name-base file) lc-events)))
     (add-hook 'after-load-functions #'lc-load-observer)
     (defun lc-absent (features)
       (dolist (f features)
         (should-not (featurep f))
         (should-not (member (symbol-name f) lc-events))))
     (defun lc-seed ()
       (supertag--ensure-store)
       (dolist (id '("a" "b" "old" "old/child"))
         (supertag-store-put-entity :nodes id (list :id id :title id)))
       (supertag-store-put-entity
        :relations "seed" '(:id "seed" :from "a" :to "b" :type :reference
                                  :kind :document-link :origin :org :relation-name "observed")))
     (defun lc-rel-owner (symbol)
       (should-not (autoloadp (symbol-function symbol)))
       (should (equal (symbol-file symbol 'defun)
                      (expand-file-name (if lc-before "supertag-ops-relation.el" "supertag-link.el") lc-root))))
     (when (memq lc-case '(reload risk-org)) (require 'org))
     (when (memq lc-case '(risk risk-org))
       (setq org-babel-load-languages '((supertag-query-block . t))))
     (when (eq lc-case 'reload)
       (setq supertag-reference-backlink-include-timestamp 'preset
             supertag-relation--last-error '(:reason :preset)
             supertag-change--suppress-legacy-store-changed 'outer))
     (princ (format "LC-LOAD-ATTEMPT %S %S before=%S\n" lc-case lc-entry lc-before))
     (if (memq lc-case '(risk risk-org))
         (progn
           (load (expand-file-name lc-entry lc-root) nil nil t)
           (princ "LC-RISK-ENTRY\n")
           (lc-seed)
           (pcase lc-entry
             ("supertag-node.el" (supertag-node-delete "a"))
             ("supertag-tag.el" (supertag-tag-merge--rewrite-relations '("a") "b"))
             ("supertag-services-sync.el"
              (unless (or lc-before (equal (getenv "SUPERTAG_LD_STAGE") "before"))
                (require 'supertag-link))
              (should (member "observed" (supertag-text-link-candidates))))
             (_ (should (supertag-query-relations-from "a"))))
           (princ "LC-RISK-REAL-CALL-DONE\n"))
       (load (expand-file-name lc-entry lc-root) nil nil t)
       (princ (format "LC-ENTRY %S %S\n" lc-case lc-entry))
       (when (and (not lc-before) (memq lc-case '(node tag-merge tag-rename sync-candidates sync-project query-get query-dsl)))
         (lc-absent '(supertag-link)))
       (when (eq lc-case 'node)
         (lc-absent '(supertag-query supertag-tag supertag-services-sync)))
       (when (memq lc-case '(query-get query-dsl))
         (lc-absent '(supertag-node supertag-tag supertag-services-sync)))
       (unless (memq lc-case '(owner main reload)) (lc-seed))
       (princ (format "LC-CALL %S\n" lc-case))
       (pcase lc-case
         ('owner
          ;; Intentionally unconditional: successful old Link ENTRY precedes red.
          (should (equal (symbol-file 'supertag-relation-create 'defun)
                         (expand-file-name "supertag-link.el" lc-root)))
          (should-not (file-exists-p (expand-file-name "supertag-ops-relation.el" lc-root)))
          (lc-absent '(supertag-ops-relation)))
         ('crud
          (should-not (supertag-relation-add-reference "" "b"))
          (should (eq :invalid-from (plist-get (supertag-relation-last-error) :reason)))
          (should-not (supertag-relation-add-reference "a" "missing"))
          (should (eq :to-node-missing (plist-get (supertag-relation-last-error) :reason)))
          (should (supertag-relation-add-reference "a" "b"))
          (should-not (supertag-relation-last-error))
          (let* ((record (car (supertag-relation-find-between "a" "b" :reference :semantic-edge)))
                 (id (plist-get record :id)))
            (should (eq :semantic (plist-get record :origin)))
            (should (eq record (supertag-relation-create (copy-tree record))))
            (should (equal "edited" (plist-get (supertag-relation-update id (lambda (r) (plist-put r :label "edited"))) :label)))
            (let ((facts (prin1-to-string supertag--store)))
              (should-error (supertag-relation-update id (lambda (r) (plist-put r :to "old"))))
              (should (equal facts (prin1-to-string supertag--store))))
            (supertag-relation-delete id)
            (should-not (supertag-relation-get id)))
          (princ "LC-CRUD-REAL-OUTPUT deleted-semantic\n")
          (should (= 1 (hash-table-count (supertag-store-get-collection :relations)))))
         ('dedupe
          (dolist (row '(("plain" :document-link :org nil nil nil)
                         ("semantic" :semantic-edge :semantic nil nil nil)
                         ("field1" :field-reference :legacy "f1" nil nil)
                         ("field2" :field-reference :legacy "f2" nil nil)
                         ("def1" :semantic-edge :semantic nil "d1" nil)
                         ("def2" :semantic-edge :semantic nil "d2" nil)
                         ("named2" :document-link :org nil nil "opposes")))
            (supertag-store-put-entity :relations (car row)
             (list :id (car row) :from "a" :to "b" :type :reference :kind (nth 1 row)
                   :origin (nth 2 row) :field-id (nth 3 row) :link-definition-id (nth 4 row) :relation-name (nth 5 row))))
          (let ((duplicate (copy-tree (supertag-relation-get "seed"))))
            (setq duplicate (plist-put duplicate :id "dup"))
            (supertag-store-put-entity :relations "dup" duplicate))
          (should (= 1 (supertag-relation-cleanup-duplicates)))
          (should (= 8 (hash-table-count (supertag-store-get-collection :relations))))
          (should (= 0 (supertag-relation-cleanup-duplicates)))
          (supertag-store-put-entity :relations "legacy-tag"
           '(:id "legacy-tag" :from "a" :to "b" :type :node-field :props (:tag-id "old")))
          (should (= 1 (supertag-relation-delete-for-tag "old")))
          (should-not (supertag-relation-get "legacy-tag")))
         ('node
          (supertag-node-delete "a")
          (should-not (supertag-node-get "a"))
          (should-not (supertag-store-get-entity :relations "seed"))
          (lc-rel-owner 'supertag-relation-delete-for-node)
          (lc-absent '(supertag-tag supertag-services-sync)))
         ((or 'tag-merge 'tag-rename)
          (supertag-store-put-entity :relations "collision"
           '(:id "collision" :from "old" :to "b" :type :reference :kind :document-link :origin :org :relation-name "observed" :label "kept"))
          (if (eq lc-case 'tag-merge)
              (progn
                (supertag-tag-merge--rewrite-relations '("old") "new")
                (let* ((id (supertag-generate-relation-id "new" "b" :reference :document-link nil nil))
                       (r (supertag-store-get-entity :relations id)))
                  (should (equal "new" (plist-get r :from)))
                  (should (equal "observed" (plist-get r :relation-name)))
                  (should (equal "kept" (plist-get r :label)))))
            (let ((mapping '(("old" . "new"))))
              (supertag-tag-rename--rewrite-relations mapping)
              (let ((r (supertag-store-get-entity :relations (supertag-generate-relation-id "new" "b" :reference :document-link nil nil))))
                (should (equal "new" (plist-get r :from))) (should (equal "kept" (plist-get r :label))))
              (setq mapping '(("new" . "a")))
              (let ((facts (prin1-to-string supertag--store)))
                (should-error (supertag-tag-rename--rewrite-relations mapping))
                (should (equal facts (prin1-to-string supertag--store))))))
          (lc-rel-owner 'supertag-relation-kind)
          (lc-rel-owner 'supertag-generate-relation-id))
         ('sync-candidates
          (unless (or lc-before (equal (getenv "SUPERTAG_LD_STAGE") "before"))
            (require 'supertag-link))
          (should (equal '("observed") (supertag-text-link-candidates)))
          (lc-rel-owner 'supertag-relation-named-document-link-p))
         ('sync-project
          (let ((counters (list :references-created 0)))
            (supertag--process-node-references '(:id "a" :ref-to ("b")) counters)
            (should (= 1 (plist-get counters :references-created)))
            (should (= 2 (length (supertag-relation-find-between "a" "b" :reference :document-link)))))
          (lc-rel-owner 'supertag-relation-project-document-link))
         ('query-get
          (should (equal "seed" (plist-get (supertag-view-api-get-entity :relation "seed") :id)))
          (lc-rel-owner 'supertag-relation-get))
         ('query-dsl
          (should (equal '("a") (supertag-query-node-ids '(has-link "observed"))))
          (lc-rel-owner 'supertag-relation-find-by-from))
         ('notify
          (let ((events nil) (observed nil)
                (real (symbol-function 'supertag-store-remove-entity)))
            (supertag-subscribe :store-changed (lambda (&rest args) (push args events)))
            (cl-letf (((symbol-function 'supertag-store-remove-entity)
                       (lambda (&rest args)
                         (push supertag-change--suppress-legacy-store-changed observed)
                         (apply real args))))
              (let ((supertag-change--suppress-legacy-store-changed nil))
                (supertag-relation-delete "seed")
                (should-not supertag-change--suppress-legacy-store-changed)))
            (should (equal '(t) observed))
            (should (= 1 (length events)))
            (princ (format "LC-NOTIFY-EVENT %S\n" events))
            (lc-seed) (setq events nil)
            (let ((supertag-change--suppress-legacy-store-changed t))
              (supertag-relation-delete "seed")
              (should supertag-change--suppress-legacy-store-changed))
            (should-not events)
            (lc-seed)
            (cl-letf (((symbol-function 'supertag-store-remove-entity)
                       (lambda (&rest _) (should supertag-change--suppress-legacy-store-changed) (error "LC remove error"))))
              (let ((supertag-change--suppress-legacy-store-changed nil))
                (should (equal '(error "LC remove error") (should-error (supertag-relation-delete "seed"))))
                (should-not supertag-change--suppress-legacy-store-changed)
                (should (supertag-relation-get "seed"))))))
         ('main
          (let ((order (reverse lc-events)))
            (princ (format "LC-MAIN-ORDER %S\n" order))
            (should (< (cl-position "supertag-node" order :test #'equal) (cl-position "supertag-services-sync" order :test #'equal)))
            (should (< (cl-position "supertag-tag" order :test #'equal) (cl-position "supertag-services-sync" order :test #'equal)))
            (should (< (cl-position "supertag-services-sync" order :test #'equal) (cl-position "supertag-link" order :test #'equal))))
          (should-not (file-exists-p supertag-db-file)))
         ('reload
          (let ((cell (symbol-function 'supertag-relation-get)) (calls 0))
            (advice-add 'supertag-relation-get :before (lambda (&rest _) (cl-incf calls)))
            (let ((advised (symbol-function 'supertag-relation-get)))
              (require 'supertag-link)
              (should (eq advised (symbol-function 'supertag-relation-get)))
              (lc-seed) (should (supertag-relation-get "seed"))
              (should (= 1 calls)))
            (should cell))
          (load (expand-file-name "supertag-link.el" lc-root) nil nil t)
          (should (eq 'preset supertag-reference-backlink-include-timestamp))
          (should (equal '(:reason :preset) supertag-relation--last-error))
          (should (eq 'outer supertag-change--suppress-legacy-store-changed)))
         (_ (error "Unknown LC case %S" lc-case))))
     (princ (format "LC-DONE %S %S\n" lc-case lc-entry))))

(defun supertag-add-link-test--lc-child (case entry)
  "Execute CASE in a fresh source process, preserving actual phase evidence."
  (let* ((tmp (make-temp-file "supertag-lc-" t))
         (root (file-name-as-directory (or (getenv "SUPERTAG_LC_ROOT") supertag-add-link-test--root)))
         (before (equal (getenv "SUPERTAG_LC_STAGE") "before"))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (process-environment (copy-sequence process-environment))
         (script (expand-file-name "case.el" tmp))
         (evidence (getenv "SUPERTAG_LC_EVIDENCE")))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert ";;; -*- lexical-binding: t; -*-\n(defvar supertag-change--suppress-legacy-store-changed)\n")
            (prin1 `(setq lc-root ,root lc-tmp ,tmp lc-before ,before lc-case ',case lc-entry ,entry) (current-buffer))
            (terpri (current-buffer))
            (prin1 `(condition-case err
                        (unwind-protect ,supertag-add-link-test--lc-program
                          (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
                          (mapc #'cancel-timer (append timer-list timer-idle-list)))
                      (error (princ (format "LC-ERROR %S\n" err)) (kill-emacs 1))) (current-buffer)))
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (with-temp-buffer
            (let ((status (apply #'call-process program nil t nil
                                 (append '("-Q" "--batch")
                                         (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                         (list "-L" root "-l" script)))))
              (when evidence
                (make-directory evidence t)
                (let ((base (expand-file-name (format "%s-%s" case (file-name-base entry)) evidence)))
                  (copy-file script (concat base ".el") t)
                  (write-region (point-min) (point-max) (concat base ".log") nil 'silent)
                  (with-temp-file (concat base ".exit") (insert (format "%s\n" status)))))
              (princ (buffer-string))
              (should (equal 0 status))
              (should (string-match-p (format "LC-DONE %s" case) (buffer-string))))))
      (delete-directory tmp t))))

(ert-deftest supertag-add-link-lc-crud () (supertag-add-link-test--lc-child 'crud "supertag-link.el"))
(ert-deftest supertag-add-link-lc-dedupe () (supertag-add-link-test--lc-child 'dedupe "supertag-link.el"))
(ert-deftest supertag-add-link-lc-node-first () (supertag-add-link-test--lc-child 'node "supertag-node.el"))
(ert-deftest supertag-add-link-lc-tag-merge-first () (supertag-add-link-test--lc-child 'tag-merge "supertag-tag.el"))
(ert-deftest supertag-add-link-lc-tag-rename-first () (supertag-add-link-test--lc-child 'tag-rename "supertag-tag.el"))
(ert-deftest supertag-add-link-lc-sync-candidates-first () (supertag-add-link-test--lc-child 'sync-candidates "supertag-services-sync.el"))
(ert-deftest supertag-add-link-lc-sync-project-first () (supertag-add-link-test--lc-child 'sync-project "supertag-services-sync.el"))
(ert-deftest supertag-add-link-lc-query-get-first () (supertag-add-link-test--lc-child 'query-get "supertag-query.el"))
(ert-deftest supertag-add-link-lc-query-dsl-first () (supertag-add-link-test--lc-child 'query-dsl "supertag-query.el"))
(ert-deftest supertag-add-link-lc-notify () (supertag-add-link-test--lc-child 'notify "supertag-link.el"))
(ert-deftest supertag-add-link-lc-main () (supertag-add-link-test--lc-child 'main "supertag.el"))
(ert-deftest supertag-add-link-lc-reload () (supertag-add-link-test--lc-child 'reload "supertag-link.el"))
(ert-deftest supertag-add-link-lc-risk ()
  (dolist (entry '("supertag-node.el" "supertag-tag.el" "supertag-services-sync.el" "supertag-query.el"))
    (supertag-add-link-test--lc-child 'risk entry)))
(ert-deftest supertag-add-link-lc-risk-org-first ()
  (dolist (entry '("supertag-node.el" "supertag-tag.el" "supertag-services-sync.el" "supertag-query.el"))
    (supertag-add-link-test--lc-child 'risk-org entry)))
(ert-deftest supertag-add-link-lc-owner () (supertag-add-link-test--lc-child 'owner "supertag-link.el"))

;;; LINK-D: independent vocabulary owner, first parser and protocol controls.
(defconst supertag-add-link-test--ld-program
  '(progn
     (require 'cl-lib) (require 'ert)
     (setq user-emacs-directory (file-name-as-directory ld-tmp)
           supertag-data-directory ld-tmp supertag--base-data-directory ld-tmp
           supertag-db-file (expand-file-name "db.el" ld-tmp)
           supertag-db-backup-directory (expand-file-name "backup" ld-tmp)
           supertag-sync-state-file (expand-file-name "sync.el" ld-tmp)
           supertag-sync--state-source supertag-sync-state-file
           org-id-locations-file (expand-file-name "ids" ld-tmp)
           org-id-track-globally nil org-id-files nil org-id-locations nil
           after-init-time nil org-mode-hook nil find-file-hook nil
           supertag-sync-directories nil supertag-active-sync-directory nil
           supertag-view-style-auto-enable nil supertag-org-capture-auto-enable nil
           make-backup-files nil auto-save-default nil load-prefer-newer t)
     (defvar ld-events nil)
     (defvar ld-refresh-events nil)
     (defun ld-loaded (file)
       (when (and (stringp file) (string-prefix-p ld-root file))
         (push (file-name-base file) ld-events)))
     (add-hook 'after-load-functions #'ld-loaded)
     (when (eq ld-case 'qd-org) (require 'org))
     (when (memq ld-case '(qd qd-org))
       (setq org-babel-load-languages '((supertag-query-block . t))))
     (when (eq ld-case 'preset)
       (setq supertag-text-link-relation-types '("ld-config")
             supertag-text-link--session-types '("ld-session")
             supertag-text-link--owned-registrations (make-hash-table :test #'equal)))
     (princ (format "LD-LOAD-ATTEMPT %S %s before=%S\n" ld-case ld-entry ld-before))
      (let ((ld-hash (and (boundp 'supertag-text-link--owned-registrations)
                        supertag-text-link--owned-registrations)))
       (load (expand-file-name ld-entry ld-root) nil nil t)
       (princ (format "LD-ENTRY %S %s graph=%S\n" ld-case ld-entry (reverse ld-events)))
         (when (equal ld-entry "supertag-services-sync.el")
           (should-not (featurep 'supertag-link))
           (should-not (member "supertag-link" ld-events)))
         ;; Protocol APIs now belong to Link; this is deliberately a warm
         ;; lifecycle fixture, distinct from the four first-parser children.
         (when (and (not ld-before) (memq ld-case '(protocol failure)))
           (require 'supertag-link))
         (pcase ld-case
           ('owner
            (should (equal (symbol-file 'supertag-text-link-refresh 'defun)
                           (expand-file-name "supertag-link.el" ld-root))))
           ((or 'header-empty 'header-plain 'nodes-empty 'nodes-plain 'qd 'qd-org)
            (let* ((plain (memq ld-case '(header-plain nodes-plain)))
                   (nodes (memq ld-case '(nodes-empty nodes-plain)))
                   (file (expand-file-name "source.org" ld-tmp))
                   (text (if plain
                             ":PROPERTIES:\n:ID: file-id\n:END:\n#+TITLE: File\n[[id:target]]\n* Heading\n:PROPERTIES:\n:ID: heading-id\n:END:\n[[id:target]]\n"
                           ""))
                   (facts (prin1-to-string (and (boundp 'supertag--store) supertag--store)))
                   (registry (copy-tree org-link-parameters)))
              (with-temp-file file (insert text))
              ;; Advice observes real refresh; it neither resolves nor invokes it early.
              (advice-add 'supertag-text-link-refresh :before
                          (lambda (&rest _)
                            (push (list (featurep 'supertag-link)
                                        (symbol-file 'supertag-text-link-refresh 'defun)) ld-refresh-events)))
              (with-temp-buffer
                (insert-file-contents file)
                (let ((dirty (buffer-modified-p))
                      (result (if nodes
                                  (supertag--parse-org-nodes-from-current-buffer file)
                                (supertag-sync--parse-file-header))))
                  (princ (format "LD-PARSE-RESULT %S %S refresh=%S graph=%S\n"
                                 ld-case result ld-refresh-events (reverse ld-events)))
                  (should ld-refresh-events)
                  (if nodes
                      (if plain
                          (progn (should (= 1 (length result)))
                                 (should (equal "heading-id" (plist-get (car result) :id)))
                                 (should (equal '("target") (plist-get (car result) :ref-to))))
                        (should-not result))
                    (should (equal (if plain "file-id" nil) (plist-get result :id)))
                    (should (equal (if plain '("target") nil) (plist-get result :ref-to))))
                  (should (equal text (buffer-string)))
                  (should (eq dirty (buffer-modified-p)))))
              (should (equal text (with-temp-buffer (insert-file-contents file) (buffer-string))))
              (should (equal facts (prin1-to-string (and (boundp 'supertag--store) supertag--store))))
              ;; First Org parser setup can load native protocol modules.
              ;; Preserve every preexisting entry, while no Link-owned type is added.
              (dolist (entry registry)
                (should (equal entry (assoc (car entry) org-link-parameters))))
              (should (= 0 (hash-table-count supertag-text-link--owned-registrations)))
              (princ (format "LD-REGISTRY-ADDED %S\n"
                             (cl-set-difference (mapcar #'car org-link-parameters)
                                                (mapcar #'car registry) :test #'equal)))
              (if ld-before (should-not (featurep 'supertag-link))
                (should (featurep 'supertag-link))
                (should (member "supertag-link" ld-events)))))
           ('protocol
            (supertag--ensure-store)
            (setq supertag-text-link-relation-types '("ld-config" "ld-config")
                  supertag-text-link--session-types '("ld-session"))
            (supertag-store-put-entity :relations "projected"
             '(:id "projected" :from "a" :to "b" :type :reference
               :kind :document-link :origin :org :relation-name "ld-projected"))
            (should (equal '("ld-config" "ld-session") (supertag-text-link-relation-types)))
            (should (equal '("ld-config" "ld-projected" "ld-session") (supertag-text-link-candidates)))
            (should-error (supertag-text-link-validate-type "") :type 'user-error)
            (should-error (supertag-text-link-validate-type "id") :type 'user-error)
            (supertag-text-link-refresh)
            (let ((registry (copy-tree org-link-parameters)))
              (supertag-text-link-refresh) (should (equal registry org-link-parameters)))
            (should-not (assoc "ld-projected" org-link-parameters))
            (let* ((file (expand-file-name "target.org" ld-tmp))
                   (text "* Target\n:PROPERTIES:\n:ID: ld-target\n:END:\nBody\n"))
              (with-temp-file file (insert text))
              (supertag-store-put-entity :nodes "ld-target"
               (list :id "ld-target" :title "Target" :file file :pos 1))
              (let ((facts (prin1-to-string supertag--store)))
                (save-window-excursion
                  (with-temp-buffer
                    (org-mode) (insert "[[ld-config:ld-target]]") (goto-char (point-min))
                    (org-open-at-point)
                    (should (equal (file-truename file) (file-truename (buffer-file-name))))
                    (should (equal "ld-target" (org-entry-get nil "ID")))))
                (should (equal facts (prin1-to-string supertag--store))))
              (should (equal text (with-temp-buffer (insert-file-contents file) (buffer-string)))))
            (setq supertag-text-link-relation-types nil)
            (supertag-text-link-refresh)
            (should-not (assoc "ld-config" org-link-parameters))
            (org-link-set-parameters "ld-session" :follow #'ignore)
            (supertag-text-link-clear-registrations)
            (should (eq #'ignore (org-link-get-parameter "ld-session" :follow)))
            (setq supertag-text-link--session-types nil
                  supertag-text-link-relation-types '("ld-new" "ld-session"))
            (let ((registry (copy-tree org-link-parameters)))
              (should-error (supertag-text-link-refresh) :type 'user-error)
              (should (equal registry org-link-parameters))
              (should-not (assoc "ld-new" org-link-parameters)))
            (princ "LD-PROTOCOL-REAL-OUTPUT owned-third-party-navigation\n"))
           ('failure
            ;; Validation succeeds; existing invalid configuration makes real refresh fail.
            (setq supertag-text-link-relation-types '("id")
                  supertag-text-link--session-types '("ld-kept"))
            (let ((previous supertag-text-link--session-types)
                  (registry (copy-tree org-link-parameters)))
              (should (equal '(user-error "Org link protocol is reserved: id")
                             (should-error (supertag-text-link-accept-session-type "ld-new"))))
              (should (eq previous supertag-text-link--session-types))
              (should (equal registry org-link-parameters)))
            (princ "LD-FAILURE-RESTORED\n"))
           ('preset
            (should (eq ld-hash supertag-text-link--owned-registrations))
            (should (equal '("ld-config") supertag-text-link-relation-types))
            (should (equal '("ld-session") supertag-text-link--session-types))
            (should-not (assoc "ld-config" org-link-parameters))
            (let ((cell (symbol-function 'supertag-text-link-refresh)))
              (require (intern (file-name-base ld-entry)))
              (should (eq cell (symbol-function 'supertag-text-link-refresh))))
            (load (expand-file-name ld-entry ld-root) nil nil t)
            (should (eq ld-hash supertag-text-link--owned-registrations))
            (should (equal '("ld-session") supertag-text-link--session-types))
            (should-not (assoc "ld-config" org-link-parameters))
            (supertag-text-link-refresh)
            (should (eq #'supertag-text-link-follow (org-link-get-parameter "ld-config" :follow)))
            (princ "LD-PRESET-RELOAD-REAL-REGISTRATION\n"))
           ('named
            (setq supertag-text-link-relation-types '("ld-named"))
            (with-temp-buffer
              (org-mode)
              (insert "* Named\n:PROPERTIES:\n:ID: ld-source\n:END:\n[[ld-named:ld-target]]\n")
              (when (getenv "SUPERTAG_LD_REMOVE_TYPE_CAPABILITY")
                (supertag-text-link-refresh)
                (fmakunbound 'supertag-text-link-relation-type-p))
              (let ((nodes (supertag--parse-org-nodes-from-current-buffer
                            (expand-file-name "named.org" ld-tmp))))
                (princ (format "LD-NAMED-REAL-RESULT %S\n" nodes))
                (should (equal '((:relation-name "ld-named" :target-id "ld-target"))
                               (plist-get (car nodes) :named-links))))))
           (_ (error "Unknown LD case %S" ld-case))))
     (princ (format "LD-DONE %S %s\n" ld-case ld-entry))))

(defun supertag-add-link-test--ld-child (case entry)
  "Run independent LD CASE against ENTRY in a fresh isolated source process."
  (let* ((tmp (make-temp-file "supertag-ld-" t))
         (root (file-name-as-directory (or (getenv "SUPERTAG_LD_ROOT") supertag-add-link-test--root)))
         (before (equal (getenv "SUPERTAG_LD_STAGE") "before"))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (process-environment (copy-sequence process-environment))
         (script (expand-file-name "case.el" tmp))
         (evidence (getenv "SUPERTAG_LD_EVIDENCE")))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert ";;; -*- lexical-binding: t; -*-\n")
            (prin1 `(setq ld-root ,root ld-tmp ,tmp ld-before ,before ld-case ',case ld-entry ,entry) (current-buffer))
            (terpri (current-buffer))
            (prin1 `(condition-case err
                        (unwind-protect ,supertag-add-link-test--ld-program
                          (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
                          (mapc #'cancel-timer (append timer-list timer-idle-list)))
                      (error (princ (format "LD-ERROR %S\n" err)) (kill-emacs 1))) (current-buffer)))
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (with-temp-buffer
            (let ((status (apply #'call-process program nil t nil
                                 (append '("-Q" "--batch")
                                         (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                         (list "-L" root "-l" script)))))
              (when evidence
                (make-directory evidence t)
                (let ((base (expand-file-name (format "%s-%s" case (file-name-base entry)) evidence)))
                  (copy-file script (concat base ".el") t)
                  (write-region (point-min) (point-max) (concat base ".log") nil 'silent)
                  (with-temp-file (concat base ".exit") (insert (format "%s\n" status)))))
              (princ (buffer-string))
              (should (equal 0 status))
              (should (string-match-p (format "LD-DONE %s" case) (buffer-string))))))
      (delete-directory tmp t))))

(ert-deftest supertag-add-link-ld-header-empty () (supertag-add-link-test--ld-child 'header-empty "supertag-services-sync.el"))
(ert-deftest supertag-add-link-ld-header-plain () (supertag-add-link-test--ld-child 'header-plain "supertag-services-sync.el"))
(ert-deftest supertag-add-link-ld-nodes-empty () (supertag-add-link-test--ld-child 'nodes-empty "supertag-services-sync.el"))
(ert-deftest supertag-add-link-ld-nodes-plain () (supertag-add-link-test--ld-child 'nodes-plain "supertag-services-sync.el"))
(ert-deftest supertag-add-link-ld-protocol () (supertag-add-link-test--ld-child 'protocol "supertag-services-sync.el"))
(ert-deftest supertag-add-link-ld-failure () (supertag-add-link-test--ld-child 'failure "supertag-services-sync.el"))
(ert-deftest supertag-add-link-ld-preset ()
  (dolist (entry '("supertag-services-sync.el" "supertag-link.el"))
    (supertag-add-link-test--ld-child 'preset entry)))
(ert-deftest supertag-add-link-ld-named () (supertag-add-link-test--ld-child 'named "supertag-services-sync.el"))
(ert-deftest supertag-add-link-ld-qd ()
  (dolist (entry '("supertag-services-sync.el" "supertag-link.el"))
    (supertag-add-link-test--ld-child 'qd entry)))
(ert-deftest supertag-add-link-ld-qd-org () (supertag-add-link-test--ld-child 'qd-org "supertag-services-sync.el"))
(ert-deftest supertag-add-link-ld-owner () (supertag-add-link-test--ld-child 'owner "supertag-link.el"))

;; V2-VAULT-A: independent stage controls; older slice helpers are unchanged.
(defconst supertag-add-link-test--va-program
  '(progn
     (require 'ert)
     (require 'cl-lib)
     (setq user-emacs-directory (file-name-as-directory va-tmp)
           default-directory (file-name-as-directory va-tmp)
           supertag-data-directory (expand-file-name "data/" va-tmp)
           supertag--base-data-directory supertag-data-directory
           supertag-db-file (expand-file-name "store.el" va-tmp)
           supertag-db-backup-directory (expand-file-name "backup/" va-tmp)
           supertag-sync-state-file (expand-file-name "state.el" va-tmp)
           org-id-locations-file (expand-file-name "ids" va-tmp)
           after-init-time nil
           supertag-sync-auto-start nil
           supertag-vault-auto-switch nil
           supertag-vault-modeline-indicator nil
           supertag-view-node-auto-show nil
           supertag-tag-auto-enable nil
           load-prefer-newer t)
     (let* ((a (file-name-as-directory (expand-file-name "a" va-tmp)))
            (b (file-name-as-directory (expand-file-name "b" va-tmp)))
            (outside (file-name-as-directory (expand-file-name "outside" va-tmp)))
            (org-root (file-name-as-directory (expand-file-name "org" va-tmp)))
            (entry (if va-before "supertag-services-vault-selection.el" "supertag-vault.el"))
            (expected-owner (if va-before "supertag-services-vault-selection.el" "supertag-vault.el"))
            (symbols '(supertag-vault-selection-normalize-path
                       supertag-vault-selection--normalized-roots
                       supertag-vault-selection-effective-root
                       supertag-vault-selection-effective-directories)))
       (dolist (dir (list a b outside org-root)) (make-directory dir t))
       ;; Builtin Org first-load hooks are measured independently; no project preload.
       (when (and (not va-before) (memq va-case '(template template-sync)))
         (require 'org) (require 'org-element) (require 'org-id))
       (let* ((dirs (list a b))
              (tree-before (directory-files-recursively va-tmp "." t))
              (hooks '(emacs-startup-hook kill-emacs-hook org-mode-hook enable-theme-functions))
              (hook-before (mapcar (lambda (s) (and (boundp s) (copy-tree (symbol-value s)))) hooks))
              (timers (copy-sequence timer-list))
              (idle-timers (copy-sequence timer-idle-list)))
         (setq supertag-sync-directories dirs
               supertag-sync-directories-mode 'vaults
               supertag-active-sync-directory b
               org-directory org-root)
         (should-not (fboundp 'supertag--effective-sync-directories))
         (dolist (feature '(supertag supertag-services-sync supertag-node supertag-tag
                           supertag-query document-fixture supertag-document-test-fixture))
           (should-not (featurep feature)))
         (if (memq va-case '(template template-sync))
             (load (expand-file-name (if va-before "supertag-services-template.el" "supertag-service-org.el") va-root) nil nil t)
           (unless (eq va-case 'sync)
             (load (expand-file-name entry va-root) nil nil t)))
         (unless (eq va-case 'sync)
           (princ (format "VA-ENTRY %S %s actual-owner=%S\n" va-case entry
                          (symbol-file 'supertag-vault-selection-effective-root 'defun)))
           ;; Run the actual path operation before checking structure or wrong expectations.
           (let ((actual (supertag-vault-selection-effective-root 'vaults dirs b)))
             (princ (format "VA-ACTUAL-ROOT %S\n" actual))
             (should (equal b actual)))
           (dolist (symbol symbols)
             (should (equal expected-owner (file-name-nondirectory (symbol-file symbol 'defun)))))
           (if va-before
               (should-not (file-exists-p (expand-file-name "supertag-vault.el" va-root)))
             (should-not (file-exists-p (expand-file-name "supertag-services-vault-selection.el" va-root)))
             (should-not (featurep 'supertag-services-vault-selection))
             (should-error (require 'supertag-services-vault-selection) :type 'file-missing))
           (dolist (feature '(supertag supertag-services-sync supertag-node supertag-tag supertag-query))
             (should-not (featurep feature)))
           (if (and (not va-before) (memq va-case '(template template-sync)))
               (progn (should (featurep 'supertag-core-store))
                      (should (boundp 'supertag--store)))
             (should-not (boundp 'supertag--store)))
           (should-not (fboundp 'supertag--effective-sync-directories))
           (should (equal hook-before
                          (mapcar (lambda (s) (and (boundp s) (symbol-value s))) hooks)))
           (should (equal timers timer-list))
           (should (equal idle-timers timer-idle-list))
           (should (eq dirs supertag-sync-directories))
           (should (eq b supertag-active-sync-directory))
           (should (equal tree-before (directory-files-recursively va-tmp "." t))))
         (pcase va-case
           ('entry
            (let ((cells (mapcar #'symbol-function symbols)))
              (require (intern (file-name-base entry)))
              (cl-mapc (lambda (symbol cell) (should (eq cell (symbol-function symbol)))) symbols cells))
            (let ((definitions (mapcar #'symbol-function symbols)))
              (load (expand-file-name entry va-root) nil nil t)
              ;; Explicit defun reload promises form equality, not function identity.
              (should (equal definitions (mapcar #'symbol-function symbols))))
            (let ((cells (mapcar #'symbol-function symbols)))
              (load (expand-file-name (if va-before "supertag-services-template.el" "supertag-service-org.el") va-root) nil nil t)
              (should (equal (expand-file-name "concepts.org" b) (supertag-template--default-file)))
              (cl-mapc (lambda (symbol cell) (should (eq cell (symbol-function symbol)))) symbols cells)))
           ('selection
            (dolist (bad '(nil "" 7 t))
              (should-not (supertag-vault-selection-normalize-path bad)))
            (should (equal a (supertag-vault-selection-normalize-path (directory-file-name a))))
            (should (equal a (supertag-vault-selection-normalize-path (concat a "../a"))))
            (should (equal a (supertag-vault-selection-effective-root 'vaults dirs outside)))
            (should (equal a (supertag-vault-selection-effective-root 'vaults dirs nil)))
            (should (equal b (supertag-vault-selection-effective-root 'vaults (list b a b) nil)))
            (should-not (supertag-vault-selection-effective-root 'vaults nil b))
            (should-not (supertag-vault-selection-effective-root 'vaults 7 b))
            (should-not (supertag-vault-selection-effective-root 'unified dirs b))
            (should-not (supertag-vault-selection-effective-directories 'vaults nil b))
            (should (equal (list b) (supertag-vault-selection-effective-directories 'vaults dirs b)))
            (dolist (mode '(unified nil unknown))
              (dolist (input (list dirs nil "not-a-list"))
                (should (eq input (supertag-vault-selection-effective-directories mode input b))))))
           ((or 'template 'template-sync)
            (let ((actual (supertag-template--default-file)))
              (princ (format "VA-ACTUAL-TEMPLATE %S\n" actual))
              (should (equal (expand-file-name "concepts.org" b) actual)))
            (when (eq va-case 'template)
              (setq supertag-concept-default-file "explicit.org")
              (should (equal (expand-file-name "explicit.org" va-tmp) (supertag-template--default-file)))
              (setq supertag-concept-default-file nil supertag-active-sync-directory outside)
              (should (equal (expand-file-name "concepts.org" a) (supertag-template--default-file)))
              (setq supertag-sync-directories nil)
              (should (equal (expand-file-name "concepts.org" org-root) (supertag-template--default-file)))
              (setq org-directory nil)
              (should (equal (expand-file-name "concepts.org" va-tmp) (supertag-template--default-file)))
              (setq supertag-sync-directories dirs supertag-active-sync-directory b
                    supertag-sync-directories-mode 'unified)
              (should (equal (expand-file-name "concepts.org" a) (supertag-template--default-file)))
              (setq supertag-sync-directories-mode 'vaults org-directory org-root)))
           ('sync nil)
           (_ (error "Unknown VA case %S" va-case)))
         (unless (memq va-case '(sync template-sync))
           (should (eq dirs supertag-sync-directories))
           (should (eq b supertag-active-sync-directory))
           (if (and (not va-before) (memq va-case '(entry template template-sync)))
               (progn (should (featurep 'supertag-core-store))
                      (should (boundp 'supertag--store)))
             (should-not (boundp 'supertag--store)))
           (should (equal tree-before (directory-files-recursively va-tmp "." t))))
       (when (memq va-case '(sync template-sync))
         (should-not (fboundp 'supertag--effective-sync-directories))
         (load (expand-file-name "supertag-services-sync.el" va-root) nil nil t)
         (should (featurep 'supertag-services-sync))
         (should-not (featurep 'supertag))
         (should-not (fboundp 'supertag--effective-sync-directories))
         (let* ((dirs supertag-sync-directories)
                (actual (supertag-sync--effective-directories))
                (cells (mapcar #'symbol-function symbols)))
           (princ (format "VA-SYNC-BEFORE-MAIN %S same-object=%S\n" actual (eq actual dirs)))
           (should (eq dirs actual))
           (should (= 2 (length actual)))
           ;; Heavy assembly is a distinct phase: no init, startup, kill or auto-sync execution.
           (setq after-init-time nil)
           (load (expand-file-name "supertag.el" va-root) nil nil t)
           (should (featurep 'supertag))
           (should (fboundp 'supertag--effective-sync-directories))
           (should-not (autoloadp (symbol-function 'supertag--effective-sync-directories)))
           (should-not supertag--initialized)
           (let ((actual (supertag-sync--effective-directories)))
             (princ (format "VA-SYNC-AFTER-MAIN %S\n" actual))
             (should (equal (list b) actual)))
           ;; Sync-only does not necessarily load pure selection until main.
           ;; Template-first cells must survive; then both cases lock reload identity.
           (cl-mapc (lambda (symbol cell)
                      (when cell (should (eq cell (symbol-function symbol))))
                      (should (equal expected-owner
                                     (file-name-nondirectory (symbol-file symbol 'defun)))))
                    symbols cells)
           (setq cells (mapcar #'symbol-function symbols))
           (load (expand-file-name "supertag.el" va-root) nil nil t)
           (load (expand-file-name (if va-before "supertag-services-template.el" "supertag-service-org.el") va-root) nil nil t)
           (cl-mapc (lambda (symbol cell) (should (eq cell (symbol-function symbol)))) symbols cells)
           (should (equal (expand-file-name "concepts.org" b) (supertag-template--default-file)))
           (should (equal (list b) (supertag-sync--effective-directories)))
           (princ "VA-MAIN-RELOAD-PRESERVES-OWNER\n")))
       (princ (format "VA-DONE %S\n" va-case))))))

(defun supertag-add-link-test--va-child (case)
  "Execute VA CASE in a genuinely fresh process, separately from suite loading."
  (let* ((tmp (make-temp-file "supertag-va-" t))
         (root (file-name-as-directory (or (getenv "SUPERTAG_VA_ROOT") supertag-add-link-test--root)))
         (before (equal (getenv "SUPERTAG_VA_STAGE") "before"))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (process-environment (copy-sequence process-environment))
         (script (expand-file-name "case.el" tmp))
         (evidence (getenv "SUPERTAG_VA_EVIDENCE")))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert ";;; -*- lexical-binding: t; -*-\n")
            (prin1 `(setq va-root ,root va-tmp ,tmp va-before ,before va-case ',case) (current-buffer))
            (terpri (current-buffer))
            (prin1 `(condition-case err
                        (unwind-protect ,supertag-add-link-test--va-program
                          (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
                          (mapc #'cancel-timer (append timer-list timer-idle-list)))
                      (error (princ (format "VA-ERROR %S\n" err)) (kill-emacs 1))) (current-buffer)))
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (with-temp-buffer
            (let ((status (apply #'call-process program nil t nil
                                 (append '("-Q" "--batch")
                                         (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                         (list "-L" root "-l" script)))))
              (when evidence
                (make-directory evidence t)
                (let ((base (expand-file-name (symbol-name case) evidence)))
                  (copy-file script (concat base ".el") t)
                  (write-region (point-min) (point-max) (concat base ".log") nil 'silent)
                  (with-temp-file (concat base ".exit") (insert (format "%s\n" status)))))
              (princ (buffer-string))
              (should (equal 0 status))
              (should (string-match-p (format "VA-DONE %s" case) (buffer-string))))))
      (delete-directory tmp t))))

(ert-deftest supertag-add-link-va-entry () (supertag-add-link-test--va-child 'entry))
(ert-deftest supertag-add-link-va-selection () (supertag-add-link-test--va-child 'selection))
(ert-deftest supertag-add-link-va-template () (supertag-add-link-test--va-child 'template))
(ert-deftest supertag-add-link-va-sync-first () (supertag-add-link-test--va-child 'sync))
(ert-deftest supertag-add-link-va-template-sync-first () (supertag-add-link-test--va-child 'template-sync))

;; V2-VAULT-B has independent stages; VA and every older slice stay unchanged.
(defconst supertag-add-link-test--vb-program
  '(progn
     (require 'ert)
     (require 'cl-lib)
     (setq user-emacs-directory (file-name-as-directory vb-tmp)
           default-directory (file-name-as-directory vb-tmp)
           after-init-time nil load-prefer-newer t)
     (let* ((specials '(supertag--base-data-directory supertag-data-directory
                       supertag-sync-directories-mode supertag-sync-directories))
            (symbols '(supertag-vault--normalize-path supertag-vault--sanitize-name
                       supertag-vault--id supertag-vault--normalize-vault-root
                       supertag-vault--vault-mode-p supertag-vault--normalized-vaults
                       supertag-vault--find-by-root supertag-vault--find-by-file))
            (expected-owner (if vb-before "supertag.el" "supertag-vault.el"))
            (template (memq vb-case '(unconfigured-template timing)))
            (a (file-name-as-directory (expand-file-name "a" vb-tmp)))
            (b (file-name-as-directory (expand-file-name "b" vb-tmp)))
            (nested (file-name-as-directory (expand-file-name "a/nested" vb-tmp)))
            (base-one (file-name-as-directory (expand-file-name "base-one" vb-tmp)))
            (base-two (file-name-as-directory (expand-file-name "base-two" vb-tmp)))
            (data-one (file-name-as-directory (expand-file-name "data-one" vb-tmp)))
            (data-two (file-name-as-directory (expand-file-name "data-two" vb-tmp))))
       ;; No fixture, setq, defvar with value, or project provider before these checks.
       (dolist (symbol specials) (should-not (boundp symbol)))
       (should-not (fboundp 'supertag--effective-sync-directories))
       (when (and template (not vb-before))
         (require 'org) (require 'org-element) (require 'org-id))
       (let ((hooks (mapcar (lambda (s) (and (boundp s) (copy-tree (symbol-value s))))
                            '(emacs-startup-hook kill-emacs-hook org-mode-hook enable-theme-functions)))
             (timers (copy-sequence timer-list)) (idle (copy-sequence timer-idle-list)))
         (load (expand-file-name (if template (if vb-before "supertag-services-template.el" "supertag-service-org.el") "supertag-vault.el") vb-root) nil nil t)
         (princ (format "VB-PURE-ENTRY case=%S before=%S bound=%S\n"
                        vb-case vb-before (mapcar #'boundp specials)))
         (dolist (symbol specials) (should-not (boundp symbol)))
         (dolist (feature '(supertag supertag-services-sync supertag-core-persistence
                           supertag-node supertag-tag supertag-query document-fixture))
           (should-not (featurep feature)))
         (should-not (fboundp 'supertag--effective-sync-directories))
         (should (equal hooks (mapcar (lambda (s) (and (boundp s) (symbol-value s)))
                                     '(emacs-startup-hook kill-emacs-hook org-mode-hook enable-theme-functions))))
         (should (equal timers timer-list)) (should (equal idle timer-idle-list)))
       (dolist (symbol symbols)
         (if vb-before (should-not (fboundp symbol)) (should (fboundp symbol))))
       (when template
         (setq org-directory vb-tmp)
         (let ((actual (supertag-template--default-file)))
           (princ (format "VB-PURE-TEMPLATE %S\n" actual))
           (should (equal (expand-file-name "concepts.org" vb-tmp) actual))))
       (if (memq vb-case '(unconfigured-vault unconfigured-template))
           (if vb-before
               ;; Old pure entry never exposed these eight definitions: do not call them.
               (princ "VB-BEFORE-UNCONFIGURED-NOT-REACHABLE\n")
             (should-not (supertag-vault--vault-mode-p))
             (should-not (supertag-vault--normalized-vaults))
             (let ((err (should-error (supertag-vault--normalize-vault-root a) :type 'void-variable)))
               (princ (format "VB-UNCONFIGURED-BASE %S\n" err))
               (should (equal '(void-variable supertag--base-data-directory) err)))
             (setq supertag--base-data-directory nil)
             (let ((err (should-error (supertag-vault--normalize-vault-root a) :type 'void-variable)))
               (princ (format "VB-UNCONFIGURED-DATA %S\n" err))
               (should (equal '(void-variable supertag-data-directory) err)))
             (setq supertag-sync-directories-mode 'vaults)
             (let ((err (should-error (supertag-vault--normalized-vaults) :type 'void-variable)))
               (princ (format "VB-UNCONFIGURED-DIRS %S\n" err))
               (should (equal '(void-variable supertag-sync-directories) err)))
             (should-not (featurep 'supertag-core-persistence))
             (should-not (featurep 'supertag-services-sync))
             (should-not (featurep 'supertag)))
         ;; Configured operations below are separate from the genuinely unbound entry.
         (dolist (dir (list a b nested)) (make-directory dir t))
         (setq supertag-data-directory data-one
               supertag-db-file (expand-file-name "store.el" vb-tmp)
               supertag-db-backup-directory (expand-file-name "backup" vb-tmp)
               supertag-sync-state-file (expand-file-name "state.el" vb-tmp)
               org-id-locations-file (expand-file-name "ids" vb-tmp)
               supertag-sync-directories-mode 'vaults
               supertag-sync-directories (list a b)
               supertag-active-sync-directory b
               supertag-sync-auto-start nil supertag-vault-auto-switch nil
               supertag-vault-modeline-indicator nil supertag-view-node-auto-show nil
               supertag-tag-auto-enable nil)
         (if (eq vb-case 'timing)
             (progn
               (should-not (boundp 'supertag--base-data-directory))
               (should-not (fboundp 'supertag--effective-sync-directories))
               (should (equal (expand-file-name "concepts.org" b) (supertag-template--default-file)))
               (load (expand-file-name "supertag-services-sync.el" vb-root) nil nil t)
               (should-not (fboundp 'supertag--effective-sync-directories))
               (should-not (boundp 'supertag--base-data-directory))
               (let ((actual (supertag-sync--effective-directories)))
                 (princ (format "VB-SYNC-BEFORE-MAIN %S\n" actual))
                 (should (eq supertag-sync-directories actual))
                 (should (= 2 (length actual))))
               ;; Change data AFTER pure/Sync load, before main captures the base.
               (setq supertag-data-directory data-two)
               (load (expand-file-name "supertag.el" vb-root) nil nil t)
               (princ (format "VB-MAIN-BASE %S\n" supertag--base-data-directory))
               (should (equal data-two supertag--base-data-directory))
               (should (equal (list b) (supertag-sync--effective-directories)))
               (should-not supertag--initialized))
           (setq supertag--base-data-directory base-one)
           (when vb-before
             ;; Actual before main provider, not fmakunbound/unload or copied definitions.
             (load (expand-file-name "supertag.el" vb-root) nil nil t)
             (should-not supertag--initialized)))
         (let* ((actual (supertag-vault--normalize-vault-root a))
                (facts (and (boundp 'supertag--store) (prin1-to-string supertag--store)))
                (files (directory-files-recursively vb-tmp "." t)))
           (princ (format "VB-BUSINESS-ENTRY %S owner=%S result=%S\n" vb-case
                          (symbol-file 'supertag-vault--normalize-vault-root 'defun) actual))
           (should (equal a (plist-get actual :root)))
           (dolist (symbol symbols)
             (should (equal expected-owner (file-name-nondirectory (symbol-file symbol 'defun)))))
           (pcase vb-case
             ('calculations
              (should-not (supertag-vault--normalize-path nil))
              (should-not (supertag-vault--normalize-path 7))
              (should (equal a (supertag-vault--normalize-path (concat a "../a"))))
              (should (equal "vault" (supertag-vault--sanitize-name nil)))
              (should (equal "vault" (supertag-vault--sanitize-name "***")))
              (should (equal "hello-world" (supertag-vault--sanitize-name " Hello / WORLD ")))
              (should-error (supertag-vault--sanitize-name 7) :type 'wrong-type-argument)
              (should (equal "vault" (supertag-vault--id nil)))
              (let ((id (supertag-vault--id (list :name "A / B" :root a))))
                (princ (format "VB-ACTUAL-ID %S\n" id))
                (should (equal (concat "a-b-" (substring (secure-hash 'sha1 a) 0 10)) id)))
              ;; Caller-side declarations are lexical metadata, not initialization.
              ;; They run only after the genuinely unbound cold-entry checks above.
              (eval
               '(progn
                  (defvar supertag--base-data-directory)
                  (defvar supertag-data-directory)
                  (defvar supertag-sync-directories-mode)
                  (defvar supertag-sync-directories)
              ;; Native lexical lets must dynamically reach the production global reads.
              (let ((supertag--base-data-directory base-two)
                    (supertag-data-directory data-two)
                    (supertag-sync-directories-mode 'vaults)
                    (supertag-sync-directories (list b a nested a)))
                (let* ((node (supertag-vault--normalize-vault-root a))
                       (expected (file-name-as-directory
                                  (expand-file-name (concat "vaults/" (plist-get node :id)) base-two))))
                  (princ (format "VB-DYNAMIC-PATH %S\n" (plist-get node :data-directory)))
                  (should (equal expected (plist-get node :data-directory))))
                (should (equal (list b a nested a)
                               (mapcar (lambda (v) (plist-get v :root)) (supertag-vault--normalized-vaults))))
                (should (equal a (plist-get (supertag-vault--find-by-root a) :root)))
                (should (equal nested (plist-get (supertag-vault--find-by-file
                                                  (expand-file-name "note.org" nested)) :root)))
                (should (equal b (plist-get (supertag-vault--find-by-file
                                             (expand-file-name "note.org" b)) :root))))
              (should (equal base-one supertag--base-data-directory))
              (let ((supertag--base-data-directory nil) (supertag-data-directory data-two))
                (should (string-prefix-p data-two
                                         (plist-get (supertag-vault--normalize-vault-root a) :data-directory))))
              (let ((supertag-sync-directories-mode 'unified))
                (should-not (supertag-vault--normalized-vaults)))
              (let ((supertag-sync-directories nil))
                (should-not (supertag-vault--normalized-vaults)))
              (let ((supertag-sync-directories 7))
                (should-not (supertag-vault--normalized-vaults)))
                  )
               `((base-one . ,base-one) (base-two . ,base-two) (data-two . ,data-two)
                 (a . ,a) (b . ,b) (nested . ,nested)))
              (should-not (supertag-vault--normalize-vault-root nil))
              (should-not (supertag-vault--find-by-root nil))
              (dolist (value '(nil "" 7)) (should-not (supertag-vault--find-by-file value))))
             ('fallback
              (let* ((file (expand-file-name "missing.org" a))
                     (real (symbol-function 'file-truename)) (calls 0))
                (cl-letf (((symbol-function 'file-truename)
                           (lambda (path &rest args)
                             (if (equal path file)
                                 (progn (cl-incf calls) (signal 'file-error '("VB path seam")))
                               (apply real path args)))))
                  (let ((found (supertag-vault--find-by-file file)))
                    (princ (format "VB-FALLBACK %S calls=%d\n" found calls))
                    (should (equal a (plist-get found :root)))
                    (should (= 1 calls)))))
              (should-not (supertag-vault--find-by-file (expand-file-name "outside.org" vb-tmp))))
             ('reload
              (let ((cells (mapcar #'symbol-function symbols)))
                (require (if vb-before 'supertag 'supertag-vault))
                (cl-mapc (lambda (symbol cell) (should (eq cell (symbol-function symbol)))) symbols cells)
                (load (expand-file-name (if vb-before "supertag.el" "supertag-vault.el") vb-root) nil nil t)
                (princ (format "VB-EXPLICIT-RELOAD-EQ %S\n"
                               (cl-mapcar (lambda (symbol cell) (eq cell (symbol-function symbol))) symbols cells)))
                (should (equal a (plist-get (supertag-vault--normalize-vault-root a) :root))))
              (let ((cells (mapcar #'symbol-function symbols)))
                (load (expand-file-name "supertag.el" vb-root) nil nil t)
                (load (expand-file-name (if vb-before "supertag-services-template.el" "supertag-service-org.el") vb-root) nil nil t)
                (if vb-before
                    (princ (format "VB-MAIN-RELOAD-FUNCTION-EQUAL %S\n"
                                   (equal cells (mapcar #'symbol-function symbols))))
                  (cl-mapc (lambda (symbol cell) (should (eq cell (symbol-function symbol)))) symbols cells))
                (should (equal b (plist-get (supertag-vault--find-by-root b) :root)))))
             ('timing nil)
             (_ (error "Unknown VB business case %S" vb-case)))
           ;; Reload deliberately enters main's heavy module assembly; compare
           ;; Store facts only across computations, not across that first load.
           (unless (eq vb-case 'reload)
             (should (equal facts (and (boundp 'supertag--store) (prin1-to-string supertag--store)))))
           (should (equal files (directory-files-recursively vb-tmp "." t)))))
       (princ (format "VB-DONE %S\n" vb-case)))))

(defun supertag-add-link-test--vb-child (case)
  "Run VB CASE in its own process, without a preconfigured project fixture."
  (let* ((tmp (make-temp-file "supertag-vb-" t))
         (root (file-name-as-directory (or (getenv "SUPERTAG_VB_ROOT") supertag-add-link-test--root)))
         (before (equal (getenv "SUPERTAG_VB_STAGE") "before"))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (process-environment (copy-sequence process-environment))
         (script (expand-file-name "case.el" tmp))
         (evidence (getenv "SUPERTAG_VB_EVIDENCE")))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert ";;; -*- lexical-binding: t; -*-\n")
            (prin1 `(setq vb-root ,root vb-tmp ,tmp vb-before ,before vb-case ',case) (current-buffer))
            (terpri (current-buffer))
            (prin1 `(condition-case err
                        (unwind-protect ,supertag-add-link-test--vb-program
                          (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
                          (mapc #'cancel-timer (append timer-list timer-idle-list)))
                      (error (princ (format "VB-ERROR %S\n" err)) (kill-emacs 1))) (current-buffer)))
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (with-temp-buffer
            (let ((status (apply #'call-process program nil t nil
                                 (append '("-Q" "--batch")
                                         (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                         (list "-L" root "-l" script)))))
              (when evidence
                (make-directory evidence t)
                (let ((base (expand-file-name (symbol-name case) evidence)))
                  (copy-file script (concat base ".el") t)
                  (write-region (point-min) (point-max) (concat base ".log") nil 'silent)
                  (with-temp-file (concat base ".exit") (insert (format "%s\n" status)))))
              (princ (buffer-string))
              (should (equal 0 status))
              (should (string-match-p (format "VB-DONE %s" case) (buffer-string))))))
      (delete-directory tmp t))))

(ert-deftest supertag-add-link-vb-unconfigured-vault () (supertag-add-link-test--vb-child 'unconfigured-vault))
(ert-deftest supertag-add-link-vb-unconfigured-template () (supertag-add-link-test--vb-child 'unconfigured-template))
(ert-deftest supertag-add-link-vb-calculations () (supertag-add-link-test--vb-child 'calculations))
(ert-deftest supertag-add-link-vb-fallback () (supertag-add-link-test--vb-child 'fallback))
(ert-deftest supertag-add-link-vb-reload () (supertag-add-link-test--vb-child 'reload))
(ert-deftest supertag-add-link-vb-timing () (supertag-add-link-test--vb-child 'timing))
