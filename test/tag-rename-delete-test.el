;;; tag-rename-delete-test.el --- Org-first tag changes -*- lexical-binding: t; -*-
(require 'document-fixture)
(if (equal (getenv "SUPERTAG_SYA_STAGE") "before")
      (require 'supertag-ui-commands)
    (require 'supertag-tag))

(defmacro supertag-tag-change-test--vault (&rest body)
  (declare (indent 0))
  `(supertag-document-test-with-vault
     (supertag-tag-create '(:id "old" :name "old" :aliases ("alias" "emacs/package")))
     (dolist (pair (list
                   (cons file ":PROPERTIES:\n:ID: file-node\n:END:\n#+TITLE: File\n#+FILETAGS: :old:\nFile body\n")
                   (cons plain "* Alias #alias\n:PROPERTIES:\n:ID: alias-node\n:END:\nAlias body\n* Path #emacs/package\n:PROPERTIES:\n:ID: path-node\n:END:\nPath body\n")))
       (with-current-buffer (find-file-noselect (car pair))
         (erase-buffer) (insert (cdr pair)) (save-buffer)))
     (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
     (should (= 3 (length (supertag-find-nodes-by-tag "old"))))
     (unwind-protect (progn ,@body)
       (when (get-buffer "*Supertag Tag Change*") (kill-buffer "*Supertag Tag Change*")))))

(defun supertag-tag-change-test--snapshot (files)
  (list (mapcar (lambda (file)
                  (with-current-buffer (find-file-noselect file)
                    (list (supertag-document-test-disk file) (buffer-string) (buffer-modified-p))))
                files)
        (prin1-to-string supertag--store)))

(ert-deftest supertag-tag-change-preview-is-zero-write ()
  (supertag-tag-change-test--vault
    (with-current-buffer (find-file-noselect plain)
      (goto-char (point-min)) (search-forward " #alias") (replace-match "")
      (search-forward "Alias body") (replace-match "Alias body #alias")
      (goto-char (point-max)) (insert "Draft"))
    (let* ((before (supertag-tag-change-test--snapshot (list file plain)))
           (report (supertag-tag-change-preview "old" "new")))
      ;; The text enumerator returns one record per occurrence.
      (should (= 3 (length report)))
      (should (equal '("alias" "emacs/package" "old")
                     (sort (mapcar (lambda (record) (plist-get record :token)) report)
                           #'string<)))
      (with-current-buffer "*Supertag Tag Change*"
        (should (derived-mode-p 'special-mode))
        (should (string-match-p "WILL CHANGE: 3" (buffer-string)))
        (should (string-match-p "3 occurrence(s) / 2 file(s)" (buffer-string)))
        (should (string-match-p "FILETAGS" (buffer-string)))
        (should (string-match-p "emacs/package" (buffer-string)))
        (should (string-match-p "Alias body #alias" (buffer-string))))
      (should (equal before (supertag-tag-change-test--snapshot (list file plain)))))))

(ert-deftest supertag-tag-change-rename-confirmed ()
  (supertag-tag-change-test--vault
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "new"))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (supertag-tag-rename "old"))
    (let ((new (supertag-tag-resolve-occurrence "new")))
      (should (supertag-tag-get new))
      (should-not (supertag-tag-get "old"))
      (dolist (id '("file-node" "alias-node" "path-node"))
        (should (equal (list new) (plist-get (supertag-node-get id) :tags))))
    (dolist (path (list file plain))
      (with-current-buffer (find-file-noselect path)
        (should-not (buffer-modified-p))
        (should (equal (buffer-string) (supertag-document-test-disk path)))
        (should-not (string-match-p "#alias\\|#emacs/package\\|:old:" (buffer-string)))
        (should (string-match-p "new" (buffer-string))))))))

(ert-deftest supertag-tag-change-delete-confirmed ()
  (supertag-tag-change-test--vault
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (supertag-delete-tag-everywhere "old"))
    (should-not (supertag-tag-get "old"))
    (dolist (id '("file-node" "alias-node" "path-node"))
      (should-not (plist-get (supertag-node-get id) :tags)))
    (dolist (path (list file plain))
      (with-current-buffer (find-file-noselect path)
        (should-not (buffer-modified-p))
        (should (equal (buffer-string) (supertag-document-test-disk path)))
        (should-not (string-match-p "#alias\\|#emacs/package\\|:old:" (buffer-string)))
        (should (string-match-p "body" (buffer-string)))))))

(ert-deftest supertag-tag-change-cancel-is-zero-write ()
  (supertag-tag-change-test--vault
    (let ((before (supertag-tag-change-test--snapshot (list file plain))))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "new"))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (should-not (supertag-tag-rename "old"))
        (should (equal before (supertag-tag-change-test--snapshot (list file plain))))
        (should-not (supertag-delete-tag-everywhere "old"))
        (should (equal before (supertag-tag-change-test--snapshot (list file plain))))))))

(ert-deftest supertag-tag-change-merge-previews-canonical-target ()
  (supertag-tag-change-test--vault
    (supertag-tag-create '(:id "other" :name "Canonical" :aliases ("destination")))
    (let ((before (supertag-tag-change-test--snapshot (list file plain))) prompt)
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "destination"))
                ((symbol-function 'yes-or-no-p) (lambda (text) (setq prompt text) nil)))
        (should-not (supertag-tag-rename "old")))
      (dolist (part '("Merge" "other" "Canonical")) (should (string-match-p part prompt)))
      (with-current-buffer "*Supertag Tag Change*"
        (should (string-prefix-p "Merge 'old' into existing Tag 'other' (token 'Canonical')"
                                 (buffer-string)))
        (should (string-match-p "3 occurrence(s) / 2 file(s)" (buffer-string))))
      (should (equal before (supertag-tag-change-test--snapshot (list file plain))))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "destination"))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (should (equal "other" (supertag-tag-rename "old"))))
      (dolist (id '("file-node" "alias-node" "path-node"))
        (should (equal '("other") (plist-get (supertag-node-get id) :tags))))
      (dolist (path (list file plain))
        (with-current-buffer (find-file-noselect path)
          (should-not (buffer-modified-p))
          (should (equal (buffer-string) (supertag-document-test-disk path)))
          (should-not (string-match-p "destination\\|#alias\\|#emacs/package\\|:old:" (buffer-string)))
          (should (string-match-p "Canonical" (buffer-string)))))
      (should-not (supertag-tag-get "old")))))

(ert-deftest supertag-tag-change-own-alias-promotes-the-alias ()
  "Renaming a Tag onto its own alias makes that alias the canonical name.
The old guard rejected any token that already resolved to the Tag, which also
blocked resuming an interrupted rename; only a token that is already the
Tag's canonical `:name' is a no-op now."
  (supertag-tag-change-test--vault
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "alias"))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (should (supertag-tag-rename "old")))
    (let ((id (supertag-tag-resolve-occurrence "alias")))
      (should id)
      (should (equal "alias" (plist-get (supertag-tag-get id) :name)))
      (should-not (supertag-tag-resolve-occurrence "old"))
      (dolist (node-id '("file-node" "alias-node" "path-node"))
        (should (member id (plist-get (supertag-node-get node-id) :tags)))))))

(ert-deftest supertag-tag-change-resolution-change-rejects-before-writing ()
  (supertag-tag-change-test--vault
    (let (after-external-change)
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "new"))
                ((symbol-function 'yes-or-no-p)
                 (lambda (&rest _)
                   (supertag-tag-create '(:name "new"))
                   (setq after-external-change (supertag-tag-change-test--snapshot (list file plain)))
                   t)))
        (let ((error (should-error (supertag-tag-rename "old") :type 'user-error)))
          (should (string-match-p "resolution changed" (error-message-string error)))))
      ;; The simulated external creation is preserved; this command adds no writes.
      (should (equal after-external-change (supertag-tag-change-test--snapshot (list file plain)))))))

(ert-deftest supertag-tag-change-preview-keeps-not-changed-shapes ()
  "A keyword line and a src block are listed as not changed, byte for byte."
  (supertag-tag-change-test--vault
    (with-current-buffer (find-file-noselect plain)
      (goto-char (point-min)) (search-forward "Alias body")
      ;; The `#+CAPTION:' is the last line here, so Org parses it as a plain
      ;; `keyword' and its `#alias' is not an occurrence at all; see
      ;; `supertag-tag-change-caption-affiliation-decides-acceptance' for the
      ;; shape where the line is an affiliated keyword of a paragraph.
      (replace-match (concat "#+BEGIN_SRC text\nMETA #alias\n#+END_SRC\n"
                             "PROSE #alias\n#+CAPTION: META #alias")))
    (let ((before (supertag-tag-change-test--snapshot (list file plain))))
      (supertag-tag-change-preview "old" "new")
      (with-current-buffer "*Supertag Tag Change*"
        (should (string-match-p "PROSE #alias" (buffer-string)))
        (should (string-match-p "not a Tag: src or example block" (buffer-string)))
        (should (string-match-p "not a Tag: keyword line" (buffer-string)))
        ;; The metadata line is listed as NOT CHANGED and never as a change.
        (let* ((text (buffer-string))
               (split (string-match-p "NOT CHANGED:" text)))
          (should split)
          (should-not (string-match-p "CAPTION" (substring text 0 split)))
          (should (string-match-p "CAPTION" (substring text split)))))
      (should (equal before (supertag-tag-change-test--snapshot (list file plain)))))))

(ert-deftest supertag-tag-change-caption-affiliation-does-not-decide ()
  "A `#+CAPTION:' occurrence is never a Tag, affiliated or not.
Measured before the rule fix: the standalone shape was rejected while the
same line with a paragraph after it was accepted, because
`org-element-context' then reports that paragraph.  The rule now decides by
the position's own line, so both shapes are rejected and only the
paragraph's own occurrence is a Tag.  See
local record (.scratch/tasks/reports/report-keyword-line-affiliation.md, not shipped)."
  (supertag-tag-change-test--vault
    ;; Keep the vault's second file out of the scan: its own fixture
    ;; occurrences are not what this test measures.
    (with-current-buffer (find-file-noselect plain)
      (erase-buffer)
      (insert "* Empty\n")
      (save-buffer))
    (let ((standalone (concat "* H\n:PROPERTIES:\n:ID: shape\n:END:\n"
                              "Prose line\n#+CAPTION: META #alias\n"))
          (affiliated (concat "* H\n:PROPERTIES:\n:ID: shape\n:END:\n"
                              "#+CAPTION: META #alias\nPROSE #alias\n")))
      (dolist (case (list (cons 'standalone standalone) (cons 'affiliated affiliated)))
        (with-current-buffer (find-file-noselect file)
          (erase-buffer)
          (insert (cdr case))
          (save-buffer))
        (let* ((records (supertag-tag-change--collect "old"))
               (captions (cl-some (lambda (record)
                                    (string-match-p "CAPTION" (plist-get record :line-text)))
                                  records)))
          (should-not captions)
          ;; The paragraph under the keyword line keeps its own occurrence.
          (if (eq (car case) 'standalone)
              (should-not records)
            (should (equal '("alias")
                           (mapcar (lambda (record) (plist-get record :token))
                                   records)))))))))


(ert-deftest supertag-tag-change-old-writers-absent ()
  (should-not (fboundp 'supertag-rename-tag))
  (should-not (fboundp 'supertag-ops-delete-tag-everywhere)))

(ert-deftest supertag-tag-change-boundary-records-membership-node-locally ()
  "A registered boundary Tag updates one node without whole-file projection."
  (supertag-document-test-with-vault
    (with-current-buffer (find-file-noselect file)
      (erase-buffer)
      (dotimes (index 50)
        (insert (format "* Heading %d\n:PROPERTIES:\n:ID: boundary-%d\n:END:\nBody %d\n"
                        index index index)))
      (save-buffer))
    (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
    (supertag-tag-create '(:id "registered" :name "registered"))
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (forward-line -1)
      (end-of-line)
      (insert " #registered ")
      (let ((project-calls 0)
            (parse-calls 0)
            (project (symbol-function 'supertag--project-node-from-org-text))
            (parse (symbol-function 'org-element-parse-buffer)))
        (cl-letf (((symbol-function 'supertag--project-node-from-org-text)
                   (lambda (&rest args)
                     (cl-incf project-calls)
                     (apply project args)))
                  ((symbol-function 'org-element-parse-buffer)
                   (lambda (&rest args)
                     (cl-incf parse-calls)
                     (apply parse args))))
          (supertag-completion--auto-record-on-boundary))
        (should (= 0 project-calls))
        (should (= 0 parse-calls)))
      (let ((node (supertag-node-get "boundary-49")))
        (should (member "registered" (plist-get node :tags)))
        (should
         (equal (plist-get node :tag-occurrences)
                (save-excursion
                  (org-back-to-heading t)
                  (supertag-node-tag-occurrences-at-point)))))
      (should (string-match-p "#registered "
                              (supertag-document-test-disk file))))))

(ert-deftest supertag-tag-change-boundary-ignores-unregistered-token ()
  "An unregistered boundary token does not save or change the Store."
  (supertag-document-test-with-vault
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (insert " #unregistered ")
      (let ((before-store (prin1-to-string supertag--store))
            (before-disk (supertag-document-test-disk file))
            (save-calls 0)
            (save (symbol-function 'save-buffer)))
        (cl-letf (((symbol-function 'save-buffer)
                   (lambda (&rest args)
                     (cl-incf save-calls)
                     (apply save args))))
          (supertag-completion--auto-record-on-boundary))
        (should (= 0 save-calls))
        (should (equal before-store (prin1-to-string supertag--store)))
        (should (equal before-disk (supertag-document-test-disk file)))))))

(ert-deftest supertag-tag-change-retry-after-save-failure ()
  "A save failure leaves the Tag holding both tokens; a second run finishes it.
The Tag is not deleted and recreated: it is rekeyed once and then keeps its ID
across the failed run, so the resumed run continues the same rename."
  (supertag-tag-change-test--vault
    (let ((save (symbol-function 'supertag-service-org--save-current-buffer))
          (failed nil) first-target
          (first-disk (supertag-document-test-disk file))
          (second-disk (supertag-document-test-disk plain)))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "new"))
                ((symbol-function 'yes-or-no-p)
                 (lambda (prompt)
                   (when failed
                     ;; The interrupted rename is a plain continuation, never a
                     ;; merge into a half-created new Tag.
                     (should (string-prefix-p "Rename" prompt)))
                   t))
                ((symbol-function 'supertag-service-org--save-current-buffer)
                 (lambda ()
                   (if (and (equal (buffer-file-name) plain) (not failed))
                       (progn (setq failed t) (error "Second file save fails once"))
                     (funcall save)))))
        (should-error (supertag-tag-rename "old"))
        ;; The Tag was rekeyed before the write, so both tokens name it and the
        ;; Tag itself still exists under the fresh ID.
        (setq first-target (supertag-tag-resolve-occurrence "new"))
        (should first-target)
        (should (equal first-target (supertag-tag-resolve-occurrence "old")))
        (should-not (supertag-tag-get "old"))
        (should-not (equal first-disk (supertag-document-test-disk file)))
        (should (equal second-disk (supertag-document-test-disk plain)))
        (should (buffer-modified-p (find-file-noselect plain)))
        (should (member first-target (plist-get (supertag-node-get "alias-node") :tags)))
        ;; The buffer the failed save left modified is a blocker: the resume is
        ;; refused rather than saving the user's buffer for them.
        (should-not (supertag-tag-rename "old"))
        (should (buffer-modified-p (find-file-noselect plain)))
        (with-current-buffer (find-file-noselect plain) (save-buffer))
        ;; The still-unsaved occurrence is listed before the resume.
        (supertag-tag-change-preview first-target "new")
        (with-current-buffer "*Supertag Tag Change*"
          (should (string-match-p "\\* Alias #alias" (buffer-string))))
        (should (equal first-target (supertag-tag-rename "old")))
        (should-not (supertag-tag-get "old"))
        (should-not (supertag-find-nodes-by-tag "old"))
        (dolist (id '("file-node" "alias-node" "path-node"))
          (should (equal (list first-target) (plist-get (supertag-node-get id) :tags))))
        (dolist (path (list file plain))
          (with-current-buffer (find-file-noselect path)
            (should-not (buffer-modified-p))
            (should (equal (buffer-string) (supertag-document-test-disk path)))))
        (should (cl-every (lambda (record) (equal "new" (plist-get record :token)))
                          (supertag-tag-change-preview first-target)))
        ;; No occurrence of the old token survives in the text.
        (should-not (supertag-tag--text-records-for-tag
                     "old" (supertag-tag--text-scan (list file plain))))))))

(ert-deftest supertag-tag-change-unsaved-buffer-blocks-without-being-saved ()
  "A source file with unsaved changes is refused, never saved by the rename."
  (supertag-tag-change-test--vault
    (with-current-buffer (find-file-noselect plain)
      (goto-char (point-max))
      (insert "Unrelated draft"))
    (let* ((before-disk (supertag-document-test-disk plain))
           (before-store (prin1-to-string supertag--store))
           (writer (symbol-function 'supertag-service-org--update-buffer-and-resync))
           (calls 0))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "new"))
                ((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (ert-fail "A blocked rename must not confirm")))
                ((symbol-function 'supertag-service-org--update-buffer-and-resync)
                 (lambda (id function &optional repair tags-only)
                   (cl-incf calls)
                   (funcall writer id function repair tags-only))))
        (should-not (supertag-tag-rename "old")))
      (should (= 0 calls))
      ;; The draft is still only in the buffer, and the Store is untouched.
      (should (equal before-disk (supertag-document-test-disk plain)))
      (with-current-buffer (find-file-noselect plain)
        (should (buffer-modified-p))
        (should (string-match-p "Unrelated draft" (buffer-string))))
      (should (equal before-store (prin1-to-string supertag--store)))
      (should (supertag-tag-get "old"))
      ;; The preview named the blocked file before any confirmation.
      (with-current-buffer "*Supertag Tag Change*"
        (should (string-match-p "BLOCKED" (buffer-string)))
        (should (string-match-p "unsaved changes" (buffer-string)))))))

(ert-deftest supertag-tag-change-unowned-entities-can-change ()
  "A Tag with no Org occurrence keeps its identity when only its name changes."
  (supertag-tag-change-test--vault
    (let ((id (plist-get (supertag-tag-create '(:name "lonely")) :id))
          (disk (mapcar #'supertag-document-test-disk (list file plain)))
          new-id)
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "new-lonely"))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (setq new-id (supertag-tag-rename id))
        ;; The Tag is renamed in place: same ID, new canonical name.
        (should (equal id new-id))
        (should (equal "new-lonely" (plist-get (supertag-tag-get id) :name)))
        (should-not (supertag-tag-resolve-occurrence "lonely"))
        (supertag-delete-tag-everywhere new-id))
      (should-not (supertag-tag-get new-id))
      (should (equal disk (mapcar #'supertag-document-test-disk (list file plain)))))))

(ert-deftest supertag-tag-change-canonical-change-rejects-before-writing ()
  (supertag-tag-change-test--vault
    (supertag-tag-create '(:id "other" :name "Canonical" :aliases ("destination")))
    (let (after-external-change)
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "destination"))
                ((symbol-function 'yes-or-no-p)
                 (lambda (prompt)
                   (should (string-match-p "Canonical" prompt))
                   (supertag-tag-update "other" (lambda (tag) (plist-put tag :name "Changed")))
                   (should (equal "Changed" (plist-get (supertag-tag-get "other") :name)))
                   (should (member "destination" (plist-get (supertag-tag-get "other") :aliases)))
                   (should (equal "other" (supertag-tag-resolve-occurrence "destination")))
                   (setq after-external-change (supertag-tag-change-test--snapshot (list file plain)))
                   t)))
        (let ((error (should-error (supertag-tag-rename "old") :type 'user-error)))
          (should (equal "Tag resolution changed; preview again" (error-message-string error)))))
      (should (equal after-external-change
                     (supertag-tag-change-test--snapshot (list file plain)))))))


;;; D1: real member writes and the existing compensation contract.
(ert-deftest supertag-tag-change-member-bulk-preserves-entity-and-write-counts ()
  (supertag-document-test-with-vault
    (with-current-buffer (find-file-noselect plain)
      (erase-buffer)
      (insert "* Second\n:PROPERTIES:\n:ID: second-node\n:END:\nSecond body\n")
      (save-buffer))
    (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
    (supertag-tag-create '(:id "stable" :name "canonical" :aliases ("alias")))
    (let ((save (symbol-function 'supertag-service-org--save-current-buffer))
          (record (symbol-function 'supertag-service-org-save-and-record-tags-at-point))
          saves records ids)
      (cl-letf (((symbol-function 'supertag-service-org--save-current-buffer)
                 (lambda () (push (buffer-file-name) saves) (funcall save)))
                ((symbol-function 'supertag-service-org-save-and-record-tags-at-point)
                 (lambda (id) (push id records) (funcall record id))))
        (setq ids (supertag-capture-add-tags-to-nodes
                   '("document-node" "second-node") '("alias" "media/book"))))
      (should (equal (car ids) "stable"))
      (should (= (length ids) 2))
      ;; `media/book' is a path: it creates `media' and links the `book' leaf.
      (let ((leaf (supertag-tag-resolve-occurrence "book")))
        (should leaf)
        (should (equal (list (supertag-tag-resolve-occurrence "media"))
                       (supertag-tag-parents leaf))))
      (dolist (pair (list (cons "document-node" file) (cons "second-node" plain)))
        (should (= 1 (cl-count (car pair) records :test #'equal)))
        (should (= 1 (cl-count (cdr pair) saves :test #'equal)))
        (should (equal (sort (copy-sequence ids) #'string<)
                       (sort (copy-sequence (plist-get (supertag-node-get (car pair)) :tags)) #'string<)))
        (with-current-buffer (find-file-noselect (cdr pair))
          (should-not (buffer-modified-p))
          (should (equal (buffer-string) (supertag-document-test-disk (cdr pair))))
          (should (string-match-p "#canonical" (buffer-string)))
          (should (string-match-p "#book" (buffer-string)))
          (should-not (string-match-p "#media/book" (buffer-string))))))))

(defun supertag-tag-change-test--late-member-failure (fail-compensation)
  "Observe durable first write, then fail verification and optionally recovery."
  (supertag-document-test-with-vault
    (let* ((before (supertag-document-test-disk file))
           (tags-before (copy-tree (plist-get (supertag-node-get "document-node") :tags)))
           (real (symbol-function 'supertag-service-org-save-and-record-tags-at-point))
           (calls 0) saved error-data)
      (cl-letf (((symbol-function 'supertag-service-org-save-and-record-tags-at-point)
                 (lambda (id)
                   (cl-incf calls)
                   (when (and fail-compensation (= calls 2))
                     (error "D1 compensation save failed"))
                   (prog1 (funcall real id)
                     (when (= calls 1)
                       (setq saved (supertag-document-test-disk file))))))
                ((symbol-function 'supertag-capture--tag-membership-present-p)
                 (lambda (&rest _) nil)))
        (setq error-data
              (should-error (supertag-capture-add-tag-to-nodes
                             '("document-node") "d1-rollback") :type 'user-error)))
      (should (= calls 2))
      (should (string-match-p "#d1-rollback" saved))
      (should-not (equal before saved))
      (should (string-match-p "membership projection did not contain every Tag"
                             (error-message-string error-data)))
      (should-not (supertag-tag-resolve-occurrence "d1-rollback"))
      (should (equal tags-before (plist-get (supertag-node-get "document-node") :tags)))
      (with-current-buffer (find-file-noselect file)
        (should (equal before (buffer-string)))
        (if fail-compensation
            (progn
              (should (string-match-p "restoring the Org file also failed: D1 compensation save failed"
                                     (error-message-string error-data)))
              (should (equal saved (supertag-document-test-disk file)))
              (should (buffer-modified-p)))
          (should (equal before (supertag-document-test-disk file)))
          (should-not (buffer-modified-p)))))))

(ert-deftest supertag-tag-change-member-late-failure-restores-saved-org ()
  (supertag-tag-change-test--late-member-failure nil))

(ert-deftest supertag-tag-change-member-compensation-failure-reports-both-errors ()
  (supertag-tag-change-test--late-member-failure t))

(provide 'tag-rename-delete-test)

;;; D4 retained cleanup command: real selection, confirmation and facts.
(ert-deftest supertag-tag-change-orphan-command-confirms-only-selected-entity ()
  (supertag-tag-change-test--vault
    (let ((supertag--view-configs (make-hash-table :test 'eq)))
      (require 'supertag-view-framework)
      (dolist (id '("unused" "kept" "protected"))
        (supertag-tag-create (list :id id :name id)))
      (supertag-view-config-register '(:id d4-protected :valid-for ("protected")))
      (should-not (member "protected" (supertag-tag-orphaned-ids)))
      (let ((before (supertag-tag-change-test--snapshot (list file plain))))
        (dolist (confirm '(nil t))
          (let ((answers '("unused" "")))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt table &rest _)
                         (should-not (member "protected" (all-completions "" table)))
                         (pop answers)))
                      ((symbol-function 'yes-or-no-p) (lambda (&rest _) confirm)))
              (call-interactively #'supertag-cleanup-orphaned-tags)))
          (if confirm
              (progn
                (should-not (supertag-tag-get "unused"))
                (should (supertag-tag-get "kept"))
                (should (supertag-tag-get "protected"))
                (should (supertag-tag-get "old"))
                (should (equal (car before)
                               (car (supertag-tag-change-test--snapshot (list file plain))))))
            (should (equal before (supertag-tag-change-test--snapshot (list file plain))))))))))
