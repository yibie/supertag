# tech-refer_sync_smart_detection_20251217: Sync Smart Detection 技术探索

## Options

### Option A: mtime-only（现状）

- 判断规则：`mtime` 变化 → 需要同步（parse + 导入）
- 优点：实现最简单，几乎无额外成本
- 缺点：伪变更会导致不必要 parse（大仓库下影响明显）

### Option B: mtime/size → content hash（推荐）

- 判断规则：
  1) 若 `mtime` 未变 → 跳过
  2) 若 `mtime` 变了：
     - 若 `size` 也变了 → 计算 hash 再确认（或直接认为需要同步，视策略）
     - 若 `size` 未变 → 计算 hash 再确认
  3) 若 hash 与上次一致 → 跳过；否则 → parse + 导入
- 优点：有效过滤伪变更，减少 parse
- 缺点：需要维护额外状态（size/hash），hash 计算有 IO 成本

### Option C: hash-first（不推荐）

- 每次都算 hash 再决定
- 对大仓库 IO 成本更高，且在多数场景比 mtime-only 更慢

## Proposed Approach（Option B）

### 状态数据（sync-state 扩展）

为每个文件维护：

- `mtime`（现有）
- `size`（新增）
- `content-hash`（新增，建议 `sha1` 或 `sha256`）

兼容策略：

- 保持旧格式可读（现有 state 是 `file -> mtime`）
- 新格式可用 plist 或结构体：`file -> (:mtime ... :size ... :hash ...)`

#### 现状与接入点（org-supertag）

当前 `supertag-services-sync.el` 的文件级状态是：

- `supertag-sync--state` / `supertag-sync--get-state-table`
  - 存储结构基本等价于：`file-absolute-path -> last-sync-mtime`
- 判断是否需要处理：
  - `supertag-sync-check-state`：比较 `last-sync` 与当前 `file mtime`
  - `supertag-get-modified-files`：遍历 state-table，收集 modified files
- 更新状态：
  - `supertag-sync-update-state`：写入当前文件 `mtime`

smart detection 的改动目标是：在“决定是否 parse/导入”之前，补齐并使用
`size/hash` 状态，而不是改变队列/事务/批处理结构。

#### 推荐的 state 结构（兼容旧格式）

为每个文件在 state-table 中存储如下结构之一：

- 旧格式（兼容读取）：
  - `mtime`（Emacs time object）
- 新格式（写入推荐）：
  - plist：`(:mtime <time> :size <int> :content-hash <string> :hash-algo <symbol>)`

兼容策略（建议“读旧写新、按需升级”）：

- 读取：
  - 若 entry 是 time object → 视为旧格式，仅有 `mtime`
  - 若 entry 是 plist → 读取 `:mtime/:size/:content-hash`
- 写入：
  - 当 smart detection 启用且本次确实读取了文件内容时，写入新格式（补齐 size/hash）
  - 其他情况可维持旧格式（或在下一次触发时懒升级）

这样可以避免一次性迁移所有 state 数据，并降低回滚成本。

### 读一次文件：hash + parse

理想实现：

- 在同一次 `with-temp-buffer` 里：
  - `insert-file-contents` 一次
  - 对 buffer 内容计算 hash（字节）
  - 决定是否继续 parse（`org-element-parse-buffer`）

这样避免“算 hash 再读文件 parse”的双读。

#### 关键点：避免“双读”的最低侵入实现

目前 `supertag--parse-org-nodes` 会在内部 `with-temp-buffer` 中
`insert-file-contents`，然后 `org-element-parse-buffer`。如果我们在外层
先读文件算 hash，再调用 `supertag--parse-org-nodes`，会导致读两遍文件。

推荐做法是新增一个“从当前 buffer parse”的入口（概念性描述）：

- `supertag--parse-org-nodes-from-buffer`（新）
  - 假设当前 buffer 已经包含文件内容
  - 复用现有逻辑：embed block stripping + `org-element-parse-buffer` + `supertag--map-headlines`
  - 返回 nodes（与现有 `supertag--parse-org-nodes` 保持一致）

然后在单文件处理路径中改成：

1. `with-temp-buffer` + `insert-file-contents`（读一次）
2. 基于 buffer 内容计算 `content-hash`（同一 buffer）
3. 决策：
   - 若 hash 未变 → 跳过 parse
   - 若 hash 变了 → 调 `supertag--parse-org-nodes-from-buffer`（不再读文件）

这条路径保证同一次处理不会重复读文件内容。

#### hash 的“内容定义”（字节 vs 解码后的文本）

需要在实现中明确 hash 的定义：

- **字节 hash（更贴近文件真实变化）**
  - 理想：对文件原始字节算 hash
  - 风险：需要确保读入 buffer 时不发生不可控的编码归一化
- **文本 hash（更贴近 org-element 的解析输入）**
  - 对 buffer 字符内容（解码后的文本）算 hash
  - 优点：与 parse 输入一致；实现最简单

建议在本 phase 先采用“文本 hash”（与解析输入一致），并在未来如有必要
再切换到字节 hash（可通过 `:hash-algo` 或额外字段做版本化兼容）。

### 可观测性

- 增加 debug/info 级别日志（遵循现有 message 风格）：
  - `skip: mtime changed but content hash identical`
  - `sync: content hash changed`

建议记录粒度：

- 对每个文件在进入处理时打印一条简短原因（可受 quiet/verbose 开关控制）：
  - `Supertag: skip (hash unchanged): <filename>`
  - `Supertag: sync (hash changed): <filename>`

### 配置开关

- `defcustom supertag-sync-smart-detection-enabled`（默认 nil 或 t，需在 plan 中定）
- 可选增强：
  - 大文件阈值：超过阈值只用 mtime（或延后处理）
  - hash 算法选择：`sha1`/`sha256`

建议最小配置集（便于回滚）：

- `supertag-sync-smart-detection-enabled`（默认 nil，保持现有行为）
- `supertag-sync-smart-detection-hash-algo`（默认 `sha1`）
- `supertag-sync-smart-detection-max-bytes`（默认 nil，表示不设阈值）

### 接入位置（实现时的最小改动点）

smart detection 的“决策点”应位于单文件处理的入口处（概念）：

- `supertag-sync--process-single-file`（或其更上层的“准备 parse”位置）
  - 在调用 parse 之前，读取 state entry（mtime/size/hash）
  - 若仅 `mtime` 变化：
    - 读取文件一次（temp buffer），计算 hash
    - 对比 hash
    - 决定是否继续 parse/导入
  - 若需要 parse：在同一 temp buffer 内 parse（避免双读）

队列/批处理（`supertag-sync-process-queue` 等）不需要改变，只需要确保
最终都走到这个单文件入口逻辑即可。

## Risks & Mitigations

- 风险：hash 计算增加 CPU/IO
  - 缓解：仅在 mtime 变化时计算；可加阈值与可配置开关
- 风险：状态格式迁移复杂
  - 缓解：读旧写新；兼容两种格式并提供自检/修复命令（如需要）
