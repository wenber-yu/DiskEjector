import AppKit
import Foundation

/// 推出结果的统一 UI 呈现（菜单栏与主窗口共用，保证弹窗内容与按钮完全一致）。
///
/// **为什么单独抽一层**：菜单栏与主窗口是两条独立的代码路径。
/// 若两处各自拼弹窗，文案与「关闭并推出」按钮极易分叉。
/// 这里把「结果 → 弹窗 → 后续动作」收敛成唯一实现：
/// 两个入口都只调用 ``handle(_:disk:)``，逻辑与展示不可能不一致。
///
/// **弹窗是自绘的**（``EjectAlertView`` + ``EjectAlertPresenter``），不是 `NSAlert` ——
/// 设计稿 `03-eject-flow.html` 的版式（图标在左、标题左对齐、提示块、下沉操作区）
/// 系统弹窗给不了。本类只负责「用户点了什么 → 该干什么」。
@MainActor
enum EjectUI {

    /// 处理一次推出结果。
    ///
    /// - `.ejected`：静默刷新列表。
    /// - `.busy`：弹窗列出占用进程并提供「关闭并推出」；确认后终止进程并重试，
    ///   重试结果递归回本函数（成功刷新 / 仍占用再提示 / 其他失败）。
    /// - `.failed`：弹失败提示，「查看日志」在访达中显示日志。
    ///
    /// **必须 `await`**：弹窗会挂起直到用户做出选择。调用方本来就在 `Task {}` 里，
    /// 写起来仍是顺序的。
    static func handle(_ outcome: EjectOutcome, disk: DiskInfo) async {
        switch outcome {
        case .ejected:
            await DiskListStore.shared.refresh()

        case .busy(let occupying):
            let choice = await EjectAlertPresenter.shared.present(
                .busy(disk: disk, occupying: occupying))
            // 只有「关闭并推出」这一条路径会丢数据，所以只有它需要确认后动手。
            guard choice == .closeAndEject else { return }
            let result = await EjectFlowController.shared.terminateAndEject(
                disk: disk, processes: occupying)
            await handle(result, disk: disk)

        case .failed(let failure):
            let choice = await EjectAlertPresenter.shared.present(
                .failure(disk: disk, failure: failure))
            if choice == .viewLog {
                LogService.shared.revealLogInFinder()
            }
        }
    }

    /// 占用弹窗的警示文案（**必须写清动作序列**）。
    ///
    /// 设计稿文案原则：「『先请求正常退出 → 几秒后强制结束 → 重试推出』——
    /// 用户知道点下去会发生什么。」这不是修辞：
    /// ``EjectFlowController/terminateAndEject(disk:processes:)`` 的实现恰好就是这三步
    /// （`SIGTERM` → 1.5s → `SIGKILL` → 普通重试）。
    /// 文案与实现是一对，改文案前先看实现，改实现后必须回来看文案。
    ///
    /// 品牌名走 `appName` 本地化键而不是硬编码 `DiskEjector`：中文界面里应用叫
    /// 「磁盘推出助手」，正文里突然出现英文品牌名是断裂的。
    static var busyWarningText: String {
        String(format: L10n.tr(.ejectBusyWarning), L10n.tr(.appName))
    }
}
