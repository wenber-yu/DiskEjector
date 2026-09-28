import AppKit
import SwiftUI
import Testing

@testable import DiskEjectorApp

/// 设置面板的**排版契约**测试。
///
/// **为什么需要**：面板高度是常量，六段内容的自然高度却随文案与内边距变化。
/// 历史上两者脱节（内容约 718pt vs 面板 520pt），结果是「关于 / 更新」两段被折叠线
/// 挡在滚动区外 —— 用户打开设置看不到它们，反馈为「设置界面排版不好看」。
/// 光靠人眼打开面板看一遍发现不了「几乎溢出」，所以把三件事钉成测试：
/// ① 头部 + 六段内容 + 底部留白 必须 ≤ 面板高度（放不下就会有内容被藏）；
/// ② 面板高度也不许虚高（差距超过一行就该同步收窄 token，而不是留一片空白）；
/// ③ 分隔线只出现在**段与段之间**（第一段上方不该有一条线顶着头部）。
///
/// 高度断言用「≤」而不是「==」：中文与英文文案长度不同，折行数可能不同，
/// 只要**任何语言下都放得下**就成立（`SettingsView` 仍保留 `ScrollView` 兜底）。
@MainActor
struct SettingsLayoutTests {

    private let panelWidth = DesignTokens.Size.settingsPanel.width

    /// 本文件量高度时**统一注入**的「接管闸门」状态 —— 与设计稿同一版（开关可用）。
    ///
    /// ## 为什么每一处都必须显式写
    ///
    /// 这个值的真值来自**本机的 TCC 状态**（谁给没给完全磁盘访问），而它取决于
    /// 跑测试的那个进程 —— xctest 的责任方是拉起它的终端。不注入的话，
    /// 同一份高度契约会在有授权的机器上量到一版、没授权的机器上量到另一版，
    /// **红绿都与被测代码无关**。
    ///
    /// ## 为什么选 `.usable` 而不是 `.needsFullDiskAccess`
    ///
    /// 因为**它才是设计稿画的版本**（`05-settings.html` 那一行是开关），
    /// 而本文件所有绝对值断言（900.20 / 916.20）都是拿设计稿对齐过的。
    /// 未授权那一版由 ``接管未授权态不得比可用态更高()`` 单独量，判据是**相对比较**、
    /// 不依赖绝对数 —— 于是它换台机器也成立。
    private let designTakeOver: AppSettings.TakeOverAvailability = .usable

    /// 「更新」组那两个开关**设计稿假设的环境**：具备能力 + 检查开 + 下载关。
    ///
    /// **与上面 `designTakeOver` 同一个理由、同一个毛病**：这两个开关的值来自 Sparkle、
    /// 「具不具备能力」来自 updater 建没建起来，而 xctest 进程里 updater 建不起来
    /// ⇒ 不注入的话，本文件量到的是**永远禁用态**那一版 —— 而真机上用户看到的是**可用态**，
    /// 设计稿画的也是可用态（`05-settings.html` / `08-update.html` 里开关是能拨的）。
    ///
    /// ⚠️ **下载取 `false`**：它是 Sparkle 的默认（`SUAutomaticallyUpdate` 没写），
    /// 也就是真机上**没拨过开关**的用户看到的样子 —— 面板高度只该由这个默认态决定。
    ///
    /// ⚠️ **别把它改成「全部为 true」**：那会把「下载也开着」混进定高的输入里。
    /// 「下载开着」「不具备能力」「检查没开」这三态由
    /// ``更新两行各态渲染出来必须一样高()`` 与 ``更新两行不可用态不得比可用态更高()``
    /// 以**相对比较**覆盖（不依赖绝对值，换台机器也成立）。
    private let designAutoUpdateRows = AutoUpdateRowsState(
        canAutoUpdate: true, checksIsOn: true, downloadsIsOn: false)

    /// 在给定宽度下渲染并返回**真实渲染尺寸**（走 SwiftUI 布局，不是读常量）。
    ///
    /// ⚠️ **必须用 `sizeThatFits(in:)`，不能用 `setFrameSize + fittingSize`**（2026-09-15 修正）。
    /// `NSHostingView.fittingSize` 返回的是**无宽度约束的理想尺寸** —— 宽度根本没生效。
    /// 实测同一份内容：`fittingSize` 报 `497×470`（宽度 497 ≠ 传入的 440），
    /// `sizeThatFits(in: 440×∞)` 报 `440×484`。
    ///
    /// 这个差别**恰好掩盖了一整类缺陷**：内容横向放不下时，弹性列（设置行的标签列）
    /// 会被压窄、文字改竖排，高度随之暴涨 —— 但理想尺寸里没有这回事，高度看着一直正常。
    /// 旧写法因此让「视觉效果」那行被压成竖排单字、内容真实高度 910pt 而面板只有 498pt
    /// 可用（45% 内容被卷走）长达一整个版本没被发现。
    ///
    /// 手法可靠性用**已知高度的磁盘行**做过对照（真值 158pt）：
    /// `sizeThatFits` → 158 ✓ ／ `fittingSize` → 158（高度对但宽度错）／ 位图扫描 → 369 ✗
    /// （`bitmapImageRepForCachingDisplay` 的缓冲区不保证清零，会扫到未初始化内存）。
    ///
    /// ⚠️ **在中文下渲染**：本文件断言的面板尺寸（480×920）是**按中英实测**出来的，
    /// 其中宽度按英文定、高度按英文 782.6 + 余量定。
    /// 不钉就跟随 `Locale.current` → 英文机器上必红（2026-09-17 CI 连续 6 次红即此因）。
    /// 英文下的表现由本文件的 ``英文下也必须放得下()`` 覆盖。
    ///
    /// ⚠️ **`view` 必须是 `@autoclosure`**：实参表达式在**进入本函数之前**求值，
    /// 而它可能含 `L10n.tr`（分区标题、行标签 …），不推迟求值就会解析成 `Locale.current` 的
    /// 那一版，钉住渲染也救不回来。理由同 `OnboardingLayoutTests.renderedSize`。
    private func renderedSize<V: View>(
        _ view: @autoclosure () -> V,
        width: CGFloat,
        language: String = TestLanguage.design
    ) -> CGSize {
        TestLanguage.with(language) {
            _ = NSApplication.shared
            let hosting = NSHostingController(rootView: view())
            return hosting.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        }
    }

