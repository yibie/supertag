;;; supertag-ui-action.el --- Interactive Policy-aware Action workflow -*- lexical-binding: t; -*-

;; This file is part of org-supertag.

;;; Commentary:
;; Thin trusted interactive boundary for deployed Ontology Actions.  It reads
;; typed arguments, builds a transient proposal, obtains a one-use confirmation
;; capability when Policy requires it, and invokes the Store-owned contract.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'subr-x)
(require 'supertag-ontology-action)
(require 'supertag-ontology-contract)
(require 'supertag-ontology-policy)
(require 'supertag-service-node-identity)
(require 'supertag-services-sync)
(require 'supertag-services-ui)

(defconst supertag-ui-action--omit
  (make-symbol "supertag-ui-action-omit"))

(defun supertag-ui-action-current-node-id ()
  "Return the semantic node at point or in the current Node View."
  (cond
   ((derived-mode-p 'org-mode)
    (save-excursion
      (org-back-to-heading t)
      (let ((node-id (supertag-node-identity-ensure-at-point)))
        (supertag-node-sync-at-point)
        node-id)))
   ((and (boundp 'supertag-view-node--current-node-id)
         supertag-view-node--current-node-id)
    supertag-view-node--current-node-id)
   (t
    (user-error
     "Ontology Action requires an Org heading or Supertag Node View"))))

(defun supertag-ui-action--read-lisp (prompt initial)
  "Read one Lisp value with PROMPT and INITIAL text."
  (let* ((text (read-from-minibuffer prompt initial))
         (parsed (condition-case err
                     (read-from-string text)
                   (error
                    (user-error "Invalid value: %s"
                                (error-message-string err))))))
    (unless (string-match-p "\\`[[:space:]]*\\'"
                            (substring text (cdr parsed)))
      (user-error "Unexpected text after value"))
    (car parsed)))

(defun supertag-ui-action--read-primitive (parameter type)
  "Read PARAMETER with primitive contract TYPE."
  (let* ((name (plist-get parameter :name))
         (description (plist-get parameter :description))
         (required (plist-get parameter :required))
         (has-default (plist-get parameter :has-default))
         (default (plist-get parameter :default))
         (label (format "%s%s%s: "
                        name
                        (if has-default (format " [default %S]" default) "")
                        (if description (format " — %s" description) "")))
         (text (read-string label)))
    (cond
     ((and (string-empty-p text) has-default) supertag-ui-action--omit)
     ((and (string-empty-p text) (not required)) supertag-ui-action--omit)
     ((eq type :string) text)
     ((eq type :number)
      (let ((value (string-to-number text)))
        (unless (string-match-p
                 "\\`[+-]?\\(?:[0-9]+\\(?:\\.[0-9]*\\)?\\|\\.[0-9]+\\)\\(?:[eE][+-]?[0-9]+\\)?\\'"
                 text)
          (user-error "%s must be a number" name))
        value))
     ((eq type :integer)
      (unless (string-match-p "\\`[+-]?[0-9]+\\'" text)
        (user-error "%s must be an integer" name))
      (string-to-number text))
     ((memq type '(:date :timestamp :url :email :tag)) text)
     (t (supertag-ui-action--read-lisp label text)))))

(defun supertag-ui-action--read-type-node (parameter type)
  "Read a node for PARAMETER whose contract TYPE is `(:type KEY)'."
  (let* ((required (plist-get parameter :required))
         (has-default (plist-get parameter :has-default))
         (label (format "%s (%s): "
                        (plist-get parameter :name) (cadr type))))
    (if (and (or has-default (not required))
             (yes-or-no-p (format "Omit %s? " (plist-get parameter :name))))
        supertag-ui-action--omit
      (or (supertag-ui-select-node label t nil)
          (if required
              (user-error "%s is required" (plist-get parameter :name))
            supertag-ui-action--omit)))))

(defun supertag-ui-action--read-parameter (parameter)
  "Read one normalized Action PARAMETER."
  (let ((type (plist-get parameter :type))
        (required (plist-get parameter :required))
        (has-default (plist-get parameter :has-default))
        (name (plist-get parameter :name)))
    (pcase type
      (:boolean
       (let* ((omit (if has-default "use default" "omit"))
              (choice
               (completing-read
                (format "%s: " name)
                (append (when (or has-default (not required)) (list omit))
                        '("true" "false"))
                nil t nil nil
                (if (or has-default (not required)) omit "false"))))
         (pcase choice
           ("true" t)
           ("false" nil)
           (_ supertag-ui-action--omit))))
      (:node-reference
       (if (and (or has-default (not required))
                (yes-or-no-p (format "Omit %s? " name)))
           supertag-ui-action--omit
         (or (supertag-ui-select-node (format "%s: " name) t nil)
             (if required
                 (user-error "%s is required" name)
               supertag-ui-action--omit))))
      (:options
       (let* ((omit (if has-default "[Use default]" "[Omit]"))
              (choices
               (append (when (or has-default (not required)) (list omit))
                       (copy-sequence (plist-get parameter :options))))
              (choice (completing-read (format "%s: " name) choices nil t)))
         (if (equal choice omit) supertag-ui-action--omit choice)))
      (`(:type ,_key)
       (supertag-ui-action--read-type-node parameter type))
      (`(:maybe ,inner)
       (if (yes-or-no-p (format "Use nil for %s? " name))
           nil
         (supertag-ui-action--read-parameter
          (plist-put (copy-tree parameter) :type inner))))
      (`(:list ,_inner)
       (if (and (or has-default (not required))
                (yes-or-no-p (format "Omit %s? " name)))
           supertag-ui-action--omit
         (supertag-ui-action--read-lisp (format "%s list: " name) "()")))
      (_ (supertag-ui-action--read-primitive parameter type)))))

(defun supertag-ui-action-read-arguments (definition)
  "Read ordered Action arguments for DEFINITION as an alist."
  (let (arguments)
    (dolist (parameter (plist-get definition :parameters))
      (let ((value (supertag-ui-action--read-parameter parameter)))
        (unless (eq value supertag-ui-action--omit)
          (push (cons (plist-get parameter :name) value) arguments))))
    (nreverse arguments)))

(defun supertag-ui-action--decision-label (decision)
  "Return display label for Policy DECISION."
  (pcase decision
    (:allow "allow")
    (:confirm "confirm")
    (:propose-only "propose only")
    (:deny "deny")
    (_ (format "%s" decision))))

(defun supertag-ui-action--effect-line (effect)
  "Return one compact proposal line for audited EFFECT.
Field effects show the planned value, and the current value when one
exists, e.g. `set-field status = \"active\" -> \"done\"'."
  (pcase (plist-get effect :kind)
    (:set-field
     ;; Audited effects (see `supertag-ontology-action--audit-effect') omit
     ;; values on purpose; only show them when the effect carries them.
     (cond
      ((not (plist-member effect :new))
       (format "set-field %s" (plist-get effect :field-id)))
      ((plist-get effect :old-exists)
       (format "set-field %s = %S -> %S"
               (plist-get effect :field-id)
               (plist-get effect :old)
               (plist-get effect :new)))
      (t (format "set-field %s = %S"
                 (plist-get effect :field-id)
                 (plist-get effect :new)))))
    (:clear-field
     (format "clear-field %s%s"
             (plist-get effect :field-id)
             (if (plist-get effect :old-exists)
                 (format " (was %S)" (plist-get effect :old))
               "")))
    ((or :add-link :remove-link)
     (format "%s %s (%s -> %s)"
             (substring (symbol-name (plist-get effect :kind)) 1)
             (plist-get effect :definition-id)
             (plist-get effect :direction)
             (plist-get effect :target-id)))
    (_ (format "%S" effect))))

(defun supertag-ui-action-display-proposal (proposal &optional plan)
  "Display a compact transient summary of PROPOSAL and return it.
When PLAN (from `supertag-ontology-action-preview') is given, its full
effects are shown so the interactive user sees planned values; PROPOSAL's
own effects are the redacted audit form and carry no values."
  (let* ((action (plist-get proposal :action))
         (policy (plist-get proposal :policy))
         (lines
          (mapcar #'supertag-ui-action--effect-line
                  (or (and plan (plist-get plan :effects))
                      (plist-get proposal :effects)))))
    (message "%s [%s]: %s"
             (plist-get action :label)
             (supertag-ui-action--decision-label
              (plist-get policy :decision))
             (if lines (string-join lines "; ") "no changes"))
    proposal))

(defun supertag-ui-action-run-definition (node-id definition)
  "Read arguments and run or propose DEFINITION for NODE-ID."
  (let* ((arguments (supertag-ui-action-read-arguments definition))
         (actor :interactive-user)
         (proposal
          (supertag-ontology-action-propose
           (plist-get definition :runtime-id) node-id arguments actor))
         (decision (plist-get (plist-get proposal :policy) :decision))
         (plan (ignore-errors
                 (supertag-ontology-action-preview
                  (plist-get definition :runtime-id) node-id arguments))))
    (supertag-ui-action-display-proposal proposal plan)
    (pcase decision
      (:propose-only
       (message "Policy permits proposal only; no Action was executed")
       proposal)
      (:allow
       (supertag-ontology-action-execute
        (plist-get definition :runtime-id) node-id arguments actor))
      (:confirm
       (let* ((plan
               (or plan
                   (supertag-ontology-action-preview
                    (plist-get definition :runtime-id) node-id arguments)))
              (token
               (supertag-ontology-policy-request-confirmation plan actor)))
         (supertag-ontology-action-execute
          (plist-get definition :runtime-id) node-id arguments actor token)))
      (:deny
       (signal 'supertag-ontology-policy-denied
               (list "Policy denied Action execution")))
      (_ (user-error "Unsupported Policy decision %S" decision)))))

(defun supertag-ui-action--read-definition (node-id)
  "Read one Action Definition applicable to NODE-ID."
  (let* ((definitions (supertag-ontology-action-applicable node-id))
         (candidates
          (mapcar
           (lambda (definition)
             (let* ((decision
                     (supertag-ontology-policy-evaluate
                      definition :interactive-user))
                    (label
                     (format "%s  [%s]"
                             (plist-get definition :label)
                             (supertag-ui-action--decision-label
                              (plist-get decision :decision)))))
               (cons label definition)))
           definitions)))
    (unless candidates
      (user-error "No Ontology Action applies to this node's Types"))
    (cdr (assoc (completing-read "Action: " candidates nil t)
                candidates))))

;;;###autoload
(defun supertag-action-run (&optional node-id action-id)
  "Run or propose ACTION-ID for NODE-ID using the interactive-user actor."
  (interactive)
  (let* ((node-id (or node-id (supertag-ui-action-current-node-id)))
         (definition
          (if action-id
              (supertag-ontology-action-resolve action-id)
            (supertag-ui-action--read-definition node-id))))
    (supertag-ui-action-run-definition node-id definition)))

(defalias 'supertag-ontology-action-run #'supertag-action-run)

(provide 'supertag-ui-action)
;;; supertag-ui-action.el ends here
