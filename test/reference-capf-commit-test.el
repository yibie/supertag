;;; reference-capf-commit-test.el --- `[[' reference completion always commits -*- lexical-binding: t; -*-

;; The shorthand CAPF must commit a link on every UI path: the explicit
;; create row, a title whose closer is already in the buffer, and a
;; selection a UI hands back as a plain string.

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

(defconst supertag-reference-capf-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))

(defmacro supertag-reference-capf-test--isolated (&rest body)
  "Run BODY with an isolated Store and temporary Org files."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "supertag-reference-capf-" t))
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
         (when-let* ((file (buffer-file-name buffer)))
           (when (string-prefix-p tmp file) (kill-buffer buffer))))
       (ignore-errors (delete-directory tmp t)))))

(defun supertag-reference-capf-test--write-node (file id title &optional body)
  "Write and project one identified node to FILE."
  (with-temp-file file
    (insert (format "* %s\n:PROPERTIES:\n:ID: %s\n:END:\n%s\n"
                    title id (or body ""))))
  (with-current-buffer (find-file-noselect file)
    (org-mode) (goto-char (point-min)) (supertag-node-sync-at-point)))

(defun supertag-reference-capf-test--capf ()
  "Enable the reference CAPF in the current buffer and return its spec."
  (setq-local completion-at-point-functions
              (list #'supertag-reference-completion-at-point))
  (run-hook-wrapped 'completion-at-point-functions
                    (lambda (fn) (funcall fn))))

(defun supertag-reference-capf-test--candidates (table predicate)
  (mapcar #'substring-no-properties
          (all-completions "" table predicate)))

(defun supertag-reference-capf-test--candidate (table predicate needle)
  (cl-find-if (lambda (candidate)
                (string-match-p (regexp-quote needle)
                                (substring-no-properties candidate)))
              (all-completions "" table predicate)))

(defun supertag-reference-capf-test--link-text ()
  "Return the buffer text from the shorthand opener, without the file header."
  (save-excursion
    (goto-char (point-min))
    (search-forward "[[" nil t)
    (string-trim (buffer-substring-no-properties (match-beginning 0) (point-max)))))

;;; The table contract Corfu depends on.

(ert-deftest supertag-reference-capf-exact-create-row-completes ()
  "A full create row is a completion; a typed prefix still is not."
  (supertag-reference-capf-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "target.org" tmp)))
      (supertag-reference-capf-test--write-node source "source" "Source" "Body")
      (supertag-reference-capf-test--write-node target "target" "Target" "Body")
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-max))
        (insert "[[Emacs Ti")
        (let* ((capf (supertag-reference-capf-test--capf))
               (table (nth 2 capf))
               (row "Emacs Ti  [Create new node]"))
          (should (equal row (car (last (supertag-reference-capf-test--candidates
                                         table nil)))))
          (should (test-completion row table))
          (should (eq t (try-completion row table)))
          ;; Typing the title is not authorization to create it.
          (should-not (test-completion "Emacs Ti" table))
          (should-not (test-completion "Emacs" table))
          ;; A unique existing target still expands to its full row.
          (should (string-match-p
                   "Target"
                   (substring-no-properties (try-completion "Targ" table)))))))))

(ert-deftest supertag-reference-capf-bounds-accept-a-typed-closer ()
  "An unfinished `[[Title]]' is a shorthand; a real link is not."
  (supertag-reference-capf-test--isolated
    (let ((source (expand-file-name "source.org" tmp)))
      (supertag-reference-capf-test--write-node source "source" "Source" "Body")
      (with-current-buffer (find-file-noselect source)
        (org-mode) (goto-char (point-max))
        (cl-flet ((bounds (text back)
                    (erase-buffer)
                    (insert text)
                    (goto-char (- (point-max) back))
                    (supertag-reference--get-prefix-bounds)))
          (let ((full (bounds "[[Emac]]" 2)))
            (should (equal "Emac" (buffer-substring-no-properties (car full) (cdr full))))
            (should (= (point) (cdr full))))
          (should (bounds "【【Emac】】" 2))
          ;; Description, known schemes and closed brackets stay untouched.
          (should-not (bounds "[[Emac][desc]]" 6))
          (should-not (bounds "[[id:emac]]" 2))
          (should-not (bounds "[[https://emac]]" 2))
          (should-not (bounds "[[Emac]] tail" 0)))))))

;;; A propertyless selection still commits.

(ert-deftest supertag-reference-capf-recovers-a-propertyless-existing-selection ()
  "Corfu may hand back the plain buffer text; the commit must still happen."
  (supertag-reference-capf-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "target.org" tmp)))
      (supertag-reference-capf-test--write-node source "source" "Source" "Body")
      (supertag-reference-capf-test--write-node target "target" "Target" "Body")
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-max))
        (insert "[[Targ")
        (let* ((capf (supertag-reference-capf-test--capf))
               (table (nth 2 capf))
               (row (supertag-reference-capf-test--candidate table nil "target.org")))
          (delete-region (nth 0 capf) (nth 1 capf))
          (insert row)
          (funcall (plist-get (nthcdr 3 capf) :exit-function)
                   (substring-no-properties row) 'finished)
          (should (equal "[[id:target][Target]]"
                         (supertag-reference-capf-test--link-text))))))))

