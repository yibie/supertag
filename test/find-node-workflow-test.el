;;; find-node-workflow-test.el --- Unified Find Node workflow -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'org)
(when load-file-name
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))
(require 'supertag-core-store)
(require 'supertag-service-org)
(require 'supertag-service-org)
(progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener))
(if (equal (getenv "SUPERTAG_SYA_STAGE") "before")
      (require 'supertag-ui-commands)
    (require 'supertag-node))

(defvar ivy-mode)

(defmacro supertag-find-node-test--isolated (&rest body)
  "Run BODY with an isolated Store, Org identity and temporary files."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "supertag-find-node-test-" t))
          (supertag-data-directory tmp)
          (supertag-db-file (expand-file-name "db.el" tmp))
          (supertag-db-backup-directory (expand-file-name "backup" tmp))
          (supertag-sync-directories (list tmp))
          (supertag-sync-directories-mode 'unified)
          (supertag--store nil) (supertag--store-origin nil)
          (supertag-ui--node-cache nil) (supertag-ui--cache-timestamp nil)
          (org-id-locations nil) (org-id-files nil)
          (org-id-locations-file (expand-file-name "org-id" tmp)))
     (unwind-protect
         (progn (supertag--ensure-store) ,@body)
       (dolist (buffer (buffer-list))
         (when-let ((file (buffer-file-name buffer)))
           (when (string-prefix-p tmp file) (kill-buffer buffer))))
       (ignore-errors (delete-directory tmp t)))))

(defun supertag-find-node-test--write-node (file id title)
  "Write and project one identified node to FILE."
  (with-temp-file file
    (insert (format "* %s\n:PROPERTIES:\n:ID: %s\n:END:\n" title id)))
  (with-current-buffer (find-file-noselect file)
    (org-mode)
    (goto-char (point-min))
    (supertag-node-sync-at-point)))

(defun supertag-find-node-test--read (text)
  "Use the real Find reader's completion collection for entered TEXT."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt collection predicate require-match &rest _)
               (should require-match)
               (let ((matches (all-completions text collection predicate)))
                 (unless (= 1 (length matches))
                   (user-error "Selection is ambiguous"))
                 (car matches)))))
    (supertag-ui-read-find-node "Find node: " nil)))

