# issue038 [ ] 普通 Org buffer 的 #tag 自动补全被通用前缀阈值延迟

## Environment

- Emacs 31.0.91
- Corfu 2.11，`corfu-auto=t`、`corfu-auto-prefix=2`
- org-supertag `191d9b6`
- 普通、可写的 Org buffer；`supertag-ui-completion-mode=t`

## Reproduction

1. 在普通 Org buffer 输入 `#`，或继续输入一个字符成为 `#d`。
2. 等待 Corfu 自动补全。
3. 输入第二个 Tag 字符成为 `#di`。

## Expected vs Actual

- Expected: 前导 `#` 已唯一确定 Tag CAPF，`#`/`#d` 即可显示已有 Tag。
- Actual: `#`/`#d` 没有 popup；`#di` 才显示候选。

## Investigation

- 现场检查所有普通 Org buffer：completion minor mode、CAPF hook 和 Corfu 均已启用，排除初始化丢失。
- 直接调用 CAPF：Store 中 112 个 Tag 可读，`#di` 可返回 `diary` 等 15 个候选，排除数据库与候选构造错误。
- 真实 Corfu 自动完成探测：旧实现 `#`/`#d` inactive，`#di` active。
- 根因是 CAPF 将当前 prefix 长度回传为 `:company-prefix-length`；该数值没有覆盖 Corfu 的通用最小长度，只重复了当前长度。

## Fix

- 前导 `#` 已识别为 Tag context 后，把 CAPF 的 `:company-prefix-length` 设为 `t`。
- 不修改全局 `corfu-auto-prefix`，不增加 Corfu advice/hook，不改变候选、提交或 Store 语义。

## Verification

- Regression first: focused Tag Path ERT 25/26，新增触发契约按预期失败。
- Fixed: focused Tag Path ERT 26/26。
- Live differential probe: `#` 从 inactive/0 变为 active/112；`#d` 从 inactive/0 变为 active/17。
- Completion self-check 与 full ERT 402/402 通过。
- Normal whole-file byte compile、changed-function strict compile、check-parens、diff-check 与 repo-local `.elc` zero 通过。
- Emacs 31 strict whole-file compile/checkdoc 仍报告本文件既有 obsolete macro/doc 告警，均位于本次改动之外。

## Resolution

- Related task: `task023`
- User confirmation: pending live-buffer verification after update/reload
- Resolved At/By/Commit: pending user confirmation
