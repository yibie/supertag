;;; tag-cards-test.el --- ERT tests for TextUI Tag Cards -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)

(when load-file-name
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)
(require 'supertag-tag)
(require 'supertag-query)
(require 'supertag-view-framework)
(require 'supertag-view-tag-cards)

(defmacro supertag-tag-cards-test--with-store (&rest body)
  "Run BODY with a small isolated read-only cards Store fixture."
  (declare (indent 0) (debug t))
  `(let ((supertag--store nil)
         (supertag--index-relations-by-from (make-hash-table :test 'equal))
         (supertag--index-relations-by-to (make-hash-table :test 'equal))
         (supertag--index-relations-source-token nil)
         (supertag--index-nodes-by-tag (make-hash-table :test 'equal))
         (supertag--index-nodes-source-token nil)
         (supertag-tag--token-index (make-hash-table :test 'equal))
         (supertag-tag--descendants-index (make-hash-table :test 'equal))
         (supertag-tag--index-source-token nil))
     (supertag--ensure-store)
     (dolist (tag '(("project" :name "Project")
                    ("reading" :name "Reading")
                    ("writing" :name "Writing")
                    ("archive" :name "Archive")
                    ("archive-child" :name "Archive child" :extends "archive")))
       (supertag-store-put-entity
        :tags (car tag)
        (append (list :id (car tag) :type :tag :aliases (list (car tag)))
                (cdr tag))))
     (dolist (node
              '(("n1" :title "Read the guide" :tags ("project" "reading")
                 :todo "TODO" :created-at (100 0))
                ("n2" :title "Draft the guide" :tags ("project" "writing")
                 :todo "DONE" :created-at (200 0))
                ("n3" :title "Read notes" :tags ("reading")
                 :todo "TODO" :created-at (300 0))
                ("target" :title "Shared target" :tags ("archive")
                 :created-at (50 0))
                ("n4" :title "Archived follow-up" :tags ("archive-child")
                 :todo "LATER" :created-at (40 0))))
       (supertag-store-put-entity
        :nodes (car node)
        (append (list :id (car node) :type :node) (cdr node))))
     (dolist (relation
              '(("r1" :type :reference :from "n1" :to "target")
                ("r1-duplicate" :type :reference :from "n1" :to "target")
                ("r2" :type :reference :from "n2" :to "target")
                ("r3" :type :reference :from "n3" :to "solo")))
       (supertag-store-put-entity
        :relations (car relation)
        (append (list :id (car relation)) (cdr relation))))
     ,@body))

(defun supertag-tag-cards-test--record (kind value records)
  "Return the record in RECORDS matching KIND and VALUE."
  (cl-find-if (lambda (record)
                (equal (plist-get record :facet) (cons kind value)))
              records))

(defun supertag-tag-cards-test--assert-grid-tracks (text width)
  "Assert TEXT's grid card runs fill WIDTH's column tracks."
  (let ((tracks (supertag-view-tag-cards--card-track-widths width))
        (gap supertag-view-tag-cards--grid-gap)
        (position 0)
        (limit (length text))
        (count 0))
    (while (< position limit)
      (let* ((line-start position)
             (line-end (or (string-match "\n" text position) limit))
             (cursor position))
        (while (< cursor line-end)
          (let* ((card (get-text-property
                        cursor 'supertag-view-tag-cards--card text))
                 (next (next-single-property-change
                        cursor 'supertag-view-tag-cards--card text line-end)))
            (when card
              (let* ((column (cdr card))
                     (expected-start
                      (cl-loop for index below column
                               sum (+ (nth index tracks) gap))))
                (should (= expected-start
                           (string-width (substring text line-start cursor))))
                (should (= (nth column tracks)
                           (string-width (substring text cursor next))))
                (setq count (1+ count))))
            (setq cursor next)))
        (setq position (min limit (1+ line-end)))))
    (should (> count 0))))

(ert-deftest supertag-tag-cards-counts-tag-todo-and-repeated-link-facets ()
  "Facet counts combine supported kinds and omit single-use link targets."
  (supertag-tag-cards-test--with-store
    (let ((records (supertag-view-tag-cards--all-facets-for-node-ids
                    '("n1" "n2" "n3"))))
      (should (= 2 (plist-get (supertag-tag-cards-test--record
                               'tag "project" records) :count)))
      (should (= 2 (plist-get (supertag-tag-cards-test--record
                               'tag "reading" records) :count)))
      (should (= 2 (plist-get (supertag-tag-cards-test--record
                               'todo "TODO" records) :count)))
      (should (= 2 (plist-get (supertag-tag-cards-test--record
                               'link "target" records) :count)))
      (should-not (supertag-tag-cards-test--record 'link "solo" records)))))

(ert-deftest supertag-tag-cards-narrows-filters-by-intersection ()
  "A tag plus TODO facet means intersection, never a union."
  (supertag-tag-cards-test--with-store
    (should (equal '("n1")
                   (supertag-view-tag-cards--node-ids-for-filters
                    (list (cons 'tag "project")
                          (cons 'todo "TODO")))))
    (should (equal '("n1")
                   (supertag-view-tag-cards--node-ids-for-filters
                    (list (cons 'tag "reading")
                          (cons 'tag "project")))))
    (should-not
     (supertag-view-tag-cards--node-ids-for-filters
      (list (cons 'tag "writing") (cons 'todo "TODO"))))
    ;; A parent filter includes a node that carries only its child tag.
    (should (equal '("n4" "target")
                   (supertag-view-tag-cards--node-ids-for-filters
                   (list (cons 'tag "archive")))))))

(ert-deftest supertag-tag-cards-drill-down-hides-singleton-continuations ()
  "Drill-down cards retain only repeated continuations when one exists."
  (supertag-tag-cards-test--with-store
    (let ((records
           (supertag-view-tag-cards--filtered-card-records
            '("n1" "n2") (list (cons 'tag "project")))))
      (should (equal (list (cons 'link "target"))
                     (mapcar (lambda (record) (plist-get record :facet))
                             records)))
      (should (= 2 (plist-get (car records) :count))))))

(ert-deftest supertag-tag-cards-drill-down-keeps-singletons-as-empty-grid-fallback ()
  "A drill-down with only singleton continuations still shows its one card."
  (supertag-tag-cards-test--with-store
    (let ((records
           (supertag-view-tag-cards--filtered-card-records
            '("n1") (list (cons 'tag "project") (cons 'todo "TODO")))))
      (should (equal (list (cons 'tag "reading"))
                     (mapcar (lambda (record) (plist-get record :facet))
                             records)))
      (should (= 1 (plist-get (car records) :count))))))

(ert-deftest supertag-tag-cards-label-budgets-follow-responsive-tracks ()
  "Card labels have a finite track budget at desktop and narrow widths."
  (should (= 3 (supertag-view-tag-cards--grid-columns 120)))
  (should (= 2 (supertag-view-tag-cards--grid-columns 80)))
  (should (equal '(38 38 38)
                 (supertag-view-tag-cards--card-track-widths 120)))
  (should (equal '(39 38)
                 (supertag-view-tag-cards--card-track-widths 80)))
  (let ((label (supertag-view-tag-cards--truncate
                "A title deliberately longer than one card track" 12)))
    (should (<= (string-width label) 12))
    (should (string-suffix-p "…" label))))

(defun supertag-tag-cards-test--fake-pixel-width (text)
  "Measure TEXT with a deliberately non-cell CJK/ellipsis test font.

ASCII glyphs are seven pixels, CJK glyphs are 17 pixels, and `…' is nine
pixels.  The final conditional models the first-card context that exposed the
bug: a marker-led line carrying an ellipsis has one extra cell of contextual
advance, whereas a label measured by itself does not."
  (+ (cl-loop for character across text
              sum (cond
                   ((eq character ?…) 9)
                   ((and (>= character ?\u4e00) (<= character ?\u9fff)) 17)
                   (t 7)))
     (if (and (string-match-p "\\`[↗→] " text)
              (string-match-p "…" text))
         7
       0)))

(defun supertag-tag-cards-test--isolated-ellipsis-fit (text budget)
  "Model the former, incorrect isolated-label pixel fitting for TEXT.

The test uses this only to demonstrate that the sample labels reproduce the
one-cell first-card overshoot.  Production fitting must use the complete line
prefix and suffix instead."
  (let* ((source (supertag-view-tag-cards--normalized-label text))
         (end (length source))
         result)
    (while (and (>= end 0) (not result))
      (let ((candidate (concat (substring source 0 end) "…")))
        (when (<= (supertag-tag-cards-test--fake-pixel-width candidate) budget)
          (setq result candidate)))
      (setq end (1- end)))
    result))

(ert-deftest supertag-tag-cards-truncated-rows-measure-the-whole-prefix ()
  "A contextual pixel font cannot make a first-card label cross its edge.

This batch-safe fake reproduces the reported one-cell overshoot for the first
facet and node samples: an isolated label appears to fit, but the same label
with its marker and count (when present) is seven pixels too wide.  The new
fit loop sees the complete candidate, including `…', and keeps every sampled
row within its absolute pixel target."
  (let ((rows
         '(("facet" "↗ " " 2"
            "[2025-11-05 Wed 22:35] 昨天下午和朋友一起" 266 7)
           ("node" "→ " ""
            "[2025-11-20 Thu 20:12] 在手机上实现一个示例" 252 7)
           ("node" "→ " ""
            "一门语言的表面语法来自哪里？它的数字模型" 252 nil))))
    (cl-letf (((symbol-function 'supertag-view-tag-cards--pixel-layout-p)
               (lambda () t))
              ((symbol-function 'supertag-view-tag-cards--render-width)
               #'supertag-tag-cards-test--fake-pixel-width))
      (dolist (row rows)
        (pcase-let ((`(,kind ,prefix ,suffix ,source ,target ,overshoot) row))
          (let* ((label-budget
                  (- target
                     (supertag-tag-cards-test--fake-pixel-width prefix)
                     (supertag-tag-cards-test--fake-pixel-width suffix)))
                 (isolated (supertag-tag-cards-test--isolated-ellipsis-fit
                            source label-budget))
                 (fitted (supertag-view-tag-cards--fit-label-to-target
                          source prefix suffix target))
                 (old-width (supertag-tag-cards-test--fake-pixel-width
                             (concat prefix isolated suffix)))
                 (new-width (supertag-tag-cards-test--fake-pixel-width
                             (concat prefix fitted suffix))))
            (should (string-suffix-p "…" isolated))
            (should (> old-width target))
            (when overshoot
              (should (= (- old-width target) overshoot)))
            (should (string-suffix-p "…" fitted))
            (should (<= new-width target))
            ;; The facet suffix is a mandatory, visible label/count gap; it
            ;; is part of the same full-line measurement as the marker.
            (when (string= kind "facet")
              (should (string-suffix-p " 2" (concat fitted suffix))))))))))

