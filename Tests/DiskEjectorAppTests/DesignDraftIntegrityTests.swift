import CryptoKit
import Foundation
import Testing

@testable import DiskEjectorApp

/// 设计稿（HTML 原型）自身的**完整性**守卫，两个维度：
///
/// 1. **CSS 类**：「用了但没有定义」必须登记（拼错类名 / 删了 CSS 忘了改 HTML）。
/// 2. **i18n 键**：`i18n-extra.json` 里声明的键必须**有页面在用**（否则是死文案）。
///
/// 这两个都属于「**有声明、没有消费者**」—— Swift 侧已经在 §8.50 钉住了
/// （`DeclarationConsumerTests`），设计稿侧此前**一条都没有**。
/// 而 §8.51 刚证明设计稿是「唯一真相」的来源：**它腐化了，同源守卫全会被误导**。
///
/// **为什么守这一向，不守另一向**：设计稿里「定义了但没元素用」的类**多数是合理的**
/// （备用样式、无障碍 `.sr-only`、文档样例）—— §8.52.5 记过：**零消费者 ≠ 可删**，
/// 删设计稿的类会改变视觉。所以那一向只**打印**，不报警。
///
/// 反过来，「用了但没定义」**一定是问题**：要么是类名拼错（`.aboutroww`），
/// 要么是删了 CSS 忘了改 HTML。它的症状是「样式没生效」——
/// 而**「样式没生效」与「本来就没写样式」在界面上逐字相同**，读代码看不出来。
/// 这一条负责把两者分开。
///
/// **定义源有两个，别漏**（§8.52.1）：主 CSS `assets/ds.css` **加上每个 HTML 的 `<style>` 块**
/// —— 实测 9 个页面共 225 行 `<style>`，`.aboutrow` 的样式就在那里，只扫主 CSS 会误报。
@MainActor
struct DesignDraftIntegrityTests {

    // MARK: 路径

    /// #filePath = <仓库根>/Tests/DiskEjectorAppTests/DesignDraftClassTests.swift
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var designRoot: URL {
        repoRoot.appendingPathComponent("DiskEjector-UI-Design/v2")
    }

    // MARK: 豁免表

    /// 「用了但没定义」的**账本** —— 两个方向都查（新出现的要拦下，登记了却已经
    /// 不存在的要回来划掉）。只查一个方向，这张表就会像 §8.33 清掉的那 6 条一样：
    /// **还了账没人回来划**。
    ///
    /// 这 4 个都是**纯容器 / 语义类**：只有结构作用，本来就不该有样式。
    private static let containerOnly: [String: String] = [
        "ds": "文档根容器（`<body class=\"ds\">`），只用来挂主题与语言",
        "row__evid": "完整行的「证据区」容器，样式走 `.evid*`，本身无规则",
        "spec": "index.html 的规格表容器",
        "state-tbl": "状态矩阵表格（样式写在 `06-states.html` 的 `<style>` 里，见 `table.state-tbl`）",
    ]

    // MARK: 守卫