(ert-deftest supertag-reference-capf-recovers-a-propertyless-create-title ()
  "A bare title that only matched the create row still creates the node."
  (supertag-reference-capf-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "concepts.org" tmp)))
      (supertag-reference-capf-test--write-node source "source" "Source" "Body")
      (with-current-buffer (find-file-noselect source)
        (goto-char (point-max))
        (insert "[[Fresh")
        (let ((capf (supertag-reference-capf-test--capf)))
          (cl-letf (((symbol-function 'supertag-template-read)
                     (lambda () (list :key "c" :name "Concept" :target-file target
                                      :tags nil :properties nil :body "")))
                    ((symbol-function 'supertag-node-identity-new)
                     (lambda () "fresh-id")))
            (delete-region (nth 0 capf) (nth 1 capf))
            (insert "Fresh")
            (funcall (plist-get (nthcdr 3 capf) :exit-function) "Fresh" 'finished)))
        (should (equal "[[id:fresh-id][Fresh]]"
                       (supertag-reference-capf-test--link-text)))))))

;;; Real Corfu, when its dependencies are on the load path.

(defmacro supertag-reference-capf-test--with-corfu (&rest body)
  "Run BODY with a real Corfu completion session in the current buffer."
  (declare (indent 0))
  `(progn
     (unless (and (require 'corfu nil t)
                  (or (require 'orderless nil t) t))
       (ert-skip "corfu is not on the load path"))
     (let ((completion-styles '(orderless basic))
           (orderless-matching-styles '(orderless-flex))
           (orderless-style-dispatchers '(orderless-affix-dispatch))
           (completion-category-overrides nil)
           (corfu-auto nil) (corfu-preselect 'prompt)
           ;; Keep the popup open so each test drives one UI command itself.
           (corfu-on-exact-match 'show))
       (cl-letf (((symbol-function 'corfu--popup-support-p) (lambda () t))
                 ((symbol-function 'corfu--popup-show) (lambda (&rest _) nil))
                 ((symbol-function 'corfu--popup-hide) (lambda (&rest _) nil)))
         ;; `corfu-mode' installs `corfu--capf-wrapper', which builds the
         ;; candidate state the popup commands operate on.
         (unwind-protect (progn (corfu-mode 1) ,@body)
           (corfu-mode -1))))))

(defun supertag-reference-capf-test--select (needle)
  "Open the popup and select the candidate matching NEEDLE."
  (completion-at-point)
  (setq corfu--index
        (or (cl-position-if (lambda (candidate)
                              (string-match-p (regexp-quote needle)
                                              (substring-no-properties candidate)))
                            corfu--candidates)
            (error "No candidate matching %s in %S" needle corfu--candidates))))

(ert-deftest supertag-reference-capf-corfu-completes-the-create-row ()
  "TAB on the `[Create new node]' row writes the canonical link."
  (supertag-reference-capf-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "concepts.org" tmp)))
      (supertag-reference-capf-test--write-node source "source" "Source" "Body")
      (with-current-buffer (find-file-noselect source)
        (org-mode) (goto-char (point-max))
        (insert "[[Fresh Concept")
        (supertag-reference-capf-test--capf)
        (supertag-reference-capf-test--with-corfu
          (cl-letf (((symbol-function 'supertag-template-read)
                     (lambda () (list :key "c" :name "Concept" :target-file target
                                      :tags nil :properties nil :body "")))
                    ((symbol-function 'supertag-node-identity-new)
                     (lambda () "fresh-id")))
            (supertag-reference-capf-test--select "Create new node")
            (corfu-complete)))
        (should (equal "[[id:fresh-id][Fresh Concept]]"
                       (supertag-reference-capf-test--link-text)))
        (should-not (buffer-modified-p))))))

(ert-deftest supertag-reference-capf-corfu-completes-a-multi-word-existing-row ()
  "TAB on an existing row with spaces in its title writes the link."
  (supertag-reference-capf-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (tips (expand-file-name "emacs-tips.org" tmp)))
      (supertag-reference-capf-test--write-node source "source" "Source" "Body")
      (supertag-reference-capf-test--write-node tips "tips" "Emacs Tips" "Body")
      (with-current-buffer (find-file-noselect source)
        (org-mode) (goto-char (point-max))
        (insert "[[Emacs Tips")
        (supertag-reference-capf-test--capf)
        (supertag-reference-capf-test--with-corfu
          (supertag-reference-capf-test--select "emacs-tips.org")
          (corfu-complete))
        (should (equal "[[id:tips][Emacs Tips]]"
                       (supertag-reference-capf-test--link-text)))
        (should-not (buffer-modified-p))))))

