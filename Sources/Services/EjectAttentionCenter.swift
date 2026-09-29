import Combine
import Foundation

/// 一次「有人想推出这块盘、但盘被占用」的待处理提醒。
///
/// ## 为什么要有它（2026-09-29 转向「监听 + 主动接管」）
///
/// 旧方案在 DA approval 回调里**拦截并同步等用户决定**（弹应用窗）。真机验收证明那条路
/// 走不通：协议没有「静默取消」，用户点「取消」后系统框必然弹出。转向后，回调**立即放行**，
/// 只把「谁在占用这块盘」记成本条 —— 菜单栏据此亮起提示，用户点开面板能看到占用者，
/// 一键「关闭并推出」。
struct EjectAttention: Identifiable, Sendable, Equatable {

    /// 挂载路径，同时也是 ``DiskInfo/id`` 与去重键。
    var id: String { disk.mountPath }

    /// 被占用的盘（只有名字与图标参与展示）。
    let disk: DiskInfo

    /// 占用它的进程（由 DA 回调那一刻的占用快照解出）。
    let processes: [OccupyingProcess]

    /// 记录时刻（仅供排序 / 诊断，UI 不展示）。
    let notedAt: Date

    /// 占用者的展示名摘要，如 `Final Cut Pro、访达`。
    ///
    /// **放在这里是为了「只有一份」**：菜单面板的提醒卡片与系统通知的正文都要这句话，
    /// 各拼一份必然漂移（分隔符、顺序、去重只要有一处不同，用户就会看到两种说法）。
    /// 分隔符用顿号：中文界面读得顺，英文界面也还能看 —— 换成 `ListFormatter`
    /// 会让两处按各自 locale 拼出不同结果，反而破坏「同一个提醒只有一种说法」。
    var processSummary: String {
        processes.map(\.displayName).joined(separator: "、")
    }
}

/// 「待处理占用」的单一事实来源：菜单栏提示由它驱动。
///
/// ## 为什么是独立于 ``OccupancyStore`` 的第二个源
///
/// ``OccupancyStore`` 存的是「**每块盘当前**的占用结论」，由 15s 轮询刷新 —— 它是
/// 「现状」。而本类存的是「**用户刚刚尝试推出、但被挡下**」这个**事件** —— 它是
/// 「发生了什么」。二者语义不同：
/// - 一块盘可以被占用很久，但只有用户**点推出**的那一刻才值得提醒；
/// - 提醒的消失时机是「盘推出」或「用户处理完」，不是「占用解除」。
///
/// 所以本类不替代 ``OccupancyStore``，而是挂在它之上：`note` 由 DA 回调触发，
/// `clear` 由「盘推出」或「用户点了关闭并推出」触发。
@MainActor
final class EjectAttentionCenter: ObservableObject {

    static let shared = EjectAttentionCenter()

    /// 待处理提醒，键 = 挂载路径。**同键重复 `note` 是更新不是累积**。
    ///
    /// 用字典而不是数组：DA 回调会因为 Finder 重试而**反复触发**，同一块盘要
    /// 幂等地合并成一条，而不是每次都追加一条新提醒。
    @Published private(set) var pending: [String: EjectAttention] = [:]

    init() {}

    /// 记录「这块盘被占用、谁在占」。
    ///
    /// **幂等**：同一挂载路径重复调用只会更新那条提醒（刷新占用者与时刻），不累积。
    func note(disk: DiskInfo, processes: [OccupyingProcess], at date: Date = Date()) {
        pending[disk.mountPath] = EjectAttention(disk: disk, processes: processes, notedAt: date)
    }

    /// 清除某块盘的待处理提醒（盘已推出、或用户已处理）。
    func clear(mountPath: String) {
        pending.removeValue(forKey: mountPath)
    }

    /// 清空全部（如：磁盘列表刷新发现盘全没了）。
    func clearAll() {
        pending.removeAll()
    }

    /// 是否还有待处理的提醒（驱动菜单栏图标的小圆点）。
    var hasPendingAttention: Bool { !pending.isEmpty }
}
