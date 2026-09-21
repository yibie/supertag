# change_svg_tag_style_20260625

## 变更摘要
按用户反馈继续调优 `supertag-view-svg-tag.el`：去掉文字颜色对 `color-name-to-rgb` 的依赖，提升彩色背景饱和度与明度，让颜色更清晰可见。

## 变更文件
- `supertag-view-svg-tag.el`

## 行为变化
- 彩色背景饱和度提升（亮主题 0.78 / 暗主题 0.65），明度降低（亮主题 0.82 / 暗主题 0.40），颜色更鲜明。
- 文字颜色直接根据当前主题确定，不再调用 `color-name-to-rgb` 解析背景色，避免在 batch/无显示环境下误判对比度。
- 默认背景不透明度为 `1.0`；如需半透明仍可调节 `supertag-svg-tag-color-alpha`。
- 保留无边框、胶囊形状、不显示 `#`、非图形终端回退等设置。

## 新增/变更的自定义项
- `supertag-svg-tag-color-alpha` 默认值改为 `1.0`。
- 彩色样式 HSL 参数调整（饱和度、明度）。
- 其余自定义项不变。

## 验证
- `emacs -batch -Q -L . -f batch-byte-compile supertag-view-svg-tag.el` 通过。
- 在 batch 模式下生成多个标签样例，确认背景颜色更饱和、文字均为深色（亮主题）、无边框、无 `#`。
