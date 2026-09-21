;;; sync-scope-symlink-test.el --- Sync scope through symlinks -*- lexical-binding: t; -*-
;; `supertag-sync--in-scope-path-p' must truename both the file path and every
;; configured directory, exactly like `supertag-git--truename-dir' does.  When
;; only the file was truenamed (`supertag-sync--run-on-save'), a
;; `supertag-sync-directories' entry reached through a symlink never matched and
;; after-save sync was dropped in silence while periodic scans kept working.
(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'supertag-services-sync)

(defmacro supertag-sync-scope-test--with-symlink (&rest body)
  "Run BODY with TMP holding REAL (a real directory) and LINK (a symlink to it)."
  (declare (indent 0) (debug t))
  `(let* ((tmp (file-name-as-directory (make-temp-file "supertag-sync-scope-test-" t)))
          (real (expand-file-name "real/" tmp))
          (link (expand-file-name "link" tmp)))
     (make-directory real t)
     (make-symbolic-link real link)
     (unwind-protect
         (progn ,@body)
       (dolist (buffer (buffer-list))
         (let ((file (buffer-file-name buffer)))
           (when (and file (string-prefix-p tmp file))
             (kill-buffer buffer))))
       (ignore-errors (delete-file link))
       (ignore-errors (delete-directory tmp t)))))

(ert-deftest supertag-sync-scope-symlinked-sync-directory-enqueues-on-save ()
  "A save under a symlinked sync directory reaches the async queue."
  (supertag-sync-scope-test--with-symlink
    (let* ((file (expand-file-name "note.org" real))
           (supertag-sync-directories (list link))
           (supertag-sync-directories-mode 'unified)
           (supertag-sync-exclude-directories nil)
           (supertag-sync--truename-directory-cache nil)
           (supertag-sync--internal-modifications (make-hash-table :test 'equal))
           (supertag-async--queue nil)
           (supertag-async--failed-items nil)
           (supertag-async--timer nil))
      (with-temp-file file (insert "* Note\nBody\n"))
      (with-current-buffer (find-file-noselect file)
        (org-mode)
        (setq-local after-save-hook nil)
        (supertag-sync-setup-realtime-hooks)
        (cl-letf (((symbol-function 'supertag-async--ensure-timer) #'ignore))
          (goto-char (point-max))
          (insert "Draft\n")
          (save-buffer))
        (should (member (file-truename file) supertag-async--queue))))))

(ert-deftest supertag-sync-scope-matches-through-symlinked-directory ()
  "Configured directories and exclusions are canonicalised in both directions."
  (supertag-sync-scope-test--with-symlink
    (let ((supertag-sync-directories (list link))
          (supertag-sync-directories-mode 'unified)
          (supertag-sync-exclude-directories nil)
          (supertag-sync--truename-directory-cache nil))
      (should (supertag-sync--in-scope-path-p (expand-file-name "note.org" real)))
      (should (supertag-sync--in-scope-path-p (expand-file-name "note.org" link)))
      (should-not (supertag-sync--in-scope-path-p (expand-file-name "note.txt" real))))
    (make-directory (expand-file-name "sub/" real) t)
    (let ((supertag-sync-directories (list link))
          (supertag-sync-directories-mode 'unified)
          ;; The exclusion is configured through the symlink, the file through
          ;; the real directory: only truenaming both sides excludes it.
          (supertag-sync-exclude-directories (list (expand-file-name "sub" link)))
          (supertag-sync--truename-directory-cache nil))
      (should (supertag-sync--in-scope-path-p (expand-file-name "note.org" real)))
      (should-not (supertag-sync--in-scope-path-p (expand-file-name "sub/note.org" real)))
      (should-not (supertag-sync--in-scope-path-p (expand-file-name "sub/note.org" link))))))

(ert-deftest supertag-sync-scope-does-not-require-the-file-to-exist ()
  "The predicate still answers for paths that are not on disk."
  (supertag-sync-scope-test--with-symlink
    (let* ((supertag-sync-directories (list link))
           (supertag-sync-directories-mode 'unified)
           (supertag-sync-exclude-directories nil)
           (supertag-sync--truename-directory-cache nil)
           (ghost (expand-file-name "draft/ghost.org" link))
           (outside (expand-file-name "ghost.org" (expand-file-name "outside/" tmp))))
      (should-not (file-exists-p ghost))
      (should-not (file-exists-p outside))
      (should (supertag-sync--in-scope-path-p ghost))
      (should-not (supertag-sync--in-scope-path-p outside))
      ;; Missing leaves do not stop `file-truename' from resolving the
      ;; symlinked ancestors the scope decision depends on.
      (should (string-prefix-p (file-name-as-directory (file-truename real))
                               (file-truename ghost))))))

(ert-deftest supertag-sync-scope-truenames-directories-once-per-scan ()
  "Directory canonicalisation is cached across the files of a scan."
  (supertag-sync-scope-test--with-symlink
    (let* ((supertag-sync-directories (list link))
           (supertag-sync-directories-mode 'unified)
           (supertag-sync-exclude-directories nil)
           (supertag-sync--truename-directory-cache nil)
           (dir-calls 0)
           (depth 0)
           (real-truename (symbol-function 'file-truename))
           (files (mapcar (lambda (n) (expand-file-name (format "note-%d.org" n) real))
                          (number-sequence 0 4)))
           ;; `file-truename' recurses into itself for every path component, so
           ;; only outermost calls are counted: one per canonicalisation.
           (handler (lambda (name &rest args)
                      (let ((outermost (zerop depth)))
                        (setq depth (1+ depth))
                        (prog1 (progn
                                 (when (and outermost
                                            (let ((normalised (file-name-as-directory name)))
                                              (or (equal normalised (file-name-as-directory link))
                                                  (equal normalised (file-name-as-directory real)))))
                                   (setq dir-calls (1+ dir-calls)))
                                 (apply real-truename name args))
                          (setq depth (1- depth)))))))
      (cl-letf (((symbol-function 'file-truename) handler))
        ;; With a cold cache every file pays for the directory: this is the
        ;; cost the cache must remove, not a property of the call count itself.
        (dolist (file files)
          (setq supertag-sync--truename-directory-cache nil)
          (should (supertag-sync--in-scope-path-p file)))
        (should (= 5 dir-calls))
        ;; One scan over the same configured list resolves it once.
        (setq dir-calls 0
              supertag-sync--truename-directory-cache nil)
        (dolist (file files)
          (should (supertag-sync--in-scope-path-p file)))
        (should (= 1 dir-calls))
        ;; A different configured list is a different cache key.
        (setq dir-calls 0)
        (let ((supertag-sync-directories (list real)))
          (should (supertag-sync--in-scope-path-p (car files)))
          (should (= 1 dir-calls)))))))

;;; sync-scope-symlink-test.el ends here
