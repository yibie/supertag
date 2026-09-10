;;; svg-tag-test.el --- SVG font metrics and command contract -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'supertag-tag)
(require 'supertag-menu)

(defmacro supertag-svg-test--metrics (&rest body)
  (declare (indent 0))
  `(let ((supertag-svg-tag-font-scale 0.68)
         (supertag-svg-tag-padding-x 8)
         (supertag-svg-tag-min-column-em 0.6)
         (supertag-svg-tag-font-family nil)
         (supertag-svg-tag-font-weight "500")
         (supertag-svg-tag--cache (make-hash-table :test 'equal)))
     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
               ((symbol-function 'face-attribute) (lambda (&rest _) "Iosevka"))
               ((symbol-function 'frame-char-width) (lambda (&rest _) 7))
               ((symbol-function 'frame-char-height) (lambda (&rest _) 18))
               ((symbol-function 'font-info) (lambda (&rest _) [nil nil 14])))
       ,@body)))

(ert-deftest supertag-svg-tag-width-matches-font-metrics ()
  (supertag-svg-test--metrics
    (dolist (sample '(("short" 30 36)
                       ("a-very-long-english-tag-name-for-testing" 240 288)
                       ("中文很长的标签名称用于测试显示" 180 216)
                       ("mixed混合Tag名/child-level" 156 188)
                       ("wwwwmmmm" 48 58) ("iiiillll" 48 58)))
      (dolist (floor '(nil 0 -1 0.6))
        (let ((supertag-svg-tag-min-column-em floor))
          (should (= (nth (if (equal floor 0.6) 2 1) sample)
                     (supertag-svg-tag--text-pixel-width (car sample)))))))))

(ert-deftest supertag-svg-tag-floor-covers-wider-renderer-face ()
  (supertag-svg-test--metrics
    (let* ((text "a-very-long-english-tag-name-for-testing")
           (image (supertag-svg-tag--make-svg text text)))
      (should (>= (supertag-svg-tag--text-pixel-width text) 286))
      (should (string-match-p "<svg[^>]* width=\"304\""
                              (plist-get (cdr image) :data))))))

(ert-deftest supertag-svg-tag-font-fallback-produces-image ()
  (supertag-svg-test--metrics
    (dolist (font '(error nil [nil nil 0]))
      (cl-letf (((symbol-function 'font-info)
                 (lambda (&rest _) (if (eq font 'error) (error "No font") font))))
        (should-not (supertag-svg-tag--base-font-px))
        (dolist (floor '(nil 0.6))
          (let ((supertag-svg-tag-min-column-em floor))
            (should (= (if floor 36 24) (supertag-svg-tag--text-pixel-width "short")))
            (should (eq 'image (car (supertag-svg-tag--make-svg "x" "x"))))))))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
      (should-not (supertag-svg-tag--base-font-px))
      (dolist (floor '(nil 0.6))
        (let ((supertag-svg-tag-min-column-em floor))
          (should (= (if floor 33 28) (supertag-svg-tag--text-pixel-width "short")))
          (should (eq 'image (car (supertag-svg-tag--make-svg "x" "x")))))))))

(ert-deftest supertag-svg-tag-font-family-override ()
  (supertag-svg-test--metrics
    (cl-letf (((symbol-function 'face-attribute) (lambda (&rest _) "Iosevka")))
      (dolist (family '("Menlo" nil ""))
        (let* ((supertag-svg-tag-font-family family)
               (image (supertag-svg-tag--make-svg "x" "x")))
          (should (string-match-p
                   (format "font-family=\"%s\"" (if (equal family "Menlo") "Menlo" "Iosevka"))
                   (plist-get (cdr image) :data))))))))

(ert-deftest supertag-svg-tag-image-width-includes-padding ()
  (supertag-svg-test--metrics
    (let* ((image (supertag-svg-tag--make-svg "short" "short"))
           (xml (plist-get (cdr image) :data)))
      (should (eq 'image (car image)))
      (should (string-match "<svg[^>]* width=\"\\([0-9]+\\)\"" xml))
      (should (= (+ (supertag-svg-tag--text-pixel-width "short")
                    (* 2 supertag-svg-tag-padding-x))
                 (string-to-number (match-string 1 xml))))
      (should (string-match-p "font-size=\"12\"" xml)))))

(ert-deftest supertag-svg-tag-command-surface ()
  (should (commandp 'supertag-toggle-tag-style))
  (should (fboundp 'supertag-menu--toggle-svg-tags))
  (dolist (old '(supertag-svg-tag-mode-toggle supertag-svg-tag-mode-enable
                 supertag-svg-tag-mode-disable))
    (should-not (fboundp old)))
  (should-not (commandp 'supertag-svg-tag--enable))
  (should-not (commandp 'supertag-svg-tag--disable))
  (let ((supertag-svg-tag-enable t))
    (supertag-toggle-tag-style)
    (should-not supertag-svg-tag-enable)
    (supertag-toggle-tag-style)
    (should supertag-svg-tag-enable)))

(ert-deftest supertag-svg-tag-cache-tracks-font-metrics ()
  (supertag-svg-test--metrics
    (let ((first (supertag-svg-tag--get-cached "short")))
      (should (eq first (supertag-svg-tag--get-cached "short")))
      (cl-letf (((symbol-function 'font-info) (lambda (&rest _) [nil nil 16])))
        (should-not (eq first (supertag-svg-tag--get-cached "short"))))
      (cl-letf (((symbol-function 'frame-char-width) (lambda (&rest _) 8)))
        (should-not (eq first (supertag-svg-tag--get-cached "short")))))))

(ert-deftest supertag-svg-tag-cache-tracks-rendering-options ()
  (supertag-svg-test--metrics
    (let ((first (supertag-svg-tag--get-cached "short")))
      (dolist (option '((supertag-svg-tag-font-family . "Menlo")
                        (supertag-svg-tag-min-column-em . nil)
                        (supertag-svg-tag-padding-x . 12)
                        (supertag-svg-tag-font-weight . "700")))
        (cl-progv (list (car option)) (list (cdr option))
          (should-not (eq first (supertag-svg-tag--get-cached "short"))))))))

(ert-deftest supertag-svg-tag-unspecified-family-falls-back ()
  (supertag-svg-test--metrics
    (cl-letf (((symbol-function 'face-attribute) (lambda (&rest _) 'unspecified)))
      (dolist (family '(nil ""))
        (let ((supertag-svg-tag-font-family family))
          (should (equal "sans-serif" (supertag-svg-tag--default-font-family)))
          (should (string-match-p
                   "font-family=\"sans-serif\""
                   (plist-get (cdr (supertag-svg-tag--make-svg "x" "x")) :data))))))))

(ert-deftest supertag-svg-tag-cache-tracks-default-family ()
  (supertag-svg-test--metrics
    (let ((first (supertag-svg-tag--get-cached "short")))
      (should-not supertag-svg-tag-font-family)
      (should (equal "Iosevka" (supertag-svg-tag--default-font-family)))
      (cl-letf (((symbol-function 'face-attribute) (lambda (&rest _) "Menlo")))
        (should-not supertag-svg-tag-font-family)
        (should-not (eq first (supertag-svg-tag--get-cached "short")))))))

(provide 'svg-tag-test)

(defconst supertag-svg-test--root
  (file-name-directory
   (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))

(defun supertag-svg-test--cold-style (entry auto svg &optional lifecycle)
  "Cold-load ENTRY with AUTO/SVG settings; optionally check LIFECYCLE.
The old SVG entry is used only by the independent before control."
  (let* ((root supertag-svg-test--root)
         (temporary (make-temp-file "supertag-style-cold-" t))
         (program (or (getenv "EMACS_BIN")
                      (expand-file-name invocation-name invocation-directory)))
         (dependencies
          (or (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t)
              (mapcar (lambda (name)
                        (file-name-directory (or (locate-library name)
                                                 (error "Missing cold dependency: %s" name))))
                      '("ht" "dash"))))
         (process-environment (copy-sequence process-environment))
         (form
          `(unwind-protect
               (progn
                 (setq user-emacs-directory ,(file-name-as-directory temporary)
                       supertag-data-directory ,(expand-file-name "data" temporary)
                       supertag--base-data-directory supertag-data-directory
                       supertag-db-file ,(expand-file-name "store.el" temporary)
                       supertag-db-backup-directory ,(expand-file-name "backups" temporary)
                       supertag-sync-state-file ,(expand-file-name "sync.el" temporary)
                       supertag-sync--state-source supertag-sync-state-file
                       org-id-locations-file ,(expand-file-name "ids" temporary)
                       supertag-sync-directories nil supertag-active-sync-directory nil
                       supertag-view-style-auto-enable ,auto
                       supertag-svg-tag-enable ,svg
                       supertag-svg-tag-font-family "Pinned family"
                       supertag-svg-tag-padding-x 17
                       load-prefer-newer t)
                 (require 'cl-lib)
                 (require 'org)
                 (require 'supertag-core-store)
                 (when (or (featurep 'supertag-tag) (featurep 'supertag-view-svg-tag))
                   (error "Cold setup preloaded Tag/style"))
                 (when (directory-files ,root nil "\\.elc\\'")
                   (error "Cold setup contains root bytecode"))
                 (supertag--ensure-store)
                 ;; Seed facts without loading either display carrier.
                 (puthash "known" '(:id "known" :name "known" :type :tag)
                          (supertag-store-get-collection :tags))
                 (let* ((file ,(expand-file-name "note.org" temporary))
                        (text "* Note\n:PROPERTIES:\n:ID: style-node\n:END:\n#known #missing [[id:other][#inside]]\n")
                        (org-buffer nil)
                        (readonly-buffer (generate-new-buffer " *style-readonly*"))
                        (text-buffer (generate-new-buffer " *style-text*"))
                        (facts (prin1-to-string supertag--store)))
                   (write-region text nil file nil 'silent)
                   (setq org-buffer (find-file-noselect file))
                   (with-current-buffer readonly-buffer
                     (org-mode) (insert text) (set-buffer-modified-p nil)
                     (setq buffer-read-only t))
                   (with-current-buffer text-buffer
                     (text-mode) (insert text) (set-buffer-modified-p nil))
                   (let ((after-init-time nil))
                     (load ,(expand-file-name (concat (symbol-name entry) ".el") root) nil nil t))
                   (unless (featurep ',entry) (error "Entry did not load"))
                   (princ ,(format "ENTRY-LOADED:%s\n" entry))
                   (when (eq ',entry 'supertag-menu)
                     (when (featurep 'supertag-tag) (error "Menu eagerly loaded Tag"))
                     (call-interactively #'supertag-menu--toggle-svg-tags)
                     (unless (and (featurep 'supertag-tag)
                                  (eq supertag-svg-tag-enable (not ,svg)))
                       (error "Real menu wrapper did not load Tag and toggle")))
                   ;; Consolidation structure is checked only after a real entry.
                   (unless (eq ',entry 'supertag-view-svg-tag)
                     (when (or (featurep 'supertag-view-svg-tag)
                               (file-exists-p ,(expand-file-name "supertag-view-svg-tag.el" root)))
                       (error "Retired SVG carrier still present"))
                     (dolist (feature '(supertag-view-helper supertag-view-api supertag-view-framework supertag))
                       (when (featurep feature) (error "Tag loaded forbidden %s" feature)))
                     (dolist (loaded load-history)
                       (when (and (stringp (car loaded))
                                  (member (file-name-base (car loaded))
                                          '("supertag-view-svg-tag" "supertag-view-helper"
                                            "supertag-view-api" "supertag-view-framework" "supertag")))
                         (error "Unexpected load-history: %s" (car loaded))))
                     (dolist (symbol '(supertag-view-style-mode supertag-toggle-tag-style
                                       supertag-view-helper--font-lock-matcher
                                       supertag-svg-tag--make-svg))
                       (unless (equal (symbol-file symbol 'defun)
                                      ,(expand-file-name "supertag-tag.el" root))
                         (error "Wrong Tag definition owner: %s" symbol))))
                   (unless (and (eq supertag-view-style-auto-enable ,auto)
                                (equal supertag-svg-tag-font-family "Pinned family")
                                (= supertag-svg-tag-padding-x 17))
                     (error "Preconfigured values changed"))
                   (when (or (featurep 'supertag) (file-exists-p supertag-db-file))
                     (error "Display initialized main/durable database"))
                   (cl-labels
                       ((check-hooks ()
                          (unless (= 1 (cl-count #'supertag-view-helper--auto-enable org-mode-hook))
                            (error "Org hook duplicated/missing"))
                          (when (boundp 'enable-theme-functions)
                            (unless (= 1 (cl-count #'supertag-svg-tag--on-theme-change enable-theme-functions))
                              (error "Theme hook duplicated/missing"))))
                        (check-buffer (buffer active)
                          (with-current-buffer buffer
                            (unless (eq (and supertag-view-style-mode t) active)
                              (error "Wrong mode state in %s" (buffer-name)))
                            ;; Only graphics/image production is stubbed; real matcher/font-lock run.
                            (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                                      ((symbol-function 'supertag-svg-tag--get-cached)
                                       (lambda (_) '(image :type svg :data "test-image"))))
                              (font-lock-flush) (font-lock-ensure))
                            (let* ((rules (if (eq t (car font-lock-keywords))
                                              (cadr font-lock-keywords) font-lock-keywords))
                                   (owned (cl-remove-if-not
                                           (lambda (rule) (eq (car-safe rule) 'supertag-view-helper--font-lock-matcher))
                                           rules)))
                              (unless (= (length owned) (if active 1 0))
                                (error "Style keywords duplicated/missing: %S" owned))
                              (when (and active
                                         (not (equal (car owned) (car (supertag-view-helper--get-font-lock-keywords)))))
                                (error "Wrong style keyword set")))
                            (when active
                              (goto-char (point-min)) (search-forward "#known")
                              (let ((position (- (point) 6)))
                                (if supertag-svg-tag-enable
                                    (unless (equal (get-text-property position 'display)
                                                   '(image :type svg :data "test-image"))
                                      (error "SVG display absent"))
                                  (unless (eq (get-text-property position 'face) 'supertag-inline-face)
                                    (error "Registered face absent"))))
                              (search-forward "#missing")
                              (when (and (not supertag-svg-tag-enable)
                                         (not (eq (get-text-property (- (point) 8) 'face) 'supertag-unresolved-tag-face)))
                                (error "Unresolved face changed"))
                              (search-forward "#inside")
                              (when (get-text-property (- (point) 7) 'display)
                                (error "Styled inside Org link")))
                            (unless (and (equal text (buffer-substring-no-properties (point-min) (point-max)))
                                         (not (buffer-modified-p)))
                              (error "Fontification changed text/dirty state")))))
                     (check-hooks)
                     (check-buffer org-buffer ,auto)
                     (check-buffer readonly-buffer ,auto)
                     (with-current-buffer text-buffer
                       (when supertag-view-style-mode (error "Enabled non-Org")))
                     (when ,lifecycle
                       (setq supertag-view-style-auto-enable nil)
                       (with-current-buffer org-buffer
                         (supertag-view-style-mode 1)
                         (supertag-view-style-mode 1))
                       (with-current-buffer readonly-buffer (supertag-view-style-mode -1))
                       (check-buffer org-buffer t)
                       (require ',entry)
                       ;; Reload must reconcile a changed preference even with auto=nil.
                       (setq supertag-svg-tag-enable (not supertag-svg-tag-enable))
                       (let ((after-init-time nil))
                         (load ,(expand-file-name (concat (symbol-name entry) ".el") root) nil nil t))
                       (check-hooks)
                       (check-buffer org-buffer t)
                       (check-buffer readonly-buffer nil)
                       (puthash 'theme-sentinel t supertag-svg-tag--cache)
                       (when (boundp 'enable-theme-functions)
                         (run-hook-with-args 'enable-theme-functions 'cold-test-theme)
                         (unless (zerop (hash-table-count supertag-svg-tag--cache))
                           (error "Real theme callback did not clear cache")))
                       (dotimes (_ 2)
                         (call-interactively #'supertag-toggle-tag-style)
                         (check-buffer org-buffer t)
                         (check-buffer readonly-buffer nil))
                       ;; Nongraphic fallback uses the existing handler unchanged.
                       (with-current-buffer org-buffer
                         (goto-char (point-min)) (search-forward "#known")
                         (set-match-data (list (- (point) 6) (point)))
                         (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
                           (unless (eq (supertag-svg-tag--match-handler) 'supertag-inline-face)
                             (error "Nongraphic fallback changed"))))
                       (check-hooks)))
                   (unless (equal facts (prin1-to-string supertag--store))
                     (error "Display changed Store facts"))
                   (unless (equal text (with-temp-buffer (insert-file-contents file) (buffer-string)))
                     (error "Display changed disk"))
                   (princ ,(format "STYLE-PASS:%s\n" entry))))
             (setq emacs-startup-hook nil kill-emacs-hook nil org-mode-hook nil)
             (when (boundp 'enable-theme-functions) (setq enable-theme-functions nil)))))
    (unwind-protect
        (with-temp-buffer
          (setenv "EMACSLOADPATH" (concat (mapconcat #'identity dependencies path-separator) path-separator))
          (let* ((args (append '("-Q" "--batch")
                               (apply #'append (mapcar (lambda (dir) (list "-L" dir)) dependencies))
                               (list "-L" root "--eval"
                                     (prin1-to-string
                                      `(condition-case problem ,form
                                         (error (princ (format "COLD-ERROR:%S\n" problem))
                                                (kill-emacs 1)))))))
                 (status (apply #'call-process program nil t nil args))
                 (output (buffer-string)))
            (unless (and (equal status 0)
                         (string-match-p (regexp-quote (format "ENTRY-LOADED:%s\n" entry)) output)
                         (string-match-p (regexp-quote (format "STYLE-PASS:%s\n" entry)) output))
              (ert-fail (format "Cold style %s auto=%S svg=%S lifecycle=%S exit=%S\n%s"
                                entry auto svg lifecycle status output)))))
      (delete-directory temporary t))))

(ert-deftest supertag-svg-tag-consolidated-cold-auto-svg-matrix ()
  (dolist (auto '(nil t))
    (dolist (svg '(nil t))
      (supertag-svg-test--cold-style 'supertag-tag auto svg))))

(ert-deftest supertag-svg-tag-consolidated-cold-manual-reload-theme-toggle ()
  (supertag-svg-test--cold-style 'supertag-tag nil t t))

(ert-deftest supertag-svg-tag-menu-only-cold-real-interactive-wrapper ()
  (supertag-svg-test--cold-style 'supertag-menu nil t))
