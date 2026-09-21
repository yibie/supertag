# issue040 [ ] Document Projector 生成临时身份且 point/file 增量结果分叉

## Summary

扫描无 ID heading 时，`supertag-sync-auto-create-node` 可在临时解析 buffer 中调用
`org-id-new`，却不把 ID 写回 Org，因此重复扫描会产生不同身份。同时 node hash 未固定
覆盖 schedule、deadline 与 outgoing references，point sync 又绕过 full-file reconciliation。

## Environment

- org-supertag `main`，ownership-separation phase 的 task005 前
- Emacs 31.0.91 / ERT
- 同时覆盖普通 Org buffer 与 Stream indirect edit buffer

## Reproduction

1. 打开 `supertag-sync-auto-create-node`，重复扫描一个没有 `:ID:` 的 heading。
2. 仅修改已有 node 的 schedule、deadline 或 direct `id:` reference。
3. 分别通过单文件同步与 `supertag-node-sync-at-point` 投影同一 heading。

Actual：扫描可产生没有 Org 持久身份的 Store node；部分 Document Fact 变化不触发更新；
point sync 丢失 outline path、file parent 与旧 node 上的 semantic extension key，且不执行
reference reconciliation。

## Expected

- scanner 只投影 Org 已经拥有持久 ID 的 heading；显式 create command 负责写入 ID。
- 所有 Document Facts 必须参与增量 fingerprint，Customize 只能扩展、不能删减契约。
- point/file sync 使用同一 parse 和 reconciliation，结果只允许 wall-clock 字段不同。

## Investigation

- `supertag--convert-element-to-node-plist` 在临时 buffer 调用 `org-id-new`，没有文档 writer。
- `supertag-sync-hash-props` 是可裁剪白名单，且默认缺少 schedule、deadline、ref-to、file
  与 position 等投影字段。
- `supertag-node-sync-at-point` 直接调用 `supertag-db-add-with-hash`；旧实现还只复制当前
  subtree，导致 outline/file context 与 full-file parser 不同。
- `supertag-db-add-with-hash` 把 reference reconciliation 错误地绑定到统计 counters 是否存在。

## Root Cause

身份、变更检测和 reconciliation 没有形成一个 Document Projector 契约；file 与 point
入口分别实现了部分规则，而 reporting 参数又意外控制了 projection 行为。

## Fix

- parser 对所有模式只接受现有 Org ID；保留旧选项/参数仅用于调用兼容，不再生成临时 ID。
- 固定 `supertag-sync-document-fact-hash-props`，用户配置只作为附加 hash keys。
- 新增共享 `supertag-sync--reconcile-node`，file 与 point 统一复用 change detection、
  semantic-key merge、tag membership 与 reference reconciliation。
- point parser 复制当前完整未保存 buffer 后复用 file parser；indirect buffer 从 base buffer
  取得源文件身份，因此 Stream edit 仍可确认/撤销。
- `supertag-create-node` 写入 Org ID 后重新解析完整 heading，再创建 Store node。

## Verification

- 四条回归测试先暴露临时 ID、hash 缺项、point/file 分叉与 explicit create 残缺属性。
- `./test/run-tests.sh sync-worker` 11/11、`view-stream` 9/9，以及 extractor、tag-path、
  reference、field-reference、smart-key 定向测试全部通过。
- 修改文件 byte-compile 成功，仅有仓库既有 obsolete/docstring/forward declaration warning；
  `check-parens` 与 `git diff --check` 通过。
- 干净临时 clone 全量 ERT 426/426 通过。

## User Confirmation

- [ ] 在真实 Vault 重复同步一个无 ID heading，确认不会出现新 Store node 或漂移 ID。
- [ ] 在普通 Org buffer 与 Stream edit 中分别修改 schedule/body/reference，确认对应视图一致刷新。

## Resolution Status

- Implementation completed: 2026-08-12
- Implemented By: Codex
- Commit: `fix: unify document projector reconciliation`
- Issue remains open until user confirmation.

## Related

- task005
- `supertag-services-sync.el`
- `supertag-ui-commands.el`
- `test/sync-worker-regression-test.el`