(defun supertag-find-node-test--window-layout ()
  "Return observable state for every live window on the selected frame."
  (mapcar (lambda (window)
            (list (eq window (selected-window))
                  (window-edges window)
                  (window-buffer window)
                  (window-point window)
                  (window-start window)
                  (window-hscroll window)
                  (copy-tree (window-prev-buffers window))
                  (copy-sequence (window-next-buffers window))))
          (window-list nil 'no-minibuffer)))

(ert-deftest supertag-find-node-reader-distinguishes-existing-and-explicit-new ()
  (supertag-find-node-test--isolated
    (let ((file (expand-file-name "existing.org" tmp)))
      (supertag-find-node-test--write-node file "existing-id" "Existing")
      (let* ((candidate (car (supertag-ui--get-cached-nodes)))
             (existing (supertag-find-node-test--read (car candidate)))
             (created (supertag-find-node-test--read "Fresh")))
        (should (equal '(:existing "existing-id") existing))
        (should (equal '(:create "Fresh") created))))))

(ert-deftest supertag-find-node-reader-requires-explicit-create-candidate ()
  (let* ((table (supertag-ui--find-completion-table nil))
         (create (car (all-completions "Fresh" table))))
    (should-not (funcall table "Fresh" nil 'lambda))
    (should (equal "Fresh  [Create new node]" create))
    (should (test-completion create table))))

(ert-deftest supertag-find-node-command-prompts-with-active-window-mode ()
  (let (calls)
    (cl-letf (((symbol-function 'supertag-ui-read-find-node)
               (lambda (prompt preview)
                 (push (list prompt preview) calls)
                 nil)))
      (should-not (supertag-find-node nil))
      (should-not (supertag-find-node '(4))))
    (setq calls (nreverse calls))
    (should (string-match-p "current window.*C-u" (caar calls)))
    (should-not (cadar calls))
    (should (string-match-p "other window.*without C-u" (caadr calls)))
    (should (cadadr calls))))

(ert-deftest supertag-find-node-reader-does-not-authorize-raw-or-ambiguous-input ()
  (should (fboundp 'supertag-ui-read-find-node))
  (supertag-find-node-test--isolated
    (let ((one (expand-file-name "one.org" tmp))
          (two (expand-file-name "two.org" tmp)))
      (supertag-find-node-test--write-node one "one" "Shared")
      (supertag-find-node-test--write-node two "two" "Shared")
      (should-error (supertag-find-node-test--read "Shared"))
      (should-not (file-exists-p (expand-file-name "concepts.org" tmp))))))

(ert-deftest supertag-find-node-command-opens-existing-and-preserves-native-return ()
  (supertag-find-node-test--isolated
    (let ((first (expand-file-name "first.org" tmp))
          (second (expand-file-name "second.org" tmp)))
      (supertag-find-node-test--write-node first "first" "First")
      (supertag-find-node-test--write-node second "second" "Second")
      (save-window-excursion
        (let ((choices '((:existing "first") (:existing "second"))))
          (cl-letf (((symbol-function 'supertag-ui-read-find-node)
                     (lambda (&rest _) (pop choices))))
            (should (equal "Jumped to node: First" (supertag-find-node nil)))
            (should (equal first (buffer-file-name)))
            (should (equal "Jumped to node: Second" (supertag-find-node nil)))
            (should (equal second (buffer-file-name)))
            (previous-buffer)
            (should (equal first (buffer-file-name)))))))))

(ert-deftest supertag-find-node-prefix-opens-existing-in-other-window ()
  (supertag-find-node-test--isolated
    (let ((file (expand-file-name "target.org" tmp)))
      (supertag-find-node-test--write-node file "target" "Target")
      (save-window-excursion
        (switch-to-buffer (get-buffer-create " *find source*"))
        (let ((source-window (selected-window)))
          (cl-letf (((symbol-function 'supertag-ui-read-find-node)
                     (lambda (&rest _) '(:existing "target"))))
            (should (equal "Jumped to node: Target" (supertag-find-node '(4))))
            (should-not (eq source-window (selected-window)))
            (should (equal file (buffer-file-name)))))))))

(ert-deftest supertag-find-node-successful-preview-restores-before-final-jump ()
  (supertag-find-node-test--isolated
    (let ((file (expand-file-name "target.org" tmp))
          (source (get-buffer-create " *find return source*"))
          (side (get-buffer-create " *find return side*"))
          (ivy-mode t)
          current-match)
      (supertag-find-node-test--write-node file "target" "Target")
      (save-window-excursion
        (switch-to-buffer source)
        (let ((source-window (selected-window))
              (side-window (split-window-right)))
          (select-window side-window)
          (switch-to-buffer side)
          (select-window source-window))
        (let ((before-layout (supertag-find-node-test--window-layout)))
          (cl-letf (((symbol-function 'ivy-current-match)
                     (lambda () current-match))
                    ((symbol-function 'ivy-read)
                     (lambda (_prompt collection &rest args)
                       (setq current-match
                             (car (all-completions "Target" collection)))
                       (funcall (plist-get args :update-fn))
                       current-match)))
            (should (equal '(:existing "target")
                           (supertag-ui-read-find-node "Find node: " t))))
          (should (eq source (current-buffer)))
          (should (equal before-layout
                         (supertag-find-node-test--window-layout))))))))

(ert-deftest supertag-find-node-explicit-new-uses-complete-template-without-source-write ()
  (supertag-find-node-test--isolated
    (let* ((target (expand-file-name "concepts.org" tmp))
           (source (get-buffer-create " *find unchanged source*"))
           (before "Unchanged source text"))
      (with-current-buffer source (erase-buffer) (insert before))
      (save-window-excursion
        (switch-to-buffer source)
        (cl-letf (((symbol-function 'supertag-ui-read-find-node)
                   (lambda (&rest _) '(:create "Fresh")))
                  ((symbol-function 'supertag-template-read)
                   (lambda () (list :key "p" :name "Project"
                                    :target-file target :tags '("project")
                                    :properties '(("STAGE" . "ready"))
                                    :body "Intro.\n\n** Child\nChild body."))))
          (let ((result (supertag-find-node nil)))
            (should (string-prefix-p "Jumped to node: Fresh" result))
            (should (equal target (buffer-file-name)))
            (with-current-buffer source
              (should (equal before (buffer-string)))))))
      (with-temp-buffer
        (insert-file-contents target)
        (should (re-search-forward "^\\* Fresh #project$" nil t))
        (should (re-search-forward "^:STAGE:[ \t]+ready$" nil t))
        (should (re-search-forward "^\\*\\* Child$" nil t))
        (should (= 1 (how-many "^:ID:" (point-min) (point-max))))))))

(ert-deftest supertag-find-node-public-reader-template-and-writer-chain ()
  (supertag-find-node-test--isolated
    (let* ((target (expand-file-name "concepts.org" tmp))
           (supertag-creation-templates
           `((:key "c" :name "Concept" :target-file ,target
              :tags ("concept") :properties (("STATE" . "new"))
              :body "Created through the public chain."))))
      (save-window-excursion
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt collection predicate require-match &rest _)
                     (should require-match)
                     (cond
                      ((string-prefix-p "Find node" prompt)
                       (let ((selected
                              (car (all-completions
                                    "Fresh" collection predicate))))
                         (should (test-completion
                                  selected collection predicate))
                         selected))
                      ((string-prefix-p "Creation template" prompt)
                       (car (all-completions "" collection predicate)))
                      (t (ert-fail (format "Unexpected prompt: %s" prompt)))))))
          (should (equal "Jumped to node: Fresh" (supertag-find-node nil)))
          (should (equal target (buffer-file-name)))))
      (with-temp-buffer
        (insert-file-contents target)
        (should (re-search-forward "^\\* Fresh #concept$" nil t))
        (should (re-search-forward "^:STATE:[ \t]+new$" nil t))
        (should (search-forward "Created through the public chain." nil t))))))

(ert-deftest supertag-find-node-navigation-failure-restores-complete-context ()
  (supertag-find-node-test--isolated
    (let ((stale-file (expand-file-name "stale.org" tmp))
          (source (get-buffer-create " *find failure source*")))
      (with-temp-file stale-file (insert "* Different\n"))
      (supertag-store-put-entity
       :nodes "stale-id"
       `(:id "stale-id" :title "Stale" :raw-value "Stale"
         :file ,stale-file :level 1 :position 1))
      (save-window-excursion
        (switch-to-buffer source)
        (erase-buffer) (insert "0123456789")
        (goto-char 6) (set-mark 8) (narrow-to-region 3 10)
        (set-window-start (selected-window) (point-min))
        (let ((before-layout (supertag-find-node-test--window-layout))
              (before-context (list (current-buffer) (point) (mark)
                                    (point-min) (point-max))))
          (cl-letf (((symbol-function 'supertag-ui-read-find-node)
                     (lambda (&rest _) '(:existing "stale-id"))))
            (should (stringp (supertag-find-node nil))))
          (should (equal before-context
                         (list (current-buffer) (point) (mark)
                               (point-min) (point-max))))
          (should (equal before-layout
                         (supertag-find-node-test--window-layout))))))))

(ert-deftest supertag-find-node-navigation-exception-restores-complete-context ()
  (supertag-find-node-test--isolated
    (let ((file (expand-file-name "target.org" tmp))
          (source (get-buffer-create " *find exception source*")) caught)
      (supertag-find-node-test--write-node file "target" "Target")
      (save-window-excursion
        (switch-to-buffer source)
        (erase-buffer) (insert "0123456789")
        (goto-char 5) (set-mark 7) (narrow-to-region 2 9)
        (set-window-start (selected-window) (point-min))
        (let ((before-layout (supertag-find-node-test--window-layout))
              (before-context (list (current-buffer) (point) (mark)
                                    (point-min) (point-max))))
          (cl-letf (((symbol-function 'supertag-ui-read-find-node)
                     (lambda (&rest _) '(:existing "target")))
                    ((symbol-function 'supertag-node--goto-location)
                     (lambda (&rest _) (error "navigation failed"))))
            (condition-case data
                (supertag-find-node nil)
              (error (setq caught data))))
          (should (equal '(error "navigation failed") caught))
          (should (equal before-context
                         (list (current-buffer) (point) (mark)
                               (point-min) (point-max))))
          (should (equal before-layout
                         (supertag-find-node-test--window-layout))))))))

(ert-deftest supertag-find-node-public-prefix-preview-and-consecutive-native-return ()
  (supertag-find-node-test--isolated
    (let ((alpha (expand-file-name "alpha.org" tmp))
          (beta (expand-file-name "beta.org" tmp))
          (gamma (expand-file-name "gamma.org" tmp))
          (source (get-buffer-create " *find combined origin*"))
          (side (get-buffer-create " *find combined side*"))
          (ivy-mode t) current-match
          (default-inputs '("Alpha" "Gamma")))
      (supertag-find-node-test--write-node alpha "alpha" "Alpha")
      (supertag-find-node-test--write-node beta "beta" "Beta")
      (supertag-find-node-test--write-node gamma "gamma" "Gamma")
      (save-window-excursion
        (switch-to-buffer source)
        (erase-buffer) (insert "origin text")
        (goto-char 5) (set-mark 9) (narrow-to-region 3 11)
        (let ((source-window (selected-window))
              (side-window (split-window-right)))
          (set-window-buffer side-window side)
          (cl-letf (((symbol-function 'ivy-current-match)
                     (lambda () current-match))
                    ((symbol-function 'ivy-read)
                     (lambda (_prompt collection &rest args)
                       (setq current-match
                             (car (all-completions "Beta" collection)))
                       (let ((preview-match
                              (car (all-completions "Alpha" collection))))
                         (setq current-match preview-match)
                         (funcall (plist-get args :update-fn)))
                       (setq current-match
                             (car (all-completions "Beta" collection)))
                       (funcall (plist-get args :update-fn))
                       current-match))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt collection predicate require-match &rest _)
                       (should require-match)
                       (let* ((input (pop default-inputs))
                              (selected
                               (car (all-completions
                                     input collection predicate))))
                         (should (test-completion
                                  selected collection predicate))
                         selected))))
            (should (equal "Jumped to node: Beta"
                           (supertag-find-node '(4))))
            (should (equal "Jumped to node: Alpha"
                           (supertag-find-node nil)))
            (should (equal "Jumped to node: Gamma"
                           (supertag-find-node nil))))
          (previous-buffer)
          (should (equal alpha (buffer-file-name)))
          (previous-buffer)
          (should (equal beta (buffer-file-name)))
          ;; Prefix Find deliberately leaves the origin visible in its window;
          ;; the native window command returns there without a Supertag stack.
          (other-window 1)
          (should (eq source (current-buffer)))
          (should (equal (list source 5 9 3 11)
                         (list (current-buffer) (point) (mark)
                               (point-min) (point-max)))))))))

(ert-deftest supertag-find-node-refreshes-warm-candidates-after-create ()
  (supertag-find-node-test--isolated
    (let ((alpha-file (expand-file-name "alpha.org" tmp))
          (target (expand-file-name "concepts.org" tmp))
          (find-inputs '("Alpha" "Fresh" "Fresh"))
          (supertag-creation-templates nil)
          third-selection)
      (supertag-find-node-test--write-node alpha-file "alpha" "Alpha")
      (setq supertag-creation-templates
            `((:key "c" :name "Concept" :target-file ,target
               :tags nil :properties nil :body "")))
      (save-window-excursion
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt collection predicate require-match &rest _)
                     (should require-match)
                     (if (string-prefix-p "Creation template" prompt)
                         (car (all-completions "" collection predicate))
                       (let* ((input (pop find-inputs))
                              (matches (all-completions
                                        input collection predicate))
                              (selected (car matches)))
                         (when (null find-inputs)
                           (setq third-selection selected)
                           (should-not
                            (string-match-p "Create new node" selected)))
                         (should (test-completion
                                  selected collection predicate))
                         selected)))))
          (supertag-find-node nil)
          (should supertag-ui--node-cache)
          (supertag-find-node nil)
          (supertag-find-node nil)))
      (should third-selection)
      (should (= 1
                 (cl-count-if
                  (lambda (pair)
                    (equal "Fresh" (plist-get (cdr pair) :raw-value)))
                  (supertag-query-nodes (lambda (_id node) node))))))))

(ert-deftest supertag-find-node-refreshes-warm-candidates-after-create-retry ()
  (supertag-find-node-test--isolated
    (let ((alpha-file (expand-file-name "alpha.org" tmp))
          (target (expand-file-name "concepts.org" tmp))
          (real-save (symbol-function 'save-buffer))
          (fail t) payload)
      (supertag-find-node-test--write-node alpha-file "alpha" "Alpha")
      (should (equal '(:existing "alpha")
                     (supertag-find-node-test--read "Alpha")))
      (should supertag-ui--node-cache)
      (cl-letf (((symbol-function 'supertag-ui-read-find-node)
                 (lambda (&rest _) '(:create "Retry")))
                ((symbol-function 'supertag-template-read)
                 (lambda () (list :key "c" :name "Concept"
                                  :target-file target :tags nil
                                  :properties nil :body "Draft")))
                ((symbol-function 'supertag-node-identity-new)
                 (lambda () "retry-id"))
                ((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (if fail
                       (progn (setq fail nil) (error "save failed"))
                     (apply real-save args)))))
        (condition-case data
            (supertag-find-node nil)
          (supertag-document-save-error (setq payload (cdr data)))))
      (should (equal "retry-id"
                     (apply (plist-get payload :retry)
                            (plist-get payload :retry-args))))
      (should (equal '(:existing "retry-id")
                     (supertag-find-node-test--read "Retry"))))))

(ert-deftest supertag-find-node-cancellation-and-preview-error-restore-context ()
  (supertag-find-node-test--isolated
    (let ((source (get-buffer-create " *find preview source*"))
          (preview (get-buffer-create " *find preview target*")))
      (save-window-excursion
        (switch-to-buffer source)
        (insert "0123456789")
        (goto-char 6)
        (narrow-to-region 3 9)
        (let ((before (list (current-buffer) (point) (point-min) (point-max))))
          (should-error
           (supertag-ui--with-find-preview-context
             (switch-to-buffer-other-window preview)
             (error "cancelled")))
          (should (equal before
                         (list (current-buffer) (point)
                               (point-min) (point-max)))))))))

(ert-deftest supertag-find-node-real-reader-preview-cancel-restores-source ()
  (supertag-find-node-test--isolated
    (let ((file (expand-file-name "target.org" tmp))
          (source (get-buffer-create " *find real preview source*")))
      (supertag-find-node-test--write-node file "target" "Target")
      (save-window-excursion
        (switch-to-buffer source)
        (erase-buffer) (insert "source") (goto-char 4)
        (set-mark 6)
        (narrow-to-region 2 7)
        ;; Make the observable window start consistent with the narrowing;
        ;; otherwise batch Emacs retains a stale pre-redisplay start at 1.
        (set-window-start (selected-window) (point-min))
        (let ((side (get-buffer-create " *find preserved side*")))
          (with-current-buffer side
            (erase-buffer) (insert "side window contents") (goto-char 8))
          (set-window-buffer (split-window-right) side)
          (let ((before-layout (supertag-find-node-test--window-layout))
              (before-context (list (current-buffer) (point) (mark)
                                    (point-min) (point-max)))
              (ivy-mode t)
              current-match caught)
            (cl-letf (((symbol-function 'ivy-current-match)
                       (lambda () current-match))
                      ((symbol-function 'ivy-read)
                       (lambda (_prompt collection &rest args)
                         (setq current-match
                               (car (all-completions "Target" collection)))
                         (funcall (plist-get args :update-fn))
                         (signal 'quit nil))))
              (condition-case nil
                  (supertag-ui-read-find-node "Find node: " t)
                (quit (setq caught t))))
            (should caught)
            (should (equal before-context
                           (list (current-buffer) (point) (mark)
                                 (point-min) (point-max))))
            (should (equal before-layout
                           (supertag-find-node-test--window-layout)))))))))

(ert-deftest supertag-find-node-cancel-and-template-cancel-write-nothing ()
  (supertag-find-node-test--isolated
    (let ((target (expand-file-name "concepts.org" tmp)))
      (cl-letf (((symbol-function 'supertag-ui-read-find-node)
                 (lambda (&rest _) nil)))
        (should-not (supertag-find-node nil)))
      (cl-letf (((symbol-function 'supertag-ui-read-find-node)
                 (lambda (&rest _) '(:create "Fresh")))
                ((symbol-function 'supertag-template-read)
                 (lambda () (user-error "cancelled"))))
        (should-error (supertag-find-node nil) :type 'user-error))
      (should-not (file-exists-p target)))))

(ert-deftest supertag-find-node-create-save-error-retains-one-id-and-retries ()
  (supertag-find-node-test--isolated
    (let ((target (expand-file-name "concepts.org" tmp)) payload (fail t)
          (real-save (symbol-function 'save-buffer)))
      (cl-letf (((symbol-function 'supertag-ui-read-find-node)
                 (lambda (&rest _) '(:create "Retry")))
                ((symbol-function 'supertag-template-read)
                 (lambda () (list :key "c" :name "Concept"
                                  :target-file target :tags nil
                                  :properties nil :body "Draft")))
                ((symbol-function 'supertag-node-identity-new)
                 (lambda () "retained-id"))
                ((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (if fail
                       (progn (setq fail nil) (error "save failed"))
                     (apply real-save args)))))
        (condition-case data
            (supertag-find-node nil)
          (supertag-document-save-error (setq payload (cdr data))))
        (should (equal "retained-id" (plist-get payload :node-id)))
        (should-not (supertag-node-get "retained-id"))
        (should (equal "retained-id"
                       (apply (plist-get payload :retry)
                              (plist-get payload :retry-args)))))
      (with-temp-buffer
        (insert-file-contents target)
        (should (= 1 (how-many "^:ID:[ \t]+retained-id$"
                               (point-min) (point-max))))))))

(ert-deftest supertag-find-node-create-projection-error-retains-durable-node ()
  (supertag-find-node-test--isolated
    (let ((target (expand-file-name "concepts.org" tmp)) payload (fail t)
          (source (get-buffer-create " *find projection source*"))
          (real-project
           (symbol-function 'supertag-service-org--project-current-node)))
      (save-window-excursion
        (switch-to-buffer source)
        (cl-letf (((symbol-function 'supertag-ui-read-find-node)
                   (lambda (&rest _) '(:create "Durable")))
                  ((symbol-function 'supertag-template-read)
                   (lambda () (list :key "c" :name "Concept"
                                    :target-file target :tags nil
                                    :properties nil :body "Body")))
                  ((symbol-function 'supertag-node-identity-new)
                   (lambda () "durable-id"))
                  ((symbol-function 'supertag-service-org--project-current-node)
                   (lambda (id)
                     (if fail
                         (progn (setq fail nil) (error "projection failed"))
                       (funcall real-project id)))))
          (condition-case data
              (supertag-find-node nil)
            (supertag-projection-error (setq payload (cdr data))))
          (should (eq source (current-buffer)))
          (should (equal "durable-id" (plist-get payload :node-id)))
          (should-not (supertag-node-get "durable-id"))
          (with-temp-buffer
            (insert-file-contents target)
            (should (= 1 (how-many "^:ID:[ \t]+durable-id$"
                                   (point-min) (point-max)))))
          (should (equal "durable-id"
                         (plist-get
                          (apply (plist-get payload :retry)
                                 (plist-get payload :retry-args))
                          :id)))
          (should (supertag-node-get "durable-id")))))))

(ert-deftest supertag-find-node-retires-separate-other-window-command ()
  (should (commandp 'supertag-find-node))
  (should-not (commandp 'supertag-find-node-other-window)))

(provide 'find-node-workflow-test)
;;; find-node-workflow-test.el ends here

;;; NODE-C retained candidate/cache and actual preview failure controls.
(defvar vertico-mode)
(defvar vertico-selection-hook)

(ert-deftest supertag-find-node-candidate-format-query-and-first-association ()
  (supertag-find-node-test--isolated
    (dolist (props `((:id "raw" :title "Ignored" :raw-value "Raw" :olp ("Parent" "Raw") :file ,(expand-file-name "a.org" tmp))
                     (:id "file" :level 0 :file ,(expand-file-name "notes.org" tmp))
                     (:id "empty" :title "") (:id "nil" :title nil)
                     (:id "same1" :title "Same") (:id "same2" :title "Same")))
      (supertag-node-create props))
    (let* ((facts (prin1-to-string (supertag-store-get-collection :nodes)))
           (candidates (supertag-ui--build-node-candidates)))
      (should (equal '("Parent / Raw  (in a.org)" . "raw") (rassoc "raw" candidates)))
      (should (equal '("📄 notes.org  (in notes.org)" . "file") (rassoc "file" candidates)))
      (should (equal '("  [orphaned]" . "empty") (rassoc "empty" candidates)))
      (should (equal '("Untitled  [orphaned]" . "nil") (rassoc "nil" candidates)))
      (should (equal (mapcar #'car candidates) (sort (mapcar #'car candidates) #'string<)))
      (should (equal '(:existing "same1") (supertag-ui--find-choice-value "Same  [orphaned]" candidates)))
      (should (equal facts (prin1-to-string (supertag-store-get-collection :nodes)))))))

(ert-deftest supertag-find-node-cache-boundary-shared-selectors-and-reset ()
  (supertag-find-node-test--isolated
    (supertag-node-create '(:id "one" :title "One"))
    (let ((now 100) (calls 0) (real (symbol-function 'supertag-ui--build-node-candidates))
          (supertag-ui--select-node-candidates 'outside))
      (cl-letf (((symbol-function 'current-time) (lambda () (seconds-to-time now)))
                ((symbol-function 'supertag-ui--build-node-candidates)
                 (lambda () (setq calls (1+ calls)) (funcall real))))
        (let ((first (supertag-ui--get-cached-nodes)))
          (setq now 130) (should (eq first (supertag-ui--get-cached-nodes)))
          (should (= calls 1))
          (setq now 131) (supertag-ui--get-cached-nodes) (should (= calls 2))
          (setq supertag-ui--cache-timestamp nil) (supertag-ui--get-cached-nodes) (should (= calls 3))
          (setq supertag-ui--node-cache nil) (supertag-ui--get-cached-nodes) (should (= calls 4))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (prompt collection &rest _)
                       (if (string-prefix-p "Many" prompt) "Done" (caar collection)))))
            (should (equal "one" (supertag-ui-select-node "One" t nil "one")))
            (should (equal '("one") (supertag-ui-select-multiple-nodes "Many" t '("one") nil))))
          (should (eq 'outside supertag-ui--select-node-candidates)) (should (= calls 4))
          (supertag-node-create '(:id "fresh" :title "Fresh"))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt table &rest _)
                       (should-not (funcall table "Fresh  [Create new node]" nil 'lambda))
                       (car (all-completions "Fresh" table)))))
            (should (equal '(:existing "fresh") (supertag-ui-read-find-node "Find" nil))))
          (should (= calls 5))
          (supertag-ui--reset-runtime)
          (should-not supertag-ui--node-cache) (should-not supertag-ui--cache-timestamp)
          (should (eq 'outside supertag-ui--select-node-candidates)))))))

(ert-deftest supertag-find-node-vertico-real-preview-then-error-restores-context ()
  (supertag-find-node-test--isolated
    (let ((file (expand-file-name "preview.org" tmp))
          (source (generate-new-buffer " *node-c-source*"))
          (vertico-mode t) (ivy-mode nil) (pre-count 0) match)
      (unwind-protect
          (progn
            (supertag-find-node-test--write-node file "preview" "Preview")
            (save-window-excursion
              (switch-to-buffer source) (insert "source body") (goto-char 5) (set-mark 8)
              (narrow-to-region 2 10) (set-window-start (selected-window) (point-min))
              (let* ((pre-hook (lambda () (setq pre-count (1+ pre-count))))
                     (vertico-selection-hook (list pre-hook))
                     (context (list (current-buffer) (point) (mark) (point-min) (point-max)))
                     (windows (supertag-find-node-test--window-layout))
                     (disk (with-temp-buffer (insert-file-contents file) (buffer-string))))
                (cl-letf (((symbol-function 'vertico-current-candidate) (lambda () match))
                          ((symbol-function 'completing-read)
                           (lambda (_prompt table &rest _)
                             (setq match (car (all-completions "Preview" table)))
                             (run-hooks 'vertico-selection-hook)
                             (should (equal file (buffer-file-name)))
                             (should (looking-at "\\* Preview"))
                             (error "NODE-C after actual preview"))))
                  (should (equal '(error "NODE-C after actual preview")
                                 (should-error (supertag-ui-read-find-node "Find" t)))))
                (should (> pre-count 0))
                (should (equal (list pre-hook) vertico-selection-hook))
                (should (equal context (list (current-buffer) (point) (mark) (point-min) (point-max))))
                (should (equal windows (supertag-find-node-test--window-layout)))
                (should (equal disk (with-temp-buffer (insert-file-contents file) (buffer-string)))))))
        (kill-buffer source)))))

;;; NODE-F: generic selection is not Find's context/recovery contract.
(defmacro supertag-find-node-test--generic-env (&rest body)
  (declare (indent 0))
  `(save-window-excursion
     (supertag-find-node-test--isolated
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (and (buffer-file-name b) (file-in-directory-p (buffer-file-name b) tmp))
             (with-current-buffer b (set-buffer-modified-p nil))))))))

(defun supertag-find-node-test--disk (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest supertag-find-node-generic-plain-dynamic-fresh-and-ivy-seam ()
  (supertag-find-node-test--generic-env
    (let ((a (expand-file-name "a.org" tmp)) (b (expand-file-name "b.org" tmp))
          (supertag-ui--select-node-candidates 'outer) (ivy-mode nil) (vertico-mode nil))
      (supertag-find-node-test--write-node a "a" "Alpha")
      (dolist (initial '("a" "unknown"))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_ table _pred _require &rest args)
                     (should (equal table supertag-ui--select-node-candidates))
                     (should (equal (nth 2 args) (and (equal initial "a") (car (rassoc "a" table)))))
                     (car (rassoc "a" table)))))
          (should (equal "a" (supertag-ui-select-node nil nil nil initial))))
        (should (eq 'outer supertag-ui--select-node-candidates)))
      (supertag-find-node-test--write-node b "b" "Beta")
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_ table &rest _) (should (rassoc "b" table)) (car (rassoc "b" table)))))
        (should (equal "b" (supertag-ui-select-node nil nil nil))))
      ;; Optional frontend seam only; no claim of a real Ivy installation.
      (let ((ivy-mode t))
        (cl-letf (((symbol-function 'ivy-read)
                   (lambda (_ choices &rest args)
                     (should (eq 'supertag-ui-select-node (plist-get args :caller)))
                     (should (equal choices (mapcar #'car supertag-ui--select-node-candidates)))
                     (car (rassoc "a" supertag-ui--select-node-candidates)))))
          (should (equal "a" (supertag-ui-select-node nil nil t)))))
      (should (eq 'outer supertag-ui--select-node-candidates)))))

(ert-deftest supertag-find-node-generic-preview-error-quit-retains-preview-context ()
  (dolist (kind '(error quit))
    (supertag-find-node-test--generic-env
      (let ((file (expand-file-name "preview.org" tmp))
            (source (generate-new-buffer " *node-f-source*"))
            (ivy-mode nil) (vertico-mode t)
            (supertag-ui--select-node-candidates 'outer) match seen)
        (unwind-protect
            (progn
              (supertag-find-node-test--write-node file "preview" "Preview")
              (switch-to-buffer source) (insert "original") (goto-char 3)
              (let* ((unrelated (lambda () (push 'unrelated seen)))
                     (vertico-selection-hook (list unrelated))
                     (disk (supertag-find-node-test--disk file)) caught)
                (cl-letf (((symbol-function 'vertico-current-candidate) (lambda () match))
                          ((symbol-function 'completing-read)
                           (lambda (_ table &rest _)
                             (setq match (car (rassoc "preview" table)))
                             (should (equal table supertag-ui--select-node-candidates))
                             (run-hooks 'vertico-selection-hook)
                             (should (equal file (buffer-file-name)))
                             (should (looking-at "\\* Preview"))
                             (signal kind (unless (eq kind 'quit) '("NODE-F preview"))))))
                  (condition-case e (supertag-ui-select-node nil nil t)
                    (quit (setq caught e)) (error (setq caught e))))
                (should (equal caught (if (eq kind 'quit) '(quit) '(error "NODE-F preview"))))
                (should (equal (list unrelated) vertico-selection-hook))
                (should (memq 'unrelated seen))
                (should (eq 'outer supertag-ui--select-node-candidates))
                ;; Unlike Find, generic preview leaves the selected preview window.
                (should (equal file (buffer-file-name)))
                (should (looking-at "\\* Preview"))
                (should (equal disk (supertag-find-node-test--disk file)))
                (princ (format "NODE-F-PREVIEW %S buffer=target point=%s windows=%s\n"
                               kind (point) (length (window-list))))))
          (kill-buffer source))))))

(ert-deftest supertag-find-node-generic-multiple-order-fallback-and-input-copy ()
  (supertag-find-node-test--generic-env
    (let ((a (expand-file-name "a.org" tmp)) (b (expand-file-name "b.org" tmp))
          (initial (list "unknown" "a")) (answers '("Add node..." add "Remove node..." "unknown" "Done")))
      (supertag-find-node-test--write-node a "a" "Alpha")
      (supertag-find-node-test--write-node b "b" "Beta")
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt choices &rest _)
                   (should answers)
                   (let ((answer (pop answers)))
                     (if (eq answer 'add)
                         (progn (should (equal prompt "Add node: "))
                                (should (= 1 (length choices))) (car choices))
                       (when (equal prompt "Remove node: ") (should (member "unknown" choices)))
                       answer)))))
        (let ((result (supertag-ui-select-multiple-nodes nil nil initial t)))
          (should (equal '("a" "b") result))
          (should-not (eq result initial))))
      (should (equal '("unknown" "a") initial)) (should-not answers))))

(defun supertag-find-node-test--reference-case (fault &optional multiple)
  (supertag-find-node-test--generic-env
    (let* ((file (expand-file-name "reference.org" tmp))
           (original "* Neighbor\nKeep exactly\n")
           (sync-real (symbol-function 'supertag-node-sync-at-point))
           (save-real (symbol-function 'save-buffer))
           (actions (list "Create node..." "Done"))
           events id result caught)
      (with-temp-file file (insert original))
      (supertag-ui--get-cached-nodes)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (if (eq fault 'blank) "  " "  Created  ")))
                ((symbol-function 'read-file-name)
                 (lambda (&rest _) (if (eq fault 'quit) (signal 'quit nil) file)))
                ((symbol-function 'completing-read)
                 (lambda (prompt choices &rest _)
                   (if (equal prompt "Insert position: ")
                       (progn (should (member "File End" choices)) "File End")
                     (should actions) (pop actions))))
                ((symbol-function 'supertag-node-sync-at-point)
                 (lambda ()
                   (setq id (org-entry-get nil "ID"))
                   (when (eq fault 'sync) (error "NODE-F sync"))
                   (prog1 (funcall sync-real)
                     (should (supertag-node-get id))
                     (should (buffer-modified-p))
                     (should (equal original (supertag-find-node-test--disk file)))
                     (push 'project events))))
                ((symbol-function 'save-buffer)
                 (lambda (&rest args)
                   (should (supertag-node-get id))
                   (push 'save-entry events)
                   (when (eq fault 'save-before) (error "NODE-F save-before"))
                   (apply save-real args)
                   (push 'saved events)
                   (when (eq fault 'save-after) (error "NODE-F save-after")))))
        (condition-case e
            (setq result (if multiple (supertag-ui-select-multiple-nodes nil t nil t)
                          (supertag-node-reference-and-create)))
          (quit (setq caught e)) (error (setq caught e))))
      (if (and multiple (memq fault '(sync save-before save-after blank)))
          (should-not caught)
        (should (equal caught
                       (pcase fault
                         ('blank '(user-error "Node title cannot be empty"))
                         ('quit '(quit))
                         ((or 'sync 'save-before 'save-after)
                          (list 'error (concat "NODE-F " (symbol-name fault))))
                         (_ nil)))))
      (with-current-buffer (find-file-noselect file)
        (cond
         ((memq fault '(blank quit))
          (should (equal original (buffer-string))) (should-not id))
         (t
          (should id) (should (string-prefix-p original (buffer-string)))
          (should (string-match-p "\\* Created" (buffer-string)))
          (if (eq fault 'sync) (should-not (supertag-node-get id))
            (should (equal "Created" (plist-get (supertag-node-get id) :title)))))))
      (if (memq fault '(nil save-after))
          (progn
            (should (string-match-p (regexp-quote id) (supertag-find-node-test--disk file)))
            (with-current-buffer (find-file-noselect file) (should-not (buffer-modified-p)))
            (should (equal '(project save-entry saved) (reverse events))))
        (should (equal original (supertag-find-node-test--disk file))))
      (unless fault
        (should (equal (if multiple (list id) id) result))
        (when multiple (should (rassoc id (supertag-ui--get-cached-nodes)))))
      (princ (format "NODE-F-CREATE fault=%S multiple=%S events=%S cache=%S\n"
                     fault multiple (reverse events) (and supertag-ui--node-cache t))))))

(ert-deftest supertag-find-node-reference-create-real-order-and-failures ()
  (dolist (fault '(nil blank quit sync save-before save-after))
    (supertag-find-node-test--reference-case fault)))
(ert-deftest supertag-find-node-multiple-real-create-error-and-quit ()
  (dolist (fault '(nil sync quit))
    (supertag-find-node-test--reference-case fault t)))

(ert-deftest supertag-find-node-reproject-real-heading-and-file-branches ()
  (dolist (file-p '(nil t))
    (supertag-find-node-test--generic-env
      (let* ((file (expand-file-name "reproject.org" tmp))
             (supertag-file-id-source 'org-id)
             (content (if file-p ":PROPERTIES:\n:ID: file-id\n:END:\n#+TITLE: Before\n\nFile body\n"
                        "* Heading\n:PROPERTIES:\n:ID: heading-id\n:END:\nBody\n"))
             (id (if file-p "file-id" "heading-id"))
             (heading-real (symbol-function 'supertag-node-sync-at-point))
             (file-real (symbol-function 'supertag-ui--ensure-file-node-synced)) calls)
        (with-temp-file file (insert content))
        (with-current-buffer (find-file-noselect file)
          (goto-char (point-min))
          (if file-p (supertag-ui--ensure-file-node-synced file) (supertag-node-sync-at-point))
          (should (supertag-node-get id))
          (when file-p
            (goto-char (point-min)) (search-forward "Before") (replace-match "Live title"))
          (goto-char (point-max)) (insert "Live only\n")
          (narrow-to-region (point-min) (1- (point-max)))
          (let ((pos (point)) (min (point-min)) (max (point-max)))
            (cl-letf (((symbol-function 'supertag-node-sync-at-point)
                       (lambda () (push 'heading calls) (funcall heading-real)))
                      ((symbol-function 'supertag-ui--ensure-file-node-synced)
                       (lambda (path) (push 'file calls) (funcall file-real path))))
              (supertag-ui--reproject-containing-node id))
            (should (equal (list (if file-p 'file 'heading)) calls))
            (should (= pos (point))) (should (= min (point-min))) (should (= max (point-max)))
            (should (equal content (supertag-find-node-test--disk file)))
            (should (supertag-node-get id))
            (if file-p
                (should (equal "Before" (plist-get (supertag-node-get id) :title)))
              (should (string-match-p "Live only" (plist-get (supertag-node-get id) :content))))
            (princ (format "NODE-F-REPROJECT file=%S content=%S\n" file-p
                           (plist-get (supertag-node-get id) :content)))))))))
