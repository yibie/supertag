;;; node-view-capabilities-retirement-test.el --- Retired Node capabilities -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'node-view-properties-test)

(ert-deftest supertag-node-view-real-render-ignores-legacy-capabilities ()
  "A saved/projected node renders retained sections without capability reads."
  (supertag-node-view-properties-test--with-node
    (supertag-store-put-entity
     :ontology-functions "legacy-function"
     '(:runtime-id "legacy-function" :label "Legacy Function"))
    (supertag-store-put-entity
     :ontology-actions "legacy-action"
     '(:runtime-id "legacy-action" :label "Legacy Action"))
    (supertag-store-put-entity
     :ontology-policies "legacy-policy"
     '(:runtime-id "legacy-policy" :label "Legacy Policy"))
    (let ((state (supertag-view-build-node-state "node-view-property-id")))
      (with-temp-buffer
        (supertag-view-node-mode)
        (cl-letf (((symbol-function 'supertag-ontology-function-applicable)
                   (lambda (&rest _)
                     (ert-fail "Node View read legacy Functions")))
                  ((symbol-function 'supertag-ontology-action-applicable)
                   (lambda (&rest _)
                     (ert-fail "Node View read legacy Actions")))
                  ((symbol-function 'supertag-ontology-policy-evaluate)
                   (lambda (&rest _)
                     (ert-fail "Node View evaluated legacy Policy"))))
          (supertag-view-node--render-from-state state))
        (should (string-match-p "Property Node" (buffer-string)))
        (should (string-match-p "ALPHA" (buffer-string)))
        (should (string-match-p "References" (buffer-string)))
        (should (string-match-p "Unlinked Mentions" (buffer-string)))
        (should-not (string-match-p "Legacy Function" (buffer-string)))
        (should-not (string-match-p "Legacy Action" (buffer-string)))
        (should-not (lookup-key supertag-view-node-mode-map (kbd "A")))
        (should-not (string-match-p "\\[A\\] Run" (buffer-string)))
        (should-not (string-match-p
                     "Run or propose an Ontology Action"
                     (documentation 'supertag-view-node-mode)))))))

(provide 'node-view-capabilities-retirement-test)
;;; node-view-capabilities-retirement-test.el ends here
