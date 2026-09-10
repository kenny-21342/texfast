# TexFast 搜索替换与最近文件首页

## Research

- 编辑器使用原生 `NSTextView`，可以直接启用 AppKit 内置的查找栏与替换界面。
- 应用原先在无命令行文件参数时直接显示文件选择器，没有独立首页。
- `NSDocumentController` 可持久保存系统标准的最近文档列表，适合首页复用。

## Plan

1. 为编辑器启用原生增量查找和替换功能。
2. 在 Edit 菜单中提供查找和查找替换入口及快捷键。
3. 新增首页窗口，展示仍然存在的最近 LaTeX 文件。
4. 文件打开后写入最近文档列表，并避免重复打开同一文件。
5. 更新 README 并完成 Debug、Release 构建验证。

## Execute

- `EditorViewController` 启用了 `usesFindBar` 和增量搜索。
- Edit 菜单新增 Find and Replace，快捷键为 Option-Command-F。
- 新增 `HomeViewController` 与 `HomeWindowController`，支持双击最近文件和通过按钮选择文件。
- 应用无文件参数启动时显示首页；File 菜单可通过 Shift-Command-H 再次打开首页。
- 每次打开文档时调用系统最近文档 API，并在文档已打开时聚焦已有窗口。
- README 已补充功能和快捷键说明。

## Review

- `xcrun --toolchain default swift build`：通过。
- `xcrun --toolchain default swift build -c release`：通过。
- 构建仅保留项目原有的未使用局部变量警告，以及动态 Selector 风格警告，不影响功能。
