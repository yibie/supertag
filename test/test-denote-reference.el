;;; test-denote-reference.el --- file-node identity and link tests -*- lexical-binding: t; -*-
;; Run: emacs --batch -Q -L . -l test/test-denote-reference.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'org-id)
(require 'supertag-core-store)
(require 'supertag-node)
(require 'supertag-link)
(require 'supertag-link)
(require 'supertag-services-sync)
(if (equal (getenv "SUPERTAG_SYA_STAGE") "before")
      (require 'supertag-ui-commands)
    (require 'supertag-services-sync))

(defun test-denote-reference--extract (text)
  "Return references extracted from TEXT."
  (with-temp-buffer
    (org-mode)
    (insert text)
    (supertag--extract-refs (org-element-contents (org-element-parse-buffer)))))

(defmacro test-denote-reference--with-env (&rest body)
  "Run BODY with an isolated store and temporary Org files."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "supertag-file-node-test" t))
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
       (ignore-errors
         (dolist (buffer (buffer-list))
           (when (and (buffer-file-name buffer)
                      (string-prefix-p tmp (buffer-file-name buffer)))
             (kill-buffer buffer))))
       (ignore-errors (delete-directory tmp t)))))

(ert-deftest file-node-links-are-extracted-independent-of-policy ()
  "Both supported physical link types are parsed without a global mode switch."
  (let ((supertag-file-id-source 'org-roam))
    (should (equal (test-denote-reference--extract
                    "[[denote:20260705T120000][File]] [[id:custom-id][Node]]")
                   '("20260705T120000" "custom-id")))))

(ert-deftest file-node-without-persisted-id-is-skipped ()
  "A file without a persisted identity must not receive a transient node ID."
  (test-denote-reference--with-env
    (let ((supertag-file-id-source 'org-roam))
      (should-not
       (supertag-sync--upsert-file-node
        (expand-file-name "plain.org" supertag-data-directory)
        '(:id nil :title "Plain" :file-tags nil)
        nil))
      (should (= 0 (hash-table-count (supertag-store-get-collection :nodes)))))))

(ert-deftest file-node-auto-detects-org-id-and-denote-identity ()
  "Auto policy records the physical link type with each file identity."
  (let ((supertag-file-id-source 'auto))
    (with-temp-buffer
      (org-mode)
      (insert ":PROPERTIES:\n:ID:       roam-id\n:END:\n#+TITLE: Roam\n")
      (should (equal (supertag-sync--parse-file-header)
                     '(:id "roam-id" :link-type id :title "Roam"
                       :file-tags nil :ref-to nil))))
    (with-temp-buffer
      (org-mode)
      (insert "#+TITLE: Denote\n#+IDENTIFIER: 20260705T120000\n")
      (should (equal (supertag-sync--parse-file-header)
                     '(:id "20260705T120000" :link-type denote
                       :title "Denote" :file-tags nil :ref-to nil))))))

(ert-deftest file-node-link-format-comes-from-target-node ()
  "Mixed stores format links from node metadata, not a global mode."
  (test-denote-reference--with-env
    (supertag-node-create '(:id "roam-id" :level 0 :title "Roam" :link-type id))
    (supertag-node-create '(:id "denote-id" :level 0 :title "Denote" :link-type denote))
    (supertag-node-create '(:id "heading-id" :level 1 :title "Heading"))
    (should (string= (supertag-node-format-link "roam-id" "Roam")
                     "[[id:roam-id][Roam]]"))
    (should (string= (supertag-node-format-link "denote-id" "Denote")
                     "[[denote:denote-id][Denote]]"))
    (should (string= (supertag-node-format-link "heading-id" "Heading")
                     "[[id:heading-id][Heading]]"))))

(ert-deftest denote-reference-does-not-materialize-target-backlink ()
  "A Denote source relation is queryable without changing target Org."
  (test-denote-reference--with-env
    (let ((source-file (expand-file-name "20260705T120000--source.org" tmp))
          (target-file (expand-file-name "target.org" tmp)))
      (with-temp-file source-file
        (insert "#+TITLE: Source\n#+IDENTIFIER: 20260705T120000\n"))
      (with-temp-file target-file
        (insert "* Target\n:PROPERTIES:\n:ID:       target-id\n:END:\n\nBody.\n"))
      (supertag-node-create
       (list :id "20260705T120000" :level 0 :title "Source"
             :link-type 'denote :file source-file :position 1))
      (with-current-buffer (find-file-noselect target-file)
        (org-mode)
        (org-id-update-id-locations nil t)
        (goto-char (point-min))
        (supertag-node-sync-at-point))
      (let ((target-text (with-temp-buffer
                           (insert-file-contents target-file)
                           (buffer-string))))
        (should (supertag-relation-add-reference "20260705T120000" "target-id"))
        (should (equal target-text
                       (with-temp-buffer
                         (insert-file-contents target-file)
                         (buffer-string)))))
      (with-current-buffer (find-file-noselect target-file)
        (goto-char (point-min))
        (should-not (re-search-forward "20260705T120000" nil t)))
      (should (equal '("20260705T120000")
                     (mapcar (lambda (relation) (plist-get relation :from))
                             (supertag-relation-find-by-to
                              "target-id" :reference)))))))

(provide 'test-denote-reference)
