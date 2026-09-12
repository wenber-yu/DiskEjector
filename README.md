# DiskEjector

**推出硬盘之前，先看清是谁占着它。**

![DiskEjector 主窗口：列出正在占用移动硬盘的程序](assets/screenshots/disk-list.png)

macOS 14+ · SwiftUI · 菜单栏常驻 + 独立窗口 · 简体中文 / 繁體中文 / English

[![CI](https://github.com/wenber-yu/DiskEjector/actions/workflows/ci.yml/badge.svg)](https://github.com/wenber-yu/DiskEjector/actions/workflows/ci.yml)

---

## 这一幕你大概不陌生

东西收好了，弯腰去拔移动硬盘。系统弹出一句话，把你拦下：

> 磁盘「My Passport」未能推出，因为一个或多个程序正在使用它。

它承认「有程序在用」，**却没说是什么程序**。

于是只能开始猜。是刚才那个播放器忘了关？把访达窗口挨个关掉再试，还是不行。是备份软件？它明明显示「已完成」。是不是 Spotlight 在后台索引？不知道，也无处可查。再点一次推出 —— 依然是「正在使用中」。

硬盘就这么卡在那儿，谁也动不了。赶时间的时候，很多人干脆把线一拔；而这一拔，正在写入的数据可能就废了。

**DiskEjector 就是为了结束这场猜谜。** 它把占用者直接摆出来：图标加名字，是谁占着，一眼看到。想推出，就从这里推。

## 它做的事

| 能力 | 说明 |
|------|------|
| 说清楚是谁在占用 | 插入硬盘即自动检测，列出每个正在读写它的程序（图标 + 名称）。判断依据是进程是否**持有该磁盘的文件句柄** —— 这正是系统用来决定「能不能推出」的唯一标准，所以列出来的就是真正挡路的那个 |
| 一键推出 | 无人占用时，点一下干净推出 |
| 关闭并推出 | 被占用时不必自己翻进程：一次点掉全部占用者 —— 先 `SIGTERM` 请它自己退出，等 1.5 秒仍在则 `SIGKILL`，然后重试推出。**这一步会丢失未保存的数据，所以按钮标红、且需你确认** |
| 绝不强卸 | 不使用 `diskutil unmount force`。它不是解决问题，而是把「磁盘忙」换成「数据损坏」 |
| 容量一览 | 每块盘显示 总容量 / 已用 / 剩余，避免拿错盘 |
| 双形态 | 菜单栏常驻面板 + 独立窗口，二者共用同一套推出流程 |
| 失败留痕 | 推出失败会记下时间、磁盘、原因，便于回溯 |
| 多语言 | 简体中文 / 繁體中文 / English |
| 外观 | 透明（Liquid Glass）与色调两种模式，跟随系统深色 / 浅色 |
| 开机自启 | `SMAppService`（唯一符合沙盒规范的登录项方案） |

## 安装

### 方式一：dmg（推荐）

1. 到 [Releases](../../releases) 下载 `DiskEjector.dmg`
2. 双击挂载，把 `DiskEjector` 拖进 `Applications` 文件夹（dmg 里已备好 Applications 替身）
3. 首次打开：**右键点图标 → 打开**（当前构建未经 Apple 公证，见下方「签名与分发」）
4. 按引导授权「完全磁盘访问」（下一节就是它）

### 方式二：zip

下载 `DiskEjector.zip`，解压得到 `DiskEjector.app`，拖进 `Applications`，同样需要第 3、4 步。

> **为什么首次打开要绕一下？**
> 本 release 使用开发期自签证书，**未经过 Apple 公证（notarization）**，Gatekeeper 会默认拦截。
> 若「右键 → 打开」无效，可移除隔离属性后再打开：
> ```bash
> xattr -dr com.apple.quarantine /Applications/DiskEjector.app
> ```

## 需要「完全磁盘访问」授权

**这是核心功能的前置条件，不授权就看不到占用进程。** 启动后主窗口顶部会出现引导横幅，点「打开系统设置」直达：

> 系统设置 › 隐私与安全性 › 完全磁盘访问 › 勾选 DiskEjector

**为什么非它不可。** 要读出**其他**进程打开了哪些文件，进程必须以「完全磁盘访问」运行；否则系统会让 `lsof` 对其他进程的文件一律不可见（实测输出 0 行）。而这恰恰是最容易漏掉的一类占用者 —— 比如 Spotlight 的索引进程正抓着你的盘，它属于系统，普通权限根本看不到。未授权时，应用不会假装「没有占用」，而是明确显示「需要完全磁盘访问」。

**授权会掉吗。** TCC（权限数据库）按**代码签名身份**记录授权。`build_app.sh` 按 `Developer ID → 任意稳定签名身份 → ad-hoc` 三档回退：用了稳定的证书身份，重建后授权依然有效；只有落到 ad-hoc（无身份）档位，每次重建 CDHash 都会变，授权才会失效、需要重新勾选。

## 已知限制

**「软占用」不会列出 —— 这不是 bug。**

macOS 推出磁盘的唯一判据是**是否持有文件句柄（fd / mmap / cwd）**。持有才返回 `fBsyErr(-47)` 阻止推出，而 `lsof` 能列出的恰好就是这类进程，所以检测是完备的。

反过来，把文件读进内存后立刻关掉句柄的程序（编辑器、压缩包预览、Quick Look 等）**不持有句柄、也不会阻止推出**，因此列不出来 —— 这是正确行为。macOS 没有任何公开 API 能查询「某程序在内存里打开着某文件但没持有句柄」，Finder 推出磁盘时同样不会警告这类程序。

其他：

- Finder 右键服务、磁盘健康（SMART）监控、自动更新尚未实现
- UI 层暂无自动化测试覆盖

## 从源码构建

需要 Xcode Command Line Tools（提供 Swift 工具链与 SDK），**不需要 Xcode GUI**。

```bash
git clone https://github.com/wenber-yu/DiskEjector.git
cd DiskEjector

./build_app.sh                # 产出 dist/DiskEjector.app
PACKAGE=1 ./build_app.sh      # 额外产出 dist/DiskEjector.dmg + DiskEjector.zip
NOTARIZE=1 ./build_app.sh     # 公证并打包（需 Developer ID 证书 + 公证凭证）

./run.sh                      # 源码目录直接编译运行
./run.sh check                # 跑 CI 门槛（零警告 + 格式 + 覆盖率）
./run.sh check --with-tests   # 门槛 + 全量测试
swift test                    # 只跑测试
```

版本号与构建号由 `build_app.sh` 从 git 自动派生（`VERSION` ← 最近 tag，`BUILD_NUMBER` ← 提交数），也可用环境变量覆盖。

## 工程约定

| 项 | 说明 |
|----|------|
| 构建 | SwiftPM（仓库根即包根），无 `.xcodeproj` |
| CI | `.github/workflows/ci.yml`：代码门槛 → 打包验证 → 产物校验 |
| 本地门槛 | `./run.sh check`，与 CI **调用同一个脚本**（`scripts/preflight.sh`），判据不会分叉 |
| 格式 | `swift-format`，配置见 `.swift-format`（4 空格缩进 / 120 行宽） |
| 覆盖率 | `scripts/coverage.sh`，只统计核心逻辑（Models / Services / Settings），不把 SwiftUI 视图计入分母 |
| 测试 | 单元测试 + 集成测试（真机挂载磁盘映像验证「关闭并推出」全流程；CI 无法挂载时自动跳过） |

三个容易踩空的细节：

- `swift-format lint` 默认即使发现问题也返回 `0`，必须加 `--strict` 才能拦住 —— CI 已加。
- `build_app.sh` 的 release 构建**不带** `-warnings-as-errors`，所以「打包成功」推不出「CI 会绿」。改完 `Sources/` 先跑 `./run.sh check`。
- 覆盖率不把 `Sources/Views/` 与 `Sources/DiskEjectorApp/` 计入分母：SwiftUI 视图无法在单测中真实驱动，计入会让数字被 UI 代码体量主导，对改进不敏感。

## 为什么不上架 Mac App Store

不是不想，是核心功能会在沙盒里归零。实测矩阵：

| 能力 | 非沙盒（直发） | MAS 沙盒 |
|------|--------------|---------|
| `lsof`（列出占用进程） | ✅ 正常 | ❌ **输出 0 行** |
| `proc_listallpids` | ✅ 正常 | ❌ **返回 0** |
| `kill()` 其他进程 | ✅ 正常 | ❌ **EPERM** |

「告诉用户是哪个进程占用了磁盘」正是这个应用存在的理由；沙盒下它只能降级成「当前环境无法检测」，等同于废掉核心价值。因此主分发渠道选择官网 / GitHub 直发（SwiftPM 构建 + Developer ID 签名，不开沙盒），MAS 版本仅保留为可选精简渠道。

## 签名与分发

本仓库当前发布的构建使用**开发期自签证书**签名。它能保住 TCC 授权，但：

- **无法公证**，用户首次打开需手动放行
- **无法上架 Mac App Store**

拿到 Apple 签发的 **Developer ID Application** 证书后，`build_app.sh` 会自动优先使用它（无需改脚本），届时 `NOTARIZE=1` 即可产出可直接双击打开的公证版本。

## 许可证

尚未指定开源许可证（All rights reserved）。如需以开源方式使用，请先补充 `LICENSE` 文件。