    /// 渲染成位图后，统计**卡片内部的行间分隔线**条数。
    ///
    /// **为什么不能用「整行都有 alpha」来判定**：v2 的设置项放在 `.scard` 里
    /// （`bg-raised` 实心填充），卡片内**每一行**都是不透明的 —— 按老办法会把
    /// 卡片的每一行都数成分隔线（实测 298 条）。
    ///
    /// 现在的判据是「**相对上下都变暗、且横向均匀**」：
    /// - 分隔线是 8% 黑叠在白色卡片上 → 比上下都暗一点点，且横向亮度方差接近 0；
    /// - 卡片填充行 → 与上下同色，不构成凹陷；
    /// - 文字行 → 横向亮度方差很大（黑字 + 白底），被方差条件排除；
    /// - 卡片自身的圆角描边行 → 上下相邻行里有一行落在卡片外（覆盖率不足），被邻居条件排除。
    private func horizontalDividerCount(_ view: some View, width: CGFloat) -> Int {
        // ⚠️ **出图必须与「量高度」钉在同一种语言下**（2026-09-28 修，CI 红）。
        //
        // `renderedSize` 内部已经 `TestLanguage.with(TestLanguage.design)`（理由见它的注释：
        // 设计稿数字全按中文实测）。但**出图这一半当时漏了**，于是成了
        // 「量高度按中文、画图跟随 `Locale.current`」的错配：
        //   - 本地开发机 `Locale.current` 就是 `zh-Hans` ⇒ 两者一致 ⇒ 一直绿；
        //   - CI（runner 系统语言英文）画出来的是英文版 ⇒ 行高不同 ⇒ 少判一条线。
        // 实测（2026-09-28，CI run `36382577179`）：不钉 → `count=4`；钉住 → `count=5`（期望值正好 5）。
        // ⇒ 与 `renderedSize` 同源，别让「量一半、画一半」再分家。
        return TestLanguage.with(TestLanguage.design) {
            // 高度取 `sizeThatFits` 的**真实**高度（理由见 `renderedSize` 注释）：
            // 用 `fittingSize` 会拿到偏小的理想高度，把内容底部裁掉，
            // 万一分隔线正好落在被裁区域就会漏数。
            let realHeight = renderedSize(view, width: width).height
            // ⚠️ **高度向上取整**：`OffscreenRender.bitmap` 按 `Int(size.height * 2)` **截断**，
            // 传 773.4 只拿到 1546px（差 0.8pt 不足），底部那条线有被裁的风险。
            guard
                let rep = OffscreenRender.bitmap(
                    view,
                    size: CGSize(width: width, height: realHeight.rounded(.up)),
                    // ⚠️ **背景必须 `.clear`，不能垫白**：判据靠「卡片外那一行覆盖率不足」
                    // 排除卡片自身的圆角描边（见上面那段注释）。垫白底会让卡片之间也变成
                    // 不透明 ⇒ 描边行的上下邻居覆盖率也过线 ⇒ 多判出线。
                    background: .clear)
            else { return -1 }
            return dividerCount(in: rep, width: width)
        }
    }

    /// 从一张已画好的位图里数分隔线。**只判读、不出图** ——
    /// 出图一律走 ``OffscreenRender/bitmap(_:size:appearance:background:)``（SPEC §8.131，
    /// 自建位图会被 `PixelReadPathTests` 拦）。
    private func dividerCount(in rep: NSBitmapImageRep, width: CGFloat) -> Int {
        guard let data = rep.bitmapData else { return -1 }

        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let bpr = rep.bytesPerRow
        let spp = rep.samplesPerPixel

        /// 逐行统计：覆盖率（alpha > 8 的像素占比）与不透明像素的亮度均值/标准差。
        func rowStats(_ y: Int) -> (coverage: Double, luma: Double, std: Double) {
            var opaque = 0
            var covered = 0
            var sum = 0.0
            var sumSq = 0.0
            for x in 0..<w {
                let p = y * bpr + x * spp
                let a = data[p + 3]
                if a > 8 { covered += 1 }
                guard a > 200 else { continue }
                let luma =
                    0.2126 * Double(data[p]) + 0.7152 * Double(data[p + 1])
                    + 0.0722 * Double(data[p + 2])
                opaque += 1
                sum += luma
                sumSq += luma * luma
            }
            guard opaque > 0 else { return (Double(covered) / Double(w), 0, 0) }
            let mean = sum / Double(opaque)
            let variance = max(0, sumSq / Double(opaque) - mean * mean)
            return (Double(covered) / Double(w), mean, variance.squareRoot())
        }

        let stats = (0..<h).map(rowStats)
        let gap = 4
        var dividerRows: [Int] = []
        for y in gap..<(h - gap) {
            guard stats[y].coverage > 0.85,
                stats[y - gap].coverage > 0.85,
                stats[y + gap].coverage > 0.85
            else { continue }
            // 横向必须均匀（排除文字行），且比上下都暗（排除填充行）。
            guard stats[y].std < 2.5,
                stats[y].luma < stats[y - gap].luma - 1,
                stats[y].luma < stats[y + gap].luma - 1
            else { continue }
            dividerRows.append(y)
        }
        // 相邻像素行合并成一条线。
        //
        // ⚠️ **不能用 `y != previous + 1` 这种「严格相邻」判据**（2026-09-15 修正）。
        // 一条 0.5pt 的分隔线在 scale=2 的位图里是 1 个像素，但**抗锯齿会把它的
        // 上下各染一个半透明像素**，实测三行的亮度是 `250.95 / 238.95 / 250.95`
        // （上下两行只比卡片底色 254.95 暗 4）。这三行**全都**满足「比上下都暗」
        // 的判据，于是进入 `dividerRows`。旧写法只在计数时推进 `previous`，
        // 遇到 `[246, 247, 248]` 会数成 2 条（246 计一次、247 被吞、248 又计一次）——
        // 两根真实分隔线被数成 4 条，测试报「多画了线」而产品其实完全正确。
        //
        // 正确判据是「**与上一条线的距离超过一根线的像素跨度**」：
        // 同一根线内部的行间隔 ≤ 2 个像素，而真实两根线至少隔着一个行高（≈44pt ≈ 88px）。
        // 阈值取 `4 × scale`（2pt）—— 远大于抗锯齿跨度、远小于行高，中间有两个数量级的余量。
        let scale = max(1, w / max(1, Int(width)))
        let mergeGap = 4 * scale
        var count = 0
        var previous = -1_000
        for y in dividerRows {
            if y - previous > mergeGap { count += 1 }
            previous = y
        }
        return count
    }

