;;; embark-test.el --- Optional contextual action contracts -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-embark)

(defconst supertag-embark-test--root
  (expand-file-name ".." (file-name-directory load-file-name)))

(ert-deftest supertag-embark-recognizes-heading-tag-link-and-nothing ()
  (with-temp-buffer
    (org-mode)
    (insert "* Heading #old\nBody [[id:target][Target]] [[https://example.org][Web]]\nPlain text\n")
    (goto-char (point-min))
    (should (equal (supertag-embark-target-finder)
                   (cl-list* 'supertag-node "Heading #old" 1 (line-end-position))))
    (search-forward "#old") (backward-char 2)
    (let ((begin (- (point) 2)))
      (should (equal (supertag-embark-target-finder)
                     (cl-list* 'supertag-tag "#old" begin (+ begin 4))))
      (should (equal (supertag-view-helper-get-tag-at-point) "old")))
    (search-forward "Target")
    (let ((link (org-element-context)))
      (should (equal (supertag-embark-target-finder)
                     (cl-list* 'supertag-link "id:target"
                            (org-element-property :begin link)
                            (org-element-property :end link)))))
    (search-forward "Web")
    (should (eq 'supertag-node (car (supertag-embark-target-finder))))
    (search-forward "Plain")
    (should (equal (supertag-embark-target-finder)
                   (cl-list* 'supertag-node "Heading #old" 1
                             (save-excursion (goto-char 1) (line-end-position)))))))

(ert-deftest supertag-embark-recognizes-concept-reference-and-region ()
  (supertag-document-test-with-vault
    (with-temp-buffer
      (org-mode)
      (insert "concept reference region")
      (put-text-property 1 8 'supertag-concept-node-id "document-node")
      (goto-char 3)
      (should (equal (supertag-embark-target-finder)
                     '(supertag-concept "Property Node" 1 . 8)))
      (dolist (property '(supertag-node-id supertag-entity-id
                         supertag-reference-node-id supertag-source-id))
        (set-text-properties 9 18 (list property "missing-node"))
        (goto-char 12)
        (should (equal (supertag-embark-target-finder)
                       '(supertag-node-reference "missing-node" 9 . 18))))
      (goto-char 19) (set-mark (point-max))
      (let ((transient-mark-mode t) (mark-active t))
        (should (equal (supertag-embark-target-finder)
                       (cl-list* 'supertag-region "region" 19 (point-max))))))))

(ert-deftest supertag-embark-idless-heading-discovery-and-view-are-zero-write ()
  (supertag-document-test-with-vault
    (let ((before (supertag-document-test-disk plain))
          (supertag-view-node--enabled nil))
      (switch-to-buffer (find-file-noselect plain))
      (goto-char (point-min))
      (should (eq 'supertag-node (car (supertag-embark-target-finder))))
      (should-error (supertag-embark-node-view "ignored") :type 'user-error)
      (should-not (org-entry-get nil "ID"))
      (should-not (buffer-modified-p))
      (should (equal before (buffer-string)))
      (should (equal before (supertag-document-test-disk plain))))))

(ert-deftest supertag-embark-link-delete-saves-and-projects-only-this-element ()
  (supertag-document-test-with-vault
    (with-temp-file file
      (insert "* Source\n:PROPERTIES:\n:ID: source\n:END:\nBefore [[id:first][First]] after [[id:second][Second]].\n* First\n:PROPERTIES:\n:ID: first\n:END:\n* Second\n:PROPERTIES:\n:ID: second\n:END:\n"))
    (supertag-reindex-org)
    (switch-to-buffer (find-file-noselect file))
    (goto-char (point-min)) (search-forward "First]]") (backward-char 3)
    (should (supertag-query-ordinary-references-from "source"))
    (supertag-embark-link-delete "not the target")
    (should (string-match-p (regexp-quote "Before after [[id:second][Second]].")
                            (supertag-document-test-disk file)))
    (should-not (buffer-modified-p))
    (should-not (supertag-relation-find-between "source" "first" :reference))
    (should (supertag-relation-find-between "source" "second" :reference))))

(ert-deftest supertag-embark-tag-change-affects-only-current-node ()
  (supertag-document-test-with-vault
    (supertag-tag-create '(:name "old"))
    (let ((other "* Other #old\n:PROPERTIES:\n:ID: other\n:END:\nKeep #old\n"))
      (with-temp-file file
        (insert "* Source #old\n:PROPERTIES:\n:ID: source\n:END:\nBody #old\n" other))
      (supertag-reindex-org)
      (switch-to-buffer (find-file-noselect file))
      (goto-char (point-min)) (search-forward "#old") (backward-char 1)
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "new")))
        (supertag-embark-tag-change "ignored"))
      (let ((text (supertag-document-test-disk file)))
        (should (string-match-p (regexp-quote "* Source #new") text))
        (should (string-match-p (regexp-quote "Body #new") text))
        (should (string-suffix-p other text)))
      (should-not (buffer-modified-p))
      (should (equal (plist-get (supertag-node-get "source") :tags)
                     (list (supertag-tag-resolve-occurrence "new"))))
      (should (equal (plist-get (supertag-node-get "other") :tags)
                     (list (supertag-tag-resolve-occurrence "old")))))))

(ert-deftest supertag-embark-tag-change-read-only-is-zero-write ()
  (supertag-document-test-with-vault
    (let ((old-id (plist-get (supertag-tag-create '(:name "old")) :id)))
      (with-temp-file file
        (insert "* Source #old\n:PROPERTIES:\n:ID: source\n:END:\nBody #old\n"))
      (supertag-reindex-org)
      (switch-to-buffer (find-file-noselect file))
      (goto-char (point-min)) (search-forward "#old") (backward-char 1)
      (let ((before (buffer-string))
            (disk (supertag-document-test-disk file))
            (tags (copy-sequence (plist-get (supertag-node-get "source") :tags)))
            (buffer-read-only t)
            caught)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) "probe-new")))
          (condition-case cause
              (supertag-embark-tag-change)
            (error (setq caught cause))))
        (should caught)
        (should (equal before (buffer-string)))
        (should (equal disk (supertag-document-test-disk file)))
        (should-not (buffer-modified-p))
        (should-not (supertag-tag-get "probe-new"))
        (should-not (supertag-tag-resolve-occurrence "probe-new"))
        (should (equal (list old-id) tags))
        (should (equal tags (plist-get (supertag-node-get "source") :tags)))
        (should (eq (car caught) 'user-error))))))

(ert-deftest supertag-embark-adapters-reject-a-missing-object ()
  (with-temp-buffer
    (org-mode) (insert "plain text")
    (dolist (adapter '(supertag-embark-node-view supertag-embark-tag-view
                       supertag-embark-link-open supertag-embark-concept-open
                       supertag-embark-node-reference-open supertag-embark-region-add-link
                       supertag-embark-region-add-tag supertag-embark-region-promote
                       supertag-embark-node-reference-view))
      (should-not (commandp adapter))
      (should-error (funcall adapter "stale target") :type 'user-error))))

(ert-deftest supertag-embark-disabled-setup-does-not-register ()
  (let ((supertag-embark-integration nil)
        (embark-target-finders '(existing))
        (embark-keymap-alist '((existing . ignored))))
    (should-not (supertag-embark-setup))
    (should (equal embark-target-finders '(existing)))
    (should (equal embark-keymap-alist '((existing . ignored))))))

(ert-deftest supertag-embark-load-does-not-require-embark ()
  (let ((features (remq 'embark features))
        (original-require (symbol-function 'require)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &rest args)
                 (when (eq feature 'embark) (error "Embark is unavailable"))
                 (apply original-require feature args))))
      (load (expand-file-name "supertag-embark.el" supertag-embark-test--root) nil t t))
    (should-not (featurep 'embark))))

(ert-deftest supertag-embark-six-raw-keymaps-have-only-noncommand-adapters ()
  (skip-unless (require 'embark nil t))
  (let ((embark-target-finders nil) (embark-keymap-alist nil)
        (supertag-embark-integration t))
    (supertag-embark-setup)
    (should (eq (car embark-target-finders) #'supertag-embark-target-finder))
    (should (= 6 (length embark-keymap-alist)))
    (dolist (spec '((node "RET" "v" "t" "r" "l" "d" "m" "M" "p" "x")
                    (tag "RET" "r" "c" "R" "D") (link "RET" "d")
                    (concept "RET" "l") (node-reference "RET" "v" "t" "r") (region "RET" "l" "t" "p")))
      (let* ((type (intern (concat "supertag-" (symbol-name (car spec)))))
             (own (symbol-value (alist-get type embark-keymap-alist)))
             (map (embark--raw-action-keymap type))
             (keys (mapcar (lambda (key) (aref (kbd key) 0)) (cdr spec)))
             actual)
        (should-not (keymap-parent own))
        (map-keymap (lambda (key action)
                      (push key actual)
                      (should (functionp action))
                      (should-not (commandp action))) map)
        (should (equal (sort actual #'<) (sort keys #'<)))
        (should-not (lookup-key map (kbd "i")))
        (should (lookup-key map (kbd "RET")))))))


(ert-deftest supertag-embark-body-target-is-read-only-and-excludes-preamble ()
  (supertag-document-test-with-vault
    (with-temp-buffer
      (org-mode) (insert "Preamble\n* Heading\nBody\n")
      (goto-char 1)
      (should-not (supertag-embark-target-finder)))
    (with-current-buffer (find-file-noselect plain)
      (goto-char (point-max))
      (let ((position (point)) (disk (supertag-document-test-disk plain)))
        (should (eq 'supertag-node (car (supertag-embark-target-finder))))
        (should (eq :containing-node (plist-get (supertag-embark--target-at-point) :origin)))
        (should-not (plist-get (supertag-embark--target-at-point) :node-id))
        (should (= position (point)))
        (should-not (buffer-modified-p))
        (should (equal disk (buffer-string)))
        (should (equal disk (supertag-document-test-disk plain)))))))

(ert-deftest supertag-embark-read-only-body-and-region-have-no-write-target ()
  (with-temp-buffer
    (org-mode) (insert "* Heading\nPlain body\n")
    (search-backward "body")
    (let ((buffer-read-only t))
      (should-not (supertag-embark-target-finder))
      (set-mark 1)
      (let ((transient-mark-mode t) (mark-active t))
        (should-not (supertag-embark-target-finder))))))

(ert-deftest supertag-embark-region-tag-writes-both-node-memberships ()
  (supertag-document-test-with-vault
    (supertag-tag-create '(:name "batch"))
    (with-temp-file file
      (insert "* One\n:PROPERTIES:\n:ID: one\n:END:\nBody\n* Two\n:PROPERTIES:\n:ID: two\n:END:\nBody\n"))
    (supertag-reindex-org)
    (switch-to-buffer (find-file-noselect file))
    (goto-char (point-max)) (set-mark 1)
    (let ((transient-mark-mode t) (mark-active t))
      (cl-letf (((symbol-function 'supertag-ui-read-tag) (lambda (&rest _) "batch")))
        (supertag-embark-region-add-tag)))
    (let ((id (supertag-tag-resolve-occurrence "batch"))
          (disk (supertag-document-test-disk file)))
      (dolist (node '("one" "two"))
        (should (equal (plist-get (supertag-node-get node) :tags) (list id))))
      (should (string-match-p (regexp-quote "* One #batch") disk))
      (should (string-match-p (regexp-quote "* Two #batch") disk))
      (should-not (buffer-modified-p)))))

(ert-deftest supertag-embark-region-promote-preserves-live-selection ()
  (with-temp-buffer
    (org-mode) (insert "* Heading\nSelected text\n")
    (goto-char (point-max)) (backward-char 1) (set-mark (line-beginning-position))
    (let ((transient-mark-mode t) (mark-active t)
          (begin (region-beginning)) (end (region-end)) called)
      (cl-letf (((symbol-function 'supertag-promote)
                 (lambda () (interactive)
                   (setq called t)
                   (should (use-region-p))
                   (should (= begin (region-beginning)))
                   (should (= end (region-end))))))
        (supertag-embark-region-promote))
      (should called))))

(ert-deftest supertag-embark-node-view-tag-removal-saves-and-refreshes ()
  (supertag-document-test-with-vault
    (supertag-tag-create '(:name "viewtag"))
    (with-temp-file file
      (insert "* Source #viewtag\n:PROPERTIES:\n:ID: source\n:END:\nBody\n"))
    (supertag-reindex-org)
    (let ((id (supertag-tag-resolve-occurrence "viewtag"))
          (view (with-current-buffer (find-file-noselect file)
                  (supertag-view-node-open "source"))))
      (with-current-buffer view
        (goto-char (point-min))
        (goto-char (text-property-any (point-min) (point-max) 'tag-id id))
        (should (eq 'supertag-tag (car (supertag-embark-target-finder))))
        (should (equal "source" (plist-get (supertag-embark--target-at-point) :node-id)))
        (should (eq :view-tag (plist-get (supertag-embark--target-at-point) :origin)))
        (supertag-embark-tag-remove)
        (should-not (text-property-any (point-min) (point-max) 'tag-id id)))
      (should-not (string-match-p "#viewtag" (supertag-document-test-disk file)))
      (should-not (plist-get (supertag-node-get "source") :tags)))))

(ert-deftest supertag-embark-node-reference-view-opens-target ()
  (supertag-document-test-with-vault
    (with-temp-buffer
      (insert (propertize "Target" 'supertag-node-id "document-node"))
      (goto-char 2)
      (supertag-embark-node-reference-view))
    (with-current-buffer (supertag-view-node--buffer)
      (should (equal (buffer-name) "*Supertag Node*"))
      (should (equal supertag-view-node--current-node-id "document-node")))))

(ert-deftest supertag-embark-semantic-title-is-node-reference ()
  (supertag-document-test-with-vault
    (with-temp-buffer
      (let ((supertag-semantic-enabled t)
            (supertag-semantic--error nil) (supertag-semantic--paused nil)
            (supertag-semantic--dirty (make-hash-table :test 'equal)))
        (cl-letf (((symbol-function 'supertag-semantic--ensure) #'ignore)
                  ((symbol-function 'supertag-semantic--queue) #'ignore)
                  ((symbol-function 'supertag-semantic--schedule) #'ignore)
                  ((symbol-function 'supertag-semantic--matches)
                   (lambda (_) (list (list :id "document-node" :score 0.9
                                          :node '(:title "Semantic title" :content "Preview"))))))
          (supertag-semantic-insert-section "other")))
      (goto-char 1) (search-forward "Semantic title") (backward-char 1)
      (should (button-at (point)))
      (should (eq 'supertag-node-reference (car (supertag-embark-target-finder))))
      (should (equal "document-node" (plist-get (supertag-embark--target-at-point) :node-id))))))


(defun supertag-embark-test--open-view-tag (file node-id tag-id)
  "Open Node View for NODE-ID from FILE and move point onto TAG-ID's line."
  (let ((view (with-current-buffer (find-file-noselect file)
                (supertag-view-node-open node-id))))
    (with-current-buffer view
      (goto-char (text-property-any (point-min) (point-max) 'tag-id tag-id))
      (should (eq :view-tag (plist-get (supertag-embark--target-at-point) :origin))))
    view))

(ert-deftest supertag-embark-node-view-tag-change-replaces-only-current-node ()
  (supertag-document-test-with-vault
    (supertag-tag-create '(:name "old"))
    (with-temp-file file
      (insert "* Source #old\n:PROPERTIES:\n:ID: source\n:END:\nBody #old\n"
              "* Other #old\n:PROPERTIES:\n:ID: other\n:END:\nKeep #old\n"))
    (supertag-reindex-org)
    (let ((view (supertag-embark-test--open-view-tag
                 file "source" (supertag-tag-resolve-occurrence "old"))))
      (with-current-buffer view
        (cl-letf (((symbol-function 'supertag-ui-read-tag) (lambda (&rest _) "new")))
          (supertag-embark-tag-change)))
      (let ((text (supertag-document-test-disk file)))
        (should (string-match-p (regexp-quote "* Source #new") text))
        (should (string-match-p (regexp-quote "Body #new") text))
        (should (string-match-p (regexp-quote "* Other #old") text))
        (should (string-match-p (regexp-quote "Keep #old") text)))
      (should (equal (plist-get (supertag-node-get "source") :tags)
                     (list (supertag-tag-resolve-occurrence "new"))))
      (should (equal (plist-get (supertag-node-get "other") :tags)
                     (list (supertag-tag-resolve-occurrence "old")))))))

(ert-deftest supertag-embark-node-view-tag-rename-shows-preview-before-confirm ()
  (supertag-document-test-with-vault
    (supertag-tag-create '(:name "old"))
    (with-temp-file file
      (insert "* Source #old\n:PROPERTIES:\n:ID: source\n:END:\nBody\n"
              "* Other #old\n:PROPERTIES:\n:ID: other\n:END:\nKeep\n"))
    (supertag-reindex-org)
    (let* ((old-id (supertag-tag-resolve-occurrence "old"))
           (view (supertag-embark-test--open-view-tag file "source" old-id))
           seen-buffer seen-window)
      (with-current-buffer view
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "renamed"))
                  ((symbol-function 'yes-or-no-p)
                   (lambda (&rest _)
                     (setq seen-buffer (get-buffer "*Supertag Tag Change*")
                           seen-window (and seen-buffer (get-buffer-window seen-buffer)))
                     t)))
          (supertag-embark-tag-rename)))
      (should seen-buffer)
      (should seen-window)
      (let ((text (supertag-document-test-disk file)))
        (should (string-match-p (regexp-quote "* Source #renamed") text))
        (should (string-match-p (regexp-quote "* Other #renamed") text))
        (should-not (string-match-p "#old\\b" text)))
      (should-not (supertag-tag-get old-id))
      (should (equal (plist-get (supertag-node-get "other") :tags)
                     (list (supertag-tag-resolve-occurrence "renamed")))))))

(ert-deftest supertag-embark-node-view-tag-delete-everywhere-removes-all ()
  (supertag-document-test-with-vault
    (supertag-tag-create '(:name "gone"))
    (with-temp-file file
      (insert "* Source #gone\n:PROPERTIES:\n:ID: source\n:END:\nBody\n"
              "* Other #gone\n:PROPERTIES:\n:ID: other\n:END:\nKeep\n"))
    (supertag-reindex-org)
    (let* ((tag-id (supertag-tag-resolve-occurrence "gone"))
           (view (supertag-embark-test--open-view-tag file "source" tag-id))
           seen-window)
      (with-current-buffer view
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (&rest _)
                     (setq seen-window (get-buffer-window "*Supertag Tag Change*"))
                     t)))
          (supertag-embark-tag-delete)))
      (should seen-window)
      (should-not (string-match-p "#gone" (supertag-document-test-disk file)))
      (should-not (plist-get (supertag-node-get "source") :tags))
      (should-not (plist-get (supertag-node-get "other") :tags))
      (should-not (supertag-tag-get tag-id)))))

(ert-deftest supertag-embark-view-tag-finder-is-nil-outside-node-view ()
  (dolist (mode '(org-mode fundamental-mode))
    (with-temp-buffer
      (funcall mode)
      (insert (propertize "tag" 'type :tag 'tag-id "x"))
      (goto-char (point-min))
      (should-not (supertag-embark--view-tag-target))))
  (with-temp-buffer
    (supertag-view-node-mode)
    (let ((inhibit-read-only t))
      (insert (propertize "tag" 'type :tag 'tag-id "x")))
    (goto-char (point-min))
    (let ((target (supertag-embark--view-tag-target)))
      (should (eq :tag (plist-get target :kind)))
      (should (eq :view-tag (plist-get target :origin)))
      (should (equal "x" (plist-get target :tag-id))))))

(defun supertag-embark-test--two-tagged-nodes (file)
  "Write two nodes tagged #one into FILE and project them; return the tag id."
  (supertag-tag-create '(:name "one"))
  (with-temp-file file
    (insert "* Source #one\n:PROPERTIES:\n:ID: source\n:END:\nBody [[id:other][Other]]\n"
            "* Other #one\n:PROPERTIES:\n:ID: other\n:END:\nKeep\n"))
  (supertag-reindex-org)
  (supertag-tag-resolve-occurrence "one"))

(defun supertag-embark-test--goto-property (prop value)
  "Move point to the first position whose text property PROP equals VALUE."
  (goto-char (point-min))
  (let ((match (text-property-search-forward prop value t)))
    (should match)
    (goto-char (prop-match-beginning match))))

(defun supertag-embark-test--stream-at (tag-id node-id)
  "Open the Stream for TAG-ID and put point on NODE-ID's title line."
  (supertag-view-stream--register-view)
  (let ((buffer (supertag-view-stream tag-id)))
    (with-current-buffer buffer
      (supertag-embark-test--goto-property 'supertag-entity-id node-id)
      (should (eq :node-reference (plist-get (supertag-embark--target-at-point) :kind))))
    buffer))

(ert-deftest supertag-embark-stream-reference-add-tag-writes-remotely-and-refreshes ()
  (supertag-document-test-with-vault
    (let ((one (supertag-embark-test--two-tagged-nodes file)))
      (supertag-tag-create '(:name "two"))
      (let ((two (supertag-tag-resolve-occurrence "two"))
            (stream (supertag-embark-test--stream-at one "other")))
        (unwind-protect
            (progn
              (with-current-buffer stream
                (cl-letf (((symbol-function 'supertag-ui-read-tag) (lambda (&rest _) "two")))
                  (supertag-embark-node-reference-add-tag))
                (should (string-match-p (regexp-quote (concat "#" two)) (buffer-string))))
              (should (string-match-p (regexp-quote "* Other #one #two")
                                      (supertag-document-test-disk file)))
              (should (member two (plist-get (supertag-node-get "other") :tags)))
              (should-not (member two (plist-get (supertag-node-get "source") :tags))))
          (when (buffer-live-p stream) (kill-buffer stream)))))))

(ert-deftest supertag-embark-stream-reference-add-tag-creates-a-new-tag-after-confirm ()
  (supertag-document-test-with-vault
    (let* ((one (supertag-embark-test--two-tagged-nodes file))
           (stream (supertag-embark-test--stream-at one "other"))
           asked)
      (unwind-protect
          (progn
            (with-current-buffer stream
              (cl-letf (((symbol-function 'supertag-ui-read-tag) (lambda (&rest _) "brandnew"))
                        ((symbol-function 'yes-or-no-p) (lambda (&rest _) (setq asked t) t)))
                (supertag-embark-node-reference-add-tag)))
            (should asked)
            (should (supertag-tag-resolve-occurrence "brandnew"))
            (should (string-match-p (regexp-quote "* Other #one #brandnew")
                                    (supertag-document-test-disk file))))
        (when (buffer-live-p stream) (kill-buffer stream))))))

(ert-deftest supertag-embark-node-view-reference-card-remove-tag-writes-remotely ()
  (supertag-document-test-with-vault
    (let* ((one (supertag-embark-test--two-tagged-nodes file))
           (view (with-current-buffer (find-file-noselect file)
                   (supertag-view-node-open "source"))))
      (with-current-buffer view
        (supertag-embark-test--goto-property 'supertag-reference-node-id "other")
        (should (eq :reference-card (plist-get (supertag-embark--target-at-point) :origin)))
        (cl-letf (((symbol-function 'supertag-ui-read-tag) (lambda (&rest _) one)))
          (supertag-embark-node-reference-remove-tag)))
      (let ((text (supertag-document-test-disk file)))
        (should (string-match-p "^\\* Other *$" text))
        (should (string-match-p (regexp-quote "* Source #one") text)))
      (should-not (plist-get (supertag-node-get "other") :tags))
      (should (equal (list one) (plist-get (supertag-node-get "source") :tags))))))

(ert-deftest supertag-embark-remote-write-refuses-unsaved-drafts-but-not-the-current-buffer ()
  (supertag-document-test-with-vault
    (let* ((one (supertag-embark-test--two-tagged-nodes file))
           (before (supertag-document-test-disk file))
           (org (find-file-noselect file))
           (stream (supertag-embark-test--stream-at one "other")))
      (unwind-protect
          (progn
            (with-current-buffer org
              (goto-char (point-max)) (insert "draft\n"))
            (should (buffer-modified-p org))
            (with-current-buffer stream
              (cl-letf (((symbol-function 'supertag-ui-read-tag) (lambda (&rest _) "one")))
                (should-error (supertag-embark-node-reference-add-tag) :type 'user-error)
                (should-error (supertag-embark-node-reference-remove-tag) :type 'user-error)))
            (should (equal before (supertag-document-test-disk file)))
            (should (buffer-modified-p org))
            (should (equal (list one) (plist-get (supertag-node-get "other") :tags)))
            ;; The visiting buffer itself may still act on its own inline tag.
            (with-current-buffer org
              (goto-char (point-min)) (search-forward "* Other #one") (backward-char 1)
              (should (eq :tag (plist-get (supertag-embark--target-at-point) :kind)))
              (supertag-embark-tag-remove))
            (should (string-match-p "^\\* Other *$" (supertag-document-test-disk file)))
            (should-not (plist-get (supertag-node-get "other") :tags)))
        (when (buffer-live-p stream) (kill-buffer stream))))))

(ert-deftest supertag-embark-stream-tag-token-is-a-tag-object-that-writes-its-node ()
  (supertag-document-test-with-vault
    (let* ((one (supertag-embark-test--two-tagged-nodes file))
           (stream (supertag-embark-test--stream-at one "other")))
      (unwind-protect
          (with-current-buffer stream
            (search-forward (concat "#" one)) (backward-char 1)
            (let ((target (supertag-embark--target-at-point)))
              (should (eq :tag (plist-get target :kind)))
              (should (eq :stream-tag (plist-get target :origin)))
              (should (equal one (plist-get target :tag-id)))
              (should (equal "other" (plist-get target :node-id)))
              (should (eq 'supertag-tag (car (supertag-embark-target-finder)))))
            (supertag-embark-tag-remove)
            (should (string-match-p "^\\* Other *$" (supertag-document-test-disk file)))
            (should-not (plist-get (supertag-node-get "other") :tags))
            (should (equal (list one) (plist-get (supertag-node-get "source") :tags))))
        (when (buffer-live-p stream) (kill-buffer stream))))))

(ert-deftest supertag-embark-stream-tag-token-bounds-are-the-token-span ()
  (supertag-document-test-with-vault
    (let* ((one (supertag-embark-test--two-tagged-nodes file))
           (stream (supertag-embark-test--stream-at one "other")))
      (unwind-protect
          (with-current-buffer stream
            (search-forward (concat "#" one)) (backward-char 1)
            (let* ((target (supertag-embark--target-at-point))
                   (found (supertag-embark-target-finder))
                   (bounds (cddr found)))
              (should (integerp (plist-get target :begin)))
              (should (integerp (plist-get target :end)))
              (should (< (plist-get target :begin) (plist-get target :end)))
              (should (eq 'supertag-tag (car found)))
              (should (integerp (car bounds)))
              (should (integerp (cdr bounds)))
              (should (equal (concat "#" one)
                             (buffer-substring-no-properties (car bounds) (cdr bounds))))))
        (when (buffer-live-p stream) (kill-buffer stream))))))

(defun supertag-embark-test--draft-then (org answer)
  "Return a stub that inserts a draft into ORG and then answers ANSWER."
  (lambda (&rest _)
    (with-current-buffer org (goto-char (point-max)) (insert "draft\n"))
    answer))

(ert-deftest supertag-embark-remote-add-and-remove-recheck-drafts-after-the-prompt ()
  (supertag-document-test-with-vault
    (let* ((one (supertag-embark-test--two-tagged-nodes file))
           (before (supertag-document-test-disk file))
           (org (find-file-noselect file))
           (stream (supertag-embark-test--stream-at one "other"))
           created)
      (supertag-tag-create '(:name "two"))
      (unwind-protect
          (progn
            (with-current-buffer stream
              (cl-letf (((symbol-function 'supertag-ui-read-tag)
                         (supertag-embark-test--draft-then org "two"))
                        ((symbol-function 'supertag-tag-create)
                         (lambda (&rest _) (setq created t))))
                (should-error (supertag-embark-node-reference-add-tag) :type 'user-error))
              (should (buffer-modified-p org))
              (with-current-buffer org (set-buffer-modified-p nil))
              (cl-letf (((symbol-function 'supertag-ui-select-tag-on-node)
                         (supertag-embark-test--draft-then org one)))
                (should-error (supertag-embark-node-reference-remove-tag) :type 'user-error)))
            (should-not created)
            (should (equal before (supertag-document-test-disk file)))
            (should (equal (list one) (plist-get (supertag-node-get "other") :tags))))
        (when (buffer-live-p stream) (kill-buffer stream))))))

(ert-deftest supertag-embark-tag-change-rechecks-drafts-after-the-prompt ()
  (supertag-document-test-with-vault
    (let* ((one (supertag-embark-test--two-tagged-nodes file))
           (before (supertag-document-test-disk file))
           (org (find-file-noselect file))
           (stream (supertag-embark-test--stream-at one "other"))
           replaced)
      (supertag-tag-create '(:name "two"))
      (unwind-protect
          (progn
            (with-current-buffer stream
              (search-forward (concat "#" one)) (backward-char 1)
              (cl-letf (((symbol-function 'supertag-ui-read-tag)
                         (supertag-embark-test--draft-then org "two"))
                        ((symbol-function 'supertag-capture-replace-tag-on-node)
                         (lambda (&rest _) (setq replaced t))))
                (should-error (supertag-embark-tag-change) :type 'user-error)))
            (should-not replaced)
            (should (equal before (supertag-document-test-disk file)))
            (should (equal (list one) (plist-get (supertag-node-get "other") :tags))))
        (when (buffer-live-p stream) (kill-buffer stream))))))

(ert-deftest supertag-embark-remote-add-tag-strips-the-literal-prefix ()
  (supertag-document-test-with-vault
    (let* ((one (supertag-embark-test--two-tagged-nodes file))
           (stream (supertag-embark-test--stream-at one "other"))
           asked)
      (supertag-tag-create '(:name "two"))
      (unwind-protect
          (progn
            (with-current-buffer stream
              (cl-letf (((symbol-function 'supertag-ui-read-tag) (lambda (&rest _) "=two")))
                (supertag-embark-node-reference-add-tag))
              (cl-letf (((symbol-function 'supertag-ui-read-tag) (lambda (&rest _) "=brandnew"))
                        ((symbol-function 'yes-or-no-p)
                         (lambda (prompt &rest _) (setq asked prompt) t)))
                (supertag-embark-node-reference-add-tag)))
            (should (string-match-p (regexp-quote "* Other #one #two #brandnew")
                                    (supertag-document-test-disk file)))
            (should (string-match-p "'brandnew'" asked))
            (should-not (supertag-tag-resolve-occurrence "=two"))
            (should-not (supertag-tag-resolve-occurrence "=brandnew")))
        (when (buffer-live-p stream) (kill-buffer stream))))))

(provide 'embark-test)

;;; D6 actual selector input, member writer and remote second draft guard.
(ert-deftest supertag-embark-remove-node-and-reference-use-real-selector ()
  (dolist (kind '(node reference))
    (supertag-document-test-with-vault
      (let* ((one (supertag-embark-test--two-tagged-nodes file))
             (org (find-file-noselect file))
             (other-before (copy-tree (supertag-node-get (if (eq kind 'node) "other" "source"))))
             (entity (copy-tree (supertag-tag-get one)))
             (view (and (eq kind 'reference) (with-current-buffer org (supertag-view-node-open "source"))))
             selected)
        (unwind-protect
            (progn
              (with-current-buffer (or view org)
                (if view
                    (supertag-embark-test--goto-property 'supertag-reference-node-id "other")
                  (goto-char (point-min)) (search-forward "\n:END:\n"))
                (cl-letf (((symbol-function 'completing-read)
                           (lambda (_prompt candidates &rest _)
                             (should (member "one" candidates)) (setq selected t) "one")))
                  (if view (supertag-embark-node-reference-remove-tag)
                    (supertag-embark-node-remove-tag))))
              (should selected)
              (should-not (plist-get (supertag-node-get (if view "other" "source")) :tags))
              (should (equal entity (supertag-tag-get one)))
              (should (equal other-before (supertag-node-get (if view "source" "other"))))
              (should-not (buffer-modified-p org))
              (should (equal (with-current-buffer org (buffer-string)) (supertag-document-test-disk file))))
          (when (buffer-live-p view) (kill-buffer view)))))))

(ert-deftest supertag-embark-reference-real-selector-rechecks-prompt-draft ()
  (supertag-document-test-with-vault
    (let* ((one (supertag-embark-test--two-tagged-nodes file))
           (org (find-file-noselect file))
           (disk (supertag-document-test-disk file))
           (store (prin1-to-string supertag--store))
           (stream (supertag-embark-test--stream-at one "other")) prompted)
      (unwind-protect
          (progn
            (with-current-buffer stream
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt candidates &rest _)
                           (should (member "one" candidates)) (setq prompted t)
                           (with-current-buffer org (goto-char (point-max)) (insert "D6 draft\n")) "one")))
                (should-error (supertag-embark-node-reference-remove-tag) :type 'user-error)))
            (should prompted) (should (buffer-modified-p org))
            (should (equal (concat disk "D6 draft\n") (with-current-buffer org (buffer-string))))
            (should (equal disk (supertag-document-test-disk file)))
            (should (equal store (prin1-to-string supertag--store))))
        (when (buffer-live-p stream) (kill-buffer stream))))))

(ert-deftest supertag-embark-reference-empty-selector-does-not-touch-source ()
  (supertag-document-test-with-vault
    (let* ((one (supertag-embark-test--two-tagged-nodes file))
           (org (find-file-noselect file)))
      (supertag-service-org-remove-tag "other" one)
      (let* ((view (with-current-buffer org (supertag-view-node-open "source")))
             (disk (supertag-document-test-disk file))
             (store (prin1-to-string supertag--store)))
        (unwind-protect
            (progn
              (with-current-buffer view
                (supertag-embark-test--goto-property 'supertag-reference-node-id "other")
                (cl-letf (((symbol-function 'completing-read)
                           (lambda (&rest _) (ert-fail "empty reference prompted"))))
                  (should-error (supertag-embark-node-reference-remove-tag) :type 'user-error)))
              (should (equal disk (supertag-document-test-disk file)))
              (should (equal disk (with-current-buffer org (buffer-string))))
              (should-not (buffer-modified-p org))
              (should (equal store (prin1-to-string supertag--store))))
          (when (buffer-live-p view) (kill-buffer view)))))))

;;; NODE-D real Move adapters; only user input is substituted.
(ert-deftest supertag-embark-move-adapters-use-real-node-writer ()
  (dolist (adapter '(supertag-embark-node-move supertag-embark-node-move-and-link))
    (supertag-document-test-with-vault
      (switch-to-buffer (find-file-noselect file)) (goto-char (point-min))
      (let ((origin (current-buffer)) (position (point))
            (target-before (supertag-document-test-disk plain)))
        (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) plain))
                  ((symbol-function 'completing-read) (lambda (&rest _) "File End"))
                  ((symbol-function 'yes-or-no-p) (lambda (_) t)))
          (should (equal '("document-node") (funcall adapter))))
        (should (eq origin (current-buffer))) (should (= position (point)))
        (should (string-prefix-p target-before (supertag-document-test-disk plain)))
        (should (equal plain (plist-get (supertag-node-get "document-node") :file)))
        (if (eq adapter 'supertag-embark-node-move-and-link)
            (progn
              (goto-char (point-min))
              (should (org-entry-get nil "ID"))
              (should-not (equal "document-node" (org-entry-get nil "ID")))
              (should (string-match-p "\\[\\[id:document-node\\]" (supertag-document-test-disk file))))
          (should (equal "" (supertag-document-test-disk file))))))))

(ert-deftest supertag-embark-move-adapters-reject-non-node-before-input ()
  (with-temp-buffer
    (org-mode) (insert "No heading")
    (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) (ert-fail "Unexpected Move input"))))
      (dolist (adapter '(supertag-embark-node-move supertag-embark-node-move-and-link))
        (should-error (funcall adapter) :type 'user-error)))))
