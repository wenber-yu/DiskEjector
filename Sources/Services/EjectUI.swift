import AppKit
import Foundation

/// 推出结果的统一 UI 呈现（菜单栏与主窗口共用，保证弹窗内容与按钮完全一致）。
///
/// **为什么单独抽一层**：菜单栏是 AppKit（`NSAlert`），主窗口是 SwiftUI（`.alert`）。
/// 若两处各自拼弹窗，文案与「关闭并推出」按钮极易分叉。这里把「结果 → 弹窗」收敛成
/// 唯一实现：菜单栏与主窗口都只调用 ``handle(_:disk:)``，逻辑与展示不可能不一致。
enum EjectUI {

    /// 处理一次推出结果。
    /// - `.ejected`：静默刷新列表。
    /// - `.busy`：弹窗列出占用进程，并提供「关闭并推出」；点击后递归处理终止并重试的结果。
    /// - `.failed`：弹通用失败提示。
    ///
    /// 必须在主线程调用（`NSAlert.runModal` 是主线程 API）。
    @MainActor
    static func handle(_ outcome: EjectOutcome, disk: DiskInfo) {
        NSApp.activate(ignoringOtherApps: true)
        switch outcome {
        case .ejected:
            Task { await DiskListStore.shared.refresh() }

        case .busy(let occupying):
            presentBusy(disk: disk, occupying: occupying)

        case .failed(let failure):
            presentFailure(disk: disk, failure: failure)
        }
    }

    // MARK: - 占用弹窗（含「关闭并推出」）

    @MainActor
    private static func presentBusy(disk: DiskInfo, occupying: [OccupyingProcess]) {
        let alert = NSAlert()
        // 标题带磁盘名（设计稿"即将推出 Samsung T7"）。
        alert.messageText = String(format: L10n.tr(.ejectBusyTitle), disk.displayName)
        // 正文只放「以下程序正在访问此磁盘…」这段说明；图标列表与「关闭会丢失数据」警示
        // 都放进 accessoryView。NSAlert 布局顺序固定为「messageText → informativeText →
        // accessoryView → 按钮」，若把警示也塞进 informativeText，accessoryView（图标列表）
        // 会被挤到警示文字之后——用户截图反馈图标漂到错误位置。把警示移到 accessoryView
        // 列表下方后，视觉顺序恢复为：说明 → 图标+名称列表 → 警示 → 按钮。
        alert.informativeText = EjectFlowController.shared.busyMessage(disk: disk, occupying: occupying)
        alert.alertStyle = .warning

        if !occupying.isEmpty {
            // accessoryView = 图标+名称列表，末尾紧跟「关闭会丢失数据」警示。
            alert.accessoryView = processListView(occupying)
        } else {
            // 无进程可列时，警示直接跟在说明文字后。
            alert.informativeText += "\n\n" + L10n.tr(.ejectBusyWarning)
        }

        // 「关闭并推出」作为默认按钮（回车即触发），另给「取消」留出逃生口。
        let closeAndEject = alert.addButton(withTitle: L10n.tr(.closeAndEject))
        closeAndEject.keyEquivalent = "\r"
        // 标红为破坏性操作：终止进程会丢失未保存数据，视觉上必须与普通按钮区分开。
        closeAndEject.hasDestructiveAction = true
        alert.addButton(withTitle: L10n.tr(.cancel))

        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                // 终止占用进程并重试推出；结果递归回本函数（成功刷新 / 仍占用再提示 / 其他失败）。
                let result = await EjectFlowController.shared.terminateAndEject(disk: disk, processes: occupying)
                handle(result, disk: disk)
            }
        }
    }

    /// 构建占用进程列表视图：每行一个「应用图标 + 名称」，末尾紧跟「关闭会丢失数据」警示。
    ///
    /// 名称与图标都取**解析后的应用身份**（``OccupyingProcess/displayName`` +
    /// ``ProcessAppResolver``），而不是 lsof 给的进程可执行名。
    ///
    /// **必须用有明确 frame 宽度的 NSView 容器包住 stack**：NSStackView 没有
    /// `intrinsicContentSize`，如果直接作为 accessoryView 传给 NSAlert，alert 拿不到尺寸
    /// 就会把它压成最小区域、漂到按钮右上角（图 + 文被排成单行贴按钮）。用一个宽度 280
    /// 的 NSView 容器包住，alert 就能把它放在 informativeText 下方、按钮上方的正确位置。
    ///
    /// 设为 `internal` 是为了让单测能断言容器宽度（避免被改回裸 stack 后被 NSAlert 挤压）。
    @MainActor
    static func processListView(_ processes: [OccupyingProcess]) -> NSView {
        // 高度：每行 20 + 行间距 6 + 警示区（约 2 行文字）44 + 列表与警示间距 6。
        let rowsHeight = CGFloat(processes.count) * 20 + CGFloat(max(processes.count - 1, 0)) * 6
        let containerHeight = max(rowsHeight + 6 + 44, 60)
        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: 280, height: containerHeight))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])

        for process in processes {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY

            let iconView = NSImageView()
            // 图标从解析出的 app bundle 路径取；取不到才回落到通用应用图标。
            // 注意不能拿进程名去猜——`IMVIDEO` 猜不到 `Bunny`（见 ``ProcessAppResolver``）。
            iconView.image =
                ProcessAppResolver.icon(for: process) ?? NSWorkspace.shared.icon(for: .application)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 18),
                iconView.heightAnchor.constraint(equalToConstant: 18),
            ])

            // 展示应用显示名（`Bunny`），不是进程可执行名（`IMVIDEO`）。
            let nameLabel = NSTextField(labelWithString: process.displayName)
            nameLabel.font = .systemFont(ofSize: 13)
            nameLabel.lineBreakMode = .byTruncatingTail

            row.addArrangedSubview(iconView)
            row.addArrangedSubview(nameLabel)
            stack.addArrangedSubview(row)
        }

        // 警示：紧跟图标列表下方，自动换行。
        let warning = NSTextField(wrappingLabelWithString: L10n.tr(.ejectBusyWarning))
        warning.font = .systemFont(ofSize: 12)
        warning.textColor = .secondaryLabelColor
        warning.preferredMaxLayoutWidth = 280
        stack.addArrangedSubview(warning)

        return container
    }

    // MARK: - 通用失败弹窗

    @MainActor
    private static func presentFailure(disk: DiskInfo, failure: EjectFailure) {
        let alert = NSAlert()
        alert.messageText = L10n.tr(.ejectFailedTitle)
        alert.informativeText = EjectFlowController.shared.failureMessage(disk: disk, failure: failure)
        alert.alertStyle = .critical
        alert.addButton(withTitle: L10n.tr(.ok))
        alert.runModal()
    }
}
