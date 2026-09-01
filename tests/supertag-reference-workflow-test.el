;;; supertag-reference-workflow-test.el --- Contextual reference tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'ht)
(require 'cl-lib)
(require 'org)
(require 'supertag-core-store)
(require 'supertag-core-index)
(require 'supertag-ops-node)
(require 'supertag-ops-relation)
(require 'supertag-services-reference)
(require 'supertag-ui-reference)
(require 'supertag-view-reference)

(defmacro supertag-v6-test--isolated (&rest body)
  (declare (indent 0))
  `(let ((supertag--store (ht-create))
         (supertag-reference-context-length 100)
         (supertag-reference-context-before 24))
     (supertag--ensure-store)
     (supertag-index-clear-all)
     ,@body))

(defun supertag-v6-test--put-node
    (id title &optional content file olp position properties)
  (supertag-store-put-entity
   :nodes id
   (list :id id :type :node :title title :raw-value title
         :content (or content "")
         :file (or file (format "/notes/%s.org" id))
         :olp (or olp (list title))
         :position (or position 1)
         :level 1
         :properties properties)))

(ert-deftest supertag-v6-legacy-commit-name-aliases-materializer ()
  "The former private writer remains a compatibility alias only."
  (should (eq (indirect-function 'supertag-reference--commit-region)
              (indirect-function 'supertag-reference-materialize))))

(ert-deftest supertag-v6-context-snippet-renders-link-description ()
  (supertag-v6-test--isolated
    (let* ((source
            '(:content
              "A long opening discusses other matters before [[id:target][Ontology as Code]] becomes the central issue and continues afterward."))
           (target '(:title "Ontology as Code" :raw-value "Ontology as Code"))
           (snippet
            (supertag-reference-service-context-snippet source target)))
      (should (string-match-p "Ontology as Code" snippet))
      (should-not (string-match-p "\\[\\[id:" snippet)))))

(ert-deftest supertag-v6-context-snippet-finds-a-custom-link-description ()
  (supertag-v6-test--isolated
    (let* ((source
            '(:content
              "The physical reference uses [[id:target][OAC]] as its short label."))
           (target '(:id "target" :title "Ontology as Code"))
           (snippet
            (supertag-reference-service-context-snippet source target)))
      (should (string-match-p "OAC" snippet))
      (should-not (string-match-p "\\[\\[id:" snippet)))))

(ert-deftest supertag-v6-context-snippet-keeps-a-late-match-visible ()
  (supertag-v6-test--isolated
    (let* ((supertag-reference-context-length 60)
           (source (list :content
                         (concat (make-string 150 ?x)
                                 " Target Concept "
                                 (make-string 80 ?y))))
           (target '(:title "Target Concept"))
           (snippet
            (supertag-reference-service-context-snippet source target)))
      (should (<= (length snippet) 62))
      (should (string-match-p "Target Concept" snippet)))))

(ert-deftest supertag-v6-backlinks-aggregate-kinds-by-source ()
  (supertag-v6-test--isolated
    (supertag-v6-test--put-node
     "source" "Daily Note"
     "Today I compared [[id:target][Ontology]] with a semantic mention of Ontology."
     "/notes/2026-08-27.org" '("Daily" "Daily Note") 20)
    (supertag-v6-test--put-node "target" "Ontology")
    (supertag-relation-create
     '(:type :reference :kind :document-link :origin :org
       :from "source" :to "target"))
    (supertag-relation-create
     '(:type :reference :kind :semantic-edge :origin :semantic
       :from "source" :to "target"))
    (let* ((items (supertag-reference-service-backlinks "target"))
           (item (car items)))
      (should (= 1 (length items)))
      (should (member :document-link (plist-get item :kinds)))
      (should (member :semantic-edge (plist-get item :kinds)))
      (should (= 2 (length (plist-get item :relation-ids))))
      (should (string-match-p "Ontology" (plist-get item :snippet))))))

(ert-deftest supertag-v6-outgoing-references-aggregate-kinds-by-target ()
  (supertag-v6-test--isolated
    (supertag-v6-test--put-node
     "source" "Research" "Compare [[id:target][Ontology]] with Ontology.")
    (supertag-v6-test--put-node "target" "Ontology")
    (supertag-relation-create
     '(:type :reference :kind :document-link :origin :org
       :from "source" :to "target"))
    (supertag-relation-create
     '(:type :reference :kind :semantic-edge :origin :semantic
       :from "source" :to "target"))
    (let* ((items (supertag-reference-service-outgoing "source"))
           (item (car items)))
      (should (= 1 (length items)))
      (should (equal "target" (plist-get item :node-id)))
      (should (member :document-link (plist-get item :kinds)))
      (should (member :semantic-edge (plist-get item :kinds)))
      (should (string-match-p "Ontology" (plist-get item :snippet))))))

(ert-deftest supertag-v6-reference-candidates-include-aliases-and-exclude-source ()
  (supertag-v6-test--isolated
    (supertag-v6-test--put-node "source" "Source")
    (supertag-v6-test--put-node
     "target" "Ontology as Code" nil nil nil nil
     '(:SUPERTAG_ALIASES "OAC, 本体代码"))
    (let* ((candidates (supertag-reference-service-candidates "source"))
           (target (car candidates)))
      (should (= 1 (length candidates)))
      (should (equal "target" (plist-get target :node-id)))
      (should (member "OAC" (plist-get target :terms)))
      (should (member "本体代码" (plist-get target :terms))))))

(ert-deftest supertag-v6-reference-resolution-rejects-ambiguous-title ()
  (supertag-v6-test--isolated
    (supertag-v6-test--put-node "one" "Shared")
    (supertag-v6-test--put-node "two" "Shared")
    (should-error (supertag-reference-service-find-by-term "Shared"))))

(ert-deftest supertag-v6-reference-prefix-detects-shorthand-only ()
  (with-temp-buffer
    (org-mode)
    (insert "* Source\nDiscuss [[Ont")
    (let ((bounds (supertag-reference--get-prefix-bounds)))
      (should bounds)
      (should (equal "Ont"
                     (buffer-substring-no-properties
                      (car bounds) (cdr bounds))))))
  (with-temp-buffer
    (org-mode)
    (insert "* Source\n[[id:abc")
    (should-not (supertag-reference--get-prefix-bounds)))
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src text\n[[Not a reference\n#+end_src\n")
    (goto-char (point-min))
    (forward-line 1)
    (end-of-line)
    (should-not (supertag-reference--get-prefix-bounds))))

(ert-deftest supertag-v6-completion-exposes-explicit-create-candidate ()
  (supertag-v6-test--isolated
    (supertag-v6-test--put-node "project" "Project")
    (let* ((new-table (supertag-reference--completion-table "New Idea" nil))
           (new-candidates (all-completions "" new-table))
           (exact-table (supertag-reference--completion-table "Project" nil))
           (exact-candidates (all-completions "" exact-table)))
      (should (cl-some
               (lambda (candidate)
                 (equal "New Idea"
                        (get-text-property
                         0 'supertag-reference-create-title candidate)))
               new-candidates))
      (should-not (cl-some
                   (lambda (candidate)
                     (get-text-property
                      0 'supertag-reference-create-title candidate))
                   exact-candidates)))))

(ert-deftest supertag-v6-completion-rewrites-shorthand-to-canonical-org-link ()
  (with-temp-buffer
    (org-mode)
    (insert "* Source\n[[Project]]")
    (goto-char (- (point-max) 2))
    (let ((open-marker (copy-marker (save-excursion
                                      (search-backward "[[")
                                      (point))))
          (selected
           (propertize "Project  (/notes/project.org)"
                       'supertag-reference-node-id "target"
                       'supertag-reference-title "Project")))
      (cl-letf (((symbol-function 'supertag-reference--source-id-at-marker)
                 (lambda (_marker) "source"))
                ((symbol-function 'supertag-ui--replace-region-with-reference)
                 (lambda (beg end _from to title)
                   (goto-char beg)
                   (delete-region beg end)
                   (insert (supertag-node-format-link to title)))))
        (supertag-reference--post-completion selected 'finished open-marker))
      (should (equal "* Source\n[[id:target][Project]]"
                     (buffer-string))))))

(ert-deftest supertag-v6-full-width-opener-detects-shorthand ()
  "A Chinese input method types 【【; it must trigger like [[."
  (with-temp-buffer
    (org-mode)
    (insert "* Source\nDiscuss 【【Ont")
    (let ((bounds (supertag-reference--get-prefix-bounds)))
      (should bounds)
      (should (equal "Ont" (buffer-substring-no-properties
                            (car bounds) (cdr bounds))))
      (should (equal (- (car bounds) 2)
                     (supertag-reference--opener-position (car bounds))))))
  (with-temp-buffer
    (org-mode)
    (insert "* Source\nDiscuss 【【Ont】】 later")
    (search-backward "】】")
    ;; The closer after point is not part of the prefix.
    (should (equal "Ont" (let ((bounds (supertag-reference--get-prefix-bounds)))
                           (buffer-substring-no-properties
                            (car bounds) (cdr bounds)))))
    ;; Once point is past the closer the shorthand is finished.
    (search-forward "】】")
    (should-not (supertag-reference--get-prefix-bounds))))

(ert-deftest supertag-v6-full-width-shorthand-rewrites-to-canonical-org-link ()
  "【【Title】】 (closer auto-paired by the input method) becomes [[id:..][Title]]."
  (with-temp-buffer
    (org-mode)
    (insert "* Source\n【【Project】】")
    (goto-char (- (point-max) 2))
    (let ((open-marker (copy-marker (save-excursion
                                      (search-backward "【【")
                                      (point))))
          (selected
           (propertize "Project  (/notes/project.org)"
                       'supertag-reference-node-id "target"
                       'supertag-reference-title "Project")))
      (cl-letf (((symbol-function 'supertag-reference--source-id-at-marker)
                 (lambda (_marker) "source"))
                ((symbol-function 'supertag-ui--replace-region-with-reference)
                 (lambda (beg end _from to title)
                   (goto-char beg)
                   (delete-region beg end)
                   (insert (supertag-node-format-link to title)))))
        (supertag-reference--post-completion selected 'finished open-marker))
      (should (equal "* Source\n[[id:target][Project]]"
                     (buffer-string))))))

(ert-deftest supertag-v6-default-concept-target-is-non-interactive ()
  (let* ((supertag-active-sync-directory nil)
         (supertag-sync-directories '("/tmp/supertag-vault"))
         (supertag-concept-default-file nil)
         (supertag-concept-default-level 1)
         (target (supertag-concept-default-create-target "Ontology")))
    (should (equal "/tmp/supertag-vault/concepts.org"
                   (plist-get target :file)))
    (should (= 1 (plist-get target :level)))
    (should-not (plist-get target :position))))

(ert-deftest supertag-v6-active-vault-wins-default-concept-target ()
  (let* ((supertag-active-sync-directory "/tmp/active-vault")
         (supertag-sync-directories '("/tmp/first-vault"))
         (supertag-concept-default-file nil)
         (target (supertag-concept-default-create-target "Ontology")))
    (should (equal "/tmp/active-vault/concepts.org"
                   (plist-get target :file)))))

(ert-deftest supertag-v6-contextual-view-carries-source-navigation-properties ()
  (supertag-v6-test--isolated
    (supertag-v6-test--put-node
     "source" "Research Note" "Ontology is discussed here."
     "/notes/research.org" '("Research" "Research Note") 42)
    (supertag-v6-test--put-node "target" "Ontology")
    (supertag-relation-create
     '(:type :reference :kind :semantic-edge :origin :semantic
       :from "source" :to "target"))
    (with-temp-buffer
      (supertag-view-reference-insert-backlinks-section "target")
      (goto-char (point-min))
      (search-forward "Research Note")
      (should (equal "source"
                     (get-text-property (1- (point)) 'supertag-node-id)))
      (should (search-forward "> Ontology is discussed here." nil t)))))

(provide 'supertag-reference-workflow-test)
;;; supertag-reference-workflow-test.el ends here
