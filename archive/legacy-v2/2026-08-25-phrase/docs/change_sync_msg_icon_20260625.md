# change_sync_msg_icon_20260625

## 变更摘要
将外部修改触发的异步同步提示从长文本改为简洁图标，减少 minibuffer 视觉噪音。

## 变更文件
- `supertag-services-sync.el`

## 行为变化
- `supertag-sync--run-on-save` 中，外部修改入队时的 `message` 由
  `Supertag: Enqueued external modification for async sync: <file>`
  改为
  `↻ <file>`
- 仅影响 `supertag-sync-smart-detection-verbose` 开启时的提示。

## 验证
- `batch-byte-compile supertag-services-sync.el` 通过。
