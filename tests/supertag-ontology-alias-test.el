;;; supertag-ontology-alias-test.el --- Ontology type alias tests -*- lexical-binding: t; -*-

;;; Commentary:
;; End-to-end coverage for the occurrence tokens an ontology Type answers to:
;; the type key (`#project' for `(type project :label "Project")') and the
;; optional declared `:aliases'.  These run against the real Tag ops layer so
;; `supertag-tag-resolve-occurrence' is the oracle.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ht)
(require 'supertag-core-store)
(require 'supertag-core-index)
(require 'supertag-ops-tag)
(require 'supertag-schema-authority)
(require 'supertag-ontology)

(defmacro supertag-ontology-alias-test--isolated (&rest body)
  "Run BODY with an empty Store, cleared indexes and an empty registry."
  (declare (indent 0) (debug t))
  `(let ((supertag--store (ht-create))
         (supertag-ontology-registry--raw (make-hash-table :test #'equal))
         (supertag-ontology-runtime-tags-provider nil)
         (supertag-ontology-runtime-fields-provider nil)
         (supertag-ontology-runtime-associations-provider nil)
         (supertag-ontology-runtime-links-provider nil))
     (supertag--ensure-store)
     (supertag-index-clear-all)
     ,@body))

(defun supertag-ontology-alias-test--register (body)
  "Register work ontology BODY and return its normalized model."
  (supertag-ontology-registry-register
   'work body '(:file "work.el" :line 1))
  (supertag-ontology-registry-get 'work))

(defun supertag-ontology-alias-test--deploy (body)
  "Register BODY, apply its plan and return the plan."
  (let ((plan (supertag-ontology-plan-build
               (supertag-ontology-alias-test--register body))))
    (supertag-ontology-deploy-apply-plan plan)
    plan))

(defun supertag-ontology-alias-test--project-id ()
  "Return the runtime Tag ID bound to work/type/project."
  (plist-get (supertag-ontology-runtime-binding-get 'work :type 'project)
             :runtime-id))

(defun supertag-ontology-alias-test--alias-change (plan)
  "Return the `:aliases' change of PLAN's single `:update-type' operation."
  (let ((operations (plist-get plan :operations)))
    (should (= 1 (length operations)))
    (should (eq :update-type (plist-get (car operations) :operation)))
    (should (eq :safe (plist-get (car operations) :class)))
    (cl-find :aliases (plist-get (car operations) :changes)
             :key (lambda (change) (plist-get change :slot)))))

(defun supertag-ontology-alias-test--issue-codes (body)
  "Return validator issue codes for work ontology BODY."
  (mapcar (lambda (issue) (plist-get issue :code))
          (supertag-ontology-validator-validate
           (supertag-ontology-model-normalize 'work body nil))))

(ert-deftest supertag-ontology-alias-redeploy-adds-key-alias-to-pre-existing-type ()
  "A type deployed before key aliasing gains `#project' on redeploy."
  (supertag-ontology-alias-test--isolated
    (let* ((tag-id (plist-get (supertag-tag-create '(:name "Project")) :id))
           (model (supertag-ontology-alias-test--register
                   '(:version 1 (type project :label "Project")))))
      (supertag-ontology-runtime-binding-put
       (list :owner :ontology :managed-by :ontology
             :module 'work :kind :type :key 'project
             :logical-id "work/type/project" :runtime-id tag-id))
      (supertag-ontology-runtime-module-put
       (list :module 'work :version 1
             :model-hash (supertag-ontology-model-hash model)
             :source-file "work.el"))
      (should (equal tag-id (supertag-tag-resolve-occurrence "Project")))
      (should-not (supertag-tag-resolve-occurrence "project"))
      (let* ((plan (supertag-ontology-plan-build model))
             (change (supertag-ontology-alias-test--alias-change plan)))
        (should (supertag-ontology-plan-safe-p plan))
        (should (equal '("project") (plist-get change :add)))
        (should-not (plist-get change :remove))
        (supertag-ontology-deploy-apply-plan plan))
      (should (equal tag-id (supertag-tag-resolve-occurrence "project")))
      (should (equal tag-id (supertag-tag-resolve-occurrence "Project")))
      (should (equal '("project")
                     (plist-get (supertag-tag-get tag-id) :ontology-aliases)))
      (should (supertag-ontology-plan-empty-p
               (supertag-ontology-plan-build model))))))

(ert-deftest supertag-ontology-alias-declared-aliases-reach-tag-and-resolve ()
  "Declared `:aliases' become Tag occurrence tokens; redeploy is empty."
  (supertag-ontology-alias-test--isolated
    (let ((plan (supertag-ontology-alias-test--deploy
                 '(:version 1
                   (type project :label "Project"
                         :aliases (proj "Projekt" "#proj"))))))
      (should (supertag-ontology-plan-safe-p plan))
      (let ((tag-id (supertag-ontology-alias-test--project-id)))
        (should tag-id)
        (dolist (token '("project" "proj" "Projekt" "Project"))
          (should (equal tag-id (supertag-tag-resolve-occurrence token))))
        (should (equal '("Projekt" "proj" "project")
                       (plist-get (supertag-tag-get tag-id) :ontology-aliases))))
      (should (supertag-ontology-plan-empty-p
               (supertag-ontology-plan-build
                (supertag-ontology-registry-get 'work)))))))

(ert-deftest supertag-ontology-alias-dropped-alias-is-released-user-alias-kept ()
  "Dropping a declared alias is SAFE and never removes user-added tokens."
  (supertag-ontology-alias-test--isolated
    (supertag-ontology-alias-test--deploy
     '(:version 1 (type project :label "Project" :aliases (proj))))
    (let ((tag-id (supertag-ontology-alias-test--project-id)))
      (supertag-schema-authority-with-actor :ontology-deployment
        (supertag-tag-update
         tag-id
         (lambda (tag)
           (plist-put tag :aliases
                      (append (plist-get tag :aliases) (list "my-proj"))))))
      (should (equal tag-id (supertag-tag-resolve-occurrence "my-proj")))
      (let* ((model (supertag-ontology-alias-test--register
                     '(:version 2 (type project :label "Project"))))
             (plan (supertag-ontology-plan-build model))
             (change (supertag-ontology-alias-test--alias-change plan)))
        (should (supertag-ontology-plan-safe-p plan))
        (should-not (plist-get change :add))
        (should (equal '("proj") (plist-get change :remove)))
        (supertag-ontology-deploy-apply-plan plan))
      (should-not (supertag-tag-resolve-occurrence "proj"))
      (should (equal tag-id (supertag-tag-resolve-occurrence "my-proj")))
      (should (equal tag-id (supertag-tag-resolve-occurrence "project")))
      (should (equal '("project")
                     (plist-get (supertag-tag-get tag-id) :ontology-aliases)))
      (should (supertag-ontology-plan-empty-p
               (supertag-ontology-plan-build
                (supertag-ontology-registry-get 'work)))))))

(ert-deftest supertag-ontology-alias-deploy-refuses-token-owned-by-other-tag ()
  "A declared alias already owned by an unrelated Tag is rejected at deploy."
  (supertag-ontology-alias-test--isolated
    (supertag-tag-create '(:name "Legacy" :aliases ("proj")))
    (let ((plan (supertag-ontology-plan-build
                 (supertag-ontology-alias-test--register
                  '(:version 1
                    (type project :label "Project" :aliases (proj)))))))
      (should (supertag-ontology-plan-safe-p plan))
      (should-error (supertag-ontology-deploy-apply-plan plan)
                    :type 'user-error))))

(ert-deftest supertag-ontology-alias-collision-across-types-is-validation-error ()
  "An alias may not collide with another type's key, label or alias."
  (should (memq :alias-collision
                (supertag-ontology-alias-test--issue-codes
                 '(:version 1
                   (type project :label "Project" :aliases (work))
                   (type item :label "Item" :aliases (work))))))
  (should (memq :alias-collision
                (supertag-ontology-alias-test--issue-codes
                 '(:version 1
                   (type project :label "Project" :aliases (item))
                   (type item :label "Item")))))
  (should (memq :alias-collision
                (supertag-ontology-alias-test--issue-codes
                 '(:version 1
                   (type project :label "Project")
                   (type other :label "project")))))
  (should-not (memq :alias-collision
                    (supertag-ontology-alias-test--issue-codes
                     '(:version 1
                       (type project :label "Project" :aliases (proj))
                       (type task :label "Task" :aliases (todo)))))))

(ert-deftest supertag-ontology-alias-malformed-aliases-are-validation-errors ()
  (should (memq :invalid-aliases
                (supertag-ontology-alias-test--issue-codes
                 '(:version 1 (type project :label "Project" :aliases "proj")))))
  (should (memq :invalid-alias
                (supertag-ontology-alias-test--issue-codes
                 '(:version 1 (type project :label "Project" :aliases (""))))))
  (should (memq :invalid-alias
                (supertag-ontology-alias-test--issue-codes
                 '(:version 1 (type project :label "Project" :aliases (42))))))
  (should-not (supertag-ontology-validator-errors-p
               (supertag-ontology-validator-validate
                (supertag-ontology-model-normalize
                 'work '(:version 1
                         (type project :label "Project" :aliases (proj "P 1")))
                 nil)))))

(ert-deftest supertag-ontology-alias-normalization-is-canonical-and-hashed ()
  "Aliases normalize to sorted unique tokens and take part in the hash."
  (let* ((normalize (lambda (body)
                      (supertag-ontology-model-normalize 'work body nil)))
         (a (funcall normalize '(:version 1 (type project :aliases (b "a" b)))))
         (b (funcall normalize '(:version 1 (type project :aliases ("#a" " b ")))))
         (plain (funcall normalize '(:version 1 (type project))))
         (type (car (plist-get a :types))))
    (should (equal '("a" "b") (plist-get type :aliases)))
    (should (equal '("a" "b" "project")
                   (supertag-ontology-model-type-aliases type)))
    (should (equal (supertag-ontology-model-hash a)
                   (supertag-ontology-model-hash b)))
    (should-not (equal (supertag-ontology-model-hash a)
                       (supertag-ontology-model-hash plain)))
    (should (equal '("project")
                   (supertag-ontology-model-type-aliases
                    (car (plist-get plain :types)))))))

(provide 'supertag-ontology-alias-test)
;;; supertag-ontology-alias-test.el ends here
