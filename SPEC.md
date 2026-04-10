# DiskEjector — MVP 需求规格文档

> 版本：v1.0 MVP  
> 日期：2026-04-08  
> 作者：文博 & 代可行  
> 状态：**已确认，待开发**

---

## 1. 项目概述

| 字段 | 内容 |
|------|------|
| 项目名称 | DiskEjector |
| 类型 | macOS 工具类应用 |
| 最低系统版本 | **macOS 14.0+**（ Sonoma 及以上） |
| UI 框架 | SwiftUI |
| 核心功能 | 安全优雅地推出第三方移动硬盘（支持查看并自动终止占用进程、显示磁盘信息、卸载失败告警与日志） |

---

## 2. 功能规格

### 2.1 核心功能

| # | 功能点 | 描述 |
|---|--------|------|
| F1 | 外置磁盘检测与列表 | 自动扫描并展示所有已挂载的外置/移动硬盘（非系统盘） |
| F2 | 磁盘基本信息 | 每个磁盘旁显示：`名称` + 总容量 / 已用 / 剩余 |
| F3 | 占用进程展示 | 列出当前正在读写该磁盘的所有进程（进程名 + PID） |
| F4 | 一键安全推出 | 用户确认后，自动终止占用进程 → 卸载磁盘 |
| F5 | 确认对话框 | 点击推出前，弹窗列出将被终止的进程名称，用户点确认后才执行 |
| F6 | 卸载失败告警 | 卸载失败时弹出系统告警（NSAlert），并记录错误日志 |
| F7 | 错误日志记录 | 将卸载失败信息写入本地日志文件（含时间戳、磁盘名、错误原因） |

### 2.2 交互形态

| 形态 | 说明 | 优先级 |
|------|------|--------|
| **菜单栏 App** | 顶部菜单栏常驻，点击展开磁盘列表，支持右键快捷操作 | P0 |
| **独立窗口 App** | 主窗口展示磁盘列表，支持上述所有交互 | P0 |
| **右键服务（Finder）** | Finder 中右键触发"安全推出"（macOS Services） | P1（MVP 后实现） |

---

## 3. UI/UX 设计

### 3.1 视觉风格

- **整体风格**：macOS Native SwiftUI + **Liquid Glass** 毛玻璃效果（macOS 15+）
- **配色方案**：
  - **透明模式（Transparent）**：全透明毛玻璃背景，contentTint 蓝色系，适配毛玻璃系统主题
  - **色调模式（Tinted）**：固定浅色 tint 背景（系统 background 色），适合不喜欢透明的用户
  - 两种模式可在设置中切换，默认为透明模式
- **深色/浅色模式**：完全跟随系统 `ColorScheme`
- **图标**：SF Symbols（`eject.fill`、`externaldrive.fill`、`xmark.circle`、`folder.fill`）

### 3.2 菜单栏模式

```
[ 💻 DiskEjector 图标（SF Symbol: externaldrive.fill）]
  ↓ 点击
[ 弹出面板 - Liquid Glass 毛玻璃 ]
  ├─ 磁盘A: Samsung T7 — 1TB / 已用 300GB / 剩余 700GB   [ ⏏️ 推出 ]
  ├─ 磁盘B: WD Blue — 500GB / 已用 120GB / 剩余 380GB   [ ⏏️ 推出 ]
  └─ ─────────────────────────────────
     [ ⚙️ 设置]          [ ⏻ 退出]
```

### 3.3 主窗口模式

- **整体布局**：单窗口，左侧列表 + 右侧详情
- **左侧**：外置磁盘列表（带图标），选中态高亮
- **右侧**：
  - 磁盘名称 + 图标（顶部）
  - 容量进度条（彩色条：蓝色已用 / 灰色剩余）
  - 占用进程列表（进程图标 + 名称 + PID）
  - 底部操作区：[ 推出磁盘 ] 按钮
- **底部状态栏**：最后操作结果（成功/失败提示）

### 3.4 确认对话框

```
┌──────────────────────────────────────────────┐
│  ⚠️ 即将终止进程并推出磁盘                     │
│                                              │
│  以下程序正在访问此磁盘，关闭它们可能导致      │
│  数据丢失（未保存的工作将被丢弃）：            │
│                                              │
│  • Finder.app (PID: 1234)                    │
│  • PhotoImport.app (PID: 5678)               │
│                                              │
│            [ 取消 ]     [ 确认终止并推出 ]    │
└──────────────────────────────────────────────┘
```

---

## 4. 技术方案

### 4.1 技术栈

| 层 | 技术选型 |
|----|----------|
| UI | SwiftUI（支持 macOS 14+） |
| 磁盘操作 | DiskArbitration.framework |
| 进程查询 | libproc（`proc_listpids`、`proc_pidpath`）+ `lsof` |
| 日志 | os.log + 本地文件（FileHandle） |
| 打包 | XcodeGen + .app bundle |

### 4.2 关键实现路径

1. **磁盘枚举**：`DADiskCopyDescription` 遍历外置卷，过滤系统盘（`/System/Volumes/Data` 以外）
2. **占用进程检测**：对每个磁盘挂载点执行 `lsof +D <mountpoint>` 或 libproc 遍历
3. **安全推出**：先 SIGTERM 终止占用进程 → 等待 500ms → `DADiskUnmount`
4. **失败重试机制**：首次卸载失败后等待 2s 重试一次，第二次失败再触发告警并写入日志

### 4.3 目录结构

```
DiskEjector/
├── project.yml                  # XcodeGen 配置
├── DiskEjector/
│   ├── App/
│   │   ├── main.swift           # 入口（不用 @main，手动 NSApplication）
│   │   ├── DiskEjectorApp.swift # SwiftUI App 根
│   │   └── AppDelegate.swift    # 菜单栏 + Services 注册
│   ├── Models/
│   │   ├── DiskInfo.swift       # 磁盘数据模型
│   │   └── ProcessInfo.swift    # 进程数据模型
│   ├── Services/
│   │   ├── DiskService.swift    # 磁盘枚举 & 卸载逻辑
│   │   ├── ProcessService.swift # 占用进程检测
│   │   └── LogService.swift      # 错误日志写入
│   ├── Views/
│   │   ├── ContentView.swift    # 主窗口内容
│   │   ├── DiskRowView.swift    # 磁盘列表行
│   │   ├── DiskDetailView.swift # 磁盘详情（容量条 + 进程列表）
│   │   ├── ConfirmDialogView.swift # 确认弹窗
│   │   └── SettingsView.swift   # 设置页（透明/色调切换）
│   └── Resources/
│       └── Assets.xcassets/
└── SPEC.md
```

---

## 5. 验收标准（MVP 完成点）

- [ ] 能正确识别并列出所有已挂载外置磁盘
- [ ] 磁盘容量信息（总量/已用/剩余）显示正确
- [ ] 能准确列出占用指定磁盘的进程
- [ ] 点击"推出"弹出确认对话框，列出将被终止的进程
- [ ] 确认后进程被终止，磁盘成功卸载
- [ ] 卸载失败时触发系统告警并写入日志文件
- [ ] 菜单栏模式正常运行
- [ ] 主窗口模式正常运行
- [ ] 透明 / 色调两种视觉模式可切换
- [ ] XcodeGen 生成的 `.xcodeproj` 能成功 build 并运行

---

## 6. 后续扩展（本次 MVP 不做）

- Finder 扩展右键菜单
- LaunchAgent 开机自启
- 磁盘健康状态（SMART）监控
- 多语言国际化