(defconst supertag-tag-cards-test--card-cell 7
  "Cell width of the fake card font, in pixels.")

(defun supertag-tag-cards-test--card-measure (text)
  "Return TEXT's advance with the reported Iosevka card geometry.

ASCII advances by one seven-pixel cell and every other glyph -- CJK, the
arrows, and the `…' ellipsis -- by fourteen pixels, so the ellipsis is twice
its column count.  Display spacers contribute their declared width."
  (let ((width 0)
        (index 0))
    (while (< index (length text))
      (let ((display (get-text-property index 'display text)))
        (if (and (consp display) (eq (car display) 'space))
            (let ((value (plist-get (cdr display) :width)))
              (setq width (+ width (if (consp value) (car value) value))))
          (setq width
                (+ width (if (< (aref text index) 128)
                             supertag-tag-cards-test--card-cell
                           14)))))
      (setq index (1+ index)))
    width))

(defmacro supertag-tag-cards-test--with-card-metrics (&rest body)
  "Run BODY with the fake card pixel metrics installed."
  (declare (indent 0))
  `(let ((textui--pixel-metrics-override
          (cons #'supertag-tag-cards-test--card-measure
                supertag-tag-cards-test--card-cell))
         (textui--pixel-width-cache nil))
     ,@body))

(defun supertag-tag-cards-test--row-card-edges (text)
  "Return TEXT's `(CARD . EDGE-PIXELS)' pairs in source order.

A card run holds only the card's own line text; TextUI composes the closing
pixel padding of the track after it, so the card's edge is the end of that
run, exactly as `supertag-view-tag-cards-measure' reads it in a live buffer."
  (let ((position 0)
        (limit (length text))
        edges)
    (while (< position limit)
      (let* ((next (next-single-property-change
                    position 'supertag-view-tag-cards--card text limit))
             (card (get-text-property
                    position 'supertag-view-tag-cards--card text)))
        (when card
          (push (cons card
                      (supertag-tag-cards-test--card-measure
                       (substring text 0 next)))
                edges))
        (setq position (or next limit))))
    (nreverse edges)))

(defun supertag-tag-cards-test--card-edges (text)
  "Return TEXT's `(CARD . EDGES)' table with every measured line edge."
  (let ((edges (make-hash-table :test 'equal)))
    (dolist (line (split-string text "\n" t))
      (dolist (edge (supertag-tag-cards-test--row-card-edges line))
        (push (cdr edge) (gethash (car edge) edges))))
    edges))

(ert-deftest supertag-tag-cards-round-nine-failing-rows-keep-every-card-edge ()
  "The eight reported truncated rows keep every card edge in the grid.

The production field grid composes one three-card row with the fake card font:
seven-pixel cells and fourteen pixels for CJK, the arrows, and the `…'
ellipsis, which is the reported Iosevka geometry.  Card 1 must end at its own
38-column track (266px) on all twelve of its lines, and cards 2 and 3 at 553px
and 840px, so no truncation can grow a track and no later card can shift."
  (let* ((fixtures
          '(("n1" facet 2 "[2025-11-05 Wed 22:35] 昨天下午和朋友一起整理笔记")
            ("n2" node nil "[2025-11-20 Thu 20:12] 在手机上实现一个自动同步方案")
            ("n3" node nil "[2026-01-16 Fri 08:40] 在邻居旁边创建一间共享工作室")
            ("n4" facet 2 "[2025-08-26 Tue 23:09] 我今天开始把所有想法写下来")
            ("n5" node nil "一门语言的表面语法来自哪里？它的数字模型如何工作")
            ("n6" node nil "Oibeater：突然觉得有了 AI 后程序猿的工作发生变化")
            ("n7" node nil "我对自己的要求很低：我活在世上，无须证明更多事情")
            ("n8" facet 4 "[2025-11-03 Mon 02:22] 看到 Sky 交出了一份新的提案")))
         (titles (mapcar (lambda (fixture)
                           (cons (nth 0 fixture) (nth 3 fixture)))
                         fixtures))
         (facets (cl-loop for (id kind count _label) in fixtures
                          when (eq kind 'facet)
                          collect (list :facet (cons 'link id) :count count)))
         (nodes (cl-loop for (id kind _count _label) in fixtures
                         when (eq kind 'node) collect id)))
    (cl-letf (((symbol-function 'supertag-view-tag-cards--node-title)
               (lambda (node-id)
                 (or (cdr (assoc node-id titles)) "ordinary note"))))
      (supertag-tag-cards-test--with-card-metrics
        (let* ((width 120)
               (tracks (supertag-view-tag-cards--card-track-widths width))
               (card-1
                (list :budget (nth 0 tracks) :row 0 :column 0
                      :overline "" :title "DIARY / IDEA" :count 8
                      :face 'supertag-view-chip1 :records facets
                      :recent-node-ids nodes :scope '(link . "n1")))
               (card-2
                (list :budget (nth 1 tracks) :row 0 :column 1
                      :overline "" :title "TAG / PROJECT" :count 3
                      :face 'supertag-view-chip2 :records nil
                      :recent-node-ids '("o1" "o2") :scope '(tag . "project")))
               (card-3
                (list :budget (nth 2 tracks) :row 0 :column 2
                      :overline "" :title "TAG / READING" :count 2
                      :face 'supertag-view-chip3 :records nil
                      :recent-node-ids '("o3") :scope '(tag . "reading")))
               (text (textui--render-frame
                      (list (supertag-view-tag-cards--field
                             (list card-1 card-2 card-3) nil width))
                      width))
               (lines (split-string text "\n" t))
               (edges (supertag-tag-cards-test--card-edges text))
               (truncated 0))
          (should (= 12 (length lines)))
          ;; every line of a card reports one and the same edge
          (dolist (card '((0 . 0) (0 . 1) (0 . 2)))
            (let ((values (gethash card edges)))
              (should values)
              (should (= 1 (length (cl-delete-duplicates values :test #'=))))))
          ;; and those edges are the three track ends of the 120-column page
          (should (equal '(266 553 840)
                         (mapcar (lambda (card) (car (gethash card edges)))
                                 '((0 . 0) (0 . 1) (0 . 2)))))
          ;; the eight reported strings are all truncated inside card 1
          (dolist (line lines)
            (let ((end (next-single-property-change
                        0 'supertag-view-tag-cards--card line (length line))))
              (when (string-match-p "…" (substring line 0 end))
                (setq truncated (1+ truncated)))))
          (should (= 8 truncated)))))))

(ert-deftest supertag-tag-cards-editorial-labels-remove-hierarchy-arrows ()
  "Titles and tag facets use slash grammar; only metadata keeps `›'."
  (supertag-tag-cards-test--with-store
    (should (equal "ARCHIVE / ARCHIVE CHILD"
                   (supertag-view-tag-cards--editorial-tag-label "archive-child")))
    (should (equal "TAG / READING"
                   (supertag-view-tag-cards--editorial-tag-label "reading")))
    (should (equal "TODO / DONE"
                   (supertag-view-tag-cards--facet-title '(todo . "DONE"))))
    (should (equal "+ "
                   (supertag-view-tag-cards--facet-marker '(tag . "reading"))))
    (should (equal "◆ "
                   (supertag-view-tag-cards--facet-marker '(todo . "TODO"))))
    (should (equal "↗ "
                   (supertag-view-tag-cards--facet-marker '(link . "target"))))
    (should (equal '((tag . "archive-child"))
                   (supertag-view-tag-cards--display-filters
                    '((tag . "archive") (tag . "archive-child")))))))

(ert-deftest supertag-tag-cards-fills-have-exact-width-and-face ()
  "Editorial fills include their padding in the whole accent surface."
  (let* ((fill (supertag-view-tag-cards--filled-title-string
                "日记 / 想法" 104 18 'supertag-view-chip1))
         (plain (supertag-view-tag-cards--filled-string
                 "SUPERTAG / TAGS" 20 'supertag-view-chip3)))
    (should (= 18 (string-width fill)))
    (should (= 20 (string-width plain)))
    (should-not (text-property-not-all
                 0 (length fill) 'face 'supertag-view-chip1 fill))
    (should-not (text-property-not-all
                 0 (length plain) 'face 'supertag-view-chip3 plain))))

(ert-deftest supertag-tag-cards-grid-cards-keep-column-exact-tracks-in-batch ()
  "The native grid keeps 120/80 tracks and never overflows."
  (supertag-tag-cards-test--with-store
    (dolist (width '(120 80))
      (with-temp-buffer
        (supertag-view-tag-cards-mode)
        (let* ((textui-state '(:filter nil :group nil :limit-nodes 5))
               (text (textui--render-frame
                      (supertag-view-tag-cards--frame width) width)))
          (should (cl-every (lambda (line) (<= (string-width line) width))
                            (split-string text "\n" nil)))
          (supertag-tag-cards-test--assert-grid-tracks text width))))))

(ert-deftest supertag-tag-cards-sibling-groups-share-a-chip-face ()
  "A hierarchy's root and child share a rotated accent; loose tags use chip2."
  (supertag-tag-cards-test--with-store
    (should (eq (supertag-view-tag-cards--card-chip-face '(tag . "archive"))
                (supertag-view-tag-cards--card-chip-face
                 '(tag . "archive-child"))))
    (should (eq 'supertag-view-chip2
                (supertag-view-tag-cards--card-chip-face '(tag . "reading"))))))

(defun supertag-tag-cards-test--buffer-face-background (face)
  "Return FACE's buffer-local remapped background, or nil."
  (let ((specs (cdr (assq face face-remapping-alist)))
        result)
    (dolist (spec specs)
      (when (and (listp spec) (plist-member spec :background))
        (setq result (plist-get spec :background))))
    result))

(defun supertag-tag-cards-test--palette-face-background (palette face)
  "Return PALETTE's FACE background for the current background mode."
  (let* ((entry (assq face (cdr (assq palette supertag-view-palettes))))
         (spec (if (eq (frame-parameter nil 'background-mode) 'dark)
                   (cddr entry)
                 (cadr entry))))
    (plist-get spec :background)))

(ert-deftest supertag-tag-cards-materialized-fills-keep-their-faces ()
  "TextUI attachment preserves masthead and fill faces and the neon palette."
  (supertag-tag-cards-test--with-store
    (let ((name supertag-view-tag-cards--buffer-name)
          buffer)
      (when-let* ((old (get-buffer name)))
        (kill-buffer old))
      (unwind-protect
          (progn
            ;; Start with the bad global-style wrapping state.  The command
            ;; must restore its no-wrap locals after `textui-open' displays
            ;; and materializes the buffer.
            (setq buffer (get-buffer-create name))
            (with-current-buffer buffer
              (supertag-view-tag-cards-mode)
              (visual-line-mode 1)
              (setq-local word-wrap t))
            (setq buffer (supertag-view-tag-cards))
            (with-current-buffer buffer
              ;; The buffer-local neon remap must survive TextUI
              ;; materialization and the card grid.
              (should (eq 'neon supertag-view--local-palette))
              (should (eq 'neon supertag-view-tag-cards-palette))
              (should (equal (supertag-tag-cards-test--palette-face-background
                              'neon 'supertag-view-chip1)
                             (supertag-tag-cards-test--buffer-face-background
                              'supertag-view-chip1)))
              (should-not (equal (supertag-tag-cards-test--palette-face-background
                                  'paper 'supertag-view-chip1)
                                 (supertag-tag-cards-test--buffer-face-background
                                  'supertag-view-chip1)))
              (goto-char (point-min))
              (should (search-forward "SUPERTAG / TAGS" nil t))
              (should (eq (get-text-property (match-beginning 0) 'face)
                          'supertag-view-chip1))
              (goto-char (point-min))
              (should (search-forward "TAG / PROJECT" nil t))
              (should (eq (get-text-property (match-beginning 0) 'face)
                          'supertag-view-chip2))
              (goto-char (point-min))
              (should (search-forward "→ Read the guide" nil t))
              ;; Facet and entry rows are native widget links now: they carry a
              ;; widget button overlay (not a button.el text button).
              (let ((button (get-char-property (match-beginning 0) 'button)))
                (should button)
                (should (functionp (widget-get button :action))))
              (should truncate-lines)
              (should-not word-wrap)
              (should-not visual-line-mode)))
        ;; Tag Cards never changes the global palette: a plain buffer still
        ;; resolves chip1 through the framework's paper spec.
        (should (eq 'paper supertag-view-palette))
        (with-temp-buffer
          (should (equal (supertag-tag-cards-test--palette-face-background
                          'paper 'supertag-view-chip1)
                         (face-background 'supertag-view-chip1 nil t))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest supertag-tag-cards-measure-reports-column-aligned-batch-tracks ()
  "The live measurement command sees all local card spans in a terminal."
  (supertag-tag-cards-test--with-store
    (let ((name supertag-view-tag-cards--buffer-name)
          (report-name "*Supertag Tag Cards Measurement*")
          buffer report)
      (when-let* ((old (get-buffer name)))
        (kill-buffer old))
      (when-let* ((old-report (get-buffer report-name)))
        (kill-buffer old-report))
      (unwind-protect
          (progn
            (setq buffer (supertag-view-tag-cards))
            (setq report
                  (with-current-buffer buffer
                    (supertag-view-tag-cards-measure)))
            (with-current-buffer report
              (should (string-match-p "row=01 card=1 PASS COLUMN-ONLY"
                                      (buffer-string)))))
        (when (buffer-live-p report)
          (kill-buffer report))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(provide 'tag-cards-test)
;;; tag-cards-test.el ends here
