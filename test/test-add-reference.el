;;; test-add-reference.el --- Forward-only Document Link tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'org-id)

(when load-file-name
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)
(require 'supertag-ops-node)
(require 'supertag-ops-relation)
(require 'supertag-services-ui)
(require 'supertag-services-sync)
(require 'supertag-ui-commands)
(require 'supertag-view-node)
(require 'supertag-view-table)

(defvar supertag-file-id-source 'org-roam)

(defmacro add-reference-test--with-clean-env (&rest body)
  "Run BODY with an isolated Store and temporary Org files."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "supertag-add-reference-test" t))
          (supertag-data-directory tmp)
          (supertag-db-file (expand-file-name "supertag-db.el" tmp))
          (supertag-db-backup-directory (expand-file-name "backups" tmp))
          (supertag--store nil)
          (supertag--store-origin nil)
          (org-id-locations nil)
          (org-id-files nil)
          (org-id-locations-file (expand-file-name "org-id-locations" tmp)))
     (unwind-protect
         (progn
           (supertag--ensure-store)
           ,@body)
       (dolist (buffer (buffer-list))
         (when-let ((file (buffer-file-name buffer)))
           (when (string-prefix-p tmp file)
             (kill-buffer buffer))))
       (ignore-errors (delete-directory tmp t)))))

(defun add-reference-test--file-hash (file)
  "Return FILE's SHA-256 hash."
  (with-temp-buffer
    (insert-file-contents file)
    (secure-hash 'sha256 (current-buffer))))

(defun add-reference-test--sync-heading (file id)
  "Visit FILE and project heading ID into the Store."
  (with-current-buffer (find-file-noselect file)
    (org-mode)
    (org-id-update-id-locations nil t)
    (goto-char (point-min))
    (re-search-forward (format ":ID:[ \t]+%s" (regexp-quote id)))
    (org-back-to-heading t)
    (supertag-node-sync-at-point)))

(ert-deftest add-reference-writes-source-only-and-derives-backlink ()
  "A new Document Link changes only source Org; all backlink views query it."
  (add-reference-test--with-clean-env
    (let ((source-file (expand-file-name "source.org" tmp))
          (target-file (expand-file-name "target.org" tmp)))
      (with-temp-file source-file
        (insert "* Source\n:PROPERTIES:\n:ID:       source-id\n:END:\n\nCursor here.\n"))
      (with-temp-file target-file
        (insert "* Target\n:PROPERTIES:\n:ID:       target-id\n:END:\n\nTarget body.\n"))
      (add-reference-test--sync-heading source-file "source-id")
      (add-reference-test--sync-heading target-file "target-id")
      (let ((target-hash (add-reference-test--file-hash target-file)))
        (with-current-buffer (find-file-noselect source-file)
          (goto-char (point-min))
          (cl-letf (((symbol-function 'supertag-ui-select-node)
                     (lambda (&rest _) "target-id")))
            (supertag-add-reference)))
        (should (string= target-hash
                         (add-reference-test--file-hash target-file)))
        (with-temp-buffer
          (insert-file-contents target-file)
          (should-not (re-search-forward "source-id" nil t)))
        (with-temp-buffer
          (insert-file-contents source-file)
          (should (looking-at-p "\\* Source$"))
          (should (re-search-forward "\\[\\[id:target-id\\]\\[Target\\]\\]" nil t)))
        (let ((relation (car (supertag-relation-find-by-to
                              "target-id" :reference))))
          (should relation)
          (should (equal "source-id" (plist-get relation :from)))
          (should (supertag-relation-document-link-p relation)))
        (should (equal '("source-id")
                       (supertag-view-node--get-referenced-by "target-id")))
        (should (equal '("source-id")
                       (supertag-view-table--get-referenced-by "target-id")))
        (should (equal '("source-id")
                       (plist-get (supertag-view-build-node-state "target-id")
                                  :refs-from)))))))

(ert-deftest remove-reference-removes-source-only ()
  "Removing a Document Link leaves target Org untouched and refreshes projection."
  (add-reference-test--with-clean-env
    (let ((source-file (expand-file-name "source.org" tmp))
          (target-file (expand-file-name "target.org" tmp)))
      (with-temp-file source-file
        (insert "* Source\n:PROPERTIES:\n:ID:       source-id\n:END:\n\n[[id:target-id][Target]]\n"))
      (with-temp-file target-file
        (insert "* Target\n:PROPERTIES:\n:ID:       target-id\n:END:\n\nTarget body.\n"))
      (add-reference-test--sync-heading target-file "target-id")
      (add-reference-test--sync-heading source-file "source-id")
      (let ((target-hash (add-reference-test--file-hash target-file)))
        (with-current-buffer (find-file-noselect source-file)
          (goto-char (point-max))
          (cl-letf (((symbol-function 'supertag-ui-select-reference-to-remove)
                     (lambda (_) "target-id")))
            (supertag-remove-reference)))
        (should (string= target-hash
                         (add-reference-test--file-hash target-file)))
        (with-temp-buffer
          (insert-file-contents source-file)
          (should-not (re-search-forward "target-id" nil t)))
        (should-not (supertag-relation-find-between
                     "source-id" "target-id" :reference))
        (should-not (supertag-view-node--get-referenced-by "target-id"))))))

(ert-deftest add-reference-file-node-source-survives-reprojection ()
  "A file-level forward link remains a Document Link after another projection."
  (add-reference-test--with-clean-env
    (let ((source-file (expand-file-name "source.org" tmp))
          (target-file (expand-file-name "target.org" tmp))
          (supertag-file-id-source 'org-roam))
      (with-temp-file source-file
        (insert ":PROPERTIES:\n:ID:       file-id\n:END:\n#+TITLE: Source\n\nSource body.\n"))
      (with-temp-file target-file
        (insert "* Target\n:PROPERTIES:\n:ID:       target-id\n:END:\n\nTarget body.\n"))
      (supertag-ui--ensure-file-node-synced source-file)
      (add-reference-test--sync-heading target-file "target-id")
      (let ((target-hash (add-reference-test--file-hash target-file)))
        (with-current-buffer (find-file-noselect source-file)
          (org-mode)
          (goto-char (point-min))
          (re-search-forward "Source body")
          (cl-letf (((symbol-function 'supertag-ui-select-node)
                     (lambda (&rest _) "target-id")))
            (supertag-add-reference)))
        (should (string= target-hash
                         (add-reference-test--file-hash target-file)))
        (supertag-ui--ensure-file-node-synced source-file)
        (let ((relation (car (supertag-relation-find-between
                              "file-id" "target-id" :reference))))
          (should (supertag-relation-document-link-p relation)))))))

(ert-deftest add-reference-and-create-preserves-region-when-source-needs-id ()
  "Creating the source ID must not invalidate the selected text region."
  (add-reference-test--with-clean-env
    (let ((source-file (expand-file-name "source.org" tmp))
          (target-file (expand-file-name "target.org" tmp))
          (generated-ids '("source-id" "target-id")))
      (with-temp-file source-file
        (insert "* Source\n\nCreate me.\n"))
      (with-temp-file target-file)
      (with-current-buffer (find-file-noselect source-file)
        (org-mode)
        (goto-char (point-min))
        (re-search-forward "Create me")
        (let ((beg (match-beginning 0))
              (end (match-end 0))
              (supertag-concept-default-file target-file))
          (cl-letf (((symbol-function 'org-id-new)
                     (lambda (&rest _) (pop generated-ids))))
            (supertag-add-reference-and-create beg end))))
      (with-temp-buffer
        (insert-file-contents source-file)
        (should (re-search-forward "^:ID:[ \t]+source-id$" nil t))
        (should (re-search-forward
                 "^\\[\\[id:target-id\\]\\[Create me\\]\\]\\.$" nil t))
        (should-not (re-search-forward "Create me\\[\\[" nil t)))
      (with-temp-buffer
        (insert-file-contents target-file)
        (should (re-search-forward "^\\* Create me$" nil t))
        (should (re-search-forward "^:ID:[ \t]+target-id$" nil t)))
      (let ((relation (car (supertag-relation-find-between
                            "source-id" "target-id" :reference))))
        (should (supertag-relation-document-link-p relation))
        (should (eq :org (plist-get relation :origin)))))))

(ert-deftest add-reference-and-create-projects-existing-id-source ()
  "An existing source ID derives the same Document Link relation."
  (add-reference-test--with-clean-env
    (let ((source-file (expand-file-name "source.org" tmp))
          (target-file (expand-file-name "target.org" tmp)))
      (with-temp-file source-file
        (insert "* Source\n:PROPERTIES:\n:ID:       source-id\n:END:\n\nCreate me.\n"))
      (with-temp-file target-file)
      (add-reference-test--sync-heading source-file "source-id")
      (with-current-buffer (find-file-noselect source-file)
        (goto-char (point-min))
        (re-search-forward "Create me")
        (let ((supertag-concept-default-file target-file))
          (cl-letf (((symbol-function 'org-id-new)
                     (lambda (&rest _) "target-id")))
            (supertag-add-reference-and-create
             (match-beginning 0) (match-end 0)))))
      (let ((relation (car (supertag-relation-find-between
                            "source-id" "target-id" :reference))))
        (should (supertag-relation-document-link-p relation))
        (should (eq :org (plist-get relation :origin)))))))

(ert-deftest add-reference-and-create-rejects-unowned-source-before-target ()
  "Do not create a target when the source cannot own a relation."
  (add-reference-test--with-clean-env
    (let ((source-file (expand-file-name "source.org" tmp))
          (target-file (expand-file-name "target.org" tmp))
          (supertag-file-id-source 'disabled))
      (with-temp-file source-file
        (insert "Create me.\n"))
      (with-temp-file target-file)
      (with-current-buffer (find-file-noselect source-file)
        (org-mode)
        (goto-char (point-min))
        (re-search-forward "Create me")
        (let ((supertag-concept-default-file target-file))
          (should-error
           (supertag-add-reference-and-create
            (match-beginning 0) (match-end 0))
           :type 'user-error)))
      (should (= 0 (file-attribute-size (file-attributes target-file)))))))

(ert-deftest add-reference-and-create-does-not-report-unprojected-success ()
  "A saved link without its Document Link projection is an error."
  (add-reference-test--with-clean-env
    (let ((source-file (expand-file-name "source.org" tmp))
          (target-file (expand-file-name "target.org" tmp)))
      (with-temp-file source-file
        (insert "* Source\n:PROPERTIES:\n:ID:       source-id\n:END:\n\nCreate me.\n"))
      (with-temp-file target-file)
      (add-reference-test--sync-heading source-file "source-id")
      (with-current-buffer (find-file-noselect source-file)
        (goto-char (point-min))
        (re-search-forward "Create me")
        (let ((supertag-concept-default-file target-file))
          (cl-letf (((symbol-function 'org-id-new)
                     (lambda (&rest _) "target-id"))
                    ((symbol-function 'supertag-ui--reproject-containing-node)
                     #'ignore))
            (should-error
             (supertag-add-reference-and-create
              (match-beginning 0) (match-end 0))
             :type 'user-error))))
      (should-not (supertag-relation-find-between
                   "source-id" "target-id" :reference)))))

(provide 'test-add-reference)
;;; test-add-reference.el ends here
