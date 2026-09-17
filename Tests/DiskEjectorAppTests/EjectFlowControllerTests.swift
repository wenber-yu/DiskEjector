import AppKit
import Foundation
import SwiftUI
import Testing

@testable import DiskEjectorApp

// MARK: - Mock 服务

/// 拦截 eject 调用的 mock，不触发真实推出。
private final class MockEjectService: EjectService, @unchecked Sendable {
    var ejectResult: Result<Void, EjectFailure> = .success(())
    var capturedDisk: DiskInfo?
    var ejectCalled = false

    override func eject(disk: DiskInfo) async -> Result<Void, EjectFailure> {
        ejectCalled = true
        capturedDisk = disk
        return ejectResult
    }
}

/// 拦截占用检测的 mock，不跑真实 lsof。
private final class MockOccupancyDetector: OccupancyDetector, @unchecked Sendable {
    var result: OccupancyResult = .none
    var capturedMountPath: String?
    var detectCalled = false

    override func detect(mountPath: String) async -> OccupancyResult {
        detectCalled = true
        capturedMountPath = mountPath
        return result
    }
}

/// 记录型日志替身。
///
/// **为什么不直接用 `LogService.shared`**：它写的是**用户真实**的
/// `~/Library/Logs/DiskEjector/error.log`。测试若走它，一是把测试造的假失败
/// 混进用户日志（用户打开日志会看到一堆没发生过的失败），二是断言要读磁盘文件、
/// 与其它用例互相干扰。注入这个替身后，断言只看内存里的数组。
private final class LogRecorder {
    struct Entry {
        let disk: String?
        let message: String
    }

    private(set) var entries: [Entry] = []

    func record(disk: String?, message: String) {
        entries.append(Entry(disk: disk, message: message))
    }
}

// MARK: - Fixtures

private func makeDisk(name: String = "测试盘") -> DiskInfo {
    DiskInfo(
        id: "/Volumes/TEST",
        bsdName: "disk4s2",
        volumeName: name,
        mountPath: "/Volumes/TEST",
        totalBytes: 1_000,
        usedBytes: 400,
        freeBytes: 600,
        deviceProtocol: "USB",
        deviceModel: nil
    )
}

// MARK: - 测试

/// 文案断言**一律不显式指定 locale**，而是用与产品代码完全相同的解析方式
/// （`L10n.tr(key)`，默认走 `Locale.current`）。
///
/// 为什么必须这样：CI 的 workflow 设了 `LC_ALL=en_US.UTF-8`，会让 `Locale.current`
/// 解析成 `en`；中文机器上则是 `zh-Hans`。若测试里写死 `locale: zhHans`，
/// 就变成「换台机器必红」的环境依赖——2026-09-12 CI 首次运行即因此红了 4 条。
/// 这些断言要钉的是「用了哪个 key、占位符填了什么」，而不是「文案恰好等于某个中文字符串」；
/// 后者既脆弱（文案随时会改），又把测试和运行环境绑死。
@MainActor
struct EjectFlowControllerTests {

    // MARK: checkOccupancy

    @Test func checkOccupancy透传检测结果与挂载路径() async {
        let mock = MockOccupancyDetector()
        let expected = [OccupyingProcess(pid: 42, processName: "IINA", path: "/Applications/IINA.app")]
        mock.result = .occupied(expected)
        let controller = EjectFlowController(occupancyDetector: mock)

        let result = await controller.checkOccupancy(mountPath: "/Volumes/TEST")

        #expect(mock.detectCalled)
        #expect(mock.capturedMountPath == "/Volumes/TEST")
        #expect(result == .occupied(expected))
    }

    /// 沙盒下检测能力缺失必须显式表现为 `.unknown`，
    /// 不能被折叠成「无占用」——否则上层会据此直接推出。
    @Test func checkOccupancy沙盒下返回unknown而非空列表() async {
        let mock = MockOccupancyDetector()
        mock.result = .unknown
        let controller = EjectFlowController(occupancyDetector: mock)

        let result = await controller.checkOccupancy(mountPath: "/Volumes/TEST")

        #expect(result == .unknown)
        #expect(result.processes.isEmpty)
        #expect(result != .none, "unknown 与 none 必须是可区分的状态")
    }

