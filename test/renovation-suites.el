;;; renovation-suites.el --- Static P1 verification manifest -*- lexical-binding: t; -*-
;; Data only. run-tests.sh owns execution. Transition names state the retained
;; responsibility; they are not claims of migrated implementations.
(defconst supertag-renovation-default
  '("contract" "compat" "identity" "vault" "view-framework" "node-view-extra" "automation-actions" "extractor" "persistence-restore" "multi-instance" "mention-extra" "saved-projection" "property-automation"
    "move" "promote" "stream" "find-node" "add-link" "discovery"
    "query-links" "query-tag-completion" "legacy-query-compat" "migrate" "storage-format" "property-consumers" "tag-change" "named-link-query" "svg-tag" "tag-path" "tag-merge-plan" "tag-manager" "embark" "ai" "semantic" "git"))
(defconst supertag-renovation-suites
  '(("multi-instance" ("test/multi-instance-test.el" . t))
    ("migrate" ("test/migrate-test.el" . t) ("test/migrate-fields-test.el" . t))
    ("storage-format"
     ("test/canonical-serialization-test.el" . (not (member supertag-canon-test-perf-canonical-vs-plain-dump)))
     ("test/persistence-hardening-test.el" . (not (member
       supertag-hardening-test-auto-migrate-stamps-version-and-snapshots-once
       supertag-hardening-test-data-root-guard-explains-comparison-and-recovery
       supertag-hardening-test-missing-db-with-backups-blocks-save
       supertag-hardening-test-verify-detects-durable-collection-loss))))
    ("git" ("test/git-test.el" . "^supertag-git-"))
    ("semantic" ("test/semantic-test.el" . t))
    ("ai" ("test/ai-test.el" . t))
    ("embark" ("test/embark-test.el" . t))
    ("tag-merge-plan" ("test/tag-merge-plan-test.el" . t))
    ("tag-path" ("test/tag-path-hierarchy-test.el" . t))
    ("tag-manager" ("test/tag-manager-test.el" . t))
    ("svg-tag" ("test/svg-tag-test.el" . t))
    ("named-link-query" ("test/named-link-query-test.el" . "^supertag-named-link-query-"))
    ("tag-change" ("test/tag-rename-delete-test.el" . t)
     ("test/delete-everywhere-text-test.el" . "^supertag-delete-everywhere-text-")
     ("test/orphan-bulk-cleanup-test.el" . "^supertag-orphan-tags-")
     ("test/inline-tag-punctuation-test.el" . "^supertag-inline-tag-punctuation-")
     ("test/rename-merge-text-test.el" . "^supertag-rename-merge-text-"))
    ("property-consumers" ("test/property-consumers-test.el" . t))
    ("migrate-fields" ("test/migrate-fields-test.el" . t))
    ("vault" ("test/vault-test.el" . "^supertag-vault-"))
    ("view-framework" ("test/view-framework-test.el" . t)
     ("test/view-palette-test.el" . t))
    ("automation-actions" ("test/automation-create-node-test.el" . t) ("test/automation-move-action-test.el" . t) ("test/automation-property-write-test.el" . t) ("test/automation-tag-action-test.el" . t))
    ("extractor" ("test/extractor-test.el" . t) ("test/generated-reference-exclusion-test.el" . t))
    ("persistence-restore" ("test/supertag-persistence-test.el" . t) ("test/supertag-restore-test.el" . t))
    ("mention-extra" ("test/test-concept-mention.el" . t) ("test/test-denote-reference.el" . t))
    ("node-view-extra" ("test/text-link-node-view-test.el" . t) ("test/test-file-node-display.el" . t))
    ("contract"
     ("test/storage-save-boundary-test.el" . "^supertag-storage-")
     ("test/document-query-contract-test.el" . "^supertag-document-query-")
     ("test/node-view-test.el" . "^supertag-node-view-")
     ("test/sync-scope-symlink-test.el" . "^supertag-sync-scope-")
     ("test/node-feature-test.el" . "^supertag-node-feature-")
     ("test/menu-lazy-test.el" . "^supertag-menu-"))
    ("compat" ("test/document-query-compat-test.el" . "^supertag-document-query-compat-"))
    ;; Identity and existing saved projection delivery; retained D/P/R.
    ("identity" ("test/node-identity-test.el" . (not (member node-location-navigates-file-node-identities-with-empty-cache node-location-ui-graph-and-board-use-store-with-empty-cache node-location-board-reports-missing-node))))
    ("saved-projection" ("test/saved-projection-automation-test.el" . t)
     ("test/sync-worker-regression-test.el" . t))
    ;; DSL and real Automation actions await P2.
    ("property-automation" ("test/org-property-query-automation-test.el" . t))
    ("move" ("test/move-node-safety-test.el" . t)
     ("test/move-nodes-position-test.el" . t) ("test/move-node-ui-test.el" . t))
    ("promote" ("test/promote-workflow-test.el" . t))
    ("stream" ("test/stream-workflow-test.el" . t) ("test/test-view-stream.el" . t))
    ("find-node" ("test/find-node-workflow-test.el" . t))
    ("add-link" ("test/add-link-workflow-test.el" . t)
     ("test/reference-capf-commit-test.el" . t))
    ("discovery" ("test/discovery-workflow-test.el" . t))
    ;; Relations P4, tags/completion P3, old field DSL G2: named transitions.
    ("query-links" ("test/query-model-test.el" .
                    "^supertag-query-model-queries-relations-without-raw-collection-access$"))
    ("query-tag-completion" ("test/query-model-test.el" .
                             "^supertag-query-model-\\(exposes-concrete-node-and-tag-reads\\|completion-consumes-concrete-reads\\)$"))
    ("legacy-query-compat" ("test/query-model-test.el" .
                           "^supertag-query-model-executes-node-query-with-compatibility-parity$"))
    ;; Explicit historical selection, never part of default.
    ("archive"
     ("test/node-identity-test.el" . (member node-location-navigates-file-node-identities-with-empty-cache node-location-ui-graph-and-board-use-store-with-empty-cache node-location-board-reports-missing-node))
     ("test/query-model-test.el" .
                "^supertag-query-model-\\(resolves-fields-and-values\\|builds-board-detail-for-the-serializer\\)$"))))
(provide 'renovation-suites)
