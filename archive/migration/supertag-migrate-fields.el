;;; supertag-migrate-fields.el --- One-time field migration -*- lexical-binding: t; -*-
;; Commands: supertag-migrate-fields-preview, supertag-migrate-fields-apply.
;; Dependencies: core-store (legacy facts), service-org (saved writer), org.
;; Explicitly load this script; remove after phase 6 migration is complete.
(require 'supertag-core-store)
(require 'supertag-service-org)
(require 'org)

(defun supertag-migrate-fields--format-date (value)
  "Best-effort formatting of VALUE as a date string."
  (cond
   ((null value) "")
   ((stringp value) value)
   ;; Emacs time list (high low micro pico)
   ((and (listp value) (= (length value) 4))
    (format-time-string "%Y-%m-%d" value))
   ;; Fallback
   (t (format "%s" value))))

(defun supertag-migrate-fields--format-timestamp (value)
  "Best-effort formatting of VALUE as a timestamp string."
  (cond
   ((null value) "")
   ((stringp value) value)
   ;; Emacs time list (high low micro pico)
   ((and (listp value) (= (length value) 4))
    (format-time-string "%Y-%m-%d %H:%M" value))
   (t (format "%s" value))))

(defun supertag-migrate-fields--display (type value)
  "Render VALUE of TYPE as a single-line Org property value."
  (replace-regexp-in-string
   "[\n\r]" " "
   (cond
    ((or (null value) (equal value "")) "")
    ((eq type :boolean) (if (member value '("false" false :false)) "false" "true"))
    ((eq type :date) (supertag-migrate-fields--format-date value))
    ((eq type :timestamp) (supertag-migrate-fields--format-timestamp value))
    ((eq type :node-reference)
     (mapconcat
      (lambda (id)
        (let ((title (plist-get (supertag-store-get-entity :nodes id) :title)))
          (if (and title (not (equal title "")))
              (format "[[id:%s][%s]]" id title)
            (format "[[id:%s]]" id))))
      (if (listp value) value (list value)) " "))
    ((listp value) (mapconcat (lambda (item) (format "%s" item)) value " "))
    (t (format "%s" value)))))

(defun supertag-migrate-fields--references (form)
  "List field references within an Automation FORM, without evaluating it."
  (cond
   ((memq form '(:on-field-change field-equals field-changed
                 global-field-equals global-field-changed
                 supertag-field-set :update-field)) (list form))
   ((consp form) (append (supertag-migrate-fields--references (car form))
                         (supertag-migrate-fields--references (cdr form))))))

(defun supertag-migrate-fields--collect ()
  "Read legacy facts and live Org into a migration report."
  (let (nodes skipped automations (write-count 0) (conflict-count 0) (node-count 0) (pending-count 0))
    (maphash
     (lambda (id fields)
       (let* ((node (supertag-store-get-entity :nodes id))
              (file (plist-get node :file))
              (candidates (make-hash-table :test 'equal)) writes conflicts pending)
         (if (not (and node (not (equal (plist-get node :level) 0))
                       file (file-exists-p file)))
             (push (list :id id :file file :reason :unlocatable) skipped)
           (maphash
            (lambda (fid value)
              (let* ((definition (supertag-store-get-field-definition fid))
                     (name (or (plist-get definition :name) fid ""))
                     (key (replace-regexp-in-string "[[:space:]:]" "_"
                                                    (upcase (format "%s" name))))
                     (display (supertag-migrate-fields--display
                               (if definition (plist-get definition :type) :undefined) value))
                     (reason (cond ((equal key "") :empty-name)
                                   ((or (equal key "ID")
                                        (member key org-special-properties)) :reserved)
                                   ((equal display "") :empty-value))))
                (if reason
                    (push (list :id id :file file :field fid :key key :reason reason) skipped)
                  (puthash key (cons (cons (format "%s" name) display) (gethash key candidates)) candidates)))) fields)
           (condition-case nil
               (supertag-service-org--with-node-buffer
                id (lambda ()
                     (dolist (key (sort (hash-table-keys candidates) #'string<))
                       (let* ((entries (sort (gethash key candidates)
                                             (lambda (a b)
                                               (if (equal (car a) (car b))
                                                   (string< (cdr a) (cdr b))
                                                 (string< (car a) (car b))))))
                              (values (delete-dups (mapcar #'cdr entries)))
                              (value (car values))
                              (old (org-entry-get nil key)))
                         (cond
                          ((cdr values)
                           (push (list :type :key-conflict :key key :fields entries) conflicts))
                          ((equal old value)
                           (unless (and (not (buffer-modified-p))
                                        (equal value (plist-get (plist-get node :properties)
                                                                (intern (concat ":" key)))))
                             (push (cons key value) pending)))
                          (old (push (list :key key :org old :field value) conflicts))
                          (t (push (cons key value) writes)))))))
             (user-error
              (setq writes nil conflicts nil pending nil)
              (push (list :id id :file file :reason :unlocatable) skipped))))
         (setq write-count (+ write-count (length writes))
               conflict-count (+ conflict-count (length conflicts)))
         (setq pending-count (+ pending-count (length pending)))
         (when writes (setq node-count (1+ node-count)))
         (push (list :id id :file file :title (plist-get node :title)
                     :writes (nreverse writes) :pending (nreverse pending) :conflicts (nreverse conflicts)) nodes)))
     (supertag-store-get-collection :field-values))
    (maphash
     (lambda (_id rule)
       (let (references)
         (dolist (part '(:trigger :condition :actions))
           (dolist (reference (delete-dups (supertag-migrate-fields--references (plist-get rule part))))
             (push (cons part reference) references)))
         (when references
           (push (list :name (plist-get rule :name) :references (nreverse references)) automations))))
     (supertag-store-get-collection :automations))
    (list :nodes (sort nodes (lambda (a b)
                              (string< (format "%s/%s" (plist-get a :file) (plist-get a :id))
                                       (format "%s/%s" (plist-get b :file) (plist-get b :id)))))
          :skipped (nreverse skipped) :automations (nreverse automations)
          :pending-count pending-count :write-count write-count :node-count node-count :conflict-count conflict-count)))

;;;###autoload
(defun supertag-migrate-fields-preview ()
  "Preview legacy fields against live Org without modifying either; return report."
  (interactive)
  (let ((report (supertag-migrate-fields--collect))
        (buffer (get-buffer-create "*Supertag Field Migration*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t) last-file)
        (erase-buffer)
        (dolist (node (plist-get report :nodes))
          (unless (equal last-file (plist-get node :file))
            (setq last-file (plist-get node :file))
            (insert (format "\n文件 %s\n" last-file)))
          (insert (format "%s [%s]\n" (plist-get node :title) (plist-get node :id)))
          (dolist (pair (plist-get node :writes))
            (insert (format "  %s = %s\n" (car pair) (cdr pair))))
          (dolist (pair (plist-get node :pending))
            (insert (format "  待保存/待投影 %s = %s\n" (car pair) (cdr pair))))
          (dolist (conflict (plist-get node :conflicts))
            (if (eq (plist-get conflict :type) :key-conflict)
                (insert (format "  同键冲突 %s: %S\n" (plist-get conflict :key)
                                (plist-get conflict :fields)))
              (insert (format "  冲突 %s: Org=%s 字段=%s\n"
                              (plist-get conflict :key) (plist-get conflict :org)
                              (plist-get conflict :field))))))
        (dolist (group '((:empty-name . "空名") (:empty-value . "空值跳过")
                         (:reserved . "保留键") (:unlocatable . "无法定位")))
          (insert (format "\n%s\n" (cdr group)))
          (dolist (item (plist-get report :skipped))
            (when (eq (plist-get item :reason) (car group))
              (insert (format "  %s %s %s\n" (plist-get item :file)
                              (plist-get item :id) (plist-get item :field))))))
        (insert "\nAutomation 字段引用（请手动修改）\n")
        (dolist (rule (plist-get report :automations))
          (insert (format "%s: %S\n" (plist-get rule :name) (plist-get rule :references))))
        (insert (format "\n写入 %d 键 / %d 节点，待保存/待投影 %d，冲突 %d，跳过 %d\n"
                        (plist-get report :write-count) (plist-get report :node-count)
                        (plist-get report :pending-count)
                        (plist-get report :conflict-count) (length (plist-get report :skipped)))))
      (special-mode))
    (when (called-interactively-p 'interactive) (pop-to-buffer buffer))
    report))

;;;###autoload
(defun supertag-migrate-fields-apply ()
  "Confirm, write nonconflicting fields, save and reproject each changed node."
  (interactive)
  (let ((report (supertag-migrate-fields-preview)))
    (when (yes-or-no-p (format "写入 %d 键 / %d 节点，待保存/待投影 %d，冲突 %d（保留 Org 值）；保存并重投影？ "
                              (plist-get report :write-count) (plist-get report :node-count)
                              (plist-get report :pending-count)
                              (plist-get report :conflict-count)))
      (dolist (node (plist-get report :nodes))
        (when (or (plist-get node :writes) (plist-get node :pending))
          (supertag-service-org--update-buffer-and-resync
           (plist-get node :id)
           (lambda ()
             (dolist (pair (plist-get node :writes))
               ;; Recheck live Org after confirmation; never overwrite a new value.
               (unless (org-entry-get nil (car pair))
                 (org-entry-put nil (car pair) (cdr pair)))))
           (and (plist-get node :pending) t))))
      (supertag-migrate-fields-preview))))

(provide 'supertag-migrate-fields)
;;; supertag-migrate-fields.el ends here
