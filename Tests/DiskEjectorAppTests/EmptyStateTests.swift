import SwiftUI
import Testing

@testable import DiskEjectorApp

/// 「列表为空时画骨架还是空状态」的判定契约。
///
/// **为什么单独一个文件**：这里修的是一个**确定性 bug**（2026-09-17 用户报
/// 「电脑上没插移动硬盘，打开主窗口一直显示首次加载的骨架层」）。旧写法把骨架的
/// **开启**判据写成「`disks` 为空」，而**关闭**只挂在 `onChange(of: store.disks)` 上：
///
/// - 没插盘时，刷新前是 `[]`、刷新后还是 `[]` —— **列表根本没变化，`onChange` 不触发**；
/// - 于是 300ms 闸门打开后，没有任何东西再把它关掉，骨架永驻。
///
/// 「加载完了但确实没有外置磁盘」与「还没加载完」是两种状态，
/// 但它们在 `disks` 上的表现**都是空数组** —— 只看空数组分不开，必须看加载是否结束。
///
/// ## 为什么只有纯函数测试，没有离屏渲染测试
///
/// **离屏渲染结构上测不到这个 bug**：`cacheDisplay` 不跑 SwiftUI 的 `.task`
/// （没有事件循环），两个状态位都停在初始值 `false`，算出来永远是「不显示骨架」——
/// 无论实现是对是错，渲染结果都一样。这与交通灯「离屏没有窗口」是同一类问题。
/// 渲染层的守卫在真机自检
/// （`AppDelegate.checkEmptyStateInsteadOfSkeleton`，跑 `--preview-main-window-keys`）。
@MainActor
struct EmptyStateTests {

    /// 闸门还没到、加载也没结束 —— 磁盘枚举通常 < 50ms，这时不该闪骨架。
    @Test func 闸门未到时不显示骨架() {
        #expect(
            !ContentView.showsSkeleton(gatePassed: false, hasFinishedInitialLoad: false),
            "300ms 闸门还没放行就显示骨架，界面会「闪一下」——比什么都不显示更糟")
    }

    /// 闸门到了、加载还没结束 —— 这才是骨架存在的意义（慢加载的占位）。
    @Test func 加载未结束时显示骨架() {
        #expect(
            ContentView.showsSkeleton(gatePassed: true, hasFinishedInitialLoad: false),
            "加载超过 300ms 还没结束，应当显示骨架层作为占位")
    }

    /// **本 bug 的核心判据**：加载已经结束（哪怕结果是「一块盘都没有」），必须显示空状态。
    ///
    /// 变异验证：把 `showsSkeleton` 改回 `gatePassed && disks.isEmpty` 那种写法
    /// （或让 `hasFinishedInitialLoad` 不参与判断），本断言立刻变红 ——
    /// 那正是「没插移动硬盘时骨架永驻」的成因。
    @Test func 加载已结束时不显示骨架() {
        #expect(
            !ContentView.showsSkeleton(gatePassed: true, hasFinishedInitialLoad: true),
            """
            首屏加载已经结束，却仍要画骨架层 —— 这就是用户报的现象：\
            没插移动硬盘时刷新前后列表都是空，`onChange` 不触发，骨架永远关不掉。\
            判据必须看「加载是否结束」，不能看「列表是否为空」。
            """
        )
    }

    /// 补齐真值表最后一种组合（闸门未到 + 已加载完）——
    /// 四种组合全测过，才说明「两个输入都真的参与判断」，
    /// 而不是恰好让某几条断言在退化实现上也是绿的。
    @Test func 闸门未到但已加载完不显示骨架() {
        #expect(
            !ContentView.showsSkeleton(gatePassed: false, hasFinishedInitialLoad: true),
            "加载已结束，闸门放不放行都不该显示骨架")
    }
}
