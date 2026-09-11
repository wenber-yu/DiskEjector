import DiskArbitration
import Foundation
import OSLog

/// 外置卷枚举。
///
/// **为什么从「路径前缀判断」换成 DiskArbitration**：
///
/// 旧实现用 `volumeURL.path.hasPrefix("/Volumes")` 判断外置，这在语义上是用「挂载位置」
/// 猜测「设备属性」。挂载位置是系统的安排，不是设备的属性——网络卷、磁盘映像、
/// 部分系统合成卷都会出现在 `/Volumes` 下，而内置盘在未来系统版本里的挂载位置也可能变化。
///
/// DiskArbitration 提供的是设备自身声明的属性，是 macOS 上判断「这块盘能不能拔」的
/// 事实来源（Finder 同样基于它）。实测在 App Sandbox 下 `DADiskCopyDescription` 可正常读取，
/// 因此可以用于上架版本。
class DiskService: @unchecked Sendable {
    static let shared = DiskService()

    /// 开放给测试注入 mock 子类；生产环境一律使用 `shared`。
    init() {}

    private static let logger = Logger(subsystem: "com.diskejector.app", category: "DiskService")

    /// 枚举当前所有外置可推出卷。
    ///
    /// 该调用涉及磁盘 I/O 与 DiskArbitration 查询，**应在后台线程执行**，不要在主线程调用
    /// （菜单栏每次展开都会触发，主线程卡顿会直接表现为菜单展开迟滞）。
    func fetchExternalDisks() -> [DiskInfo] {
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil,
                options: []
            ) ?? []

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            Self.logger.error("无法创建 DASession，本次不返回任何磁盘")
            return []
        }

        var disks: [DiskInfo] = []

        for url in urls {
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                let description = DADiskCopyDescription(disk) as? [String: Any]
            else {
                // 取不到 DA 描述的卷一律跳过：宁可漏列，也不能把性质不明的卷
                // 当成外置盘交给用户去「推出」。
                Self.logger.debug("卷缺少 DiskArbitration 描述，跳过: \(url.path, privacy: .public)")
                continue
            }

            let deviceInternal = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool
            let deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
            let isNetwork = description[kDADiskDescriptionVolumeNetworkKey as String] as? Bool
            let isEjectable = description[kDADiskDescriptionMediaEjectableKey as String] as? Bool

            let attributes = DiskClassifier.Attributes(
                deviceInternal: deviceInternal,
                deviceProtocol: deviceProtocol,
                isNetworkVolume: isNetwork,
                isEjectable: isEjectable,
                mountPath: url.path
            )

            guard DiskClassifier.isExternalVolume(attributes) else {
                continue
            }

            guard let info = makeDiskInfo(url: url, description: description) else {
                continue
            }
            disks.append(info)
        }

        return disks
    }

    /// 从卷 URL 与 DiskArbitration 描述组装 `DiskInfo`；容量信息缺失时返回 `nil`。
    private func makeDiskInfo(url: URL, description: [String: Any]) -> DiskInfo? {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
            ])
        } catch {
            Self.logger.warning(
                "读取卷容量失败，跳过 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let totalCapacity = values.volumeTotalCapacity,
            let availableCapacity = values.volumeAvailableCapacity
        else {
            return nil
        }

        let volumeName = values.volumeName ?? ""
        let bsdName =
            (description[kDADiskDescriptionMediaBSDNameKey as String] as? String)
            ?? url.lastPathComponent
        let deviceModel = description[kDADiskDescriptionDeviceModelKey as String] as? String

        return DiskInfo(
            id: url.path,
            bsdName: bsdName,
            volumeName: volumeName,
            mountPath: url.path,
            totalBytes: Int64(totalCapacity),
            usedBytes: Int64(totalCapacity - availableCapacity),
            freeBytes: Int64(availableCapacity),
            deviceProtocol: description[kDADiskDescriptionDeviceProtocolKey as String] as? String,
            deviceModel: deviceModel
        )
    }
}
