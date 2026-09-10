;;; ob-supertag-query-block.el --- Org Babel loader for supertag-query-block -*- lexical-binding: t; -*-
;;; Commentary:
;; Commands: none. Org loads this file itself when `org-babel-load-languages'
;; lists `(supertag-query-block . t)'; it only announces the Babel language
;; and autoloads the executor that lives in supertag-query.el.
;; Dependencies: none at load time; supertag-query on first block execution.
;;
;; Org resolves a Babel language NAME by requiring the feature `ob-NAME'.
;; Keeping this loader separate from supertag-query.el means the require
;; succeeds no matter whether Org or Supertag loads first, and a preset
;; `org-babel-load-languages' entry can never break loading Supertag.
;;; Code:

(autoload 'org-babel-execute:supertag-query-block "supertag-query"
  "Execute a supertag-query-block source block." nil)

(provide 'ob-supertag-query-block)
;;; ob-supertag-query-block.el ends here
