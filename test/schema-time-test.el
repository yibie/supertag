;;; schema-time-test.el --- Time validation ownership tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Regression tests for the shared strict Emacs-time validator and the
;; explicitly optional timestamp fields on stored nodes.
;;
;; Run:
;;   emacs -Q --batch --eval '(package-initialize)' -L . \
;;     -l test/schema-time-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)

(when load-file-name
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

;; Preserve the application's historical load order in this regression test:
;; persistence first, then schema.
(require 'supertag-core-persistence)
(require 'supertag-core-schema)

(ert-deftest supertag-schema-time-test-nil-is-not-a-valid-time ()
  "The shared time-shape validator is strict about nil."
  (should-not (supertag--validate-time nil)))

(ert-deftest supertag-schema-time-test-time-equal-rejects-two-missing-times ()
  "Two absent timestamps are not valid equal Emacs times."
  (should-not (supertag-time-equal nil nil)))

(ert-deftest supertag-schema-time-test-node-allows-missing-created-at ()
  "Stored nodes may omit optional timestamp fields."
  (should (supertag--validate-node '(:id "n1" :type :node))))

(provide 'schema-time-test)

;;; schema-time-test.el ends here