    @Test func 面板高度放得下头部与全部四组() {
        let header = renderedSize(SettingsHeaderBar(onDone: {}), width: panelWidth)
        let sections = renderedSize(
            SettingsSectionsColumn(
                autoUpdateRowsOverride: designAutoUpdateRows, takeOverAvailabilityOverride: designTakeOver
            ) { _ in }, width: panelWidth)
        let need = header.height + sections.height + SettingsMetrics.bottomInset
        #expect(
            need <= DesignTokens.Size.settingsPanel.height,
            "头部 \(header.height) + 内容 \(sections.height) + 底留白 \(SettingsMetrics.bottomInset) = \(need)pt，超过面板 \(DesignTokens.Size.settingsPanel.height)pt——多出来的部分会被折叠线藏在滚动区外（「关于」曾因此整个看不见）"
        )
    }

    @Test func 面板高度不留大片空白() {
        let header = renderedSize(SettingsHeaderBar(onDone: {}), width: panelWidth)
        let sections = renderedSize(
            SettingsSectionsColumn(
                autoUpdateRowsOverride: designAutoUpdateRows, takeOverAvailabilityOverride: designTakeOver
            ) { _ in }, width: panelWidth)
        let need = header.height + sections.height + SettingsMetrics.bottomInset
        let slack = DesignTokens.Size.settingsPanel.height - need
        #expect(
            slack >= 0 && slack <= 40,
            "面板比内容高出 \(slack)pt（超过一行）。要么把 DesignTokens.Size.settingsPanel.height 收窄到 \(need)pt，要么补内容——否则面板底部会留下一条明显的空白带"
        )
    }

    /// 英文下也必须放得下。
    ///
    /// **这条原来在 `LanguageLayoutGapTests` 里，而且是一条「已知缺陷」的锁**：
    /// 2026-09-17 实测英文需要 612.25pt、容器只有 566pt，那条测试专门断言
    /// 「英文确实放不下」，并写明「修好后它会变红，提醒你删掉它」。
    ///
    /// 2026-09-18 面板加宽到 480（临界宽度 477）+ 加高到 800 之后，它**如期变红**
    /// —— 于是按它自己写的要求，把设置面板那两条从 `LanguageLayoutGapTests` 摘掉，
    /// 英文覆盖**并入本文件**：从「记录缺陷」变成「必须通过的门槛」。
    ///
    /// （`LanguageLayoutGapTests` 没有整个删掉 —— 它还有一条**引导面板**的英文缺陷是活的。）
    @Test func 英文下也必须放得下() {
        let header = renderedSize(SettingsHeaderBar(onDone: {}), width: panelWidth, language: "en")
        let sections = renderedSize(
            SettingsSectionsColumn(
                autoUpdateRowsOverride: designAutoUpdateRows, takeOverAvailabilityOverride: designTakeOver
            ) { _ in }, width: panelWidth,
            language: "en")
        let need = header.height + sections.height + SettingsMetrics.bottomInset
        print(
            "  [设置面板] 英文需要 \(need)pt，容器 \(DesignTokens.Size.settingsPanel.height)pt"
        )
        #expect(
            need <= DesignTokens.Size.settingsPanel.height,
            "英文下头部 \(header.height) + 内容 \(sections.height) + 底留白 \(SettingsMetrics.bottomInset) = \(need)pt，超过面板 \(DesignTokens.Size.settingsPanel.height)pt —— 英文文案最长，是**最坏情况**，容器必须按它定"
        )
    }

    /// 繁中（`zh-Hant`）下也必须放得下。
    ///
    /// **为什么单列一条**（2026-09-27，架构文档 §8 待明确事项 **R3**）：
    /// 繁中的 footnote 实测 **65 字**，比简中的 52 字长，且字符串里夹着 `Finder`
    /// （拉丁字符）⇒ **折行位置与简中不同**。而上面两条只量了 `zh-Hans` 与 `en`，
    /// 繁中在测试层面**完全没被看过**（全仓搜不到任何 `zh-Hant` 的布局量测）。
    ///
    /// 而面板高度是按**英文 916.20pt** 定的 —— 距 920 只剩 **3.8pt**。
    /// 繁中只要比英文多折一行（≈15pt）就会被折叠线藏进滚动区外。
    ///
    /// ⚠️ `zh-Hant` 必须**原样**传（不能写 `zh-Hant-TW`）：`L10n.tr` 的 id 解析只按 `_`
    /// 切分，`zh-Hant-TW` 会落进 `hasPrefix("zh")` 那一支 ⇒ 拿到的是**简中**文案，
    /// 这条测试就变成了「简中的第二次复读」而看不出来。
    ///
    /// ## 实测结论（2026-09-27 首测；2026-09-28 更新）
    ///
    /// | | 中文 | 繁中 | 英文 |
    /// |---|---|---|---|
    /// | 2026-09-27 | 841.40 | **841.40** | 873.40 |
    /// | 2026-09-28（拆「自动更新」为两行后） | 900.20 | **900.20** | 916.20 |
    ///
    /// ⇒ 繁中**没有**多折一行（65 字与 52 字在 480 宽下折成同样行数），R3 的担忧不成立。
    /// ⇒ 拆行那次也没把繁中与简中拉开：三条新文案（`autoCheckUpdateHint` /
    /// `autoDownloadUpdateHint` 各 14 / 17 字，繁中同字数）折行数一致。
    ///
    /// ⚠️ **这条判据的分辨力边界**：繁中与简中的高度**逐点相同**，所以
    /// 「`language:` 传成 `zh-Hans`」这类变异它**抓不住**（两种写法量出同一个数）。
    /// 它能抓住的是「繁中没生效」—— 由函数体开头那条 `L10n.tr` 自证断言负责。
    /// 将来繁中与简中高度一旦出现差异，这条判据就自然获得分辨力。
    @Test func 繁中下也必须放得下() {
        // 自证：`zh-Hant` 真的解析出了**另一串**文案。
        //
        // 为什么必须有：繁中量出来是 900.20，与简中**逐点相同** —— 而「繁中没生效、
        // 悄悄回退成简中」与「繁中折行数恰好与简中相同」的**输出逐字相同**。
        // 这条断言把两者分开（在 `TestLanguage.with` 之外调，`forcedLocale` 为 nil，
        // 于是 `tr` 真的走传入的 `locale`）。
        #expect(
            L10n.tr(.takeOverFinderEject, locale: Locale(identifier: "zh-Hant"))
                != L10n.tr(.takeOverFinderEject, locale: Locale(identifier: "zh-Hans")),
            "繁中与简中解析出了同一串文案 —— `zh-Hant` 没生效，下面量到的其实是简中（假绿）"
        )

        let header = renderedSize(
            SettingsHeaderBar(onDone: {}), width: panelWidth, language: "zh-Hant")
        let sections = renderedSize(
            SettingsSectionsColumn(
                autoUpdateRowsOverride: designAutoUpdateRows, takeOverAvailabilityOverride: designTakeOver
            ) { _ in }, width: panelWidth,
            language: "zh-Hant")
        let need = header.height + sections.height + SettingsMetrics.bottomInset
        print(
            "  [设置面板] 繁中需要 \(need)pt，容器 \(DesignTokens.Size.settingsPanel.height)pt"
        )
        #expect(
            need <= DesignTokens.Size.settingsPanel.height,
            "繁中下头部 \(header.height) + 内容 \(sections.height) + 底留白 \(SettingsMetrics.bottomInset) = \(need)pt，超过面板 \(DesignTokens.Size.settingsPanel.height)pt —— 繁中 footnote 65 字（简中 52 字、英文 117 字符），折行数可能最多；要么压短繁中文案，要么加高面板"
        )
    }

    /// 面板尺寸的**依据**：中文必须与设计稿几乎逐点相同。
    ///
    /// 这一条是上面两条「放得下」的**前提校验**。只有「≤ 容器」时，
    /// 把内容整体缩小（字号、内边距改小）也能让断言变绿 —— 而那是排版走样，不是修好了。
    /// 所以这里钉住绝对值：**中文下实现与设计稿的差必须 ≤ 2pt**。
    ///
    /// 实测（2026-09-18，设计稿用无头 Chrome 探针量，实现用 `sizeThatFits`）：
    ///
    /// | | 中文 | 英文 |
    /// |---|---|---|
    /// | 设计稿（CSS） | 766.44 | 814.25 |
    /// | 实现（SwiftUI） | **766.60** | **782.60** |
    ///
    /// 中文差 **0.16pt** → 结构忠实；英文差 31.65pt → CSS 与 CoreText 的英文断行差异
    /// （本仓库已记为「已知不是 bug」）。
    /// ⚠️ 量设计稿时**必须先把 `.settings__body` 的 `flex: 1 1 auto` 关掉** ——
    /// 它被拉伸填满面板，直接量到的是「被撑开的高度」（面板高 − 52），不是内容自然高度。
    /// 2026-09-18 之前设计稿写的是 826（= 它自己 Chrome 口径的英文自然高 814.25 + 余量），
    /// 它对自己的渲染没错，**但对实现偏大**：照它做会在中文下留 59.4pt 空白带。
    /// → 已拍板把设计稿同步成 800（§8.43），两份文档现在同数，
    /// 由 `DesignSizeParityTests.设计稿与实现的尺寸必须同数()` 钉住（同源表第 4/5 项）。
    ///
    /// ## 2026-09-27：加「接管访达的推出」行后重测
    ///
    /// | | 中文 | 英文 |
    /// |---|---|---|
    /// | 设计稿（无头 Chrome 探针） | **841.16** | （本行未量） |
    /// | 实现（SwiftUI） | **841.40** | **874.60** |
    ///
    /// 设计稿那侧的量法与旧稿一致（`.shead` 高 + `.settings__body` 关掉 flex 后的自然高）——
    /// **同一个量法在旧稿上复现出 766.44**（与当时的期望值逐点相同），所以它不是新编的口径。
    /// 面板 800 → 876 的推导见 `DesignTokens.Size.settingsPanel` 的注释。
    ///
    /// ## 2026-09-28：「自动更新」拆成两行后重测
    ///
    /// | | 中文 | 英文 |
    /// |---|---|---|
    /// | 设计稿（`Tools/measure_settings_panel.py`） | **899.94** | （本行未量） |
    /// | 实现（SwiftUI） | **900.20** | **916.20** |
    ///
    /// 中文差 **0.26pt**（历史两次是 0.16 / 0.24pt，同一量级）⇒ 三个新文案的折行与
    /// 设计稿一致，结构忠实。
    ///
    /// ⚠️ **这一步以前是「手工跑一次探针、把数抄进这里」，2026-09-28 起有脚本了**：
    /// `Tools/measure_settings_panel.py` 会自证（`svg>0`、`readyState` 已离开 `loading`）、
    /// 选择器没命中就退出码 1。**改这段话或这段结构之后必须重跑它，不许手抄** ——
    /// 手抄的数与实现一起漂，而这条断言会一直绿（它比的是「实现 vs 这里写的数」）。
    /// 面板 876 → 920 的推导见 `DesignTokens.Size.settingsPanel` 的注释。
    @Test func 中文高度与设计稿几乎逐点相同() {
        let header = renderedSize(SettingsHeaderBar(onDone: {}), width: panelWidth)
        let sections = renderedSize(
            SettingsSectionsColumn(
                autoUpdateRowsOverride: designAutoUpdateRows, takeOverAvailabilityOverride: designTakeOver
            ) { _ in }, width: panelWidth)
        let zh = header.height + sections.height + SettingsMetrics.bottomInset
        let en =
            renderedSize(SettingsHeaderBar(onDone: {}), width: panelWidth, language: "en").height
            + renderedSize(
                SettingsSectionsColumn(
                    autoUpdateRowsOverride: designAutoUpdateRows, takeOverAvailabilityOverride: designTakeOver
                ) { _ in }, width: panelWidth,
                language: "en"
            ).height
            + SettingsMetrics.bottomInset
        print(
            "  [设置面板] 实现 中文 \(zh) / 英文 \(en) ｜ 设计稿 中文 899.94 ｜ "
                + "面板 \(DesignTokens.Size.settingsPanel.width)×\(DesignTokens.Size.settingsPanel.height)"
        )
        #expect(
            abs(zh - 899.94) <= 2,
            """
            中文下需要 \(zh)pt，设计稿实测 899.94pt。差得超过 2pt 说明**结构**变了
            （少/多一行、组间距或内边距改动），不只是英文折行差异 —— 请同步复核设计稿与面板尺寸
            （设计稿那侧用 `Tools/measure_settings_panel.py` 重量，别手抄）。
            """
        )
        // 「英文更长」是上面那条「英文是最坏情况」的前提。不成立只有两种可能：
        // ① 钉语言失效；② 英文文案缺失、`tr` 回退到中文源语言。**都不是「缺陷被修好」**。
        #expect(en > zh, "英文（\(en)）没比中文（\(zh)）高 —— 检查 L10n.forcedLocale 是否还能传到渲染")
    }

    /// 「更新」行**各态渲染出来必须一样高**。
    ///
    /// **为什么**：这一行是设置面板里**唯一**会在运行中换画法的行 ——
    /// 其余行的形态由偏好决定，只有它随事件（检查中 / 下载中 / 已就绪 / 失败…）变形。
    /// 而面板是**固定高度**的：只要有一态比别的高，切到那一态时要么多出一条空白带、
    /// 要么把最后一行挤到折叠线外（历史上「关于」整段就是这样消失的，见文件头）。
    /// 「下载中」那一态尤其危险 —— 它多画了一条轨道 + 一个百分比。
    ///
    /// ⚠️ 这条断言**与渲染机器无关**（只比各高度互相相等，不比绝对值），所以能进 CI。
    /// 各态的出图进不了 CI（`DE_SNAPSHOTS=1` 才跑）→ **光出图不补守卫等于没补**（§8.33）。
    ///
    /// ⚠️ **名字里不写数字**（原叫「七态」）：状态数会随实现增长（2026-09-19 加了
    /// 「下载中（无百分比）」那一态，2026-09-20 又加了「正在检查」与「位置不允许更新」
    /// 两态 —— 名字里若写数字，它**已经要改两次了**），写死数字的名字**每加一态就变一次假话**，
    /// 而它又是别的文档引用这个函数时的入口。数字型的名字会漂移，就说「各态」。
    /// 同理下面打印/失败消息里也一律不写数字 —— 写数字的地方迟早与清单分叉。
    @Test func 更新行各态渲染出来必须一样高() {
        let lastCheck = Date(timeIntervalSince1970: 1_789_000_000)
        func row(_ phase: UpdatePhase, skipped: String? = nil) -> UpdateController.CheckRowState {
            UpdateController.rowState(phase: phase, skippedVersion: skipped, lastCheck: lastCheck)
        }
        let states: [(String, UpdateController.CheckRowState)] = [
            ("尚未检查", UpdateController.rowState(phase: .idle, skippedVersion: nil, lastCheck: nil)),
            ("已是最新", row(.idle)),
            // 2026-09-28 加的那一态（用户报告）：「检查**失败**」与「已是最新」原先共用同一句话。
            // ⚠️ 它必须**与「已是最新」并列**，不能顶掉它 —— 两者是**相反**的两件事
            // （`UpdateController.CheckOutcome` 有说明），合并等于那句谎原地复活。
            // 文案是「上次检查：%@ · 检查失败」+「重试」按钮，也**必须有第二行**。
            (
                "检查失败",
                UpdateController.rowState(
                    phase: .idle, skippedVersion: nil, lastCheck: lastCheck, outcome: .failed)
            ),
            ("已跳过", row(.idle, skipped: "1.1.0")),
            // 2026-09-20 加的那一态（§8.93 / §8.97）：用户点了「检查更新」、
            // Sparkle 还没答的那 3~4.5 秒。它**有第二行**（`updateCheckingHint`）——
            // 少一行就会矮（§8.82 就是这么抓到「下载中（无百分比）」那一态的：矮 14.8pt）。
            ("正在检查", row(.checking)),
            ("发现新版本", row(.found(version: "1.1.0"))),
            ("下载中", row(.downloading(version: "1.1.0", fraction: 0.42))),
            // 2026-09-19 加的那一态（§8.81 / §8.82）：自动那条路的「后台下载中」。
            // 百分比**无从得知**（`fraction: nil`）⇒ 不画进度条、不给「取消」。
            // ⚠️ 它必须**与「下载中」并列**，不能顶掉它：那是两条不同的路
            // （手动检查 vs 自动），画法也不同（有进度条 vs 没有）——
            // 统一口径时把不方便的那一态删掉，就等于那一态再也没人看过（§8.33）。
            ("下载中（无百分比）", row(.downloading(version: "1.1.0", fraction: nil))),
            // 2026-09-25 拆成两格（§8.146.2）：「已就绪」在两条路上**说的话不一样** ——
            // 自动那条路是「重启后完成安装；下次退出应用时也会自动安装」，
            // 点过「后台更新并重启」那条路是「会自动重启完成安装；有磁盘正在推出时会等它结束」。
            // ⚠️ 两格都必须在清单里：**只留一格就等于另一句话再也没人量过高度**
            // （§8.33 的老毛病 —— 统一口径时把不方便的那一态删掉）。
            ("已就绪", row(.ready(version: "1.1.0", autoRestart: false))),
            ("已就绪（会自动重启）", row(.ready(version: "1.1.0", autoRestart: true))),
            ("失败", row(.failed(version: "1.1.0"))),
            // 2026-09-22 加的那一态（账本第 43 行）：**下载成功、但之后那一步失败**
            // （解压 / 验签 / 安装）。文案是「%@ 安装失败」+ 一句说明 —— 也**必须有第二行**。
            ("安装失败", row(.installFailed(version: "1.1.0"))),
            // 2026-09-20 加的那一态（§8.94 / §8.95.7）：只读卷 / App Translocation。
            // 文案是「请把应用拷到『应用程序』文件夹」+ 一句说明 —— 也**必须有第二行**。
            ("位置不允许更新", row(.locationBlocked)),
        ]

        var heights: [(String, CGFloat)] = []
        for (name, state) in states {
            let h = renderedSize(
                SettingsSectionsColumn(updateStateOverride: state, takeOverAvailabilityOverride: designTakeOver),
                width: panelWidth
            ).height
            heights.append((name, h))
        }
        let printed = heights.map { "\($0.0) \($0.1)" }.joined(separator: " ｜ ")
        print("  [更新行各态] \(printed)")

        // 判据是「**各态互相相等**」，不是「等于某个数」—— 后者会把「整体挪了 1pt」
        // 报成每一态都失败，而真正要防的是**某一态与别的不一样**。
        let first = heights[0].1
        for (name, h) in heights.dropFirst() {
            #expect(
                abs(h - first) <= 0.5,
                """
                「\(name)」渲染出来 \(h)pt，而「\(heights[0].0)」是 \(first)pt —— 各态必须一样高。
                设置面板是固定高度：某一态更高就会挤掉最后一行（或留出空白带）。
                全部各态：\(printed)
                """
            )
        }
    }

    /// 「更新」组那两个开关**各形态渲染出来必须一样高**。
    ///
    /// 与上面那条同一个理由：面板是固定高度。而这两行的说明都是**整句替换**的
    /// （检查行 `autoCheckUpdateHint` ↔ `autoUpdateUnavailableHint`；
    /// 下载行 `autoDownloadUpdateHint` ↔ `autoDownloadNeedsCheckHint` ↔ 上面那句）——
    /// 换长了就可能多折一行，把最后一行挤出折叠线。
    ///
    /// ⚠️ **名单里必须有「检查关 · 下载行说『需先打开…』」那一态**：它是唯一一态
    /// **换了文案又同时让控件变灰**的，而「文案与可点性不同源」正是这一版要防的错
    /// （见 ``更新两行不可用态不得比可用态更高()`` 与 `UpdateSettingsTests` 里那条自洽断言）。
    /// 出图清单（`SnapshotRenderTests`）与这里**各有一份**，别只补一处。
    @Test func 更新两行各态渲染出来必须一样高() {
        let states: [(String, AutoUpdateRowsState)] = [
            ("默认（具能力 · 检查开 · 下载关）", designAutoUpdateRows),
            ("检查关", AutoUpdateRowsState(canAutoUpdate: true, checksIsOn: false, downloadsIsOn: false)),
            ("两个都开", AutoUpdateRowsState(canAutoUpdate: true, checksIsOn: true, downloadsIsOn: true)),
            ("不具备能力", AutoUpdateRowsState(canAutoUpdate: false, checksIsOn: false, downloadsIsOn: false)),
        ]

        var heights: [(String, CGFloat)] = []
        for (name, state) in states {
            let h = renderedSize(
                SettingsSectionsColumn(
                    autoUpdateRowsOverride: state, takeOverAvailabilityOverride: designTakeOver),
                width: panelWidth
            ).height
            heights.append((name, h))
        }
        let printed = heights.map { "\($0.0) \($0.1)" }.joined(separator: " ｜ ")
        print("  [更新两行各态] \(printed)")

        let first = heights[0].1
        for (name, h) in heights.dropFirst() {
            #expect(
                abs(h - first) <= 0.5,
                """
                「\(name)」渲染出来 \(h)pt，而「\(heights[0].0)」是 \(first)pt —— 各态必须一样高。
                说明文案是整句替换的，长了就会多折一行、把最后一行挤出折叠线。
                全部各态：\(printed)
                """
            )
        }
    }

    /// 「更新」组那两个开关的**禁用态不得比可用态更高**（2026-09-28，与 ``接管未授权态不得比可用态更高()`` 同源）。
    ///
    /// ## 判据为什么是「≤」而不是「等高」
    ///
    /// 面板高度契约（``面板高度放得下头部与全部四组()`` / ``面板高度不留大片空白()``）
    /// 拿 ``designAutoUpdateRows`` 那一版（**可用态**，也是真机默认态）对齐。
    /// 只要禁用态**不比它高**，那两条契约就天然覆盖了禁用态；
    /// 反过来（禁用态更高）就意味着面板要重新定高 —— 那是另一件事。
    ///
    /// ⚠️ **这条为什么不能省（它真的抓到过东西）**：禁用态的文案与可用态**不是同一句**
    /// （`autoUpdateUnavailableHint` / `autoDownloadNeedsCheckHint`），
    /// 而「不可用时把话说清楚」与「不许因为说多了就把面板撑高」是**两个方向相反的诉求**。
    /// 只压前者就会多折一行 —— 2026-09-28 把 `autoUpdateUnavailableHint` 从
    /// 79 字符压到 49 字符（英文）就是因为它在两行上**各出现一次**，
    /// 一旦折成两行，英文比中文多两行 ⇒ 面板高度**无解**（不是偏紧）。
    ///
    /// ⚠️ **将来把禁用文案写长**，首选同样是压短文案，**别把断言放宽成 `+ 40`**：
    /// 那样放过的正是「多折了一行」。
    @Test func 更新两行不可用态不得比可用态更高() {
        // 自证：三句话**必须互不相同** —— 否则下面量到的是同一版，断言恒成立
        // （同 ``接管未授权态不得比可用态更高()`` 开头那条）。
        let lines = [
            L10n.tr(.autoCheckUpdateHint), L10n.tr(.autoDownloadUpdateHint),
            L10n.tr(.autoDownloadNeedsCheckHint), L10n.tr(.autoUpdateUnavailableHint),
        ]
        #expect(
            Set(lines).count == lines.count,
            "更新两行的四句说明里有重复：\(lines) —— 重复意味着某一态其实没有换文案，量到的可能是同一版（假绿）"
        )

        for language in [TestLanguage.design, "en", "zh-Hant"] {
            let usable = renderedSize(
                SettingsSectionsColumn(
                    autoUpdateRowsOverride: designAutoUpdateRows, takeOverAvailabilityOverride: designTakeOver),
                width: panelWidth, language: language)
            let blocked = renderedSize(
                SettingsSectionsColumn(
                    autoUpdateRowsOverride: AutoUpdateRowsState(
                        canAutoUpdate: false, checksIsOn: false, downloadsIsOn: false),
                    takeOverAvailabilityOverride: designTakeOver),
                width: panelWidth, language: language)
            let checksOff = renderedSize(
                SettingsSectionsColumn(
                    autoUpdateRowsOverride: AutoUpdateRowsState(
                        canAutoUpdate: true, checksIsOn: false, downloadsIsOn: false),
                    takeOverAvailabilityOverride: designTakeOver),
                width: panelWidth, language: language)
            print(
                "  [更新两行] \(language)：可用 \(usable.height) ｜ 不具备能力 \(blocked.height) ｜ 检查关 \(checksOff.height)"
            )
            #expect(
                blocked.height <= usable.height + 0.5,
                "[\(language)] 「不具备能力」那一态 \(blocked.height)pt 比可用态 \(usable.height)pt 更高 —— 禁用态的说明文案多折了一行，面板要重新定高（首选是压短文案）"
            )
            #expect(
                checksOff.height <= usable.height + 0.5,
                "[\(language)] 「检查关 · 下载行说『需先打开…』」那一态 \(checksOff.height)pt 比可用态 \(usable.height)pt 更高 —— 禁用态的说明文案多折了一行，面板要重新定高（首选是压短文案）"
            )
        }
    }

    /// 「接管访达的推出」那一行**两态**的高度关系（2026-09-28）。
    ///
    /// ## 判据为什么是「未授权态 ≤ 可用态」而不是「等高」
    ///
    /// 两态换的是说明文字（`takeOverFinderEjectFootnote` ↔ `takeOverFinderEjectNeedsFDA`），
    /// 而**可用态才是设计稿画的版本**（`05-settings.html` 里是开关），
    /// 本文件所有绝对值断言（900.20 / 916.20）也都是拿它对齐的。
    /// 只要未授权态**不比它高**，面板高度契约就天然对它成立；
    /// 反过来（未授权态更高）就意味着面板要重新定高，那是另一件事。
    ///
    /// ⚠️ **将来把未授权态的文案写长**（比如补一句「系统设置在哪」），这条会红 ——
    /// 那时首选是压短文案（与英文 footnote 从 158 压到 116 字符那次同一手法），
    /// **别把断言放宽成 `+ 40`**：那样放过的正是「多折了一行」。
    @Test func 接管未授权态不得比可用态更高() {
        // 自证：两态用的**必须不是同一句话** —— 否则下面两次量的是同一版，断言恒成立
        // （同 ``繁中下也必须放得下()`` 开头那条自证）。
        #expect(
            L10n.tr(.takeOverFinderEjectFootnote) != L10n.tr(.takeOverFinderEjectNeedsFDA),
            "未授权态的说明与可用态逐字相同 —— 那一行没有真的换文案，量到的是同一版（假绿）"
        )

        for language in [TestLanguage.design, "en", "zh-Hant"] {
            let usable = renderedSize(
                SettingsSectionsColumn(takeOverAvailabilityOverride: .usable) { _ in },
                width: panelWidth, language: language)
            let blocked = renderedSize(
                SettingsSectionsColumn(takeOverAvailabilityOverride: .needsFullDiskAccess) { _ in },
                width: panelWidth, language: language)
            print("  [接管行两态] \(language)：可用 \(usable.height) ｜ 未授权 \(blocked.height)")

            #expect(
                blocked.height <= usable.height + 0.5,
                """
                未授权态比可用态高 \(blocked.height - usable.height)pt（\(language)）——
                面板高度是按可用态定的，高出来的部分只能从折叠线外要（「关于」会被藏掉）。
                两态：可用 \(usable.height) ｜ 未授权 \(blocked.height)。
                首选改法是压短 takeOverFinderEjectNeedsFDA，不是加高面板。
                """
            )
        }
    }

    @Test func 分段控件不许吃掉标签列的宽度() {
        _ = NSApplication.shared
        let control = SettingsSegmentedControl(
            options: VisualStyle.allCases.map { ($0.rawValue, $0.shortName, $0.displayName) },
            selection: .constant(VisualStyle.default.rawValue),
            accent: .default
        )
        // 量**固有宽度**：提案给无穷大，控件才会报出自己真正想要的宽度。
        // （若按面板宽 440 去提案，`.fixedSize()` 会被裁到 440，量不出溢出。）
        let hosting = NSHostingController(rootView: control)
        let ideal = hosting.sizeThatFits(
            in: CGSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))

        // 行内可用宽 ≈ 面板宽 − 卡片与行的左右内边距；留一半以上给标签列。
        let budget = panelWidth * 0.45
        #expect(
            ideal.width <= budget,
            """
            分段控件固有宽 \(Int(ideal.width))pt，超过预算 \(Int(budget))pt（面板的 45%）。\
            它末尾带 `.fixedSize()`，**不可压缩**——同行的标签列是 `maxWidth: .infinity` 的弹性列，\
            会独吞这个差额并被压成竖排单字（2026-09-15 实测：长标签让该行理想宽 745pt vs 面板 440pt，\
            内容真实高度 910pt vs 可用 498pt）。可见标签必须用 `VisualStyle.shortName`（「透明」/「色调」）。
            """
        )
    }

    @Test func 分隔线只画在卡片内的行与行之间() {
        // 外观卡 2 行 → 1 条；通用卡 4 行 → 3 条；诊断卡 1 行 → 0 条；更新卡 3 行 → 2 条。合计 6 条。
        // （通用卡 2026-09-27 从 3 行变 4 行 —— 加了「接管访达的推出」，故 2 条 → 3 条。
        //  更新卡 2026-09-28 从 2 行变 3 行 —— 「自动更新」拆成「自动检查更新」+「自动下载更新」，
        //  故 1 条 → 2 条。）
        // 首行上方那条要是画出来，卡片会被一条横线从顶部切开；
        // 卡片自身的圆角描边不算行间分隔线（检测器已按「上下都变暗」排除）。
        //
        // ⚠️ **这个数会随「每张卡几行」变**：加一行就要 +1。
        // 它抓的是「某张卡的首行上方也画了线」——那种错会让总数**多**出来，
        // 而少画一条（卡片看起来糊成一块）同样要被抓到。
        let count = horizontalDividerCount(
            SettingsSectionsColumn(
                autoUpdateRowsOverride: designAutoUpdateRows, takeOverAvailabilityOverride: designTakeOver
            ) { _ in }, width: panelWidth)
        #expect(
            count == 6,
            "测到 \(count) 条卡片内行间分隔线，期望 6 条（外观 1 + 通用 3 + 更新 2；诊断只有一行，不画线）。数目不符说明某张卡的首行上方也画了线，或某条行间线没画出来"
        )
    }

    // MARK: 头部与设计稿内边距

    /// 头部标题的**渲染起点**必须等于设计稿的内边距（`.shead { padding: 0 16px }`）。
    ///
    /// **必须量渲染结果**：拿 `SettingsMetrics` 里的常量跟自己比是**没牙的**。
    /// 本项目踩过 —— 这条测试原先判的是「红绿灯有没有压住标题」，用的常量
    /// `headerTitleMinX` 本身就是从让位宽度算出来的，于是**删掉视图里那句让位它照样是绿的**。
    /// 后来改成量墨迹；2026-09-16 让位连同红绿灯一起删掉（`DESIGN-SPEC.md` §8.17），
    /// 期望值也跟着变成**前导内边距本身**。
    ///
    /// 实测（离屏，scale 2）：前导 16 → 首列墨迹 **16.0pt**（2026-09-16 本轮实测，最右 412.5）；
    /// 让位还在时（前导 20 + 让位 52 + 间距 8）→ **80.0pt**。
    /// 上界 +6 是给字形侧边距留的：中文「设」几乎贴边，英文 "Settings" 的 `S` 会再右偏一点。
    /// 下界 −1 是抗锯齿。
    /// **为什么非要量像素**：SwiftUI 的 `Text` 在 AppKit 视图树里**没有任何对应视图** ——
    /// 实测 `NSHostingView` 的 `subviews` 是空的、整棵树里找不到 `NSTextField`，
    /// 无障碍子树也是懒建的（`accessibilityChildren` 返回 nil）。
    /// 所以「标题从第几列开始」问不到 AppKit，只能看**渲染结果**。
    ///
    /// **判据是「相对白底变暗」而不是看 alpha**：``OffscreenRender/bitmap(_:size:appearance:background:)``
    /// 默认垫一层白底，于是每个像素都是不透明的，读到的就是真实渲染色。
    /// （`bitmapImageRepForCachingDisplay` 的缓冲区**不保证清零**，所以那边显式
    /// `NSBitmapImageRep(bitmapDataPlanes: nil, …)` 让系统分配一块干净的；
    /// 本文件原先也自己抄了这么一段出图 + 逐像素 `colorAt`，2026-09-23 收敛进
    /// ``OffscreenRender``，见 `DESIGN-SPEC.md` §8.131。）
    ///
    /// **扫描带取 y ∈ [8, 44]**（52pt 头部的中段）：**必须避开底部那条 `Hairline`** ——
    /// 它横跨整宽，会把 x=0 也算成墨迹。
    @Test func 头部标题渲染起点等于设计稿内边距() {
        guard
            let rep = OffscreenRender.bitmap(
                SettingsHeaderBar(onDone: {}),
                size: CGSize(width: panelWidth, height: SettingsMetrics.headerHeight)),
            let range = OffscreenRender.inkColumnRange(rep, rows: 8...44, maxX: panelWidth)
        else {
            Issue.record("头部离屏渲染后没扫到任何墨迹 —— 渲染本身没成功，这条断言不能算通过")
            return
        }

        // 自证：右半侧也该有墨迹（「完成」按钮）。两侧都扫到，才说明渲出的是一整个头部，
        // 而不是某个只画了一半的半成品（量到半成品会得出错误基准值）。
        #expect(
            range.last > panelWidth / 2,
            "最右侧墨迹只到 \(range.last)pt（面板宽 \(panelWidth)）—— 渲染不完整，下面的断言无意义"
        )

        let expected = SettingsMetrics.headerPaddingLeading
        // 把量到的数打出来 —— 像素量测最容易的失败方式是「量错了东西」，
        // 有这两个数才能当场分辨「对齐坏了」和「扫描带落在空白上」。
        print("  [设置面板头部] 首列墨迹 \(range.first)pt、最右 \(range.last)pt（期望首列 ≈ \(expected)）")
        #expect(
            range.first >= expected - 1 && range.first <= expected + 6,
            """
            标题首列墨迹在 \(range.first)pt，设计稿内边距 \(expected)pt。\
            偏大（≈20.0）说明前导内边距被改回了 20；再大（≈80.0）说明红绿灯让位块又回来了 —— \
            设计稿的 `.shead` 里没有 traffic；偏小则说明内边距被改小。
            """
        )
    }

    /// 「后台下载中」那一行的进度条**固定 16pt 高**，与说明行同高。
    ///
    /// 设计稿 `08-update.html` B3 的 spec-note 点名要求「进度条外层固定 16pt，
    /// 与 `.sline__desc` 同一行高，**下载中这一行不会被撑高**」。
    ///
    /// **为什么必须钉**：不钉的话，把外层高度去掉（只留 5pt 轨道 + 文字行盒）
    /// 会让整块设置面板在下载过程中**跳一下** —— 而这件事只在真机下载时看得到，
    /// 离屏出图与其它单测都不会红。
    @Test func 行内进度条固定16pt高() {
        let size = renderedSize(SettingsProgressLine(fraction: 0.42), width: 200)
        #expect(
            size.height == DesignTokens.Size.settingsProgressLineHeight,
            "行内进度条渲染出来 \(size.height)pt，不是固定的 \(DesignTokens.Size.settingsProgressLineHeight)pt")
        #expect(
            DesignTokens.Size.settingsProgressLineHeight == 16,
            "设计稿写的是 16 —— 改这个数要同时改设计稿 B3 的 spec-note")
    }
}
