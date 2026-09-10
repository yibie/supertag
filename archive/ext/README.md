# archive/ext — 封存的 Web 前端

两个 Web 前端于 **2026-09-10** 封存，移入此目录（原路径 `ext/`，未删历史、不留壳）：

- `board-ui/` — Board 画布前端（React/npm）
- `graph-ui/` — Graph 可视化前端（Next.js/npm）

对应的 Elisp 侧早已封存于 `archive/board/`、`archive/graph/`（以及 `archive/table/` 等相邻面）。

重新启用时需恢复：

1. `.github/workflows/test.yml` 中被删除的 `archive_board` 手动输入与 `board-ui` npm/build job；
2. `.gitignore` 中 `archive/ext/{board-ui,graph-ui}/` 的 `node_modules`、`.next`、`out`、`build` 条目；
3. `test/development-entrypoints-test.sh` 中对 CI 入口的断言。

构建产物（`node_modules`、`.next`、`out`、`build`）不入 git；本目录只跟踪源码与配置。
