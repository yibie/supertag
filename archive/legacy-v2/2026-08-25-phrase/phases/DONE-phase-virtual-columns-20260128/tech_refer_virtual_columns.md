# 虚拟列技术参考

## Proposed Approach

### 架构分层

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 4: UI (View Layer)                                     │
│ - Schema View (v c / v e / v d)                             │
│ - Table View integration                                    │
│ - Viewer selector (v v)                                     │
├─────────────────────────────────────────────────────────────┤
│ Layer 3: Virtual Column API                                  │
│ - supertag-virtual-column-create/get/update/delete          │
│ - supertag-virtual-column-get-value (public API)            │
├─────────────────────────────────────────────────────────────┤
│ Layer 2: Compute Engine                                      │
│ - Lazy evaluation trigger                                   │
│ - Type-specific compute functions                           │
│ - Formula parser & evaluator                                │
├─────────────────────────────────────────────────────────────┤
│ Layer 1: Cache & Dependency                                  │
│ - Cache storage (hash-table per node)                       │
│ - Dependency tracking                                       │
│ - Invalidation on change events                             │
├─────────────────────────────────────────────────────────────┤
│ Layer 0: Data Source                                         │
│ - :field-values (global fields)                             │
│ - :nodes (properties)                                       │
│ - :relations (for Rollup)                                   │
└─────────────────────────────────────────────────────────────┘
```

## Interfaces & APIs

### Virtual Column Definition

```elisp
;; Rollup
'(:id "total-effort"
  :name "Total Effort"
  :type :rollup
  :params (:relation "children"          ; relation name
           :field "effort"               ; target field
           :function :sum))              ; :sum :count :avg :max :min

;; Formula
'(:id "progress-percent"
  :name "Progress %"
  :type :formula
  :params (:expression "(/ (* done 100) total)"
           :variables ((done . (:virtual "done-count"))
                       (total . (:virtual "total-count")))))
```

### Public API

```elisp
;; Get virtual column value
(supertag-virtual-column-get node-id column-id &optional default)

;; Force recalculate
(supertag-virtual-column-refresh node-id column-id)

;; Bulk refresh (after batch import)
(supertag-virtual-column-refresh-all &optional tag-id)
```

## Trade-offs

| Decision | Option A | Option B | Chosen | Reason |
|----------|----------|----------|--------|--------|
| Compute timing | Real-time | Lazy + Cache | B | Performance for large datasets |
| Storage | Org properties | External DB | B | Keep org files clean |
| Formula syntax | Excel-like | Lisp-like | Lisp | Emacs ecosystem fit |
| Viewer API | Config only | Code only | Both | Progressive complexity |

## Risks & Mitigations

1. **Formula parser complexity**
   - Risk: Full Lisp parser is overkill
   - Mitigation: Start with limited operators (+ - * /) and built-in functions

2. **Circular dependency**
   - Risk: Formula A -> B -> A causes infinite loop
   - Mitigation: Track computation stack, detect cycles, error out

3. **Cache memory usage**
   - Risk: Large number of nodes × virtual columns = memory bloat
   - Mitigation: LRU cache eviction, configurable cache size

4. **Event storm after bulk import**
   - Risk: 1000 nodes imported → 1000 cache invalidations
   - Mitigation: Batch mode (suppress events during import, manual refresh after)
