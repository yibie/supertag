# issue033 [ ] Widget DSL editable-field 导致边框像素错位

## Environment

- GNU Emacs 31.0.91 GUI
- Iosevka 16px
- `*View: Demo Dashboard - demo*`，141 列

## Repro

1. 打开包含 `editable-field` 的 Widget DSL view。
2. 再次打开同名 view。
3. 检查 field overlays 与 editable-field 所在行的右边框像素位置。

## Expected vs Actual

- Expected：仅存在当前 editable field 的 overlay；同列右边框具有相同 x 坐标。
- Actual：reopen 遗留覆盖整个 buffer 的旧 overlay；原生 `widget-field` face 的横向 box 额外占用 2px。

## Investigation

- live buffer 中发现一个 `1..9611` 的幽灵 field overlay，以及当前 24 字符 field overlay。
- 最小复现首次 open 得到 `(8)`，第二次 open 得到 `(8 9)`。
- editable-field 行右边框为 x=1122，相邻行均为 x=1120；临时移除 `widget-field` box 后恢复 x=1120。

## Root Cause

- Runtime reopen 重新运行 major mode，先清除了 `widget-field-list`，旧 native Widget 因失去句柄而无法释放。
- `widget-field` 默认 face 带 1px 横向 box，在字符列宽正确时仍会推动同行后续 glyph 2px。

## Fix

- Widget mode 通过 buffer-local `change-major-mode-hook` 在局部变量重置前释放 native fields。
- editable field 使用继承 `widget-field` 但无 box/extend 的固定宽度 face。

## Verification

- `test-view-runtime-dsl-reopen-removes-old-field-overlays`
- live GUI：唯一 field overlay span=24，field 前/当前/后一行右边框均为 x=1120。
- 关联：task024

## User Confirmation

待用户实机确认。

## Resolved At/By/Commit

待用户确认后填写。
