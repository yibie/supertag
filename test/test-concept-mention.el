;;; test-concept-mention.el --- self-checks for concept mentions -*- lexical-binding: t; -*-
;; Run: emacs --batch -Q --eval '(package-initialize)' -L . -l test/test-concept-mention.el

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'org-id)

(when load-file-name
  ;; This file lives in test/; add the project root (its parent) to
  ;; load-path so the `require' calls below can find sibling modules
  ;; even when invoked without an explicit `-L .' flag.
  (add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)
(require 'supertag-node)
(require 'supertag-link)
(require 'supertag-services-sync)
(require 'supertag-concept)
(require 'supertag-link)
(require 'supertag-mention)

(defmacro concept-test--with-env (&rest body)
  "Run BODY with an isolated store and temp directory."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "supertag-concept-test" t))
          (supertag-data-directory tmp)
          (supertag-db-file (expand-file-name "supertag-db.el" tmp))
          (supertag-db-backup-directory (expand-file-name "backups" tmp))
          (supertag--store nil)
          (supertag--store-origin nil)
          (supertag-concept-default-file
           (expand-file-name "concepts.org" tmp))
          (supertag-active-sync-directory nil)
          (supertag-creation-templates nil)
          (supertag-sync-directories nil)
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
       (ignore-errors
         (delete-directory tmp t)))))

(defun concept-test--create-node (id title &optional aliases)
  "Save a real template-file heading with ID, TITLE and optional ALIASES."
  (with-current-buffer (find-file-noselect supertag-concept-default-file)
    (goto-char (point-max))
    (let ((start (point)))
      (insert (format "* %s\n:PROPERTIES:\n:ID: %s\n" title id))
      (when aliases (insert ":SUPERTAG_ALIASES: " aliases "\n"))
      (insert ":END:\n")
      (save-buffer)
      (goto-char start)
      (supertag-node-sync-at-point))))

(defun concept-test--text-property-at-search (text prop)
  "Search TEXT and return PROP at the match beginning."
  (goto-char (point-min))
  (search-forward text)
  (get-text-property (match-beginning 0) prop))

(ert-deftest concept-entries-use-title-and-alias-only-for-concepts ()
  "Concept entries include title/aliases from template-file headings only."
  (concept-test--with-env
    (concept-test--create-node "concept-id" "大语言模型" "LLM, 大模型")
    (supertag-node-create
     (list :id "ordinary-id" :title "普通节点" :level 1 :position 1))
    (let ((entries (supertag-concept-entries)))
      (should (equal (cdr (assoc "大语言模型" entries)) "concept-id"))
      (should (equal (cdr (assoc "LLM" entries)) "concept-id"))
      (should (equal (cdr (assoc "大模型" entries)) "concept-id"))
      (should-not (assoc "普通节点" entries)))))

(ert-deftest concept-mention-mode-highlights-plain-mentions-not-org-links ()
  "Mention mode uses its own face and skips explicit Org links."
  (concept-test--with-env
    (concept-test--create-node "concept-id" "注意力机制" "Attention")
    (with-temp-buffer
      (org-mode)
      (insert "注意力机制 and Attention\n[[id:concept-id][注意力机制]]\n")
      (supertag-concept-link-mode 1)
      (font-lock-ensure)
      (goto-char (point-min))
      (search-forward "注意力机制")
      (should (equal (get-text-property (match-beginning 0) 'supertag-concept-node-id)
                     "concept-id"))
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'supertag-concept-mention-face))
      (should (eq (get-text-property (match-beginning 0) 'keymap)
                  supertag-concept-mention-map))
      (let (opened)
        (cl-letf (((symbol-function 'supertag-goto-node)
                   (lambda (node-id) (setq opened node-id))))
          (goto-char (match-beginning 0))
          (supertag-concept-open-at-point))
        (should (equal opened "concept-id")))
      (should (equal (concept-test--text-property-at-search "Attention"
                                                            'supertag-concept-node-id)
                     "concept-id"))
      (goto-char (point-min))
      (search-forward "[[id:concept-id][")
      (let ((link-desc-pos (point)))
        (should-not (get-text-property link-desc-pos 'supertag-concept-node-id))))))

(ert-deftest concept-mention-mode-prefers-longest-match ()
  "Overlapping concept terms prefer the longest title."
  (concept-test--with-env
    (concept-test--create-node "base-id" "大语言模型")
    (concept-test--create-node "long-id" "大语言模型微调")
    (with-temp-buffer
      (org-mode)
      (insert "大语言模型微调")
      (supertag-concept-link-mode 1)
      (font-lock-ensure)
      (goto-char (point-min))
      (should (equal (get-text-property (point) 'supertag-concept-node-id)
                     "long-id")))))

(ert-deftest concept-mention-mode-skips-non-prose-contexts ()
  "Mentions do not override Org code, verbatim, comments or COMMENT headings."
  (concept-test--with-env
    (concept-test--create-node "concept-id" "注意力机制")
    (with-temp-buffer
      (org-mode)
      (insert "~注意力机制~ =注意力机制=\n# 注意力机制\n* COMMENT 注意力机制\n* Normal\nPlain 注意力机制\n")
      (supertag-concept-link-mode 1)
      (font-lock-ensure)
      (goto-char (point-min))
      (dotimes (_ 4)
        (search-forward "注意力机制")
        (should-not (get-text-property (match-beginning 0)
                                       'supertag-concept-node-id)))
      (search-forward "注意力机制")
      (should (equal (get-text-property (match-beginning 0)
                                        'supertag-concept-node-id)
                     "concept-id")))))

(ert-deftest concept-entries-skip-ambiguous-terms ()
  "A shared title or alias must not silently choose a concept node."
  (concept-test--with-env
    (concept-test--create-node "first-id" "First" "Shared")
    (concept-test--create-node "second-id" "Second" "Shared")
    (should-not (assoc "Shared" (supertag-concept-entries)))
    (should-not (fboundp 'supertag-concept--find-concept-id-by-term))))

(ert-deftest concept-old-marker-does-not-grant-position-membership ()
  "Historical marker data is preserved but no longer determines membership."
  (concept-test--with-env
    (let ((file (expand-file-name "existing.org" supertag-data-directory)))
      (with-temp-file file
        (insert "* Existing\n:PROPERTIES:\n:ID:       existing-id\n:SUPERTAG_CONCEPT: t\n:END:\n"))
      (supertag-node-create
       (list :id "existing-id" :title "Existing" :file file
             :position 1 :level 1 :properties nil))
      (should-not (fboundp 'supertag-concept--mark-node))
      (with-temp-buffer
        (insert-file-contents file)
        (should (re-search-forward "^:SUPERTAG_CONCEPT: t$" nil t)))
      (should-not (supertag-concept-node-p (supertag-node-get "existing-id"))))))

(ert-deftest concept-create-node-works-with-empty-location-cache ()
  "Concept creation persists and projects identity without Org's cache."
  (concept-test--with-env
    (let ((file (expand-file-name "concepts.org" supertag-data-directory)))
      (with-temp-file file)
      (cl-letf (((symbol-function 'supertag-node-identity-new)
                 (lambda () "concept-id"))
                ((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (ert-fail "Concept creation consulted org-id-find"))))
        (should (equal "concept-id"
                       (supertag-reference--create-target
                        "Concept" (car (supertag-template-list))))))
      (should (supertag-concept-node-p (supertag-node-get "concept-id")))
      (should (supertag-node-location-find "concept-id")))))

(ert-deftest concept-file-node-is-not-reused-as-heading-concept ()
  "A same-title file node is not silently marked as a heading concept."
  (concept-test--with-env
    (supertag-node-create
     '(:id "file-id" :title "Topic" :file "/tmp/topic.org"
       :position 1 :level 0 :properties nil))
    (should-not (supertag-concept-node-p (supertag-node-get "file-id")))))

(ert-deftest promote-concept-materializes-one-document-link ()
  "Promoting selected text writes one link and derives one Document Link."
  (concept-test--with-env
    (let ((test-file (expand-file-name "notes.org" supertag-data-directory)))
      (with-temp-file test-file
        (org-mode)
        (insert "* Source\n:PROPERTIES:\n:ID:       source-id\n:END:\n\n这里讨论注意力机制。\n\n* 注意力机制\n:PROPERTIES:\n:ID:       concept-id\n:SUPERTAG_CONCEPT: t\n:END:\n\n"))
      (with-current-buffer (find-file-noselect test-file)
        (org-mode)
        (org-id-update-id-locations nil t)
        (goto-char (point-min))
        (org-back-to-heading t)
        (supertag-node-sync-at-point)
        (org-next-visible-heading 1)
        (supertag-node-sync-at-point)
        (goto-char (point-min))
        (search-forward "注意力机制")
        (let ((beg (match-beginning 0))
              (end (match-end 0)))
          (goto-char beg)
          (set-mark end)
          (activate-mark)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt choices &rest _)
                       (car (cl-find-if (lambda (choice) (cdr choice)) choices))))
                    ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
            (supertag-promote "c")))
        (goto-char (point-min))
        (org-back-to-heading t)
        (let ((source-end (save-excursion (org-end-of-subtree t t))))
          (should (re-search-forward
                   (regexp-quote
                    "这里讨论[[id:concept-id][注意力机制]]。")
                   source-end t)))
        (let ((relations (supertag-relation-find-between
                          "source-id" "concept-id" :reference)))
          (should (= 1 (length relations)))
          (should (supertag-relation-document-link-p (car relations)))
          (should (eq :org (plist-get (car relations) :origin))))))))

(ert-deftest promote-concept-inside-itself-rejects-before-mutation ()
  "Explicit reuse of the containing heading cannot create a self-link or marker."
  (concept-test--with-env
    (let ((file (expand-file-name "self.org" supertag-data-directory))
          materialized)
      (with-temp-file file
        (insert "* 注意力机制\n:PROPERTIES:\n:ID: concept-id\n:END:\n\n再次提到注意力机制。\n"))
      (with-current-buffer (find-file-noselect file)
        (org-mode)
        (goto-char (point-min))
        (should (supertag-node-sync-at-point))
        (search-forward "注意力机制" nil nil 2)
        (let ((beg (match-beginning 0))
              (end (match-end 0)))
          (cl-letf (((symbol-function 'supertag-reference-materialize)
                     (lambda (&rest _)
                       (setq materialized t))))
            (goto-char beg) (set-mark end) (activate-mark)
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt choices &rest _)
                         (car (cl-find-if (lambda (choice) (cdr choice)) choices)))))
              (should-error (supertag-promote "c") :type 'user-error))))
        (should-not materialized)
        (goto-char (point-min))
        (should-not (org-entry-get nil "SUPERTAG_CONCEPT"))
        (should-not (search-forward "[[id:concept-id]" nil t))))))

(ert-deftest promote-empty-concept-does-not-create-source-id ()
  "Reject an empty concept before mutating the source heading."
  (concept-test--with-env
    (let ((file (expand-file-name "empty.org" supertag-data-directory)))
      (with-temp-file file
        (insert "* Source\n\n   \n"))
      (with-current-buffer (find-file-noselect file)
        (org-mode)
        (goto-char (point-min))
        (search-forward "   ")
        (let ((before (buffer-string))
              (beg (match-beginning 0))
              (end (match-end 0)))
          (goto-char beg) (set-mark end) (activate-mark)
          (should-error (supertag-promote "c") :type 'user-error)
          (should (equal (buffer-string) before))
          (goto-char (point-min))
          (should-not (org-entry-get nil "ID")))))))


;;; Unlinked mentions: one card per source, capped per source, links excluded.

(defun concept-test--mention-node (tmp name id title body)
  "Write and project one identified source node to NAME under TMP."
  (let ((file (expand-file-name name tmp)))
    (with-temp-file file
      (insert (format "* %s\n:PROPERTIES:\n:ID: %s\n:END:\n%s\n" title id body)))
    (with-current-buffer (find-file-noselect file)
      (org-mode) (goto-char (point-min)) (supertag-node-sync-at-point))
    file))

(defun concept-test--mention-target (tmp)
  "Write the mention target node for the current test under TMP."
  (concept-test--mention-node tmp "target.org" "pi" "Pi" "Target body"))

(defun concept-test--mention-text (target-id &optional width)
  "Render the unlinked mention section for TARGET-ID as text."
  (let ((supertag-view-helper-width-override (or width 120)))
    (with-temp-buffer
      (supertag-view-mention-insert-section target-id)
      (buffer-string))))

(defun concept-test--count (needle text)
  "Return how often NEEDLE appears in TEXT."
  (let ((start 0) (count 0))
    (while (string-match (regexp-quote needle) text start)
      (setq count (1+ count) start (match-end 0)))
    count))

(defun concept-test--mention-sources (target-id)
  "Return distinct mention source ids for TARGET-ID."
  (delete-dups
   (mapcar (lambda (candidate) (plist-get candidate :source-id))
           (supertag-mention-service-find target-id))))

(ert-deftest mention-section-groups-one-card-per-source ()
  "Several occurrences of one source render one card with a `+N more' note."
  (concept-test--with-env
    (concept-test--mention-target tmp)
    (concept-test--mention-node
     tmp "a-many.org" "many-src" "Many Src"
     "第一处 Pi 出现。然后是第二处 Pi，还有第三处 Pi 在这里。")
    (concept-test--mention-node tmp "b-one.org" "one-src" "One Src" "只有一处 Pi 提及。")
    (supertag-mention-service-clear-cache)
    (let ((text (concept-test--mention-text "pi")))
      ;; The chip counts sources, not occurrences.
      (should (string-match-p " UNLINKED MENTIONS / 02 " text))
      (should (= 2 (concept-test--count "[Link]" text)))
      (should (= 1 (concept-test--count "Many Src" text)))
      (should (= 1 (concept-test--count "+2 more" text)))
      (should (= 0 (concept-test--count "+1 more" text)))
      (should (eq 'supertag-view-mute
                  (get-text-property (string-match "+2 more" text) 'face text)))
      ;; First-appearance order, both sources present.
      (should (< (string-match "Many Src" text) (string-match "One Src" text))))))

(ert-deftest mention-grouped-card-links-the-first-occurrence-only ()
  "[Link] on a grouped card links one occurrence; the rest stay plain text."
  (concept-test--with-env
    (concept-test--mention-target tmp)
    (let ((file (concept-test--mention-node
                 tmp "a-many.org" "many-src" "Many Src"
                 "第一处 Pi 出现。然后是第二处 Pi，还有第三处 Pi 在这里。")))
      (supertag-mention-service-clear-cache)
      (let ((supertag-view-helper-width-override 120))
        (with-temp-buffer
          (supertag-view-mention-insert-section "pi")
          (goto-char (point-min))
          (search-forward "[Link]")
          (button-activate (button-at (1- (point))))))
      (let ((disk (with-temp-buffer
                    (insert-file-contents file)
                    (buffer-string))))
        (should (string-match-p "第一处 \\[\\[id:pi\\]\\[Pi\\]\\] 出现" disk))
        (should (string-match-p "第二处 Pi" disk))
        (should (string-match-p "第三处 Pi" disk))))))

(ert-deftest mention-cap-counts-distinct-sources ()
  "The cap admits whole sources instead of hiding later ones."
  (concept-test--with-env
    (concept-test--mention-target tmp)
    (concept-test--mention-node
     tmp "a-many.org" "many-src" "Many Src"
     "第一处 Pi 出现。然后是第二处 Pi，还有第三处 Pi 在这里。")
    (concept-test--mention-node tmp "b-one.org" "one-src" "One Src" "只有一处 Pi 提及。")
    (supertag-mention-service-clear-cache)
    (let ((supertag-mention-max-results 1))
      (should (equal '("many-src") (concept-test--mention-sources "pi")))
      ;; All occurrences of the admitted source are kept.
      (should (= 3 (length (supertag-mention-service-find "pi")))))
    (let ((supertag-mention-max-results 2))
      (should (equal '("many-src" "one-src") (concept-test--mention-sources "pi")))
      (should (= 4 (length (supertag-mention-service-find "pi")))))))

(ert-deftest mention-excludes-sources-that-already-link-the-target ()
  "A body or heading Org link means the source is not an unlinked mention."
  (concept-test--with-env
    (concept-test--mention-target tmp)
    (concept-test--mention-node
     tmp "b-body.org" "body-src" "Body Src" "正文 [[id:pi][Pi]] 与后面的 Pi 提及。")
    (concept-test--mention-node
     tmp "c-heading.org" "heading-src" "标题 [[id:pi][Pi]] 链接" "正文提到 Pi。")
    (concept-test--mention-node tmp "d-plain.org" "plain-src" "Plain Src" "只有一处 Pi 提及。")
    (supertag-mention-service-clear-cache)
    (should (equal '("plain-src") (concept-test--mention-sources "pi")))
    (let ((text (concept-test--mention-text "pi")))
      (should (string-match-p " UNLINKED MENTIONS / 01 " text))
      (should-not (string-match-p "Body Src" text))
      (should-not (string-match-p "标题" text)))))

(provide 'test-concept-mention)
;;; test-concept-mention.el ends here