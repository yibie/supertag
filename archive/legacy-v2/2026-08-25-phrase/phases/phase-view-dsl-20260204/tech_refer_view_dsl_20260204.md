# tech_refer_view_dsl_20260204

## Context

现有 view framework 更偏开发者工具箱，用户缺少“组件 + 嵌套 + 绑定”的 DSL 入口。新 DSL 需要足够简单（20 行可用）且不引入复杂样式/热更新。

## Options

### Option A: 保持现有 DSL（平铺 + 静态 props）
- 优点：最小改动，零风险。
- 缺点：无法嵌套、无法数据绑定，仍依赖开发者写 view。

### Option B: DSL v2（嵌套 + 函数绑定）
- 优点：满足用户自定义需求，保持技术复杂度可控。
- 缺点：需要新增渲染管线与容器组件，增加维护成本。

### Option C: 新建独立 DSL 文件格式（JSON/YAML）
- 优点：更接近配置式使用习惯。
- 缺点：解析成本高，脱离 Emacs 原生生态，绑定语义复杂。

## Decision

采用 Option B：在现有 DSL 基础上扩展为“可嵌套 + 函数绑定”的 DSL v2，保持 Elisp plist 形式，最大化兼容并最小化改动。

## Proposed Approach

1. **DSL 结构保持 plist**，新增 `:children` 支持嵌套。
2. **函数绑定**：组件属性允许 `lambda (ctx) ...`，运行时求值。
3. **组件体系**：
   - 继续使用现有 widget registry。
   - 新增最小容器组件：`section` / `stack` / `columns`。
4. **Context 扩展**：
   - `:tag` / `:nodes` / `:virtual-columns` / `:global-fields`（或 accessor）
   - 通过 view data API 生成 nodes（若可用），否则回退到 nil。
5. **统一刷新命令**：保存 view id + context builder，支持手动重新渲染。

## Interfaces & APIs

### DSL Config Schema

顶层配置（plist）：
- `:id` (symbol) - view id
- `:name` (string) - display name
- `:tag` (string, optional) - 绑定 tag
- `:widgets` (list) - widget 定义列表

Widget 定义（plist）：
- `:type` (symbol or keyword) - widget 类型（keyword 将被归一化）
- `:children` (list, optional) - 子组件列表（用于嵌套）
- 其他 key 作为 props

**Props 绑定语义**：
- 若 prop value 是函数（`functionp`），则 `(funcall value ctx)`。
- 仅对顶层 prop 求值；若需要动态列表，返回 list 即可。

### Context Contract

`ctx` 为 plist，至少包含：
- `:tag` string
- `:nodes` list (node plists or ids)
- `:virtual-columns` list or hash (optional)
- `:get-vc` function (optional) `(node-id column-id &optional default)`
- `:get-global-field` function (optional) `(node-id field-id &optional default)`

生成策略：
- 若 `supertag-view-api-*` 可用，优先用其构造 `:nodes`。
- 否则允许 `:nodes` 为空，由绑定函数自行查询。

### Render APIs (内部)

- `supertag-view--render-widget` `(widget ctx)`
  - 递归处理 `:children`
  - 解析 props（函数绑定）
  - 调用 `supertag-widget-render`

- `supertag-widget-render` `(type props &optional ctx)`
  - 兼容旧签名；如提供 ctx 则支持容器组件或复杂渲染。

### Refresh API

- `supertag-view-refresh`
  - 重新构建 context 并渲染当前 view
  - 依赖 buffer-local 变量存储当前 view id/context builder

## Container Widgets (Minimum)

### section
- Props: `:title` (string or binding), `:children` (required)
- 行为：插入标题 + 渲染子组件

### stack
- Props: `:children` (required), `:spacing` (number, optional, default 1)
- 行为：按顺序渲染子组件并插入空行

### columns
- Props: `:columns` (required)
- 每个 column: `(:width 30 :children (...))`
- 行为：将每列渲染为字符串后按列拼接（固定宽度，超长截断）
- 目标：提供“轻量并排布局”，不引入复杂样式系统

## Example (DSL v2)

```elisp
(supertag-view-define-from-config
 (list :id 'my-dashboard
       :name "My Dashboard"
       :tag "project"
       :widgets
       (list
        (list :type :section :title "Overview"
              :children
              (list
               (list :type :stats-row
                     :stats (lambda (ctx)
                              (list (cons "Total" (length (plist-get ctx :nodes))))))
               (list :type :progress-bar
                     :value (lambda (ctx)
                              (or (plist-get (car (plist-get ctx :nodes)) :progress) 0)))))
        (list :type :columns
              :columns
              (list
               (list :width 24
                     :children (list (list :type :text :content "Left")))
               (list :width 24
                     :children (list (list :type :text :content "Right"))))))))
```

## Trade-offs

- 仅函数绑定：降低 DSL 复杂度，但对不熟悉 Elisp 的用户有门槛。
- columns 实现为轻量字符布局：牺牲复杂排版换取可维护性。
- Context 通过 data API 生成 nodes：依赖现有 API 稳定性。

## Risks & Mitigations

- **风险**：绑定函数出错导致渲染失败
  - **缓解**：捕获错误并提示，不中断整体渲染

- **风险**：context 数据不足导致绑定失败
  - **缓解**：明确文档说明，提供 helper functions

- **风险**：DSL 功能膨胀
  - **缓解**：明确非目标，不引入表达式 DSL/样式系统/自动刷新