    // MARK: eject

    @Test func eject成功时返回ejected() async {
        let disk = makeDisk()
        let mock = MockEjectService()
        mock.ejectResult = .success(())
        let controller = EjectFlowController(ejectService: mock)

        let result = await controller.eject(disk: disk)

        #expect(mock.ejectCalled)
        #expect(mock.capturedDisk == disk)
        guard case .ejected = result else {
            Issue.record("期望 ejected，实际 \(result)")
            return
        }
    }

    /// 占用（fBsyErr）必须映射为 `.busy` 且携带检测到的进程，供弹窗列出「是谁」。
    @Test func eject占用时返回busy并携带进程() async {
        let disk = makeDisk()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .failure(.inUse)
        let mockDetect = MockOccupancyDetector()
        let expected = [OccupyingProcess(pid: 42, processName: "IINA", path: "/x.mp4")]
        mockDetect.result = .occupied(expected)
        let controller = EjectFlowController(ejectService: mockEject, occupancyDetector: mockDetect)

        let result = await controller.eject(disk: disk)

        guard case .busy(let occupying) = result else {
            Issue.record("期望 busy，实际 \(result)")
            return
        }
        #expect(occupying == expected)
    }

    /// 非占用类的失败（如设备已消失）仍映射为 `.failed`，不应被误判为占用。
    @Test func eject非占用类失败映射为failed() async {
        let disk = makeDisk()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .failure(.notFound)
        let mockDetect = MockOccupancyDetector()
        mockDetect.result = .none
        let controller = EjectFlowController(ejectService: mockEject, occupancyDetector: mockDetect)

        let result = await controller.eject(disk: disk)

        guard case .failed(let reason) = result else {
            Issue.record("期望 failed，实际 \(result)")
            return
        }
        #expect(reason == .notFound)
    }

    // MARK: 失败留痕（弹窗与设置面板都向用户承诺了这件事）

