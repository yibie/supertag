# issue045：网络/同步目录中的陈旧数据库锁阻断自动保存

## Environment

- macOS，Emacs 31.x
- Org-SuperTag Git sync phase
- `supertag-db-file` 位于网络盘或 Dropbox/iCloud/Syncthing 同步目录

## Repro

1. 让一个 Emacs 实例打开数据库并在网络异常或异常退出后留下数据库旁的 `.#supertag-db.el`。
2. 在同一台机器启动另一个 Emacs 实例并加载同一 vault。
3. 触发自动保存或正常退出。

## Expected vs Actual

Expected：陈旧的网络目录锁不应阻断本机新会话；仍然应该阻止两个当前运行的同机 Emacs 同时写入。

Actual：出现 `Supertag auto-save skipped: database locked by another Emacs instance`，随后
`supertag-git-sync: exit cancelled because the Store could not be saved`，正常退出被阻断。

## Investigation

Emacs 的 `lock-file`/`file-locked-p` 默认在数据库旁创建 advisory lock 符号链接。网络/同步
文件系统会把陈旧锁路径保留下来或延迟同步；该路径随后被新会话当作活跃的外部锁。Git fetch/push
的离线重试会保留本地数据，问题发生在数据库锁路径，不在 Git 网络重试状态机。

## Fix

关联 `task009`：对本地数据库文件临时绑定 `lock-file-name-transforms`，把同机 advisory lock
放到本机 `temporary-file-directory/org-supertag-locks/` 的确定性 SHA-256 路径；Doctor 和所有
保存/恢复锁检查使用同一锁状态入口。保留 nil 配置回退到 Emacs 原生数据库旁锁。

## Verification

- [x] 回归测试证明数据库旁的陈旧外部锁不阻断新会话保存。
- [x] 回归测试证明当前同机外部锁仍阻断保存。
- [x] `./test/run-tests.sh persist`（36/36）、Git 子套件（38/38）和全量测试（516/516，2 skipped）通过。
- [x] 临时目录 byte-compile、`check-parens` 与 `git diff --check` 通过。

## User Confirmation

待用户在真实 vault 重启所有 Emacs 实例并确认自动保存/正常退出恢复。

## Resolved At / By / Commit

待实现与用户确认。
