;;; promote-workflow-test.el --- Template Promote workflows -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'supertag-concept)
(require 'supertag-link)
(require 'supertag-view-node)
(require 'supertag-automation)

(defmacro supertag-promote-test--isolated (&rest body)
  (declare (indent 0))
  `(let* ((tmp (file-truename (make-temp-file "supertag-promote-" t)))
          (supertag-data-directory (expand-file-name "data/" tmp))
          (supertag-db-file (expand-file-name "db.el" tmp))
          (supertag-db-backup-directory (expand-file-name "backups/" tmp))
          (supertag-sync-state-file (expand-file-name "state.el" tmp))
          (supertag-sync-directories (list tmp))
          (supertag-sync-directories-mode 'unified)
          (supertag-active-sync-directory nil)
          (supertag--store nil) (supertag--store-origin nil)
          (supertag--subscribers (make-hash-table :test 'equal))
          (supertag--index-source-revisions (make-hash-table :test 'eq))
          (supertag-automation-sync--enabled nil)
          (transient-mark-mode t)
          (org-id-locations nil) (org-id-files nil)
          (org-id-locations-file (expand-file-name "ids" tmp))
          (supertag-concept-default-file (expand-file-name "concepts.org" tmp))
          (supertag-creation-templates
           (list (list :key "c" :name "Concept" :target-file supertag-concept-default-file
                       :tags '("concept") :properties '(("STAGE" . "seed"))
                       :body "Template body\n")))
          (buffers-before (buffer-list)))
     (unwind-protect
         (save-window-excursion
           (supertag--ensure-store)
           (supertag-tag-create '(:id "concept" :name "concept"))
           ,@body)
       (dolist (buffer (cl-set-difference (buffer-list) buffers-before))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory tmp t))))

(defun supertag-promote-test--file (tmp name text)
  (let ((file (expand-file-name name tmp)))
    (with-temp-file file (insert text))
    (with-current-buffer (find-file-noselect file)
      (org-mode)
      (org-map-entries
       (lambda () (when (org-entry-get nil "ID") (supertag-node-sync-at-point))) nil 'file))
    file))

(defun supertag-promote-test--disk (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest supertag-promote-monitor-excludes-idless-headings-without-writing ()
  (supertag-promote-test--isolated
    (let* ((file (supertag-promote-test--file
                  tmp "concepts.org"
                  "* 手工概念\n:PROPERTIES:\n:SUPERTAG_ALIASES: 手工别名\n:END:\nBody\n"))
           (before (supertag-promote-test--disk file))
           (entries (supertag-concept-entries)))
      (should-not (assoc "手工概念" entries))
      (should-not (assoc "手工别名" entries))
      (should-not (supertag-concept-node-p
                   (list :file file :level 1 :title "手工概念")))
      (should (equal before (supertag-promote-test--disk file)))
      (should-not (buffer-modified-p (find-file-noselect file))))))

(ert-deftest supertag-promote-monitor-exit-does-not-remove-old-marker-data ()
  (supertag-promote-test--isolated
    (let* ((file (supertag-promote-test--file
                  tmp "concepts.org"
                  "* Old concept\n:PROPERTIES:\n:ID: old\n:SUPERTAG_CONCEPT: t\n:END:\nKeep body\n"))
           (before (supertag-promote-test--disk file))
           (node (copy-tree (supertag-node-get "old"))))
      (should (assoc "Old concept" (supertag-concept-entries)))
      (setf (plist-get (car supertag-creation-templates) :target-file)
            (expand-file-name "new.org" tmp))
      (should-not (assoc "Old concept" (supertag-concept-entries)))
      (should (equal before (supertag-promote-test--disk file)))
      (should (equal node (supertag-node-get "old")))
      (should-not (buffer-modified-p (find-file-noselect file))))))

(defun supertag-promote-test--four-files (tmp)
  (list
   (supertag-promote-test--file tmp "source.org"
     "* Source\n:PROPERTIES:\n:ID: source\n:END:\nDiscuss Shared topic here.\n")
   (supertag-promote-test--file tmp "old.org"
     "* Shared topic\n:PROPERTIES:\n:ID: retained\n:STAGE: established\n:SUPERTAG_CONCEPT: t\n:END:\nExisting body\n** Child\n:PROPERTIES:\n:ID: child\n:END:\nChild body\n")
   (supertag-promote-test--file tmp "concepts.org" "#+title: Concepts\n")
   (supertag-promote-test--file tmp "inbound.org"
     "* Inbound\n:PROPERTIES:\n:ID: inbound\n:END:\n[[id:retained][Still linked]]\n")))

(defun supertag-promote-test--select-source (file)
  (switch-to-buffer (find-file-noselect file))
  (goto-char (point-min)) (search-forward "Shared topic")
  (set-mark (- (point) (length "Shared topic")))
  (setq mark-active t))

(defmacro supertag-promote-test--choices (choice &rest body)
  (declare (indent 1))
  `(cl-letf (((symbol-function 'completing-read)
              (lambda (prompt collection &rest _)
                (if (string-prefix-p "Promote template" prompt) "c"
                  (or (cl-find-if (lambda (entry) (string-prefix-p ,choice (car entry)))
                                 collection)
                      (error "No expected actual choice"))
                  (car (cl-find-if (lambda (entry) (string-prefix-p ,choice (car entry)))
                                   collection)))))
             ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
     ,@body))

(ert-deftest supertag-promote-public-reuse-preserves-four-file-identity-and-content ()
  (supertag-promote-test--isolated
    (let* ((files (supertag-promote-test--four-files tmp))
           (inbound (supertag-promote-test--disk (nth 3 files)))
           (source (car files)) id)
      (supertag-promote-test--select-source source)
      (supertag-promote-test--choices "1  Reuse"
        (setq id (call-interactively #'supertag-promote)))
      (should (equal "retained" id))
      (should (equal source buffer-file-name))
      (should (string-match-p "\\[\\[id:retained\\]\\[Shared topic\\]\\]"
                              (supertag-promote-test--disk source)))
      (should (equal "[[id:retained][Shared topic]]\n"
                     (supertag-promote-test--disk (nth 1 files))))
      (let ((text (supertag-promote-test--disk (nth 2 files))))
        (dolist (kept '("Existing body" "Child body" ":ID: retained" ":ID: child"
                        ":STAGE: established" ":SUPERTAG_CONCEPT: t"))
          (should (string-match-p (regexp-quote kept) text)))
        (should-not (string-match-p "Template body" text)))
      (should (equal inbound (supertag-promote-test--disk (nth 3 files))))
      (should (equal (file-truename (nth 2 files))
                     (file-truename (plist-get (supertag-node-get "retained") :file)))))))

(ert-deftest supertag-promote-public-same-name-new-applies-full-template ()
  (supertag-promote-test--isolated
    (let* ((files (supertag-promote-test--four-files tmp))
           (old (supertag-promote-test--disk (nth 1 files))) id)
      (supertag-promote-test--select-source (car files))
      (supertag-promote-test--choices "n  Create"
        (setq id (call-interactively #'supertag-promote)))
      (should (stringp id)) (should-not (equal "retained" id))
      (should (equal id (cdr (assoc "Shared topic" (supertag-concept-entries)))))
      (should (equal old (supertag-promote-test--disk (nth 1 files))))
      (let ((text (supertag-promote-test--disk (nth 2 files))))
        (should (string-match-p "Template body" text))
        (should (string-match-p ":STAGE:[ \t]+seed" text))
        (should-not (string-match-p "SUPERTAG_CONCEPT" text))))))

(ert-deftest supertag-promote-public-preview-cancel-is-zero-write ()
  (supertag-promote-test--isolated
    (let* ((files (supertag-promote-test--four-files tmp))
           (before (mapcar #'supertag-promote-test--disk files)) shown caught)
      (supertag-promote-test--select-source (car files))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt _collection &rest _)
                   (if (string-prefix-p "Promote template" prompt) "c"
                     (setq shown (with-current-buffer "*Promote candidates*" (buffer-string)))
                     (signal 'quit nil)))))
        (condition-case data (call-interactively #'supertag-promote)
          (quit (setq caught data))))
      (should (eq (car caught) 'quit))
      (should (string-match-p "Existing body" shown))
      (should (string-match-p "Child body" shown))
      (should (equal before (mapcar #'supertag-promote-test--disk files)))
      (dolist (file files) (should-not (buffer-modified-p (find-file-noselect file)))))))

(defun supertag-promote-test--failed-stage (failed-index expected-stage)
  (supertag-promote-test--isolated
    (let* ((files (supertag-promote-test--four-files tmp))
           (failed-file (nth failed-index files))
           (real-save (symbol-function 'save-buffer)) payload second)
      (supertag-promote-test--select-source (car files))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (if (equal (file-truename buffer-file-name) failed-file)
                       (error "Injected source save")
                     (apply real-save args)))))
        (supertag-promote-test--choices "1  Reuse"
          (condition-case data (call-interactively #'supertag-promote)
            (supertag-link-error (setq payload (cdr data)))))
        (should (eq expected-stage (plist-get payload :stage)))
        (should-error (apply (plist-get payload :retry) (plist-get payload :retry-args))))
      (should (string-match-p ":ID: retained" (supertag-promote-test--disk (nth 2 files))))
      (should-not (supertag-reference-recovery-complete-p payload))
      (cl-letf (((symbol-function 'supertag-sync--reconcile-node)
                 ;; Inject the failure where every projection path writes to the
                 ;; Store, so this retry contract does not depend on which
                 ;; caller parses a node.
                 (lambda (&rest _) (error "Injected projection"))))
        (condition-case data
            (apply (plist-get payload :retry) (plist-get payload :retry-args))
          (supertag-link-error (setq second (cdr data)))))
      (should (plist-get second :retry))
      (should-not (supertag-reference-recovery-complete-p payload))
      (should (equal "retained"
                     (apply (plist-get second :retry) (plist-get second :retry-args))))
      (should (supertag-reference-recovery-complete-p payload))
      (should (equal "retained"
                     (apply (plist-get payload :retry) (plist-get payload :retry-args))))
      (should (equal "[[id:retained][Shared topic]]\n"
                     (supertag-promote-test--disk (nth 1 files))))
      (dolist (pair (list (cons (car files) "id:retained")
                          (cons (nth 2 files) ":ID: retained")
                          (cons (nth 2 files) "Existing body")))
        (with-temp-buffer
          (insert-file-contents (car pair))
          (should (= 1 (how-many (regexp-quote (cdr pair)) (point-min) (point-max)))))))))

(ert-deftest supertag-promote-old-location-save-failure-retains-target-and-retries-once ()
  (supertag-promote-test--failed-stage 1 :old-location-save))

(ert-deftest supertag-promote-current-source-save-failure-retains-target-and-retries-once ()
  (supertag-promote-test--failed-stage 0 :source-save))

(ert-deftest supertag-promote-retry-target-then-source-failure-does-not-reinsert ()
  (supertag-promote-test--isolated
    (let* ((files (supertag-promote-test--four-files tmp))
           (real-save (symbol-function 'save-buffer))
           (failed-file (nth 1 files)) first second)
      (supertag-promote-test--select-source (car files))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (if (equal (file-truename buffer-file-name) failed-file)
                       (error "Next save failure") (apply real-save args)))))
        (supertag-promote-test--choices "1  Reuse"
          (condition-case data (call-interactively #'supertag-promote)
            (supertag-link-error (setq first (cdr data)))))
        (setq failed-file (car files))
        (condition-case data (apply (plist-get first :retry) (plist-get first :retry-args))
          (supertag-link-error (setq second (cdr data)))))
      (should (eq :source-save (plist-get second :stage)))
      (should (equal "retained" (apply (plist-get second :retry) (plist-get second :retry-args))))
      (should (equal "retained" (apply (plist-get first :retry) (plist-get first :retry-args))))
      (with-temp-buffer
        (insert-file-contents (car files))
        (should (= 1 (how-many "id:retained" (point-min) (point-max))))))))

(ert-deftest supertag-promote-idless-same-file-reuse-and-stale-preview ()
  (supertag-promote-test--isolated
    (let* ((file (supertag-promote-test--file tmp "concepts.org"
                  "* Shared topic\n:PROPERTIES:\n:STAGE: retained\n:END:\nKeep body\n"))
           (candidate (with-current-buffer (find-file-noselect file)
                        (supertag-service-org-promote-candidate (copy-marker (point-min))))))
      (should-not (plist-get candidate :node-id))
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-max)) (insert "Changed after preview\n"))
      (should-error (supertag-service-org--promote-validate-candidate candidate)
                    :type 'user-error)
      (supertag-service-org--promote-release-candidates (list candidate))
      (switch-to-buffer (find-file-noselect file))
      (goto-char (point-min)) (setq mark-active nil)
      (let ((id (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                  (supertag-promote "c"))))
        (should (stringp id))
        (should (equal id (plist-get (supertag-node-get id) :id)))
        (should (equal id (cdr (assoc "Shared topic" (supertag-concept-entries)))))
        (should-not (string-match-p "Template body" (supertag-promote-test--disk file)))
        (should (string-match-p "Changed after preview" (supertag-promote-test--disk file)))
        (should (string-match-p ":STAGE: retained" (supertag-promote-test--disk file)))))))

(ert-deftest supertag-promote-retry-does-not-delete-old-node-if-target-draft-was-removed ()
  (supertag-promote-test--isolated
    (let* ((files (supertag-promote-test--four-files tmp))
           (old (supertag-promote-test--disk (nth 1 files)))
           (target (find-file-noselect (nth 2 files)))
           (real-save (symbol-function 'save-buffer)) payload)
      (supertag-promote-test--select-source (car files))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (if (eq (current-buffer) target) (error "Target save failure")
                     (apply real-save args)))))
        (supertag-promote-test--choices "1  Reuse"
          (condition-case data (call-interactively #'supertag-promote)
            (supertag-link-error (setq payload (cdr data))))))
      (should (eq :target-save (plist-get payload :stage)))
      (with-current-buffer target (erase-buffer) (insert "#+title: Concepts\n"))
      (should-error (apply (plist-get payload :retry) (plist-get payload :retry-args))
                    :type 'supertag-link-error)
      (should (equal old (supertag-promote-test--disk (nth 1 files))))
      (should-not (supertag-reference-recovery-complete-p payload)))))

(ert-deftest supertag-promote-rejects-duplicate-identity-outside-reused-subtree ()
  (supertag-promote-test--isolated
    (let* ((file (supertag-promote-test--file tmp "old.org"
                  "* Chosen\n:PROPERTIES:\n:ID: duplicate\n:END:\nA\n* Other\n:PROPERTIES:\n:ID: duplicate\n:END:\nB\n"))
           (before (supertag-promote-test--disk file)))
      (supertag-promote-test--file tmp "concepts.org" "")
      (switch-to-buffer (find-file-noselect file)) (goto-char (point-min))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (should-error (supertag-promote "c") :type 'user-error))
      (should (equal before (supertag-promote-test--disk file)))
      (should (equal "" (supertag-promote-test--disk supertag-concept-default-file))))))

(ert-deftest supertag-promote-idless-text-has-no-monitor-or-act-target ()
  (supertag-promote-test--isolated
    (require 'supertag-embark)
    (let* ((target-file (supertag-promote-test--file tmp "concepts.org"
                         "* 手工概念\nOriginal body\n"))
           (source-file (supertag-promote-test--file tmp "source.org"
                         "* Source\n:PROPERTIES:\n:ID: source\n:END:\n讨论手工概念。\n"))
           (before (supertag-promote-test--disk target-file)))
      (switch-to-buffer (find-file-noselect source-file))
      (supertag-mention-mode 1) (font-lock-ensure)
      (goto-char (point-min)) (search-forward "手工概念")
      (should-not (supertag-embark--node-target-at (match-beginning 0)))
      (should (equal before (supertag-promote-test--disk target-file)))
      (should-not (buffer-modified-p))
      (with-current-buffer (find-file-noselect target-file)
        (goto-char (point-min))
        (should-not (org-entry-get nil "ID"))
        (should-not (buffer-modified-p))))))

(ert-deftest supertag-promote-shared-canonical-target-exit-preserves-drafts-and-facts ()
  (supertag-promote-test--isolated
    (let* ((file (supertag-promote-test--file tmp "concepts.org"
                  "* Shared\n:PROPERTIES:\n:ID: shared\n:SUPERTAG_ALIASES: 别名\n:SUPERTAG_CONCEPT: t\n:END:\nKeep\n"))
           (alias (expand-file-name "alias.org" tmp))
           (before (supertag-promote-test--disk file))
           (node (copy-tree (supertag-node-get "shared"))))
      (make-symbolic-link file alias)
      (push (list :key "s" :name "Same file" :target-file alias) supertag-creation-templates)
      (with-current-buffer (find-file-noselect file) (goto-char (point-max)) (insert "Unsaved draft\n"))
      (let ((live (with-current-buffer (find-file-noselect file) (buffer-string))))
        (setq supertag-creation-templates (list (car supertag-creation-templates)))
        (should (equal "shared" (cdr (assoc "别名" (supertag-concept-entries)))))
        (setf (plist-get (car supertag-creation-templates) :target-file) (expand-file-name "other.org" tmp))
        (should-not (assoc "别名" (supertag-concept-entries)))
        (should (equal before (supertag-promote-test--disk file)))
        (should (equal node (supertag-node-get "shared")))
        (with-current-buffer (find-file-noselect file)
          (should (equal live (buffer-string))) (should (buffer-modified-p)))))))

(ert-deftest supertag-promote-monitored-chinese-occurrence-materializes-only-on-explicit-act ()
  (supertag-promote-test--isolated
    (require 'supertag-embark)
    (supertag-promote-test--file tmp "concepts.org" "* 概念标题\n:PROPERTIES:\n:ID: monitored\n:SUPERTAG_ALIASES: 中文别名\n:END:\nKeep\n")
    (let* ((source (supertag-promote-test--file tmp "source.org"
                    "* Source\n:PROPERTIES:\n:ID: source\n:END:\n讨论中文别名。\n#+begin_src text\n中文别名\n#+end_src\n#+begin_embed: monitored [概念标题]\n中文别名\n#+end_embed\n"))
           (before (supertag-promote-test--disk source)))
      (switch-to-buffer (find-file-noselect source))
      (supertag-mention-mode 1) (font-lock-ensure)
      (goto-char (point-min)) (search-forward "中文别名")
      (let ((target (supertag-embark--node-target-at (match-beginning 0))))
        (should (equal "monitored" (plist-get target :node-id)))
        (dolist (_ '(src embed))
          (search-forward "中文别名")
          (should-not (get-text-property (match-beginning 0) 'supertag-concept-node-id)))
        (should (equal before (supertag-promote-test--disk source)))
        (supertag-embark--link-concept-occurrence target))
      (should (string-match-p "讨论\\[\\[id:monitored\\]\\[中文别名\\]\\]。"
                              (supertag-promote-test--disk source)))
      (should (supertag-query-ordinary-references-from "source")))))

(ert-deftest supertag-promote-idless-cancel-and-confirmed-outside-heading ()
  (supertag-promote-test--isolated
    (let* ((file (supertag-promote-test--file tmp "outside.org" "* Manual\nBody\n"))
           (before (supertag-promote-test--disk file)))
      (switch-to-buffer (find-file-noselect file)) (goto-char (point-min))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (should-error (supertag-promote "c") :type 'user-error))
      (should (equal before (supertag-promote-test--disk file)))
      (should-not (buffer-modified-p))
      (should-not (org-entry-get nil "ID"))
      (let ((id (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                  (supertag-promote "c"))))
        (should (equal id (cdr (assoc "Manual" (supertag-concept-entries)))))
        (should (string-match-p (regexp-quote (concat "id:" id)) (supertag-promote-test--disk file)))
        (should (string-match-p "Body" (supertag-promote-test--disk supertag-concept-default-file)))))))

(ert-deftest supertag-promote-retained-target-source-changed-error-can-resume ()
  (supertag-promote-test--isolated
    (let* ((files (supertag-promote-test--four-files tmp))
           (source (find-file-noselect (car files)))
           (real-save (symbol-function 'save-buffer)) changed payload)
      (supertag-promote-test--select-source (car files))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (prog1 (apply real-save args)
                     (when (and (equal buffer-file-name (nth 2 files)) (not changed))
                       (setq changed t)
                       (with-current-buffer source
                         (save-excursion
                           (goto-char (point-min)) (search-forward "Shared topic")
                           (subst-char-in-region (match-beginning 0) (match-end 0) ?S ?X))))))))
        (supertag-promote-test--choices "1  Reuse"
          (condition-case data (call-interactively #'supertag-promote)
            (supertag-link-error (setq payload (cdr data))))))
      (should (eq :source-edit (plist-get payload :stage)))
      (should (equal "retained" (plist-get payload :target-id)))
      (should-not (supertag-reference-recovery-complete-p payload))
      (with-current-buffer source
        (goto-char (point-min)) (search-forward "Xhared topic")
        (subst-char-in-region (match-beginning 0) (match-end 0) ?X ?S))
      (should (equal "retained" (apply (plist-get payload :retry) (plist-get payload :retry-args))))
      (should (supertag-reference-recovery-complete-p payload)))))

(ert-deftest supertag-promote-monitor-observes-find-add-link-and-native-saved-aliases ()
  (supertag-promote-test--isolated
    (let ((source (supertag-promote-test--file tmp "source.org" "* Source\nBody\n")))
      (switch-to-buffer (find-file-noselect source))
      (cl-letf (((symbol-function 'supertag-ui-read-find-node) (lambda (&rest _) '(:create "From Find")))
                ((symbol-function 'supertag-template-read) (lambda () (car supertag-creation-templates))))
        (supertag-find-node nil))
      (should (assoc "From Find" (supertag-concept-entries)))
      (switch-to-buffer (find-file-noselect source)) (goto-char (point-max))
      (let ((id (cl-letf (((symbol-function 'supertag-reference--read-candidate)
                           (lambda (&rest _)
                             (cons "From Add Link" (propertize "Create" 'supertag-reference-create-title "From Add Link"))))
                          ((symbol-function 'supertag-template-read) (lambda () (car supertag-creation-templates))))
                  (supertag-add-link nil))))
        (should (equal id (cdr (assoc "From Add Link" (supertag-concept-entries)))))
        (with-current-buffer (find-file-noselect supertag-concept-default-file)
          (goto-char (supertag-node-location-find id))
          (org-entry-put nil "SUPERTAG_ALIASES" "新增别名")
          (save-buffer) (supertag-node-sync-at-point)
          (should (equal id (cdr (assoc "新增别名" (supertag-concept-entries)))))
          (org-entry-delete nil "SUPERTAG_ALIASES")
          (save-buffer) (supertag-node-sync-at-point)
          (should-not (assoc "新增别名" (supertag-concept-entries))))))))

(ert-deftest supertag-promote-save-order-and-independent-recovery-operations ()
  (supertag-promote-test--isolated
    (let* ((files (supertag-promote-test--four-files tmp))
           (second-source (supertag-promote-test--file tmp "second.org" "* Second\n:PROPERTIES:\n:ID: second\n:END:\nShared topic\n"))
           (real-save (symbol-function 'save-buffer)) saves first second)
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (push buffer-file-name saves)
                   (if (member buffer-file-name (list (car files) second-source))
                       (error "Source failure") (apply real-save args)))))
        (supertag-promote-test--select-source (car files))
        (supertag-promote-test--choices "1  Reuse"
          (condition-case data (call-interactively #'supertag-promote)
            (supertag-link-error (setq first (cdr data)))))
        (should (equal (reverse saves) (list (nth 2 files) (nth 1 files) (car files))))
        (supertag-promote-test--select-source second-source)
        (supertag-promote-test--choices "1  Reuse"
          (condition-case data (call-interactively #'supertag-promote)
            (supertag-link-error (setq second (cdr data))))))
      (should (plist-get first :retry)) (should (plist-get second :retry))
      (apply (plist-get second :retry) (plist-get second :retry-args))
      (should (supertag-reference-recovery-complete-p second))
      (should-not (supertag-reference-recovery-complete-p first))
      (apply (plist-get first :retry) (plist-get first :retry-args))
      (should (supertag-reference-recovery-complete-p first)))))

(defun supertag-promote-test--facts (files)
  "Read disk, live text, dirty state and projected identities for FILES."
  (list (mapcar #'supertag-promote-test--disk files)
        (mapcar (lambda (file)
                  (with-current-buffer (find-file-noselect file)
                    (save-restriction
                      (widen)
                      (list (buffer-substring-no-properties (point-min) (point-max))
                            (buffer-modified-p))))) files)
        (mapcar (lambda (id) (copy-tree (supertag-node-get id)))
                '("one" "two" "source" "retained" "child"))))

(ert-deftest supertag-promote-repair-region-heading-boundaries ()
  (dolist (reverse '(nil t))
    (dolist (dirty '(nil t))
      (dolist (endpoint '(body heading-inside heading-start))
	(supertag-promote-test--isolated
          (let* ((source (supertag-promote-test--file tmp "source.org"
						      "* One\n:PROPERTIES:\n:ID: one\n:END:\nFirst prose\n* Two\n:PROPERTIES:\n:ID: two\n:END:\nSecond prose\n"))
		 (target (supertag-promote-test--file tmp "concepts.org" ""))
		 begin end)
            (switch-to-buffer (find-file-noselect source))
            (when dirty
              (goto-char (point-max)) (insert "Unrelated source draft\n")
              (with-current-buffer (find-file-noselect target) (insert "Target draft\n")))
            (goto-char (point-min)) (search-forward "First")
            (setq begin (match-beginning 0))
            (search-forward "* Two")
            (setq end (pcase endpoint
                        ('heading-start (match-beginning 0))
                        ('heading-inside (point))
                        ('body (search-forward "Second"))))
            (goto-char (if reverse begin end))
            (set-mark (if reverse end begin)) (setq mark-active t)
            (let ((before (supertag-promote-test--facts (list source target))))
              (supertag-promote-test--choices "n  Create"
		(if (eq endpoint 'heading-start)
		    (progn
		      (should (stringp (supertag-promote "c")))
		      (should (string-match-p "\\* Two\n:PROPERTIES:\n:ID: two"
					      (supertag-promote-test--disk source))))
		  (should-error (supertag-promote "c") :type 'user-error)
		  (should (equal before (supertag-promote-test--facts (list source target)))))))))))))

(defun supertag-promote-test--target-stage-failure (files stage)
  "Run the public flow and return its original failed STAGE payload."
  (let ((real-save (symbol-function 'save-buffer))
        (real-project (symbol-function 'supertag-service-org--retry-move-projection))
        payload)
    (supertag-promote-test--select-source (car files))
    (cl-letf (((symbol-function 'save-buffer)
               (lambda (&rest args)
                 (if (and (eq stage :old-location-save)
                          (equal buffer-file-name (nth 1 files)))
                     (error "Injected old location save")
                   (apply real-save args))))
              ((symbol-function 'supertag-service-org--retry-move-projection)
               (lambda (&rest args)
                 (if (eq stage :target-project) (error "Injected target projection")
                   (apply real-project args)))))
      (supertag-promote-test--choices "1  Reuse"
	(condition-case data (supertag-promote "c")
	  (supertag-link-error (setq payload (cdr data))))))
    (should (eq stage (plist-get payload :stage)))
    payload))

(ert-deftest supertag-promote-repair-later-retry-revalidates-durable-target ()
  (dolist (stage '(:old-location-save :target-project))
    (dolist (change '(deleted-saved child-draft))
      (supertag-promote-test--isolated
        (let* ((files (supertag-promote-test--four-files tmp))
               (payload (supertag-promote-test--target-stage-failure files stage))
               (target (find-file-noselect (nth 2 files)))
               (saved (supertag-promote-test--disk (nth 2 files))))
          (with-current-buffer target
            (goto-char (point-min))
            (if (eq change 'deleted-saved)
                (progn (erase-buffer) (insert "#+title: Concepts\n") (save-buffer))
              (goto-char (point-max)) (insert "Unsaved child addition\n")))
          (let ((before (supertag-promote-test--facts files)))
            (dotimes (_ 2)
              (should-error (apply (plist-get payload :retry) (plist-get payload :retry-args))
                            :type 'supertag-link-error)
              (should-not (supertag-reference-recovery-complete-p payload))
              (should (equal before (supertag-promote-test--facts files)))))
          ;; Explicit reconciliation by the user, then retry the same payload.
          (with-current-buffer target (erase-buffer) (insert saved) (save-buffer))
          (should (equal "retained" (apply (plist-get payload :retry) (plist-get payload :retry-args))))
          (should (supertag-reference-recovery-complete-p payload))
          (should (equal "retained" (apply (plist-get payload :retry) (plist-get payload :retry-args))))
          (with-temp-buffer
            (insert-file-contents (nth 2 files))
            (should (= 1 (how-many ":ID: retained" (point-min) (point-max)))))
          (should-not (string-match-p "Unsaved child addition"
                                      (format "%S" (supertag-node-get "child")))))))))

(ert-deftest supertag-promote-repair-old-location-edit-after-failure-is-not-saved ()
  (dolist (stage '(:old-location-save :target-project))
    (supertag-promote-test--isolated
      (let* ((files (supertag-promote-test--four-files tmp))
             (payload (supertag-promote-test--target-stage-failure files stage)))
        (with-current-buffer (find-file-noselect (nth 1 files))
          (goto-char (point-max)) (insert "User recovery draft\n"))
        (let ((before (supertag-promote-test--facts files)))
          (dotimes (_ 2)
            (should-error (apply (plist-get payload :retry) (plist-get payload :retry-args))
                          :type 'supertag-link-error)
            (should-not (supertag-reference-recovery-complete-p payload))
            (should (equal before (supertag-promote-test--facts files)))))))))

(ert-deftest supertag-promote-repair-same-target-preserves-logical-context ()
  (dolist (narrow '(nil t))
    (dolist (active '(nil t))
      (supertag-promote-test--isolated
        (let ((file (supertag-promote-test--file tmp "concepts.org"
						 "* Before\nOther\n* Shared topic :existing:\n:PROPERTIES:\n:ID: retained\n:STAGE: established\n:END:\nBody alpha omega\n** Child\n:PROPERTIES:\n:ID: child\n:END:\nChild body\n* After\nKeep\n")))
          (push '("MISSING" . "filled") (plist-get (car supertag-creation-templates) :properties))
          (switch-to-buffer (find-file-noselect file))
          (goto-char (point-min)) (search-forward "Body alpha")
          ;; An active empty region still invokes current-heading Promote.
          (set-mark (if active (point) (- (point) 3)))
          (setq mark-active active)
          (when narrow
            (save-excursion (org-back-to-heading t) (org-narrow-to-subtree)))
          (let ((point-tail (buffer-substring-no-properties (point) (line-end-position)))
                (mark-tail (save-excursion (goto-char (mark))
                                           (buffer-substring-no-properties (point) (line-end-position))))
                (minimum (copy-marker (point-min)))
                (maximum (copy-marker (point-max) t)))
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
              (should (equal "retained" (supertag-promote "c"))))
            (should (equal point-tail (buffer-substring-no-properties (point) (line-end-position))))
            (should (equal mark-tail (save-excursion (goto-char (mark))
                                                     (buffer-substring-no-properties (point) (line-end-position)))))
            (should (eq active mark-active))
            (should (eq narrow (buffer-narrowed-p)))
            (should (= minimum (point-min))) (should (= maximum (point-max)))
            (set-marker minimum nil) (set-marker maximum nil))
          (save-excursion
            (org-back-to-heading t)
            (should (equal "retained" (org-entry-get nil "ID")))
            (should (equal "established" (org-entry-get nil "STAGE")))
            (should (equal "filled" (org-entry-get nil "MISSING")))
            (should (member "existing" (org-get-tags nil t)))
            (should (member "concept" (org-get-tags nil t))))
          (with-temp-buffer
            (insert-file-contents file)
            (should (= 1 (how-many ":ID: retained" (point-min) (point-max))))
            (should (= 1 (how-many ":ID: child" (point-min) (point-max))))))))))

(defun supertag-promote-test--source-retry-safety (stage)
  "Exercise STAGE with fresh and reused targets and changed retained facts."
  (dolist (choice '("1  Reuse" "n  Create"))
    (dolist (change '(deleted-saved target-draft source-draft))
      (supertag-promote-test--isolated
        (let* ((files (supertag-promote-test--four-files tmp))
               (source (find-file-noselect (car files)))
               (target (find-file-noselect (nth 2 files)))
               (real-save (symbol-function 'save-buffer))
               (real-project (symbol-function 'supertag-ui--reproject-containing-node))
               (real-materialize (symbol-function 'supertag-reference-materialize))
               payload)
          (supertag-promote-test--select-source (car files))
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest args)
                       (if (and (eq stage :source-save) (eq (current-buffer) source))
                           (error "Injected source save") (apply real-save args))))
                    ((symbol-function 'supertag-ui--reproject-containing-node)
                     (lambda (id)
                       (if (and (eq stage :source-project) (equal id "source"))
                           (error "Injected source projection") (funcall real-project id))))
                    ((symbol-function 'supertag-reference-materialize)
                     (lambda (&rest args)
                       (if (eq stage :source-edit) (user-error "Injected source edit")
                         (apply real-materialize args)))))
            (supertag-promote-test--choices choice
	      (condition-case data (supertag-promote "c")
		(supertag-link-error (setq payload (cdr data))))))
          (should (eq stage (plist-get payload :stage)))
          (let ((target-text (supertag-promote-test--disk (nth 2 files)))
                (edited (if (eq change 'source-draft) source target))
                original-end)
            (with-current-buffer edited
              (setq original-end (point-max))
              (if (eq change 'deleted-saved)
                  (progn (erase-buffer) (insert "#+title: Concepts\n") (save-buffer))
                (goto-char (point-max)) (insert "Unconfirmed recovery draft\n")))
            (let ((before (supertag-promote-test--facts files)))
              (dotimes (_ 2)
                (should-error (apply (plist-get payload :retry) (plist-get payload :retry-args))
                              :type 'supertag-link-error)
                (should-not (supertag-reference-recovery-complete-p payload))
                (should (equal before (supertag-promote-test--facts files)))))
            (with-current-buffer edited
              (if (eq change 'deleted-saved)
                  (progn (erase-buffer) (insert target-text) (save-buffer))
                (delete-region original-end (point-max))
                ;; Reconcile to the prior durable state when the operation was
                ;; not retaining its own failed source-save draft.
                (unless (and (eq change 'source-draft) (eq stage :source-save))
                  (save-buffer))))
            (let ((id (apply (plist-get payload :retry) (plist-get payload :retry-args))))
              (should (equal id (plist-get payload :target-id)))
              (should (supertag-reference-recovery-complete-p payload))
              (should (equal id (apply (plist-get payload :retry) (plist-get payload :retry-args))))
              (with-temp-buffer
                (insert-file-contents (car files))
                (should (= 1 (how-many (regexp-quote (concat "id:" id)) (point-min) (point-max)))))
              (with-temp-buffer
                (insert-file-contents (nth 2 files))
                (should (= 1 (how-many (concat ":ID:[ \t]+" (regexp-quote id)) (point-min) (point-max))))))
            (should-not (string-match-p "Unconfirmed recovery draft"
                                        (format "%S" (supertag-node-get "source"))))))))))

(ert-deftest supertag-promote-repair-source-edit-retry-safety ()
  (supertag-promote-test--source-retry-safety :source-edit))
(ert-deftest supertag-promote-repair-source-save-retry-safety ()
  (supertag-promote-test--source-retry-safety :source-save))
(ert-deftest supertag-promote-repair-source-project-retry-safety ()
  (supertag-promote-test--source-retry-safety :source-project))

(ert-deftest supertag-promote-repair-confirmation-changes-selection-and-candidate ()
  (dolist (change '(selection identified-child))
    (supertag-promote-test--isolated
      (let* ((files (supertag-promote-test--four-files tmp)) before)
        (supertag-promote-test--select-source (car files))
        (supertag-promote-test--choices "1  Reuse"
	  (cl-letf (((symbol-function 'yes-or-no-p)
		     (lambda (&rest _)
		       (if (eq change 'selection)
			   (save-excursion (goto-char (region-beginning))
					   (delete-char 1) (insert "X"))
			 (with-current-buffer (find-file-noselect (nth 1 files))
			   (goto-char (point-max)) (insert "Changed child after preview\n")))
		       (setq before (supertag-promote-test--facts files)) t)))
	    (should-error (supertag-promote "c") :type 'user-error)))
        (should (equal before (supertag-promote-test--facts files)))))))

(ert-deftest supertag-promote-repair-native-save-queue-updates-monitor-without-writes ()
  (supertag-promote-test--isolated
    (let* ((supertag-sync--state (list :sync-state (make-hash-table :test 'equal)))
           (supertag-sync--state-source supertag-sync-state-file)
           (supertag-sync--internal-modifications (make-hash-table :test 'equal))
           (supertag-sync--deferred-files (make-hash-table :test 'equal))
           (supertag-async--queue nil)
           (supertag-async--failed-items nil)
           (supertag-async--timer nil)
           (supertag-async--processor-fn #'supertag-sync--async-processor)
           (supertag-after-operation-hook nil)
           (supertag-automation--enabled nil)
           (supertag-automation-sync--enabled nil)
           (file (supertag-promote-test--file tmp "concepts.org"
					      "* Native title\n:PROPERTIES:\n:ID: native\n:END:\nBody\n* No identity\nKeep\n"))
           (source (supertag-promote-test--file tmp "source.org"
					        "* Reader\n:PROPERTIES:\n:ID: reader\n:END:\n原生别名。\n"))
           (hook-calls 0))
      (cl-letf (((symbol-function 'supertag-async--ensure-timer) #'ignore))
        (with-current-buffer (find-file-noselect file)
          (setq-local after-save-hook nil)
          (supertag-sync-setup-realtime-hooks)
          (add-hook 'after-save-hook (lambda () (cl-incf hook-calls)) nil t)
          (goto-char (point-min))
          (org-entry-put nil "SUPERTAG_ALIASES" "原生别名")
          (should-not (assoc "原生别名" (supertag-concept-entries)))
          (save-buffer))
        (should (= 1 hook-calls))
        (should (equal (list file) supertag-async--queue))
        (let ((saved (supertag-promote-test--facts (list file source))))
          (supertag-async--worker)
          (should-not supertag-async--queue)
          (should-not supertag-async--failed-items)
          (should (equal "native" (cdr (assoc "原生别名" (supertag-concept-entries)))))
          (switch-to-buffer (find-file-noselect source))
          (supertag-mention-mode 1) (font-lock-ensure)
          (goto-char (point-min)) (search-forward "原生别名")
          (should (equal "native" (get-text-property (match-beginning 0) 'supertag-concept-node-id)))
          (should (equal (seq-take saved 2)
                         (seq-take (supertag-promote-test--facts (list file source)) 2)))
          (should-not (assoc "No identity" (supertag-concept-entries))))
        (with-current-buffer (find-file-noselect file)
          (goto-char (point-min)) (org-entry-delete nil "SUPERTAG_ALIASES")
          (save-buffer))
        (should (= 2 hook-calls))
        (should (equal (list file) supertag-async--queue))
        (supertag-async--worker)
        (should-not supertag-async--failed-items)
        (should-not (assoc "原生别名" (supertag-concept-entries)))
        (with-current-buffer (find-file-noselect source)
          (supertag-concept-refresh) (font-lock-ensure)
          (goto-char (point-min)) (search-forward "原生别名")
          (should-not (get-text-property (match-beginning 0) 'supertag-concept-node-id)))
        ))))

(ert-deftest supertag-promote-repair-duplicate-template-key-is-zero-write ()
  (supertag-promote-test--isolated
    (let* ((files (supertag-promote-test--four-files tmp))
           (before (supertag-promote-test--facts files)))
      (push (copy-tree (car supertag-creation-templates)) supertag-creation-templates)
      (supertag-promote-test--select-source (car files))
      (should-error (supertag-promote "c") :type 'user-error)
      (should (equal before (supertag-promote-test--facts files))))))

(ert-deftest supertag-promote-repair-original-payload-follows-later-failed-stage ()
  (dolist (initial '(:old-location-save :target-project))
    (supertag-promote-test--isolated
      (let* ((files (supertag-promote-test--four-files tmp))
             (payload (supertag-promote-test--target-stage-failure files initial))
             (real-save (symbol-function 'save-buffer)))
        (cl-letf (((symbol-function 'save-buffer)
                   (lambda (&rest args)
                     (if (equal buffer-file-name (car files)) (error "Source save failure")
                       (apply real-save args)))))
          (dotimes (_ 2)
            (should-error (apply (plist-get payload :retry) (plist-get payload :retry-args))
                          :type 'supertag-link-error)))
        (should-not (supertag-reference-recovery-complete-p payload))
        (should (equal "retained" (apply (plist-get payload :retry) (plist-get payload :retry-args))))
        (should (supertag-reference-recovery-complete-p payload))
        (should (equal "retained" (apply (plist-get payload :retry) (plist-get payload :retry-args))))
        (with-temp-buffer
          (insert-file-contents (car files))
          (should (= 1 (how-many "id:retained" (point-min) (point-max)))))))))

(ert-deftest supertag-promote-repair-reuse-normalizes-nested-levels-and-merges-tags ()
  (supertag-promote-test--isolated
    (let* ((files (supertag-promote-test--four-files tmp))
           (old (nth 1 files)))
      (with-current-buffer (find-file-noselect old)
        (goto-char (point-min)) (insert "* Container\nKeep parent\n")
        (org-demote-subtree)
        (org-set-tags '("existing"))
        (save-buffer) (supertag-node-sync-at-point))
      (supertag-promote-test--select-source (car files))
      (supertag-promote-test--choices "1  Reuse"
	(should (equal "retained" (supertag-promote "c"))))
      (with-current-buffer (find-file-noselect (nth 2 files))
        (goto-char (supertag-node-location-find "retained"))
        (should (= 1 (org-outline-level)))
        (should (member "existing" (org-get-tags nil t)))
        (should (member "concept" (org-get-tags nil t)))
        (goto-char (supertag-node-location-find "child"))
        (should (= 2 (org-outline-level))))
      (should (string-match-p "Keep parent" (supertag-promote-test--disk old)))
      (should (string-match-p "Child body" (supertag-promote-test--disk (nth 2 files)))))))

(ert-deftest supertag-promote-repair-monitor-protected-org-contexts ()
  (supertag-promote-test--isolated
    (supertag-promote-test--file tmp "concepts.org"
				 "* ProtectedTerm\n:PROPERTIES:\n:ID: protected\n:END:\nBody\n")
    (let* ((file (supertag-promote-test--file tmp "source.org"
					      "* Source\n:PROPERTIES:\n:ID: source\n:NOTE: ProtectedTerm\n:END:\nProtectedTerm prose\n[[id:protected][ProtectedTerm]]\n=ProtectedTerm=\n~ProtectedTerm~\n#+begin_example\nProtectedTerm\n#+end_example\n#+begin_comment\nProtectedTerm\n#+end_comment\n| ProtectedTerm |\n* COMMENT Hidden\nProtectedTerm\n"))
           (before (supertag-promote-test--facts (list file))))
      (switch-to-buffer (find-file-noselect file))
      (supertag-mention-mode 1) (font-lock-ensure)
      (goto-char (point-min))
      (while (search-forward "ProtectedTerm" nil t)
        (should (eq (and (save-match-data (looking-at " prose")) t)
                    (and (get-text-property (match-beginning 0) 'supertag-concept-node-id) t))))
      (should (equal before (supertag-promote-test--facts (list file)))))))

(ert-deftest supertag-promote-repair-source-save-hook-draft-is-not-projected ()
  (supertag-promote-test--isolated
    (let* ((files (supertag-promote-test--four-files tmp))
           (real-save (symbol-function 'save-buffer)) payload)
      (supertag-promote-test--select-source (car files))
      (cl-letf (((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (if (equal buffer-file-name (car files)) (error "Source save failed")
                     (apply real-save args)))))
        (supertag-promote-test--choices "1  Reuse"
	  (condition-case data (supertag-promote "c")
	    (supertag-link-error (setq payload (cdr data))))))
      (let ((before (copy-tree (supertag-node-get "source"))))
        (with-current-buffer (find-file-noselect (car files))
          (let ((after-save-hook
                 (list (lambda () (goto-char (point-max)) (insert "After-save draft\n")))))
            (should-error (apply (plist-get payload :retry) (plist-get payload :retry-args))
                          :type 'supertag-link-error)))
        (should-not (supertag-reference-recovery-complete-p payload))
        (should (equal before (supertag-node-get "source")))
        (should-not (string-match-p "After-save draft" (supertag-promote-test--disk (car files))))))))

(ert-deftest supertag-promote-repair-fresh-target-failure-retry-preserves-drafts ()
  (dolist (stage '(:target-save :target-project))
    (supertag-promote-test--isolated
      (let* ((files (supertag-promote-test--four-files tmp))
             (real-save (symbol-function 'save-buffer))
             (real-project (symbol-function 'supertag-service-org--project-current-node))
             payload original-end)
        (supertag-promote-test--select-source (car files))
        (cl-letf (((symbol-function 'save-buffer)
                   (lambda (&rest args)
                     (if (and (eq stage :target-save) (equal buffer-file-name (nth 2 files)))
                         (error "Fresh target save failure") (apply real-save args))))
                  ((symbol-function 'supertag-service-org--project-current-node)
                   (lambda (id)
                     (if (and (eq stage :target-project) (equal buffer-file-name (nth 2 files)))
                         (error "Fresh target project failure") (funcall real-project id)))))
          (supertag-promote-test--choices "n  Create"
	    (condition-case data (supertag-promote "c")
	      (supertag-link-error (setq payload (cdr data))))))
        (should (eq stage (plist-get payload :stage)))
        (with-current-buffer (find-file-noselect (nth 2 files))
          (setq original-end (point-max))
          (goto-char original-end) (insert "New target draft\n"))
        (let ((before (supertag-promote-test--facts files)))
          (dotimes (_ 2)
            (should-error (apply (plist-get payload :retry) (plist-get payload :retry-args))
                          :type 'supertag-link-error)
            (should-not (supertag-reference-recovery-complete-p payload))
            (should (equal before (supertag-promote-test--facts files)))))
        (with-current-buffer (find-file-noselect (nth 2 files))
          (delete-region original-end (point-max))
          (when (eq stage :target-project) (save-buffer)))
        (when (eq stage :target-save)
          (let (next)
            (cl-letf (((symbol-function 'supertag-service-org--project-current-node)
                       (lambda (&rest _) (error "Next target projection failure"))))
              (condition-case data
                  (apply (plist-get payload :retry) (plist-get payload :retry-args))
                (supertag-link-error (setq next (cdr data)))))
            (should (eq :target-project (plist-get next :stage)))
            (should-not (supertag-reference-recovery-complete-p payload))))
        (let ((id (apply (plist-get payload :retry) (plist-get payload :retry-args))))
          (should (stringp id))
          (should (supertag-reference-recovery-complete-p payload))
          (should-not (string-match-p "New target draft" (format "%S" (supertag-node-get id)))))))))

(ert-deftest supertag-promote-b2-rejected-hook-draft-never-becomes-retry-baseline ()
  (dolist (choice '("1  Reuse" "n  Create"))
    (supertag-promote-test--isolated
      (let* ((files (supertag-promote-test--four-files tmp))
             (source (find-file-noselect (car files)))
             (real-save (symbol-function 'save-buffer)) payload allowed)
        (supertag-promote-test--select-source (car files))
        (cl-letf (((symbol-function 'save-buffer)
                   (lambda (&rest args)
                     (if (eq (current-buffer) source) (error "Initial source save failure")
                       (apply real-save args)))))
          (supertag-promote-test--choices choice
            (condition-case data (supertag-promote "c")
              (supertag-link-error (setq payload (cdr data))))))
        (should (eq :source-save (plist-get payload :stage)))
        (with-current-buffer source (setq allowed (buffer-string)))
        (let ((projected (copy-tree (supertag-node-get "source"))))
          (with-current-buffer source
            (let ((after-save-hook
                   (list (lambda () (goto-char (point-max)) (insert "Rejected hook draft\n")))))
              (should-error (apply (plist-get payload :retry) (plist-get payload :retry-args))
                            :type 'supertag-link-error)))
          (should (equal projected (supertag-node-get "source")))
          (should (equal allowed (supertag-promote-test--disk (car files))))
          ;; The hook is gone.  No text was restored, saved or confirmed.
          (let ((rejected (supertag-promote-test--facts files)))
            (dotimes (_ 2)
              (should-error (apply (plist-get payload :retry) (plist-get payload :retry-args))
                            :type 'supertag-link-error)
              (should-not (supertag-reference-recovery-complete-p payload))
              (should (equal rejected (supertag-promote-test--facts files)))))
          (with-current-buffer source
            (should (buffer-modified-p))
            (should (string-suffix-p "Rejected hook draft\n" (buffer-string)))
            ;; Explicitly restore the operation's allowed link draft.
            (delete-region (+ (point-min) (length allowed)) (point-max))
            (should (equal allowed (buffer-string))))
          (let ((id (apply (plist-get payload :retry) (plist-get payload :retry-args))))
            (should (equal id (plist-get payload :target-id)))
            (should (supertag-reference-recovery-complete-p payload))
            (let ((finished (supertag-promote-test--facts files)))
              (should (equal id (apply (plist-get payload :retry) (plist-get payload :retry-args))))
              (should (equal finished (supertag-promote-test--facts files)))))
          (should-not (string-match-p "Rejected hook draft" (format "%S" (supertag-node-get "source")))))))))

(ert-deftest supertag-promote-b2-source-edit-link-draft-remains-recoverable ()
  (dolist (choice '("1  Reuse" "n  Create"))
    (supertag-promote-test--isolated
      (let* ((files (supertag-promote-test--four-files tmp))
             (source (find-file-noselect (car files)))
             (original (supertag-promote-test--disk (car files)))
             (real-save (symbol-function 'save-buffer)) payload next)
        (supertag-promote-test--select-source (car files))
        (cl-letf (((symbol-function 'supertag-reference-materialize)
                   (lambda (&rest _) (user-error "Initial source edit failure"))))
          (supertag-promote-test--choices choice
            (condition-case data (supertag-promote "c")
              (supertag-link-error (setq payload (cdr data))))))
        (should (eq :source-edit (plist-get payload :stage)))
        (cl-letf (((symbol-function 'save-buffer)
                   (lambda (&rest args)
                     (if (eq (current-buffer) source) (error "Save after real link edit failed")
                       (apply real-save args)))))
          (condition-case data
              (apply (plist-get payload :retry) (plist-get payload :retry-args))
            (supertag-link-error (setq next (cdr data))))
          (should (eq :source-save (plist-get next :stage)))
          (should-not (supertag-reference-recovery-complete-p payload))
          (should (equal original (supertag-promote-test--disk (car files))))
          (let ((draft (supertag-promote-test--facts files)))
            (should-error (apply (plist-get payload :retry) (plist-get payload :retry-args))
                          :type 'supertag-link-error)
            (should (equal draft (supertag-promote-test--facts files)))))
        (with-current-buffer source
          (should (buffer-modified-p))
          (should (= 1 (how-many (regexp-quote (concat "id:" (plist-get payload :target-id)))
                                 (point-min) (point-max)))))
        (let ((id (apply (plist-get payload :retry) (plist-get payload :retry-args))))
          (should (equal id (plist-get payload :target-id)))
          (should (supertag-reference-recovery-complete-p payload))
          (should (supertag-reference-recovery-complete-p next))
          (let ((finished (supertag-promote-test--facts files)))
            (should (equal id (apply (plist-get payload :retry) (plist-get payload :retry-args))))
            (should (equal finished (supertag-promote-test--facts files)))))
        (with-temp-buffer
          (insert-file-contents (car files))
          (should (= 1 (how-many (regexp-quote (concat "id:" (plist-get payload :target-id)))
                                 (point-min) (point-max)))))))))


(ert-deftest supertag-promote-node-view-omits-empty-mention-section ()
  (supertag-promote-test--isolated
    (let ((concept (supertag-promote-test--file tmp "concepts.org"
                    "* Same title\n:PROPERTIES:\n:ID: concept-node\n:END:\nBody\n"))
          (ordinary (supertag-promote-test--file tmp "ordinary.org"
                     "* Same title\n:PROPERTIES:\n:ID: ordinary-node\n:END:\nBody\n")))
      (dolist (entry (list (cons "concept-node" concept) (cons "ordinary-node" ordinary)))
        (let ((disk (supertag-promote-test--disk (cdr entry)))
              (store (prin1-to-string supertag--store))
              (buffer (find-file-noselect (cdr entry))))
          (with-current-buffer buffer (should-not (buffer-modified-p)))
          (supertag-view-node-open (car entry))
          (with-current-buffer supertag-view-node--buffer-name
            ;; The magazine view renders a mentions chip only when it has
            ;; entries, including for a concept node.
            (should-not (string-match-p "UNLINKED MENTIONS /" (buffer-string))))
          (should (equal disk (supertag-promote-test--disk (cdr entry))))
          (with-current-buffer buffer
            (should (equal disk (buffer-string)))
            (should-not (buffer-modified-p)))
          (should (equal store (prin1-to-string supertag--store))))))))

(ert-deftest supertag-promote-shortcut-command-passes-template-key ()
  (unwind-protect
      (progn
        (eval '(supertag-define-promote-command supertag-promote-test--shortcut "c" "Test shortcut."))
        (should (commandp 'supertag-promote-test--shortcut))
        (should (equal "Test shortcut." (documentation 'supertag-promote-test--shortcut)))
        (let (received)
          (cl-letf (((symbol-function 'supertag-promote) (lambda (key) (setq received key))))
            (call-interactively 'supertag-promote-test--shortcut))
          (should (equal "c" received))))
    (fmakunbound 'supertag-promote-test--shortcut)))

(ert-deftest supertag-promote-shortcut-unknown-key-is-zero-write ()
  (supertag-promote-test--isolated
    (let* ((file (supertag-promote-test--file tmp "source.org" "* Ordinary\nBody\n"))
           (disk (supertag-promote-test--disk file))
           (store (prin1-to-string supertag--store)))
      (unwind-protect
          (progn
            (eval '(supertag-define-promote-command supertag-promote-test--unknown "unknown"))
            (should (commandp 'supertag-promote-test--unknown))
            (should (equal (format "Promote using template %s." "unknown")
                           (documentation 'supertag-promote-test--unknown)))
            (with-current-buffer (find-file-noselect file)
              (goto-char (point-min))
              (should-error (call-interactively 'supertag-promote-test--unknown) :type 'user-error)
              (should (equal disk (buffer-string)))
              (should-not (buffer-modified-p)))
            (should (equal disk (supertag-promote-test--disk file)))
            (should (equal store (prin1-to-string supertag--store)))
            (should-not (file-exists-p supertag-concept-default-file)))
        (fmakunbound 'supertag-promote-test--unknown)))))

(provide 'promote-workflow-test)
;;; promote-workflow-test.el ends here

;;; CONCEPT-A: native loading boundaries and original transient recovery.
(defun supertag-promote-test--ca-child (name entry body)
  "Run BODY in a fresh ENTRY process; parent facts are not preloaded."
  (let* ((test-file (symbol-file 'supertag-promote-test--ca-child 'defun))
         (root (file-name-directory (directory-file-name (file-name-directory test-file))))
         (tmp (make-temp-file "supertag-ca-child-" t))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
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
                              org-id-locations-file ,(expand-file-name "ids" tmp)
                              org-id-track-globally nil after-init-time nil
                              make-backup-files nil auto-save-default nil load-prefer-newer t)
                        (load ,(expand-file-name (concat (symbol-name entry) ".el") root) nil nil t)
                        (princ ,(format "CA-%s-ENTRY\n" name))
                        (let ((before (equal (getenv "SUPERTAG_CA_STAGE") "before"))
                              (root ,root) (test-file ,test-file)) ,@body)
                        (princ ,(format "CA-%s-DONE\n" name)))
                    (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil
                          enable-theme-functions nil)
                    (mapc #'cancel-timer (append timer-list timer-idle-list)))))
            (with-temp-buffer
              (let ((code (apply #'call-process program nil t nil
                                 (append '("-Q" "--batch")
                                         (apply #'append (mapcar (lambda (dir) (list "-L" dir)) deps))
                                         (list "-L" root "-L" (expand-file-name "test" root)
                                               "--eval" (prin1-to-string
                                                         `(condition-case err ,form
                                                            (error (princ (format "CA-ERROR %S\n" err))
                                                                   (kill-emacs 1)))))))))
                (princ (buffer-string))
                (unless (and (equal code 0)
                             (string-match-p (format "CA-%s-ENTRY" name) (buffer-string))
                             (string-match-p (format "CA-%s-DONE" name) (buffer-string)))
                  (ert-fail (format "CA %s exit=%S\n%s" name code (buffer-string))))))))
      (delete-directory tmp t))))

(defun supertag-promote-test--ca-recover (choice hook-draft)
  "Exercise real public CHOICE, original payload, and optional HOOK-DRAFT."
  (supertag-promote-test--isolated
    (let* ((files (supertag-promote-test--four-files tmp))
           (source (find-file-noselect (car files)))
           (inbound (supertag-promote-test--disk (nth 3 files)))
           (old (supertag-promote-test--disk (nth 1 files)))
           (save (symbol-function 'save-buffer))
           (guard-calls 0)
           (guard (lambda (&rest _) (cl-incf guard-calls))) payload allowed state operation id begin end)
      ;; Transparent advice remains installed across real Concept reload.
      (advice-add 'supertag-service-org-promote-check-source-stage :before guard)
      (unwind-protect
          (let ((advised (symbol-function 'supertag-service-org-promote-check-source-stage)))
            (let* ((symbols '(supertag-service-org--promote-check-retained-target
                              supertag-service-org-promote-call-source
                              supertag-service-org-promote-check-source-stage
                              supertag-service-org-promote-source-state
                              supertag-service-org-promote-target
                              supertag-service-org-promote-target-guard))
                   (cells (mapcar #'symbol-function symbols)))
              (dolist (symbol symbols)
                (should-not (autoloadp (symbol-function symbol)))
                (should (equal (if (or (equal (getenv "SUPERTAG_CB_STAGE") "before")
                                  (equal (getenv "SUPERTAG_CA_STAGE") "before"))
                                   "supertag-service-org.el" "supertag-concept.el")
                               (file-name-nondirectory (symbol-file symbol 'defun)))))
              ;; Require-only does not redefine either generation's real providers.
              (require 'supertag-concept)
              (cl-mapc (lambda (symbol cell) (should (eq cell (symbol-function symbol)))) symbols cells)
              (should (eq advised (symbol-function 'supertag-service-org-promote-check-source-stage)))
              (load (locate-library "supertag-concept.el") nil nil t)
              (if (or (equal (getenv "SUPERTAG_CB_STAGE") "before")
                      (equal (getenv "SUPERTAG_CA_STAGE") "before"))
                  (progn
                    (cl-mapc (lambda (symbol cell) (should (eq cell (symbol-function symbol)))) symbols cells)
                    (princ "CA-SIX-REAL-PROVIDERS-RELOAD-PRESERVED\n"))
                (princ (format "CB-SIX-REAL-PROVIDERS-RELOAD-EQ=%S\n"
                               (cl-mapcar (lambda (symbol cell) (eq cell (symbol-function symbol))) symbols cells)))
                (dolist (symbol symbols)
                  (should-not (autoloadp (symbol-function symbol)))
                  (should (equal "supertag-concept.el"
                                 (file-name-nondirectory (symbol-file symbol 'defun)))))))
            (if (or (equal (getenv "SUPERTAG_CB_STAGE") "before")
                    (equal (getenv "SUPERTAG_CA_STAGE") "before"))
                (should (eq advised (symbol-function 'supertag-service-org-promote-check-source-stage)))
              (should (advice-member-p guard 'supertag-service-org-promote-check-source-stage)))
            (supertag-promote-test--select-source (car files))
            (cl-letf (((symbol-function 'save-buffer)
                       (lambda (&rest args)
                         (if (eq (current-buffer) source) (error "CA injected source save")
                           (apply save args)))))
              (supertag-promote-test--choices choice
                (condition-case err (call-interactively #'supertag-promote)
                  (supertag-link-error (setq payload (cdr err))))))
            (should (eq :source-save (plist-get payload :stage)))
            (setq id (plist-get payload :target-id)
                  operation (plist-get payload :recovery-operation)
                  state (car (aref (car (plist-get payload :retry-args)) 1))
                  begin (plist-get state :begin) end (plist-get state :end))
            (should id) (should (consp operation))
            (should-not (supertag-reference-recovery-complete-p payload))
            (should (equal (nth 2 files) (plist-get (supertag-node-get id) :file)))
            (should (string-match-p (concat ":ID:[ \t]+" (regexp-quote id))
                                    (supertag-promote-test--disk (nth 2 files))))
            (with-current-buffer source (setq allowed (buffer-string)))
            (princ "CA-REAL-TARGET-DURABLE-SOURCE-FAILED\n")
            (when hook-draft
              (let ((projected (copy-tree (supertag-node-get "source"))))
                (with-current-buffer source
                  (let ((after-save-hook
                         (list (lambda () (goto-char (point-max)) (insert "CA rejected draft\n")))))
                    (should-error (apply (plist-get payload :retry) (plist-get payload :retry-args))
                                  :type 'supertag-link-error)))
                (should (equal allowed (supertag-promote-test--disk (car files))))
                (should (equal projected (supertag-node-get "source")))
                (let ((facts (supertag-promote-test--facts files))
                      (source-state (plist-get state :source-state)))
                  (dotimes (_ 2)
                    (should-error (apply (plist-get payload :retry) (plist-get payload :retry-args))
                                  :type 'supertag-link-error)
                    (should (eq source-state (plist-get state :source-state)))
                    (should (equal facts (supertag-promote-test--facts files)))
                    (should-not (car operation))))
                (with-current-buffer source
                  (should (buffer-modified-p))
                  (should (string-suffix-p "CA rejected draft\n" (buffer-string)))
                  (delete-region (+ (point-min) (length allowed)) (point-max))
                  (should (equal allowed (buffer-string))))
                (princ "CA-AFTER-SAVE-GUARD-REAL-DISK-REJECTED\n")))
            (should (equal id (apply (plist-get payload :retry) (plist-get payload :retry-args))))
            (princ "CA-REAL-RETRY-COMPLETE\n")
            (should (eq operation (plist-get payload :recovery-operation)))
            (should (car operation)) (should (plist-get state :done))
            (dolist (key '(:pending-retry :source-state :target-guard :fresh-target-guard))
              (should-not (plist-get state key)))
            (should-not (marker-buffer begin)) (should-not (marker-buffer end))
            (should (> guard-calls 0))
            (should (equal inbound (supertag-promote-test--disk (nth 3 files))))
            (if (equal choice "1  Reuse")
                (progn
                  (should (equal id "retained"))
                  (should (equal (nth 2 files) (plist-get (supertag-node-get "child") :file)))
                  (should (string-match-p "Child body" (supertag-promote-test--disk (nth 2 files)))))
              (should (equal old (supertag-promote-test--disk (nth 1 files))))
              (should (string-match-p "Template body" (supertag-promote-test--disk (nth 2 files)))))
            (with-current-buffer source
              (should-not (buffer-modified-p))
              (should (equal allowed (supertag-promote-test--disk (car files))))
              (should (= 1 (how-many (regexp-quote (concat "[[id:" id "][Shared topic]]"))
                                      (point-min) (point-max)))))
            (should (member id (plist-get (supertag-node-get "source") :ref-to)))
            (let ((finished (supertag-promote-test--facts files)))
              (should (equal id (apply (plist-get payload :retry) (plist-get payload :retry-args))))
              (should (equal finished (supertag-promote-test--facts files)))))
        (advice-remove 'supertag-service-org-promote-check-source-stage guard)))))

(ert-deftest supertag-promote-ca-link-load-surface ()
  (supertag-promote-test--ca-child
   "link-surface" 'supertag-link
   '((should (featurep 'supertag-service-org))
     (dolist (feature '(supertag-concept supertag-services-sync
                       supertag-tag supertag-view-helper supertag-services-ui supertag-ui-commands))
       (should-not (featurep feature))
       (should-not (cl-find-if (lambda (row) (and (stringp (car row))
                                                 (equal (file-name-nondirectory (car row))
                                                        (concat (symbol-name feature) ".el")))) load-history)))
     (if (equal (getenv "SUPERTAG_LD_STAGE") "before")
         (should-not (boundp 'supertag-text-link--session-types))
       (should (boundp 'supertag-text-link--session-types))
       (should-not supertag-text-link--session-types))
     (should-not (bound-and-true-p global-supertag-ui-completion-mode))
     (dolist (symbol '(supertag-reference-promote--failure supertag-reference-promote--retry
                      supertag-reference-promote-continue))
       (if before (should (equal "supertag-link.el" (file-name-nondirectory (symbol-file symbol 'defun))))
         (should-not (fboundp symbol))))
     (dolist (symbol '(supertag-service-org--promote-check-retained-target
                      supertag-service-org-promote-call-source supertag-service-org-promote-check-source-stage
                      supertag-service-org-promote-source-state supertag-service-org-promote-target
                      supertag-service-org-promote-target-guard))
       (if before (should (autoloadp (symbol-function symbol))) (should-not (fboundp symbol))))
     (require 'supertag-concept)
     (if (equal (getenv "SUPERTAG_SYA_STAGE") "before")
         (should (featurep 'supertag-service-org))
       (should (featurep 'supertag-service-org)))
     (princ "CA-LINK-THEN-CONCEPT-REAL-CLOSURE\n"))))

(ert-deftest supertag-promote-ca-owner-entry ()
  (supertag-promote-test--ca-child
   "owner" 'supertag-concept
   '((dolist (symbol '(supertag-reference-promote--failure supertag-reference-promote--retry
                      supertag-reference-promote-continue))
       (should (equal "supertag-concept.el" (file-name-nondirectory (symbol-file symbol 'defun)))))
     (dolist (symbol '(supertag-service-org--promote-check-retained-target
                      supertag-service-org-promote-call-source supertag-service-org-promote-check-source-stage
                      supertag-service-org-promote-source-state supertag-service-org-promote-target
                      supertag-service-org-promote-target-guard))
       (should-not (autoloadp (symbol-function symbol)))
       (should (equal (if (or (equal (getenv "SUPERTAG_CB_STAGE") "before")
                                  (equal (getenv "SUPERTAG_CA_STAGE") "before"))
                           "supertag-service-org.el" "supertag-concept.el")
                       (file-name-nondirectory (symbol-file symbol 'defun)))))
     (princ (format "CA-REAL-CLOSURE sync=%S org-service=%S\n"
                    (featurep 'supertag-services-sync) (featurep 'supertag-service-org))))))

(ert-deftest supertag-promote-ca-reuse-original-payload ()
  (supertag-promote-test--ca-child "reuse" 'supertag-concept
    '((load test-file nil nil t) (supertag-promote-test--ca-recover "1  Reuse" nil))))
(ert-deftest supertag-promote-ca-fresh-original-payload ()
  (supertag-promote-test--ca-child "fresh" 'supertag-concept
    '((load test-file nil nil t) (supertag-promote-test--ca-recover "n  Create" nil))))
(ert-deftest supertag-promote-ca-hook-reuse-original-payload ()
  (supertag-promote-test--ca-child "hook-reuse" 'supertag-concept
    '((load test-file nil nil t) (supertag-promote-test--ca-recover "1  Reuse" t))))
(ert-deftest supertag-promote-ca-hook-fresh-original-payload ()
  (supertag-promote-test--ca-child "hook-fresh" 'supertag-concept
    '((load test-file nil nil t) (supertag-promote-test--ca-recover "n  Create" t))))

;;; CONCEPT-B: dedicated owner and real shared-writer boundaries.
(defun supertag-promote-test--cb-symbols ()
  '(supertag-service-org-promote-candidate supertag-service-org--promote-validate-candidate
    supertag-service-org--promote-release-candidates supertag-service-org--promote-text
    supertag-service-org-promote-target supertag-service-org--promote-retained-text
    supertag-service-org--promote-check-saved-buffer supertag-service-org--promote-check-retained-target
    supertag-service-org--promote-check-old-location supertag-service-org-promote-target-guard
    supertag-service-org-promote-source-state supertag-service-org-promote-check-source-stage
    supertag-service-org-promote-call-source supertag-service-org-retry-promote-target))

(defun supertag-promote-test--cb-target ()
  "Run one real nested reuse and old-location-save recovery, tracing native calls."
  (supertag-promote-test--isolated
    (let* ((files (supertag-promote-test--four-files tmp))
           (old (nth 1 files)) (real-save (symbol-function 'save-buffer))
           (inbound (supertag-promote-test--disk (nth 3 files)))
           (trace (make-hash-table :test 'eq)) advices payload outer target-state operation markers)
      (with-current-buffer (find-file-noselect old)
        (erase-buffer)
        (insert "* Container\nKeep parent\n** Shared topic :existing:\n:PROPERTIES:\n:ID: retained\n:STAGE: established\n:SUPERTAG_CONCEPT: t\n:END:\nExisting body\n*** Child\n:PROPERTIES:\n:ID: child\n:END:\nChild body\n")
        (save-buffer)
        (org-map-entries (lambda () (when (org-entry-get nil "ID") (supertag-node-sync-at-point))) nil 'file))
      (unwind-protect
          (progn
            (dolist (symbol '(supertag-service-org--move-root supertag-service-org--move-snapshot
                              supertag-service-org--move-disk-text supertag-service-org--move-save
                              supertag-service-org--retry-move-projection supertag-service-org--move-notify-git
                              supertag-service-org--adjust-subtree-level supertag-service-org--validate-create-content
                              supertag-service-org--preflight-create supertag--strip-inline-tags supertag--render-org-headline))
              (should-not (autoloadp (symbol-function symbol)))
              (should (equal (if (memq symbol '(supertag--strip-inline-tags supertag--render-org-headline))
                                 "supertag-services-sync.el" "supertag-service-org.el")
                             (file-name-nondirectory (symbol-file symbol 'defun))))
              (let ((advice (lambda (original &rest args)
                              (prog1 (apply original args)
                                (puthash symbol (1+ (gethash symbol trace 0)) trace)
                                (princ (format "CB-RETURN %s argc=%s\n" symbol (length args)))))))
                (push (cons symbol advice) advices)
                (advice-add symbol :around advice)))
            (supertag-promote-test--select-source (car files))
            (cl-letf (((symbol-function 'save-buffer)
                       (lambda (&rest args)
                         (if (equal buffer-file-name old) (error "CB old-location save fault")
                           (apply real-save args)))))
              (supertag-promote-test--choices "1  Reuse"
                (condition-case err (call-interactively #'supertag-promote)
                  (supertag-link-error (setq payload (cdr err))))))
            (should (eq :old-location-save (plist-get payload :stage)))
            (setq operation (plist-get payload :recovery-operation)
                  outer (car (aref (car (plist-get payload :retry-args)) 1))
                  target-state (car (plist-get (cadr (aref (car (plist-get payload :retry-args)) 1)) :retry-args))
                  markers (mapcar (lambda (key) (plist-get target-state key))
                                  '(:begin :end :target-begin :target-end)))
            (should (eq :old-location-save (plist-get target-state :stage)))
            (should (string-match-p "Existing body" (supertag-promote-test--disk (nth 2 files))))
            (should (string-match-p "Child body" (supertag-promote-test--disk (nth 2 files))))
            (should (string-match-p "Existing body" (supertag-promote-test--disk old)))
            (should-not (car operation))
            (princ "CB-TARGET-DURABLE-OLD-SAVE-FAILED\n")
            (let ((id (apply (plist-get payload :retry) (plist-get payload :retry-args))))
              (princ "CB-REAL-PUBLIC-RETRY-RETURNED\n")
              (should (equal id "retained"))
              (should (eq operation (plist-get payload :recovery-operation)))
              (should (car operation)) (should (plist-get outer :done))
              (should (eq :done (plist-get target-state :stage)))
              (dolist (marker markers) (should-not (marker-buffer marker)))
              (should-not (plist-get outer :pending-retry))
              (should (equal inbound (supertag-promote-test--disk (nth 3 files))))
              (should (equal "* Container\nKeep parent\n[[id:retained][Shared topic]]\n"
                             (supertag-promote-test--disk old)))
              (with-current-buffer (find-file-noselect (nth 2 files))
                (goto-char (supertag-node-location-find "retained"))
                (should (= 1 (org-outline-level)))
                (should (equal "established" (org-entry-get nil "STAGE")))
                (should (member "existing" (org-get-tags nil t)))
                (should (member "concept" (org-get-tags nil t)))
                (goto-char (supertag-node-location-find "child"))
                (should (= 2 (org-outline-level))))
              (dolist (id '("retained" "child"))
                (should (equal (nth 2 files) (plist-get (supertag-node-get id) :file))))
              (should (member "retained" (plist-get (supertag-node-get "source") :ref-to)))
              (with-temp-buffer
                (insert-file-contents (car files))
                (should (= 1 (how-many (regexp-quote "[[id:retained][Shared topic]]") (point-min) (point-max)))))
              (let ((facts (supertag-promote-test--facts files)))
                (should (equal id (apply (plist-get payload :retry) (plist-get payload :retry-args))))
                (should (equal facts (supertag-promote-test--facts files)))))
            (dolist (pair advices) (should (> (gethash (car pair) trace 0) 0)))
            (princ (format "CB-NATIVE-SHARED-RETURNS %S\n" trace)))
        (dolist (pair advices) (advice-remove (car pair) (cdr pair)))))))

(ert-deftest supertag-promote-cb-service-entry ()
  (let ((symbols (supertag-promote-test--cb-symbols)))
    (supertag-promote-test--ca-child
     "cb-service" 'supertag-service-org
     `((should-not (featurep 'supertag-concept))
       (should-not (cl-find-if (lambda (row) (and (stringp (car row))
                                                 (equal "supertag-concept.el" (file-name-nondirectory (car row))))) load-history))
       (let ((cb-before (equal (getenv "SUPERTAG_CB_STAGE") "before")))
         (dolist (symbol ',symbols)
           (if cb-before
               (should (equal "supertag-service-org.el" (file-name-nondirectory (symbol-file symbol 'defun))))
             (should-not (fboundp symbol))))
         (if cb-before (should (equal '(supertag-promote-error error) (get 'supertag-promote-error 'error-conditions)))
           (should-not (get 'supertag-promote-error 'error-conditions))))
       (require 'supertag-concept)
       (dolist (symbol ',symbols)
         (should (equal (if (equal (getenv "SUPERTAG_CB_STAGE") "before") "supertag-service-org.el" "supertag-concept.el")
                        (file-name-nondirectory (symbol-file symbol 'defun)))))
       (should (equal '(supertag-promote-error error) (get 'supertag-promote-error 'error-conditions)))
       (should (equal "Promote retained document state; retry the reported stage" (get 'supertag-promote-error 'error-message)))))))

(ert-deftest supertag-promote-cb-owner-entry ()
  (let ((symbols (supertag-promote-test--cb-symbols)))
    (supertag-promote-test--ca-child
     "cb-owner" 'supertag-concept
     `((dolist (symbol ',symbols)
         (should (equal "supertag-concept.el" (file-name-nondirectory (symbol-file symbol 'defun)))))
       (should (equal '(supertag-promote-error error) (get 'supertag-promote-error 'error-conditions)))
       (should (equal "Promote retained document state; retry the reported stage" (get 'supertag-promote-error 'error-message)))
       (if (equal (getenv "SUPERTAG_SYA_STAGE") "before")
           (should (featurep 'supertag-service-org))
         (should (featurep 'supertag-service-org))) (should (featurep 'supertag-services-sync))))))

(ert-deftest supertag-promote-cb-public-target-recovery ()
  (supertag-promote-test--ca-child "cb-target" 'supertag-concept
    '((load test-file nil nil t) (supertag-promote-test--cb-target))))

(ert-deftest supertag-promote-cb-native-reload-advice ()
  (supertag-promote-test--ca-child
   "cb-advice" 'supertag-concept
   '((load test-file nil nil t)
     (supertag-promote-test--isolated
       (let* ((files (supertag-promote-test--four-files tmp))
              (symbols '(supertag-service-org--promote-check-retained-target supertag-service-org-promote-call-source
                         supertag-service-org-promote-check-source-stage supertag-service-org-promote-source-state
                         supertag-service-org-promote-target supertag-service-org-promote-target-guard))
              (guard-state (supertag-service-org-promote-target-guard "retained"))
              (source-state (with-current-buffer (find-file-noselect (car files))
                              (supertag-service-org-promote-source-state (point-marker))))
              (phase 'before-reload) (counts (make-hash-table :test 'eq))
              (advice (lambda (&rest _) (puthash phase (1+ (gethash phase counts 0)) counts)))
              first second)
         (advice-add 'supertag-service-org-promote-check-source-stage :before advice)
         (unwind-protect
             (let ((cells (mapcar #'symbol-function symbols)))
               (setq first (supertag-service-org-promote-check-source-stage guard-state source-state t))
               (should (= 1 (gethash 'before-reload counts 0)))
               (require 'supertag-concept)
               (cl-mapc (lambda (s f) (should (eq f (symbol-function s)))) symbols cells)
               (load (locate-library "supertag-concept.el") nil nil t)
               (if (equal (getenv "SUPERTAG_CB_STAGE") "before")
                   (cl-mapc (lambda (s f) (should (eq f (symbol-function s)))) symbols cells)
                 (princ (format "CB-ACTUAL-RELOAD-EQ=%S\n"
                                (cl-mapcar (lambda (s f) (eq f (symbol-function s))) symbols cells))))
               (should (advice-member-p advice 'supertag-service-org-promote-check-source-stage))
               (setq phase 'after-reload
                     second (supertag-service-org-promote-check-source-stage guard-state source-state t))
               (should (equal first second))
               (should (= 1 (gethash 'after-reload counts 0)))
               (princ (format "CB-NATIVE-GUARD-PRE-POST=%S/%S output=%S\n"
                              (gethash 'before-reload counts) (gethash 'after-reload counts) second)))
           (advice-remove 'supertag-service-org-promote-check-source-stage advice)))))))


(defun supertag-promote-test--many-heading-text (title-prefix id-prefix count)
  "Return Org text with COUNT ID-bearing headings.
Titles start with TITLE-PREFIX, IDs with ID-PREFIX (kept lowercase)."
  (mapconcat (lambda (index)
               (format "* %s %d\n:PROPERTIES:\n:ID: %s-%d\n:END:\nBody %d\n"
                       title-prefix index id-prefix index index))
             (number-sequence 1 count) ""))

(ert-deftest supertag-promote-retry-move-projection-parses-each-file-once ()
  "Reprojecting many headings costs one whole-file parse per file.

The Promote/Move projection step used to reproject each ID-bearing heading
through `supertag--parse-node-at-point', which parses the whole file per
heading -- quadratic in file size.  Count whole-file parses instead of
wall-clock time, so the regression trips no matter how fast the machine is."
  (supertag-promote-test--isolated
    (let* ((many (expand-file-name "many.org" tmp))
           (few (expand-file-name "few.org" tmp))
           (many-text (supertag-promote-test--many-heading-text "Many" "many" 60))
           (few-text (concat (supertag-promote-test--many-heading-text "Few" "few" 1)
                             "* Few two\n:PROPERTIES:\n:ID: few-2\n:END:\nBody\n"))
           (real-parse (symbol-function 'supertag--parse-org-nodes-from-current-buffer))
           (parses 0))
      (with-temp-file many (insert many-text))
      (with-temp-file few (insert few-text))
      ;; Seed the same 62 heading identities without paying one parse each.
      (dolist (spec (list (list many "many" 60) (list few "few" 1)))
        (dotimes (index (nth 2 spec))
          (let ((id (format "%s-%d" (nth 1 spec) (1+ index))))
            (supertag-store-put-entity
             :nodes id
             (list :id id :level 1 :file (file-truename (nth 0 spec))
                   :title "seed" :content "")
             t))))
      (with-current-buffer (find-file-noselect many)
        (goto-char (point-min))
        (search-forward "* Many 1")
        (replace-match "* Many One"))
      (cl-letf (((symbol-function 'supertag--parse-org-nodes-from-current-buffer)
                 (lambda (file &optional migration-mode)
                   (setq parses (1+ parses))
                   (funcall real-parse file migration-mode))))
        (supertag-service-org--retry-move-projection few many)
        ;; Two files, sixty-two headings: two parses.
        (should (= 2 parses))
        ;; The heading edit really was reprojected, not skipped for speed.
        (should (equal "Many One"
                       (or (plist-get (supertag-node-get "many-1") :raw-value)
                           (plist-get (supertag-node-get "many-1") :title))))
        (should (equal "Few two"
                       (or (plist-get (supertag-node-get "few-2") :raw-value)
                           (plist-get (supertag-node-get "few-2") :title))))))))