    /// 失败弹窗写着「已记入日志，可在『设置 › 诊断』中查看」。
    /// 这句承诺只有在 `record(_:disk:)` 真的调用日志写入时才成立 ——
    /// 之前 `LogService` 与 `EjectFailure.logText` 都已就绪却从未接上，
    /// 日志里一条推出失败都没有，而没有任何测试会红。
    @Test func 推出失败会写进用户日志() async {
        let recorder = LogRecorder()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .failure(.notPermitted)
        let mockDetect = MockOccupancyDetector()
        mockDetect.result = .none
        let controller = EjectFlowController(
            ejectService: mockEject, occupancyDetector: mockDetect, log: recorder.record)

        _ = await controller.eject(disk: makeDisk())

        #expect(recorder.entries.count == 1, "一次失败应恰好写一条日志，实际 \(recorder.entries.count) 条")
        let entry = recorder.entries.first
        #expect(entry?.disk == "测试盘", "日志必须带磁盘名，否则用户分不清是哪块盘出的问题")
        #expect(
            entry?.message.contains(EjectFailure.notPermitted.logText) == true,
            "日志要带失败类型（\(EjectFailure.notPermitted.logText)），否则查日志也定位不了原因；实际 \(entry?.message ?? "无")"
        )
    }

    /// 设置面板的诊断分组承诺「记录**每次**推出失败」，而「被占用」是最常见的那种。
    /// 只记 `.failed` 会让用户报「磁盘推不出来」时在日志里查无此事。
    @Test func 推出被占用也写进日志且用应用名() async {
        let recorder = LogRecorder()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .failure(.inUse)
        let mockDetect = MockOccupancyDetector()
        mockDetect.result = .occupied([
            OccupyingProcess(pid: 42, processName: "IMVIDEO", displayName: "Bunny", path: "/x.mp4")
        ])
        let controller = EjectFlowController(
            ejectService: mockEject, occupancyDetector: mockDetect, log: recorder.record)

        _ = await controller.eject(disk: makeDisk())

        let message = recorder.entries.first?.message ?? ""
        #expect(message.contains("Bunny"), "日志要写应用显示名，实际 \(message)")
        #expect(
            !message.contains("IMVIDEO"),
            "不能写进程可执行名（IMVIDEO）—— 用户看到这个名字无法对上是哪个应用"
        )
    }

    /// 成功不该往日志里写东西，否则日志会被正常操作淹没，真出问题时翻不出来。
    @Test func 推出成功不写日志() async {
        let recorder = LogRecorder()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .success(())
        let mockDetect = MockOccupancyDetector()
        mockDetect.result = .none
        let controller = EjectFlowController(
            ejectService: mockEject, occupancyDetector: mockDetect, log: recorder.record)

        _ = await controller.eject(disk: makeDisk())

        #expect(recorder.entries.isEmpty, "成功推出不该留日志，实际写了 \(recorder.entries.count) 条")
    }

    /// 终止占用进程后推出成功，应返回 `.ejected`。
    /// 用不存在的 PID（kill 返回 ESRCH，被视为已退出）避免真实杀进程。
    @Test func terminateAndEject关闭进程后成功推出() async {
        let disk = makeDisk()
        let mockEject = MockEjectService()
        mockEject.ejectResult = .success(())
        let mockDetect = MockOccupancyDetector()
        mockDetect.result = .none  // 复检认为已无占用
        let controller = EjectFlowController(ejectService: mockEject, occupancyDetector: mockDetect)

        let processes = [OccupyingProcess(pid: 9_999_999, processName: "Ghost", path: "")]
        let result = await controller.terminateAndEject(disk: disk, processes: processes)

        guard case .ejected = result else {
            Issue.record("期望 ejected，实际 \(result)")
            return
        }
        #expect(mockEject.ejectCalled)
    }

    // MARK: busyMessage

    @Test func busyMessage带进程时返回引导句不含进程列表() {
        let controller = EjectFlowController()
        let disk = makeDisk()
        let processes = [OccupyingProcess(pid: 42, processName: "IINA", path: "")]
        let message = controller.busyMessage(disk: disk, occupying: processes)
        // 引导句是设计稿"推出确认对话框"的固定文案（不带磁盘名——磁盘名已放在弹窗标题里）。
        let expected = L10n.tr(.ejectBusyMessageFormat)
        #expect(message == expected)
        #expect(!message.contains("PID"), "弹窗正文不应再拼 PID（进程列表改由 accessoryView 渲染图标+名称）")
    }

    @Test func busyMessage无进程时提示授权() {
        let controller = EjectFlowController()
        let disk = makeDisk()
        let message = controller.busyMessage(disk: disk, occupying: [])
        let expected = String(format: L10n.tr(.ejectBusyNoProcessInfo), "测试盘")
        #expect(message == expected)
    }

    // MARK: failureMessage

    /// 卷名为空时 `displayName` 回落到 bsdName，正文与标题都必须用这个回落值。
    ///
    /// **为什么用 `.notFound` 而不是 `.inUse`**：`.inUse` 的文案已按设计稿改成不带磁盘名
    /// （盘名归标题），拿它验证「回落」会得到永远成立的假绿。`.notFound` 的正文里带盘名，
    /// 才真的能验证回落。
    @Test func failureMessage卷名为空时回退到bsdName() {
        let controller = EjectFlowController()
        let disk = DiskInfo(
            id: "/Volumes/TEST", bsdName: "disk4s2", volumeName: "",
            mountPath: "/Volumes/TEST", totalBytes: 0, usedBytes: 0, freeBytes: 0,
            deviceProtocol: "USB", deviceModel: nil
        )

        let message = controller.failureMessage(disk: disk, failure: .notFound)
        let expected = String(format: L10n.tr(.ejectFailedNotFoundReason), "disk4s2")
        #expect(message == expected)
    }

    @Test func failureMessage按失败原因给出不同文案() {
        let controller = EjectFlowController()
        let disk = makeDisk()

        let busy = controller.failureMessage(disk: disk, failure: .inUse)
        let gone = controller.failureMessage(disk: disk, failure: .notFound)

        #expect(busy != gone, "不同失败原因必须给出不同引导，不能都显示同一句")
        #expect(busy == L10n.tr(.ejectFailedInUseReason))
    }

    /// 正文不再重复磁盘名：设计稿文案原则是「标题带磁盘名」，正文那一行留给「怎么解决」。
    /// 早前正文写的是「磁盘 "Samsung T7" 正被其他程序使用…」，与标题重复报同一个盘名。
    @Test func 被占用时正文不重复磁盘名() {
        let controller = EjectFlowController()
        let message = controller.failureMessage(disk: makeDisk(name: "Samsung T7"), failure: .inUse)
        #expect(!message.contains("Samsung T7"), "盘名只该出现在标题里，实际正文：\(message)")
    }

    // MARK: EjectFailure.possibleCauses（设计稿 03-eject-flow.html B 变体）

    /// 设计稿给「被占用」这一类列了两条原因，其中一条专门讲 Spotlight 索引 ——
    /// 这是最容易被误判为「程序卡住」的情形（用户会反复点重试），必须出现在清单里。
    @Test func 被占用时给出可执行的原因清单() {
        let causes = EjectFailure.inUse.possibleCauses
        #expect(causes.count == 2)
        #expect(causes.contains { $0.contains("Spotlight") }, "缺少「Spotlight 正在建立索引」这条")
        #expect(causes.allSatisfy { !$0.isEmpty })
    }

    /// 「系统不允许」是最让人困惑的一类失败（用户会反复重试），也要给清单。
    @Test func 系统不允许时也给出原因清单() {
        #expect(EjectFailure.notPermitted.possibleCauses.count == 2)
    }

    /// 原因句本身已经把话说完了的分类不再凑一屏清单 —— 空数组表示 UI 只显示原因句与日志提示。
    @Test func 原因已明确的分类不再给清单() {
        #expect(EjectFailure.notFound.possibleCauses.isEmpty)
        #expect(EjectFailure.other("boom").possibleCauses.isEmpty)
    }

    /// 清单走本地化表，缺一档就会中英混排。
    @Test func 原因清单三语都不为空() {
        let keys: [L10n.Key] = [
            .ejectFailedCausesTitle, .ejectFailedCauseFileOpen, .ejectFailedCauseSpotlight,
            .ejectFailedCauseNotRemovable, .ejectFailedCauseSystemHold,
            .ejectFailedTitleFormat, .ejectBusyOccupiedHeaderFormat, .ejectBusyIrreversibleCaption,
        ]
        for identifier in ["zh-Hans", "zh-Hant", "en"] {
            let locale = Locale(identifier: identifier)
            for key in keys {
                #expect(!L10n.tr(key, locale: locale).isEmpty, "\(key.rawValue) 缺 \(identifier)")
            }
        }
    }

    // MARK: 弹窗内容契约（设计稿 03-eject-flow.html）
    //
    // 弹窗是自绘的，文案没法像 `NSAlert.messageText` 那样直接读。所以断言打在
    // ``EjectAlertModel`` 上 —— 它是纯数据，不渲染、不驱动窗口，照样能把
    // 「标题带不带盘名」「清单有没有」「按钮是哪个」这些契约钉死。

    /// 标题必须带磁盘名：多块盘时用户要能确认操作对象没选错（设计稿文案原则）。
    @MainActor
    @Test func 失败弹窗标题带磁盘名() {
        let model = EjectAlertModel.failure(disk: makeDisk(name: "Samsung T7"), failure: .inUse)
        #expect(
            model.title.contains("Samsung T7"),
            "标题必须出现磁盘名，实际：\(model.title)")
    }

    /// 按钮是「查看日志」+「好」，且「好」是默认按钮 —— 否则回车会直接打开访达打断用户。
    @MainActor
    @Test func 失败弹窗按钮是查看日志加好() {
        let model = EjectAlertModel.failure(disk: makeDisk(), failure: .inUse)
        #expect(model.actions.map(\.title) == [L10n.tr(.viewLog), L10n.tr(.okAcknowledge)])
        #expect(model.actions.map(\.choice) == [.viewLog, .dismiss])
        #expect(model.actions.first(where: \.isDefault)?.choice == .dismiss, "默认按钮应是「好」")
        #expect(!model.actions.contains { $0.isCancel }, "失败弹窗没有取消路径")
    }

    /// 「可能的原因」必须成区块出现在正文与提示块**之间** —— 这是设计稿的信息层级。
    @MainActor
    @Test func 失败弹窗有原因清单区块与日志提示块() {
        let model = EjectAlertModel.failure(disk: makeDisk(), failure: .inUse)
        guard case .causes(let label, let items) = model.section else {
            Issue.record("期望原因清单区块，实际：\(String(describing: model.section))")
            return
        }
        #expect(label == L10n.tr(.ejectFailedCausesTitle))
        #expect(items.count == 2)
        #expect(model.callout?.kind == .info, "日志提示是信息块，不是警示块")
        #expect(model.callout?.text == L10n.tr(.ejectFailedLoggedHint))
    }

    /// 没有清单可给的分类不硬凑空标题，但仍要保留日志提示块（失败必须留痕）。
    @MainActor
    @Test func 无清单的分类只显示日志提示() {
        let model = EjectAlertModel.failure(disk: makeDisk(), failure: .notFound)
        #expect(model.section == nil)
        #expect(model.callout?.text == L10n.tr(.ejectFailedLoggedHint))
    }

    /// 占用弹窗：破坏性按钮标红、默认按钮是「关闭并推出」、「取消」是逃生口，
    /// 操作区左侧带「此操作不可撤销」小标。
    @MainActor
    @Test func 占用弹窗按钮与不可撤销小标() {
        let model = EjectAlertModel.busy(
            disk: makeDisk(),
            occupying: [
                OccupyingProcess(pid: 1234, processName: "IINA", path: "")
            ])
        #expect(model.actions.map(\.variant) == [.outline, .danger], "破坏性按钮必须标红")
        #expect(model.actions.map(\.choice) == [.cancel, .closeAndEject])
        #expect(model.actions.first(where: \.isDefault)?.choice == .closeAndEject, "回车即确认")
        #expect(model.actions.first(where: \.isCancel)?.choice == .cancel, "Esc 是逃生口")
        #expect(model.footNote == L10n.tr(.ejectBusyIrreversibleCaption))
    }

    /// 进程行必须同时给出应用名与 PID，且条数写进分组头。
    @MainActor
    @Test func 占用弹窗进程区块含应用名与PID() {
        let processes = [
            OccupyingProcess(pid: 1234, processName: "IINA", displayName: "IINA", path: ""),
            OccupyingProcess(pid: 5678, processName: "tail", displayName: "tail", path: ""),
        ]
        let model = EjectAlertModel.busy(disk: makeDisk(), occupying: processes)
        guard case .processes(let label, let items) = model.section else {
            Issue.record("期望进程区块，实际：\(String(describing: model.section))")
            return
        }
        #expect(label == String(format: L10n.tr(.ejectBusyOccupiedHeaderFormat), 2))
        #expect(items.map(\.displayName) == ["IINA", "tail"])
        #expect(items.map(\.pid) == [1234, 5678])
    }

    /// 无法列出进程时（未授予完全磁盘访问）不给空区块，说明句本身已带授权引导。
    @MainActor
    @Test func 无法列出进程时不给空区块() {
        let model = EjectAlertModel.busy(disk: makeDisk(), occupying: [])
        #expect(model.section == nil)
        #expect(model.subtitle.contains("完全磁盘访问"))
    }

    /// 警示必须写清动作序列（设计稿文案原则），且与 ``EjectFlowController/terminateAndEject``
    /// 的真实三步一致：SIGTERM → 等 1.5s → SIGKILL → 普通重试。
    /// 改实现忘改文案，或反过来，都会让这句承诺变成假话。
    @MainActor
    @Test func 占用弹窗警示写清动作序列() {
        let text = EjectUI.busyWarningText
        #expect(text.contains(L10n.tr(.appName)), "品牌名应走本地化，而不是硬编码 DiskEjector")
        #expect(text.contains("正常退出"), "缺少第一步「先请求正常退出」")
        #expect(text.contains("强制结束"), "缺少第二步「强制结束」")
        #expect(text.contains("重新尝试推出"), "缺少第三步「重新尝试推出」")
        #expect(!text.contains("%@"), "格式化占位符必须已被替换")
    }

    // MARK: 弹窗版式契约

    /// 版式（宽 / 逐块高 / 行高 / 图标列）的契约集中在 `AlertLayoutTests`。
    ///
    /// **为什么搬走**：原先这里只有一条「总高 ±12pt」的断言。它看着很稳，实际**掩盖了两处
    /// 十几 pt 的偏差** —— 一是基准值本身取自「设计稿图标还没水合」时的量测（312 而非 330），
    /// 二是 ±12 的容差刚好兜住了 B 变体少掉的 11pt。逐块断言才拦得住这类偏差。

    // MARK: 弹窗窗口（自绘弹窗最容易漏的两步）

    /// 无边框窗口默认**不能**成为 key window，于是回车 / Esc / 按钮点击会全部失效 ——
    /// 这是自绘弹窗最容易漏的一步。同时 `canBecomeMain` 必须保持 false：
    /// 弹窗不该被当成主窗口（会顶掉主窗口的标题栏与菜单行为）。
    @MainActor
    @Test func 弹窗窗口能成为key但不是主窗口() {
        let panel = EjectAlertPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        #expect(panel.canBecomeKey, "不能成为 key → 回车/Esc/点击全都失效")
        #expect(!panel.canBecomeMain)
    }

    /// 窗口配置逐条钉住：这些都是「删掉也不会让任何断言变红、但界面会静默坏掉」的设置。
    ///
    /// **不真的把窗口显示出来**：那会弹窗抢走用户焦点，`swift test` 不该有这个副作用。
    /// 真正的上屏验证走 `DiskEjectorApp --preview-alerts`（会打印 key / 上屏 / 尺寸 / 圆角）。
    @MainActor
    @Test func 弹窗窗口的透明圆角配置() {
        let model = EjectAlertModel.failure(disk: makeDisk(), failure: .inUse)
        let hosting = NSHostingController(rootView: EjectAlertView(model: model, onAction: { _ in }))
        let panel = EjectAlertPresenter.shared.makePanel(hosting: hosting, height: 314, title: model.title)

        #expect(panel.styleMask.contains(.borderless), "自绘弹窗不能带系统标题栏")
        #expect(!panel.isOpaque, "不透明窗口会把圆角外的区域填成白色")
        #expect(panel.backgroundColor == .clear, "窗口底色必须清掉，否则圆角外露出白底")
        #expect(panel.hasShadow, "弹窗要有投影才有浮层感（设计稿 e3）")
        #expect(panel.contentView?.layer?.cornerRadius == DesignTokens.Radius.lg, "窗口圆角 14")
        #expect(panel.contentView?.layer?.masksToBounds == true, "不遮罩则阴影按矩形算")
        #expect(panel.title == model.title, "无边框窗口没有标题栏，VoiceOver 只能从这里拿标题")
        #expect(panel.frame.width == DesignTokens.Size.alertWidth)
        // **`NSPanel` 的默认值与 `NSWindow` 不同**：`hidesOnDeactivate` 默认是 `true`，
        // 于是「应用一失去焦点，弹窗就被系统从屏幕上摘掉」—— 用户 2026-09-16 报告
        // 「点别处弹窗就被遮挡了」，根因就是它。这条断言是那个坑的唯一守卫。
        #expect(!panel.hidesOnDeactivate, "失焦隐藏 → 用户点一下别的窗口，弹窗就从屏幕上消失了")
        // 切 Space / 别的应用进全屏时，弹窗也得跟着用户走（同一诉求的另一半）。
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces), "切 Space 后弹窗会留在原地")
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary), "别的应用全屏时弹窗会被压在下面")
    }

    /// Esc 的兜底出口：`cancelOperation(_:)` 是 AppKit 在 Esc 时的标准入口，
    /// 挂在这里可以保证「无论焦点在哪，Esc 都能退出」。
    @MainActor
    @Test func 弹窗Esc走cancelOperation出口() {
        let panel = EjectAlertPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        var cancelled = false
        panel.onCancel = { cancelled = true }
        panel.cancelOperation(nil)
        #expect(cancelled)
    }

    /// 每个弹窗必须**恰好**有一个默认按钮（回车）—— 两个默认按钮会让回车行为不确定。
    @MainActor
    @Test func 每个弹窗恰好一个默认按钮() {
        let busy = EjectAlertModel.busy(disk: makeDisk(), occupying: [])
        let failure = EjectAlertModel.failure(disk: makeDisk(), failure: .inUse)
        for model in [busy, failure] {
            #expect(model.actions.filter(\.isDefault).count == 1, "\(model.title)")
        }
    }
}
