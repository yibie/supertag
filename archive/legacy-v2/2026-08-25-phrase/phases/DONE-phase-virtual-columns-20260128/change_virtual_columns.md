# Virtual Columns Phase - Change Log

## 2026-01-28 - Viewer Architecture Planning

**Viewer 架构设计与规划**（当前阶段暂停，文档已完成）
- **已完成文档**:
  - `tech_refer_viewer_architecture.md` - 技术调研（4KB）
  - `spec_viewer_architecture.md` - 功能规格（9KB）
- **调研内容**:
  - 技术选项分析（函数式 vs DSL vs 模板继承）
  - 参考实现（Org blocks, Emacs Dashboard, Notion Views）
  - 与虚拟列系统的集成方案
  - 关键设计决策（渲染方式、数据查询、配置存储）
- **功能规格**:
  - 3 个用户场景（项目经理、个人用户、团队 lead）
  - 5 个功能需求（MVP + Phase 2 + Future）
  - 详细的 API 设计和验收标准
  - 3-Phase 开发计划
- **决策**:
  - Viewer 作为独立功能，在当前阶段暂停
  - 等待用户反馈验证需求后再继续
  - 优先完成核心虚拟列系统

## 2026-01-28 - Complete User Documentation (task021)

**task021**: Full user documentation
- **Files**:
  - Added: `doc/VIRTUAL_COLUMNS.md` (~11KB complete manual)
- **Content**:
  - Overview and core features
  - Four virtual column types (detailed with comparison tables)
  - Quick start guide (interactive + programmatic)
  - Complete API reference
  - UI usage guide (Schema/Table View)
  - Performance benchmarks
  - Best practices (naming, caching, optimization)
  - Troubleshooting guide with debugging tips
  - File location index
- **Structure**: 8 main sections, suitable for end users

## 2026-01-28 - Performance Benchmark (task020)

**task020**: Performance benchmark suite
- **Files**:
  - Added: `test/virtual-column-benchmark.el` (~250 lines)
  - Updated: `doc/VIRTUAL_COLUMNS_QUICKSTART.md` (test results)
- **Benchmarks**:
  - Rollup with 1000 nodes: cache miss (0.182 ms) vs cache hit (0.000 ms)
  - Scaling test: 100, 500, 1000, 2000 nodes - all < 3 ms
  - Formula complexity: various expressions, all < 0.01 ms
- **Results**:
  - Performance exceeds targets by 1000-10000x
  - Cache system has near-zero overhead
  - Linear scaling up to 2000+ nodes
- **Functions**:
  - `supertag-benchmark-rollup-1000`: Target < 5s (miss), < 1s (hit)
  - `supertag-benchmark-rollup-scaling`: Scale testing
  - `supertag-benchmark-formula-suite`: Formula perf
  - `supertag-benchmark-run-all`: Complete report
- **Features**:
  - Mock data generator (no database needed)
  - Time measurement macro
  - Automatic PASS/FAIL detection
  - Full report generation

## 2026-01-28 - UI Integration Complete

**task010-013**: UI Integration
- **Files**:
  - Modified: `supertag-view-schema.el` (+ virtual column keybindings)
  - Modified: `supertag-view-table.el` (+ virtual column display & refresh)
  - Modified: `supertag-virtual-column.el` (+ interactive commands)
- **Schema View (`v` prefix)**:
  - `v c`: Create virtual column (interactive)
  - `v e`: Edit virtual column
  - `v d`: Delete virtual column
  - `v l`: List virtual columns
- **Table View**:
  - Auto-displays all virtual columns as additional columns
  - Virtual column values computed via `supertag-virtual-column-get`
  - `g`: Normal refresh (uses cache)
  - `G`: Force refresh (clears virtual column cache first)
- **Interactive Commands**:
  - `supertag-virtual-column-create-interactive`: Prompts for type and params
  - `supertag-virtual-column-edit-interactive`: Edit name
  - `supertag-virtual-column-delete-interactive`: Delete with confirmation
  - `supertag-virtual-column-list-interactive`: Show all columns
  - Type-specific param readers for rollup/formula/aggregate/reference

## 2026-01-28 - Reference Type Implementation

**task009**: Reference virtual column type
- **Files**:
  - Modified: `supertag-virtual-column.el` (+20 lines)
  - Added: `test/reference-test.el` (3 tests)
  - Added: `test/demo-reference.el`
- **Changes**:
  - Added `supertag-virtual-column--compute-reference`: gets field value from related node
  - Uses `supertag-relation-find-by-from` to find related nodes
  - Supports `:index` parameter to select Nth relation target
- **Parameters**:
  - `:relation` - relation type to follow (e.g., "parent")
  - `:field` - field name to retrieve from target node
  - `:index` - optional, which relation to use (default: 0 = first)
- **Behavior**: Returns nil if no relation found or field doesn't exist
- **Use cases**: Parent deadline, owner name, category color inheritance
- **Risk**: Low - returns nil gracefully for missing data

## 2026-01-28 - Aggregate Type Implementation

**task008**: Aggregate virtual column type
- **Files**:
  - Modified: `supertag-virtual-column.el` (+30 lines)
  - Added: `test/aggregate-test.el` (3 tests)
  - Added: `test/demo-aggregate.el`
- **Changes**:
  - Added `supertag-virtual-column--compute-aggregate`: aggregates across all nodes with a tag
  - Uses `supertag-find-nodes-by-tag` for node discovery
  - Reuses same 7 aggregation functions as Rollup
- **Behavior**:
  - `:tag` - which tag to query (e.g., "project")
  - `:field` - which field to aggregate
  - `:function` - aggregation function (:sum, :count, :avg, :max, :min, :first, :last)
- **Difference from Rollup**:
  - Rollup: aggregates *related* nodes (via relation type)
  - Aggregate: aggregates *all* nodes with a specific tag
- **Risk**: Low - O(N) scan, returns 0 for empty results

## 2026-01-28 - Formula Parser Implementation

**task004**: Formula parser and evaluator
- **Files**: 
  - Modified: `supertag-virtual-column.el` (+150 lines)
  - Added: `test/formula-test.el` (14 tests)
  - Added: `test/demo-formula.el`
- **Changes**:
  - Added `supertag-formula-tokenize`: lexical analysis
  - Added `supertag-formula-parse`: recursive descent parser
  - Added `supertag-formula-eval`: AST evaluator with field resolution
  - Added `supertag-virtual-column--compute-formula`: integration hook
- **Behavior**: 
  - Supports infix expressions: `(done / total) * 100`
  - Operator precedence: * / before + -
  - Parentheses for grouping
  - Variable references resolve to node fields
  - Division by zero returns 0
- **Risk**: Low - isolated to formula type, nil on undefined fields

## 2026-01-28 - Initial Implementation

**task001-003, 019**: Core virtual column system
- **Files**:
  - Added: `supertag-virtual-column.el` (227 lines)
  - Added: `test/virtual-column-test.el` (12 tests)
  - Added: `test/demo-virtual-column.el`
  - Added: `doc/VIRTUAL_COLUMNS_QUICKSTART.md`
- **Changes**:
  - CRUD API for virtual column definitions
  - 2-level cache with dependency tracking
  - Lazy evaluation with cycle detection
  - Rollup type with all aggregation functions
- **Bug Fix**: Removed docstrings to avoid load-time evaluation issues
- **Status**: Core system working, demo verified
