;;; node-view-test.el --- Public document view contracts -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-query)
(require 'supertag-view-node)

(ert-deftest supertag-node-view-hides-org-properties-shows-only-discovered-context ()
  "Node View renders a node's discovered tag but never its Org properties."
  (let* ((tmp (file-name-as-directory
               (file-truename (make-temp-file "supertag-node-view-props-" t))))
         (file (expand-file-name "ready-item.org" tmp))
         (supertag-data-directory (expand-file-name "data/" tmp))
         (supertag-view-node-side-size 0.8)
         (supertag-db-file (expand-file-name "store.el" supertag-data-directory))
         (supertag-db-backup-directory
          (expand-file-name "backups/" supertag-data-directory))
         (supertag-sync-directories (list tmp))
         (supertag-active-sync-directory tmp)
         (supertag--store nil)
         (supertag--store-origin nil)
         (supertag--subscribers (make-hash-table :test 'equal))
         (supertag-sync--state (list :sync-state (make-hash-table :test 'equal)))
         (supertag-sync--state-source (expand-file-name "sync-state.el" tmp))
         (supertag-sync-state-file (expand-file-name "sync-state.el" tmp))
         (supertag-sync--deferred-files (make-hash-table :test 'equal))
         (supertag-sync--internal-modifications (make-hash-table :test 'equal))
         (supertag-async--queue nil)
         (org-id-locations nil)
         (org-id-locations-file (expand-file-name "ids" tmp))
         (org-id-track-globally nil)
         (make-backup-files nil)
         (auto-save-default nil))
    (unwind-protect
        (progn
          (supertag--ensure-store)
          (supertag-tag-create '(:id "ready-work" :name "ready-work"))
          (with-temp-file file
            (insert "* Ready Item #ready-work\n"
                    ":PROPERTIES:\n:ID: ready-item\n:STAGE: ready\n:END:\n"
                    "Body.\n"))
          (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
          (let ((state (supertag-view-build-node-state "ready-item")))
            (should-not (plist-member state :properties))
            (should-not (plist-member state :property-count))
            (should (equal '("ready-work") (plist-get state :tags))))
          (let ((view (supertag-view-node-open "ready-item"))
                (case-fold-search nil))
            (unwind-protect
                (with-current-buffer view
                  (should (string-match-p "READY-WORK" (buffer-string)))
                  (should-not (string-match-p "Properties" (buffer-string)))
                  (should-not (string-match-p "STAGE" (buffer-string))))
              (when (buffer-live-p view) (kill-buffer view)))))
      (when (get-buffer "*Supertag Node*") (kill-buffer "*Supertag Node*"))
      (delete-directory tmp t))))

;;; VWA independent view ownership controls.
(defconst supertag-node-view-vwa--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(defun supertag-node-view-vwa--child (name body)
  "Run BODY in a genuinely fresh, isolated source process; retain evidence."
  (let* ((tmp (make-temp-file "supertag-vwa-" t))
         (script (expand-file-name "child.el" tmp))
         (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
         (root supertag-node-view-vwa--root)
         (process-environment (copy-sequence process-environment)))
    ;; Pin the child cwd before HOME is repointed.
    (setq default-directory (file-truename default-directory))
    (setenv "HOME" tmp) (setenv "CFFIXED_USER_HOME" tmp)
    (with-temp-file script
      (insert ";;; -*- lexical-binding: t; -*-\n")
      (prin1
       `(condition-case err
            (unwind-protect
                (progn
                  (require 'cl-lib) (require 'ert)
                  (setq user-emacs-directory ,(file-name-as-directory tmp)
                        supertag-data-directory ,tmp supertag--base-data-directory ,tmp
                        supertag-db-file ,(expand-file-name "db.el" tmp)
                        supertag-db-backup-directory ,(expand-file-name "backups" tmp)
                        supertag-sync-state-file ,(expand-file-name "sync.el" tmp)
                        supertag-sync--state-source supertag-sync-state-file
                        org-id-locations-file ,(expand-file-name "ids" tmp)
                        org-id-track-globally nil after-init-time nil
                        supertag-sync-directories (list ,tmp)
                        supertag-sync-directories-mode 'unified
                        make-backup-files nil auto-save-default nil)
                  (let ((vwa-root ,root) (vwa-tmp ,tmp)
                        (before (equal (getenv "SUPERTAG_VWA_STAGE") "before")))
                    ,body)
                  (princ ,(concat "VWA-" name "-DONE\n")))
              (setq kill-emacs-hook nil emacs-startup-hook nil org-mode-hook nil
                    enable-theme-functions nil)
              (mapc #'cancel-timer (append timer-list timer-idle-list)))
          (error (princ (format "VWA-ERROR %S\n" err)) (kill-emacs 1)))
       (current-buffer)))
    (unwind-protect
        (with-temp-buffer
          (let* ((exit (apply #'call-process
                              (or (getenv "EMACS_BIN")
                                  (expand-file-name invocation-name invocation-directory))
                              nil t nil
                              (append '("-Q" "--batch")
                                      (apply #'append (mapcar (lambda (d) (list "-L" d)) deps))
                                      (list "-L" root "-L" (expand-file-name "test" root)
                                            "-l" script))))
                 (output (buffer-string)) (evidence (getenv "SUPERTAG_VWA_EVIDENCE")))
            (when evidence
              (make-directory evidence t)
              (copy-file script (expand-file-name (concat name ".el") evidence) t)
              (with-temp-file (expand-file-name (concat name ".log") evidence) (insert output))
              (with-temp-file (expand-file-name (concat name ".exit") evidence) (prin1 exit (current-buffer))))
            (princ output)
            (should (equal exit 0))
            (should (string-match-p (concat "VWA-" name "-DONE") output))))
      (delete-directory tmp t))))

(ert-deftest supertag-node-view-vwa-cold-services-entry ()
  (supertag-node-view-vwa--child
   "services"
   '(progn
      (should-not (featurep 'supertag-services-sync))
      (should-not (featurep 'document-fixture))
      (should-not (featurep 'supertag-view-node))
      (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener))
      (princ "VWA-services-ENTRY\n")
      (should (featurep 'supertag-services-sync))
      (should-not (featurep 'document-fixture))
      (should-not (featurep 'supertag-view-node))
      (should-not (fboundp 'supertag-register-listener))
      (if before
          (should (equal "supertag-services-ui.el"
                         (file-name-nondirectory (symbol-file 'supertag-view-build-node-state 'defun))))
        (should-not (fboundp 'supertag-view-build-node-state)))
      (require 'supertag-view-node)
      (let ((builder (symbol-function 'supertag-view-build-node-state)) (calls nil))
        (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener))
        (require 'supertag-view-node)
        (should (eq builder (symbol-function 'supertag-view-build-node-state)))
        ;; Deliberately installed availability seam, not a native subscription API.
        (cl-letf (((symbol-function 'supertag-register-listener)
                   (lambda (event callback) (push (list event callback) calls))))
          (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener))
          (should-not calls)
          (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener t)))
        (should (equal calls '((:store-changed supertag-ui--invalidate-cache-on-change))))
        (should (equal (if before "supertag-services-ui.el" "supertag-view-node.el")
                       (file-name-nondirectory (symbol-file 'supertag-view-build-node-state 'defun))))
        (unless before (should (eq builder (symbol-function 'supertag-view-build-node-state)))))
      (princ "VWA-CONDITIONAL-LISTENER call=1; native API originally absent\n"))))

(ert-deftest supertag-node-view-vwa-cold-node-entry ()
  (supertag-node-view-vwa--child
   "node"
   '(progn
      (should-not (featurep 'document-fixture))
      (should-not (featurep 'supertag-services-sync))
      (require 'supertag-view-node)
      (princ "VWA-node-ENTRY\n")
      (should-not (featurep 'supertag-services-ui))
      (should supertag-node--cache-listener-prepared)
      (should (featurep 'supertag-services-sync))
      (should-not (featurep 'document-fixture))
      (should (fboundp 'supertag-view-build-node-state))
      (should (= 1 (cl-count #'supertag-view-node--on-window-selection-change
                             window-selection-change-functions)))
      (let ((fn (symbol-function 'supertag-view-build-node-state))
            (hooks (copy-sequence window-selection-change-functions)))
        (require 'supertag-view-node)
        (should (eq fn (symbol-function 'supertag-view-build-node-state)))
        (should (equal hooks window-selection-change-functions)))
      (let ((supertag--store nil))
        (should-not (supertag-view-build-node-state nil))
        (should-not (supertag-view-build-node-state 12))
        (should-error (supertag-view-build-node-state "missing"))
        (should-error (supertag-view-build-node-state ""))
        (should-not supertag--store)))))

(ert-deftest supertag-node-view-vwa-owner ()
  (supertag-node-view-vwa--child
   "owner"
   '(progn
      (require 'supertag-view-node)
      (princ "VWA-owner-ENTRY\n")
      (should (equal "supertag-view-node.el"
                     (file-name-nondirectory (symbol-file 'supertag-view-build-node-state 'defun)))))))

(ert-deftest supertag-node-view-vwa-state-and-public-refresh ()
  (supertag-node-view-vwa--child
   "state"
   '(progn
      ;; Real cold snapshot precedes any fixture/Sync preload.
      (should-not (featurep 'document-fixture))
      (should-not (featurep 'supertag-services-sync))
      (progn (require 'supertag-query) (require 'supertag-tag) (require 'supertag-services-sync) (supertag-node--prepare-cache-listener))
      (when before (should (fboundp 'supertag-view-build-node-state)))
      (require 'supertag-view-node)
      (princ "VWA-state-ENTRY-COLD-COMPLETE\n")
      (require 'document-fixture)
      (supertag-document-test-with-vault
        (let ((other (expand-file-name "other.org" tmp))
              (incoming (expand-file-name "incoming.org" tmp))
              (supertag-text-link-relation-types '("supports")))
          (supertag-tag-create '(:id "vwa-tag" :name "vwa-tag"))
          (with-temp-file other
            (insert "* Other\n:PROPERTIES:\n:ID: vwa-other\n:END:\nBody\n"))
          (with-temp-file incoming
            (insert "* Incoming\n:PROPERTIES:\n:ID: vwa-in\n:END:\n[[id:document-node][incoming]]\n[[supports:document-node][named incoming]]\n"))
          (with-current-buffer (find-file-noselect file)
            (goto-char (point-min)) (end-of-line) (insert " #vwa-tag")
            (goto-char (point-max))
            (insert "[[id:vwa-other][outgoing]]\n[[supports:vwa-other][named outgoing]]\n")
            (save-buffer))
          (should (eq 'complete (plist-get (supertag-reindex-org) :status)))
          (princ "VWA-state-REAL-PROJECTION\n")
          (let* ((files (list file plain other incoming))
                 (disks (mapcar #'supertag-document-test-disk files))
                 (live (with-current-buffer (find-file-noselect file) (buffer-string)))
                 (store (prin1-to-string supertag--store))
                 (state (supertag-view-build-node-state "document-node")))
            (should-not (supertag-view-build-node-state "missing"))
            (should (equal "document-node" (plist-get state :id)))
            (should (equal '("vwa-tag") (plist-get state :tags)))
            (should-not (plist-member state :properties))
            (should-not (plist-member state :property-count))
            (should (equal '("vwa-other") (plist-get state :refs-to)))
            (should (equal '("vwa-in") (plist-get state :refs-from)))
            (should (= 2 (plist-get state :ref-count)))
            (should (= 1 (length (supertag-query-named-links-from "document-node"))))
            (should (= 1 (length (supertag-query-named-links-to "document-node"))))
            ;; Only Q-detached node data is promised deeply isolated.
            (aset (plist-get (plist-get state :node) :title) 0 ?X)
            (should (equal store (prin1-to-string supertag--store)))
            (should (equal disks (mapcar #'supertag-document-test-disk files)))
            (with-current-buffer (find-file-noselect file)
              (should (equal live (buffer-string))) (should-not (buffer-modified-p))))
          (let* ((supertag-view-node-side-size 0.8)
                 (baseline (length (gethash :store-changed supertag--subscribers)))
                 (view (with-current-buffer (find-file-noselect file)
                         (supertag-view-node-open "document-node"))))
            (unwind-protect
                (progn
                  (should (= (1+ baseline) (length (gethash :store-changed supertag--subscribers))))
                  (with-current-buffer view
                    (should (string-match-p "Property Node" (buffer-string)))
                    (should-not (string-match-p "Properties" (buffer-string)))
                    (should-not (string-match-p "ALPHA" (buffer-string)))
                    (should (string-match-p "vwa-tag" (buffer-string)))
                    (should (string-match-p "supports" (buffer-string)))
                    (goto-char (point-min)) (search-forward "vwa-tag") (backward-char 1)
                    (princ (format "VWA-WINDOW before point=%s start=%S\n"
                                   (point) (window-start (get-buffer-window view)))))
                  ;; A real save that does not touch tags still triggers a
                  ;; Runtime-owned refresh; the tag selection survives it.
                  (supertag-document-test-save-property file "ALPHA" "updated")
                  (supertag-document-test-drain)
                  (with-current-buffer view
                    (should (get-text-property (point) 'supertag-context))
                    (supertag-view-node-refresh)
                    (princ (format "VWA-WINDOW after point=%s start=%S\n"
                                   (point) (window-start (get-buffer-window view)))))
                  (supertag-view-node-open "document-node")
                  (should (= (1+ baseline) (length (gethash :store-changed supertag--subscribers))))
                  (princ "VWA-REAL-OUTPUT refs=2 title=Property Node\n")
                  (should (= 2 (plist-get (supertag-view-build-node-state "document-node") :ref-count))))
              (when (buffer-live-p view) (kill-buffer view)))
            (should (= baseline (length (gethash :store-changed supertag--subscribers))))
            (with-current-buffer (find-file-noselect file)
              (should-not (memq #'supertag-view-node--post-command post-command-hook))))
          (let ((missing (supertag-view-node-open "missing")))
            (unwind-protect
                (with-current-buffer missing
                  (should (equal "Node missing not found." (buffer-string)))
                  (should-not supertag-view-node--current-node-id))
              (when (buffer-live-p missing) (kill-buffer missing)))))))))

(ert-deftest supertag-node-view-magazine-omits-empty-reference-chip ()
  "A Node View does not render an empty References section."
  (with-temp-buffer
    (supertag-view-node-mode)
    (cl-letf (((symbol-function 'supertag-view-reference-insert-sections) #'ignore)
              ((symbol-function 'supertag-ai-insert-section) #'ignore)
              ((symbol-function 'supertag-semantic-insert-section) #'ignore)
              ((symbol-function 'supertag-view-node--insert-named-links-section) #'ignore)
              ((symbol-function 'supertag-concept-node-p) (lambda (_node) nil)))
      (supertag-view-node--render-from-state
       '(:id "abcdef012345" :node (:id "abcdef012345" :title "Heading" :file "/tmp/heading.org")
         :tags nil)))
    (should-not (string-match-p "REFERENCES /" (buffer-string)))
    (should (string-match-p "01 / NODE  heading\\.org  ·  ABCDEF01\nSUPERTAG / NODE\n" (buffer-string)))))

(ert-deftest supertag-node-view-magazine-masthead-tag-keeps-context-property ()
  "A masthead chip remains a selectable Tag context."
  (with-temp-buffer
    (supertag-view-node-mode)
    (cl-letf (((symbol-function 'supertag-view-reference-insert-sections) #'ignore)
              ((symbol-function 'supertag-ai-insert-section) #'ignore)
              ((symbol-function 'supertag-semantic-insert-section) #'ignore)
              ((symbol-function 'supertag-view-node--insert-named-links-section) #'ignore)
              ((symbol-function 'supertag-concept-node-p) (lambda (_node) nil)))
      (supertag-view-node--render-from-state
       '(:id "abcdef012345" :node (:id "abcdef012345" :title "Heading") :tags ("project"))))
    (goto-char (point-min))
    (search-forward " PROJECT ")
    (let ((position (match-beginning 0)))
      (should (get-text-property position 'supertag-context))
      (should (eq (get-text-property position 'type) :tag))
      (should (equal (get-text-property position 'tag-id) "project")))))

(ert-deftest supertag-node-view-magazine-tab-folds-chip-section ()
  "TAB creates an invisible fold overlay for a chip section."
  (with-temp-buffer
    (supertag-view-node-mode)
    (cl-letf (((symbol-function 'supertag-view-reference-insert-sections)
               (lambda (_node-id)
                 (insert "\n")
                 (supertag-view-helper-insert-section-chip "References" 1 'supertag-view-chip1)
                 (insert "  Entry\n      Excerpt\n")))
              ((symbol-function 'supertag-ai-insert-section) #'ignore)
              ((symbol-function 'supertag-semantic-insert-section) #'ignore)
              ((symbol-function 'supertag-view-node--insert-named-links-section) #'ignore)
              ((symbol-function 'supertag-concept-node-p) (lambda (_node) nil)))
      (supertag-view-node--render-from-state
       '(:id "abcdef012345" :node (:id "abcdef012345" :title "Heading") :tags nil)))
    (goto-char (point-min))
    (search-forward " REFERENCES / 01 ")
    (beginning-of-line)
    (supertag-view-node-toggle-section)
    (let ((fold (seq-find (lambda (overlay)
                            (overlay-get overlay 'supertag-view-node-fold))
                          (overlays-in (point-min) (point-max)))))
      (should fold)
      (should (overlay-get fold 'invisible))
      (should (equal (substring-no-properties (overlay-get fold 'after-string)) "  …")))))

(ert-deftest supertag-node-view-reference-snippet-cleans-before-clipping ()
  "Long physical paths and bracketed dates never leak into clipped prose."
  (let* ((supertag-reference-context-length 60)
         (source (list :content
                       (concat "* Neighbour before\n"
                               "Read [[https://example.test/" (make-string 300 ?x)
                               "][manual]] with [[id:target][[2026-01-01] Target]]"
                               " and [[id:bare]].\n* Neighbour after\n")))
         (before (copy-tree source))
         (snippet (supertag-reference-service-context-snippet
                   source '(:id "target" :title "Target"))))
    ;; The link description stays in place inside the sentence; only the bare
    ;; ID link disappears.
    (should (equal snippet "Read manual with [2026-01-01] Target and ."))
    (should (equal source before))
    (should-not (string-match-p "\\[\\[\\|\\]\\]" snippet))))

(ert-deftest supertag-node-view-reference-snippet-prefers-linked-line ()
  "The physical destination wins over earlier mentions and other headings."
  (should
   (equal
    (supertag-reference-service-context-snippet
     '(:content "* Target elsewhere\nIgnore this paragraph.\nThis cites [[id:t][The actual note]].\n* Next heading\nUnrelated text.")
     '(:id "t" :title "Target"))
    "This cites The actual note.")))

(ert-deftest supertag-node-view-reference-snippet-drops-uninformative-prose ()
  "Title-only or description-only prose is dropped, sentences survive."
  ;; The line is only the link; its description equals the entry title.
  (should-not
   (supertag-reference-service-context-snippet
    '(:content "[[id:t][Target]]") '(:id "t" :title "Target")))
  ;; Cleaned prose that equals the entry title adds nothing.
  (should-not
   (supertag-reference-service-context-snippet
    '(:content "See [[id:t][Target]]") '(:id "t" :title "See Target")))
  ;; Cleaned prose that equals the current node title adds nothing.
  (should-not
   (supertag-reference-service-context-snippet
    '(:id "anchor" :title "Anchor" :content "Anchor") '(:id "t" :title "Target")))
  ;; Prose that is nothing but the matched link description adds nothing.
  (should-not
   (supertag-reference-service-context-snippet
    '(:content "[[id:t][Other label]]") '(:id "t" :title "Target")))
  ;; Real surrounding prose survives with the link description in place.
  (should
   (equal "Keeps this context Target"
          (supertag-reference-service-context-snippet
           '(:content "Keeps this context [[id:t][Target]]")
           '(:id "t" :title "Target")))))

(ert-deftest supertag-node-view-reference-snippet-bare-and-semantic ()
  "Bare IDs disappear; semantic references retain only their matching line."
  (should-not
   (supertag-reference-service-context-snippet
    '(:content "* Before\n[[id:t]]\n* After") '(:id "t" :title "Target")))
  (should
   (equal
    (supertag-reference-service-context-snippet
     '(:content "* Before\nA Target is discussed here.\n* After")
     '(:id "t" :title "Target"))
    "A Target is discussed here.")))

(ert-deftest supertag-node-view-reference-snippet-long-line ()
  "Clip cleaned prose, not a character window spanning source lines."
  (let* ((supertag-reference-context-length 40)
         (snippet (supertag-reference-service-context-snippet
                   (list :content (concat "[[id:t][Target]] " (make-string 100 ?界)
                                          "\n* Unrelated"))
                   '(:id "t" :title "Target"))))
    (should (= (length snippet) 40))
    (should (string-prefix-p "Target " snippet))
    (should (string-suffix-p "…" snippet))
    (should-not (string-match-p "Unrelated\\|\\[\\[\\|\\]\\]" snippet))))

(defun supertag-node-view-test--visible-text ()
  "Return the current Node View text without invisible overlay text."
  (let ((position (point-min))
        (chunks nil))
    (while (< position (point-max))
      (let ((next (next-single-char-property-change position 'invisible nil (point-max))))
        (unless (invisible-p position)
          (push (buffer-substring-no-properties position next) chunks))
        (setq position next)))
    (apply #'concat (nreverse chunks))))

(ert-deftest supertag-node-view-62-column-pane-flows-without-padding ()
  "A 62-column pane keeps every line inside the pane and caps entries."
  (let* ((base (or (cl-find-if (lambda (window)
                                 (>= (window-body-width window) 63))
                               (window-list (selected-frame) t))
                   (selected-window)))
         (window (split-window base (- (window-body-width base) 62) t))
         (buffer (get-buffer-create " *supertag-node-62*")))
    (unwind-protect
        (progn
          (should (= 62 (window-body-width window)))
          (set-window-buffer window buffer)
          (with-selected-window window
            (with-current-buffer buffer
              (supertag-view-node-mode)
              (cl-letf (((symbol-function 'supertag-view-reference-insert-sections)
                         (lambda (_node-id)
                           (supertag-view-helper-insert-section-chip
                            "References" 11 'supertag-view-chip1)
                           (dotimes (index 11)
                             (supertag-view-reference--insert-card
                              (list :node-id (format "target-%d" index)
                                    :title (format "Entry %d 一段用于窄栏排版的标题" index)
                                    :file (format "/tmp/hangji__project-%d.org" index)
                                    :date "2026-07-15"
                                    :snippet (format "附加信息 %d，用于检查摘要在窄栏中的换行行为。" index))))
                           (supertag-view-helper-insert-section-chip
                            "Backlinks" 1 'supertag-view-chip2)
                           (supertag-view-reference--insert-card
                            (list :node-id "incoming" :title "Incoming"
                                  :file "/tmp/20260629T105208--incoming__notes.org"
                                  :date "2026-07-20"))))
                        ((symbol-function 'supertag-ai-insert-section) #'ignore)
                        ((symbol-function 'supertag-semantic-insert-section) #'ignore)
                        ((symbol-function 'supertag-view-node--insert-named-links-section) #'ignore)
                        ((symbol-function 'supertag-concept-node-p) (lambda (_node) nil)))
                (supertag-view-node--render-from-state
                 (list :id "abcdef012345"
                       :node (list :id "abcdef012345"
                                   :title "窄栏标题"
                                   :file "/tmp/heading.org"
                                   :created-at (encode-time '(0 0 0 15 7 2026)))
                       :tags '("project" "diary")))))
            (with-current-buffer buffer
              (goto-char (point-min))
              (while (< (point) (point-max))
                (should (<= (string-width
                             (buffer-substring (line-beginning-position)
                                               (line-end-position)))
                            61))
                (forward-line 1))
              (should (string-match-p "REFERENCES / 11" (buffer-string)))
              (should (string-match-p "BACKLINKS / 01" (buffer-string)))
              ;; The masthead uses the display name, not the raw Denote name.
              (should (string-match-p "heading  /  2026-07-15" (buffer-string)))
              (should-not (string-match-p "heading\\.org  /" (buffer-string)))
              ;; Metadata uses display names, not raw Denote file names.
              (should (string-match-p "hangji__project-0 · 2026-07-15"
                                      (buffer-string)))
              (should (string-match-p "incoming · 2026-07-20"
                                      (buffer-string)))
              (should-not (string-match-p "T[0-9]\\{6\\}--incoming" (buffer-string)))
              (should (string-match-p "\\+ 3 more" (buffer-string)))
              (let ((hidden (cl-find-if (lambda (overlay)
                                          (overlay-get overlay 'supertag-view-node-overflow))
                                        (overlays-in (point-min) (point-max)))))
                (should hidden)
                (should (invisible-p (overlay-start hidden))))
              ;; One blank line after the more-line, before the next band.
              (should (string-match-p "\\+ 3 more\n\n BACKLINKS / 01"
                                      (supertag-node-view-test--visible-text)))
              (let ((visible (supertag-node-view-test--visible-text)))
                (with-temp-buffer
                  (insert visible)
                  (should (= 9 (how-many "^→ " (point-min) (point-max))))))
              (goto-char (point-min))
              (search-forward "+ 3 more")
              (should (eq (lookup-key (get-text-property (match-beginning 0) 'keymap)
                                      (kbd "RET"))
                          #'push-button))
              (button-activate (button-at (match-beginning 0)))
              (should-not (cl-find-if (lambda (overlay)
                                        (overlay-get overlay 'supertag-view-node-overflow))
                                      (overlays-in (point-min) (point-max))))
              (should-not (string-match-p "\\+ 3 more"
                                          (supertag-node-view-test--visible-text)))
              (let ((visible (supertag-node-view-test--visible-text)))
                (with-temp-buffer
                  (insert visible)
                  (should (= 12 (how-many "^→ " (point-min) (point-max)))))))))
      (when (window-live-p window) (delete-window window))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest supertag-node-view-title-is-never-truncated ()
  "A 12-character CJK title renders in full in a 62-column pane.
The mocked display units reproduce the wider glyphs of a GUI font."
  (let* ((base (or (cl-find-if (lambda (window)
                                 (>= (window-body-width window) 63))
                               (window-list (selected-frame) t))
                   (selected-window)))
         (window (split-window base (- (window-body-width base) 62) t))
         (buffer (get-buffer-create " *supertag-node-title*"))
         (title "机动战士高达水星的魔女"))
    (unwind-protect
        (progn
          (should (= 62 (window-body-width window)))
          (set-window-buffer window buffer)
          (with-selected-window window
            (with-current-buffer buffer
              (supertag-view-node-mode)
              (cl-letf (((symbol-function 'supertag-view-reference-insert-sections) #'ignore)
                        ((symbol-function 'supertag-ai-insert-section) #'ignore)
                        ((symbol-function 'supertag-semantic-insert-section) #'ignore)
                        ((symbol-function 'supertag-view-node--insert-named-links-section) #'ignore)
                        ((symbol-function 'supertag-concept-node-p) (lambda (_node) nil))
                        ;; GUI units: one column is several pixels wide.
                        ((symbol-function 'supertag-view-helper-display-capacity)
                         (lambda () (* 10 (window-body-width))))
                        ((symbol-function 'supertag-view-helper-display-cost)
                         (lambda (string) (* 10 (string-width string)))))
                (supertag-view-node--render-from-state
                 '(:id "abcdef012345"
                   :node (:id "abcdef012345" :title "机动战士高达水星的魔女"
                          :file "/tmp/anime.org")
                   :tags nil))))
            (with-current-buffer buffer
              (should (string-match-p (regexp-quote title) (buffer-string)))
              (should-not (string-match-p "…" (buffer-string)))
              (should-not (string-match-p "\\.\\.\\." (buffer-string))))))
      (when (window-live-p window) (delete-window window))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest supertag-node-view-width-helpers-clip-without-padding ()
  "Clipping keeps lines inside the limit and trims padding silently."
  (with-temp-buffer
    (setq-local supertag-view-helper-width-override 37)
    (should (= 37 (supertag-view-helper-width)))
    (should (equal "abc…" (supertag-view-helper-clip "abcdefgh" 4)))
    (should (equal "abc" (supertag-view-helper-clip "abc   " 3)))
    (should (equal "abcdefgh" (supertag-view-helper-clip "abcdefgh" 20)))
    (let ((cjk (supertag-view-helper-clip (make-string 30 ?界) 20)))
      (should (<= (string-width cjk) 20))
      (should (string-suffix-p "…" cjk))))
  (let ((supertag-view-node-side-size 0.5))
    (should (= (round (* 0.5 (frame-width)))
               (supertag-view-node--estimated-width)))))

(ert-deftest supertag-node-view-footer-has-one-blank-line ()
  "The colophon has one blank separator regardless of preceding whitespace."
  (dolist (previous '("[OPEN]\n\n" "Last excerpt\n" "Last excerpt\n\n\n"))
    (with-temp-buffer
      (insert previous)
      (supertag-view-node--insert-footer "abcdef0123")
      (should (string-match-p "[^\n]\n\n[+] \\. [+] \\. [+] \\.\n" (buffer-string)))
      (should-not (string-match-p "\n\n\n" (buffer-string))))))
