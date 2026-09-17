import AppKit
import SwiftUI

/// 承载自绘推出弹窗的无边框窗口。
///
/// **为什么不用 `NSAlert`**：设计稿 `03-eject-flow.html` 把弹窗的版式写成了硬规格
/// （图标 38×38 圆角 10 在左、标题 15/600 左对齐、进程行高 29 带奇数行底色、
/// 警示块圆角 6、操作区下沉 54）。`NSAlert` 的排版顺序与样式由系统决定 ——
/// 图标居中、标题居中、没有提示块、按钮是系统胶囊，**一样都给不了**。
/// 要落地这份设计稿只能自绘。
///
/// **为什么 `canBecomeKey` 要覆盖**：无边框窗口（`.borderless`）默认不能成为 key window，
/// 于是回车 / Esc / 按钮点击都会失效。这是自绘弹窗最容易漏的一步。
@MainActor
final class EjectAlertPanel: NSPanel {

    /// Esc 的兜底出口。
    ///
    /// **为什么除了 SwiftUI 的 `.cancelAction` 还要这一层**：`.keyboardShortcut(.cancelAction)`
    /// 依赖 SwiftUI 把快捷键注册到窗口的 key equivalent 上，而自绘的无边框窗口
    /// 未必走同一条路径。`cancelOperation(_:)` 是 AppKit 在 Esc 时的标准入口，
    /// 挂在这里可以保证「无论焦点在哪，Esc 都能退出」—— 逃生口不能有前提条件。
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 与 ``KeySilentWindow`` 同一条规则：**没人接管的按键不敲钟**。
    ///
    /// **为什么不能像另外三个窗口那样直接继承**：本类必须继承 `NSPanel`
    /// （`hidesOnDeactivate` 的默认值与 `NSWindow` 相反、且面板有自己的一套行为），
    /// 而 Swift 是单继承 —— `NSPanel` 与 `KeySilentWindow` 二选一。
    /// 所以规则抽成 `KeySilentWindow.shouldSwallowSilently(_:)` 让两边共用，避免各写一份后漂移。
    ///
    /// 弹窗里更常见的是「焦点在按钮上时按了别的键」，那同样该安静地忽略。
    /// Esc 走的是 `cancelOperation(_:)`（见上），在到达兜底**之前**就被接走，不受影响。
    override func noResponder(for eventSelector: Selector) {
        if KeySilentWindow.shouldSwallowSilently(eventSelector) { return }
        super.noResponder(for: eventSelector)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// 自绘推出弹窗的宿主：负责窗口生命周期，并把「用户点了哪个按钮」异步交回调用方。
///
/// **为什么是 async 而不是 `runModal()`**：`runModal()` 会阻塞主线程，
/// 弹窗就没法被离屏渲染、也没法被测试驱动（这正是当初把 ``EjectUI`` 的
/// 「构建弹窗」与「运行弹窗」拆开的理由）。现在换成挂起等待，
/// 调用方写起来仍是顺序的：`let choice = await presenter.present(model)`。
@MainActor
final class EjectAlertPresenter {

    static let shared = EjectAlertPresenter()

    private var continuation: CheckedContinuation<EjectAlertChoice, Never>?
    private var window: EjectAlertPanel?

    private init() {}

    /// 当前是否已有弹窗在等用户回应。
    var isPresenting: Bool { continuation != nil }

    /// 当前弹窗是否已经真正成为 key window。
    ///
    /// **为什么要暴露这个**：`makeKeyAndOrderFront` 是异步生效的，紧接着查必然是 false；
    /// 而「上屏」和「抢到焦点」之间还有一小段窗口期。自检脚本要等到它稳定为 true 再断言，
    /// 否则会把中间态打成 `key=false` —— 而回车明明还能用，输出自相矛盾。
    var isKeyWindow: Bool { window?.isKeyWindow ?? false }

    /// 展示弹窗并挂起，直到用户做出选择。
    ///
    /// - Returns: 用户点下的那个按钮对应的 ``EjectAlertChoice``。
    func present(_ model: EjectAlertModel) async -> EjectAlertChoice {
        // 同一时刻只允许一个弹窗：前一个按「取消」收场，避免两个窗口叠在一起
        // （菜单栏与主窗口共用本类，理论上可能同时触发）。
        if isPresenting { respond(.cancel) }

        let view = EjectAlertView(model: model, accent: currentAccent) { [weak self] choice in
            self?.respond(choice)
        }
        let hosting = NSHostingController(rootView: view)
        // 用 `sizeThatFits(in:)` 而不是 `fittingSize`：前者尊重传入的宽度约束，
        // 后者返回的是**无宽度约束的理想尺寸**（宽度不生效），会让高度算错。
        let height = hosting.sizeThatFits(
            in: CGSize(width: DesignTokens.Size.alertWidth, height: CGFloat.greatestFiniteMagnitude)
        ).height

        let panel = makePanel(hosting: hosting, height: height, title: model.title)
        window = panel

        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// 自检：把当前弹窗窗口的状态打到终端。
    ///
    /// **为什么需要**：离屏出图渲染的是一张图，**没有窗口** ——
    /// 「窗口能不能成为 key（决定回车/Esc/点击是否生效）、有没有真的上屏、
    /// 尺寸与层级对不对」这些只有真机跑起来才知道。`--preview-alerts` 用它做验证。
    func dumpWindowState(label: String) {
        guard let window else {
            print("  ⚠️ \(label)：没有窗口")
            return
        }
        print(
            "  \(label)：key=\(window.isKeyWindow) 上屏=\(window.isVisible) "
                + "层级=\(window.level.rawValue) 可成为key=\(window.canBecomeKey) "
                + "尺寸=\(Int(window.frame.width))×\(Int(window.frame.height)) "
                + "圆角=\(window.contentView?.layer?.cornerRadius ?? 0) "
                + "应用前台=\(NSApp.isActive)"
        )
        // 失焦即隐藏是 `NSPanel` 的**默认**行为（`NSWindow` 是 false）——
        // 打印出来，`--preview-alerts-keys` 才能守住「点别处弹窗不会消失」。
        print(
            "    失焦隐藏=\(window.hidesOnDeactivate)（必须 false） "
                + "collectionBehavior=\(window.collectionBehavior.rawValue)"
        )
    }

    /// 结束当前弹窗（若没有弹窗则什么都不做）。
    func respond(_ choice: EjectAlertChoice) {
        guard let continuation else { return }
        self.continuation = nil
        window?.orderOut(nil)
        window = nil
        continuation.resume(returning: choice)
    }

    // MARK: - 组装窗口

    /// 组装承载弹窗的无边框窗口。
    ///
    /// 设为 `internal` 是为了让单测能直接断言窗口配置 —— 这几行里每一条去掉都会**静默**劣化：
    /// 少了 `backgroundColor = .clear` 圆角外会露出白底、少了 `layer.cornerRadius`
    /// 阴影会按矩形算、少了 `canBecomeKey` 键盘直接失效，而三者都不会让任何断言变红。
    /// **单测只断言配置，不真的 `makeKeyAndOrderFront`** —— 那会弹窗抢走用户焦点。
    func makePanel(
        hosting: NSHostingController<EjectAlertView>, height: CGFloat, title: String
    )
        -> EjectAlertPanel
    {
        let size = NSSize(width: DesignTokens.Size.alertWidth, height: height)
        let panel = EjectAlertPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        panel.contentViewController = hosting
        panel.setContentSize(size)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 浮在普通窗口之上，但不抢系统级焦点（`.modalPanel` 不会盖住系统弹窗）。
        panel.level = .modalPanel
        // ⚠️ **必须显式关掉 `hidesOnDeactivate`**（2026-09-16 用户报告「点别处弹窗就没了」）。
        //
        // `NSPanel` 的默认值是 **`true`**，而 `NSWindow` 是 `false` —— 这是 `NSPanel`
        // 与 `NSWindow` 之间一个**默认值就不同**的坑。文档写得很直白：
        // "When the value of this property is `true`, the window is **removed from the screen**
        //  when its application is deactivated"，并且 "This property is used only for panels"。
        //
        // 后果正是用户描述的现象：被占用的磁盘弹窗出现后，用户点一下别的窗口
        // （应用失去焦点）→ 系统把弹窗**从屏幕上摘掉**。而它是 `async` 挂起等用户回应的，
        // 用户以为「弹窗被遮挡了」，实际上它已经不在屏幕上了，而这次推出还悬在那里。
        panel.hidesOnDeactivate = false
        // 同一诉求的另外两个漏洞：切 Space、或别的应用进了全屏，弹窗会被留在原来的空间里。
        // `.canJoinAllSpaces` 让它跟着用户走，`.fullScreenAuxiliary` 允许它浮在全屏应用之上。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        // 无边框窗口没有标题栏，VoiceOver 只能从这里拿到「这是什么弹窗」。
        panel.title = title
        panel.onCancel = { [weak self] in self?.respond(.cancel) }
        // **圆角窗口的关键**：光靠 SwiftUI 的 `clipShape` 只裁内容，
        // 窗口自身的阴影仍按矩形算。给 contentView 的 layer 设圆角 + 遮罩，
        // 阴影才会跟着圆角走（与主窗口 `ContentView` 同一套做法）。
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = DesignTokens.Radius.lg
        panel.contentView?.layer?.masksToBounds = true
        panel.center()
        return panel
    }

    /// 当前强调色（设置里可改，弹窗的提示块与主按钮都跟着它走）。
    private var currentAccent: AccentColor {
        AccentColor(rawValue: UserDefaults.standard.string(forKey: AppSettings.Key.accentColor) ?? "")
            ?? .default
    }
}
