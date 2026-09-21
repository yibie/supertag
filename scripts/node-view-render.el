;;; node-view-render.el --- Read-only editorial Node View checks -*- lexical-binding: t; -*-

;;; Commentary:
;; emacs -Q --batch -L . -L /Users/chenyibin/Documents/emacs/package/textui \
;;   -L "$HOME/.emacs.d/elpa/ht-20230703.558" \
;;   -L "$HOME/.emacs.d/elpa/dash-20260221.1346" \
;;   -l scripts/node-view-render.el
;; The live Store is only read.  All runtime data and outputs go to /private/tmp.

;;; Code:
(require 'cl-lib)
(setq user-emacs-directory (file-name-as-directory
                            (make-temp-file "/private/tmp/supertag-node-render-" t))
      supertag-data-directory user-emacs-directory
      supertag-presence-enable nil
      load-prefer-newer t)
(require 'supertag)
(require 'supertag-view-node)

(defconst supertag-node-render-vault
  "/Users/chenyibin/Documents/notes/.supertag/supertag-db.el")

(defun supertag-node-render--digest ()
  "Hash the live file to verify it remains unchanged."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally supertag-node-render-vault)
    (secure-hash 'sha256 (current-buffer))))

(defun supertag-node-render--visible-text ()
  "Return the buffer text a user sees, dropping invisible overlay text."
  (let ((position (point-min))
        (chunks nil))
    (while (< position (point-max))
      (let ((next (next-single-char-property-change position 'invisible nil (point-max))))
        (unless (invisible-p position)
          (push (buffer-substring-no-properties position next) chunks))
        (setq position next)))
    (apply #'concat (nreverse chunks))))

(defun supertag-node-render--sample (id width)
  "Render ID at WIDTH and return plain text, retaining no subscriptions."
  (with-temp-buffer
    (supertag-view-node-mode)
    (setq-local fill-column width)
    (setq-local supertag-view-helper-width-override width)
    (let ((supertag-semantic-enabled nil))
      (supertag-view-node--render-from-state (supertag-view-build-node-state id)))
    (goto-char (point-min))
    (while (< (point) (point-max))
      (when (eq (get-text-property (point) 'face) 'supertag-view-excerpt)
        (cl-assert (not (string-match-p
                         "\\[\\[\\|\\]\\]"
                         (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position))))))
      (forward-line 1))
    (let ((text (supertag-node-render--visible-text)))
      (cl-assert (string-match-p "[^\n]\n\n[+] [.] [+] [.] [+] [.]\n" text))
      (cl-assert (not (string-match-p "\n\n\n[+] [.]" text)))
      ;; One blank line before every section band, even after `+ N more'.
      (let ((start 0))
        (while (string-match "^ [A-Z][A-Z /0-9]* / [0-9][0-9] *$" text start)
          (let ((at (match-beginning 0)))
            (cl-assert (and (>= at 2)
                            (eq (aref text (1- at)) ?\n)
                            (eq (aref text (- at 2)) ?\n))))
          (setq start (match-end 0))))
      text)))

(defun supertag-node-render--check-contract ()
  "Check editorial bounds and retained interaction without Store writes."
  (cl-assert (eq supertag-view-palette 'paper))
  (cl-assert (equal 1.4 (face-attribute 'supertag-view-title :height nil nil)))
  (with-temp-buffer
    (setq-local fill-column 72)
    (supertag-view-helper-insert-section-chip "Empty" 0 'supertag-view-chip1)
    (cl-assert (= (buffer-size) 0))
    (supertag-view-helper-insert-section-chip "References" 3 'supertag-view-chip1)
    (goto-char (point-min))
    (search-forward "REFERENCES / 03 ")
    (cl-assert (get-text-property (point) 'supertag-view-section))
    (cl-assert (= (string-width (buffer-substring
                                (line-beginning-position) (line-end-position))) 71)))
  (with-temp-buffer
    (supertag-view-node-mode)
    (setq-local supertag-view-helper-width-override 62)
    (let ((inhibit-read-only t))
      (supertag-view-node--insert-masthead
       (list :node (list :file "/notes/20260620T131132--org-supertag__emacs_project.org"
                         :created-at (encode-time '(0 0 0 5 7 2026)))
             :tags '("prj")))
      ;; The masthead shows the display name, never the raw Denote name.
      (cl-assert (string-match-p "org-supertag  /  2026-07-05" (buffer-string)))
      (cl-assert (not (string-match-p "20260620T\\|__emacs_project" (buffer-string))))))
  (with-temp-buffer
    (setq-local fill-column 72)
    (supertag-view-helper-insert-excerpt (make-string 300 ?界))
    (cl-assert (= (count-lines (point-min) (point-max)) 2))
    (cl-assert (string-suffix-p "…\n" (buffer-string))))
  (with-temp-buffer
    (supertag-view-node-mode)
    (setq-local fill-column 72)
    (let ((inhibit-read-only t))
      (supertag-view-node--insert-panel
       (list :node (list :title (concat "TODO " (make-string 300 ?界)))))
      ;; The full title is present: no line cap and no ellipsis.
      (cl-assert (> (count-lines (point-min) (point-max)) 3))
      (cl-assert (= 300 (how-many "界" (point-min) (point-max))))
      (cl-assert (not (string-match-p "…" (buffer-string))))
      (erase-buffer)
      (supertag-view-node--insert-field-section
       (lambda (_id)
         (supertag-view-helper-insert-section-chip "References" 1 'supertag-view-chip1)
         (insert "  ")
         (insert-text-button (make-string 200 ?界) 'face 'supertag-view-entry
                             'action #'ignore 'supertag-node-id "target")
         (insert "\n")) "fixture")
      (supertag-view-node--insert-footer "fixture")
      (goto-char (point-min))
      (search-forward "→ ")
      (cl-assert (equal (button-get (button-at (point)) 'supertag-node-id) "target"))
      (goto-char (point-min))
      (search-forward "REFERENCES / ")
      (supertag-view-node-toggle-section)
      (search-forward "+ . + .")
      (cl-assert (not (invisible-p (point))))))
  (message "NODE contract: title/excerpt bounds, empty sections, buttons, folding / OK"))

(supertag-node-render--check-contract)

(let ((before (supertag-node-render--digest))
      (best-count -1) best-id todo-id)
  (supertag-load-store supertag-node-render-vault)
  (maphash
   (lambda (id node)
     (let ((count (+ (length (supertag-query-ordinary-references-from id))
                     (length (supertag-query-ordinary-references-to id)))))
       (when (> count best-count)
         (setq best-count count best-id id)))
     (when (and (not todo-id) (plist-get node :tags)
                (or (plist-get node :todo)
                    (plist-get node :todo-keyword)
                    (string-match-p
                     (concat "\\`" (regexp-opt supertag-view-node-todo-keywords t) "[[:space:]]")
                     (or (plist-get node :title) ""))))
       (setq todo-id id)))
   (supertag-store-get-collection :nodes))
  (unless (and best-id todo-id)
    (error "Missing reference or tagged TODO sample"))
  (message "NODE samples: references=%s (%d ordinary links), todo=%s"
           best-id best-count todo-id)
  (dolist (sample `(("references" . ,best-id) ("todo" . ,todo-id)))
    (dolist (width '(62 72 80 120))
      (let* ((text (supertag-node-render--sample (cdr sample) width))
             (maximum (apply #'max (mapcar #'string-width (split-string text "\n"))))
             (path (format "/private/tmp/supertag-node-view-%s-%d.txt" (car sample) width)))
        (with-temp-file path (insert text))
        (message "NODE %s width=%d max-line=%d file=%s" (car sample) width maximum path)
        (when (> maximum (1- width)) (error "Node View pads or overflows the pane"))
        (when (string-match-p "[─-╿]" text) (error "Box drawing in Node View")))))
  (dolist (palette '(neon paper ink ocean))
    (supertag-view-apply-palette palette)
    (dolist (face '(supertag-view-accent supertag-view-score))
      (unless (eq (face-attribute face :foreground nil nil) 'unspecified)
        (error "Colored foreground: %s / %s" palette face)))
    (message "NODE palette=%s neutral emphasis / OK" palette))
  (unless (equal before (supertag-node-render--digest))
    (error "Live Store changed during rendering"))
  (message "NODE live Store SHA256 unchanged: %s" before))

;;; node-view-render.el ends here
