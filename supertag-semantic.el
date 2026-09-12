;;; supertag-semantic.el --- Optional node-level similarity candidates -*- lexical-binding: t; -*-

;; Commands: supertag-semantic-rebuild, supertag-semantic-resume, supertag-semantic-status,
;; supertag-semantic-stop
;; Dependencies: cl-lib, subr-x, seq, json, button, org, org-element, org-fold, supertag-core-store,
;; supertag-core-persistence, supertag-view-framework; guarded existing
;; supertag-view-node refresh capabilities. Selected navigation actions use
;; supertag-node and supertag-view-node through the view integration.
;; Explicitly enabled embedding requests use the configured curl executable/endpoint.

;;; Commentary:
;; Read Store projections, embed asynchronously, and keep only a disposable
;; side-car index.  Similarity proposes notes, never identity or physical links.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'json)
(require 'button)
(require 'org)
(require 'org-element)
(require 'org-fold)
(require 'supertag-core-store)
(require 'supertag-core-persistence)
(require 'supertag-view-framework)
(declare-function supertag-view-node--buffer "supertag-view-node" ())
(declare-function supertag-view-node--refresh-view "supertag-view-node" ())
(declare-function supertag-view-node-open "supertag-view-node" (node-id))
(declare-function supertag-goto-node "supertag-node" (node-id &optional other-window))
(defvar supertag-view-node--current-node-id)

(defgroup supertag-semantic nil "Optional similarity candidates." :group 'supertag)
(defcustom supertag-semantic-enabled nil
  "Whether to show and compute semantic candidates.  Requires an embedding endpoint."
  :type 'boolean :group 'supertag-semantic)
(defcustom supertag-semantic-endpoint "http://localhost:11434"
  "Base URL of an Ollama-compatible /api/embed endpoint."
  :type 'string :group 'supertag-semantic)
(defcustom supertag-semantic-model "bge-m3"
  "Embedding model available at the endpoint.  Changing it rebuilds the index."
  :type 'string :group 'supertag-semantic)
(defcustom supertag-semantic-curl-program "curl"
  "Program used for asynchronous embedding HTTP requests."
  :type 'string :group 'supertag-semantic)
(defcustom supertag-semantic-request-timeout 30
  "Maximum seconds allowed for each embedding request."
  :type 'number :group 'supertag-semantic)
(defcustom supertag-semantic-max-chars 1500
  "Maximum own-body characters embedded after the title and outline path."
  :type 'natnum :group 'supertag-semantic)
(defcustom supertag-semantic-request-chars 6000
  "Approximate text-character budget per request; one longer node may exceed it."
  :type 'natnum :group 'supertag-semantic)
(defcustom supertag-semantic-max-results 5
  "Maximum similar-note candidates shown."
  :type 'natnum :group 'supertag-semantic)
(defcustom supertag-semantic-min-similarity 0.4
  "Minimum similarity, calibrated only on synthetic notes so far."
  :type 'number :group 'supertag-semantic)
(defcustom supertag-semantic-preview-lines 3
  "Maximum lines of a candidate's own-body preview."
  :type 'natnum :group 'supertag-semantic)

(defcustom supertag-semantic-save-interval 30
  "Minimum seconds between partial side-car saves; a drained queue saves immediately."
  :type 'number :group 'supertag-semantic)
(defvar supertag-semantic--last-save 0)
(defvar supertag-semantic--last-enabled nil
  "Non-nil after the current enabled context has been reconciled.
Nil preserves pending reconciliation across disabled or paused observations.")

(defvar supertag-semantic--vectors (make-hash-table :test 'equal))
(defvar supertag-semantic--dirty (make-hash-table :test 'equal))
(defvar supertag-semantic--context nil)
(defvar supertag-semantic--dim nil)
(defvar supertag-semantic--active nil)
(defvar supertag-semantic--process nil)
(defvar supertag-semantic--timer nil)
(defvar supertag-semantic--error nil)
(defvar supertag-semantic--paused nil)
(defvar supertag-semantic--rebuild nil
  "Active one-shot rebuild progress session, or nil.")
(defvar supertag-semantic--needs-save nil)
(defvar supertag-semantic--subscription-table nil)

(defun supertag-semantic--current-context ()
  "Return the cache identity for this data directory and model."
  (list (supertag-data-file "supertag-semantic.el") supertag-semantic-model))

(defun supertag-semantic--node (id)
  "Read ID's projection without initializing or writing Store."
  (gethash id (supertag-store-get-collection :nodes)))

(defun supertag-semantic--text (node)
  "Return NODE's title, outline path and bounded own-body input."
  (let ((body (or (plist-get node :content) ""))
        (path (plist-get node :olp)))
    (concat (or (plist-get node :title) "") "\n"
            (if (listp path) (mapconcat #'identity path " / ") (or path "")) "\n"
            (substring body 0 (min (length body) supertag-semantic-max-chars)))))

(defun supertag-semantic--hash (node)
  (secure-hash 'sha256 (supertag-semantic--text node)))

(defun supertag-semantic--quantize (vector)
  "Normalize VECTOR and encode signed int8 components as bytes offset by 128."
  (unless (and (sequencep vector) (> (length vector) 0)
               (cl-every (lambda (x) (and (numberp x) (= x x) (< (abs x) 1.0e100))) vector))
    (error "Invalid embedding vector"))
  (let* ((norm (sqrt (cl-loop for x across (vconcat vector) sum (* x x))))
         (bytes (make-string (length vector) 0)))
    (unless (> norm 0) (error "Zero embedding vector"))
    (dotimes (i (length vector))
      (aset bytes i (+ 128 (max -127 (min 127 (round (* 127 (/ (float (elt vector i)) norm))))))))
    bytes))

(defun supertag-semantic--score (a b)
  "Return the normalized int8 dot product of A and B."
  (unless (= (length a) (length b)) (error "Embedding dimensions differ"))
  (/ (float (cl-loop for i below (length a)
                     sum (* (- (aref a i) 128) (- (aref b i) 128))))
     (* 127 127)))

(defun supertag-semantic--load ()
  "Read a compatible side-car.  Incompatible or malformed caches are disposable."
  (when (file-readable-p (car supertag-semantic--context))
    (condition-case nil
        (let ((data (with-temp-buffer
                      (insert-file-contents (car supertag-semantic--context))
                      (read (current-buffer)))))
          (when (and (equal (plist-get data :version) 1)
                     (equal (plist-get data :model) supertag-semantic-model)
                     (integerp (plist-get data :dim)) (> (plist-get data :dim) 0))
            (let ((dim (plist-get data :dim))
                  (vectors (make-hash-table :test 'equal)))
              (dolist (entry (plist-get data :entries))
                (unless (and (stringp (car entry)) (stringp (cadr entry))
                             (stringp (cddr entry)))
                  (error "Invalid cached vector"))
                (let ((bytes (string-to-unibyte (cddr entry))))
                  (unless (= (length bytes) dim) (error "Invalid cached dimension"))
                  (puthash (car entry) (cons (cadr entry) bytes) vectors)))
              (setq supertag-semantic--vectors vectors supertag-semantic--dim dim))))
      (error nil))))

(defun supertag-semantic--save ()
  "Atomically replace only this feature's disposable side-car."
  (when supertag-semantic--dim
    (let* ((file (car supertag-semantic--context))
           (directory (file-name-directory file)) temp entries)
      (maphash (lambda (id entry) (push (cons id entry) entries)) supertag-semantic--vectors)
      (make-directory directory t)
      (unwind-protect
          (progn
            (setq temp (make-temp-file (expand-file-name ".semantic-" directory)))
            (let ((coding-system-for-write 'utf-8-unix)
                  (print-length nil) (print-level nil) (print-escape-nonascii t))
              (with-temp-file temp
                (prin1 (list :version 1 :model (cadr supertag-semantic--context)
                             :dim supertag-semantic--dim :entries entries) (current-buffer))))
            (rename-file temp file t)
            (setq supertag-semantic--needs-save nil
                  supertag-semantic--last-save (float-time)))
        (when (and temp (file-exists-p temp)) (delete-file temp))))))

(defun supertag-semantic--queue (id)
  "Mark ID dirty only when its embedding text changed; remove deleted IDs."
  (let ((node (supertag-semantic--node id)))
    (if node
        (if (equal (car (gethash id supertag-semantic--vectors))
                   (supertag-semantic--hash node))
            (remhash id supertag-semantic--dirty)
          (puthash id t supertag-semantic--dirty))
      (when (gethash id supertag-semantic--vectors)
        (remhash id supertag-semantic--vectors)
        (setq supertag-semantic--needs-save t))
      (remhash id supertag-semantic--dirty))))

(defun supertag-semantic--scan ()
  "Reconcile the disposable index against currently projected nodes."
  (maphash (lambda (id _) (supertag-semantic--queue id))
           (supertag-store-get-collection :nodes))
  (dolist (id (hash-table-keys supertag-semantic--vectors))
    (unless (supertag-semantic--node id) (supertag-semantic--queue id))))

(defun supertag-semantic--schedule ()
  "Schedule one idle batch, never a concurrent request or automatic error retry."
  (when (and supertag-semantic-enabled (not supertag-semantic--paused)
             (not supertag-semantic--active) (not supertag-semantic--timer)
             (or (> (hash-table-count supertag-semantic--dirty) 0) supertag-semantic--needs-save))
    (setq supertag-semantic--timer (run-with-idle-timer 0.2 nil #'supertag-semantic--pump))))

(defun supertag-semantic--changed (path _old _new)
  "Track node PATH changes while enabled; never write Org or Store."
  (unless supertag-semantic-enabled (setq supertag-semantic--last-enabled nil))
  (when (and supertag-semantic-enabled
             (equal supertag-semantic--context (supertag-semantic--current-context))
             (eq (car-safe path) :nodes) (stringp (cadr path)))
    (supertag-semantic--queue (cadr path))
    (supertag-semantic--schedule)))

(defun supertag-semantic--observe-context ()
  "Observe identity and subscriptions without scanning, queuing or scheduling."
  (if (not supertag-semantic-enabled)
      (setq supertag-semantic--last-enabled nil)
    (let ((context (supertag-semantic--current-context)))
      (unless (equal supertag-semantic--context context)
        (let ((paused supertag-semantic--paused))
          (supertag-semantic-stop)
          (setq supertag-semantic--context context
                supertag-semantic--vectors (make-hash-table :test 'equal)
                supertag-semantic--dirty (make-hash-table :test 'equal)
                supertag-semantic--dim nil supertag-semantic--needs-save nil
                supertag-semantic--last-save (float-time)
                supertag-semantic--last-enabled nil
                supertag-semantic--paused paused))
        (supertag-semantic--load)))
    (unless (eq supertag-semantic--subscription-table supertag--subscribers)
      (supertag-subscribe :store-changed #'supertag-semantic--changed)
      (setq supertag-semantic--subscription-table supertag--subscribers))))

(defun supertag-semantic--ensure ()
  "Observe the context and reconcile pending changes only when unblocked."
  (supertag-semantic--observe-context)
  (when (and supertag-semantic-enabled
             (not supertag-semantic--paused) (not supertag-semantic--error)
             (not supertag-semantic--last-enabled))
    (supertag-semantic--scan)
    (setq supertag-semantic--last-enabled t)))

(defun supertag-semantic--request (texts callback)
  "Asynchronously embed TEXTS; call CALLBACK with (VECTORS ERROR-MESSAGE).
Return the curl process.  Request data and process buffers are always temporary."
  (let ((input (make-temp-file "supertag-semantic-request-"))
        (output (generate-new-buffer " *supertag-semantic-response*"))
        (errors (generate-new-buffer " *supertag-semantic-errors*"))
        (timeout (number-to-string supertag-semantic-request-timeout)))
    (condition-case err
        (progn
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file input
              (insert (json-serialize (list :model supertag-semantic-model :input (vconcat texts))))))
          (make-process
           :name "supertag-semantic" :buffer output :stderr errors :noquery t
           :connection-type 'pipe :coding 'utf-8-unix
           :command (list supertag-semantic-curl-program "--silent" "--show-error" "--fail"
                          "--noproxy" "*" "--max-time" timeout "-H" "Content-Type: application/json"
                          "--data-binary" (concat "@" input)
                          (concat (string-remove-suffix "/" supertag-semantic-endpoint) "/api/embed"))
           :sentinel
           (lambda (process _event)
             (when (memq (process-status process) '(exit signal))
               (unwind-protect
                   (let (vectors failure)
                     (condition-case parse-error
                         (cond
                          ((zerop (process-exit-status process))
                             (setq vectors (with-current-buffer output
                                             (alist-get 'embeddings
                                                        (json-parse-string (buffer-string)
                                                                           :object-type 'alist)))))
                          ((= (process-exit-status process) 28)
                           (setq failure (format "Request timed out after %s s" timeout)))
                          (t (setq failure (with-current-buffer errors (string-trim (buffer-string))))))
                       (error (setq failure (error-message-string parse-error))))
                     (funcall callback vectors (and failure (if (string-empty-p failure) "Embedding request failed" failure))))
                 (when (file-exists-p input) (delete-file input))
                 (kill-buffer output) (kill-buffer errors))))))
      (error
       (delete-file input) (kill-buffer output) (kill-buffer errors)
       (signal (car err) (cdr err))))))

(defun supertag-semantic--probe ()
  "Synchronously verify that the configured embedding endpoint accepts MODEL.

The probe has no side effects on the semantic index and is deliberately capped
at ten seconds, even when normal embedding requests are allowed more time."
  (let ((input (make-temp-file "supertag-semantic-probe-"))
        (output (generate-new-buffer " *supertag-semantic-probe*"))
        (timeout (number-to-string (min 10 supertag-semantic-request-timeout)))
        status)
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file input
              (insert (json-serialize
                       (list :model supertag-semantic-model :input ["supertag probe"])))))
          (setq status
                (call-process
                 supertag-semantic-curl-program input output nil
                 "--silent" "--show-error" "--fail" "--noproxy" "*"
                 "--max-time" timeout "-H" "Content-Type: application/json"
                 "--data-binary" (concat "@" input)
                 (concat (string-remove-suffix "/" supertag-semantic-endpoint) "/api/embed")))
          (unless (and (integerp status) (zerop status))
            (error "curl exited with status %s" status))
          (let ((embeddings
                 (alist-get 'embeddings
                            (with-current-buffer output
                              (json-parse-string (buffer-string) :object-type 'alist)))))
            (unless (and (sequencep embeddings) (= (length embeddings) 1)
                         (sequencep (elt embeddings 0)) (> (length (elt embeddings 0)) 0))
              (error "Invalid embedding probe response"))
            t))
      (when (file-exists-p input) (delete-file input))
      (kill-buffer output))))

(defun supertag-semantic--refresh (&optional node-id)
  "Refresh the matching view while preserving reading positions and window starts."
  (when (and (fboundp 'supertag-view-node--buffer)
             (fboundp 'supertag-view-node--refresh-view))
    (when-let* ((buffer (supertag-view-node--buffer)))
      (with-current-buffer buffer
        (when (and (bound-and-true-p supertag-view-node--current-node-id)
                   (or (null node-id) (equal node-id supertag-view-node--current-node-id)))
          (let ((position (point))
                (windows (mapcar (lambda (window)
                                   (list window (window-start window) (window-point window)))
                                 (get-buffer-window-list buffer nil t))))
            (unwind-protect
                (save-excursion (ignore-errors (supertag-view-node--refresh-view)))
              ;; Erasing a rendered buffer collapses markers; restore numeric positions.
              (goto-char (min position (point-max)))
              (dolist (state windows)
                (when (and (window-live-p (car state))
                           (eq (window-buffer (car state)) buffer))
                  (set-window-point (car state) (min (nth 2 state) (point-max)))
                  (set-window-start (car state) (min (nth 1 state) (point-max)) t))))))))))

(defun supertag-semantic--advance-rebuild (count)
  "Advance the active rebuild progress session by COUNT embedded notes."
  (when supertag-semantic--rebuild
    (let* ((session supertag-semantic--rebuild)
           (done (+ (plist-get session :done) count)))
      (setq supertag-semantic--rebuild (plist-put session :done done))
      (progress-reporter-update (plist-get supertag-semantic--rebuild :reporter) done))))

(defun supertag-semantic--finish-rebuild ()
  "Complete and announce the active rebuild progress session."
  (when supertag-semantic--rebuild
    (let* ((session supertag-semantic--rebuild)
           (done (plist-get session :done))
           (elapsed (- (float-time) (plist-get session :started))))
      (setq supertag-semantic--rebuild nil)
      (progress-reporter-done (plist-get session :reporter))
      (message "Similar notes ready: %d notes embedded with %s in %.1fs"
               done supertag-semantic-model elapsed))))

(defun supertag-semantic--pause-rebuild (failure)
  "Clear and report the active rebuild progress session after FAILURE."
  (when supertag-semantic--rebuild
    (let ((reporter (plist-get supertag-semantic--rebuild :reporter)))
      (setq supertag-semantic--rebuild nil)
      (progress-reporter-done reporter)
      (message "Embedding paused: %s — M-x supertag-semantic-rebuild to retry" failure))))

(defun supertag-semantic--receive (token context batch vectors failure &optional view-id)
  "Commit a valid BATCH response only for the current TOKEN and CONTEXT."
  (when (eq token supertag-semantic--active)
    ;; Even an ignored response must release its own slot when opt-in changed.
    (setq supertag-semantic--active nil supertag-semantic--process nil)
    (when (and supertag-semantic-enabled
               (equal context (supertag-semantic--current-context)))
      (let (committed)
        (condition-case err
            (progn
              (when failure (error "%s" failure))
              (unless (and (sequencep vectors) (= (length vectors) (length batch)))
                (error "Embedding count mismatch"))
              (let* ((quantized (mapcar #'supertag-semantic--quantize (append vectors nil)))
                     (dim (length (car quantized))))
                (unless (cl-every (lambda (v) (= (length v) dim)) quantized)
                  (error "Embedding dimensions differ within batch"))
                (when (and supertag-semantic--dim (/= dim supertag-semantic--dim))
                  (clrhash supertag-semantic--vectors)
                  (supertag-semantic--scan))
                (setq supertag-semantic--dim dim)
                (cl-mapc
                 (lambda (item vector)
                   (let ((node (supertag-semantic--node (car item))))
                     (when (and node (equal (nth 1 item) (supertag-semantic--hash node)))
                       (puthash (car item) (cons (nth 1 item) vector) supertag-semantic--vectors)
                       (remhash (car item) supertag-semantic--dirty))))
                 batch quantized)
                (setq supertag-semantic--needs-save t)
                (when (or (zerop (hash-table-count supertag-semantic--dirty))
                          (>= (- (float-time) supertag-semantic--last-save)
                              supertag-semantic-save-interval))
                  (supertag-semantic--save))
                (setq committed t)))
          (error (setq supertag-semantic--error (error-message-string err)
                       supertag-semantic--paused t)))
        (when committed
          (supertag-semantic--advance-rebuild (length batch)))
        (cond
         ;; A failed round must display its explicit Retry action immediately.
         (supertag-semantic--error
          (supertag-semantic--pause-rebuild supertag-semantic--error)
          (supertag-semantic--refresh view-id))
         ((zerop (hash-table-count supertag-semantic--dirty))
          (supertag-semantic--finish-rebuild)
          (supertag-semantic--refresh))
         (t (dolist (item batch) (supertag-semantic--refresh (car item)))))
        (supertag-semantic--schedule)))))

(defun supertag-semantic--pump ()
  "Drain at most one character-budgeted batch from the dirty set."
  (setq supertag-semantic--timer nil)
  (when (and supertag-semantic-enabled (not supertag-semantic--paused)
             (not supertag-semantic--active)
             (equal supertag-semantic--context (supertag-semantic--current-context)))
    (let ((budget 0) batch)
      (dolist (id (sort (hash-table-keys supertag-semantic--dirty) #'string-lessp))
        (let ((node (supertag-semantic--node id)))
          (if (not node) (remhash id supertag-semantic--dirty)
            (let ((text (supertag-semantic--text node)))
              (when (or (null batch) (<= (+ budget (length text)) supertag-semantic-request-chars))
                (push (list id (secure-hash 'sha256 text) text) batch)
                (cl-incf budget (length text)))))))
      (if (null batch)
          (when supertag-semantic--needs-save
            (condition-case err (supertag-semantic--save)
              (error
               (setq supertag-semantic--error (error-message-string err)
                     supertag-semantic--paused t)
               (supertag-semantic--pause-rebuild supertag-semantic--error)
               (supertag-semantic--refresh))))
        (let ((token (gensym "semantic-")) (context supertag-semantic--context)
              (view-id (when (fboundp 'supertag-view-node--buffer)
                         (when-let* ((buffer (supertag-view-node--buffer)))
                           (buffer-local-value 'supertag-view-node--current-node-id buffer)))))
          (setq supertag-semantic--active token)
          (condition-case err
              (let ((process (supertag-semantic--request
                              (mapcar (lambda (item) (nth 2 item)) batch)
                              (lambda (vectors failure)
                                (supertag-semantic--receive token context batch vectors failure view-id)))))
                (when (eq token supertag-semantic--active)
                  (setq supertag-semantic--process process)))
            (error (supertag-semantic--receive token context batch nil (error-message-string err) view-id))))))))

(defun supertag-semantic--matches (node-id)
  "Rank current node-level candidates, excluding self and existing references."
  (let* ((node (supertag-semantic--node node-id))
         (source (gethash node-id supertag-semantic--vectors)) matches)
    (when (and node source (equal (car source) (supertag-semantic--hash node)))
      (maphash
       (lambda (id entry)
         (let ((other (supertag-semantic--node id)))
           (when (and other (not (equal id node-id))
                      (not (member id (plist-get node :ref-to)))
                      (not (member id (plist-get node :ref-from)))
                      (not (member node-id (plist-get other :ref-to)))
                      (equal (car entry) (supertag-semantic--hash other)))
             (let ((score (supertag-semantic--score (cdr source) (cdr entry))))
               (when (>= score supertag-semantic-min-similarity)
                 (push (list :id id :node other :score score) matches))))))
       supertag-semantic--vectors))
    (seq-take (sort matches (lambda (a b)
                              (if (= (plist-get a :score) (plist-get b :score))
                                  (string-lessp (plist-get a :id) (plist-get b :id))
                                (> (plist-get a :score) (plist-get b :score)))))
              supertag-semantic-max-results)))

;;;###autoload
(defun supertag-semantic-stop ()
  "Pause this round and discard late responses; leave the optional subscription."
  (interactive)
  (let ((session supertag-semantic--rebuild))
    (setq supertag-semantic--active nil supertag-semantic--paused t)
    (when (timerp supertag-semantic--timer) (cancel-timer supertag-semantic--timer))
    (setq supertag-semantic--timer nil)
    (when (process-live-p supertag-semantic--process) (delete-process supertag-semantic--process))
    (setq supertag-semantic--process nil)
    (when session
      (setq supertag-semantic--rebuild nil)
      (progress-reporter-done (plist-get session :reporter))
      (message "Embedding stopped at %d/%d — M-x supertag-semantic-resume to continue"
               (plist-get session :done) (plist-get session :total)))))

(defun supertag-semantic--start-rebuild ()
  "Start visible progress for the current dirty embedding set."
  (let* ((total (hash-table-count supertag-semantic--dirty))
         (reporter (make-progress-reporter
                    (format "Embedding %d notes with %s" total supertag-semantic-model)
                    0 total)))
    (setq supertag-semantic--rebuild
          (list :total total :done 0 :started (float-time) :reporter reporter))
    (message "Embedding %d notes with %s… (M-x supertag-semantic-stop to stop)"
             total supertag-semantic-model)
    (when (zerop total) (supertag-semantic--finish-rebuild))))

;;;###autoload
(defun supertag-semantic-rebuild ()
  "Rebuild all node embeddings asynchronously with visible progress."
  (interactive)
  (unless supertag-semantic-enabled
    (if (yes-or-no-p "Similar notes are off. Enable for this session and index the vault? ")
        (setq supertag-semantic-enabled t)
      (user-error "Enable Similar notes to index the vault")))
  (condition-case err
      (supertag-semantic--probe)
    (error
     (user-error "Embedding endpoint %s / model %s unavailable: %s"
                 supertag-semantic-endpoint supertag-semantic-model
                 (error-message-string err))))
  (supertag-semantic--ensure)
  (supertag-semantic-stop)
  (clrhash supertag-semantic--vectors) (clrhash supertag-semantic--dirty)
  (setq supertag-semantic--dim nil supertag-semantic--paused nil supertag-semantic--error nil)
  (supertag-semantic--scan)
  (setq supertag-semantic--last-enabled t)
  (supertag-semantic--start-rebuild)
  (supertag-semantic--schedule)
  (supertag-semantic--refresh))

;;;###autoload
(defun supertag-semantic-resume ()
  "Continue a stopped rebuild without clearing already embedded vectors."
  (interactive)
  (unless supertag-semantic-enabled
    (user-error "Enable Similar notes before continuing embeddings"))
  (supertag-semantic--observe-context)
  (setq supertag-semantic--paused nil supertag-semantic--error nil)
  (supertag-semantic--start-rebuild)
  (supertag-semantic--schedule)
  (supertag-semantic--refresh))

;;;###autoload
(defun supertag-semantic-status ()
  "Report disposable index state without starting requests."
  (interactive)
  (let ((status (list :enabled supertag-semantic-enabled :model supertag-semantic-model
                      :indexed (hash-table-count supertag-semantic--vectors)
                      :dirty (hash-table-count supertag-semantic--dirty)
                      :running (and supertag-semantic--active t)
                      :paused supertag-semantic--paused :error supertag-semantic--error)))
    (when (called-interactively-p 'interactive)
      (message "Similar notes: %s, model %s, %d indexed, %d pending, %s"
               (if supertag-semantic-enabled "enabled" "disabled")
               supertag-semantic-model (plist-get status :indexed) (plist-get status :dirty)
               (cond (supertag-semantic--active "running")
                     (supertag-semantic--error
                      (format "error: %s" supertag-semantic--error))
                     (supertag-semantic--paused "paused")
                     (t "idle"))))
    status))

(defun supertag-semantic--retry (node-id)
  "Explicitly resume the embedding round for NODE-ID."
  (when supertag-semantic-enabled
    (setq supertag-semantic--paused nil supertag-semantic--error nil)
    (supertag-semantic--ensure)
    (supertag-semantic--queue node-id)
    (supertag-semantic--schedule)
    (supertag-semantic--refresh node-id)))

(defun supertag-semantic--passage-regions (begin end)
  "Return paragraph regions in bounded own body BEGIN..END.
Exclude only structurally recognized closed Org drawers.  Parse an isolated
copy under a heading so fundamental-mode callers and live buffer caches or
narrowing cannot change the result.  Source/example block text remains body."
  (let* ((text (buffer-substring-no-properties begin end))
         (drawers
          (with-temp-buffer
            (insert "* Body\n")
            (let ((offset (- begin (point)))
                  (org-inhibit-startup t)
                  (org-element-use-cache nil))
              (insert text)
              (delay-mode-hooks (org-mode))
              (org-element-map (org-element-parse-buffer)
                  '(drawer property-drawer)
                (lambda (element)
                  (cons (+ offset (org-element-property :begin element))
                        (min end (+ offset (org-element-property :end element))))))))))
    (save-excursion
      (goto-char begin)
      (let (start regions)
        (while (< (point) end)
          (let ((bol (point)))
            (cond
             ((and drawers (= bol (caar drawers)))
              (when start
                (push (cons start (1- bol)) regions)
                (setq start nil))
              (goto-char (cdar drawers))
              (setq drawers (cdr drawers)))
             ((string-blank-p
               (buffer-substring-no-properties bol (min end (line-end-position))))
              (when start
                (push (cons start (1- bol)) regions)
                (setq start nil))
              (forward-line 1))
             (t
              (unless start (setq start bol))
              (forward-line 1)))))
        (when start
          (push (cons start (if (and (> end start) (eq (char-before end) ?\n))
                               (1- end) end)) regions))
        (nreverse regions)))))

(defun supertag-semantic--passages (content)
  "Split own-body CONTENT into nonempty paragraphs, excluding drawer metadata."
  (with-temp-buffer
    (insert (or content ""))
    (mapcar (lambda (region)
              (buffer-substring-no-properties (car region) (cdr region)))
            (supertag-semantic--passage-regions (point-min) (point-max)))))

(defun supertag-semantic--words (text)
  "Return lowercase English words and adjacent CJK bigrams in TEXT as a set."
  (let ((tokens (make-hash-table :test 'equal)) (pos 0))
    (while (string-match "[A-Za-z]+\\|[一-鿿㐀-䶿]+" text pos)
      (let ((word (match-string 0 text)))
        (setq pos (match-end 0))
        (if (string-match-p "\\`[A-Za-z]" word)
            (puthash (downcase word) t tokens)
          (dotimes (i (1- (length word)))
            (puthash (substring word i (+ i 2)) t tokens)))))
    tokens))

(defun supertag-semantic--closest-passage (query-text passages)
  "Return (PASSAGE . SCORE) with greatest lexical Jaccard overlap with QUERY-TEXT.
Ties, including no overlap, retain the first passage.  Empty PASSAGES yields nil
as the passage.  Tokens never span paragraph or whitespace boundaries."
  (let ((query (supertag-semantic--words query-text))
        (best (car passages)) (score 0.0))
    (dolist (passage passages)
      (let ((words (supertag-semantic--words passage)) (intersection 0))
        (maphash (lambda (word _) (when (gethash word query) (cl-incf intersection))) words)
        (let* ((union (- (+ (hash-table-count words) (hash-table-count query)) intersection))
               (overlap (if (zerop union) 0.0 (/ (float intersection) union))))
          (when (> overlap score) (setq best passage score overlap)))))
    (cons best score)))

(defun supertag-semantic--visit-passage (node-id passage)
  "Visit NODE-ID, then locate displayed PASSAGE within its own live body.
Nil or missing passages leave point at the target heading.  Drawer text and
child or sibling nodes are never searched."
  (supertag-goto-node node-id)
  (when (and passage (derived-mode-p 'org-mode) (org-at-heading-p)
             (equal node-id (org-entry-get nil "ID")))
    (let* ((heading (point))
           (first-line (string-trim (car (split-string passage "\n"))))
           (needle (substring first-line 0 (min 80 (length first-line))))
           (begin (save-excursion (forward-line 1) (point)))
           (end (save-excursion
                  (forward-line 1)
                  (if (re-search-forward org-heading-regexp nil t)
                      (line-beginning-position) (point-max))))
           found)
      (unless (string-empty-p needle)
        (dolist (region (supertag-semantic--passage-regions begin end))
          (unless found
            (goto-char (car region))
            (when (search-forward needle (cdr region) t)
              (setq found (line-beginning-position))))))
      (goto-char (or found heading))
      (when found (org-fold-show-context)))))

(defun supertag-semantic--insert-status-section (label node-id message action-label action help)
  "Insert a live similarity status section for NODE-ID."
  (insert "\n")
  (supertag-view-helper-insert-section-chip label 0 'supertag-view-chip3)
  (insert (propertize (concat "  " message) 'face 'supertag-view-mute))
  (when action-label
    (insert "  ")
    (supertag-view-helper-insert-action-button action-label action node-id help
                                                'supertag-semantic))
  (insert "\n"))

(defun supertag-semantic--insert-match (match query)
  "Insert one magazine-style semantic MATCH for QUERY."
  (let* ((id (plist-get match :id))
         (node (plist-get match :node))
         (title (or (plist-get node :title) id))
         (closest (supertag-semantic--closest-passage
                   query (supertag-semantic--passages (plist-get node :content))))
         (passage (car closest))
         (hit (> (cdr closest) 0))
         (score (format "%.2f" (plist-get match :score)))
         (start (point)))
    (insert "  ")
    (insert-text-button title 'face 'supertag-view-entry 'follow-link t
                        'action (lambda (_button)
                                  (supertag-semantic--visit-passage id (and hit passage)))
                        'supertag-node-id id
                        'help-echo "Visit the original Org node")
    (insert (propertize " " 'display `(space :align-to (- right ,(1+ (string-width score))))))
    (insert (propertize score 'face 'supertag-view-score) "\n")
    (supertag-view-helper-insert-excerpt passage)
    (add-text-properties start (point) '(line-spacing 0.15))))

(defun supertag-semantic-insert-section (node-id)
  "Insert live or nonempty semantic candidates for NODE-ID."
  (supertag-semantic--ensure)
  (when supertag-semantic-enabled
    (unless (or supertag-semantic--paused supertag-semantic--error)
      (supertag-semantic--queue node-id)
      (supertag-semantic--schedule))
    (cond
     (supertag-semantic--error
      (supertag-semantic--insert-status-section
       "Similar" node-id (format "Unavailable: %s" supertag-semantic--error)
       "[Retry]"
       (lambda (button)
         (supertag-semantic--retry (button-get button 'supertag-semantic)))
       "Retry this embedding round"))
     (supertag-semantic--paused
      (supertag-semantic--insert-status-section
       "Similar" node-id "Paused." "[Retry]"
       (lambda (button)
         (supertag-semantic--retry (button-get button 'supertag-semantic)))
       "Retry this embedding round"))
     ((gethash node-id supertag-semantic--dirty)
      (supertag-semantic--insert-status-section
       "Similar" node-id "Computing…" "[Stop]"
       (lambda (button)
         (let ((id (button-get button 'supertag-semantic)))
           (supertag-semantic-stop)
           (supertag-semantic--refresh id)))
       "Stop this embedding round"))
     (t
      (let* ((source (supertag-semantic--node node-id))
             (content (or (plist-get source :content) ""))
             (query (concat (or (plist-get source :title) "") "\n\n"
                            (substring content 0 (min (length content) supertag-semantic-max-chars))))
             (matches (supertag-semantic--matches node-id)))
        (when matches
          (insert "\n")
          (supertag-view-helper-insert-section-chip "Similar" (length matches)
                                                       'supertag-view-chip3)
          (dolist (match matches)
            (supertag-semantic--insert-match match query))))))))

(provide 'supertag-semantic)
;;; supertag-semantic.el ends here
