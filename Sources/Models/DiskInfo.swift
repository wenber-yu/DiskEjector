import Foundation

/// 一块已挂载的卷。
///
/// **关于 `isEjectable` 的移除**：此前该字段在 `DiskService` 里被硬编码为 `true`，
/// 与真实设备状态无关——列表里出现的所有磁盘都「可推出」，这个字段既没有信息量，
/// 又会让调用方误以为它经过了判定。现在列表本身就只包含外置卷（判定见 ``DiskClassifier``），
/// 「在列表里」即意味着「可推出」，冗余字段反而会造成两处口径不一致。
struct DiskInfo: Identifiable, Sendable, Equatable {

    /// 挂载路径，同路径即同一卷。
    let id: String

    /// BSD 设备名，如 `disk4s2`（取自 DiskArbitration 的 `DAMediaBSDName`）。
    ///
    /// 此前取的是 `volumeURL.lastPathComponent`，那其实是卷名（`wenbo-data`），
    /// 不是设备名，日志与详情里会误导排查方向。
    let bsdName: String

    let volumeName: String
    let mountPath: String

    let totalBytes: Int64
    let usedBytes: Int64
    let freeBytes: Int64

    /// 设备总线协议，如 `USB` / `Thunderbolt` / `Disk Image`。
    let deviceProtocol: String?

    /// 设备型号，如 `SanDisk Extreme 55AE`。可能为 `nil`（部分虚拟设备不提供）。
    let deviceModel: String?

    var displayName: String {
        volumeName.isEmpty ? bsdName : volumeName
    }

    var totalFormatted: String { ByteFormat.string(totalBytes) }
    var usedFormatted: String { ByteFormat.string(usedBytes) }
    var freeFormatted: String { ByteFormat.string(freeBytes) }

    var usagePercent: Double {
        ByteFormat.usagePercent(used: usedBytes, total: totalBytes)
    }
}

/// 外置卷判定规则。
///
/// **为什么需要单独的纯函数**：这块逻辑是整个应用最危险的地方——判错了会把系统盘或网络卷
/// 当成可推出的外置盘交给用户。抽成无依赖的纯函数后可以脱离 DiskArbitration 直接单测，
/// 把「设备属性 → 能不能推出」的规则固化下来。
///
/// **关键的实测事实**（本机 SanDisk Extreme 55AE 4TB USB 硬盘）：
/// ```
/// DADeviceInternal  = 0      ← 唯一可靠的「外置」信号
/// DADeviceProtocol  = USB
/// DAMediaRemovable  = 0      ← USB 硬盘介质标记为 Fixed，不可用
/// DAMediaEjectable  = 0      ← 同样不可用
/// NSURLVolumeIsEjectableKey = false ← 同样不可用
/// ```
/// 也就是说，**不能用「可移动」「可推出」来判断外置**。USB 外置硬盘的介质被系统标记为
/// Fixed，上述三个键对它全是 false；若按它们过滤，会直接把用户的外置硬盘过滤掉。
enum DiskClassifier {

    /// 用于判定的设备属性集合。
    ///
    /// 拆成结构体而非多个参数，是为了让调用方无法漏传或错位传参，
    /// 也让测试用例的表达更接近真实数据。
    struct Attributes: Sendable, Equatable {
        /// `DADeviceInternal`：设备是否在机器内部。虚拟设备（如磁盘映像）**不提供该属性**。
        let deviceInternal: Bool?
        /// `DADeviceProtocol`：如 `USB` / `Thunderbolt` / `Virtual Interface`。
        let deviceProtocol: String?
        /// `DAVolumeNetwork`：是否为网络卷。
        let isNetworkVolume: Bool?
        /// `DAMediaEjectable`：介质是否可推出。
        let isEjectable: Bool?
        /// 挂载路径。用于区分「用户挂载的映像」与「系统内部使用的映像」。
        let mountPath: String?

        static let empty = Attributes(
            deviceInternal: nil, deviceProtocol: nil,
            isNetworkVolume: nil, isEjectable: nil,
            mountPath: nil)
    }

    /// 已知的网络文件系统协议：网络卷应当卸载（unmount）而非推出（eject）设备。
    private static let networkProtocols: Set<String> = [
        "SMB", "AFP", "NFS", "WebDAV", "FTP", "SFTP", "CIFS",
    ]

    /// 判断一个卷是否为「外置可推出」卷。
    ///
    /// **关键的实测事实**：
    /// ```
    /// USB 外置硬盘（SanDisk Extreme 55AE）：
    ///   DADeviceInternal = 0      ← 唯一可靠的「外置」信号
    ///   DADeviceProtocol = USB
    ///   DAMediaRemovable = 0      ← 介质标记为 Fixed，不可用
    ///   DAMediaEjectable = 0      ← 同样不可用
    ///
    /// 磁盘映像（.dmg 挂载后）：
    ///   DADeviceInternal = <不存在>  ← 虚拟设备没有「内部/外部」概念
    ///   DADeviceProtocol = Virtual Interface
    ///   DAMediaEjectable = 1
    ///   DAVolumeNetwork  = 0
    /// ```
    /// 也就是说：**既不能只用「可移动/可推出」（对外置 USB 硬盘是 false），
    /// 也不能只用 DADeviceInternal（对磁盘映像根本不存在）**。因此判定分两条路径。
    static func isExternalVolume(_ attributes: Attributes) -> Bool {

        // 1. 内置硬件一律排除——内置盘不能被推出。
        if let isInternal = attributes.deviceInternal, isInternal {
            return false
        }

        // 2. 网络卷排除：它在 DA 里也常表现为「非内部设备」，但推出设备对它没有意义，
        //    失败时给出的错误还会误导用户以为硬盘出了问题。
        if let isNetwork = attributes.isNetworkVolume, isNetwork {
            return false
        }
        if let proto = attributes.deviceProtocol, networkProtocols.contains(proto) {
            return false
        }

        // 3. 明确的物理外置设备。
        if let isInternal = attributes.deviceInternal, isInternal == false {
            return true
        }

        // 4. 无物理设备属性（磁盘映像等虚拟卷）：必须同时满足「系统标记可推出」与
        //    「挂载在用户可见的 /Volumes 下」两个条件。
        //
        //    第二个条件是实测补上的：仅按可推出性筛选时，Xcode 的 iOS 模拟器映像
        //    （/Library/Developer/CoreSimulator/...）与 Apple 的 cryptex 组件映像
        //    （/private/var/run/com.apple.security.cryptexd/...）都会被收入列表，
        //    而推出它们会直接破坏 Xcode 与系统组件。这些系统映像的挂载点都不在 /Volumes。
        if attributes.deviceInternal == nil {
            guard attributes.isEjectable == true, let mountPath = attributes.mountPath else {
                return false
            }
            return mountPath == "/Volumes" || mountPath.hasPrefix("/Volumes/")
        }

        return false
    }
}
