# 发布说明（新版本弹窗的「本次更新」清单）

每个版本一个文件，文件名 = 版本号，扩展名 `.html`：

```
release-notes/2026.09.18.3.html     ← 对应 tag v2026.09.18.3
```

生成 appcast 时传进去：

```bash
RELEASE_NOTES_FILE=release-notes/2026.09.18.3.html ./scripts/make_appcast.sh
```

## 格式要求（四条，都是「做错了也看不出」的）

1. **不要写 HTML 注释。**
   解析器 `UpdateReleaseNotes.stripTags` 只剥 `<…>` 尖括号对，**不认注释** ——
   `<!-- 说明 -->` 剥掉 `<!--` 之后，**注释正文会原样出现在弹窗里**。
   （2026-09-18 实测踩到：第一版把格式说明写在注释里，生成出来全进了 `<description>`。
   脚本现在有一条守卫直接拦下含 `<!--` 的说明文件。）
2. **不要加 `<!DOCTYPE>` / `<html>` / `<body>`。**
   不含它们时 `generate_appcast` 才会把内容**内嵌**进 appcast 的 `<description>`；
   而 `UpdateUserDriver` **只读内嵌的那份**（`showUpdateReleaseNotes` 是空实现，
   外链的 `sparkle:releaseNotesLink` 它不看）。
3. **每条更新用 `<li>` 包起来。**
   解析器**先**把 `<li>` / `<br>` / `</p>` 变成换行、**再**剥标签。
   没有这些边界的话所有条目会粘成一行 —— 而粘出来的文本读起来完全正常，
   肉眼很难发现「4 条更新变成了 1 条」。
4. **别自己写行首的 `·` / `-` / `*`。**
   弹窗自己会画 `·`，源文本里带了会变成「· · 修复了…」。

## 已知限制

appcast 的 `<description>` 是**单一字符串**，没有按语言分支 —— 而应用本体是三语的
（简体中文 / 繁體中文 / English）。所以说明文件用**主语言中文**写。
要按语言分支得换成 `sparkle:releaseNotesLink` 指向多语言页面，那需要先改
`UpdateUserDriver`（它现在明确只读内嵌的 `<description>`）。
