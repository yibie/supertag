;;; tag-cards-render.el --- Render and time Tag Cards safely -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with:
;;   emacs -Q --batch -L . -L /Users/chenyibin/Documents/emacs/package/textui \
;;     -L "$HOME/.emacs.d/elpa/ht-20230703.558" \
;;     -L "$HOME/.emacs.d/elpa/dash-20260221.1346" \
;;     -l scripts/tag-cards-render.el
;;
;; The script loads a vault explicitly into a private temporary Supertag data
;; directory, disables presence, never saves, writes all-tags and diary/idea
;; drill-down text renderings, checks widths and accent fills at 120 and 80,
;; and prints timings.

;;; Code:

(require 'benchmark)
(require 'cl-lib)

;; These are defined by `supertag' below.  Declare them before the temporary
;; render settings so this standalone script also byte-compiles cleanly.
(defvar supertag-data-directory)
(defvar supertag-presence-enable)

(declare-function supertag-load-store "supertag-core-persistence" (file))
(declare-function supertag-store-get-collection "supertag-core-store" (collection))
(declare-function supertag-view-tag-cards-mode "supertag-view-tag-cards" ())
(declare-function supertag-view-tag-cards--frame "supertag-view-tag-cards" (width))
(declare-function supertag-view-tag-cards--card-track-widths
                  "supertag-view-tag-cards" (width))
(declare-function supertag-view-tag-cards--masthead-cell-widths
                  "supertag-view-tag-cards" (width))
(declare-function textui--render-frame "textui" (frame width))
(declare-function textui-refresh "textui" (&optional buffer))

(defvar supertag-tag-cards-render-vault
  "/Users/chenyibin/Documents/notes/.supertag/supertag-db.el"
  "Read-only Store file rendered by this script.")

(defvar supertag-tag-cards-render-output-directory "/private/tmp"
  "Directory receiving the two rendered Tag Cards text files.")

(defvar supertag-tag-cards-render-width 120
  "Primary width used for text rendering and timing.")

(defun supertag-tag-cards-render--text (state width)
  "Return a TextUI frame for STATE at WIDTH without modifying a view buffer."
  (with-temp-buffer
    (supertag-view-tag-cards-mode)
    (setq-local textui-state state
                textui--last-width width)
    (textui--render-frame (supertag-view-tag-cards--frame width) width)))

(defun supertag-tag-cards-render--max-line-width (text)
  "Return the greatest display width in TEXT."
  (let ((maximum 0))
    (dolist (line (split-string text "\n" nil) maximum)
      (setq maximum (max maximum (string-width line))))))

(defun supertag-tag-cards-render--face-runs (text face)
  "Return every contiguous FACE-bearing substring in rendered TEXT."
  (let ((position 0)
        (limit (length text))
        runs)
    (while (< position limit)
      (let ((next (next-single-property-change position 'face text limit)))
        (when (eq (get-text-property position 'face text) face)
          (push (substring text position next) runs))
        (setq position next)))
    (nreverse runs)))

(defun supertag-tag-cards-render--verify-fills (text width)
  "Assert TEXT keeps whole-width editorial fills and their faces at WIDTH."
  (pcase-let* ((`(,left _middle ,right)
                (supertag-view-tag-cards--masthead-cell-widths width))
               (card-widths (supertag-view-tag-cards--card-track-widths width))
               (chip-faces '(supertag-view-chip1 supertag-view-chip2
                              supertag-view-chip3))
               (allowed-widths (append (list left right) card-widths)))
    (dolist (face chip-faces)
      (let ((runs (supertag-tag-cards-render--face-runs text face)))
        (unless runs
          (error "No rendered %S fill" face))
        (dolist (run runs)
          (unless (member (string-width run) allowed-widths)
            (error "Unexpected %S fill width %d" face (string-width run))))))
    (let ((panel-runs
           (supertag-tag-cards-render--face-runs text 'supertag-view-panel)))
      (unless (= (length panel-runs) 3)
        (error "Expected three manifesto panel lines, got %d" (length panel-runs)))
      (dolist (run panel-runs)
        (unless (= (string-width run) width)
          (error "Panel fill width %d, expected %d" (string-width run) width))))
    (unless (cl-some (lambda (run) (member (string-width run) card-widths))
                     (append
                      (supertag-tag-cards-render--face-runs
                       text 'supertag-view-chip1)
                      (supertag-tag-cards-render--face-runs
                       text 'supertag-view-chip2)
                      (supertag-tag-cards-render--face-runs
                       text 'supertag-view-chip3)))
      (error "No card fill used one of the %S-column tracks" card-widths))
    (list :card-widths card-widths :masthead-left left :masthead-right right)))

(defun supertag-tag-cards-render--verify-local-card-tracks (text width)
  "Assert locally composed card ranges in TEXT use WIDTH's exact tracks.

The attached blocks tag every complete card span.  In batch their Variant-C
padding is ordinary spaces, so this check verifies both the text fallback and
the responsive 3/2/1 track allocation without needing GUI font metrics."
  (let ((tracks (supertag-view-tag-cards--card-track-widths width))
        (position 0)
        (limit (length text))
        (checked 0))
    (while (< position limit)
      (let* ((line-end (or (string-match "\n" text position) limit))
             (line-start position)
             (cursor position))
        (while (< cursor line-end)
          (let* ((card (get-text-property
                        cursor 'supertag-view-tag-cards--card text))
                 (next (next-single-property-change
                        cursor 'supertag-view-tag-cards--card text line-end)))
            (when card
              (let* ((column (cdr card))
                     (expected-width (nth column tracks))
                     (expected-start
                      (cl-loop for index below column
                               sum (+ (nth index tracks) 3)))
                     (actual-start (string-width
                                    (substring text line-start cursor)))
                     (actual-width (string-width (substring text cursor next))))
                (unless (= actual-start expected-start)
                  (error "Card %S starts at %d, expected %d columns"
                         card actual-start expected-start))
                (unless (= actual-width expected-width)
                  (error "Card %S is %d, expected %d columns"
                         card actual-width expected-width))
                (setq checked (1+ checked))))
            (setq cursor next)))
        (setq position (min limit (1+ line-end)))))
    (unless (> checked 0)
      (error "No locally composed card tracks at width %d" width))
    checked))

(defun supertag-tag-cards-render--frame-ms (state width)
  "Return mean milliseconds for complete frame construction of STATE."
  (with-temp-buffer
    (supertag-view-tag-cards-mode)
    (setq-local textui-state state)
    (* 1000.0 (/ (nth 0 (benchmark-run 3
                            (supertag-view-tag-cards--frame width)))
                 3.0))))

(defun supertag-tag-cards-render--refresh-ms (state width)
  "Return mean milliseconds for a complete TextUI refresh of STATE."
  (let ((buffer (generate-new-buffer " *supertag-tag-cards-render*")))
    (unwind-protect
        (with-current-buffer buffer
          (supertag-view-tag-cards-mode)
          (setq-local textui--render-function #'supertag-view-tag-cards--frame
                      textui-state state
                      textui--last-width width)
          ;; Warm all indexes and one initial widget materialization first.
          (textui-refresh buffer)
          (* 1000.0 (/ (nth 0 (benchmark-run 3 (textui-refresh buffer)))
                       3.0)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun supertag-tag-cards-render--tags-per-node-histogram ()
  "Return the current Store's `(tag-count . node-count)' histogram."
  (let ((histogram (make-hash-table :test 'eql)))
    (maphash
     (lambda (_node-id node)
       (let ((count (length (or (plist-get node :tags) '()))))
         (puthash count (1+ (gethash count histogram 0)) histogram)))
     (supertag-store-get-collection :nodes))
    (sort (let (rows)
            (maphash (lambda (count nodes) (push (cons count nodes) rows)) histogram)
            rows)
          (lambda (left right) (< (car left) (car right))))))

(defun supertag-tag-cards-render--write (name text)
  "Write TEXT as NAME under the configured output directory and return its path."
  (make-directory supertag-tag-cards-render-output-directory t)
  (let ((path (expand-file-name name supertag-tag-cards-render-output-directory)))
    (with-temp-file path
      (insert text))
    path))

(defun supertag-tag-cards-render ()
  "Render, verify, and time Tag Cards without writing to the live vault."
  ;; These settings must precede the load so all Supertag startup paths use a
  ;; private directory.  Keeping them in this function also makes byte
  ;; compilation side-effect free.
  (setq user-emacs-directory "/private/tmp/supertag-tag-cards-render-data/"
        supertag-data-directory user-emacs-directory
        supertag-presence-enable nil)
  (require 'supertag)
  (require 'supertag-view-tag-cards)
  (let* ((temporary-data-directory (file-name-as-directory supertag-data-directory))
         (all-state '(:filter nil :group nil :limit-nodes 5))
         (drill-state '(:filter ((tag . "diary") (tag . "idea"))
                        :group nil :limit-nodes 5))
         all-text drill-text narrow-text all-max drill-max narrow-max)
    (make-directory temporary-data-directory t)
    ;; `supertag-load-store' sees the explicit source only.  Presence is
    ;; disabled above and this script never calls a save command.
    (supertag-load-store supertag-tag-cards-render-vault)
    (setq all-text
          (supertag-tag-cards-render--text all-state supertag-tag-cards-render-width)
          drill-text
          (supertag-tag-cards-render--text drill-state supertag-tag-cards-render-width)
          all-max (supertag-tag-cards-render--max-line-width all-text)
          drill-max (supertag-tag-cards-render--max-line-width drill-text)
          narrow-text (supertag-tag-cards-render--text all-state 80)
          narrow-max (supertag-tag-cards-render--max-line-width narrow-text))
    (when (> all-max supertag-tag-cards-render-width)
      (error "All-tags text overflow: %d > %d" all-max supertag-tag-cards-render-width))
    (when (> drill-max supertag-tag-cards-render-width)
      (error "Drill-down text overflow: %d > %d" drill-max supertag-tag-cards-render-width))
    (when (> narrow-max 80)
      (error "80-column text overflow: %d > 80" narrow-max))
    (let ((fills (supertag-tag-cards-render--verify-fills
                  all-text supertag-tag-cards-render-width))
          (narrow-fills (supertag-tag-cards-render--verify-fills narrow-text 80)))
      (message "TAG-CARDS fills width=%d card-tracks=%S masthead=(%d %d) faces=preserved"
               supertag-tag-cards-render-width (plist-get fills :card-widths)
               (plist-get fills :masthead-left)
               (plist-get fills :masthead-right))
      (message "TAG-CARDS fills width=80 card-tracks=%S masthead=(%d %d) faces=preserved"
               (plist-get narrow-fills :card-widths)
               (plist-get narrow-fills :masthead-left)
               (plist-get narrow-fills :masthead-right)))
    (message "TAG-CARDS local-tracks width=%d spans=%d; width=80 spans=%d"
             supertag-tag-cards-render-width
             (supertag-tag-cards-render--verify-local-card-tracks
              all-text supertag-tag-cards-render-width)
             (supertag-tag-cards-render--verify-local-card-tracks narrow-text 80))
    (message "TAG-CARDS histogram=%S" (supertag-tag-cards-render--tags-per-node-histogram))
    (message "TAG-CARDS all width=%d max-line=%d frame=%.3fms refresh=%.3fms file=%s"
             supertag-tag-cards-render-width all-max
             (supertag-tag-cards-render--frame-ms all-state supertag-tag-cards-render-width)
             (supertag-tag-cards-render--refresh-ms all-state supertag-tag-cards-render-width)
             (supertag-tag-cards-render--write "supertag-tag-cards-all.txt" all-text))
    (message "TAG-CARDS drill width=%d max-line=%d frame=%.3fms refresh=%.3fms file=%s"
             supertag-tag-cards-render-width drill-max
             (supertag-tag-cards-render--frame-ms drill-state supertag-tag-cards-render-width)
             (supertag-tag-cards-render--refresh-ms drill-state supertag-tag-cards-render-width)
             (supertag-tag-cards-render--write "supertag-tag-cards-diary-idea.txt" drill-text))
    (message "TAG-CARDS width=80 max-line=%d" narrow-max)))

(when noninteractive
  (supertag-tag-cards-render))

;;; tag-cards-render.el ends here
