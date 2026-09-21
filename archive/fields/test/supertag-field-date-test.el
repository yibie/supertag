;;; supertag-field-date-test.el --- Date field normalization tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'org)
(require 'supertag-core-store)
(require 'supertag-ops-field)

(defmacro supertag-field-date-test--isolated (&rest body)
  "Run BODY with an empty Store and quiet transaction state."
  (declare (indent 0) (debug t))
  `(let ((supertag--store (make-hash-table :test #'equal))
         (supertag--transaction-active nil)
         (supertag--transaction-log nil)
         (supertag--subscribers (make-hash-table :test #'eq))
         (supertag-after-operation-hook nil)
         (supertag-ops-deferred-event-errors nil))
     (supertag--ensure-store)
     ,@body))

(defun supertag-field-date-test--install ()
  "Install date and timestamp fields on one node."
  (supertag-store-put-entity
   :tags "event"
   '(:id "event" :type :tag :name "Event" :extends nil))
  (supertag-store-put-entity
   :field-definitions "due"
   '(:id "due" :name "Due" :type :date :required nil))
  (supertag-store-put-entity
   :field-definitions "seen-at"
   '(:id "seen-at" :name "Seen At" :type :timestamp :required nil))
  (supertag-store-put-entity
   :tag-field-associations "event"
   '((:field-id "due" :order 0) (:field-id "seen-at" :order 1)))
  (supertag-store-put-entity
   :nodes "event-1"
   '(:id "event-1" :type :node :title "One" :tags ("event"))))

(ert-deftest supertag-field-date-stores-canonical-string ()
  "A calendar date is persisted in the existing YYYY-MM-DD string shape."
  (supertag-field-date-test--isolated
    (supertag-field-date-test--install)
    (should (equal "2026-01-15"
                   (supertag-field-set
                    "event-1" "event" "Due" "2026-01-15")))
    (should (equal "2026-01-15"
                   (supertag-store-get-field-value "event-1" "due")))))

(ert-deftest supertag-field-date-accepts-org-read-date-input ()
  "Relative date input from the package's own editor becomes canonical."
  (supertag-field-date-test--isolated
    (supertag-field-date-test--install)
    (let ((today (format-time-string "%Y-%m-%d"
                                     (org-read-date nil t "today")))
          (plus-three (format-time-string "%Y-%m-%d"
                                          (org-read-date nil t "+3d")))
          (tomorrow (format-time-string "%Y-%m-%d"
                                        (org-read-date nil t "+1d")))
          (plus-week (format-time-string "%Y-%m-%d"
                                         (org-read-date nil t "+1w"))))
      (supertag-field-set "event-1" "event" "Due" "today")
      (should (equal today
                     (supertag-store-get-field-value "event-1" "due")))
      (supertag-field-set "event-1" "event" "Due" "+3 days")
      (should (equal plus-three
                     (supertag-store-get-field-value "event-1" "due")))
      (supertag-field-set "event-1" "event" "Due" "+3d")
      (should (equal plus-three
                     (supertag-store-get-field-value "event-1" "due")))
      (supertag-field-set "event-1" "event" "Due" "tomorrow")
      (should (equal tomorrow
                     (supertag-store-get-field-value "event-1" "due")))
      (supertag-field-set "event-1" "event" "Due" "+1 week")
      (should (equal plus-week
                     (supertag-store-get-field-value "event-1" "due"))))))

(ert-deftest supertag-field-timestamp-keeps-existing-conversion-shape ()
  "The date repair must not turn timestamp values into date strings."
  (supertag-field-date-test--isolated
    (supertag-field-date-test--install)
    (let ((stored (supertag-field-set
                   "event-1" "event" "Seen At" "2026-01-15 12:30")))
      (should-not (stringp stored))
      (should (equal stored
                     (supertag-store-get-field-value "event-1" "seen-at"))))))

(provide 'supertag-field-date-test)

;;; supertag-field-date-test.el ends here
