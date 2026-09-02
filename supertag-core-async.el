;;; supertag/core/async.el --- Asynchronous task queue for Supertag -*- lexical-binding: t; -*-

;;; Commentary:
;; This module implements an asynchronous job queue for Supertag.
;; It allows heavy operations (like file parsing and database sync) to be
;; performed in the background using idle timers, preventing UI freezes.
;;
;; Inspired by Vulpea's async architecture.

;;; Code:

(require 'cl-lib)

(defgroup supertag-async nil
  "Asynchronous processing settings for Supertag."
  :group 'supertag)

(defcustom supertag-async-idle-delay 0.5
  "Seconds of idle time to wait before processing the next job in the queue.
Lower values make sync faster but might interfere with typing.
Higher values ensure Emacs is truly idle."
  :type 'number
  :group 'supertag-async)

(defcustom supertag-async-batch-size 1
  "Number of files to process in a single idle cycle.
Keep this low (1-3) to maintain responsiveness."
  :type 'integer
  :group 'supertag-async)

;;; Variables

(defvar supertag-async--queue '()
  "List of items (usually file paths) waiting to be processed.
Ordered from oldest to newest.")

(defvar supertag-async--failed-items '()
  "Items whose most recent processing attempt failed.
They are kept outside the active queue to avoid a tight automatic retry
loop.  Use `supertag-async-retry-failed' after fixing the reported cause.")

(defvar supertag-async--timer nil
  "The active idle timer, or nil if not running.")

(defvar supertag-async--processor-fn nil
  "The function to call for each item in the queue.
Must accept a single argument (the item).")

;;; Core Functions

(defun supertag-async-init (processor-fn)
  "Initialize the async system with a PROCESSOR-FN.
PROCESSOR-FN is a function that takes one argument (the item to process)."
  (setq supertag-async--processor-fn processor-fn)
  (setq supertag-async--queue '())
  (setq supertag-async--failed-items '())
  (supertag-async--ensure-timer))

(defun supertag-async-enqueue (item)
  "Add ITEM to the processing queue.
If ITEM is already in the queue, it is moved to the end (re-prioritized).
Returns the new queue length."
  ;; Remove if exists (deduplicate)
  (setq supertag-async--queue (delete item supertag-async--queue))
  ;; A fresh enqueue supersedes an earlier failed attempt for this item.
  (setq supertag-async--failed-items
        (delete item supertag-async--failed-items))
  ;; Add to end
  (setq supertag-async--queue (append supertag-async--queue (list item)))
  ;; Ensure timer is running
  (supertag-async--ensure-timer)
  (length supertag-async--queue))

(defun supertag-async-clear ()
  "Clear all pending jobs."
  (setq supertag-async--queue '())
  (setq supertag-async--failed-items '()))

;;;###autoload
(defun supertag-async-retry-failed ()
  "Move all retained failed items back to the active queue.
The original item (normally an Org filename) is preserved so the user can
fix the cause and retry explicitly without waiting for another scan."
  (interactive)
  (let ((items (copy-sequence supertag-async--failed-items)))
    (setq supertag-async--failed-items nil)
    (dolist (item items)
      (supertag-async-enqueue item))
    (if items
        (message "Supertag sync: queued %d failed file(s) for retry; processing resumes when Emacs is idle."
                 (length items))
      (message "Supertag sync: no failed files are waiting to retry."))
    (length items)))

;;; Internal Timer Logic

(defun supertag-async--ensure-timer ()
  "Start the idle timer if it's not already running and there is work to do."
  (when (and supertag-async--queue
             (not supertag-async--timer))
    (setq supertag-async--timer
          (run-with-idle-timer
           supertag-async-idle-delay
           nil ;; Run once (we will re-schedule if more work remains)
           #'supertag-async--worker))))

(defun supertag-async--worker ()
  "Process the next batch of items from the queue."
  (setq supertag-async--timer nil) ;; Timer has fired, so it's gone

  (when (and supertag-async--queue supertag-async--processor-fn)
    (let ((count 0))
      ;; Process each item independently so one failure does not hide which
      ;; file failed or discard the rest of this batch.
      (while (and supertag-async--queue
                  (< count supertag-async-batch-size))
        ;; Pop before invoking user code.  The processor may enqueue work
        ;; synchronously; removing the old head afterward would then operate
        ;; on that newer queue and could discard an unrelated pending item.
        (let ((item (pop supertag-async--queue)))
          (condition-case err
              (funcall supertag-async--processor-fn item)
            (error
             (cl-pushnew item supertag-async--failed-items :test #'equal)
             (message
              (concat "Supertag sync failed for %s: %s. "
                      "Data safety: the Org source file was not modified, and its filename is retained for retry. "
                      "Next: fix the cause, then run M-x supertag-async-retry-failed.")
              item (error-message-string err))))
          (cl-incf count))))

    ;; If work remains, re-schedule
    (when supertag-async--queue
      (supertag-async--ensure-timer))))

(provide 'supertag-core-async)