(ert-deftest supertag-reference-capf-corfu-expand-commits-a-unique-target ()
  "`corfu-expand' (no selected candidate) also commits."
  (supertag-reference-capf-test--isolated
    (let ((source (expand-file-name "source.org" tmp))
          (target (expand-file-name "target.org" tmp)))
      (supertag-reference-capf-test--write-node source "source" "Source" "Body")
      (supertag-reference-capf-test--write-node target "target" "Target" "Body")
      (with-current-buffer (find-file-noselect source)
        (org-mode) (goto-char (point-max))
        (insert "[[Targ")
        (supertag-reference-capf-test--capf)
        (supertag-reference-capf-test--with-corfu
          (completion-at-point)
          (corfu-expand))
        (should (equal "[[id:target][Target]]"
                       (supertag-reference-capf-test--link-text)))))))


(ert-deftest supertag-reference-capf-org-capture-keeps-link-until-finalize ()
  "Both openers and paired closers preserve real capture finalize/abort behavior."
  (dolist (finish '(finalize abort))
    (dolist (opener '("[[" "【【"))
      (supertag-reference-capf-test--isolated
       (let* ((source (expand-file-name "capture.org" tmp))
              (target (expand-file-name "concepts.org" tmp))
              (org-capture-templates
               `(("r" "Reference" entry (file ,source) "* Captured\n%?")))
              (org-capture-mode-hook nil)
              (org-capture-before-finalize-hook nil)
              (org-capture-prepare-finalize-hook nil)
              (org-capture-after-finalize-hook nil))
         (with-temp-file source (insert "#+title: Inbox\n"))
         (supertag-reference-capf-test--write-node target "pi-target" "Pi")
         (save-window-excursion
           (unwind-protect
               (progn
                 (org-capture nil "r")
                 (should org-capture-mode)
                 (should (buffer-base-buffer))
                 (should-not buffer-file-name)
                 (insert opener "Pi" (if (equal opener "[[") "]]" "】】"))
                 (backward-char 2)
                 (let* ((capf (supertag-reference-capf-test--capf))
                        (row (supertag-reference-capf-test--candidate
                              (nth 2 capf) nil "concepts.org")))
                   (should row)
                   (delete-region (nth 0 capf) (nth 1 capf))
                   (insert row)
                   (funcall (plist-get (nthcdr 3 capf) :exit-function)
                            (substring-no-properties row) 'finished))
                 (should (string-match-p (regexp-quote "[[id:pi-target][Pi]]")
                                         (buffer-string)))
                 (should org-capture-mode)
                 (should-not (save-excursion
                               (org-back-to-heading t) (org-entry-get nil "ID")))
                 (should (equal "#+title: Inbox\n"
                                (with-temp-buffer
                                  (insert-file-contents source) (buffer-string))))
                 (if (eq finish 'finalize)
                     (progn
                       (org-capture-finalize)
                       (should (string-match-p
                                (regexp-quote "[[id:pi-target][Pi]]")
                                (with-temp-buffer
                                  (insert-file-contents source) (buffer-string)))))
                   (org-capture-kill)
                   (should (equal "#+title: Inbox\n"
                                  (with-temp-buffer
                                    (insert-file-contents source) (buffer-string))))))
             (when (bound-and-true-p org-capture-mode)
               (org-capture-kill)))))))))

(ert-deftest supertag-reference-capf-org-capture-creates-target-not-source ()
  "Creating a new target is durable, but its capture source remains a draft."
  (supertag-reference-capf-test--isolated
   (let* ((source (expand-file-name "capture.org" tmp))
          (target (expand-file-name "concepts.org" tmp))
          (org-capture-templates
           `(("r" "Reference" entry (file ,source) "* Captured\n%?")))
          (org-capture-mode-hook nil)
          (org-capture-before-finalize-hook nil)
          (org-capture-prepare-finalize-hook nil)
          (org-capture-after-finalize-hook nil))
     (with-temp-file source (insert "#+title: Inbox\n"))
     (save-window-excursion
       (unwind-protect
           (progn
             (org-capture nil "r")
             (insert "【【Fresh")
             (let* ((capf (supertag-reference-capf-test--capf))
                    (row (supertag-reference-capf-test--candidate
                          (nth 2 capf) nil "Create new node")))
               (should row)
               (delete-region (nth 0 capf) (nth 1 capf))
               (insert row)
               (cl-letf (((symbol-function 'supertag-template-read)
                          (lambda () (list :key "c" :name "Concept"
                                           :target-file target :tags nil
                                           :properties nil :body "")))
                         ((symbol-function 'supertag-node-identity-new)
                          (lambda () "fresh-id")))
                 (funcall (plist-get (nthcdr 3 capf) :exit-function)
                          (substring-no-properties row) 'finished)))
             (should org-capture-mode)
             (should (string-match-p (regexp-quote "[[id:fresh-id][Fresh]]")
                                     (buffer-string)))
             (should (supertag-node-get "fresh-id"))
             (should (file-exists-p target))
             (should (equal "#+title: Inbox\n"
                            (with-temp-buffer
                              (insert-file-contents source) (buffer-string))))
             (org-capture-kill))
         (when (bound-and-true-p org-capture-mode)
           (org-capture-kill)))))))

(provide 'reference-capf-commit-test)
;;; reference-capf-commit-test.el ends here