    /// 设计稿里**用了但没有任何 CSS 定义**的类，必须全在豁免表里。
    @Test func 用了但没定义的类必须登记在案() throws {
        let scan = try load()
        // 解析器的**锚**：下面几条不成立，说明扫描逻辑退化了，
        // 而那种情况下「未定义」会**空着** —— 通过得毫无意义。
        #expect(scan.defined.count > 150, "只解析到 \(scan.defined.count) 个类 —— 扫描逻辑多半坏了")
        #expect(scan.used.count > 150, "只收集到 \(scan.used.count) 个类 —— HTML 没读到")
        #expect(
            scan.defined.contains("row"), "`.row` 都没解析到 —— 定义源（ds.css / `<style>`）没读到")
        #expect(scan.used.contains("row"), "`.row` 都没收集到 —— HTML 的 class 属性没读到")
        #expect(
            scan.defined.contains("aboutrow"),
            "`.aboutrow` 必须能解析到 —— 它的样式在 05-settings.html 的 `<style>` 里，只扫 ds.css 会漏掉（§8.52.1）"
        )

        let missing = scan.used.subtracting(scan.defined).subtracting(Self.containerOnly.keys)
        #expect(
            missing.isEmpty,
            """
            设计稿里这些类**被元素用着，但没有任何 CSS 定义**（多半是类名拼错，或删了 CSS 忘了改 HTML）：
            \(missing.sorted().joined(separator: ", "))
            已知的无样式容器类登记在 `containerOnly` 里；新增的要连同理由一起登记。
            """
        )
    }

    /// 豁免表**不许过期**：登记的类如果已经有了定义，要回来划掉。
    @Test func 豁免表里已经定义了的类要划掉() throws {
        let scan = try load()
        let stale = Self.containerOnly.keys.filter { scan.defined.contains($0) }
        #expect(
            stale.isEmpty,
            """
            这些类登记为「没有定义」，但现在**已经有定义了**：\(stale.sorted().joined(separator: ", "))
            还了账就回来划掉 —— 否则这张表会像 §8.33 那 6 条一样越积越不可信。
            """
        )
    }

    /// 豁免表的第三向：登记的类如果**已经没人用了**，也要回来划掉。
    ///
    /// 前两条只堵「登记了却有定义」（= 记账记错）；这一条堵「登记了但对象没了」
    /// —— 那种条目永远不会被任何断言碰到，只会**安静地烂在表里**。
    @Test func 豁免表里已经没人用的类要划掉() throws {
        let scan = try load()
        let stale = Self.containerOnly.keys.filter { !scan.used.contains($0) }
        #expect(
            stale.isEmpty,
            """
            这些类登记为「无样式容器」，但设计稿里**已经没有任何元素在用**它们：
            \(stale.sorted().joined(separator: ", "))
            要么把类也删掉，要么回来把这一条划掉 —— 留着它永远不会有人再看第二眼。
            """
        )
    }

    /// 反向（定义了但没元素用）**只打印不报警** —— §8.52.5：零消费者 ≠ 可删。
    @Test func 反向扫描只记录不报警() throws {
        let scan = try load()
        let unused = scan.defined.subtracting(scan.used).sorted()
        print("  [设计稿] 定义了但没元素用：\(unused.count) 个 —— \(unused.joined(separator: ", "))")
        // 只留一条极松的自检：数字不该是 0（那说明「定义」没扫到），也不该接近全部
        #expect(!unused.isEmpty, "一个零消费者都没有 —— 「定义」那一向多半没扫到")
        #expect(unused.count < scan.defined.count / 2, "零消费者超过一半 —— 解析多半出了问题")
    }

    // MARK: 图标

    /// 设计稿里**用了但图标表里没有**的名字，必须为零 —— 一个都不许有。
    ///
    /// 为什么这一向比另一向重要得多：`ds.js` 的 `build(name)` 里是
    /// `var body = I[name]; if (!body) return '';` —— **名字写错就返回空串**。
    /// 于是 `<i data-i="ejct">` 渲染出来**什么都没有**，而
    /// **「图标是空白」与「这块本来就没放图标」在界面上逐字相同**，读 HTML 看不出来。
    @Test func 用了但图标表里没有的名字一个都不许有() throws {
        let (defined, used) = try loadIcons()
        // 解析器的**锚**：图标表要是没解析到，下面的差集会空着，通过得毫无意义
        #expect(defined.count > 25, "只解析到 \(defined.count) 个图标 —— 图标表没读到")
        #expect(defined.contains("eject"), "`eject` 都没解析到 —— 图标表结构变了？")
        #expect(used.contains("eject"), "`eject` 明明在用却没收集到 —— data-i 的扫描坏了")

        let missing = used.subtracting(defined)
        #expect(
            missing.isEmpty,
            """
            这些图标名被 `<i data-i="…">` 用着，但 `ds.js` 的图标表里**没有**：
            \(missing.sorted().joined(separator: ", "))
            `build()` 对未知名字返回**空串** ⇒ 这些位置渲染出来是**空白**，
            而「图标是空白」与「本来就没放图标」长得一模一样。
            """
        )
    }

    /// 图标表里**定义了但没用**的名字 —— 只打印。
    ///
    /// 图标表是**库**（和 `ds.css` 一样是组件库），**库里允许有存货**；
    /// i18n 文案是**内容**，内容不允许有孤儿。判据见 §8.54.2。
    @Test func 图标表里的存货只记录不报警() throws {
        let (defined, used) = try loadIcons()
        let spare = defined.subtracting(used).sorted()
        print("  [设计稿] 图标表存货：\(spare.count) 个 —— \(spare.joined(separator: ", "))")
        #expect(!spare.isEmpty, "一个存货都没有 —— 「定义」那一向多半没扫到")
        #expect(spare.count < defined.count / 2, "存货超过一半 —— 解析多半出了问题")
    }

    // MARK: i18n

    /// `i18n-extra.json` 里**声明了但没有页面在用**的键 —— 死文案，登记在案。
    ///
    /// 与 CSS 类**不同**：删掉一个没用的文案键**不改变任何渲染**，所以这一向是
    /// 「零消费者 = 可删」。但仍然**登记而不是立刻删** —— 因为有些是
    /// 「备着给还没画的样本用的」，那是设计决策，不该由扫描器替人决定（§8.52.5 同理）。
    ///
    /// ⚠️ **已清空**（§8.68）：原先唯一一条 `ds.sample.cap.usedFreeC` 在那一轮给
    /// 2 TB 那块盘接上了 `data-i18n`（它本就是界面里「已用 1.4 TB · 剩余 600 GB」那一行的文案，
    /// 只是**忘了接线**，不是没有样本）。⇒ 表空了，但**别删这张表**：
    /// 下次再出现死文案，登记进来比直接删键安全（删键是设计决策，不由扫描器替人决定）。
    private static let unusedI18nKeys: [String: String] = [:]

    /// 声明了但没页面在用的文案键，必须全在豁免表里。
    @Test func 声明了但没有页面在用的文案键必须登记在案() throws {
        let (declared, referenced) = try loadI18n()
        // 解析器的**锚**
        #expect(declared.count > 30, "只解析到 \(declared.count) 个键 —— i18n-extra.json 没读到")
        #expect(
            declared.contains("ds.sample.cap.usedFreeA"),
            "`usedFreeA` 都没解析到 —— 键名格式变了？")
        #expect(
            referenced.contains("ds.sample.cap.usedFreeA"),
            "`usedFreeA` 明明被 02-menu-bar 用着却没收集到 —— 消费源扫错了")

        let dead = declared.subtracting(referenced).subtracting(Self.unusedI18nKeys.keys)
        #expect(
            dead.isEmpty,
            """
            这些文案键在 `i18n-extra.json` 里声明了，但**没有任何页面在用**（死文案）：
            \(dead.sorted().joined(separator: ", "))
            要么给它找一个 `data-i18n` 消费者，要么把键删掉 —— 留着它永远不会有人再看第二眼。
            """
        )
    }

    /// 豁免表**不许过期**：登记为「没人用」的键如果已经有页面在用了，要回来划掉。
    @Test func 已登记的文案键如果有页面在用了要划掉() throws {
        let (_, referenced) = try loadI18n()
        let stale = Self.unusedI18nKeys.keys.filter { referenced.contains($0) }
        #expect(
            stale.isEmpty,
            """
            这些键登记为「没有页面在用」，但现在已经**有消费者**了：\(stale.sorted().joined(separator: ", "))
            还了账就回来划掉 —— 否则这张表会像 §8.33 那 6 条一样越积越不可信。
            """
        )
    }

    /// 页面**引用了但声明集里没有**的键 —— 静默回退，一个都不许有。
    ///
    /// `tools/build_i18n.py` 的注释自己写着：「抄漏一条不会报错，只会在切到那门语言时
    /// **静默回退成中文** —— 而『回退』和『翻好了』长得一模一样」。
    /// 声明集是 **`i18n-extra.json` ∪ `Localizable.xcstrings`**（设计稿可以引用产品已有文案）。
    @Test func 页面引用了但没有声明的文案键一个都不许有() throws {
        let (_, referenced) = try loadI18n()
        let declared = try Self.declaredTextKeys(repoRoot: repoRoot)
        #expect(declared.count > 150, "只解析到 \(declared.count) 个键 —— xcstrings 没读到")
        #expect(
            declared.contains("ds.sample.cap.usedFreeA"),
            "`usedFreeA` 不在声明集里 —— xcstrings / i18n-extra 都没读到")

        let missing = referenced.subtracting(declared)
        #expect(
            missing.isEmpty,
            """
            这些 `data-i18n` 引用的键**在任何一处都没有声明**：
            \(missing.sorted().joined(separator: ", "))
            切到英文/繁体时会**静默回退成中文** —— 和「翻好了」长得一模一样。
            """
        )
    }

    /// **生成物与源必须同步**：改了源忘了重跑 `tools/build_i18n.py`，`i18n.js` 就是旧的。
    ///
    /// 这一向才贵：**加了键忘了重跑** ⇒ 切到英文时设计稿**静默回退成中文**，
    /// 而「回退」和「翻好了」在界面上长得一模一样 —— `build_i18n.py` 的头注释自己写着这句。
    ///
    /// 实测已经抓到过一次（§8.48 那轮）：从 `xcstrings` 删掉 2 个键后源是 156 条，
    /// 而**已提交的 `i18n.js` 里那 2 个键还在**（3 门语言 × 2 = 6 行），
    /// 文件时间戳甚至比源还旧 —— 生成步骤被跳过了，谁也没发现。
    ///
    /// 守的办法是**源指纹**，不是在测试里跑一遍 python：
    /// 环境无关（不要求机器上有 python、不起进程），且**任一方变了必然红**。
    @Test func 生成物i18njs的源指纹必须与源一致() throws {
        let jsURL = designRoot.appendingPathComponent("assets/i18n.js")
        let js = try read(jsURL)

        // 锚 ①：指纹行**必须解析得到**。找不到就红，绝不静默放过 ——
        // 万一头部格式改了而正则没跟上，它会「永远绿」，那种绿比不测更糟（§8.55.5）。
        let embedded = try #require(
            Self.matches(in: js, pattern: #"源指纹\s+([0-9a-f]{64})"#).first,
            """
            \(jsURL.lastPathComponent) 头部找不到「源指纹 <64 位 hex>」。
            要么没跑过 `python3 tools/build_i18n.py`，要么头部格式改了而这里的正则没跟上。
            """)

        let expected = try Self.sourceFingerprint(repoRoot: repoRoot)

        #expect(
            embedded == expected,
            """
            \(jsURL.lastPathComponent) 与源**不同步**：
              文件里  \(embedded.prefix(16))…
              源算得  \(expected.prefix(16))…
            源（Localizable.xcstrings / i18n-extra.json / build_i18n.py）有一方改过了 —— 重跑：
                python3 tools/build_i18n.py
            并把新生成的 i18n.js 一起提交（它是生成物，但必须入库）。
            """)
    }

    // MARK: 语言包内部（§8.65）

    /// 生成物 `i18n.js` 里的**语言包本体**（`window.DS_L10N = { … };`），按语言取键值表。
    ///
    /// ⚠️ 读的是**生成物**而不是 `i18n-extra.json`：想知道「英文那一列到底有没有值」，
    /// 只能看生成物 —— `extra.json` 里写了，不代表 `build_i18n.py` 抄进去了。
    /// 与上面「源指纹」那条互补：**它**守「生成物是不是旧的」，**这一组**守
    /// 「生成物**内部**三门语言对不对得上」。
    private func loadLanguagePack() throws -> [String: [String: String]] {
        let js = try read(designRoot.appendingPathComponent("assets/i18n.js"))
        let marker = "window.DS_L10N = "
        guard let start = js.range(of: marker)?.upperBound,
            let tail = js.range(of: "\n};", range: start..<js.endIndex)?.lowerBound
        else {
            Issue.record("i18n.js 里解析不到语言包（`window.DS_L10N = {` … `\\n};`）")
            return [:]
        }
        // `tail` 指向 `};` 前的换行；往回一步是外层收尾的那个 `}`。
        let json = String(js[start...js.index(tail, offsetBy: 1)])
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
            let pack = obj as? [String: [String: String]]
        else {
            Issue.record("语言包不是 [语言: [键: 值]] —— 生成脚本的输出格式变了？")
            return [:]
        }
        return pack
    }

    /// 三门语言的**键集合必须完全一致**。
    ///
    /// 缺一个键 ⇒ 切到那门语言时 `t()` 取不到 ⇒ **静默回退成中文**（ds.js 的回退链），
    /// 而「回退」与「翻好了」在界面上**长得一模一样** —— 这是本仓库反复出现的同一类病。
    /// 现有两条 i18n 守卫看的是**键在不在声明集里**，不看「每一门语言都齐不齐」。
    @Test func 三门语言的键集合必须完全一致() throws {
        let pack = try loadLanguagePack()
        let langs = pack.keys.sorted()
        // 锚：三门语言都得解析到，否则「差集为空」只是「两边都是空」
        #expect(langs.count >= 3, "只解析到 \(langs) 门语言 —— 语言包结构变了？")
        guard let first = langs.first else {
            Issue.record("语言包一门语言都没解析到")
            return
        }
        let base = Set(pack[first, default: [:]].keys)
        #expect(base.count > 150, "只有 \(base.count) 个键 —— 语言包没读全")

        var problems: [String] = []
        for lang in langs.dropFirst() {
            let keys = Set(pack[lang, default: [:]].keys)
            let missing = base.subtracting(keys).sorted()
            let extra = keys.subtracting(base).sorted()
            if !missing.isEmpty {
                problems.append(
                    "\(lang) 缺 \(missing.count) 个键：\(missing.prefix(5).joined(separator: ", "))…")
            }
            if !extra.isEmpty {
                problems.append(
                    "\(lang) 多 \(extra.count) 个键：\(extra.prefix(5).joined(separator: ", "))…")
            }
        }
        #expect(
            problems.isEmpty,
            """
            三门语言的键集合对不上：
            \(problems.joined(separator: "\n  "))
            缺的那个键会**静默回退成中文** —— 界面上看不出「没翻」，只看得出「还是中文」。
            """)
    }

    /// **样本文案**在各语言下的数字必须逐字一致。
    ///
    /// 这条是 `i18n-extra.json` 头注释里**明写**的约定：
    /// 「`ds.sample.<...>` 走查用的样本数据（磁盘名、容量数字、版本号），
    ///   各语言数字必须一致，否则走查图对不上」。
    /// ⇒ 约定写下来了，但没有判据 —— 这正是 §8.45「有能力、没接线」那一族：
    /// **明写的规则没人执行，和没写一样。**
    @Test func 样本文案在各语言下的数字必须一致() throws {
        let pack = try loadLanguagePack()
        guard let first = pack.keys.sorted().first, let table = pack[first] else { return }
        let samples = table.keys.filter { $0.hasPrefix("ds.sample.") }.sorted()
        #expect(samples.count >= 5, "只有 \(samples.count) 个样本键 —— 前缀约定改了？")

        var problems: [String] = []
        for key in samples {
            var perLang: [String: String] = [:]
            for (lang, t) in pack {
                // ⚠️ `matches` 固定取**捕获组 1**：写 `(?:…)` 这种非捕获组 ⇒
                // `range(at: 1)` 越界 ⇒ NSException（进程直接 abort，不是测试失败）。
                let nums = Self.matches(in: t[key] ?? "", pattern: #"(\d+(?:\.\d+)?)"#)
                perLang[lang] = nums.joined(separator: "|")
            }
            let distinct = Set(perLang.values)
            if distinct.count > 1 {
                let detail = perLang.keys.sorted().map { "\($0)=[\(perLang[$0] ?? "")]" }
                    .joined(separator: "  ")
                problems.append("\(key)：\(detail)")
            }
        }
        #expect(
            problems.isEmpty,
            """
            样本数据在各语言下数字不一致：
            \(problems.joined(separator: "\n  "))
            走查图是逐语言各出一套的 —— 数字对不上，两门语言的图就**不是同一个盘**，
            比完以为是自己改坏了。约定见 `i18n-extra.json` 头注释。
            """)
    }

    /// 语言包里**不许有空值**。
    ///
    /// 空串与「这一行本来就没有文字」在渲染结果上**逐字相同** ——
    /// 界面上就是一个空白位置，谁也不会想到是翻译漏了。
    @Test func 语言包里不许有空值() throws {
        let pack = try loadLanguagePack()
        var problems: [String] = []
        for (lang, table) in pack {
            let empty = table.filter { $0.value.isEmpty }.keys.sorted()
            if !empty.isEmpty {
                problems.append("\(lang)：\(empty.joined(separator: ", "))")
            }
        }
        #expect(
            problems.isEmpty,
            """
            语言包里有空值：
            \(problems.joined(separator: "\n  "))
            空串渲染出来就是一个**空白位置**，和「这行本来就没有文字」一模一样。
            """)
    }

    /// 英文那一列**不许出现中文字符**（漏翻）。
    ///
    /// 与「键在不在」互补：键在、值也在、但值**就是中文** ——
    /// `t()` 取得到，回退链根本不触发，界面上完全正常，**只有切到英文才看得见**，
    /// 而走查时没人会逐条切一遍。
    ///
    /// ⚠️ 判据之所以能这么硬：实测英文列 **0 处**含 CJK，不存在「本来就该留中文」的例外。
    @Test func 英文文案里不许出现中文字符() throws {
        let pack = try loadLanguagePack()
        guard let en = pack["en"] else {
            Issue.record("语言包里没有英文列")
            return
        }
        // 负向锚：英文列是空的 ⇒ 下面「0 处漏翻」只是「没扫到任何东西」
        #expect(en.count > 150, "英文列只有 \(en.count) 个键 —— 没读全")
        let han = en.filter { _, value in
            value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }.keys.sorted()
        #expect(
            han.isEmpty,
            """
            英文列里出现了中文字符（漏翻）：\(han.joined(separator: ", "))
            键在、值也在 ⇒ 回退链**不会触发**，界面上看不出任何异常 ——
            只有切到英文才会发现那一行还是中文。
            """)
    }

    // MARK: 文案值里的 HTML（§8.66）

    private struct HtmlTag {
        var name: String
        var closing: Bool
        var attrs: String
    }

    /// 文案**值里**允许出现的标签 —— `i18n.js` 头注释里明写的清单。
    private static let allowedValueTags: Set<String> = ["b", "code", "br", "i"]

    /// 空元素（不成对，`<br>` / `<br/>` 都算）。
    private static let voidTags: Set<String> = ["br"]

    /// 解析文案值里的 HTML 标签。
    ///
    /// ⚠️ 只认 `<tag …>` / `</tag>` / `<tag/>` 这一种写法 —— 文案是**手写**的，
    /// 不会有注释、不会有 `<script>`；真要去解析完整 HTML 就得换 XMLParser，
    /// 而 HTML 不是合法 XML（`<br>` 不闭合、实体未声明），换过去只会更糟。
    private func tags(in value: String) -> [HtmlTag] {
        guard let re = try? NSRegularExpression(pattern: #"<(/?)([A-Za-z][A-Za-z0-9]*)([^>]*)>"#)
        else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return re.matches(in: value, range: range).compactMap { m in
            guard let slash = Range(m.range(at: 1), in: value),
                let name = Range(m.range(at: 2), in: value),
                let attrs = Range(m.range(at: 3), in: value)
            else { return nil }
            return HtmlTag(
                name: String(value[name]).lowercased(),
                closing: !value[slash].isEmpty,
                attrs: String(value[attrs]))
        }
    }

    /// 文案值里的 HTML 标签**必须闭合**。
    ///
    /// 值是被 `innerHTML` 回填的 ⇒ 少了 `</b>` 时浏览器**不报错**，
    /// 只是把这个元素**后面所有的文字都变粗** —— 症状在**别处**，
    /// 谁也不会想到是那一条文案少写了个结束标签。
    @Test func 文案值里的HTML标签必须闭合() throws {
        let pack = try loadLanguagePack()
        var problems: [String] = []
        var scanned = 0
        var sawBold = false
        for (lang, table) in pack {
            for (key, value) in table.sorted(by: { $0.key < $1.key }) {
                guard value.contains("<") else { continue }
                scanned += 1
                var stack: [String] = []
                for tag in tags(in: value) {
                    if tag.name == "b" { sawBold = true }
                    if tag.closing {
                        if Self.voidTags.contains(tag.name) { continue }
                        if stack.last != tag.name {
                            problems.append(
                                "[\(lang)] \(key)：</\(tag.name)> 对不上 \(stack.last.map { "<\($0)>" } ?? "空")")
                        } else {
                            stack.removeLast()
                        }
                    } else if !Self.voidTags.contains(tag.name) {
                        stack.append(tag.name)
                    }
                }
                if !stack.isEmpty {
                    problems.append(
                        "[\(lang)] \(key)：未闭合 \(stack.map { "<\($0)>" }.joined(separator: " "))")
                }
            }
        }
        // 锚：扫到的含标签值不能太少，且必须见过 `<b>`（白名单里最常见的那个）
        #expect(scanned >= 5, "只扫到 \(scanned) 条含标签的文案 —— 解析口径失效")
        #expect(sawBold, "一条 `<b>` 都没扫到 —— 标签解析口径失效（假绿）")
        #expect(
            problems.isEmpty,
            """
            文案值里的 HTML 标签不闭合：
            \(problems.joined(separator: "\n  "))
            值是按 **innerHTML** 回填的 ⇒ 少了 `</b>` 浏览器**不报错**，
            只是把它**后面所有文字都变粗** —— 症状出现在别处，很难想到是这条文案写漏了。
            """)
    }

    /// 文案值里的标签**必须在允许清单内**，且 `<i>` 必须带 `data-i`。
    ///
    /// 头注释写着「值里允许 HTML（`<b>` / `<code>` / `<br>` / `<i data-i="gear">`）」——
    /// 又是一条**明写却没有判据**的约定（§8.65.2 同族）。
    ///
    /// `<i>` 那条更具体：图标靠 `data-i` 水合，**没有 `data-i` 的 `<i>` 就是一段斜体字** ——
    /// 与 §8.45「有能力、没接线」同族：结构有了，接上标识才算数。
    @Test func 文案值里的HTML标签必须在允许清单内() throws {
        let pack = try loadLanguagePack()
        var problems: [String] = []
        for (lang, table) in pack {
            for (key, value) in table.sorted(by: { $0.key < $1.key }) {
                for tag in tags(in: value) {
                    if !Self.allowedValueTags.contains(tag.name) {
                        problems.append("[\(lang)] \(key)：不允许的标签 <\(tag.name)>")
                    }
                    if tag.name == "i", !tag.closing, !tag.attrs.contains("data-i") {
                        problems.append("[\(lang)] \(key)：<i> 没有 data-i —— 水合时找不到图标名")
                    }
                }
            }
        }
        #expect(
            problems.isEmpty,
            """
            文案值里出现了允许清单之外的标签：
            \(problems.joined(separator: "\n  "))
            允许的是 `<b>` / `<code>` / `<br>` / `<i data-i="…">`（见 i18n.js 头注释）。
            值是用 **innerHTML** 回填的 —— 多写一个块级标签就会把那一行的行内布局顶开。
            """)
    }

    // MARK: 跨语言结构（§8.67）

    /// 格式占位符：`%@` / `%d` / `%.0f` / `%1$@` …
    private static let placeholderPattern = #"(%(?:\d+\$)?(?:\.\d+)?[@dfslqSDF])"#

    /// 各语言的**格式占位符序列**必须一致。
    ///
    /// 这是语言包里**后果最重**的一类漂移：实现侧是 `String(format:)`，
    /// 占位符少一个 ⇒ 参数对不上 ⇒ **运行时可能直接崩**（`%d` 接到字符串），
    /// 而不是「显示得不好看」。翻译时漏掉或调换一个 `%@` 太容易了。
    ///
    /// 与 §8.65「样本数字一致」不同：那条只管 `ds.sample.*` 的**内容**，
    /// 这条管**任意键**的**结构**，且覆盖所有三门语言。
    @Test func 各语言的格式占位符必须一致() throws {
        let pack = try loadLanguagePack()
        guard !pack.isEmpty else {
            Issue.record("语言包一门语言都没解析到")
            return
        }
        // ⚠️ 键集合必须取**各语言的并集**，不能只按某一门语言筛。
        // 否则那门语言把占位符一删 ⇒ 这个键**自己从被检集合里消失** ⇒ 变异反而变绿
        // （实测 M89：删掉英文的 `%@`，判成绿 —— 判据把变异藏起来了）。
        // 与 §8.61.2「扫描看不见『该写的没写』」同源，只是这次是判据自身的盲区。
        let keys = Set(pack.values.flatMap { $0.keys }).filter { key in
            pack.values.contains {
                !Self.matches(in: $0[key] ?? "", pattern: Self.placeholderPattern).isEmpty
            }
        }.sorted()
        // 锚：含占位符的键不能太少，且必须见过 `%@`（最常见的那个）
        #expect(keys.count >= 20, "只有 \(keys.count) 个键含占位符 —— 匹配口径失效")
        let allPlaceholders = keys.flatMap { key in
            pack.values.flatMap {
                Self.matches(in: $0[key] ?? "", pattern: Self.placeholderPattern)
            }
        }
        #expect(
            allPlaceholders.contains("%@"), "一个 `%@` 都没扫到 —— 占位符口径失效（假绿）")

        var problems: [String] = []
        for key in keys {
            var perLang: [String: String] = [:]
            for (lang, t) in pack {
                perLang[lang] =
                    Self.matches(in: t[key] ?? "", pattern: Self.placeholderPattern)
                    .joined(separator: " ")
            }
            if Set(perLang.values).count > 1 {
                let detail = perLang.keys.sorted().map { "\($0)=[\(perLang[$0] ?? "")]" }
                    .joined(separator: "  ")
                problems.append("\(key)：\(detail)")
            }
        }
        #expect(
            problems.isEmpty,
            """
            同一条文案在各语言下的**占位符**对不上：
            \(problems.joined(separator: "\n  "))
            实现侧是 String(format:) —— 少一个 `%@` 就是**参数个数不匹配**，
            轻则显示错乱、重则运行时崩溃，而不是「翻得不好看」。
            """)
    }

    /// 各语言的 **HTML 标签结构**必须一致（`<b>` 强调在哪儿，各语言都得有）。
    ///
    /// 中文加了 `<b>` 强调、英文忘了 ⇒ 那门语言**重点丢了**，
    /// 而文案本身是翻好的 —— 没人会盯着「这一门语言少了个加粗」看。
    /// 与 §8.66 不同：那条是**单语言内**的合法性与闭合，这条是**跨语言**的结构一致。
    @Test func 各语言的HTML标签结构必须一致() throws {
        let pack = try loadLanguagePack()
        guard !pack.isEmpty else {
            Issue.record("语言包一门语言都没解析到")
            return
        }
        // 同上的并集口径（实测 M91：删掉英文的 `<b>`，键从集合里消失 ⇒ 判成绿）
        let keys = Set(pack.values.flatMap { $0.keys }).filter { key in
            pack.values.contains { ($0[key] ?? "").contains("<") }
        }.sorted()
        // 锚：含标签的键不能太少（现状 5 个）
        #expect(keys.count >= 3, "只有 \(keys.count) 个键含标签 —— 匹配口径失效")

        var problems: [String] = []
        for key in keys {
            var perLang: [String: String] = [:]
            for (lang, t) in pack {
                perLang[lang] = tags(in: t[key] ?? "").map { $0.name }.joined(separator: ",")
            }
            if Set(perLang.values).count > 1 {
                let detail = perLang.keys.sorted().map { "\($0)=[\(perLang[$0] ?? "")]" }
                    .joined(separator: "  ")
                problems.append("\(key)：\(detail)")
            }
        }
        #expect(
            problems.isEmpty,
            """
            同一条文案在各语言下的**标签结构**对不上：
            \(problems.joined(separator: "\n  "))
            中文加了 `<b>` 而英文没有 ⇒ 那门语言的**重点丢了**，
            而文案本身是翻好的 —— 逐条看很难发现。
            """)
    }

    // MARK: 界面文案漏接（§8.68）

    private struct ElementText {
        var text: String
        var key: String?  // data-i18n
        var note: Bool  // 在设计说明区内（说明区的中文不翻，不参与判定）
        var suppressed: Bool  // 自身、祖先或后代已接线
    }

    /// 极简 HTML 扫描：把文本**累积到栈上每一个元素**，弹出时给出「元素整文本」。
    ///
    /// 为什么必须拿**整文本**：`已用 <b>300 GB</b> · 剩余 <b>700 GB</b>` 这种，
    /// 文本被 `<b>` 切成好几段 —— 只看单段永远对不上语言包里的整句。
    /// （首版按「单个文本片段」比对 ⇒ 01/07 的容量行**一处都没扫到**。）
    ///
    /// ⚠️ 只支持设计稿这种手写 HTML：没有注释、`screens/` 下没有内联 `<script>`。
    /// 换 `XMLParser` 反而更糟 —— **HTML 不是合法 XML**。
    private func elementTexts(in html: String) -> [ElementText] {
        struct Node {
            var tag: String
            var attrs: [String: String]
            var text = ""
            var descWired = false  // 后代里已经有人接线 ⇒ 祖先不必再报
        }
        func isNote(_ cls: String?) -> Bool {
            guard let cls else { return false }
            // ⚠️ `frame__label` 是**画框标签**（「800 × 520 · …」），属设计稿 chrome，不翻。
            // ⚠️ **没有** `dim`：那是**弹窗遮罩层**（`<div class="dim">` 包着整个 alert），
            // 把它当说明区 ⇒ 所有弹窗内容被豁免，守卫对弹窗**完全失效**（实测 M95 假绿）。
            // 类名有歧义时（dim 既可指遮罩也可指次要文字），宁可**不豁免** ——
            // 漏报比误报危险：误报会被人看见，漏报不会。
            return [
                "spec-note", "note-list", "doc__", "state-tbl", "framecap", "legend",
                "frame__label",
            ]
            .contains { cls.contains($0) }
        }
        let voids: Set<String> = [
            "br", "img", "meta", "link", "input", "hr", "source",
            "path", "circle", "rect", "use", "stop", "line", "polyline", "polygon", "ellipse",
        ]
        var stack: [Node] = []
        var out: [ElementText] = []
        var i = html.startIndex
        while i < html.endIndex {
            if html[i] == "<" {
                guard let gt = html[i...].firstIndex(of: ">") else { break }
                var inner = String(html[html.index(after: i)..<gt])
                i = html.index(after: gt)
                if inner.hasPrefix("!") { continue }  // 注释 / DOCTYPE
                let closing = inner.hasPrefix("/")
                if closing { inner.removeFirst() }
                let selfClosing = inner.hasSuffix("/")
                if selfClosing { inner.removeLast() }
                let name =
                    inner.split(separator: " ").first.map { $0.lowercased() } ?? ""
                if closing {
                    guard let idx = stack.lastIndex(where: { $0.tag == name }) else { continue }
                    let ancestorWired =
                        stack[..<idx].contains { $0.attrs["data-i18n"] != nil }
                        || stack[..<idx].contains { isNote($0.attrs["class"]) }
                    for k in idx..<stack.count {
                        let n = stack[k]
                        out.append(
                            ElementText(
                                text: n.text,
                                key: n.attrs["data-i18n"],
                                note: isNote(n.attrs["class"]) || ancestorWired,
                                suppressed: ancestorWired || n.descWired
                                    || n.attrs["data-i18n"] != nil))
                    }
                    // 往上传递：本元素（或其后代）已接线 ⇒ 祖先不必再报
                    let wired =
                        stack[idx...].contains { $0.attrs["data-i18n"] != nil }
                        || stack[idx...].contains { $0.descWired }
                    stack.removeSubrange(idx...)
                    // ⚠️ 必须是 **||=**：兄弟元素（无 data-i18n）弹出时会把祖先的标记**清掉**
                    // ⇒ 祖先又被当成没接线（实测：05-settings 的开关行假红 4 处）。
                    if let last = stack.indices.last { stack[last].descWired = stack[last].descWired || wired }
                    continue
                }
                if !selfClosing, !voids.contains(name), !name.isEmpty {
                    var attrs: [String: String] = [:]
                    for pair in Self.attrPairs(in: inner) { attrs[pair.0] = pair.1 }
                    stack.append(Node(tag: name, attrs: attrs))
                }
                continue
            }
            let next = html[i...].firstIndex(of: "<") ?? html.endIndex
            let piece = String(html[i..<next])
            // `<script>` / `<style>` 里的文本不当文案
            let inRaw = stack.contains { ["script", "style"].contains($0.tag) }
            if !inRaw { for k in stack.indices { stack[k].text += piece } }
            i = next
        }
        return out
    }

    /// 取标签里的 `名="值"` 对。
    private static func attrPairs(in inner: String) -> [(String, String)] {
        // ⚠️ 属性名里有**数字**（`data-i18n`、`data-i`）：写成 `[a-zA-Z-]+` 会漏掉它们
        // ⇒ `data-i18n` 解析不出来 ⇒ 已接线的元素被当成没接线（本轮首跑 `wired → 0`）。
        guard let re = try? NSRegularExpression(pattern: #"([a-zA-Z][a-zA-Z0-9-]*)="([^"]*)""#)
        else { return [] }
        let range = NSRange(inner.startIndex..<inner.endIndex, in: inner)
        return re.matches(in: inner, range: range).compactMap { m in
            guard let a = Range(m.range(at: 1), in: inner), let b = Range(m.range(at: 2), in: inner)
            else { return nil }
            return (String(inner[a]), String(inner[b]))
        }
    }

    /// 界面里写死的中文，如果语言包里**明明有这条文案**，就必须接上 `data-i18n`。
    ///
    /// 漏接的症状：**切到英文时那一行还是中文** —— 不报错、不算漏翻（键压根没被引用）、
    /// 语言包的「覆盖」统计也看不出来。实测一轮扫出 **26 处**（§8.68）。
    ///
    /// 判据用「元素整文本 == 语言包 zh-Hans 的某个值」，因为两边都**逐字**对得上时，
    /// 接线是**零改动**的 —— 不存在「不知该挂哪个键」的歧义。
    @Test func 界面里写死的中文必须接上语言包() throws {
        let pack = try loadLanguagePack()
        guard let zh = pack["zh-Hans"] else {
            Issue.record("语言包里没有 zh-Hans 列")
            return
        }
        var byValue: [String: [String]] = [:]
        for (key, value) in zh {
            let plain = Self.plainText(value)
            guard !plain.isEmpty else { continue }
            byValue[plain, default: []].append(key)
        }
        #expect(byValue.count > 150, "只有 \(byValue.count) 条中文文案 —— 语言包没读全")

        var problems: [String] = []
        var wired = 0  // 已接线且整文本对得上键值的元素数（口径自证）
        let dir = designRoot.appendingPathComponent("screens")
        for name in try screenFiles() {
            for element in elementTexts(in: try read(dir.appendingPathComponent(name))) {
                let text = Self.plainText(element.text)
                guard let keys = byValue[text] else { continue }
                if let key = element.key {
                    if keys.contains(key) { wired += 1 }
                    continue
                }
                if element.note || element.suppressed { continue }
                problems.append("\(name)：'\(text)' → \(keys.joined(separator: " / "))")
            }
        }
        print("  [设计稿] 界面文案接线：整文本对得上的已接线元素 \(wired) 个")
        // 负向锚：**口径自证** —— 已接线的元素里必须有一大批整文本对得上，
        // 否则说明「整文本」的拼法与语言包对不上，下面「0 处漏接」就是假绿。
        #expect(
            wired >= 30,
            "只有 \(wired) 个已接线元素的整文本对得上语言包 —— 整文本口径失效（假绿）")
        #expect(
            problems.isEmpty,
            """
            页面上写死了这些中文，而语言包里**明明有**这条文案，却没接 `data-i18n`：
            \(problems.joined(separator: "\n  "))
            症状：**切到英文时那一行还是中文** —— 不报错、也不算漏翻（键压根没被引用）。
            两边是**逐字**对得上的，接上即可，不会改变中文显示。
            """)
    }

    /// CSS **变量**（自定义属性）的「用了没定义」 —— 此前一条守卫都没有。
    ///
    /// `var(--foo)` 拼错 / 定义被删 ⇒ 渲染出来是「**没这个样式**」，
    /// 而「样式没生效」与「本来就没写样式」在界面上**逐字相同**（§8.52 那一向的理由）。
    /// 本设计稿 **916 处** `var()` 引用，全靠这一条守。
    ///
    /// ⚠️ 变量有**页面作用域**：`06-states.html` 的 `<style>` 里定义的变量，
    /// `01-main-window.html` **拿不到**。所以按**页**解析（`ds.css` ∪ 本页 `<style>`），
    /// **不能**把所有页面的 `<style>` 汇总 —— 汇总会把跨页断链判成可达。
    /// （本轮实测 9 个页面的 `<style>` 里**一个变量定义都没有**，两种口径目前同结果；
    ///  按页写是为了将来有人加页面级变量时不至于静默放过 —— 变异 M21 钉的就是这条。）
    ///
    /// `var(--x, 兜底)` **不算断** —— 作者明说了「没有就用兜底值」。
    /// 全库目前 0 处兜底写法，这条逻辑由变异 M22 的**绿**对照钉住。
    @Test func 用了但没定义的CSS变量一个都不许有() throws {
        let scan = try loadCSSVariables()

        // 锚：定义侧与使用侧**都得扫到足够多**，否则「0 处断链」只是「两边都没扫到」。
        #expect(scan.defined.count >= 60, "只解析到 \(scan.defined.count) 个变量定义 —— ds.css 没读到")
        #expect(
            scan.defined.contains("--fs-11") && scan.defined.contains("--text-3"),
            "`--fs-11` / `--text-3` 不在定义集里 —— 定义侧的正则坏了")
        #expect(scan.pages.count >= 9, "只扫到 \(scan.pages.count) 个页面 —— 逐页扫描坏了")
        for p in scan.pages {
            #expect(!p.used.isEmpty, "\(p.name) 一个 var() 都没扫到 —— 使用侧解析坏了（假绿）")
        }
        let occurrences = scan.pages.reduce(0) { $0 + $1.used.count }
        #expect(occurrences >= 500, "只扫到 \(occurrences) 处 var() —— 量级不对（实际 900+ 处）")

        for p in scan.pages where !p.missing.isEmpty {
            #expect(
                p.missing.isEmpty,
                """
                \(p.name) 用了这些**解析不到**的 CSS 变量：\(Set(p.missing).sorted().joined(separator: ", "))
                `var(--x)` 拿不到值时**不报错**，只是那一处样式没了 ——
                而「样式没了」和「这儿本来就没写样式」在界面上长得一模一样。
                """)
        }
    }

    /// **反向**（定义了但没人用）只记录，不报警 —— 与 §8.52.5 同一个判据：
    /// 设计稿里的「存货」**多数是合理的**（备用令牌），删它会改变视觉。
    @Test func 定义了但没用的CSS变量只记录不报警() throws {
        let scan = try loadCSSVariables()
        var used: Set<String> = []
        for p in scan.pages { used.formUnion(p.used) }
        let unused = scan.defined.subtracting(used).sorted()
        print("[设计稿] 定义了但没用到的 CSS 变量：\(unused.count) 个 —— \(unused.joined(separator: ", "))")
    }

    // MARK: ds.js 查询的 DOM 目标

    /// **ds.js 查询不到目标 ⇒ 那段逻辑静默不生效**，与「这段逻辑本来就没触发」逐字相同。
    ///
    /// `document.querySelectorAll('[data-lang-btn]')` 选中 0 个元素时**不报错** ——
    /// JS 里的空集合是合法的。于是「接线断了」与「功能没写」在界面上长得一模一样
    /// （与 §8.47「updater 从来没启动过」同形，只是那一侧是 Swift、这一侧是 JS）。
    ///
    /// ⚠️ **元素从哪来不止一个来源**（上一轮踩的坑，见 §8.57.2）：
    /// HTML 静态 `class="…"` 之外，ds.js 自己还会造 ——
    /// `.className = '…'` / `classList.add(…)` / `setAttribute('data-lang-btn', …)`。
    /// 只认 HTML 静态会把 `.langbar` 误判成断链。所以来源是**并集**，
    /// 且由两条**负向锚**（`langbar` / `data-lang-btn` 必须在已知集里）钉住 ——
    /// 若哪天这两条来源的解析坏了，守卫会**先红在这里**，而不是误报一堆断链。
    private static let unresolvedDOMTargets: [String: String] = [
        "data-i18n-attr":
            """
        ds.js 实现了**属性级翻译**（`data-i18n-attr="aria-label:键,title:键"`，
        用法就写在 ds.js:136 的注释里），但设计稿里**一个元素都没用** ⇒ 这段代码从不执行。
        而硬编码中文的 `aria-label` / `title` 有 **67 处** ——
        切到英文时正文翻了、**无障碍标签仍是中文**（VoiceOver 会念中文），
        而 aria-label 不显示，**走查看不出来**。
        要不要接线（以及接哪些）是设计决策，待拍板；这里先登记，由「不得增加」那条守住别再恶化。
        """
    ]

    @Test func 脚本查询的DOM目标必须存在() throws {
        let s = try loadDOM()

        // 锚：三张已知表都得有货，否则「0 处断链」只是「三张表都是空的」。
        #expect(s.selectors.count >= 15, "只解析到 \(s.selectors.count) 个查询 —— ds.js 没读到")
        #expect(s.classes.count >= 150, "只解析到 \(s.classes.count) 个 class —— HTML/ds.js 没读到")
        #expect(s.ids.count >= 30, "只解析到 \(s.ids.count) 个 id")
        #expect(s.attrs.count >= 8, "只解析到 \(s.attrs.count) 个属性")

        // 负向锚：这两个名字**只能**由 ds.js 的动态创建提供。
        // 它们不在已知集 ⇒ 不是「设计稿断了」，是**我的解析漏了来源**（假红）。
        #expect(s.classes.contains("langbar"), "`langbar` 不在已知集 —— `.className = '…'` 这条来源漏了（会假红）")
        #expect(
            s.attrs.contains("data-lang-btn"),
            "`data-lang-btn` 不在已知集 —— `setAttribute(…)` 这条来源漏了（会假红）")

        let unregistered = Set(s.missing.map { $0.target }).subtracting(Self.unresolvedDOMTargets.keys)
        let detail = s.missing
            .filter { unregistered.contains($0.target) }
            .map { "\($0.form)('\($0.selector)') → \($0.target)" }
            .sorted().joined(separator: "\n  ")
        #expect(
            unregistered.isEmpty,
            """
            ds.js 查询的这些目标**在设计稿里不存在**（且没登记）：
              \(detail)
            选中 0 个元素**不报错** —— 那段逻辑会静默不生效。
            若是 ds.js 自己动态创建的，补一条来源解析；若是设计稿真断了，修 HTML；
            若是有意保留的能力，登记进 `unresolvedDOMTargets` 并写清理由。
            """)
    }

    /// 豁免表**不许过期**：登记为「没人用」的目标，一旦有元素在用了就要回来划掉。
    @Test func 已登记的DOM目标如果有元素在用了要划掉() throws {
        let s = try loadDOM()
        let stale = Self.unresolvedDOMTargets.keys.filter { s.htmlAttrs.contains($0) }
        #expect(
            stale.isEmpty,
            """
            这些目标登记为「没有元素在用」，但 HTML 里**已经有了**：\(stale.sorted().joined(separator: ", "))
            还了账就回来划掉 —— 否则这张表会像 §8.33 那 6 条一样越积越不可信。
            """)
    }

    /// **量化基线**：硬编码中文的无障碍标签**只许减少，不许增加**。
    ///
    /// 修不修那 67 处是设计决策（要拍板），但**继续劣化是不需要讨论的** ——
    /// 每新增一处，切到英文时它就又是「中文的无障碍标签」。
    /// 报红时一定有问题（只可能因为新增），所以它可以进 CI。
    @Test func 硬编码中文的无障碍标签不得增加() throws {
        var n = 0
        for url in try htmlFiles() {
            let text = Self.withoutStyleBlocks(try read(url))
            for v in Self.matches(in: text, pattern: #"(?:aria-label|title)="([^"]*)""#) {
                if v.range(of: #"[\u{4e00}-\u{9fff}]"#, options: .regularExpression) != nil { n += 1 }
            }
        }
        #expect(
            n <= Self.hardcodedA11yBaseline,
            """
            硬编码中文的 `aria-label` / `title` 现在是 \(n) 处，基线 \(Self.hardcodedA11yBaseline) 处 —— **增加了**。
            新增的部分切到英文时不会跟着变（VoiceOver 会念中文），而 aria-label 不显示、走查看不出来。
            要么用 `data-i18n-attr="aria-label:键,title:键"` 接上翻译，要么说明为什么这里是例外。
            """)
    }

    /// 基线 = 2026-09-19 实测的 **67 处**。修掉会变小（仍绿），新增会变大（必红）。
    private static let hardcodedA11yBaseline = 67

    // MARK: 索引 ↔ 页面自身标题（§8.62）

    /// 索引里**指向某个页面**的链接，其文字必须包含**该页面自己 `<title>` 的主名**。
    ///
    /// 这一类的静默性：改了页面标题（或改了索引里的叫法），**两边都不报错** ——
    /// 读者按索引点进去，看到的是另一个名字，只会以为自己记错了。
    /// 首跑就抓到一处真的：04 号页在卡片里叫「完全磁盘访问引导」，
    /// 而它自己的标题（与导航链接）叫「授权引导」—— **同一页面两个名字**。
    ///
    /// ⚠️ 口径是「**包含**」而不是「相等」：导航链接是短名（相等），
    /// 卡片链接带 `SCREEN 04` 前缀与一整句描述（只可能是子串）。
    /// 一开始按「相等」写会 16 条全红 —— 那是**假红**（描述性文案本来就长）。
    @Test func 索引里指向页面的名字必须与该页面自己的标题一致() throws {
        let s = try loadLinks()

        // 负向锚：解析不到链接 = 口径失效，不是「全都一致」
        #expect(s.links.count >= 8, "只解析到 \(s.links.count) 条指向页面的链接 —— 解析口径失效（假绿）")

        var mismatches: [String] = []
        for link in s.links {
            let file = designRoot.appendingPathComponent(link.href)
            guard FileManager.default.fileExists(atPath: file.path) else {
                mismatches.append("\(link.href)：索引指向的文件不存在")
                continue
            }
            guard let main = try pageMainTitle(link.href) else {
                mismatches.append("\(link.href)：页面里读不到 <title>")
                continue
            }
            if !link.text.contains(main) {
                mismatches.append("\(link.href)：索引写「\(link.text)」，页面标题主名是「\(main)」")
            }
        }
        #expect(
            mismatches.isEmpty,
            """
            索引与页面自己的标题对不上：
            \(mismatches.joined(separator: "\n  "))
            改了页面标题、或改了索引里的叫法，**两边都不会报错** ——
            读者按索引点进去看到另一个名字，只会以为自己记错了。
            统一成一个名字（页面 `<title>` 是准绳：它是页面对自己的正式命名）。
            """)
    }

    /// 页面**自己**的两个名字必须一致：`<title>` 主名 与 `<h1>`。
    ///
    /// 这一处比「索引 ↔ 页面」更近：用户打开页面，浏览器标签是一个名字、
    /// 页面大标题是另一个名字 —— 而**没有任何东西会报错**。
    /// 首跑同样只红 04 号页（`<title>`「授权引导」 vs `<h1>`「完全磁盘访问引导」），
    /// 其余 7 页**逐字相等** ⇒ 这个「相等」口径没有假红。
    @Test func 页面自己的大标题必须与它自己的title一致() throws {
        let files = try screenFiles()
        var mismatches: [String] = []
        for name in files {
            let rel = "screens/\(name)"
            guard let main = try pageMainTitle(rel) else {
                mismatches.append("\(rel)：读不到 <title>")
                continue
            }
            guard let h1 = try pageH1(rel) else {
                mismatches.append("\(rel)：读不到 <h1>")
                continue
            }
            if h1 != main {
                mismatches.append("\(rel)：<title> 主名「\(main)」 vs <h1>「\(h1)」")
            }
        }
        #expect(
            mismatches.isEmpty,
            """
            页面自己的两个名字对不上：
            \(mismatches.joined(separator: "\n  "))
            浏览器标签显示一个名字、页面大标题显示另一个，**没有任何东西会报错** ——
            读者只会以为有两个不同的页面。以 `<title>` 为**（它是页面对自己的正式命名）。
            """)
    }

    /// 反向（缺位）：**每个页面都必须被索引链接到**。
    ///
    /// ⚠️ 与 §8.61 那条相反：这一向**可以**靠扫描守住 ——
    /// 「页面文件集合」与「索引链接集合」都是现成的，不依赖历史，
    /// 所以「新加了一屏却忘记挂进索引」能判出来（那一屏从此没人找得到）。
    @Test func 每个页面都必须被索引链接到() throws {
        let s = try loadLinks()
        let linked = Set(s.links.map { $0.href })
        let fm = FileManager.default
        let screensDir = designRoot.appendingPathComponent("screens")
        let files = (try fm.contentsOfDirectory(atPath: screensDir.path))
            .filter { $0.hasSuffix(".html") }.sorted()

        #expect(!files.isEmpty, "screens/ 下一个页面都没有 —— 路径错了（假绿）")

        let orphans = files.filter { !linked.contains("screens/\($0)") }
        #expect(
            orphans.isEmpty,
            """
            这些页面**没有被索引链接到**：\(orphans.joined(separator: ", "))
            新增一屏却忘记挂进 index.html，**不会有任何报错** ——
            它就在那里，但没人点得到（与 §8.45「有能力、没接线」同形）。
            """)
    }

    // MARK: 扫描

    // MARK: 页面之间的导航 + 文档清单（§8.63）

    /// 每个页面顶部 `<nav>` 必须**列全所有屏** —— 上一轮守的是「index → 页面」，
    /// 这一向是「**页面 → 页面**」：新增一屏却忘了在 8 个页面的 nav 里加，
    /// 从其他任何一屏都**点不过去**（只能退回 index），而**没有任何东西会报错**。
    @Test func 每个页面的导航必须列全所有屏() throws {
        let all = Set(try screenFiles())
        var problems: [String] = []
        for page in try screenFiles() {
            let links = Set(try navLinks(of: page).map { $0.href })
            // 负向锚：一个 nav 链接都解析不到 = 口径失效，不是「列全了」
            if links.isEmpty {
                problems.append("\(page)：nav 里一个页面链接都没解析到 —— 解析口径失效（假绿）")
                continue
            }
            let missing = all.subtracting(links).sorted()
            if !missing.isEmpty {
                problems.append("\(page)：nav 缺 \(missing.joined(separator: ", "))")
            }
        }
        #expect(
            problems.isEmpty,
            """
            页面之间的导航不全：
            \(problems.joined(separator: "\n  "))
            新增一屏却忘了加进各页的 nav ⇒ 从其他任何一屏都**点不过去**，
            而这件事**不会有任何报错**（与 §8.45「有能力、没接线」同形）。
            """)
    }

    /// nav 里的**名字**也必须与该页面自己的 `<title>` 主名一致（实测当前 8×8 全对）。
    @Test func 导航里的页面名必须与页面自己的标题一致() throws {
        var problems: [String] = []
        for page in try screenFiles() {
            for link in try navLinks(of: page) {
                guard
                    FileManager.default.fileExists(
                        atPath: designRoot.appendingPathComponent("screens/\(link.href)").path)
                else {
                    problems.append("\(page)：nav 指向不存在的文件 \(link.href)")
                    continue
                }
                guard let main = try pageMainTitle("screens/\(link.href)") else { continue }
                if link.text != main {
                    problems.append("\(page) 的 nav 写「\(link.text)」，而 \(link.href) 的标题主名是「\(main)」")
                }
            }
        }
        #expect(
            problems.isEmpty,
            """
            导航里的名字与页面自己的标题对不上：
            \(problems.joined(separator: "\n  "))
            改了页面标题却没改 nav（或反过来）**两边都不报错** ——
            读者点进去发现名字不一样，只会以为那不是同一屏。
            """)
    }

    /// §9 文件清单里对每个页面的**说明**，必须包含该页面自己的 `<title>` 主名。
    ///
    /// 首跑抓到一处真的：03 号页的清单说明写「推出确认（破坏性）与失败弹窗」，
    /// 而它自己的标题主名是「**推出流程弹窗**」—— 7/8 通过，只有它不通过（⇒ 口径无假红）。
    @Test func 文件清单里的页面说明必须含该页面的标题主名() throws {
        let listing = try screenListing()
        #expect(
            listing.count >= 8,
            "§9 文件清单里只解析到 \(listing.count) 个页面 —— 解析口径失效（假绿）")

        var problems: [String] = []
        for (file, desc) in listing.sorted(by: { $0.key < $1.key }) {
            guard let main = try pageMainTitle("screens/\(file)") else { continue }
            if !desc.contains(main) {
                problems.append("§9 里 \(file) 的说明「\(desc)」不含它的标题主名「\(main)」")
            }
        }
        #expect(
            problems.isEmpty,
            """
            §9 文件清单的说明与页面自己的标题对不上：
            \(problems.joined(separator: "\n  "))
            页面改了名字而文档没跟上 ⇒ 读者按文档找的是旧名字，
            而文档与页面**都不会报错**（与 §8.62 那处同型，只是这一处在文档侧）。
            """)
    }

    // MARK: 页面引用的资源（§8.64）

    /// 每个页面都必须把**样式与两个脚本**都引上（缺哪个都是「页面还在、功能没了」）。
    ///
    /// 缺位类，但按 §8.61.2 的判据可以守：**「该有的全集」可派生**（页面集合 + 固定的三个资源）。
    @Test func 每个页面都必须引用样式与脚本() throws {
        let required = ["ds.css", "i18n.js", "ds.js"]
        var problems: [String] = []
        for url in try htmlFiles() {
            let html = try read(url)
            let refs =
                Self.matches(in: html, pattern: ##"<link[^>]+href="([^"]+\.css)""##)
                + Self.matches(in: html, pattern: ##"<script[^>]+src="([^"]+\.js)""##)
            let have = Set(refs.map { ($0 as NSString).lastPathComponent })
            // 负向锚：一个 css/js 都没扫到 = 口径失效，不是「都引了」
            if have.isEmpty {
                problems.append("\(url.lastPathComponent)：一个 css/js 引用都没解析到 —— 解析口径失效（假绿）")
                continue
            }
            let missing = required.filter { !have.contains($0) }
            if !missing.isEmpty {
                problems.append("\(url.lastPathComponent)：没引 \(missing.joined(separator: " / "))")
            }
        }
        #expect(
            problems.isEmpty,
            """
            有页面的样式 / 脚本没引全：
            \(problems.joined(separator: "\n  "))
            少引一个，页面**还在**，只是样式或交互没了 —— 浏览器只在控制台报 404，
            走查时「页面能打开」会让人以为没问题。
            """)
    }

    /// `ds.js` 依赖 `i18n.js` 先定义 `window.DS_L10N` / `window.DS_LANGS`
    /// （ds.js line 145/192 直接读这两个全局量）。
    ///
    /// ⚠️ 这个依赖**只存在于 HTML 里 `<script>` 的先后顺序**，代码里没有任何声明 ——
    /// 交换两行 ⇒ 语言包未定义 ⇒ 文案全空，而**交换两行不会有任何报错**。
    /// 与 §8.45「有能力、没接线」同族：**依赖是隐式的，就一定要有个地方把它钉住。**
    @Test func 语言包必须排在dsjs之前() throws {
        var problems: [String] = []
        for url in try htmlFiles() {
            let html = try read(url)
            let scripts = Self.matchesWithLocation(
                in: html, pattern: ##"<script[^>]+src="([^"]+\.js)""##
            ).map { (($0.text as NSString).lastPathComponent, $0.location) }
            let names = scripts.map { $0.0 }
            guard let i18n = names.firstIndex(where: { $0.contains("i18n") }),
                let ds = names.firstIndex(of: "ds.js")
            else {
                problems.append("\(url.lastPathComponent)：没同时引到 i18n.js 与 ds.js（\(names)）")
                continue
            }
            if i18n > ds {
                problems.append(
                    "\(url.lastPathComponent)：i18n.js（第 \(i18n + 1) 个脚本）排在 ds.js（第 \(ds + 1) 个）之后")
            }
        }
        #expect(
            problems.isEmpty,
            """
            语言包与 ds.js 的加载顺序不对：
            \(problems.joined(separator: "\n  "))
            ds.js 启动时直接读 window.DS_L10N / window.DS_LANGS（都由 i18n.js 定义），
            而这个依赖**只体现在 HTML 里两个 <script> 的先后** —— 交换两行不报错，
            只会让语言包变成 undefined（文案全空）。
            """)
    }

    /// 页面里引用的**本地**资源必须真实存在（相对该页面解析）。
    ///
    /// 浏览器对 404 只在**控制台**报一下：样式表 404 ⇒ 页面变成裸 HTML，
    /// 图标 404 ⇒ 那个位置空着，两者在「页面能打开」这件事上都看不出来。
    @Test func 页面引用的本地资源必须存在() throws {
        var problems: [String] = []
        var total = 0
        for url in try htmlFiles() {
            let html = try read(url)
            let dir = url.deletingLastPathComponent()
            // ⚠️ 定界符必须是 `##"…"##` 且**末尾三连引号**：正则以 `"` 收尾（匹配属性值
            // 的右引号），它后面还得再跟一个 `"` 才是 raw string 的结束引号，然后才是 `##`。
            // 只写两个引号 ⇒ 编译器把 `"` 当成正则内容，`##` 成了裸的磅字面量（编译不过）。
            for raw in Self.matches(in: html, pattern: ##"(?:href|src)="([^"]+)""##) {
                let ref = raw.split(separator: "#")[0].split(separator: "?").joined()
                guard !ref.isEmpty,
                    !ref.hasPrefix("#"), !ref.hasPrefix("http://"), !ref.hasPrefix("https://"),
                    !ref.hasPrefix("mailto:"), !ref.hasPrefix("data:"), !ref.hasPrefix("javascript:")
                else { continue }
                total += 1
                let resolved = dir.appendingPathComponent(String(ref))
                if !FileManager.default.fileExists(atPath: resolved.path) {
                    problems.append("\(url.lastPathComponent)：'\(ref)' → \(resolved.path)")
                }
            }
        }
        // 负向锚：一条本地引用都没扫到 = 口径失效
        #expect(total >= 20, "只扫到 \(total) 条本地引用 —— 解析口径失效（假绿）")
        #expect(
            problems.isEmpty,
            """
            页面引用了不存在的本地资源：
            \(problems.joined(separator: "\n  "))
            浏览器对 404 **只在控制台报一下**：样式表没了页面变成裸 HTML、
            图片没了那个位置空着 —— 而「页面能打开」这件事完全不受影响。
            """)
    }

    private struct LinkScan {
        var links: [(href: String, text: String)] = []
    }

    private func loadLinks() throws -> LinkScan {
        let idx = try read(designRoot.appendingPathComponent("index.html"))
        // 卡片链接是**多行**的（`<a class="scard-link" …>` 里嵌了标题与描述），
        // 导航链接是单行的 —— 一个正则要同时吃下两种，故 `.` 需跨行。
        //
        // ⚠️ 定界符必须用 **`##"`**：正则里的 `[^"#]` 含有 `"#` 这个序列，
        // 用普通 `#"…"#` 会被当成**字符串提前结束**（编译期报错：consecutive statements）。
        // 与 §8.50.3「注释会蒙过扫描器」同族：**自己写的文本里出现了自己用的定界符**。
        let pattern = ##"<a\s[^>]*href="(screens/[^"#]+)"[^>]*>(.*?)</a>"##
        guard
            let re = try? NSRegularExpression(
                pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return LinkScan() }
        var scan = LinkScan()
        let range = NSRange(idx.startIndex..<idx.endIndex, in: idx)
        for m in re.matches(in: idx, range: range) {
            guard let hr = Range(m.range(at: 1), in: idx),
                let tr = Range(m.range(at: 2), in: idx)
            else { continue }
            scan.links.append((String(idx[hr]), Self.plainText(String(idx[tr]))))
        }
        return scan
    }

    /// `<title>主名 · DiskEjector UI v2</title>` ⇒ `主名`（页面对自己的正式命名）。
    private func pageMainTitle(_ rel: String) throws -> String? {
        let html = try read(designRoot.appendingPathComponent(rel))
        guard let t = Self.matches(in: html, pattern: #"<title>(.*?)</title>"#).first else { return nil }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "·").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// 某个页面顶部 `<nav>` 里的页面链接（`<a href="0X-….html">名字</a>`）。
    private func navLinks(of page: String) throws -> [(href: String, text: String)] {
        let html = try read(designRoot.appendingPathComponent("screens/\(page)"))
        guard let nav = Self.match(in: html, pattern: ##"<nav[^>]*>(.*?)</nav>"##) else { return [] }
        let pattern = ##"<a\s+href="([\w-]+\.html)"[^>]*>(.*?)</a>"##
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(nav.startIndex..<nav.endIndex, in: nav)
        return re.matches(in: nav, range: range).compactMap { m in
            guard let hr = Range(m.range(at: 1), in: nav), let tr = Range(m.range(at: 2), in: nav)
            else { return nil }
            return (String(nav[hr]), Self.plainText(String(nav[tr])))
        }
    }

    /// §9 文件清单里「页面文件名 → 说明」。
    private func screenListing() throws -> [String: String] {
        let spec = try read(designRoot.appendingPathComponent("DESIGN-SPEC.md"))
        guard
            let block = Self.match(
                in: spec,
                pattern: ##"^## 9\. 文件清单\s*\n+```\n(.*?)\n```"##)
        else { return [:] }
        var out: [String: String] = [:]
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            guard let m = l.range(of: ##"(\d\d-[\w-]+\.html)\s+(\S.*)$"##, options: .regularExpression)
            else { continue }
            let parts = l[m]
            // 文件名 + 说明（说明里的 `#` 之后是行内注释，剥掉）
            guard let mm = Self.firstMatch(in: String(parts), pattern: ##"^(\d\d-[\w-]+\.html)\s+(.*?)(?:\s+#.*)?$"##)
            else { continue }
            out[mm.0] = mm.1
        }
        return out
    }

    /// 取**第一个**匹配（整段），用于 `<nav>…</nav>` 这类**跨行**块。
    ///
    /// ⚠️ 两个 option 都不能少：`.dotMatchesLineSeparators` 让 `.` 跨行；
    /// `.anchorsMatchLines` 让 `^` 匹配**行首**（默认只匹配字符串开头 ——
    /// 少了它，「第 9 章」这种不在文件开头的行永远匹配不到，且**不报错、只返回 nil**）。
    private static func match(in text: String, pattern: String) -> String? {
        guard
            let re = try? NSRegularExpression(
                pattern: pattern, options: [.dotMatchesLineSeparators, .anchorsMatchLines])
        else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: range), let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    /// 取第一个匹配的**两个捕获组**（文件名 / 说明）。
    /// 带**位置**（用于判断 `<script>` 的先后顺序）。
    private static func matchesWithLocation(
        in text: String, pattern: String
    ) -> [(
        text: String, location: Int
    )] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, range: range).compactMap { m in
            guard let r = Range(m.range(at: 1), in: text) else { return nil }
            return (String(text[r]), m.range.location)
        }
    }

    /// 取第一个匹配的**两个捕获组**（文件名 / 说明）。
    private static func firstMatch(in text: String, pattern: String) -> (String, String)? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: range),
            let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text)
        else { return nil }
        return (String(text[a]), String(text[b]))
    }

    /// 页面自己的 `<h1>`（取第一个）。
    private func pageH1(_ rel: String) throws -> String? {
        let html = try read(designRoot.appendingPathComponent(rel))
        guard let raw = Self.matches(in: html, pattern: ##"<h1[^>]*>(.*?)</h1>"##).first else { return nil }
        return Self.plainText(raw)
    }

    /// `screens/` 下的页面文件名（不含 index.html 等）。
    private func screenFiles() throws -> [String] {
        let dir = designRoot.appendingPathComponent("screens")
        return (try FileManager.default.contentsOfDirectory(atPath: dir.path))
            .filter { $0.hasSuffix(".html") }.sorted()
    }

    /// 去标签 + 压平空白（`SCREEN 04\n  名字 …` ⇒ 一行）。
    private static func plainText(_ html: String) -> String {
        let stripped = replace(in: html, pattern: #"<[^>]+>"#, with: "")
        return stripped.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    private struct Scan {
        var defined: Set<String> = []
        var used: Set<String> = []
    }

    private func load() throws -> Scan {
        let fm = FileManager.default
        var scan = Scan()

        // ① 主 CSS
        let cssURL = designRoot.appendingPathComponent("assets/ds.css")
        scan.defined.formUnion(Self.selectorClasses(in: Self.stripCSSComments(try read(cssURL))))

        // ② 每个 HTML：`<style>` 进「定义」，body 的 class 进「使用」
        let htmls = try htmlFiles()
        #expect(htmls.count >= 8, "只找到 \(htmls.count) 个 HTML —— 设计稿目录不对")
        for url in htmls {
            let raw = try read(url)
            for block in Self.styleBlocks(in: raw) {
                scan.defined.formUnion(Self.selectorClasses(in: Self.stripCSSComments(block)))
            }
            scan.used.formUnion(Self.classAttributes(in: Self.withoutStyleBlocks(raw)))
        }

        // ③ ds.js 动态注入的类也算消费者
        let jsURL = designRoot.appendingPathComponent("assets/ds.js")
        if fm.fileExists(atPath: jsURL.path) {
            scan.used.formUnion(Self.classAttributes(in: try read(jsURL)))
        }
        return scan
    }

    /// 返回（声明的键，被页面引用的键）。
    private func loadI18n() throws -> (declared: Set<String>, referenced: Set<String>) {
        let url = designRoot.appendingPathComponent("assets/i18n-extra.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            Issue.record("i18n-extra.json 顶层不是对象")
            return ([], [])
        }
        // `_comment` 是注释键，不是文案
        let declared = Set(dict.keys.filter { !$0.hasPrefix("_") })

        var referenced: Set<String> = []
        var corpus = ""
        for url in try htmlFiles() {
            corpus += Self.withoutStyleBlocks(try read(url))
        }
        let jsURL = designRoot.appendingPathComponent("assets/ds.js")
        if FileManager.default.fileExists(atPath: jsURL.path) { corpus += try read(jsURL) }

        // ① 精确形式：`data-i18n="key"`
        for m in Self.matches(in: corpus, pattern: #"data-i18n="([^"]+)""#) { referenced.insert(m) }
        // ② 精确形式：`data-i18n-attr="aria-label:key,title:key"` —— 冒号后面那半截才是键
        for raw in Self.matches(in: corpus, pattern: #"data-i18n-attr="([^"]+)""#) {
            for pair in raw.split(separator: ",") {
                if let v = pair.split(separator: ":").last { referenced.insert(String(v)) }
            }
        }
        // ③ 兜底（**偏松**）：键名以带引号的字符串形式出现就算被引用。
        //    会漏报、不会误报 —— 宁可放过，也不能把活着的键判成死的。
        for k in declared where corpus.contains("\"\(k)\"") { referenced.insert(k) }
        return (declared, referenced)
    }

    /// 返回（图标表里定义的名字，被 `data-i` 用到的名字）。
    private func loadIcons() throws -> (defined: Set<String>, used: Set<String>) {
        let js = try read(designRoot.appendingPathComponent("assets/ds.js"))
        // 图标表：`var I = { … }`，以缩进 2 空格的 `};` 收尾
        guard let block = Self.matches(in: js, pattern: #"var I = \{([\s\S]*?)\n  \};"#).first else {
            Issue.record("ds.js 里找不到 `var I = { … }` 图标表 —— 结构变了？")
            return ([], [])
        }
        let defined = Set(Self.matches(in: block, pattern: #"^\s*(\w+)\s*:"#, lines: true))

        var used: Set<String> = []
        for url in try htmlFiles() { used.formUnion(Self.matches(in: try read(url), pattern: #"data-i="([^"]+)""#)) }
        used.formUnion(Self.matches(in: js, pattern: #"data-i="([^"]+)""#))
        // i18n 文案值里也可以嵌 `<i data-i="gear">`（回填后会重新水合）
        let extraURL = designRoot.appendingPathComponent("assets/i18n-extra.json")
        if FileManager.default.fileExists(atPath: extraURL.path) {
            used.formUnion(Self.matches(in: try read(extraURL), pattern: #"data-i="([^"]+)""#))
        }
        return (defined, used)
    }

    /// 文案键的**声明集** = `i18n-extra.json` ∪ `Localizable.xcstrings`。
    private static func declaredTextKeys(repoRoot: URL) throws -> Set<String> {
        var out: Set<String> = []
        let extraURL = repoRoot.appendingPathComponent(
            "DiskEjector-UI-Design/v2/assets/i18n-extra.json")
        if let obj = try? JSONSerialization.jsonObject(with: Data(contentsOf: extraURL)) as? [String: Any] {
            out.formUnion(obj.keys.filter { !$0.hasPrefix("_") })
        }
        let xcsURL = repoRoot.appendingPathComponent("Sources/Localization/Localizable.xcstrings")
        if let obj = try? JSONSerialization.jsonObject(with: Data(contentsOf: xcsURL)) as? [String: Any],
            let strings = obj["strings"] as? [String: Any]
        {
            out.formUnion(strings.keys)
        }
        return out
    }

    /// 源指纹 = sha256(xcstrings → extra → 生成脚本)，**拼接顺序必须与
    /// `tools/build_i18n.py` 的 `fingerprint()` 逐字一致**（那边注释里标了顺序）。
    ///
    /// 顺序写反**不会报错** —— 只会算出另一个值，于是守卫**永远红**且看不出为什么。
    /// 所以顺带钉住三件事：三个输入都得读得到、**都得有内容**。
    /// 路径写错 ⇒ `Data(contentsOf:)` 直接抛 ⇒ 不会静默；但读到 0 字节不抛，只能靠这条。
    private static func sourceFingerprint(repoRoot: URL) throws -> String {
        let rels = [
            "Sources/Localization/Localizable.xcstrings",
            "DiskEjector-UI-Design/v2/assets/i18n-extra.json",
            "tools/build_i18n.py",
        ]
        var sha = SHA256()
        for rel in rels {
            let data = try Data(contentsOf: repoRoot.appendingPathComponent(rel))
            #expect(data.count > 200, "\(rel) 只有 \(data.count) 字节 —— 路径写错了？")
            sha.update(data: data)
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: CSS 变量

    private struct CSSVarPage {
        let name: String
        /// 出现次数（**含重复**）—— 用来判断「使用侧到底扫到多少」。
        var used: [String] = []
        /// 用了、**没写兜底**、且这一页解析不到的变量。
        var missing: [String] = []
    }

    private struct CSSVarScan {
        /// `ds.css` 里定义的（所有页面都引它，所以算全局可用）。
        var defined: Set<String> = []
        var pages: [CSSVarPage] = []
    }

    /// 变量**按页**解析：可用集 = `ds.css` ∪ **本页** `<style>`。
    /// `ds.css` 自己也作为一个「页」参与（它内部也在用 `var()`）。
    private func loadCSSVariables() throws -> CSSVarScan {
        let cssURL = designRoot.appendingPathComponent("assets/ds.css")
        let css = Self.stripCSSComments(try read(cssURL))
        var scan = CSSVarScan()
        scan.defined = Set(Self.matches(in: css, pattern: #"(--[\w-]+)\s*:"#))
        scan.pages.append(Self.page(name: "assets/ds.css", text: css, available: scan.defined))

        for url in try htmlFiles() {
            let raw = try read(url)
            let blocks = Self.styleBlocks(in: raw)
            var own: Set<String> = []
            for b in blocks {
                own.formUnion(Self.matches(in: Self.stripCSSComments(b), pattern: #"(--[\w-]+)\s*:"#))
            }
            // 本页可见 = 全局 + 本页 <style>（**不含别的页面**）
            let body =
                Self.withoutStyleBlocks(raw) + "\n"
                + blocks.map { Self.stripCSSComments($0) }.joined(separator: "\n")
            scan.pages.append(
                Self.page(
                    name: url.lastPathComponent,
                    text: body,
                    available: scan.defined.union(own)))
        }
        return scan
    }

    private static func page(name: String, text: String, available: Set<String>) -> CSSVarPage {
        // 带兜底的 `var(--x, …)`：作者明说了「没有就用兜底」，不算断链。
        let withFallback = Set(matches(in: text, pattern: #"var\(\s*(--[\w-]+)\s*,"#))
        var p = CSSVarPage(name: name)
        for v in matches(in: text, pattern: #"var\(\s*(--[\w-]+)"#) {
            p.used.append(v)
            if !withFallback.contains(v) && !available.contains(v) { p.missing.append(v) }
        }
        return p
    }

    // MARK: DOM 目标

    private struct DOMScan {
        /// （查询形式，选择器原文）
        var selectors: [(form: String, text: String)] = []
        var classes: Set<String> = []
        var ids: Set<String> = []
        /// 所有已知属性名 = HTML 静态 ∪ ds.js 动态赋值
        var attrs: Set<String> = []
        /// **只**从 HTML 静态解析到的属性名 —— 用来查「豁免表是不是过期了」
        var htmlAttrs: Set<String> = []
        /// （查询形式，选择器原文，解析不到的那个目标）
        var missing: [(form: String, selector: String, target: String)] = []
    }

    private func loadDOM() throws -> DOMScan {
        let js = try read(designRoot.appendingPathComponent("assets/ds.js"))
        var s = DOMScan()

        // ① 查询：四种调用形式 + `closest` / `matches`
        let forms: [(String, String)] = [
            ("querySelector", #"querySelector\(\s*['\"]([^'\"]+)['\"]"#),
            ("querySelectorAll", #"querySelectorAll\(\s*['\"]([^'\"]+)['\"]"#),
            ("getElementById", #"getElementById\(\s*['\"]([^'\"]+)['\"]"#),
            ("getElementsByClassName", #"getElementsByClassName\(\s*['\"]([^'\"]+)['\"]"#),
            ("closest/matches", #"\.(?:closest|matches)\(\s*['\"]([^'\"]+)['\"]"#),
        ]
        for (form, p) in forms {
            for text in Self.matches(in: js, pattern: p) { s.selectors.append((form, text)) }
        }

        // ② 来源 A：HTML 静态（`<style>` 里的内容不算）
        var corpus = ""
        for url in try htmlFiles() { corpus += Self.withoutStyleBlocks(try read(url)) }
        s.classes.formUnion(Self.classAttributes(in: corpus))
        s.ids.formUnion(Self.matches(in: corpus, pattern: #"\bid="([^"]+)""#))
        // ⚠️ 属性可能是**无值的**（`<div data-expandable>`），只认 `data-x=` 会漏掉它
        // ⇒ 用前瞻收到 `=` / 空白 / `>` 三种结尾。
        let htmlAttrs = Self.matches(in: corpus, pattern: #"\s(data-[\w-]+)(?=[\s=>])"#)
        s.htmlAttrs.formUnion(htmlAttrs)
        s.attrs.formUnion(htmlAttrs)

        // ③ 来源 B：ds.js 自己动态造出来的
        for v in Self.matches(in: js, pattern: #"\.className\s*=\s*['\"]([^'\"]+)['\"]"#) {
            s.classes.formUnion(v.split(separator: " ").map(String.init))
        }
        for v in Self.matches(in: js, pattern: #"classList\.(?:add|toggle|remove)\(\s*['\"]([^'\"]+)['\"]"#) {
            s.classes.insert(v)
        }
        for v in Self.matches(in: js, pattern: #"setAttribute\(\s*['\"]class['\"]\s*,\s*['\"]([^'\"]+)['\"]"#) {
            s.classes.formUnion(v.split(separator: " ").map(String.init))
        }
        s.ids.formUnion(Self.matches(in: js, pattern: #"\.id\s*=\s*['\"]([^'\"]+)['\"]"#))
        // 任意属性名（含 `aria-*` / `data-*`）—— 只要 ds.js 会写出来，这个属性就算「存在」
        s.attrs.formUnion(Self.matches(in: js, pattern: #"setAttribute\(\s*['\"]([\w-]+)['\"]"#))

        // ④ 判定：`#id` / `.class` / `[attr]` 三种目标各自查表
        for (form, text) in s.selectors {
            // ⚠️ `target` 一律存**裸名**（不带 `#` / `.` / `[]`）——
            // 豁免表的键也是裸名，两边形状不同就会**永远匹配不上**（账本形同虚设）。
            switch form {
            case "getElementById":
                if !s.ids.contains(text) { s.missing.append((form, text, text)) }
            case "getElementsByClassName":
                if !s.classes.contains(text) { s.missing.append((form, text, text)) }
            default:
                for i in Self.matches(in: text, pattern: #"#([\w-]+)"#) where !s.ids.contains(i) {
                    s.missing.append((form, text, i))
                }
                for c in Self.matches(in: text, pattern: #"\.([\w-]+)"#) where !s.classes.contains(c) {
                    s.missing.append((form, text, c))
                }
                for a in Self.matches(in: text, pattern: #"\[([\w-]+)[\]=]"#) where !s.attrs.contains(a) {
                    s.missing.append((form, text, a))
                }
            }
        }
        return s
    }

    /// 取正则的第 1 捕获组。
    /// - parameter lines: 需要 `^` 按行匹配时打开（例如逐行取对象的键）。
    private static func matches(in text: String, pattern: String, lines: Bool = false) -> [String] {
        guard
            let re = try? NSRegularExpression(
                pattern: pattern, options: lines ? [.anchorsMatchLines] : []
            )
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, range: range).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func htmlFiles() throws -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: designRoot, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "html" }.sorted { $0.path < $1.path }
    }

    /// 去掉 `/* … */` 注释（注释里常写着别的数字 / 类名，不剥会误收）。
    private static func stripCSSComments(_ text: String) -> String {
        Self.replace(in: text, pattern: #"/\*[\s\S]*?\*/"#, with: " ")
    }

    /// 取 `<style>` 块 —— **第二个定义源**，别漏（§8.52.1）。
    private static func styleBlocks(in html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"<style[^>]*>([\s\S]*?)</style>"#) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return re.matches(in: html, range: range).compactMap { m in
            Range(m.range(at: 1), in: html).map { String(html[$0]) }
        }
    }

    private static func withoutStyleBlocks(_ html: String) -> String {
        Self.replace(in: html, pattern: #"<style[^>]*>[\s\S]*?</style>"#, with: " ")
    }

    /// 只取**选择器位置**的类名 —— 先抹掉声明体，否则属性值里的 `.5px` 之类会被误收。
    private static func selectorClasses(in css: String) -> Set<String> {
        var text = css
        // `@media (…) {` 的条件部分先抹掉（保留 `{`），否则里面的类会被当成属性值
        text = Self.replace(in: text, pattern: #"@media[^{]*"#, with: " ")
        text = Self.replace(in: text, pattern: #"\{[^}]*\}"#, with: "{ }")
        guard
            let re = try? NSRegularExpression(
                pattern: #"(?:^|[\s,>+~])\.([a-zA-Z][\w-]*)"#, options: [.anchorsMatchLines]
            )
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(
            re.matches(in: text, range: range).compactMap { m in
                Range(m.range(at: 1), in: text).map { String(text[$0]) }
            })
    }

    private static func classAttributes(in html: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: #"class="([^"]*)""#) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var out: Set<String> = []
        for m in re.matches(in: html, range: range) {
            guard let r = Range(m.range(at: 1), in: html) else { continue }
            out.formUnion(String(html[r]).split(separator: " ").map(String.init))
        }
        return out
    }

    private static func replace(in text: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
