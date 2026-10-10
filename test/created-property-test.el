;;; created-property-test.el --- CREATED property on Tag add -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-tag)
(require 'supertag-service-org)
(require 'supertag-concept)

(defconst supertag-created-property-test--line
  "^:CREATED: +[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} [0-9]\\{2\\}:[0-9]\\{2\\}$"
  "A CREATED line in the default format.")

(defun supertag-created-property-test--count (text)
  "Return the number of CREATED lines in TEXT."
  (let ((count 0) (start 0))
    (while (string-match "^:CREATED:" text start)
      (setq count (1+ count) start (match-end 0)))
    count))

(ert-deftest supertag-created-property-add-tag-writes-it-once ()
  "The first Tag writes CREATED right below ID; later Tags keep it."
  (supertag-document-test-with-vault
    (dolist (tag '("first" "second"))
      (supertag-tag-create (list :id tag :name tag)))
    (supertag-service-org-add-tag "document-node" "first")
    (let ((disk (supertag-document-test-disk file)))
      (should (string-match-p supertag-created-property-test--line disk))
      (should (string-match-p
               "\\`\\* Property Node #first\n:PROPERTIES:\n:ID: document-node\n:CREATED: [^\n]+\n:ZETA: last\n:EMPTY:\n:ALPHA: first\n:END:\nBody.\n\\'"
               disk))
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-min))
        (org-entry-put nil "CREATED" "2020-01-02 03:04")
        (save-buffer))
      (supertag-service-org-add-tag "document-node" "second")
      (let ((after (supertag-document-test-disk file)))
        (should (string-match-p "#second" after))
        (should (string-match-p "^:CREATED: +2020-01-02 03:04$" after))
        (should (= 1 (supertag-created-property-test--count after)))))))

(ert-deftest supertag-created-property-nil-format-writes-nothing ()
  "A nil format turns the creation time off."
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "first" :name "first"))
    (let ((supertag-created-time-format nil))
      (supertag-service-org-add-tag "document-node" "first"))
    (let ((disk (supertag-document-test-disk file)))
      (should (string-match-p "#first" disk))
      (should (= 0 (supertag-created-property-test--count disk))))))

(ert-deftest supertag-created-property-custom-format ()
  "The format is the user's to choose."
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "first" :name "first"))
    (let ((supertag-created-time-format "[%Y-%m-%d]"))
      (supertag-service-org-add-tag "document-node" "first"))
    (should (string-match-p
             "^:CREATED: +\\[[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\]$"
             (supertag-document-test-disk file)))))

(ert-deftest supertag-created-property-file-node-gets-none ()
  "A file-level Tag lives in #+FILETAGS and writes no CREATED."
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "first" :name "first"))
    (let ((filed (expand-file-name "filed.org" tmp)))
      (with-temp-file filed
        (insert ":PROPERTIES:\n:ID: created-file-node\n:END:\n#+title: Filed\n"))
      (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
      (should (supertag-node-get "created-file-node"))
      (supertag-service-org-add-tag "created-file-node" "first")
      (let ((disk (supertag-document-test-disk filed)))
        (should (string-match-p "^#\\+FILETAGS: :first:$" disk))
        (should (= 0 (supertag-created-property-test--count disk)))))))

(ert-deftest supertag-created-property-completion-stamps-new-heading ()
  "Completing a Tag on an ID-less heading writes CREATED below the new ID."
  (supertag-document-test-with-vault
    (let* ((tag (supertag-tag-create '(:name "diary")))
           (tag-id (plist-get tag :id)))
      (with-current-buffer (find-file-noselect plain)
        (goto-char (point-min))
        (end-of-line)
        (insert " #diary")
        (supertag-completion--post-completion-action
         (propertize "diary" 'supertag-tag-id tag-id))
        (goto-char (point-min))
        (let ((node-id (org-entry-get nil "ID")))
          (should (stringp node-id))
          (should (member tag-id (plist-get (supertag-node-get node-id) :tags)))
          (should (string-match-p
                   (concat "\\`\\* Ordinary writing #diary *\n:PROPERTIES:\n"
                           ":ID: +" (regexp-quote node-id)
                           "\n:CREATED: [^\n]+\n:END:\n")
                   (supertag-document-test-disk plain))))))))

(ert-deftest supertag-created-property-typed-tag-stamps-heading ()
  "Typing a known Tag and its delimiter records it and writes CREATED."
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "typed" :name "typed"))
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (end-of-line)
      (insert " #typed ")
      (supertag-completion--auto-record-on-boundary))
    (should (member "typed" (plist-get (supertag-node-get "document-node") :tags)))
    (let ((disk (supertag-document-test-disk file)))
      (should (string-match-p supertag-created-property-test--line disk))
      (should (= 1 (supertag-created-property-test--count disk))))))

(ert-deftest supertag-created-property-created-node-with-tags ()
  "A node created with Tags gets CREATED below its ID; one without does not."
  (supertag-document-test-with-vault
    (supertag-tag-create '(:id "first" :name "first"))
    (let ((tagged (expand-file-name "tagged.org" tmp))
          (bare (expand-file-name "bare.org" tmp))
          (preset (expand-file-name "preset.org" tmp)))
      (dolist (path (list tagged bare preset))
        (with-temp-file path (insert "#+title: Target\n")))
      (let ((id (supertag-service-org-create-node tagged "Tagged" '("first"))))
        (should (string-match-p
                 (concat "^\\* Tagged #first\n:PROPERTIES:\n:ID: +"
                         (regexp-quote id) "\n:CREATED: +[^\n]+\n:END:\n")
                 (supertag-document-test-disk tagged))))
      (supertag-service-org-create-node bare "Bare" nil)
      (should (= 0 (supertag-created-property-test--count
                    (supertag-document-test-disk bare))))
      ;; A template that sets CREATED itself keeps its own value.
      (supertag-service-org-create-node
       preset "Preset" '("first")
       '(:properties (("CREATED" . "2020-01-02 03:04"))))
      (let ((disk (supertag-document-test-disk preset)))
        (should (string-match-p "^:CREATED: +2020-01-02 03:04$" disk))
        (should (= 1 (supertag-created-property-test--count disk)))))))

(ert-deftest supertag-created-property-promote-with-tags ()
  "Promote stamps a heading only when its template adds Tags."
  (let ((tagged (supertag-service-org--promote-text
                 "* Heading\nBody.\n" "promote-id" '("first") nil))
        (kept (supertag-service-org--promote-text
               "* Heading\n:PROPERTIES:\n:CREATED: 2020-01-02 03:04\n:END:\n"
               "promote-id" '("first") nil))
        (bare (supertag-service-org--promote-text
               "* Heading\nBody.\n" "promote-id" nil nil)))
    (should (string-match-p
             ":PROPERTIES:\n:ID: +promote-id\n:CREATED: +[^\n]+\n:END:\nBody.\n"
             tagged))
    (should (string-match-p "^:CREATED: +2020-01-02 03:04$" kept))
    (should (= 1 (supertag-created-property-test--count kept)))
    (should (= 0 (supertag-created-property-test--count bare)))))

(provide 'created-property-test)
;;; created-property-test.el ends here
