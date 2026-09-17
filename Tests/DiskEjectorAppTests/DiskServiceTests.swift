import DiskArbitration
import Foundation
import Testing

@testable import DiskEjectorApp

/// `DiskService` 里**不碰硬件的那一半**：`makeDiskInfo` 的组装规则。
///
/// ## 为什么只测这一半
///
/// `DiskService` 分成两层：
///
/// | 层 | 内容 | 怎么测 |
/// |---|---|---|
/// | **枚举** | `DASessionCreate` + `mountedVolumeURLs` + `DADiskCopyDescription` | 只能靠真机 —— `IntegrationEjectTests` 自己挂一个 dmg 卷 |
/// | **组装** | 从 URL + 描述字典拼 `DiskInfo` | **本文件** —— 喂参数就行，不依赖本机插了什么 |
///
/// 本文件本身就是一次事故的产物：2026-09-17 发现 `DiskService` 的那 77 行
/// **从来不是被单测覆盖的** —— 是「某个测试构造 `ContentView` → 摸到生产单例
/// → 本机恰好插着盘」蹭来的（`DESIGN-SPEC.md` §8.28.6）。
/// 把那条暗道堵掉后它诚实地掉到 **0/94**，于是把真正能测的这一层补上。
///
/// > **判据**：**覆盖率掉了不等于回归，也可能是「原来那部分覆盖率是假的」。**
/// > 区分方法：看它原来是被**断言**覆盖的，还是被**副作用**覆盖的 ——
/// > 后者会在有人整理依赖关系时整块蒸发。
struct DiskServiceTests {

    private let service = DiskService()

    /// 一个必然存在的目录。
    ///
    /// 用临时目录而不是 `/Volumes/...`：**测试不能依赖本机插了什么盘** ——
    /// 这正是本文件要守的那条纪律，夹具自己先得做到。
    private var tempDir: URL { FileManager.default.temporaryDirectory }

    /// 一份「描述齐全」的 DiskArbitration 字典。
    private func description(
        bsdName: String? = "disk9s2",
        model: String? = "SanDisk Extreme 55AE",
        protocolName: String? = "USB"
    ) -> [String: Any] {
        var d: [String: Any] = [:]
        if let bsdName { d[kDADiskDescriptionMediaBSDNameKey as String] = bsdName }
        if let model { d[kDADiskDescriptionDeviceModelKey as String] = model }
        if let protocolName { d[kDADiskDescriptionDeviceProtocolKey as String] = protocolName }
        return d
    }

    @Test func 描述齐全时按字典组装() throws {
        let info = try #require(service.makeDiskInfo(url: tempDir, description: description()))

        #expect(
            info.id == tempDir.path,
            "id 必须就是挂载路径 —— 它是占用结论那张字典的键，错一次就张冠李戴")
        #expect(info.mountPath == tempDir.path)
        #expect(info.bsdName == "disk9s2")
        #expect(info.deviceProtocol == "USB")
        #expect(info.deviceModel == "SanDisk Extreme 55AE")
        #expect(!info.volumeName.isEmpty, "卷名取自 URL 资源值，真实卷一定有名字")
        #expect(info.totalBytes > 0, "总容量取自 URL 资源值，真实卷一定 > 0")
        #expect(
            info.usedBytes + info.freeBytes == info.totalBytes,
            "已用 + 可用必须等于总量 —— 三者由同一次读数的 total 与 available 得到，对不上就是算错了")
    }

    /// **静默退化 1**：描述里没有 BSD 名时，回退成 `url.lastPathComponent`。
    ///
    /// 这条断言的作用不是「证明回退是对的」，而是**把这个行为钉住**：
    /// 它会让界面上显示的设备名从 `disk9s2` 变成卷名 —— 不报错，只是看着像另一块盘。
    /// 以后谁想改成「缺了就跳过这块盘」，会在这里看见自己改动了什么。
    @Test func 描述缺BSD名时回退成路径末段() throws {
        let info = try #require(
            service.makeDiskInfo(url: tempDir, description: description(bsdName: nil)))
        #expect(info.bsdName == tempDir.lastPathComponent)
        #expect(info.bsdName != "disk9s2")
    }

    /// **静默退化 2**：读不到容量就整块跳过（宁可漏列，也不列一块容量未知的盘）。
    ///
    /// 用一个**不存在的路径**逼出这条：`resourceValues` 要么抛错、要么给不出容量，
    /// 两条路都应当收成 `nil`，而不是崩掉、也不是返回一块 `totalBytes == 0` 的盘。
    @Test func 读不到容量时返回nil而不是零容量() {
        let missing = tempDir.appendingPathComponent("DiskEjector-不存在的路径-\(UUID().uuidString)")
        let info = service.makeDiskInfo(url: missing, description: description())
        #expect(
            info == nil,
            "容量读不到时必须返回 nil —— 返回一块 0 字节的盘，用户会以为盘是空的")
    }
}
