# spec_concept_mentions_20260708

## Summary

为 org-supertag 增加 CJK 友好的 concept mention 能力：用户选中文本并提升为概念节点，当前节点自动建立 reference，原文保持不变；之后同一概念标题或 alias 在 Org buffer 中作为动态 mention 高亮并可跳转，但不自动落库为 reference。

## Goals & Non-goals

### Goals

- 提供 `supertag-promote-concept`：从选区创建或选择 concept node，当前 node 到 concept node 建立一条 reference，选区文本不替换为 Org link。
- 提供 `supertag-concept-link-mode`：在 Org buffer 中识别已知 concept 的 title/alias，最长优先高亮为 mention，并支持 `RET` / `mouse-1` 跳转。
- mention 使用独立琥珀色语义高亮，不继承 `org-link`，不默认下划线，不混同 `#tag` 样式。
- 不默认绑定 `M-RET` 或其他按键，只提供命令和文档中的可选绑定示例。
- 保持 mention 与 reference 分离：mention 是动态文本匹配，reference 是持久关系。

### Non-goals

- 不做中文分词、AI 概念抽取或 fuzzy mention。
- 不在非 Org buffer 中启用全局 recognizer。
- 不把所有同词 mention 自动落库为 reference。
- 不改变 `supertag-add-reference` / `supertag-add-reference-and-create` 的既有行为。

## User Flows

1. 用户在 Org node 内容中选中 `注意力机制`。
2. 用户执行 `M-x supertag-promote-concept`。
3. 系统创建或选择标题为 `注意力机制` 的 concept node。
4. 当前 node 自动 reference 该 concept node；选区文本保持 `注意力机制` 原样。
5. 用户启用 `supertag-concept-link-mode` 后，其他 `注意力机制` 出现位置以 mention 样式高亮，可跳转到 concept node，但不会新增 reference。

## Edge Cases

- 当前点不在 Org node 内：命令报错，不创建孤立 reference。
- 选区为空：命令报错。
- 同名 concept 已存在：复用已有 node，不重复创建。
- alias/title 重叠：最长匹配优先，例如先匹配 `大语言模型微调`，再匹配 `大语言模型`。
- mention 出现在 src block、Org keyword/comment、表格或 verbatim 上下文：不高亮。
- mention 不渲染为真实 `[[id:...]]` 文本，避免 sync 把它误当 reference。

## Acceptance Criteria

- `supertag-promote-concept` 可在选区上创建/复用 concept node，并只为当前 node 建立 reference。
- promote 后选区文本保持不变。
- `supertag-concept-link-mode` 能高亮 title/alias mention，样式区别于 `org-link` 和 inline `#tag`。
- mention 上 `RET` / `mouse-1` 跳转到 concept node。
- 其他 mention 不会自动创建 relation/backlink。
- README/README_CN 提供可选 keybinding 示例，不默认修改 `org-mode-map`。
