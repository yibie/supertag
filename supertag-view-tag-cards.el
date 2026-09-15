;;; supertag-view-tag-cards.el --- Browse Semantic Tags as responsive cards -*- lexical-binding: t; -*-

;;; Commentary:
;; Commands: supertag-view-tag-cards.
;; Dependencies: cl-lib, subr-x, widget, textui, textui-widgets,
;; supertag-core-store, supertag-query, supertag-tag, supertag-node,
;; supertag-view-framework.
;;
;; This is an experimental, read-only TextUI magazine view.  It owns no Store
;; mutations: every card and facet is computed from the current projections.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'widget)
(require 'textui)
(require 'textui-widgets)

(declare-function supertag-goto-node "supertag-node" (node-id &optional other-window))
(declare-function supertag-store-get-collection "supertag-core-store" (collection))
(declare-function supertag-view-api-get-entity "supertag-query" (type entity-id))
(declare-function supertag-find-nodes-by-tag "supertag-query"
                  (tag-name &optional include-descendants))
(declare-function supertag-query-ordinary-references-from "supertag-query" (node-id))
(declare-function supertag-view-api-subscribe "supertag-view-framework" (event fn))
(declare-function supertag-tag-get "supertag-tag" (id))
(declare-function supertag-tag-ancestors "supertag-tag" (tag-id))
(declare-function supertag-tag-descendants "supertag-tag" (tag-id))
(declare-function supertag-tag-display-name "supertag-tag" (tag-id))
(declare-function supertag-view-register-modal-state "supertag-view-framework" (mode))
(declare-function supertag-view-apply-palette-locally "supertag-view-framework" (name))

(defgroup supertag-view-tag-cards nil
  "Responsive Semantic Tag cards."
  :group 'supertag)

(defcustom supertag-view-tag-cards-favorite-groups nil
  "Semantic Tag IDs shown as Favorite groups.

Nil means show every tag that has one or more `:extends' children."
  :type '(repeat string)
  :group 'supertag-view-tag-cards)

(defcustom supertag-view-tag-cards-manifesto
  '("MAKE ROOM"
    "FOR THE UNEXPECTED."
    "Tags are fuel. The connections are computed for you: click any + row to narrow.")
  "Three lines of editorial copy displayed below the Tag Cards masthead.

The first two lines are rendered in uppercase; the third remains sentence
case.  Supplying fewer than three strings falls back to the corresponding
default line."
  :type '(repeat string)
  :group 'supertag-view-tag-cards)

(defcustom supertag-view-tag-cards-palette 'neon
  "Palette applied buffer-locally in the Tag Cards buffer.

Tag Cards keeps the `neon' role faces of design.md section 2 while the
global `supertag-view-palette' and Node View use `paper'."
  :type '(choice (const paper) (const neon) (const ink) (const ocean))
  :group 'supertag-view-tag-cards)

(defconst supertag-view-tag-cards--buffer-name "*Supertag Tag Cards*"
  "Name of the one Tag Cards buffer.")

(defconst supertag-view-tag-cards--maximum-columns 3
  "Maximum number of card columns.")

(defconst supertag-view-tag-cards--minimum-card-width 34
  "Smallest supported card width in character cells.")

(defconst supertag-view-tag-cards--node-limit 5
  "Default number of recent nodes shown in a card.")

(defconst supertag-view-tag-cards--grid-gap 3
  "Horizontal and vertical gap between card grid cells.")

(defconst supertag-view-tag-cards--text-button-chrome-width 4
  "Width contributed by the `[ ' and ` ]' around a TextUI text button.")

(defvar-local supertag-view-tag-cards--unsubscribe nil
  "Store subscription cleanup function for the current cards buffer.")

(defun supertag-view-tag-cards--button-face (_widget)
  "Keep Tag Cards controls on the ordinary `widget-button' face."
  'widget-button)

(define-widget 'supertag-view-tag-cards-button 'textui-button
  "A fast-attached traditional Emacs text button for Tag Cards."
  :button-face-get #'supertag-view-tag-cards--button-face)

(defun supertag-view-tag-cards--item-measure (widget)
  "Return WIDGET's attributed static value without dropping its face.

TextUI's stock `item' measurement deliberately uses a property-free buffer
substring.  Magazine fills need their background face in the batch renderer
as well as in the materialized view buffer, so this derived item provides the
same text together with its properties."
  (copy-sequence (format "%s" (or (widget-get widget :value) ""))))

(defun supertag-view-tag-cards--item-attach (widget from to)
  "Attach static WIDGET to its measured text from FROM through TO.

Unlike a stock `item', this keeps TextUI's measured, face-bearing text in the
materialized buffer.  TextUI otherwise deletes the placeholder and calls the
widget's normal creator, whose inserted value has no guarantee of retaining
the face properties used by Tag Cards fills."
  (widget-put widget :from (copy-marker from t))
  (widget-put widget :to (copy-marker to nil))
  (widget-put widget :delete #'widget-leave-text)
  (widget-put widget :textui-attached t)
  ;; The measured text already has these faces.  Copy them from the widget
  ;; value too, so materialization remains correct if a TextUI cleanup step
  ;; has removed properties other than its own placeholder marker.
  (let* ((value (format "%s" (or (widget-get widget :value) "")))
         (length (min (length value) (- to from)))
         (position 0))
    (while (< position length)
      (let ((next (next-single-property-change position 'face value length))
            (face (get-text-property position 'face value)))
        (when face
          (put-text-property (+ from position) (+ from next) 'face face))
        (setq position next)))))

(define-widget 'supertag-view-tag-cards-item 'item
  "A static TextUI item whose attributed value survives measurement."
  :format "%v"
  :textui-measure #'supertag-view-tag-cards--item-measure
  :textui-attach #'supertag-view-tag-cards--item-attach)

(defun supertag-view-tag-cards--card-row-block-layout (widget width)
  "Return WIDGET's precomposed card row at TextUI WIDTH.

This is a top-level TextUI attached block: its layout owns the complete row,
  including the inter-card gaps, because TextUI's public flex/grid API measures
  those tracks in columns rather than the GUI's actual glyph pixels."
  (if-let* ((cards (widget-get widget :cards)))
      (supertag-view-tag-cards--compose-card-row
       cards width (widget-get widget :row-index))
    (or (widget-get widget :value) "\n")))

(defun supertag-view-tag-cards--card-row-block-attach (widget from to)
  "Attach WIDGET's row buttons without changing its composed text.

Each action span is a plain Emacs text button, rather than a nested widget.el
control: a TextUI attached block is necessarily precomposed and cannot contain
native child widgets."
  (widget-put widget :from (copy-marker from t))
  (widget-put widget :to (copy-marker to nil))
  (widget-put widget :delete
              (lambda (active-widget)
                (delete-region (widget-get active-widget :from)
                               (widget-get active-widget :to))
                (set-marker (widget-get active-widget :from) nil)
                (set-marker (widget-get active-widget :to) nil)))
  (widget-put widget :textui-attached t)
  ;; TextUI converts a fresh widget at materialization time, so layout-local
  ;; widget properties are not available here.  The precomposed text itself
  ;; carries the actions until this callback turns those exact spans into
  ;; ordinary Emacs buttons.
  (let ((position from))
    (while (< position to)
      (let* ((action (get-text-property
                      position 'supertag-view-tag-cards--button-action))
             (next (next-single-property-change
                    position 'supertag-view-tag-cards--button-action nil to)))
        (when action
          (make-text-button position next
                            'action action
                            'follow-link t
                            'face 'widget-button))
        (setq position next)))))

(define-widget 'supertag-view-tag-cards-card-row-block 'item
  "A top-level attached block that locally composes one row of cards."
  :textui-layout #'supertag-view-tag-cards--card-row-block-layout
  :textui-attach #'supertag-view-tag-cards--card-row-block-attach)

(defun supertag-view-tag-cards--link-measure (widget)
  "Return the exact bracket-free label displayed by link WIDGET."
  (format "%s" (or (widget-get widget :tag)
                    (widget-get widget :value)
                    "")))

(defun supertag-view-tag-cards--link-value-create (widget)
  "Insert the exact bracket-free label for link WIDGET."
  (insert (supertag-view-tag-cards--link-measure widget)))

(defun supertag-view-tag-cards--link-attach (widget from to)
  "Attach link WIDGET to unchanged TextUI text between FROM and TO."
  (widget-put widget :from (copy-marker from t))
  (widget-put widget :to (copy-marker to nil))
  (widget-put widget :delete #'widget-leave-text)
  (widget-put widget :textui-attached t)
  (widget-specify-button widget from to))

(define-widget 'supertag-view-tag-cards-link 'link
  "A bracket-free, TextUI-attached link for dense card rows."
  :button-prefix ""
  :button-suffix ""
  :button-face-get #'supertag-view-tag-cards--button-face
  :value-create #'supertag-view-tag-cards--link-value-create
  :textui-measure #'supertag-view-tag-cards--link-measure
  :textui-attach #'supertag-view-tag-cards--link-attach)

(defun supertag-view-tag-cards--truncate (text width)
  "Return TEXT collapsed and limited to WIDTH display columns with `…'."
  (let ((normalized
         (replace-regexp-in-string
          "[[:space:]\n]+" " " (string-trim (format "%s" (or text ""))))))
    (truncate-string-to-width normalized (max 1 width) nil nil "…")))

(defun supertag-view-tag-cards--display-window ()
  "Return the visible window for the current Tag Cards buffer, if any.

Text renders and batch buffers intentionally return nil: they have no GUI
pixel geometry, so their deterministic `string-width' layout remains the
fallback." 
  (let ((window (get-buffer-window (current-buffer) 0)))
    (and (window-live-p window)
         (display-graphic-p (window-frame window))
         window)))

(defun supertag-view-tag-cards--track-pixel-width (columns)
  "Return COLUMNS' actual GUI track width in pixels, or nil in batch.

The calculation deliberately uses the displayed window's frame character
width instead of a hard-coded pixel value.  TextUI lays out in columns, but
this view can keep wide CJK glyphs within that column-derived pixel track."
  (when-let* ((window (supertag-view-tag-cards--display-window))
              (character-width (frame-char-width (window-frame window))))
    (* (max 1 columns) character-width)))

(defun supertag-view-tag-cards--string-pixel-width (text)
  "Return TEXT's pixel width in the current Tag Cards display window."
  (let ((window (supertag-view-tag-cards--display-window)))
    (when window
      (with-selected-window window
        ;; Supplying the live buffer explicitly retains its face remaps and
        ;; default/fallback font configuration while a TextUI refresh is
        ;; composing an unattached string.
        (string-pixel-width text (window-buffer window))))))

(defun supertag-view-tag-cards--pixel-layout-p ()
  "Return non-nil when the current card layout has GUI pixel geometry."
  (and (supertag-view-tag-cards--display-window) t))

(defun supertag-view-tag-cards--normalized-label (text)
  "Return TEXT as one trimmed, whitespace-collapsed display label."
  (replace-regexp-in-string
   "[[:space:]\n]+" " " (string-trim (format "%s" (or text "")))))

(defun supertag-view-tag-cards--fit-label-to-target (text prefix suffix target)
  "Fit TEXT between PREFIX and SUFFIX before absolute TARGET.

PREFIX is the complete, already composed line prefix, not merely the local
card track.  SUFFIX contains every required reservation, including the marker
or the mandatory space and count.  In a GUI each candidate is measured as the
whole line, with its `…' appended, before it is accepted.  That is important:
measuring an isolated label can be one cell short at the first card boundary
when the surrounding prefix changes the rendered advance.  Batch rendering
uses the equivalent `string-width' calculation."
  (let* ((label (supertag-view-tag-cards--normalized-label text))
         (available (- target
                       (supertag-view-tag-cards--render-width prefix)
                       (supertag-view-tag-cards--render-width suffix))))
    (cond
     ((or (string-empty-p label) (<= available 0)) "")
     ((not (supertag-view-tag-cards--pixel-layout-p))
      (supertag-view-tag-cards--truncate label available))
     ;; Do not first make a column-estimated version of LABEL.  The complete
     ;; untruncated candidate is the only valid fast path in a GUI.
     ((<= (supertag-view-tag-cards--render-width
           (concat prefix label suffix))
          target)
      label)
     (t
      (let* ((ellipsis "…")
             ;; Avoid turning an already abbreviated source into `……'.
             (source (if (string-suffix-p ellipsis label)
                         (substring label 0 -1)
                       label))
             (end (length source))
             result)
        ;; Include END = 0 so a bare ellipsis remains possible when it fits
        ;; between the complete prefix and suffix.
        (while (and (>= end 0) (not result))
          (let ((candidate (concat (substring source 0 end) ellipsis)))
            ;; This must be the full candidate.  In particular, do not use a
            ;; column estimate for the ellipsis or a label-only pixel width.
            (when (<= (supertag-view-tag-cards--render-width
                       (concat prefix candidate suffix))
                      target)
              (setq result candidate)))
          (setq end (1- end)))
        (or result ""))))))

(defun supertag-view-tag-cards--truncate-for-track (text columns &optional reserve)
  "Fit TEXT inside COLUMNS after reserving RESERVE's visible width.

RESERVE is measured as the required suffix of the same candidate.  Callers
which are composing a card row should use `--fit-label-to-target' directly so
the complete line prefix takes part in the GUI measurement too."
  (supertag-view-tag-cards--fit-label-to-target
   text "" (or reserve "")
   (supertag-view-tag-cards--target-width (max 1 columns))))

(defun supertag-view-tag-cards--pad-right (text width)
  "Return TEXT right-padded within WIDTH display columns and GUI pixels.

In a GUI buffer, add only spaces that still fit the column-derived pixel
track.  A wide CJK row can therefore end a little short of the right edge,
rather than spilling into the next visual line."
  (let* ((limit (max 1 width))
         (fitted (supertag-view-tag-cards--truncate-for-track text limit))
         (pixels (supertag-view-tag-cards--track-pixel-width limit))
         (result fitted))
    (while (< (string-width result) limit)
      (let ((candidate (concat result " ")))
        (if (and pixels
                 (> (or (supertag-view-tag-cards--string-pixel-width candidate)
                        most-positive-fixnum)
                    pixels))
            ;; Do not fill the remaining columns: that final space is already
            ;; too wide in this font, and preserving the pixel boundary wins.
            (setq limit (string-width result))
          (setq result candidate))))
    result))

(defun supertag-view-tag-cards--pad-between (left right width)
  "Place LEFT and RIGHT in WIDTH columns without exceeding its GUI track.

RIGHT is normally a facet or title count.  The batch fallback pads exactly to
WIDTH; in a GUI the gap may be shorter when another space would exceed the
pixel track." 
  (let* ((limit (max 1 width))
         (pixels (supertag-view-tag-cards--track-pixel-width limit))
         (spaces (max 0 (- limit (string-width left) (string-width right))))
         (result left))
    (while (> spaces 0)
      (let ((candidate (concat result " " right)))
        (if (and pixels
                 (> (or (supertag-view-tag-cards--string-pixel-width candidate)
                        most-positive-fixnum)
                    pixels))
            (setq spaces 0)
          (setq result (concat result " ")
                spaces (1- spaces)))))
    (concat result right)))

(defun supertag-view-tag-cards--render-width (text)
  "Return TEXT's width in the active GUI's pixels, else in display columns."
  (or (supertag-view-tag-cards--string-pixel-width text)
      (string-width text)))

(defun supertag-view-tag-cards--target-width (columns)
  "Return COLUMNS in the active GUI's pixels, else in display columns."
  (or (supertag-view-tag-cards--track-pixel-width columns)
      columns))

(defun supertag-view-tag-cards--spacer-to-width (prefix target &optional face)
  "Return relative Variant-C padding from PREFIX to absolute TARGET width.

On a GUI, use as many ordinary spaces as fit and one display-only residual
space.  Measuring the whole PREFIX is important: a preceding CJK glyph or an
earlier residual spacer must not shift this card's edge or the next card's
left edge.  FACE, when non-nil, is applied to all padding characters."
  (let ((remaining (- target (supertag-view-tag-cards--render-width prefix))))
    (when (> remaining 0)
      (let ((spacer
             (if (supertag-view-tag-cards--display-window)
                 (let* ((space-width
                         (max 1 (supertag-view-tag-cards--render-width " ")))
                        (whole (/ remaining space-width))
                        (residual (% remaining space-width)))
                   (concat
                    (make-string whole ?\s)
                    (when (> residual 0)
                      (propertize " " 'display `(space :width (,residual))))))
               (make-string remaining ?\s))))
        (if face (propertize spacer 'face face) spacer)))))

(defun supertag-view-tag-cards--append-to-width (prefix target &optional face)
  "Append Variant-C padding to PREFIX until absolute TARGET is reached."
  (concat prefix
          (or (supertag-view-tag-cards--spacer-to-width prefix target face) "")))

(defun supertag-view-tag-cards--append-to-cell (prefix cell &optional face)
  "Append Variant-C padding to PREFIX until absolute CELL is reached."
  (supertag-view-tag-cards--append-to-width
   prefix (supertag-view-tag-cards--target-width cell) face))

(defun supertag-view-tag-cards--filled-string (label width face)
  "Return LABEL as a FACE-filled string exactly WIDTH columns wide.

One leading and trailing space are reserved inside a normal-width fill.  The
face is intentionally applied to every character, including its padding, so
the accent is an area rather than colored ink."
  (let* ((limit (max 1 width))
         (content (supertag-view-tag-cards--truncate-for-track label limit "  "))
         (text (if (>= limit 3)
                   (concat (supertag-view-tag-cards--pad-right
                            (concat " " content) (1- limit))
                           " ")
                 (supertag-view-tag-cards--pad-right content limit))))
    (propertize text 'face face)))

(defun supertag-view-tag-cards--filled-title-string (label count width face)
  "Return a FACE-filled LABEL and right-aligned COUNT at exactly WIDTH.

The count is inside the same accent surface as the card identity, matching the
card template while keeping the entire background an unbroken fill."
  (let* ((limit (max 1 width))
         (count-text (format "%s" count)))
    (if (< limit 3)
        (propertize (supertag-view-tag-cards--pad-right label limit) 'face face)
      (let* ((title (supertag-view-tag-cards--truncate-for-track
                     label limit (concat " " count-text " ")))
             (text (supertag-view-tag-cards--pad-between
                    (concat " " title) (concat count-text " ") limit)))
        (propertize text 'face face)))))

(defun supertag-view-tag-cards--grid-columns (width)
  "Return the responsive grid column count at available WIDTH."
  (max 1
       (min supertag-view-tag-cards--maximum-columns
            (/ (+ width supertag-view-tag-cards--grid-gap)
               (+ supertag-view-tag-cards--minimum-card-width
                  supertag-view-tag-cards--grid-gap)))))

(defun supertag-view-tag-cards--card-track-widths (width)
  "Return the exact TextUI grid track widths at page WIDTH.

TextUI gives remainder cells to earlier equal-weight tracks.  Cards use these
same widths before constructing their fills, so a 80-column two-track render
can use 39 and 38 rather than leaving an unfilled trailing cell in track one."
  (let* ((columns (supertag-view-tag-cards--grid-columns width))
         (available (max 1 (- width
                              (* supertag-view-tag-cards--grid-gap
                                 (1- columns)))))
         (base (/ available columns))
         (remainder (% available columns)))
    (cl-loop for index below columns
             collect (+ base (if (< index remainder) 1 0)))))

(defun supertag-view-tag-cards--card-content-budget (width &optional column)
  "Return page WIDTH's exact card track for COLUMN, defaulting to the first.

Cards intentionally have neither borders nor padding, so their complete grid
track is available to labels and accent fills."
  (or (nth (or column 0) (supertag-view-tag-cards--card-track-widths width))
      1))

(defun supertag-view-tag-cards--all-tag-ids ()
  "Return every live Semantic Tag ID in deterministic display order."
  (let (ids)
    (maphash
     (lambda (tag-id tag)
       (when (and (stringp tag-id) (listp tag))
         (push tag-id ids)))
     (supertag-store-get-collection :tags))
    (sort ids
          (lambda (left right)
            (string-lessp (supertag-view-tag-cards--tag-label left)
                          (supertag-view-tag-cards--tag-label right))))))

(defun supertag-view-tag-cards--tag-label (tag-id)
  "Return the hierarchy-aware display label for TAG-ID."
  (or (ignore-errors (supertag-tag-display-name tag-id))
      (plist-get (supertag-tag-get tag-id) :name)
      tag-id))

(defun supertag-view-tag-cards--editorial-tag-label (tag-id)
  "Return TAG-ID in uppercase `NOUN / NOUN' hierarchy grammar."
  (let ((label (supertag-view-tag-cards--compact-tag-label tag-id)))
    ;; A root has no hierarchy separator of its own.  Give it a stable noun
    ;; prefix so its title fill follows the same editorial two-noun grammar.
    (if (string-match-p " / " label) label (format "TAG / %s" label))))

(defun supertag-view-tag-cards--compact-tag-label (tag-id)
  "Return TAG-ID uppercase with slash-separated hierarchy, without a prefix.

This shorter form is for traditional action buttons, which are controls rather
than filled editorial identities."
  (upcase
   (replace-regexp-in-string
    "[[:space:]]*›[[:space:]]*" " / "
    (supertag-view-tag-cards--tag-label tag-id))))

(defun supertag-view-tag-cards--editorial-facet-label (facet)
  "Return FACET as a masthead-safe uppercase editorial label."
  (pcase (car facet)
    ('tag (supertag-view-tag-cards--editorial-tag-label (cdr facet)))
    ('todo (upcase (cdr facet)))
    ('link (format "LINK / %s"
                   (upcase (supertag-view-tag-cards--node-title (cdr facet)))))
    (_ (upcase (supertag-view-tag-cards--facet-label facet)))))

(defun supertag-view-tag-cards--node (node-id)
  "Return read-only node projection for NODE-ID, or nil."
  (when (and (stringp node-id) (not (string-empty-p node-id)))
    (supertag-view-api-get-entity :nodes node-id)))

(defun supertag-view-tag-cards--node-title (node-id)
  "Return a useful single-line title for NODE-ID."
  (let ((node (supertag-view-tag-cards--node node-id)))
    (string-trim
     (format "%s"
             (or (plist-get node :title)
                 (plist-get node :raw-value)
                 node-id)))))

(defun supertag-view-tag-cards--node-ids-for-tag (tag-id)
  "Return node IDs carrying TAG-ID or any of its descendants."
  (mapcar #'car (supertag-find-nodes-by-tag tag-id t)))

(defun supertag-view-tag-cards--facet-p (facet)
  "Return non-nil when FACET has the `(KIND . VALUE)' representation."
  (and (consp facet)
       (memq (car facet) '(tag todo link))
       (stringp (cdr facet))
       (not (string-empty-p (cdr facet)))))

(defun supertag-view-tag-cards--facet-label (facet)
  "Return the user-facing label for FACET."
  (pcase (car facet)
    ('tag (supertag-view-tag-cards--tag-label (cdr facet)))
    ('todo (cdr facet))
    ('link (supertag-view-tag-cards--node-title (cdr facet)))
    (_ (format "%s" (cdr facet)))))

(defun supertag-view-tag-cards--facet-title (facet)
  "Return a `NOUN / NOUN' card title for FACET."
  (pcase (car facet)
    ('tag (supertag-view-tag-cards--editorial-tag-label (cdr facet)))
    ('todo (format "TODO / %s" (upcase (supertag-view-tag-cards--facet-label facet))))
    ('link (format "LINK / %s" (upcase (supertag-view-tag-cards--facet-label facet))))
    (_ (upcase (supertag-view-tag-cards--facet-label facet)))))

(defun supertag-view-tag-cards--node-has-tag-p (node tag-id)
  "Return non-nil when NODE belongs to TAG-ID's inherited tag family."
  (cl-some (lambda (node-tag)
             (or (equal node-tag tag-id)
                 (member tag-id (supertag-tag-ancestors node-tag))))
           (or (plist-get node :tags) '())))

(defun supertag-view-tag-cards--node-matches-facet-p (node facet)
  "Return non-nil when NODE matches FACET without changing Store data."
  (pcase (car-safe facet)
    ('tag (supertag-view-tag-cards--node-has-tag-p node (cdr facet)))
    ('todo (equal (plist-get node :todo) (cdr facet)))
    ('link (cl-some (lambda (relation)
                      (equal (plist-get relation :to) (cdr facet)))
                    (supertag-query-ordinary-references-from
                     (plist-get node :id))))
    (_ nil)))

(defun supertag-view-tag-cards--node-ids-for-filters (filters)
  "Return node IDs that satisfy every `(KIND . VALUE)' in FILTERS.

An empty FILTERS list returns the IDs of all nodes carrying a Semantic Tag.
The function is deliberately data-only so it is also the test seam for
intersection narrowing."
  (let (node-ids)
    (maphash
     (lambda (node-id node)
       (when (and (listp node)
                  (or filters (plist-get node :tags))
                  (cl-every (lambda (facet)
                              (supertag-view-tag-cards--node-matches-facet-p
                               node facet))
                            filters))
         (push node-id node-ids)))
     (supertag-store-get-collection :nodes))
    (sort node-ids #'string-lessp)))

(defun supertag-view-tag-cards--facet-record (facet count)
  "Return an immutable display record for FACET and COUNT."
  (list :facet facet
        :kind (car facet)
        :value (cdr facet)
        :label (supertag-view-tag-cards--facet-label facet)
        :count count))

(defun supertag-view-tag-cards--all-facets-for-node-ids
    (node-ids &optional excluded-tag-ids)
  "Return every counted facet co-occurring in NODE-IDS.

EXCLUDED-TAG-IDS removes a card's own tag and ancestor tags from its tag rows.
Link targets with only one occurrence are omitted as low-signal facets."
  (let ((counts (make-hash-table :test 'equal)))
    (dolist (node-id node-ids)
      (when-let* ((node (supertag-view-tag-cards--node node-id)))
        (dolist (tag-id (or (plist-get node :tags) '()))
          (unless (member tag-id excluded-tag-ids)
            (let ((facet (cons 'tag tag-id)))
              (puthash facet (1+ (gethash facet counts 0)) counts))))
        (when-let* ((todo (plist-get node :todo)))
          (let ((facet (cons 'todo (format "%s" todo))))
            (puthash facet (1+ (gethash facet counts 0)) counts)))
        ;; A link facet counts the number of source nodes, not duplicate
        ;; relation records emitted by one source node.
        (let ((targets (make-hash-table :test 'equal)))
          (dolist (relation (supertag-query-ordinary-references-from node-id))
            (when-let* ((target (plist-get relation :to)))
              (puthash target t targets)))
          (maphash
           (lambda (target _present)
             (let ((facet (cons 'link target)))
               (puthash facet (1+ (gethash facet counts 0)) counts)))
           targets))))
    (let (facets)
      (maphash
       (lambda (facet count)
         (when (or (not (eq (car facet) 'link)) (> count 1))
           (push (supertag-view-tag-cards--facet-record facet count) facets)))
       counts)
      (sort facets
            (lambda (left right)
              (let ((left-count (plist-get left :count))
                    (right-count (plist-get right :count))
                    (left-label (plist-get left :label))
                    (right-label (plist-get right :label)))
                (if (= left-count right-count)
                    (if (string= left-label right-label)
                        (string-lessp (symbol-name (plist-get left :kind))
                                      (symbol-name (plist-get right :kind)))
                      (string-lessp left-label right-label))
                  (> left-count right-count))))))))

(defun supertag-view-tag-cards--facets-for-node-ids
    (node-ids &optional excluded-tag-ids)
  "Return the six highest-count facets co-occurring in NODE-IDS."
  (seq-take (supertag-view-tag-cards--all-facets-for-node-ids
             node-ids excluded-tag-ids)
            6))

(defun supertag-view-tag-cards--facet-member-p (facet facets)
  "Return non-nil when FACET occurs in FACETS by structural equality."
  (cl-member facet facets :test #'equal))

(defun supertag-view-tag-cards--display-filters (filters)
  "Return FILTERS without tag ancestors implied by a more specific tag.

Facet clicks retain both constraints in state for straightforward intersection
semantics.  The masthead omits the redundant ancestor, so clicking `DIARY /
IDEA' from the DIARY card reads as that one editorial label rather than
`DIARY ∩ DIARY / IDEA'."
  (cl-remove-if
   (lambda (facet)
     (and (eq (car facet) 'tag)
          (cl-some
           (lambda (other)
             (and (not (equal facet other))
                  (eq (car other) 'tag)
                  (member (cdr facet)
                          (supertag-tag-ancestors (cdr other)))))
           filters)))
   filters))

(defun supertag-view-tag-cards--recent-node-ids (node-ids limit)
  "Return up to LIMIT NODE-IDS, newest `:created-at' first."
  (seq-take
   (sort (copy-sequence node-ids)
         (lambda (left right)
           (let ((left-time (plist-get (supertag-view-tag-cards--node left)
                                       :created-at))
                 (right-time (plist-get (supertag-view-tag-cards--node right)
                                        :created-at)))
             (cond
              ((and left-time right-time) (time-less-p right-time left-time))
              (left-time t)
              (right-time nil)
              (t (string-lessp left right))))))
   limit))

(defun supertag-view-tag-cards--parent-chain (tag-id)
  "Return TAG-ID's ancestor chain for the muted card overline."
  (mapconcat #'supertag-view-tag-cards--tag-label
             (nreverse (supertag-tag-ancestors tag-id)) " › "))

(defconst supertag-view-tag-cards--chip-faces
  '(supertag-view-chip1 supertag-view-chip2 supertag-view-chip3)
  "Accent faces rotated across top-level tag groups.")

(defvar supertag-view-tag-cards--render-chip-face-map nil
  "Dynamically bound root-tag to face map for one complete frame render.")

(defun supertag-view-tag-cards--top-level-group-ids ()
  "Return root tag IDs that structurally contain other tags."
  (cl-remove-if-not
   (lambda (tag-id) (supertag-tag-descendants tag-id))
   (supertag-view-tag-cards--all-tag-ids)))

(defun supertag-view-tag-cards--top-level-tag-id (tag-id)
  "Return the root ancestor of TAG-ID, or TAG-ID itself."
  (let ((ancestors (supertag-tag-ancestors tag-id)))
    (or (car (last ancestors)) tag-id)))

(defun supertag-view-tag-cards--chip-face-map ()
  "Build the root-group chip-face map for the current Store render.

This map lives only in the dynamic extent of one `--frame' call: it prevents
each card from rewalking the hierarchy, without retaining data across a Store
refresh."
  (let ((faces (make-hash-table :test 'equal))
        (index 0))
    (dolist (group-id (supertag-view-tag-cards--top-level-group-ids))
      (puthash group-id
               (nth (mod index (length supertag-view-tag-cards--chip-faces))
                    supertag-view-tag-cards--chip-faces)
               faces)
      (setq index (1+ index)))
    faces))

(defun supertag-view-tag-cards--card-chip-face (facet)
  "Return the accent face for FACET's top-level tag group.

Sibling tags resolve to their common root and therefore share a face.  Tags
outside a hierarchy deliberately use chip2, the neutral structural accent."
  (let ((tag-id (and (eq (car facet) 'tag) (cdr facet))))
    (if (not tag-id)
        'supertag-view-chip2
      (let* ((root (supertag-view-tag-cards--top-level-tag-id tag-id))
             (faces (or supertag-view-tag-cards--render-chip-face-map
                        (supertag-view-tag-cards--chip-face-map))))
        (or (gethash root faces) 'supertag-view-chip2)))))

(defun supertag-view-tag-cards--group-ids ()
  "Return configured or inferred favorite group IDs that still exist."
  (let ((candidates
         (or supertag-view-tag-cards-favorite-groups
             (cl-remove-if-not
              (lambda (tag-id) (supertag-tag-descendants tag-id))
              (supertag-view-tag-cards--all-tag-ids)))))
    (cl-remove-if-not #'supertag-tag-get (delete-dups (copy-sequence candidates)))))

(defun supertag-view-tag-cards--tag-ids-for-group (group-id)
  "Return card Tag IDs for GROUP-ID, restricted to its descendants.

A selected group intentionally names the branch rather than adding another
copy of its root card; the root itself remains visible in the all-tags view."
  (if group-id
      (supertag-tag-descendants group-id)
    (supertag-view-tag-cards--all-tag-ids)))

(defun supertag-view-tag-cards--display-node-ids (state)
  "Return the page's node set for STATE's active intersection or group."
  (let ((filters (plist-get state :filter))
        (group (plist-get state :group)))
    (cond
     (filters (supertag-view-tag-cards--node-ids-for-filters filters))
     (group
      (delete-dups
       (cl-mapcan #'supertag-view-tag-cards--node-ids-for-tag
                  (supertag-view-tag-cards--tag-ids-for-group group))))
     (t (supertag-view-tag-cards--node-ids-for-filters nil)))))

(defun supertag-view-tag-cards--card-node-ids (facet filters)
  "Return nodes for FACET after applying already active FILTERS."
  (supertag-view-tag-cards--node-ids-for-filters
   (append filters (list facet))))

(defun supertag-view-tag-cards--button (label action &optional focus-id)
  "Return a traditional native text button named LABEL running ACTION."
  (append (list :type 'supertag-view-tag-cards-button
                :value label
                :action action)
          (when focus-id (list :layout (list :focus-id focus-id)))))

(defun supertag-view-tag-cards--link (label action &optional focus-id)
  "Return a bracket-free native link named LABEL running ACTION."
  (append (list :type 'supertag-view-tag-cards-link
                :tag label
                :value label
                :action action)
          (when focus-id (list :layout (list :focus-id focus-id)))))

(defun supertag-view-tag-cards--plain-item (text &optional face)
  "Return an atomic TEXT element optionally carrying FACE.

The custom static item preserves FACE in TextUI's text renderer instead of
letting stock widget measurement discard it."
  (list :type 'supertag-view-tag-cards-item :format "%v"
        :value (if face (propertize text 'face face) text)))

(defun supertag-view-tag-cards--fixed-item (text width &optional face)
  "Return TEXT right-padded to WIDTH display columns with optional FACE."
  (supertag-view-tag-cards--plain-item
   (supertag-view-tag-cards--pad-right text width) face))

(defun supertag-view-tag-cards--filled-item (label width face)
  "Return LABEL in a whole-width FACE fill of WIDTH display columns."
  (supertag-view-tag-cards--plain-item
   (supertag-view-tag-cards--filled-string label width face)))

(defun supertag-view-tag-cards--filled-title-item (label count width face)
  "Return a whole-width FACE fill with LABEL and right-aligned COUNT."
  (supertag-view-tag-cards--plain-item
   (supertag-view-tag-cards--filled-title-string label count width face)))

(defun supertag-view-tag-cards--set-state (key value)
  "Set current Tag Cards TextUI KEY to VALUE."
  (textui-set-state (current-buffer) key value))

(defun supertag-view-tag-cards--add-facet (facet &optional scope)
  "Add FACET and optional card SCOPE to the page-wide intersection."
  (supertag-view-tag-cards--set-state
   :filter
   (lambda (filters)
     (let ((next (copy-tree filters)))
       (dolist (candidate (delq nil (list scope facet)))
         (when (and (supertag-view-tag-cards--facet-p candidate)
                    (not (supertag-view-tag-cards--facet-member-p
                          candidate next)))
           (setq next (append next (list candidate)))))
       next))))

(defun supertag-view-tag-cards--remove-facet (facet)
  "Remove FACET from the current intersection."
  (supertag-view-tag-cards--set-state
   :filter
   (lambda (filters) (cl-remove facet filters :test #'equal))))

(defun supertag-view-tag-cards--reset ()
  "Clear group and facet narrowing in the current cards page."
  (textui-update
   (current-buffer)
   (lambda (state)
     (let ((next (copy-sequence state)))
       (setq next (plist-put next :filter nil))
       (plist-put next :group nil)))))

(defun supertag-view-tag-cards--select-group (group-id)
  "Restrict the current cards page to GROUP-ID's descendants."
  (textui-update
   (current-buffer)
   (lambda (state)
     (let ((next (copy-sequence state)))
       (setq next (plist-put next :filter nil))
       (plist-put next :group group-id)))))

(defun supertag-view-tag-cards--masthead-cell-widths (width)
  "Split WIDTH into three masthead cells separated by two two-cell gaps."
  (let* ((available (max 3 (- width 4)))
         (base (/ available 3))
         (remainder (% available 3)))
    (list (+ base (if (> remainder 0) 1 0))
          (+ base (if (> remainder 1) 1 0))
          base)))

(defun supertag-view-tag-cards--masthead-status (state)
  "Return STATE's right-side masthead status in editorial label grammar."
  (let ((filters (plist-get state :filter))
        (group (plist-get state :group)))
    (cond
     (filters
      (mapconcat #'supertag-view-tag-cards--editorial-facet-label
                 (supertag-view-tag-cards--display-filters filters) " ∩ "))
     (group (format "GROUP / %s"
                    (supertag-view-tag-cards--compact-tag-label group)))
     (t "COMPOSITION / LIVE"))))

(defun supertag-view-tag-cards--masthead (state tag-count tagged-node-count width)
  "Return the three-cell Tag Cards masthead at WIDTH.

STATE contributes the live narrowing status; TAG-COUNT and TAGGED-NODE-COUNT
remain whole-Store measures so the volume stays stable while drilling down."
  (pcase-let ((`(,left ,middle ,right)
               (supertag-view-tag-cards--masthead-cell-widths width)))
    (list :type :flex :direction :row :gap 2
          :children
          (list
           (supertag-view-tag-cards--filled-item
            "SUPERTAG / TAGS" left 'supertag-view-chip1)
           (supertag-view-tag-cards--fixed-item
            (format "VOL. %d / %d NOTES" tag-count tagged-node-count)
            middle 'supertag-view-mute)
           (supertag-view-tag-cards--filled-item
            (supertag-view-tag-cards--masthead-status state)
            right 'supertag-view-chip3)))))

(defun supertag-view-tag-cards--manifesto-line (index fallback)
  "Return manifesto line INDEX, or FALLBACK when the custom value is absent."
  (let ((value (nth index supertag-view-tag-cards-manifesto)))
    (if (and (stringp value) (not (string-empty-p value))) value fallback)))

(defun supertag-view-tag-cards--manifesto (width)
  "Return the full-width three-line Tag Cards manifesto at WIDTH."
  (list :type :flex :direction :column :gap 0
        :children
        (list
         (supertag-view-tag-cards--fixed-item
          (upcase (supertag-view-tag-cards--manifesto-line 0 "MAKE ROOM"))
          width 'supertag-view-panel)
         (supertag-view-tag-cards--fixed-item
          (upcase (supertag-view-tag-cards--manifesto-line 1 "FOR THE UNEXPECTED."))
          width 'supertag-view-panel)
         (supertag-view-tag-cards--fixed-item
          (supertag-view-tag-cards--manifesto-line
           2 "Tags are fuel. The connections are computed for you: click any + row to narrow.")
          width 'supertag-view-panel))))

(defun supertag-view-tag-cards--action-row (width)
  "Return the traditional button row for global and group navigation."
  (let ((groups (supertag-view-tag-cards--group-ids))
        (label-budget
         (max 1 (- width supertag-view-tag-cards--text-button-chrome-width))))
    (list :type :flex :direction :row :gap 2
          :children
          (append
           (list
            (supertag-view-tag-cards--button
             "ALL TAGS" (lambda (&rest _) (supertag-view-tag-cards--reset))
             'all-tags)
            (supertag-view-tag-cards--button
             "RESET" (lambda (&rest _) (supertag-view-tag-cards--reset))
             'reset))
           (mapcar
            (lambda (group-id)
              (supertag-view-tag-cards--button
               (supertag-view-tag-cards--truncate
                (supertag-view-tag-cards--compact-tag-label group-id)
                label-budget)
               (lambda (&rest _)
                 (supertag-view-tag-cards--select-group group-id))
               (list 'group group-id)))
            groups)))))

(defun supertag-view-tag-cards--facet-marker (facet)
  "Return FACET's distinct, one-cell editorial marker and following space."
  (pcase (car facet)
    ('tag "+ ")
    ('todo "◆ ")
    ('link "↗ ")
    (_ "+ ")))

(defun supertag-view-tag-cards--facet-row-label (facet)
  "Return the compact display label for FACET inside a card row."
  (pcase (car facet)
    ('tag (supertag-view-tag-cards--editorial-tag-label (cdr facet)))
    ('todo (upcase (cdr facet)))
    ('link (supertag-view-tag-cards--node-title (cdr facet)))
    (_ (supertag-view-tag-cards--facet-label facet))))

(defun supertag-view-tag-cards--card-model
    (facet node-ids state width &optional track-width)
  "Return one data model for FACET's locally composed card at WIDTH.

TRACK-WIDTH is the exact responsive column track.  The attached block uses it
as a hard local pixel budget rather than allowing an individual widget's
natural width to change the neighbour card's origin."
  (let* ((kind (car facet))
         (tag-id (and (eq kind 'tag) (cdr facet)))
         (ancestors (and tag-id (supertag-tag-ancestors tag-id)))
         (excluded (and tag-id (cons tag-id ancestors)))
         (scope facet)
         (budget (or track-width
                     (supertag-view-tag-cards--card-content-budget width)))
         (records
          (cl-remove-if
           (lambda (record)
             (or (equal (plist-get record :facet) scope)
                 (supertag-view-tag-cards--facet-member-p
                  (plist-get record :facet) (plist-get state :filter))))
           (supertag-view-tag-cards--facets-for-node-ids node-ids excluded)))
         (overline (if tag-id
                       (or (supertag-view-tag-cards--parent-chain tag-id) "")
                     ""))
         (count (length node-ids))
         (recent-node-ids
          (supertag-view-tag-cards--recent-node-ids
           node-ids (or (plist-get state :limit-nodes)
                        supertag-view-tag-cards--node-limit))))
    (list :facet facet
          :scope scope
          :budget budget
          :overline overline
          :title (supertag-view-tag-cards--facet-title facet)
          :count count
          :face (supertag-view-tag-cards--card-chip-face facet)
          :records records
          :recent-node-ids recent-node-ids)))

(defun supertag-view-tag-cards--filtered-card-records (node-ids filters)
  "Return useful drill-down facet records for NODE-IDS and FILTERS.

Single-occurrence facets are removed to keep an intersection page legible.
When every available continuation has count one, retain those records instead
of producing an empty grid.  This data-only step is intentionally separate
from element construction so it remains easy to exercise in ERT."
  (let* ((candidates
          (cl-remove-if
           (lambda (record)
             (supertag-view-tag-cards--facet-member-p
              (plist-get record :facet) filters))
           (supertag-view-tag-cards--all-facets-for-node-ids node-ids)))
         (non-singletons
          (cl-remove-if (lambda (record) (= (plist-get record :count) 1))
                        candidates)))
    (or non-singletons candidates)))

(defun supertag-view-tag-cards--cards (state width)
  "Return `(:cards ... :empty-tags ...)' for STATE at WIDTH.

Empty tag families are intentionally kept out of the grid.  Their names are
returned separately so the field can acknowledge them in one quiet line."
  (let ((filters (plist-get state :filter))
        (track-widths (supertag-view-tag-cards--card-track-widths width)))
    (if filters
        (let* ((base-node-ids (supertag-view-tag-cards--display-node-ids state))
               (records (supertag-view-tag-cards--filtered-card-records
                         base-node-ids filters)))
          (let ((index 0)
                cards)
            (dolist (record records)
              (let ((facet (plist-get record :facet)))
                (push (supertag-view-tag-cards--card-model
                       facet
                       (supertag-view-tag-cards--card-node-ids facet filters)
                       state width
                       (nth (mod index (length track-widths)) track-widths))
                      cards)
                (setq index (1+ index))))
            (list :cards (nreverse cards) :empty-tags nil)))
      (let (cards empty-tags
                  (index 0))
        (dolist (tag-id (supertag-view-tag-cards--tag-ids-for-group
                         (plist-get state :group)))
          (let ((node-ids (supertag-view-tag-cards--node-ids-for-tag tag-id)))
            (if node-ids
                (progn
                  (push (supertag-view-tag-cards--card-model
                         (cons 'tag tag-id) node-ids state width
                         (nth (mod index (length track-widths)) track-widths))
                        cards)
                  (setq index (1+ index)))
              (push tag-id empty-tags))))
        (list :cards (nreverse cards) :empty-tags (nreverse empty-tags))))))

(defun supertag-view-tag-cards--card-line-specs (card)
  "Return CARD's unpadded visual line specifications in display order."
  (let ((lines
         (list (list :kind :mute :text (plist-get card :overline)
                     :face 'supertag-view-mute)
               (list :kind :title :label (plist-get card :title)
                     :count (plist-get card :count)
                     :face (plist-get card :face)))))
    (when-let* ((records (plist-get card :records)))
      (setq lines
            (append lines (list (list :kind :blank))
                    (mapcar (lambda (record)
                              (list :kind :facet :record record
                                    :scope (plist-get card :scope)))
                            records))))
    (when-let* ((node-ids (plist-get card :recent-node-ids)))
      (setq lines
            (append lines (list (list :kind :blank))
                    (mapcar (lambda (node-id)
                              (list :kind :node :node-id node-id
                                    :scope (plist-get card :scope)))
                            node-ids))))
    lines))

(defun supertag-view-tag-cards--card-line-at (line specs)
  "Return SPECS' LINE, or the blank card-line specification."
  (or (nth line specs) (list :kind :blank)))

(defun supertag-view-tag-cards--card-row-specs (cards)
  "Return equal-height line-spec rows for CARDS.

Shorter cards receive blank lines only within this local block, which keeps
all cards' following lines and right edges aligned without a TextUI grid."
  (let* ((per-card (mapcar #'supertag-view-tag-cards--card-line-specs cards))
         (height (apply #'max 1 (mapcar #'length per-card)))
         rows
         (line 0))
    (while (< line height)
      (push (mapcar (apply-partially #'supertag-view-tag-cards--card-line-at
                                     line)
                    per-card)
            rows)
      (setq line (1+ line)))
    (nreverse rows)))

(defun supertag-view-tag-cards--card-title-into (text spec edge)
  "Append SPEC's filled title to TEXT, ending exactly at absolute EDGE."
  (let* ((face (plist-get spec :face))
         (count (format "%s" (plist-get spec :count)))
         (target (supertag-view-tag-cards--target-width edge))
         ;; The leading title-fill space and the literal title/count separator
         ;; are part of the candidate.  Reserving that separator here means a
         ;; count cannot be glued to a truncated title.
         (prefix (concat text " "))
         (suffix (concat " " count " "))
         (title (supertag-view-tag-cards--fit-label-to-target
                 (plist-get spec :label) prefix suffix target))
         (left (propertize (concat " " title " ") 'face face))
         (right (propertize (concat count " ") 'face face)))
    (setq text (concat text left))
    (setq text (supertag-view-tag-cards--append-to-width
                text (- target (supertag-view-tag-cards--render-width right))
                face))
    (setq text (concat text right))
    (supertag-view-tag-cards--append-to-width text target face)))

(defun supertag-view-tag-cards--facet-into (text spec edge)
  "Append SPEC's clickable facet row to TEXT, ending at absolute EDGE.

Return `(TEXT ACTION)' so the attached-block callback can turn the exact
already composed range into a text button after TextUI materializes it."
  (let* ((record (plist-get spec :record))
         (facet (plist-get record :facet))
         (count (format "%d" (plist-get record :count)))
         (prefix (supertag-view-tag-cards--facet-marker facet))
         (target (supertag-view-tag-cards--target-width edge))
         ;; Fit the complete row and reserve one literal label/count space.
         ;; Measuring LABEL alone was what allowed card one to overshoot a
         ;; cell and, in the tightest case, join the count to the ellipsis.
         (line-prefix (concat text prefix))
         (label (supertag-view-tag-cards--fit-label-to-target
                 (supertag-view-tag-cards--facet-row-label facet)
                 line-prefix (concat " " count) target))
         (right count)
         (action (lambda (&rest _)
                   (supertag-view-tag-cards--add-facet
                    facet (plist-get spec :scope)))))
    (setq text (concat line-prefix label " "))
    (setq text (supertag-view-tag-cards--append-to-width
                text (- target (supertag-view-tag-cards--render-width right))))
    (setq text (concat text right))
    (list (supertag-view-tag-cards--append-to-width text target) action)))

(defun supertag-view-tag-cards--node-into (text spec edge)
  "Append SPEC's clickable node row to TEXT, ending at absolute EDGE."
  (let* ((node-id (plist-get spec :node-id))
         (prefix "→ ")
         (target (supertag-view-tag-cards--target-width edge))
         (line-prefix (concat text prefix))
         (title (supertag-view-tag-cards--fit-label-to-target
                 (supertag-view-tag-cards--node-title node-id)
                 line-prefix "" target))
         (action (lambda (&rest _) (supertag-goto-node node-id))))
    (list (supertag-view-tag-cards--append-to-cell
           (concat line-prefix title) edge)
          action)))

(defun supertag-view-tag-cards--compose-card-row-line
    (specs cards row-index)
  "Return one locally composed card line from SPECS and CARDS.

Every boundary is padded from the complete prefix with Variant C's relative
pixel spacer.  Thus a wide glyph in any card cannot move a sibling card or a
later count column." 
  (let ((text "")
        (origin 0)
        (card-index 0))
    (cl-mapc
     (lambda (spec card)
       (let* ((track (plist-get card :budget))
              (edge (+ origin track))
              (start (length text))
              action)
         (setq text (supertag-view-tag-cards--append-to-cell text origin))
         (setq start (length text)
               spec (plist-put (copy-sequence spec) :track track))
         (pcase (plist-get spec :kind)
           (:title
            (setq text (supertag-view-tag-cards--card-title-into text spec edge)))
           (:facet
            (pcase-let ((`(,next ,next-action)
                         (supertag-view-tag-cards--facet-into text spec edge)))
              (setq text next action next-action)))
           (:node
            (pcase-let ((`(,next ,next-action)
                         (supertag-view-tag-cards--node-into text spec edge)))
              (setq text next action next-action)))
           (:mute
            (let ((face (plist-get spec :face)))
              (setq text
                    (concat text
                            (propertize
                             (supertag-view-tag-cards--fit-label-to-target
                              (plist-get spec :text) text ""
                              (supertag-view-tag-cards--target-width edge))
                             'face face)))
              (setq text (supertag-view-tag-cards--append-to-cell text edge face))))
           (_
            (setq text (supertag-view-tag-cards--append-to-cell text edge))))
         (let ((end (length text)))
           (put-text-property start end 'supertag-view-tag-cards--card
                              (cons row-index card-index) text)
           (when action
             (put-text-property start end
                                'supertag-view-tag-cards--button-action
                                action text))
         (setq origin (+ edge supertag-view-tag-cards--grid-gap)
               card-index (1+ card-index)))))
     specs cards)
    text))

(defun supertag-view-tag-cards--compose-card-row (cards width &optional row-index)
  "Return CARDS as one attached multiline block at WIDTH."
  ;; Card models already contain the exact responsive tracks made at WIDTH;
  ;; accept the public block-layout argument without recomputing the model.
  (ignore width)
  (let (lines)
    (dolist (specs (supertag-view-tag-cards--card-row-specs cards))
      (push (supertag-view-tag-cards--compose-card-row-line
             specs cards (or row-index 0))
            lines))
    (concat (mapconcat #'identity (nreverse lines) "\n") "\n")))

(defun supertag-view-tag-cards--card-rows (cards width)
  "Split CARDS into the responsive visual rows selected at WIDTH."
  (let ((columns (supertag-view-tag-cards--grid-columns width))
        rows)
    (while cards
      (push (cl-subseq cards 0 (min columns (length cards))) rows)
      (setq cards (nthcdr columns cards)))
    (nreverse rows)))

(defun supertag-view-tag-cards--card-row-block (cards row-index)
  "Return one top-level attached block for CARDS at ROW-INDEX."
  (list :type 'supertag-view-tag-cards-card-row-block
        :value " "
        :cards cards
        :row-index row-index))

(defun supertag-view-tag-cards--separator-block (&optional blank-line)
  "Return a top-level attached block separating frame sections.

BLANK-LINE adds an empty visual line after the ordinary line separator."
  (list :type 'supertag-view-tag-cards-card-row-block
        :value (if blank-line "\n\n" "\n")))

(defun supertag-view-tag-cards--empty-tags-line (tag-ids width)
  "Return the muted one-line acknowledgement for zero-count TAG-IDS."
  (when tag-ids
    (supertag-view-tag-cards--fixed-item
     (format "EMPTY / %02d  %s"
             (length tag-ids)
             (mapconcat #'supertag-view-tag-cards--tag-label tag-ids ", "))
     width 'supertag-view-mute)))

(defun supertag-view-tag-cards--field-elements (cards empty-tags width)
  "Return top-level field elements for CARDS and optional EMPTY-TAGS.

Attached blocks are intentionally top-level, as required by TextUI's public
block-widget API.  A small block separator replaces the outer column flex's
former gaps without nesting a block in a layout container."
  (if (null cards)
      (append (list (supertag-view-tag-cards--plain-item
                     "No co-occurring facets." 'supertag-view-mute)
                    (supertag-view-tag-cards--separator-block t))
              (when-let* ((empty (supertag-view-tag-cards--empty-tags-line
                                  empty-tags width)))
                (list empty (supertag-view-tag-cards--separator-block t))))
    (append
     (cl-loop for row in (supertag-view-tag-cards--card-rows cards width)
              for row-index from 0
              append (list (supertag-view-tag-cards--card-row-block row row-index)
                           (supertag-view-tag-cards--separator-block)))
     (when-let* ((empty (supertag-view-tag-cards--empty-tags-line
                         empty-tags width)))
       (list empty (supertag-view-tag-cards--separator-block t))))))

(defun supertag-view-tag-cards--colophon ()
  "Return the shared three-line Tag Cards colophon."
  (list :type :flex :direction :column :gap 0
        :children
        (list
         ;; This leading blank plus the page band's gap makes two blanks
         ;; before the footer without adding a visible pseudo-band above it.
         (supertag-view-tag-cards--plain-item " ")
         (supertag-view-tag-cards--plain-item "+ . + . + ." 'supertag-view-rule)
         (supertag-view-tag-cards--plain-item
          "01 / TAG FIELD   live store, recomputed on every refresh"
          'supertag-view-mute)
         (supertag-view-tag-cards--plain-item "SUPERTAG / TAGS"
                                               'supertag-view-mute))))

(defun supertag-view-tag-cards--frame (width)
  "Return the complete TextUI page for the current buffer state."
  (let* ((state textui-state)
         (all-tag-ids (supertag-view-tag-cards--all-tag-ids))
         (tagged-node-ids (supertag-view-tag-cards--node-ids-for-filters nil))
         (supertag-view-tag-cards--render-chip-face-map
          (supertag-view-tag-cards--chip-face-map))
         (card-data (supertag-view-tag-cards--cards state width)))
    (append
     (list
      (supertag-view-tag-cards--masthead
       state (length all-tag-ids) (length tagged-node-ids) width)
      (supertag-view-tag-cards--separator-block t)
      (supertag-view-tag-cards--manifesto width)
      (supertag-view-tag-cards--separator-block t)
      (supertag-view-tag-cards--action-row width)
      (supertag-view-tag-cards--separator-block t))
     (supertag-view-tag-cards--field-elements
      (plist-get card-data :cards) (plist-get card-data :empty-tags) width)
     (list (supertag-view-tag-cards--colophon)))))

(defun supertag-view-tag-cards--install-store-refresh (buffer)
  "Subscribe BUFFER to tag and node changes, once for its lifetime."
  (with-current-buffer buffer
    (unless supertag-view-tag-cards--unsubscribe
      (let ((unsubscribe
             (supertag-view-api-subscribe
              :store-changed
              (lambda (path _old-value _new-value)
                (when (and (buffer-live-p buffer)
                           (listp path)
                           (memq (car path) '(:tags :nodes)))
                  (textui-request-refresh buffer))))))
        (setq-local supertag-view-tag-cards--unsubscribe unsubscribe)
        (textui-register-cleanup
         buffer
         (lambda ()
           (when supertag-view-tag-cards--unsubscribe
             (funcall supertag-view-tag-cards--unsubscribe)
             (setq supertag-view-tag-cards--unsubscribe nil))))))))

(defun supertag-view-tag-cards--enforce-no-wrap ()
  "Keep this view's rows on one visual line in the current buffer.

TextUI opens and refreshes a displayed buffer after the derived mode has run;
global visual-line configuration can therefore have changed these locals in
between.  The entry command calls this helper again after `textui-open'."
  (when (fboundp 'visual-line-mode)
    (visual-line-mode -1))
  (setq-local truncate-lines t
              word-wrap nil))

(defun supertag-view-tag-cards--apply-palette ()
  "Apply `supertag-view-tag-cards-palette' in the current buffer.

The framework owns the role faces, so this is a no-op when this file is
loaded standalone without `supertag-view-framework'."
  (when (fboundp 'supertag-view-apply-palette-locally)
    (supertag-view-apply-palette-locally supertag-view-tag-cards-palette)))

(defun supertag-view-tag-cards-refresh ()
  "Synchronously redraw the Tag Cards page from the current Store."
  (interactive)
  (textui-refresh (current-buffer)))

(defun supertag-view-tag-cards-next-button ()
  "Move to the next native or locally composed Tag Cards button."
  (interactive)
  (forward-button 1 t t))

(defun supertag-view-tag-cards-previous-button ()
  "Move to the previous native or locally composed Tag Cards button."
  (interactive)
  (backward-button 1 t t))

(defun supertag-view-tag-cards--card-edge-x (window line-start edge graphic)
  "Return WINDOW's x coordinate from LINE-START through EDGE.

GRAPHIC selects `window-text-pixel-size'; the column fallback makes a
terminal invocation useful without claiming it verifies GUI pixel alignment."
  (if graphic
      (car (window-text-pixel-size window line-start edge 100000))
    (string-width (buffer-substring line-start edge))))

(defun supertag-view-tag-cards--live-string-width (window text graphic)
  "Return TEXT's width using WINDOW's live buffer or the column fallback."
  (if graphic
      (with-selected-window window
        (string-pixel-width text (window-buffer window)))
    (string-width text)))

(defun supertag-view-tag-cards--display-space-width (display)
  "Return a `space :width' value from DISPLAY, or nil for another spec."
  (when (and (consp display) (eq (car display) 'space))
    (let ((width (plist-get (cdr display) :width)))
      (cond
       ((numberp width) width)
       ((and (consp width) (numberp (car width))) (car width))))))

(defun supertag-view-tag-cards--residual-spacers
    (window line-start from to graphic)
  "Return live measurements for residual display spaces between FROM and TO.

The `space :width' property is the Variant-C remainder that closes a local
pixel boundary.  Measure its actual contribution from the logical line origin
rather than assuming the property survived or that the font maps it to the
declared width."
  (let ((position from)
        residuals)
    (while (< position to)
      (let* ((next (next-single-property-change position 'display nil to))
             (display (get-text-property position 'display))
             (declared (supertag-view-tag-cards--display-space-width display)))
        (when declared
          (push (list :display display
                      :declared declared
                      :pixels
                      (- (supertag-view-tag-cards--card-edge-x
                          window line-start next graphic)
                         (supertag-view-tag-cards--card-edge-x
                          window line-start position graphic)))
                residuals))
        (setq position next)))
    (nreverse residuals)))

(defun supertag-view-tag-cards--ellipsis-info (window from to graphic)
  "Return the rendered ellipsis character and font metadata between FROM and TO."
  (when-let* ((position
               (save-excursion
                 (goto-char from)
                 (when (search-forward "…" to t) (1- (point)))))
              (character (char-after position)))
    (list :code character
          :font-family
          (and graphic
               (ignore-errors
                 (when-let* ((font (font-at position window)))
                   (font-get font :family)))))))

(defun supertag-view-tag-cards--modal-edge (records)
  "Return the most frequent `:x' value in RECORDS, preferring the lower tie."
  (let ((counts (make-hash-table :test 'eql))
        winner
        highest)
    (dolist (record records)
      (let ((x (plist-get record :x)))
        (puthash x (1+ (gethash x counts 0)) counts)))
    (maphash (lambda (x count)
               (when (or (null highest)
                         (> count highest)
                         (and (= count highest) (< x winner)))
                 (setq winner x highest count)))
             counts)
    winner))

(defun supertag-view-tag-cards--format-residual-spacers (residuals unit)
  "Return RESIDUALS as a compact diagnostic string in UNIT."
  (if residuals
      (mapconcat
       (lambda (residual)
         (format "display=%S declared=%S live=%d%s"
                 (plist-get residual :display)
                 (plist-get residual :declared)
                 (plist-get residual :pixels) unit))
       residuals "; ")
    "none"))

;;;###autoload
(defun supertag-view-tag-cards-measure ()
  "Report every locally composed card edge in the visible Tag Cards buffer.

The report is a live GUI measurement, not a text-render approximation.  Each
card segment carries its row/card identity from the attached block.  Its edge
is measured from the logical line origin with `window-text-pixel-size', then
all lines belonging to that card PASS only when their spread is at most 1px.
For a failing line, include its text, live string width, ellipsis font, and
residual display-space measurement so the renderer and measurement can be
compared directly."
  (interactive)
  (let* ((source (current-buffer))
         (window (or (get-buffer-window source 0)
                     (and (eq (window-buffer (selected-window)) source)
                          (selected-window))))
         (graphic (and (window-live-p window)
                       (display-graphic-p (window-frame window))))
         (unit (if graphic "px" "col"))
         (edges (make-hash-table :test 'equal))
         records)
    (unless (window-live-p window)
      (user-error "Display the Tag Cards buffer before measuring it"))
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (let ((line-start (line-beginning-position))
              (line-end (line-end-position))
              (line-number (line-number-at-pos))
              (position (line-beginning-position)))
          (while (< position line-end)
            (let* ((card (get-text-property
                          position 'supertag-view-tag-cards--card))
                   (next (next-single-property-change
                          position 'supertag-view-tag-cards--card nil line-end)))
              (when card
                (let* ((segment (buffer-substring position next))
                       (x (supertag-view-tag-cards--card-edge-x
                           window line-start next graphic)))
                  (push (list :line line-number :x x) (gethash card edges))
                  (push (list :row (car card) :card (cdr card)
                              :line line-number :x x
                              :text segment
                              :string-width
                              (supertag-view-tag-cards--live-string-width
                               window segment graphic)
                              :ellipsis
                              (supertag-view-tag-cards--ellipsis-info
                               window position next graphic)
                              :residuals
                              (supertag-view-tag-cards--residual-spacers
                               window line-start position next graphic))
                        records)))
              (setq position next)))
          (forward-line 1))))
    (unless records
      (user-error "No locally composed Tag Cards rows are present"))
    (let ((report-buffer (get-buffer-create "*Supertag Tag Cards Measurement*"))
          (keys nil))
      (maphash (lambda (key _value) (push key keys)) edges)
      (setq records
            (sort records
                  (lambda (left right)
                    (if (= (plist-get left :row) (plist-get right :row))
                        (if (= (plist-get left :line) (plist-get right :line))
                            (< (plist-get left :card) (plist-get right :card))
                          (< (plist-get left :line) (plist-get right :line)))
                      (< (plist-get left :row) (plist-get right :row))))))
      (setq keys
            (sort keys (lambda (left right)
                         (if (= (car left) (car right))
                             (< (cdr left) (cdr right))
                           (< (car left) (car right))))))
      (with-current-buffer report-buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Tag Cards pixel alignment | graphic=%S | frame-char-width=%d\n"
                          graphic (if graphic (frame-char-width (window-frame window)) 1))
                  "right-x is measured from each logical line start to the card edge.\n"
                  (if graphic
                      (format "string-pixel-width \"…\"=%dpx; \" \"=%dpx\n"
                              (supertag-view-tag-cards--live-string-width
                               window "…" graphic)
                              (supertag-view-tag-cards--live-string-width
                               window " " graphic))
                    "string-pixel-width unavailable; terminal output is column-only.\n"))
          (dolist (record records)
            (insert (format "  row=%02d card=%d line=%02d right-x=%d%s\n"
                            (1+ (plist-get record :row))
                            (1+ (plist-get record :card))
                            (plist-get record :line) (plist-get record :x) unit)))
          (insert "\n")
          (dolist (key keys)
            (let* ((values (mapcar (lambda (record) (plist-get record :x))
                                   (gethash key edges)))
                   (deviation (- (apply #'max values) (apply #'min values)))
                   (pass (<= deviation (if graphic 1 0)))
                   (card-records
                    (cl-remove-if-not
                     (lambda (record)
                       (and (= (plist-get record :row) (car key))
                            (= (plist-get record :card) (cdr key))))
                     records))
                   (baseline (supertag-view-tag-cards--modal-edge card-records)))
              (insert (format "row=%02d card=%d %s%s max-deviation=%d%s\n"
                              (1+ (car key)) (1+ (cdr key))
                              (if pass "PASS" "FAIL")
                              (if graphic "" " COLUMN-ONLY")
                              deviation unit))
              (unless pass
                (dolist (record card-records)
                  (unless (= (plist-get record :x) baseline)
                    (let ((ellipsis (plist-get record :ellipsis)))
                      (insert
                       (format
                        "  FAIL line=%02d raw=%S string-pixel-width=%d%s right-x=%d%s ellipsis=%s font-family=%S residual=%s\n"
                        (plist-get record :line)
                        (substring-no-properties (plist-get record :text))
                        (plist-get record :string-width) unit
                        (plist-get record :x) unit
                        (if ellipsis
                            (format "U+%04X" (plist-get ellipsis :code))
                          "none")
                        (and ellipsis (plist-get ellipsis :font-family))
                        (supertag-view-tag-cards--format-residual-spacers
                         (plist-get record :residuals) unit)))))))))
        (special-mode))
      (display-buffer report-buffer)
      (message "Tag Cards alignment: %d card segments measured; see %s"
               (length records) (buffer-name report-buffer))
      report-buffer))))

(defvar supertag-view-tag-cards-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map widget-keymap)
    (define-key map (kbd "g") #'supertag-view-tag-cards-refresh)
    (define-key map (kbd "r") #'supertag-view-tag-cards--reset)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "TAB") #'supertag-view-tag-cards-next-button)
    (define-key map (kbd "<backtab>") #'supertag-view-tag-cards-previous-button)
    map)
  "Keymap for `supertag-view-tag-cards-mode'.")

(define-derived-mode supertag-view-tag-cards-mode textui-mode "Supertag-Tag-Cards"
  "TextUI Tag Manager magazine page.

The mode inherits `special-mode' through `textui-mode'.  g refreshes, r resets
filters, q quits the window, and TAB/S-TAB move among native text buttons."
  :group 'supertag-view-tag-cards
  :keymap supertag-view-tag-cards-mode-map
  (setq-local buffer-read-only t
              cursor-type 'box
              line-spacing 0.1)
  (supertag-view-tag-cards--enforce-no-wrap)
  (supertag-view-tag-cards--apply-palette))

(when (fboundp 'supertag-view-register-modal-state)
  (supertag-view-register-modal-state 'supertag-view-tag-cards-mode))
(with-eval-after-load 'supertag-view-framework
  (supertag-view-register-modal-state 'supertag-view-tag-cards-mode))

;;;###autoload
(defun supertag-view-tag-cards ()
  "Open responsive read-only cards for the current Semantic Tag store."
  (interactive)
  ;; Keep the file independently loadable alongside TextUI, while making the
  ;; command robust when it is invoked outside the normal `supertag' loader.
  (require 'supertag-view-framework)
  (let* ((existing (get-buffer supertag-view-tag-cards--buffer-name))
         (buffer (or existing
                     (get-buffer-create supertag-view-tag-cards--buffer-name)))
         (new-buffer (with-current-buffer buffer
                       (not (derived-mode-p 'textui-mode)))))
    (when (and existing new-buffer)
      (user-error "A non-TextUI buffer already uses %s"
                  supertag-view-tag-cards--buffer-name))
    (with-current-buffer buffer
      (unless (derived-mode-p 'supertag-view-tag-cards-mode)
        (supertag-view-tag-cards-mode)))
    (setq buffer
          (if new-buffer
              (textui-open supertag-view-tag-cards--buffer-name
                           #'supertag-view-tag-cards--frame
                           (list :filter nil :group nil
                                 :limit-nodes supertag-view-tag-cards--node-limit))
            (textui-open supertag-view-tag-cards--buffer-name
                         #'supertag-view-tag-cards--frame)))
    ;; `textui-open' displays and refreshes after the mode body.  Reassert
    ;; these locals in case TextUI or a global visual-line setup touched them.
    (with-current-buffer buffer
      (supertag-view-tag-cards--enforce-no-wrap)
      (supertag-view-tag-cards--apply-palette))
    (supertag-view-tag-cards--install-store-refresh buffer)
    buffer))

(provide 'supertag-view-tag-cards)
;;; supertag-view-tag-cards.el ends here
