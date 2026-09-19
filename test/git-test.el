;;; git-test.el --- Isolated Org Git transport contracts -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-git)

(defun supertag-git-test-run (root &rest args)
  (let ((result (apply #'supertag-git--run root args)))
    (should (equal 0 (car result)))
    (cdr result)))

(defun supertag-git-test-write (root name text)
  (let ((path (expand-file-name name root)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path (insert text))))

(defun supertag-git-test-commit (root)
  (supertag-git-test-run root "add" "-A" "--" "*.org")
  (supertag-git-test-run root "commit" "-m" "Synthetic Org edit"))

(defmacro supertag-git-test-with-vault (&rest body)
  (declare (indent 0))
  `(supertag-document-test-with-vault
     (let* ((root (expand-file-name "vault/" tmp))
            (bare (expand-file-name "remote.git/" tmp))
            (peer (expand-file-name "peer/" tmp))
            (process-environment (copy-sequence process-environment))
            (default-directory tmp)
            (supertag-git-sync--synchronous t)
            (supertag-git-sync-mode nil)
            (supertag-git-sync--vault-root nil)
            (supertag-git-sync--pull-timer nil) (supertag-git-sync--commit-timer nil)
            (supertag-git-sync--exit-wait-timer nil) (supertag-git-sync--in-flight nil)
            (supertag-git-sync--pending-push-count 0)
            (supertag-git--conflicted-files nil)
            (supertag-git-sync--offline-warned nil)
            (supertag-git-sync--conflict-commit-warned nil)
            (supertag--config-guard-allow t))
       (setenv "HOME" (expand-file-name "home/" tmp))
       (make-directory (getenv "HOME") t)
       (setenv "GIT_CONFIG_GLOBAL" "/dev/null") (setenv "GIT_CONFIG_NOSYSTEM" "1")
       (setenv "GIT_TERMINAL_PROMPT" "0")
       (setenv "GIT_AUTHOR_NAME" "Supertag Test") (setenv "GIT_COMMITTER_NAME" "Supertag Test")
       (setenv "GIT_AUTHOR_EMAIL" "test@example.invalid") (setenv "GIT_COMMITTER_EMAIL" "test@example.invalid")
       (make-directory root t) (make-directory bare t)
       (supertag-git-test-run root "init" "-q" "-b" "main")
       (supertag-git-test-run bare "init" "-q" "--bare" "--initial-branch=main")
       (supertag-git-test-run root "config" "commit.gpgsign" "false")
       (rename-file file (expand-file-name "note.org" root))
       (setq file (expand-file-name "note.org" root)
             supertag-sync-directories (list root)
             supertag-active-sync-directory root)
       (supertag-git-test-write root "unchanged.org" "* Stable\n:PROPERTIES:\n:ID: stable\n:END:\nUnchanged.\n")
       (supertag-git-test-write root "delete.org" "* Delete\n:PROPERTIES:\n:ID: deleted\n:END:\nDelete.\n")
       (supertag-git-test-commit root)
       (supertag-git-test-run root "remote" "add" "origin" bare)
       (supertag-git-test-run root "push" "-u" "origin" "main")
       (supertag-git-test-run tmp "clone" bare peer)
       (supertag-git-test-run peer "config" "commit.gpgsign" "false")
       (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
       (setq supertag-async--queue nil)
       (unwind-protect (progn ,@body)
         (supertag-git--cancel-timers)
         (supertag-git-sync-mode -1)))))

(ert-deftest supertag-git-org-only-setup-and-root-independence ()
  (supertag-git-test-with-vault
    (let ((db supertag-db-file))
      (supertag-git-test-write root "credential.txt" "synthetic secret")
      (supertag-git-test-write root ".supertag/supertag-db.el" "cache")
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
        (supertag-git-setup))
      (should (equal db supertag-db-file))
      (should-not (file-exists-p (expand-file-name ".gitattributes" root)))
      (should-not (supertag-git--get-config root "merge.supertag-db.driver"))
      (should (plist-get (supertag-git-check) :org-only-p))
      (should (member ".gitignore" (supertag-git--tracked-files root)))
      (let ((supertag-sync-directories (list root peer)))
        (should-error (supertag-git-setup) :type 'user-error))
      (let ((supertag-sync-directories nil))
        (should-error (supertag-git-setup) :type 'user-error)))))

(ert-deftest supertag-git-setup-untracks-old-cache-only-after-confirmation ()
  (supertag-git-test-with-vault
    (supertag-git-test-write root ".supertag/supertag-db.el" "old DB")
    (supertag-git-test-write root ".gitattributes" "*.el merge=supertag-db\n")
    (supertag-git-test-run root "add" "--" ".supertag/supertag-db.el" ".gitattributes")
    (supertag-git-test-run root "commit" "-m" "Old layout")
    (let ((head (supertag-git-test-run root "rev-parse" "HEAD")))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (should-error (supertag-git-setup) :type 'user-error))
      (should (equal head (supertag-git-test-run root "rev-parse" "HEAD"))))
    (let ((count 0))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (cl-incf count) t))
                ((symbol-function 'read-string) (lambda (&rest _) "")))
        (supertag-git-setup))
      (should (= count 1)))
    (should-not (supertag-git--retired-tracked root))
    (should (file-exists-p (expand-file-name ".supertag/supertag-db.el" root)))
    (should (file-exists-p (expand-file-name ".gitattributes" root)))))

(ert-deftest supertag-git-clone-rebuilds-org-not-remote-db ()
  (supertag-git-test-with-vault
    (supertag-git-test-write root ".supertag/supertag-db.el" "not a database")
    (supertag-git-test-run root "add" ".supertag/supertag-db.el")
    (supertag-git-test-run root "commit" "-m" "Legacy remote cache")
    (supertag-git-test-run root "push")
    (let ((db supertag-db-file) (dest (expand-file-name "new/" tmp)))
      ;; Initialize this local Store as startup does; never load the cloned DB.
      (supertag-load-store)
      (cl-letf (((symbol-function 'supertag-load-store) (lambda (&rest _) (ert-fail "Remote DB loaded"))))
        (should (plist-get (supertag-git-clone bare dest) :rebuilt)))
      (should (equal supertag-db-file db))
      (should (file-exists-p db))
      (should (equal (file-truename (expand-file-name "note.org" dest))
                     (plist-get (supertag-node-get "document-node") :file))))))

(ert-deftest supertag-git-pull-projects-exact-delta-and-orphans-deletion ()
  (supertag-git-test-with-vault
    (supertag-git-sync-mode 1)
    (supertag-git-test-write peer "note.org" "* Changed\n:PROPERTIES:\n:ID: document-node\n:END:\nChanged body.\n")
    (delete-file (expand-file-name "delete.org" peer))
    (supertag-git-test-write peer "nested/new.org" "* Added\n:PROPERTIES:\n:ID: added\n:END:\nNew.\n")
    (supertag-git-test-commit peer) (supertag-git-test-run peer "push")
    (should (supertag-git-sync-now))
    (should (equal (sort (mapcar #'file-name-nondirectory supertag-async--queue) #'string<)
                   '("new.org" "note.org")))
    (should-not (supertag-find-nodes-by-file (expand-file-name "delete.org" root)))
    (should-not (plist-get (supertag-node-get "deleted") :file))
    (should (plist-get (supertag-node-get "deleted") :orphaned-at))
    (supertag-document-test-drain)
    (should (equal "Changed" (plist-get (supertag-node-get "document-node") :title)))
    (should (supertag-node-get "added"))
    (should (equal "Stable" (plist-get (supertag-node-get "stable") :title)))))

(defun supertag-git-test-conflict (root peer)
  (supertag-git-test-write root "note.org" "* Local\n:PROPERTIES:\n:ID: document-node\n:END:\nLocal.\n")
  (supertag-git-test-commit root)
  (supertag-git-test-write peer "note.org" "* Remote\n:PROPERTIES:\n:ID: document-node\n:END:\nRemote.\n")
  (supertag-git-test-commit peer) (supertag-git-test-run peer "push"))

(ert-deftest supertag-git-conflict-pauses-and-explicit-resolution-resumes ()
  (supertag-git-test-with-vault
    (supertag-git-sync-mode 1)
    (supertag-git-test-conflict root peer)
    (supertag-git-sync--schedule-commit)
    (supertag-git-sync-now)
    (should supertag-git-sync-mode)
    (should supertag-git--conflicted-files)
    (should-not supertag-git-sync--pull-timer) (should-not supertag-git-sync--commit-timer)
    (should (string-match-p "!" (supertag-git-sync--lighter)))
    (with-current-buffer (get-file-buffer file) (should smerge-mode))
    (should-not (supertag-git-sync-now))
    (should (equal "Property Node" (plist-get (supertag-node-get "document-node") :title)))
    (with-current-buffer (get-file-buffer file)
      (erase-buffer)
      (insert "* Local\n:PROPERTIES:\n:ID: document-node\n:END:\nLocal.\n")
      (should-not (supertag-git-sync-now))
      (save-buffer))
    (should (supertag-git-sync-now))
    (should-not supertag-git--conflicted-files)
    (should (timerp supertag-git-sync--pull-timer))
    (should-not (supertag-git-sync--unmerged-paths root))
    (supertag-document-test-drain)
    (should (equal "Local" (plist-get (supertag-node-get "document-node") :title)))
    (should (= 0 (supertag-git-sync--rev-count root "@{upstream}..HEAD")))))

(ert-deftest supertag-git-cold-unmerged-enable-pauses ()
  (supertag-git-test-with-vault
    (supertag-git-test-conflict root peer)
    (supertag-git-test-run root "fetch")
    (should-not (supertag-git--ok-p (supertag-git--run root "merge" "--no-edit" "@{upstream}")))
    (supertag-git-sync-mode 1)
    (should supertag-git--conflicted-files)
    (should-not supertag-git-sync--pull-timer)
    (with-current-buffer (get-file-buffer file) (should smerge-mode))))

(ert-deftest supertag-git-staging-scope-debounce-disable-and-symlink ()
  (supertag-git-test-with-vault
    (let ((alias (expand-file-name "alias" tmp)))
      (make-symbolic-link root alias)
      (let ((supertag-sync-directories (list alias)))
        (should (equal (plist-get (supertag-git-check) :repo-root) (file-truename root)))))
    (supertag-git-sync-mode 1)
    (supertag-git-sync--schedule-commit)
    (let ((timer supertag-git-sync--commit-timer))
      (supertag-git-sync--schedule-commit)
      (should-not (eq timer supertag-git-sync--commit-timer)))
    (supertag-git-test-write root "credentials.txt" "synthetic only")
    (supertag-git-test-run root "add" "credentials.txt")
    (let ((index (supertag-git-test-run root "diff" "--cached")))
      (supertag-git-sync--fire-commit)
      (should (equal index (supertag-git-test-run root "diff" "--cached"))))
    (supertag-git-test-run root "reset" "--" "credentials.txt")
    (supertag-git-test-write root "nested/new.org" "* Added\n")
    (supertag-git-sync--schedule-commit)
    (supertag-git-sync-mode -1)
    (should-not supertag-git-sync--pull-timer) (should-not supertag-git-sync--commit-timer)
    (should (member "nested/new.org" (supertag-git--tracked-files root)))
    (should-not (member "credentials.txt" (supertag-git--tracked-files root)))))

(ert-deftest supertag-git-offline-commit-and-catchup-restart ()
  (supertag-git-test-with-vault
    (supertag-git-sync-mode 1)
    (supertag-git-test-run root "remote" "set-url" "origin" (expand-file-name "missing.git" tmp))
    (supertag-git-test-write root "new.org" "* Offline\n")
    (supertag-git-sync--fire-commit)
    (should-not supertag-git-sync--in-flight)
    (should (> supertag-git-sync--pending-push-count 0))
    (supertag-git-test-run root "remote" "set-url" "origin" bare)
    (supertag-git-sync-mode -1)
    (supertag-git-sync-mode 1)
    (should (= 0 supertag-git-sync--pending-push-count))
    (should (= 0 (supertag-git-sync--rev-count root "@{upstream}..HEAD")))))

(ert-deftest supertag-git-rejected-push-fetches-merges-and-retries ()
  (supertag-git-test-with-vault
    (supertag-git-sync-mode 1)
    (supertag-git-test-write peer "remote.org" "* Remote\n")
    (supertag-git-test-commit peer) (supertag-git-test-run peer "push")
    (supertag-git-test-write root "local.org" "* Local\n")
    (let ((runner (symbol-function 'supertag-git-sync--run-git)) (pushes 0))
      (cl-letf (((symbol-function 'supertag-git-sync--run-git)
                 (lambda (dir args callback)
                   (when (equal (car args) "push") (cl-incf pushes))
                   (funcall runner dir args callback))))
        (supertag-git-sync--fire-commit))
      (should (= pushes 2)))
    (should-not supertag-git-sync--in-flight)
    (should (file-exists-p (expand-file-name "remote.org" root)))
    (should (= 0 (supertag-git-sync--rev-count root "@{upstream}..HEAD")))))
(ert-deftest supertag-git-repair-chinese-conflict-pauses ()
  (supertag-git-test-with-vault
    (supertag-git-test-write root "中文.org" "* Base\n")
    (supertag-git-test-commit root) (supertag-git-test-run root "push")
    (supertag-git-test-run peer "pull" "--no-edit")
    (supertag-git-sync-mode 1)
    (supertag-git-test-write root "中文.org" "* Local\n")
    (supertag-git-test-commit root)
    (supertag-git-test-write peer "中文.org" "* Remote\n")
    (supertag-git-test-commit peer) (supertag-git-test-run peer "push")
    (supertag-git-sync-now)

    (should supertag-git--conflicted-files)))

(ert-deftest supertag-git-repair-continue-rejects-extra-staged-markers ()
  (supertag-git-test-with-vault
    (supertag-git-sync-mode 1)
    (supertag-git-test-conflict root peer)
    (supertag-git-sync-now)
    (should supertag-git--conflicted-files)
    (with-current-buffer (get-file-buffer file)
      (erase-buffer) (insert "* Resolved\n:PROPERTIES:\n:ID: document-node\n:END:\n") (save-buffer))
    (supertag-git-test-write root "extra.org" "<<<<<<< HEAD\nsecret local\n=======\nremote\n>>>>>>> incoming\n")
    (supertag-git-test-run root "add" "extra.org")
    (let ((head (supertag-git-test-run root "rev-parse" "HEAD"))
          (index (supertag-git-test-run root "diff" "--cached")))
      (let ((err (should-error (supertag-git-sync-now) :type 'user-error)))
        (should (string-match-p "extra.org" (error-message-string err))))
      (should supertag-git--conflicted-files)
      (should (equal index (supertag-git-test-run root "diff" "--cached")))
      (should (equal head (supertag-git-test-run root "rev-parse" "HEAD"))))))

(ert-deftest supertag-git-repair-clone-excludes-backup-org ()
  (supertag-git-test-with-vault
    (supertag-load-store)
    (let ((dest (expand-file-name "clone/" tmp)))
      (supertag-git-clone bare dest)
      (supertag-git-test-write dest "backups/private.org" "* Synthetic backup only\n")
      (supertag-git-sync-mode 1)
      (supertag-git-sync-now)

      (should-not (member "backups/private.org" (supertag-git--tracked-files dest))))))

(ert-deftest supertag-git-repair-setup-excludes-tracked-backup-org ()
  (supertag-git-test-with-vault
    (supertag-git-test-write root "backups/private.org" "* Old backup\n")
    (supertag-git-test-commit root)
    (supertag-git-test-write root "backups/private.org" "* New backup\n")
    (supertag-git-sync-mode 1)
    (let (messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages))))
        (supertag-git-sync-now))
      (should (cl-some (lambda (m) (string-match-p "supertag-git-setup" m)) messages)))
    (should (equal "* Old backup" (supertag-git-test-run root "show" "HEAD:backups/private.org")))))

(ert-deftest supertag-git-repair-fire-marker-control ()
  (supertag-git-test-with-vault
    (supertag-git-sync-mode 1)
    (supertag-git-test-write root "extra.org" "<<<<<<< HEAD\nlocal\n=======\nremote\n>>>>>>> other\n")
    (let ((head (supertag-git-test-run root "rev-parse" "HEAD")))
      (supertag-git-sync-now)
      (should (equal head (supertag-git-test-run root "rev-parse" "HEAD"))))))

(ert-deftest supertag-git-repair-renamed-file-removed-node-orphaned ()
  (supertag-git-test-with-vault
    (let ((text (mapconcat (lambda (n) (format "* Node %d\n:PROPERTIES:\n:ID: rename-%d\n:END:\nStable content with sufficient lines for rename detection.\n" n n))
                           (number-sequence 0 19) "")))
      (supertag-git-test-write root "rename.org" text)
      (supertag-git-test-commit root) (supertag-git-test-run root "push")
      (supertag-git-test-run peer "pull" "--no-edit")
      (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
      (supertag-git-sync-mode 1)
      (supertag-git-test-run peer "mv" "rename.org" "renamed.org")
      (supertag-git-test-write peer "renamed.org"
        (mapconcat (lambda (n) (format "* Node %d\n:PROPERTIES:\n:ID: rename-%d\n:END:\nStable content with sufficient lines for rename detection.\n" n n))
                   (number-sequence 1 19) ""))
      (supertag-git-test-commit peer) (supertag-git-test-run peer "push")
      (supertag-git-sync-now)

      (supertag-document-test-drain)

      (should-not (plist-get (supertag-node-get "rename-0") :file))
      (should (plist-get (supertag-node-get "rename-0") :orphaned-at))
      (should-not (supertag-find-nodes-by-file (expand-file-name "rename.org" root)))
      (dolist (n (number-sequence 1 19))
        (should (equal (plist-get (supertag-node-get (format "rename-%d" n)) :file)
                       (file-truename (expand-file-name "renamed.org" root))))))))

(ert-deftest supertag-git-repair-conflict-pathspec-is-literal ()
  (supertag-git-test-with-vault
    (supertag-git-test-write root "[ab].org" "* Base\n")
    (supertag-git-test-write root "a.org" "* Unrelated\n")
    (supertag-git-test-commit root) (supertag-git-test-run root "push")
    (supertag-git-test-run peer "pull" "--no-edit")
    (supertag-git-sync-mode 1)
    (supertag-git-test-write root "[ab].org" "* Local\n")
    (supertag-git-test-commit root)
    (supertag-git-test-write peer "[ab].org" "* Remote\n")
    (supertag-git-test-commit peer) (supertag-git-test-run peer "push")
    (supertag-git-sync-now)
    (with-current-buffer (get-file-buffer (expand-file-name "[ab].org" root))
      (erase-buffer) (insert "* Resolved\n") (save-buffer))
    (supertag-git-test-write root "a.org" "* Unrelated pending draft on disk\n")
    (let ((result (condition-case err (supertag-git-sync-now) (error err))))

      (should (eq result t))
      (should (equal "* Unrelated" (supertag-git-test-run root "show" "HEAD:a.org"))))))

(ert-deftest supertag-git-repair-conflict-magic-never-stages-credentials ()
  (supertag-git-test-with-vault
    (supertag-git-test-write root ":(exclude).org" "* Base\n")
    (supertag-git-test-commit root) (supertag-git-test-run root "push")
    (supertag-git-test-run peer "pull" "--no-edit")
    (supertag-git-sync-mode 1)
    (supertag-git-test-write root ":(exclude).org" "* Local\n")
    (supertag-git-test-commit root)
    (supertag-git-test-write peer ":(exclude).org" "* Remote\n")
    (supertag-git-test-commit peer) (supertag-git-test-run peer "push")
    (supertag-git-sync-now)
    (with-current-buffer (get-file-buffer (expand-file-name ":(exclude).org" root))
      (erase-buffer) (insert "* Resolved\n") (save-buffer))
    (supertag-git-test-write root "credentials.txt" "SYNTHETIC SECRET ONLY")
    (let ((runner (symbol-function 'supertag-git-sync--run-git)) (add-checked nil))
      (cl-letf (((symbol-function 'supertag-git-sync--run-git)
                 (lambda (dir args callback)
                   (funcall runner dir args
                            (lambda (result)
                              (when (equal (car args) "add")
                                (setq add-checked t)
                                (should-not (member "credentials.txt" (supertag-git--tracked-files dir))))
                              (funcall callback result))))))
        (should (supertag-git-sync-now)))
      (should add-checked)
      (should-not (supertag-git--ok-p (supertag-git--run root "show" "HEAD:credentials.txt")))
      (should-not (supertag-git--ok-p (supertag-git--run bare "show" "HEAD:credentials.txt")))
      (should-not (member "credentials.txt" (supertag-git--tracked-files root))))))



(defun supertag-git-test-named-conflict (root peer name)
  "Create a real conflict at literal NAME in the isolated pair."
  (supertag-git-test-write root name "* Base\n")
  (supertag-git-test-commit root) (supertag-git-test-run root "push")
  (supertag-git-test-run peer "pull" "--no-edit")
  (supertag-git-test-write root name "* Local\n")
  (supertag-git-test-commit root)
  (supertag-git-test-write peer name "* Remote\n")
  (supertag-git-test-commit peer) (supertag-git-test-run peer "push"))

(ert-deftest supertag-git-repair-unusual-conflicts-live-and-cold ()
  (dolist (name '("中文.org" "space quote\" tab\t.org" "line\nbreak.org" " leading.org"))
    (dolist (cold '(nil t))
      (supertag-git-test-with-vault
        (supertag-git-test-named-conflict root peer name)
        (if cold
            (progn
              (supertag-git-test-run root "fetch")
              (should-not (supertag-git--ok-p
                           (supertag-git--run root "merge" "--no-edit" "@{upstream}")))
              (supertag-git-sync-mode 1))
          ;; Enable before the fetch/merge, without pushing the divergent head.
          (cl-letf (((symbol-function 'supertag-git-sync--maybe-push-after-cycle)
                     (lambda (_) (setq supertag-git-sync--in-flight nil))))
            (supertag-git-sync-mode 1))
          (supertag-git-sync-now))
        (should (equal (supertag-git-sync--unmerged-paths root) (list name)))
        (should (member (file-truename (expand-file-name name root)) supertag-git--conflicted-files))
        (should-not supertag-git-sync--pull-timer)))))

(ert-deftest supertag-git-repair-post-add-scope-restores-index ()
  (dolist (continuing '(nil t))
    (supertag-git-test-with-vault
      (supertag-git-sync-mode 1)
      (when continuing
        (supertag-git-test-conflict root peer) (supertag-git-sync-now)
        (with-current-buffer (get-file-buffer file)
          (erase-buffer) (insert "* Saved resolution\n") (save-buffer)))
      (supertag-git-test-write root "extra.org" "* Pre-staged user content\n")
      (supertag-git-test-run root "add" "extra.org")
      (supertag-git-test-write root "credentials.txt" "SYNTHETIC ONLY")
      (let ((index (supertag-git-test-run root "ls-files" "--stage" "-z"))
            (head (supertag-git-test-run root "rev-parse" "HEAD"))
            (runner (symbol-function 'supertag-git-sync--run-git)) (commits 0) (pushes 0))
        (cl-letf (((symbol-function 'supertag-git-sync--run-git)
                   (lambda (dir args callback)
                     (when (equal (car args) "commit") (cl-incf commits))
                     (when (equal (car args) "push") (cl-incf pushes))
                     (funcall runner dir args
                              (lambda (result)
                                (when (equal (car args) "add")
                                  (supertag-git-test-run dir "add" "--" ":(literal)credentials.txt"))
                                (funcall callback result))))))
          (condition-case nil (supertag-git-sync-now) (user-error nil)))
        (should (= commits 0)) (should (= pushes 0))
        (should (equal head (supertag-git-test-run root "rev-parse" "HEAD")))
        (should (equal index (supertag-git-test-run root "ls-files" "--stage" "-z")))
        (when continuing (should supertag-git--conflicted-files))))))

(ert-deftest supertag-git-repair-local-data-shared-exclusion ()
  (supertag-git-test-with-vault
    (let ((supertag-data-directory (expand-file-name "private-data/" root))
          (supertag-db-backup-directory (expand-file-name "private-backup/" root))
          (supertag-sync-state-file (expand-file-name "state.org" root)))
      (dolist (path '("private-data/cache.org" "private-backup/copy.org" "state.org" ".supertag/cache.org"))
        (supertag-git-test-write root path "* Local only\n")
        (should (supertag-git--local-data-path-p root path))
        (should-not (supertag-git-sync--auto-commit-path-p root path)))
      (make-symbolic-link supertag-data-directory (expand-file-name "alias-data" root))
      (should-not (supertag-git-sync--auto-commit-path-p root "alias-data/cache.org"))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
        (supertag-git-setup))
      (should-not (cl-intersection '("private-data/cache.org" "private-backup/copy.org" "state.org" ".supertag/cache.org")
                                  (supertag-git--tracked-files root) :test #'equal))
      ;; Historically tracked exclusions are retained until explicit setup approval.
      (supertag-git-test-run root "add" "-f" "--" ":(literal)private-backup/copy.org")
      (supertag-git-test-run root "commit" "-m" "Synthetic historical tracking")
      (let ((index (supertag-git-test-run root "ls-files" "--stage" "-z")))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
          (should-error (supertag-git-setup) :type 'user-error))
        (should (equal index (supertag-git-test-run root "ls-files" "--stage" "-z"))))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'read-string) (lambda (&rest _) "")))
        (supertag-git-setup))
      (should-not (member "private-backup/copy.org" (supertag-git--tracked-files root)))
      (should (file-exists-p (expand-file-name "private-backup/copy.org" root))))))

(ert-deftest supertag-git-repair-pure-rename-preserves-identities ()
  (supertag-git-test-with-vault
    (supertag-git-sync-mode 1)
    (supertag-git-test-run peer "mv" "note.org" "renamed.org")
    (supertag-git-test-commit peer) (supertag-git-test-run peer "push")
    (supertag-git-sync-now) (supertag-document-test-drain)
    (should-not (supertag-find-nodes-by-file file))
    (should (equal (plist-get (supertag-node-get "document-node") :file)
                   (file-truename (expand-file-name "renamed.org" root))))))

(ert-deftest supertag-git-retained-exit-sync-wait-failure ()
  (supertag-git-test-with-vault
    (supertag-git-sync-mode 1)
    (should (supertag-git-sync--query-exit))
    (supertag-git-test-write root "exit.org" "* Save before exit\n")
    (let (wait-callback exit-called)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                ((symbol-function 'run-with-timer)
                 (lambda (_secs _repeat fn &rest args)
                   (setq wait-callback (lambda () (apply fn args))) nil))
                ((symbol-function 'save-buffers-kill-emacs)
                 (lambda (&rest _) (setq exit-called t))))
        (should-not (supertag-git-sync--query-exit))
        (should wait-callback) (funcall wait-callback) (should exit-called)
        (setq exit-called nil wait-callback nil)
        (let ((supertag-git-sync--in-flight t))
          (should-not (supertag-git-sync--query-exit))
          (should wait-callback) (funcall wait-callback) (should-not exit-called))
        (supertag-git-test-write root "exit.org" "* Failure leaves work\n")
        (supertag-git-test-run root "remote" "set-url" "origin" (expand-file-name "missing.git" tmp))
        (should-not (supertag-git-sync--query-exit))
        (funcall wait-callback) (should-not exit-called)
        (should-not supertag-git-sync--exit-wait-timer)))))

(ert-deftest supertag-git-retained-modify-delete-symlink-and-teardown ()
  (supertag-git-test-with-vault
    (supertag-git-sync-mode 1)
    (supertag-git-test-write root "note.org" "* Local edit\n") (supertag-git-test-commit root)
    (supertag-git-test-run peer "rm" "note.org")
    (supertag-git-test-run peer "commit" "-m" "Remote deletes") (supertag-git-test-run peer "push")
    (supertag-git-sync-now)
    (should-not (supertag-git-sync--file-has-conflict-markers-p file))
    (should supertag-git--conflicted-files)
    (let ((alias (expand-file-name "alias" tmp)) (calls 0))
      (make-symbolic-link root alias)
      (supertag-git-sync--skip-conflicted-file-advice
       (lambda (&rest _) (cl-incf calls)) (expand-file-name "note.org" alias))
      (should (= calls 0)))
    (supertag-git-sync--schedule-exit-after-sync)
    (supertag-git-sync-mode -1)
    (dolist (symbol '(supertag-git-sync--pull-timer supertag-git-sync--commit-timer supertag-git-sync--exit-wait-timer))
      (should-not (symbol-value symbol)))
    (should-not (memq #'supertag-git-sync--on-file-saved after-save-hook))
    (should-not (memq #'supertag-git-sync--query-exit kill-emacs-query-functions))
    (should-not (advice-member-p #'supertag-git-sync--maybe-focus-pull after-focus-change-function))
    (should-not (advice-member-p #'supertag-git-sync--skip-conflicted-file-advice 'supertag-sync--process-single-file))))

(ert-deftest supertag-git-retained-offline-diagnostic-once ()
  (supertag-git-test-with-vault
    (supertag-git-sync-mode 1)
    (supertag-git-test-run root "remote" "set-url" "origin" (expand-file-name "missing.git" tmp))
    (let (messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (supertag-git-sync-now) (supertag-git-sync-now))
      (should (= 1 (cl-count-if (lambda (m) (string-match-p "Automatic retry remains enabled" m)) messages))))))

(ert-deftest supertag-git-retained-diverged-pull-cycle ()
  (supertag-git-test-with-vault
    (supertag-git-sync-mode 1)
    (supertag-git-test-write root "local.org" "* Local\n") (supertag-git-test-commit root)
    (supertag-git-test-write peer "remote.org" "* Remote\n")
    (supertag-git-test-commit peer) (supertag-git-test-run peer "push")
    (supertag-git-sync-now)
    (should (file-exists-p (expand-file-name "remote.org" root)))
    (should (supertag-git--ok-p (supertag-git--run bare "show" "HEAD:local.org")))
    (should (= 0 supertag-git-sync--pending-push-count))
    (should-not supertag-git-sync--in-flight)))


;;; A pull must not silently fail on saved-but-uncommitted Org edits.

(defun supertag-git-dirty-merge--base (root)
  "Write the shared base NOTE.ORG that both sides branch from."
  (supertag-git-test-write
   root "note.org"
   (concat "* Property Node\n:PROPERTIES:\n:ID: document-node\n:END:\n"
           "alpha line\n"
           "middle one\nmiddle two\nmiddle three\nmiddle four\n"
           "beta line\n")))

(ert-deftest supertag-git-dirty-merge-commits-saved-edits-before-merging ()
  "Saved-but-uncommitted Org edits are committed first, so the pull's merge
is a real three-way merge instead of the refusal that used to be silent."
  (supertag-git-test-with-vault
    (let ((supertag-git-sync--merge-refused-warned nil))
      (supertag-git-dirty-merge--base root)
      (supertag-git-test-commit root) (supertag-git-test-run root "push")
      (supertag-git-test-run peer "pull" "--no-edit")
      (supertag-git-sync-mode 1)
      ;; The peer moves one line and pushes it.
      (supertag-git-test-write
       peer "note.org"
       (concat "* Property Node\n:PROPERTIES:\n:ID: document-node\n:END:\n"
               "alpha peer\n"
               "middle one\nmiddle two\nmiddle three\nmiddle four\n"
               "beta line\n"))
      (supertag-git-test-commit peer) (supertag-git-test-run peer "push")
      ;; The user's edit to the other line is saved but not yet committed:
      ;; exactly the auto-commit debounce window.
      (supertag-git-test-write
       root "note.org"
       (concat "* Property Node\n:PROPERTIES:\n:ID: document-node\n:END:\n"
               "alpha line\n"
               "middle one\nmiddle two\nmiddle three\nmiddle four\n"
               "beta local\n"))
      (should (supertag-git-sync--owned-changes-p root))
      (supertag-git-sync--pull)
      (should-not supertag-git-sync--in-flight)
      (should-not supertag-git--conflicted-files)
      (should (equal "" (string-trim (supertag-git-test-run root "status" "--porcelain"))))
      (should (= 0 (supertag-git-sync--rev-count root "@{upstream}..HEAD")))
      (let ((head (supertag-git-test-run root "show" "HEAD:note.org")))
        (should (string-match-p "alpha peer" head))
        (should (string-match-p "beta local" head)))
      (supertag-document-test-drain))))

(ert-deftest supertag-git-dirty-merge-pauses-on-an-overlapping-edit ()
  "With the local edit committed first, overlapping edits reach the normal
conflict pause instead of a silent no-op."
  (supertag-git-test-with-vault
    (let ((supertag-git-sync--merge-refused-warned nil))
      (supertag-git-dirty-merge--base root)
      (supertag-git-test-commit root) (supertag-git-test-run root "push")
      (supertag-git-test-run peer "pull" "--no-edit")
      (supertag-git-sync-mode 1)
      (supertag-git-test-write
       peer "note.org"
       (concat "* Property Node\n:PROPERTIES:\n:ID: document-node\n:END:\n"
               "alpha peer\n"
               "middle one\nmiddle two\nmiddle three\nmiddle four\n"
               "beta line\n"))
      (supertag-git-test-commit peer) (supertag-git-test-run peer "push")
      (supertag-git-test-write
       root "note.org"
       (concat "* Property Node\n:PROPERTIES:\n:ID: document-node\n:END:\n"
               "alpha local\n"
               "middle one\nmiddle two\nmiddle three\nmiddle four\n"
               "beta line\n"))
      (supertag-git-sync--pull)
      (should supertag-git--conflicted-files)
      (should (member (file-truename file) supertag-git--conflicted-files))
      (should (supertag-git-sync--live-conflicted-org-files root))
      ;; The existing pause path, not a silent no-op: timers off, smerge on.
      (should-not supertag-git-sync--pull-timer)
      (should-not supertag-git-sync--commit-timer)
      (with-current-buffer (get-file-buffer file) (should smerge-mode))
      (should-not supertag-git-sync--in-flight))))

(ert-deftest supertag-git-dirty-merge-reports-a-refused-merge-once ()
  "A merge git refuses without unmerged paths is reported, once per episode,
and still leaves `supertag-git-sync--in-flight' cleared."
  (supertag-git-test-with-vault
    (let ((supertag-git-sync--merge-refused-warned nil))
      ;; A tracked non-Org file, dirty locally and changed upstream: outside
      ;; auto-commit scope, so it must not be committed and git refuses.
      (supertag-git-test-write root "notes.txt" "base\n")
      (supertag-git-test-run root "add" "--" "notes.txt")
      (supertag-git-test-run root "commit" "-m" "Tracked non-Org file")
      (supertag-git-test-run root "push")
      (supertag-git-test-run peer "pull" "--no-edit")
      (supertag-git-test-write peer "notes.txt" "peer\n")
      (supertag-git-test-run peer "add" "--" "notes.txt")
      (supertag-git-test-run peer "commit" "-m" "Peer non-Org edit")
      (supertag-git-test-run peer "push")
      (supertag-git-sync-mode 1)
      (supertag-git-test-write root "notes.txt" "local\n")
      (should-not (supertag-git-sync--owned-changes-p root))
      (let (messages)
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
          (supertag-git-sync--pull)
          (supertag-git-sync--pull))
        (should (= 1 (cl-count-if (lambda (m) (string-match-p "git merge refused" m))
                                  messages)))
        (should (= 1 (cl-count-if (lambda (m) (string-match-p "No local data was discarded" m))
                                  messages))))
      (should-not supertag-git-sync--in-flight)
      (should-not supertag-git--conflicted-files))))


(ert-deftest supertag-git-r4b-setup-and-clone-ignore-literal-directory ()
  (dolist (clone '(nil t))
    (supertag-git-test-with-vault
      (let* ((target (if clone (expand-file-name "clone/" tmp) root))
             (supertag-data-directory (expand-file-name "cache[ab]/" target))
             (supertag-sync-state-file (expand-file-name "sync-state.el" supertag-data-directory)))
        (when clone
          (supertag-load-store)
          (supertag-git-clone bare target))
        (dolist (name '("cachea/ordinary.org" "cacheb/ordinary.org" "cache[ab]/private.org"))
          (supertag-git-test-write target name "* Synthetic text\n"))
        (unless clone
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
            (supertag-git-setup)))
        (should (supertag-git--ok-p
                 (supertag-git--run target "check-ignore" "--" "cache[ab]/private.org")))
        (supertag-git-sync-mode 1)
        (supertag-git-sync-now)
        (dolist (name '("cachea/ordinary.org" "cacheb/ordinary.org"))
          (should (member name (supertag-git--tracked-files target)))
          (should (equal "* Synthetic text" (supertag-git-test-run bare "show" (concat "HEAD:" name)))))
        (should-not (member "cache[ab]/private.org" (supertag-git--tracked-files target)))))))

(ert-deftest supertag-git-r4b-dynamic-ignore-special-filenames ()
  (supertag-git-test-with-vault
    (let ((names '("back\\slash.org" "star*.org" "question?.org" "[ab].org"
                   "trailing.org " "#hash.org" "!bang.org")))
      (dolist (name names) (supertag-git-test-write root name "local"))
      (supertag-git--prepare-ignore root names)
      (dolist (name names)
        (should (supertag-git--ok-p (supertag-git--run root "check-ignore" "--" name))))
      (dolist (name '("backslash.org" "starX.org" "questionX.org" "a.org" "b.org" "trailing.org"))
        (should-not (supertag-git--ok-p (supertag-git--run root "check-ignore" "--" name)))))))

(ert-deftest supertag-git-r4b-unrepresentable-ignore-path-is-one-warning ()
  (supertag-git-test-with-vault
    (let (messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (supertag-git--prepare-ignore root '("unsafe\n*.org" "unsafe\rname")))
      (should (= 2 (length messages))))
    (should-not (supertag-git--ok-p (supertag-git--run root "check-ignore" "--" "ordinary.org")))
    (with-temp-buffer
      (insert-file-contents (expand-file-name ".gitignore" root))
      (should-not (string-match-p "unsafe" (buffer-string))))))

(provide 'git-test)

;;; V2-VAULT-C: public local clone with independent fresh loading phases.
(defconst supertag-git-test--vc-program
  '(progn
     (require 'ert) (require 'cl-lib)
     (setq user-emacs-directory (file-name-as-directory vc-tmp)
           default-directory (file-name-as-directory vc-tmp)
           after-init-time nil load-prefer-newer t)
     (let* ((states '(supertag--config-guard-enabled supertag--config-guard-allow
                      supertag--config-guard--reverting supertag--config-guard-state))
            (seed (expand-file-name "seed/" vc-tmp))
            (bare (expand-file-name "local.git/" vc-tmp))
            (dest (expand-file-name "clone/" vc-tmp))
            (data (expand-file-name "data/" vc-tmp))
            (body "* VC local node\n:PROPERTIES:\n:ID: vc-clone-node\n:END:\nLocal only.\n")
            (calls 0) (capture-observer (lambda (&rest _) (cl-incf calls)))
            available)
       (dolist (s states) (should-not (boundp s)))
       (should-not (fboundp 'supertag-config-guard--capture))
       (when (eq vc-case 'template-first)
         (require (if vc-before 'supertag-services-template 'supertag-service-org))
         (princ (format "VC-GIT-TEMPLATE-PURE states=%S capture=%S\n"
                        (mapcar #'boundp states) (fboundp 'supertag-config-guard--capture)))
         (dolist (s states) (should-not (boundp s)))
         (should-not (featurep 'supertag))
         (should-not (featurep 'supertag-services-sync))
         (should-not (featurep 'supertag-core-persistence)))
       ;; Local-only configuration begins AFTER entry observation, no document fixture.
       (setq supertag-data-directory data
             supertag-db-file (expand-file-name "store.el" data)
             supertag-db-backup-directory (expand-file-name "backups/" data)
             supertag-sync-state-file (expand-file-name "sync-state.el" data)
             supertag-sync-directories-mode 'unified supertag-sync-directories nil
             supertag-active-sync-directory nil supertag-sync-auto-start nil
             supertag-vault-auto-switch nil supertag-vault-modeline-indicator nil
             supertag-tag-auto-enable nil org-id-locations-file (expand-file-name "ids" vc-tmp)
             org-id-track-globally nil)
       (when (eq vc-case 'main-preinit) (require 'supertag) (should-not supertag--initialized))
       (require 'supertag-git)
       (setq available (fboundp 'supertag-config-guard--capture))
       (princ (format "VC-GIT-ENTRY %S template=%S main=%S capture=%S states=%S owner=%S\n"
                      vc-case (featurep 'supertag-services-template) (featurep 'supertag)
                      available (mapcar #'boundp states)
                      (and available (symbol-file 'supertag-config-guard--capture 'defun))))
       (if (eq vc-case 'main-preinit) (should (featurep 'supertag)) (should-not (featurep 'supertag)))
       ;; Historical VC Git-only was light; current Node loads shared Org/Template.
       (if (and vc-before (eq vc-case 'git-only))
           (should-not (featurep 'supertag-services-template))
         (if vc-before
             (should (featurep 'supertag-services-template))
           (should (featurep 'supertag-service-org))
           (should-not (featurep 'supertag-services-template))))
       (should (eq available (or (eq vc-case 'main-preinit) (not vc-before))))
       (when available
         (should (equal (if vc-before "supertag.el" "supertag-vault.el")
                        (file-name-nondirectory (symbol-file 'supertag-config-guard--capture 'defun)))))
       ;; Record genuine Git-only dependency facts; branch execution below follows
       ;; the actual provider, rather than manufacturing one to attach advice.
       (when available (advice-add 'supertag-config-guard--capture :after capture-observer))
       (unwind-protect
           (progn
             (make-directory seed t) (make-directory bare t)
             (cl-labels ((git (dir &rest args)
                           (let ((result (apply #'supertag-git--run dir args)))
                             (princ (format "VC-LOCAL-GIT %S exit=%S\n" args (car result)))
                             (should (equal 0 (car result))) (cdr result))))
               (git seed "init" "-q" "-b" "main")
               (git bare "init" "-q" "--bare" "--initial-branch=main")
               (git seed "config" "commit.gpgsign" "false")
               (with-temp-file (expand-file-name "note.org" seed) (insert body))
               (git seed "add" "--" "note.org")
               (git seed "commit" "-m" "VC synthetic local seed")
               (git seed "remote" "add" "origin" bare)
               (git seed "push" "-u" "origin" "main"))
             (supertag-sync-load-state)
             (supertag-load-store)
             (let ((result (supertag-git-clone bare dest)))
               (princ (format "VC-CLONE-ACTUAL result=%S capture-count=%d state=%S\n"
                              result calls (and (boundp 'supertag--config-guard-state)
                                                supertag--config-guard-state)))
               (should (plist-get result :rebuilt))
               (should (equal (plist-get result :db-file) supertag-db-file))
               (should (file-exists-p supertag-db-file))
               (should-not (supertag-dirty-p))
               (should (equal (with-temp-buffer (insert-file-contents (expand-file-name "note.org" dest))
                                               (buffer-string)) body))
               (should (equal (file-truename (expand-file-name "note.org" dest))
                              (plist-get (supertag-node-get "vc-clone-node") :file)))
               (should (= calls (if available 1 0)))
               (when available
                 (should (equal supertag-sync-directories
                                (plist-get supertag--config-guard-state :sync-directories)))
                 (should (equal supertag-db-file (plist-get supertag--config-guard-state :db-file))))
               (let ((state (and (boundp 'supertag--config-guard-state) supertag--config-guard-state)))
                 (require 'supertag)
                 (should-not supertag--initialized)
                 (when available (should (eq state supertag--config-guard-state)))
                 (should (= calls (if available 1 0))))))
         (when available (advice-remove 'supertag-config-guard--capture capture-observer)))
       (princ (format "VC-GIT-DONE %S\n" vc-case)))))

(defun supertag-git-test--vc-child (case)
  "Run real local public clone CASE without warming it through document-fixture."
  (let* ((tmp (make-temp-file "supertag-vc-git-" t))
         (root (file-name-as-directory (or (getenv "SUPERTAG_VC_ROOT")
                                          (file-name-directory (locate-library "supertag-vault")))))
         (before (equal (getenv "SUPERTAG_VC_STAGE") "before"))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (program (or (getenv "EMACS_BIN") (expand-file-name invocation-name invocation-directory)))
         (process-environment (copy-sequence process-environment))
         (script (expand-file-name "case.el" tmp))
         (evidence (getenv "SUPERTAG_VC_EVIDENCE")))
    (unwind-protect
        (progn
          ;; Pin the child cwd before HOME is repointed.
          (setq default-directory (file-truename default-directory))
          (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
          (setenv "GIT_CONFIG_GLOBAL" "/dev/null") (setenv "GIT_CONFIG_NOSYSTEM" "1")
          (setenv "GIT_TERMINAL_PROMPT" "0") (setenv "GIT_ALLOW_PROTOCOL" "file")
          (setenv "GIT_AUTHOR_NAME" "VC Test") (setenv "GIT_COMMITTER_NAME" "VC Test")
          (setenv "GIT_AUTHOR_EMAIL" "vc@example.invalid") (setenv "GIT_COMMITTER_EMAIL" "vc@example.invalid")
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity deps path-separator) path-separator))
          (with-temp-file script
            (insert ";;; -*- lexical-binding: t; -*-\n")
            (prin1 `(setq vc-root ,root vc-tmp ,tmp vc-before ,before vc-case ',case) (current-buffer))
            (terpri (current-buffer))
            (prin1 `(condition-case err
                        (unwind-protect ,supertag-git-test--vc-program
                          (dolist (s '(supertag-data-directory supertag-db-file supertag-db-backup-directory
                                       supertag-sync-state-file supertag-sync-directories supertag-active-sync-directory))
                            (remove-variable-watcher s 'supertag-config-guard--watch))
                          (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil enable-theme-functions nil)
                          (mapc #'cancel-timer (append timer-list timer-idle-list)))
                      (error (princ (format "VC-GIT-ERROR %S\n" err)) (kill-emacs 1))) (current-buffer)))
          (with-temp-buffer
            (let ((status (apply #'call-process program nil t nil
                                 (append '("-Q" "--batch")
                                         (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                         (list "-L" root "-l" script)))))
              (when evidence
                (make-directory evidence t)
                (let ((base (expand-file-name (format "git-%s" case) evidence)))
                  (copy-file script (concat base ".el") t)
                  (write-region (point-min) (point-max) (concat base ".log") nil 'silent)
                  (with-temp-file (concat base ".exit") (insert (format "%s\n" status)))))
              (princ (buffer-string)) (should (equal 0 status))
              (should (string-match-p (format "VC-GIT-DONE %s" case) (buffer-string))))))
      (delete-directory tmp t))))

(ert-deftest supertag-git-vc-git-only () (supertag-git-test--vc-child 'git-only))
(ert-deftest supertag-git-vc-template-first () (supertag-git-test--vc-child 'template-first))
(ert-deftest supertag-git-vc-main-preinit () (supertag-git-test--vc-child 'main-preinit))
