;;; supertag-unlinked-mention-test.el --- Unlinked mention tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'ht)
(require 'org)
(require 'supertag-core-store)
(require 'supertag-mention)

(defmacro supertag-mention-v8-test--isolated (&rest body)
  (declare (indent 0) (debug t))
  `(let ((supertag--store (ht-create))
         (supertag-mention-max-results 50))
     (supertag--ensure-store)
     ,@body))

(defvar supertag-mention-v8-test--materializations nil)

(defmacro supertag-mention-v8-test--with-materializer-spy (&rest body)
  "Run BODY with a recording stand-in for the reference materializer."
  (declare (indent 0) (debug t))
  `(let (supertag-mention-v8-test--materializations)
     (cl-letf (((symbol-function 'supertag-reference-materialize)
                (lambda (beg-marker end-marker target-id title)
                  (push (list target-id title)
                        supertag-mention-v8-test--materializations)
                  (goto-char beg-marker)
                  (delete-region beg-marker end-marker)
                  (insert (supertag-node-format-link target-id title))
                  target-id)))
       ,@body)))

(defun supertag-mention-v8-test--put-node
    (id title &optional content properties)
  (supertag-store-put-entity
   :nodes id
   (list :id id :type :node :title title :raw-value title
         :content (or content "") :file (format "/tmp/%s.org" id)
         :position 1 :level 1 :olp (list title)
         :properties properties)))

(ert-deftest supertag-mention-v8-cjk-does-not-use-ascii-word-boundaries ()
  (let ((matches
         (supertag-mention-service-scan-content
          "学习本体论的方法" '("本体论"))))
    (should (= 1 (length matches)))
    (should (equal "本体论" (plist-get (car matches) :term)))))

(ert-deftest supertag-mention-v8-ascii-identifiers-require-boundaries ()
  (let ((matches
         (supertag-mention-service-scan-content
          "ontology superontology ontology_2 ontology"
          '("ontology"))))
    (should (= 2 (length matches)))
    (should (= 0 (plist-get (car matches) :start)))))

(ert-deftest supertag-mention-v8-excludes-links-and-literal-regions ()
  (let* ((content
          (concat "Ontology plain\n"
                  "[[id:x][Ontology]]\n"
                  "=Ontology=\n"
                  "#+begin_src text\nOntology\n#+end_src\n"))
         (matches
          (supertag-mention-service-scan-content content '("Ontology"))))
    (should (= 1 (length matches)))
    (should (= 0 (plist-get (car matches) :start)))))


(ert-deftest supertag-mention-v8-short-terms-are-filtered-by-policy ()
  (let ((supertag-mention-min-term-length 2))
    (should-not
     (supertag-mention-service-scan-content "A appears" '("A")))))

(ert-deftest supertag-mention-v8-protected-range-cache-is-disposable ()
  (let ((supertag-mention-service--protected-range-cache
         (make-hash-table :test #'equal)))
    (supertag-mention-service-scan-content "=Ontology=" '("Ontology"))
    (should (= 1 (hash-table-count
                  supertag-mention-service--protected-range-cache)))
    (supertag-mention-service-clear-cache)
    (should (zerop (hash-table-count
                    supertag-mention-service--protected-range-cache)))))

(ert-deftest supertag-mention-protected-range-cache-is-content-addressed ()
  "Editing content must parse a new protected-range value, not reuse stale data."
  (let ((supertag-mention-service--protected-range-cache
         (make-hash-table :test #'equal)))
    (should-not
     (supertag-mention-service-scan-content "=Ontology=" '("Ontology")))
    (should (= 1 (length
                  (supertag-mention-service-scan-content
                   "Ontology" '("Ontology")))))
    (should (= 2 (hash-table-count
                  supertag-mention-service--protected-range-cache)))))

(ert-deftest supertag-mention-v8-longest-overlap-wins ()
  (let ((matches
         (supertag-mention-service-scan-content
          "Ontology as Code" '("Ontology" "Ontology as Code"))))
    (should (= 1 (length matches)))
    (should (equal "Ontology as Code" (plist-get (car matches) :term)))))

(ert-deftest supertag-mention-v8-longest-shifted-overlap-wins ()
  ;; The longer term starts inside the shorter match.  Non-ASCII terms carry
  ;; no identifier boundaries, so single-token CJK text exercises the pure
  ;; overlap rule; the ASCII case must also pass the word-boundary check.
  (let ((matches
         (supertag-mention-service-scan-content
          "甲乙丙丁戊" '("甲乙丙" "乙丙丁戊"))))
    (should (= 1 (length matches)))
    (should (equal "乙丙丁戊" (plist-get (car matches) :term)))
    (should (= 1 (plist-get (car matches) :start))))
  (let ((matches
         (supertag-mention-service-scan-content
          "alpha beta gamma delta" '("alpha beta" "beta gamma delta"))))
    (should (= 1 (length matches)))
    (should (equal "beta gamma delta" (plist-get (car matches) :term)))
    (should (= 6 (plist-get (car matches) :start)))))

(ert-deftest supertag-mention-v8-ignore-is-source-owned ()
  (supertag-mention-v8-test--isolated
    (supertag-mention-v8-test--put-node
     "source" "Source" "Ontology appears here."
     '(:SUPERTAG_IGNORE_MENTIONS "target other"))
    (supertag-mention-v8-test--put-node "target" "Ontology")
    (should-not (supertag-mention-service-find "target"))
    (should (member "target"
                    (supertag-mention-service-ignored-targets
                     (supertag-store-get-entity :nodes "source"))))))

(ert-deftest supertag-mention-v8-candidates-are-disposable-read-models ()
  (supertag-mention-v8-test--isolated
    (supertag-mention-v8-test--put-node
     "source" "Source" "Ontology appears twice: Ontology.")
    (supertag-mention-v8-test--put-node "target" "Ontology")
    (let ((before (hash-table-count
                   (supertag-store-get-collection :relations)))
          (mentions (supertag-mention-service-find "target")))
      (should (= 2 (length mentions)))
      (should (= before
                 (hash-table-count
                  (supertag-store-get-collection :relations))))
      (should-not (member :unlinked-mentions
                          (supertag-store-collection-names))))))

(ert-deftest supertag-mention-v8-context-preserves-exact-occurrence ()
  (supertag-mention-v8-test--isolated
    (supertag-mention-v8-test--put-node
     "source" "Source"
     "Ontology first. Later Ontology is the selected occurrence.")
    (supertag-mention-v8-test--put-node "target" "Ontology")
    (let* ((mentions (supertag-mention-service-find "target"))
           (second (nth 1 mentions)))
      (should (= 1 (plist-get second :ordinal)))
      (should (string-match-p "Later $" (plist-get second :before)))
      (should (equal "Ontology" (plist-get second :match))))))

(ert-deftest supertag-mention-v8-replacement-uses-canonical-id-link ()
  (supertag-mention-v8-test--with-materializer-spy
    (with-temp-buffer
      (org-mode)
      (insert "Ontology")
      (supertag-mention--link-at-match
       (cons (point-min) (point-max))
       '(:start 0 :end 8)
       "target" "Ontology")
      (should (equal "[[id:target][Ontology]]" (buffer-string))))
    (should (equal '(("target" "Ontology"))
                   supertag-mention-v8-test--materializations))))

(ert-deftest supertag-mention-v8-replacement-preserves-alias-wording ()
  (supertag-mention-v8-test--with-materializer-spy
    (with-temp-buffer
      (org-mode)
      (insert "本体代码")
      (supertag-mention--link-at-match
       (cons (point-min) (point-max))
       '(:start 0 :end 4 :term "本体代码")
       "target")
      (should (equal "[[id:target][本体代码]]" (buffer-string))))
    (should (equal '(("target" "本体代码"))
                   supertag-mention-v8-test--materializations))))


(ert-deftest supertag-mention-v8-replacement-preserves-source-case ()
  (supertag-mention-v8-test--with-materializer-spy
    (with-temp-buffer
      (org-mode)
      (insert "ONTOLOGY")
      (supertag-mention--link-at-match
       (cons (point-min) (point-max))
       '(:start 0 :end 8 :term "Ontology")
       "target")
      (should (equal "[[id:target][ONTOLOGY]]" (buffer-string))))
    (should (equal '(("target" "ONTOLOGY"))
                   supertag-mention-v8-test--materializations))))

(ert-deftest supertag-mention-v8-live-match-uses-stable-offsets ()
  (let* ((candidate '(:start 10 :end 18 :ordinal 0))
         (matches '((:term "New alias" :start 0 :end 9)
                    (:term "Ontology" :start 10 :end 18))))
    (should
     (equal 10
            (plist-get
             (supertag-mention--find-live-match candidate matches)
             :start)))))


(ert-deftest supertag-mention-v8-case-folded-terms-are-deduplicated ()
  (let ((matches
         (supertag-mention-service-scan-content
          "ONTOLOGY" '("Ontology" "ontology"))))
    (should (= 1 (length matches)))))

(ert-deftest supertag-mention-v8-orphaned-source-nodes-are-not-candidates ()
  (supertag-mention-v8-test--isolated
    (supertag-mention-v8-test--put-node
     "source" "Source" "Ontology appears here.")
    (supertag-mention-v8-test--put-node "target" "Ontology")
    (supertag-store-put-entity
     :nodes "source"
     (plist-put (copy-tree (supertag-store-get-entity :nodes "source"))
                :file nil))
    (should-not (supertag-mention-service-find "target"))))

(ert-deftest supertag-mention-find-cache-invalidates-after-node-change ()
  "Repeated reads are cached, but a source-node mutation changes the result."
  (supertag-mention-v8-test--isolated
    (let ((scan-count 0)
          (original-scan (symbol-function
                          'supertag-mention-service-scan-content)))
      (supertag-mention-v8-test--put-node
       "source" "Source" "Ontology appears here.")
      (supertag-mention-v8-test--put-node "target" "Ontology")
      (cl-letf (((symbol-function 'supertag-mention-service-scan-content)
                 (lambda (content terms)
                   (cl-incf scan-count)
                   (funcall original-scan content terms))))
        (should (= 1 (length (supertag-mention-service-find "target"))))
        (should (= 1 (length (supertag-mention-service-find "target"))))
        (should (= 1 scan-count))
        (supertag-mention-v8-test--put-node
         "source" "Source" "The term was removed.")
        (should-not (supertag-mention-service-find "target"))
        (supertag-mention-v8-test--put-node
         "source" "Source" "Ontology is back.")
        (should (= 1 (length (supertag-mention-service-find "target"))))
        (should (= 2 scan-count))))))

(provide 'supertag-unlinked-mention-test)
;;; supertag-unlinked-mention-test.el ends here
