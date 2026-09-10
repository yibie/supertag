;;; discovery-workflow-test.el --- Discovery workflow tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'supertag-core-store)
(require 'supertag-link)
(require 'supertag-services-sync)
(require 'supertag-discovery)
(require 'supertag-link)
(require 'supertag-view-framework)

(defmacro supertag-discovery-test--isolated (&rest body)
  (declare (indent 0) (debug t))
  `(let ((supertag--store (make-hash-table :test #'equal))
         (supertag--index-source-revisions (make-hash-table :test #'eq))
         (supertag-discovery--history nil)
         (supertag-discovery-history-file
          (make-temp-name (expand-file-name "discovery-history-"
                                            temporary-file-directory))))
     (supertag--ensure-store)
     ,@body))

(defmacro supertag-discovery-test--with-files (&rest body)
  (declare (indent 0) (debug t))
  `(let* ((tmp (make-temp-file "supertag-discovery-test-" t))
          (supertag-data-directory (expand-file-name "data" tmp))
          (supertag-db-file (expand-file-name "db.el" supertag-data-directory))
          (supertag-db-backup-directory (expand-file-name "backup" tmp))
          (supertag-sync-directories (list tmp))
          (supertag-active-sync-directory tmp)
          (supertag--store nil) (supertag--store-origin nil)
          (org-id-locations nil) (org-id-files nil)
          (org-id-locations-file (expand-file-name "org-id" tmp)))
     (unwind-protect
         (progn (supertag--ensure-store) ,@body)
       (dolist (buffer (buffer-list))
         (when-let* ((file (buffer-file-name buffer)))
           (when (string-prefix-p tmp file)
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer))))
       (ignore-errors (delete-directory tmp t)))))

(defun supertag-discovery-test--write-node (file id title body)
  (with-temp-file file
    (insert (format "* %s\n:PROPERTIES:\n:ID: %s\n:END:\n%s\n"
                    title id body)))
  (with-current-buffer (find-file-noselect file)
    (org-mode)
    (goto-char (point-min))
    (supertag-node-sync-at-point)))

(defun supertag-discovery-test--put-node (number &optional body properties)
  (let ((id (format "node-%02d" number)))
    (supertag-store-put-entity
     :nodes id
     (list :id id :type :node :title (format "Note %02d" number)
           :file (format "/tmp/%s.org" id)
           :content (or body (format "Complete body %02d" number))
           :tags (if (zerop (% number 2)) '("even") '("odd"))
           :properties properties))
    id))

(ert-deftest supertag-discovery-public-command-opens-readable-random-ten-without-prompt ()
  (supertag-discovery-test--isolated
    (dotimes (index 12)
      (supertag-discovery-test--put-node index))
    (let ((origin (generate-new-buffer " *discovery-origin*"))
          buffer)
      (unwind-protect
          (cl-letf (((symbol-function 'read-string)
                     (lambda (&rest _) (ert-fail "Discovery prompted on open")))
                    ((symbol-function 'display-buffer) #'ignore)
                    ((symbol-function 'supertag-discovery--get-node-tags)
                     (lambda (id) (plist-get (supertag-node-get id) :tags))))
            (setq buffer (with-current-buffer origin (supertag-discovery)))
            (with-current-buffer buffer
              (should supertag-discovery-mode)
              (let* ((nodes (plist-get
                             (plist-get supertag-view--instance :state)
                             :nodes))
                     (ids (mapcar (lambda (pair)
                                    (plist-get (car pair) :id))
                                  nodes)))
                (should (= 10 (length nodes)))
                (should (= 10 (length (delete-dups ids))))
                (should (= 10 (how-many "^┌" (point-min) (point-max)))))
              (should (string-match-p "Complete body" (buffer-string)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest supertag-discovery-empty-body-is-explicitly-readable ()
  (supertag-discovery-test--isolated
    (supertag-discovery-test--put-node 1 "")
    (cl-letf (((symbol-function 'display-buffer) #'ignore)
              ((symbol-function 'supertag-discovery--get-node-tags) #'ignore))
      (let ((buffer (supertag-discovery)))
        (unwind-protect
            (with-current-buffer buffer
              (should (string-match-p "Empty body" (buffer-string))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest supertag-discovery-real-whitespace-body-is-explicitly-empty ()
  (supertag-discovery-test--with-files
    (let ((file (expand-file-name "blank.org" tmp)) results)
      (with-temp-file file
        (insert "* Blank\n:PROPERTIES:\n:ID: blank\n:END:\n \t\n\n"
                "* Next\n:PROPERTIES:\n:ID: next\n:END:\nBody\n"))
      (with-current-buffer (find-file-noselect file)
        (org-mode)
        (goto-char (point-min))
        (supertag-node-sync-at-point)
        (outline-next-heading)
        (supertag-node-sync-at-point))
      (setq results
            (supertag-discovery--show-results
             :search '("Blank") (supertag-discovery-find-nodes '("Blank"))))
      (unwind-protect
          (with-current-buffer results
            (should (string-match-p "Empty body" (buffer-string)))
            (should-not (string-match-p "Body.*Next" (buffer-string))))
        (when (buffer-live-p results) (kill-buffer results))))))

(ert-deftest supertag-discovery-empty-library-and-long-body-are-complete ()
  (supertag-discovery-test--isolated
    (cl-letf (((symbol-function 'display-buffer) #'ignore)
              ((symbol-function 'supertag-discovery--get-node-tags) #'ignore))
      (let ((empty (supertag-discovery)))
        (unwind-protect
            (with-current-buffer empty
              (should (string-match-p "Showing 0 random notes" (buffer-string)))
              (should (string-match-p "No matching nodes" (buffer-string))))
          (when (buffer-live-p empty) (kill-buffer empty))))
      (supertag-discovery-test--put-node
       1 (concat (make-string 180 ?x) "END-OF-BODY"))
      (let ((buffer (supertag-discovery)))
        (unwind-protect
            (with-current-buffer buffer
              (should (string-match-p "END-OF-BODY" (buffer-string))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest supertag-discovery-search-renders-all-matches-and-empty-returns-to-sample ()
  (supertag-discovery-test--isolated
    (dotimes (index 14)
      (supertag-discovery-test--put-node
       index "shared needle body" '(:STAGE "ready")))
    (cl-letf (((symbol-function 'display-buffer) #'ignore)
              ((symbol-function 'supertag-discovery--get-node-tags)
               (lambda (id) (plist-get (supertag-node-get id) :tags))))
      (let ((buffer (supertag-discovery)))
        (unwind-protect
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'read-string)
                         (lambda (prompt &rest _)
                           (should (equal prompt "Search notes (all keywords): "))
                           "shared ready")))
                (supertag-discovery-search))
              (should (eq :search
                          (plist-get (plist-get supertag-view--instance :input)
                                     :mode)))
              (should (string-match-p "Supertag Discovery Search results:" (buffer-string)))
              (should (string-match-p (regexp-quote "[s] Search") (buffer-string)))
              (should-not (string-match-p (regexp-quote "[f] Filter") (buffer-string)))
              (should (string-match-p "Found 14 matching nodes"
                                      (buffer-string)))
              (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
                (supertag-discovery-search))
              (should (eq :sample
                          (plist-get (plist-get supertag-view--instance :input)
                                     :mode)))
              (should (string-match-p "Showing 10 random notes"
                                      (buffer-string))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest supertag-discovery-refresh-preserves-visible-and-hidden-marks ()
  (supertag-discovery-test--isolated
    (dotimes (index 3)
      (supertag-discovery-test--put-node index))
    (cl-letf (((symbol-function 'display-buffer) #'ignore)
              ((symbol-function 'supertag-discovery--get-node-tags) #'ignore))
      (let ((buffer (supertag-discovery)))
        (unwind-protect
            (with-current-buffer buffer
              (setq supertag-discovery--marked-nodes '("node-00" "node-01"))
              (setf (plist-get supertag-view--instance :input)
                    '(:mode :search :keywords ("Note 00")))
              (supertag-discovery-refresh)
              (should (equal '("node-00" "node-01")
                             supertag-discovery--marked-nodes))
              (should (string-match-p "Marked: 2 (1 hidden)" (buffer-string))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest supertag-discovery-space-updates-checkbox-and-mark-counts ()
  (supertag-discovery-test--isolated
    (supertag-discovery-test--put-node 1)
    (cl-letf (((symbol-function 'display-buffer) #'ignore)
              ((symbol-function 'supertag-discovery--get-node-tags) #'ignore))
      (let ((buffer (supertag-discovery)))
        (unwind-protect
            (with-current-buffer buffer
              (goto-char (point-min))
              (re-search-forward "^┌")
              (beginning-of-line)
              (call-interactively (lookup-key (current-local-map) (kbd "SPC")))
              (should (string-match-p "Marked: 1 (0 hidden)" (buffer-string)))
              (should (string-match-p "│ \\[X\\] Note 01" (buffer-string)))
              (call-interactively (lookup-key (current-local-map) (kbd "SPC")))
              (should (string-match-p "Marked: 0 (0 hidden)" (buffer-string)))
              (should (string-match-p "│ \\[ \\] Note 01" (buffer-string))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest supertag-discovery-origin-marker-tracks-edits-and-quit-restores-context ()
  (supertag-discovery-test--isolated
    (supertag-discovery-test--put-node 1)
    (let ((origin (generate-new-buffer " *discovery-live-origin*")) buffer)
      (unwind-protect
          (progn
            (with-current-buffer origin
              (org-mode)
              (insert "* Source\nabcdef\n")
              (goto-char 12)
              (set-mark 15)
              (setq mark-active t)
              (narrow-to-region 3 (point-max)))
            (cl-letf (((symbol-function 'display-buffer) #'ignore)
                      ((symbol-function 'supertag-discovery--get-node-tags) #'ignore))
              (setq buffer (with-current-buffer origin (supertag-discovery))))
            (with-current-buffer origin
              (save-restriction
                (widen)
                (goto-char 1)
                (insert "prefix ")))
            (switch-to-buffer buffer)
            (supertag-discovery-quit)
            (should-not (buffer-live-p buffer))
            (should (eq (current-buffer) origin))
            (should (eq (window-buffer (selected-window)) origin))
            (with-current-buffer origin
              (should (= (point) 19))
              (should (= (mark) 22))
              (should (= (point-min) 10))
              (should mark-active)))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest supertag-discovery-real-multi-reference-save-and-projection ()
  (supertag-discovery-test--with-files
    (let ((source (expand-file-name "source.org" tmp))
          (one (expand-file-name "one.org" tmp))
          (two (expand-file-name "two.org" tmp)))
      (supertag-discovery-test--write-node source "source" "Source" "Draft")
      (supertag-discovery-test--write-node one "one" "One" "First")
      (supertag-discovery-test--write-node two "two" "Two" "Second")
      (save-window-excursion
        (let* ((source-buffer (find-file-noselect source))
               (results
                (with-current-buffer source-buffer
                  (goto-char (point-max))
                  (supertag-discovery))))
          (with-current-buffer results
            ;; Newest-first storage yields selection order one, then two.
            (setq supertag-discovery--marked-nodes '("two" "one"))
            (should (equal '("one" "two")
                           (supertag-discovery-insert-references))))))
      (with-temp-buffer
        (insert-file-contents source)
        (should (= 1 (how-many "\\[\\[id:one\\]" (point-min) (point-max))))
        (should (= 1 (how-many "\\[\\[id:two\\]" (point-min) (point-max)))))
      (should (= 1 (length (supertag-relation-find-between
                            "source" "one" :reference))))
      (should (= 1 (length (supertag-relation-find-between
                            "source" "two" :reference)))))))

(ert-deftest supertag-discovery-second-save-failure-retry-does-not-duplicate ()
  (supertag-discovery-test--with-files
    (let ((source (expand-file-name "source.org" tmp))
          (one (expand-file-name "one.org" tmp))
          (two (expand-file-name "two.org" tmp))
          payload results)
      (supertag-discovery-test--write-node source "source" "Source" "Draft")
      (supertag-discovery-test--write-node one "one" "One" "First")
      (supertag-discovery-test--write-node two "two" "Two" "Second")
      (save-window-excursion
        (let ((source-saves 0)
              (real-save (symbol-function 'save-buffer)))
          (setq results
                (with-current-buffer (find-file-noselect source)
                  (goto-char (point-max))
                  (supertag-discovery)))
          (with-current-buffer results
            (setq supertag-discovery--marked-nodes '("two" "one")))
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest args)
                       (if (and (equal (buffer-file-name) source)
                                (= 2 (cl-incf source-saves)))
                           (error "second source save")
                         (apply real-save args)))))
            (condition-case error-data
                (with-current-buffer results
                  (supertag-discovery-insert-references))
              (supertag-link-error (setq payload (cdr error-data)))))
          (should (eq :source-save (plist-get payload :stage)))
          (apply (plist-get payload :retry) (plist-get payload :retry-args))
          (with-current-buffer results
            (should (equal '("one" "two")
                           (supertag-discovery-insert-references))))))
      (with-temp-buffer
        (insert-file-contents source)
        (should (= 1 (how-many "\\[\\[id:one\\]" (point-min) (point-max))))
        (should (= 1 (how-many "\\[\\[id:two\\]" (point-min) (point-max))))))))

(ert-deftest supertag-discovery-old-endpoint-does-not-acknowledge-failed-occurrence ()
  (supertag-discovery-test--with-files
    (let ((source (expand-file-name "source.org" tmp))
          (one (expand-file-name "one.org" tmp))
          (two (expand-file-name "two.org" tmp))
          first-error second-error results)
      (supertag-discovery-test--write-node
       source "source" "Source" "- [[id:two][old]]")
      (supertag-discovery-test--write-node one "one" "One" "First")
      (supertag-discovery-test--write-node two "two" "Two" "Second")
      (save-window-excursion
        (let ((source-saves 0)
              (real-save (symbol-function 'save-buffer)))
          (setq results
                (with-current-buffer (find-file-noselect source)
                  (goto-char (point-max))
                  (supertag-discovery)))
          (with-current-buffer results
            (setq supertag-discovery--marked-nodes '("two" "one")))
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest args)
                       (if (and (equal (buffer-file-name) source)
                                (= 2 (cl-incf source-saves)))
                           (error "second source save")
                         (apply real-save args)))))
            (condition-case data
                (with-current-buffer results
                  (supertag-discovery-insert-references))
              (supertag-link-error (setq first-error data))))
          ;; Projecting the retained unsaved buffer is not recovery: the
          ;; writer's save retry has not completed.
          (with-current-buffer (find-file-noselect source)
            (goto-char (point-min))
            (supertag-node-sync-at-point))
          (should (supertag-reference--projected-p "source" "two" nil))
          (condition-case data
              (with-current-buffer results
                (supertag-discovery-insert-references))
            (supertag-link-error (setq second-error data)))
          (should (equal first-error second-error))
          (should (buffer-modified-p (find-file-noselect source)))
          (with-temp-buffer
            (insert-file-contents source)
            (should (= 1 (how-many "\\[\\[id:two\\]" (point-min) (point-max))))))))))

(ert-deftest supertag-discovery-file-node-retry-completes-without-node-content ()
  (supertag-discovery-test--with-files
    (let ((source (expand-file-name "source.org" tmp))
          (one (expand-file-name "one.org" tmp))
          (two (expand-file-name "two.org" tmp)) payload results)
      (with-temp-file source
        (insert ":PROPERTIES:\n:ID: file-source\n:END:\n- [[id:two][old]]\n"))
      (supertag-discovery-test--write-node one "one" "One" "First")
      (supertag-discovery-test--write-node two "two" "Two" "Second")
      (save-window-excursion
        (let ((source-saves 0)
              (real-save (symbol-function 'save-buffer)))
          (setq results
                (with-current-buffer (find-file-noselect source)
                  (org-mode)
                  (supertag-ui--ensure-file-node-synced source)
                  (goto-char (point-max))
                  (supertag-discovery)))
          (should-not (plist-get (supertag-node-get "file-source") :content))
          (with-current-buffer results
            (setq supertag-discovery--marked-nodes '("two" "one")))
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest args)
                       (if (and (equal (buffer-file-name) source)
                                (= 2 (cl-incf source-saves)))
                           (error "second source save")
                         (apply real-save args)))))
            (condition-case data
                (with-current-buffer results
                  (supertag-discovery-insert-references))
              (supertag-link-error (setq payload (cdr data)))))
          (should (eq :source-save (plist-get payload :stage)))
          (should-not (supertag-reference-recovery-complete-p payload))
          (should (equal "two"
                         (apply (plist-get payload :retry)
                                (plist-get payload :retry-args))))
          (should (supertag-reference-recovery-complete-p payload))
          (with-current-buffer results
            (should (equal '("one" "two")
                           (supertag-discovery-insert-references))))))
      (with-temp-buffer
        (insert-file-contents source)
        (should (= 1 (how-many "\\[\\[id:one\\]" (point-min) (point-max))))
        (should (= 2 (how-many "\\[\\[id:two\\]" (point-min) (point-max))))))))

(ert-deftest supertag-discovery-second-projection-failure-retry-does-not-duplicate ()
  (supertag-discovery-test--with-files
    (let ((source (expand-file-name "source.org" tmp))
          (one (expand-file-name "one.org" tmp))
          (two (expand-file-name "two.org" tmp))
          payload results)
      (supertag-discovery-test--write-node source "source" "Source" "Draft")
      (supertag-discovery-test--write-node one "one" "One" "First")
      (supertag-discovery-test--write-node two "two" "Two" "Second")
      (save-window-excursion
        (let ((projects 0)
              (real-project
               (symbol-function 'supertag-ui--reproject-containing-node)))
          (setq results
                (with-current-buffer (find-file-noselect source)
                  (goto-char (point-max))
                  (supertag-discovery)))
          (with-current-buffer results
            (setq supertag-discovery--marked-nodes '("two" "one")))
          (cl-letf (((symbol-function 'supertag-ui--reproject-containing-node)
                     (lambda (id)
                       (if (= 2 (cl-incf projects))
                           (error "second source projection")
                         (funcall real-project id)))))
            (condition-case error-data
                (with-current-buffer results
                  (supertag-discovery-insert-references))
              (supertag-link-error (setq payload (cdr error-data)))))
          (should (eq :source-project (plist-get payload :stage)))
          (apply (plist-get payload :retry) (plist-get payload :retry-args))
          (with-current-buffer results
            (should (equal '("one" "two")
                           (supertag-discovery-insert-references))))))
      (with-temp-buffer
        (insert-file-contents source)
        (should (= 1 (how-many "\\[\\[id:one\\]" (point-min) (point-max))))
        (should (= 1 (how-many "\\[\\[id:two\\]" (point-min) (point-max))))))))

(ert-deftest supertag-discovery-open-node-preserves-native-return-and-stale-context ()
  (supertag-discovery-test--with-files
    (let ((file (expand-file-name "target.org" tmp)))
      (supertag-discovery-test--write-node file "target" "Target" "Readable")
      (save-window-excursion
        (let ((origin (generate-new-buffer " *discovery-nav-origin*")) results)
          (unwind-protect
              (progn
                (setq results (with-current-buffer origin (supertag-discovery)))
                (with-current-buffer results
                  (goto-char (point-min))
                  (re-search-forward "^┌")
                  (beginning-of-line)
                  (should (equal "Jumped to node: Target"
                                 (supertag-discovery-open-node))))
                (should (equal file
                               (buffer-file-name
                                (window-buffer (selected-window)))))
                (with-current-buffer (find-file-noselect file)
                  (goto-char (point-min))
                  (re-search-forward "^:ID: target$")
                  (replace-match ":ID: stale")
                  (save-buffer))
                (switch-to-buffer results)
                (let ((position (point)))
                  (should (equal (format "Error: Could not find ID target in file %s"
                                         (file-truename file))
                                 (supertag-discovery-open-node)))
                  (should (eq (current-buffer) results))
                  (should (= position (point)))))
            (when (buffer-live-p results) (kill-buffer results))
            (when (buffer-live-p origin) (kill-buffer origin))))))))

(ert-deftest supertag-discovery-public-two-opens-native-history-then-live-origin ()
  (supertag-discovery-test--with-files
    (let ((a (expand-file-name "a.org" tmp))
          (b (expand-file-name "b.org" tmp))
          (origin (generate-new-buffer " *discovery-two-open-origin*")) results)
      (supertag-discovery-test--write-node a "a" "A" "Alpha")
      (supertag-discovery-test--write-node b "b" "B" "Beta")
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer origin)
            (org-mode)
            (insert "* Origin\n0123456789\n")
            (goto-char 14) (set-mark 17) (setq mark-active t)
            (narrow-to-region 3 20)
            (setq results (supertag-discovery))
            (dolist (id '("a" "b"))
              (switch-to-buffer results)
              (goto-char (point-min))
              (let ((match (text-property-search-forward 'node-id id #'equal)))
                (should match)
                (goto-char (prop-match-beginning match))
                (should (string-prefix-p "Jumped to node:"
                                         (supertag-discovery-open-node))))
              (should (equal id (file-name-base (buffer-file-name))))
              (previous-buffer)
              (should (eq (current-buffer) results)))
            (supertag-discovery-quit)
            (should (eq (current-buffer) origin))
            (should (= 14 (point)))
            (should (= 17 (mark)))
            (should (= 3 (point-min)))
            (should (= 20 (point-max)))
            (should mark-active))
        (when (buffer-live-p results) (kill-buffer results))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest supertag-discovery-invalid-source-refuses-before-bullet-or-identity ()
  (supertag-discovery-test--with-files
    (let ((target (expand-file-name "target.org" tmp))
          (origin (generate-new-buffer " *discovery-invalid-source*")) results
          (writes 0))
      (supertag-discovery-test--write-node target "target" "Target" "Body")
      (unwind-protect
          (progn
            (setq results (with-current-buffer origin (supertag-discovery)))
            (with-current-buffer results
              (setq supertag-discovery--marked-nodes '("target")))
            (cl-letf (((symbol-function 'supertag-reference-materialize-at-point)
                       (lambda (&rest _) (cl-incf writes))))
              (with-current-buffer results
                (should-error (supertag-discovery-insert-references)
                              :type 'user-error)))
            (should (= 0 writes))
            (with-current-buffer origin
              (should (string-empty-p (buffer-string)))))
        (when (buffer-live-p results) (kill-buffer results))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest supertag-discovery-heading-without-id-reaches-shared-writer ()
  (supertag-discovery-test--with-files
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "target.org" tmp)) results)
      (with-temp-file source (insert "* Source\nDraft\n"))
      (supertag-discovery-test--write-node target "target" "Target" "Body")
      (save-window-excursion
        (setq results
              (with-current-buffer (find-file-noselect source)
                (org-mode) (goto-char (point-max)) (supertag-discovery)))
        (with-current-buffer results
          (setq supertag-discovery--marked-nodes '("target"))
          (should (equal '("target")
                         (supertag-discovery-insert-references)))))
      (with-temp-buffer
        (insert-file-contents source)
        (should (re-search-forward "^:ID:[ \t]+.+$" nil t))
        (should (search-forward "[[id:target][Target]]" nil t))))))

(ert-deftest supertag-discovery-non-org-file-refuses-before-bullet ()
  (supertag-discovery-test--with-files
    (let ((source (expand-file-name "source.txt" tmp))
          (target (expand-file-name "target.org" tmp)) results (writes 0))
      (with-temp-file source (insert "plain source"))
      (supertag-discovery-test--write-node target "target" "Target" "Body")
      (setq results
            (with-current-buffer (find-file-noselect source)
              (fundamental-mode) (goto-char (point-max)) (supertag-discovery)))
      (with-current-buffer results
        (setq supertag-discovery--marked-nodes '("target")))
      (cl-letf (((symbol-function 'supertag-reference-materialize-at-point)
                 (lambda (&rest _) (cl-incf writes))))
        (with-current-buffer results
          (should-error (supertag-discovery-insert-references)
                        :type 'user-error)))
      (should (= 0 writes))
      (with-temp-buffer
        (insert-file-contents source)
        (should (equal "plain source" (buffer-string))))
      (when (buffer-live-p results) (kill-buffer results)))))

(ert-deftest supertag-discovery-removed-target-refuses-before-materializer ()
  (supertag-discovery-test--with-files
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "target.org" tmp)) results (writes 0))
      (supertag-discovery-test--write-node source "source" "Source" "Draft")
      (supertag-discovery-test--write-node target "target" "Target" "Body")
      (setq results
            (with-current-buffer (find-file-noselect source)
              (goto-char (point-max)) (supertag-discovery)))
      (with-current-buffer results
        (setq supertag-discovery--marked-nodes '("target")))
      (supertag-store-remove-entity :nodes "target")
      (delete-file target)
      (cl-letf (((symbol-function 'supertag-reference-materialize-at-point)
                 (lambda (&rest _) (cl-incf writes))))
        (with-current-buffer results
          (should-error (supertag-discovery-insert-references)
                        :type 'user-error)))
      (should (= 0 writes))
      (with-temp-buffer
        (insert-file-contents source)
        (should-not (search-forward "[[id:target]" nil t)))
      (when (buffer-live-p results) (kill-buffer results)))))

(ert-deftest supertag-discovery-killed-origin-refuses-insertion-before-write ()
  (supertag-discovery-test--isolated
    (supertag-discovery-test--put-node 1)
    (let ((origin (generate-new-buffer " *discovery-killed-origin*")) results
          (writes 0))
      (unwind-protect
          (progn
            (setq results (with-current-buffer origin (supertag-discovery)))
            (with-current-buffer results
              (setq supertag-discovery--marked-nodes '("node-01")))
            (kill-buffer origin)
            (cl-letf (((symbol-function 'supertag-reference-materialize-at-point)
                       (lambda (&rest _) (cl-incf writes))))
              (with-current-buffer results
                (should-error (supertag-discovery-insert-references)
                              :type 'user-error)))
            (should (= 0 writes)))
        (when (buffer-live-p results) (kill-buffer results))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest supertag-discovery-no-selection-refuses-before-source-write ()
  (supertag-discovery-test--isolated
    (let ((writes 0))
      (cl-letf (((symbol-function 'display-buffer) #'ignore)
                ((symbol-function 'supertag-reference-materialize-at-point)
                 (lambda (&rest _) (cl-incf writes))))
        (let ((buffer (supertag-discovery)))
          (unwind-protect
              (with-current-buffer buffer
                (should-error (supertag-discovery-insert-references)
                              :type 'user-error)
                (should (= 0 writes)))
            (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(ert-deftest supertag-discovery-real-projection-matches-four-fields-and-refreshes ()
  (supertag-discovery-test--with-files
    (let ((file (expand-file-name "alpha.org" tmp)) results)
      (with-temp-file file
        (insert "* Alpha :topic:\n:PROPERTIES:\n:ID: alpha\n:STAGE: ready\n:END:\nNeedle body\n"))
      (supertag-tag-create '(:name "topic"))
      (with-current-buffer (find-file-noselect file)
        (org-mode)
        (goto-char (point-min))
        (supertag-node-sync-at-point))
      (dolist (keyword '("Alpha" "topic" "Needle" "ready"))
        (let ((matches (supertag-discovery-find-nodes (list keyword))))
          (ert-info ((format "keyword %s" keyword))
            (should matches)
            (should (equal "alpha" (plist-get (caar matches) :id))))))
      (setq results (supertag-discovery--show-results
                     :search '("ready")
                     (supertag-discovery-find-nodes '("ready"))))
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-min))
        (org-entry-put nil "STAGE" "done")
        (save-buffer)
        (supertag-node-sync-at-point))
      (with-current-buffer results
        (setf (plist-get supertag-view--instance :input)
              '(:mode :search :keywords ("ready")))
        (supertag-discovery-refresh)
        (should (string-match-p "Found 0 matching nodes" (buffer-string)))
        (setf (plist-get supertag-view--instance :input)
              '(:mode :search :keywords ("done")))
        (supertag-discovery-refresh)
        (should (string-match-p "Found 1 matching nodes" (buffer-string))))
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-min))
        (org-entry-delete nil "STAGE")
        (save-buffer)
        (supertag-node-sync-at-point))
      (with-current-buffer results
        (supertag-discovery-refresh)
        (should (string-match-p "Found 0 matching nodes" (buffer-string))))
      (when (buffer-live-p results) (kill-buffer results)))))

(ert-deftest supertag-discovery-public-and-local-entrypoints-replace-search ()
  (should (commandp 'supertag-discovery))
  (should (commandp 'supertag-discovery-search))
  (should-not (fboundp 'supertag-discovery-filter))
  (should-not (fboundp 'supertag-search))
  (should-not (fboundp 'supertag-search-export-results-to-file))
  (should-not (fboundp 'supertag-search-export-results-to-new-file))
  (should-not (fboundp 'supertag-search-find-nodes))
  (should-not (boundp 'supertag-search-history-file))
  (let ((map (supertag-discovery-mode-init-map)))
    (should-not (lookup-key map (kbd "f")))
    (should (eq (lookup-key map (kbd "s")) 'supertag-discovery-search))
    (should (eq (lookup-key map (kbd "g")) 'supertag-discovery-refresh))
    (should (eq (lookup-key map (kbd "RET")) 'supertag-discovery-open-node))
    (should (eq (lookup-key map (kbd "i"))
                'supertag-discovery-insert-references))
    (should-not (commandp (lookup-key map (kbd "e f"))))
    (should-not (commandp (lookup-key map (kbd "e n"))))))

(ert-deftest supertag-discovery-menu-wrapper-reaches-only-new-entry ()
  (require 'supertag-menu)
  (let (called)
    (cl-letf (((symbol-function 'supertag-discovery)
               (lambda () (interactive) (setq called t) :opened)))
      (should (eq :opened (supertag-menu--discovery))))
    (should called)
    (should-not (fboundp 'supertag-menu--search))))

(provide 'discovery-workflow-test)
;;; discovery-workflow-test.el ends here
