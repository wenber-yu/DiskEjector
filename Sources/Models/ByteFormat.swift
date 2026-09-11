import Foundation

/// 容量格式化的唯一实现。
///
/// **为什么要收敛**：此前项目里有三套互不一致的容量格式化：
/// - `AppDelegate.formatBytes(_:)`：手写实现，**1024 进制**
/// - `ContentView.formatBytes(_:)`：同一份手写实现的拷贝，**1024 进制**
/// - `DiskInfo.totalFormatted` 等：系统 `ByteCountFormatter`，**1000 进制**
///
/// 结果是同一块盘在不同界面显示不同数字（例如 1,000,000,000 字节分别显示
/// `953.7 MB` 与 `1 GB`），且两份手写实现必须同步修改，否则口径漂移。
///
/// **为什么选 1000 进制**：`.file` 风格与 Finder 的「显示简介」一致（MB 及以上单位完全相同：
/// `1 GB` / `4 TB`）。工具类应用显示的容量必须和用户在对标工具里看到的数字相同，
/// 否则用户会认为是我们算错了。
///
/// **为什么用 `ByteCountFormatStyle` 而不是 `ByteCountFormatter`**：实测两者在 1000 字节
/// 上分别输出 `1 kB` 与 `1 KB`（SI 标准写小写 k），MB 以上一致；但在 0 字节上
/// `ByteCountFormatter` 会输出 `Zero KB` 这种未本地化的怪异结果，而前者正确输出本地化的
/// `0字节`。此外前者是值类型且 `Sendable`，可在 Swift 6 严格并发下安全跨线程调用。
enum ByteFormat {

    /// 允许出现的单位；不限制时系统会对极小值给出「0 bytes」这类无用输出。
    private static let allowedUnits: ByteCountFormatStyle.Units = [.bytes, .kb, .mb, .gb, .tb, .pb]

    /// 格式化字节数，例如 `1_000_000_000` → `1 GB`（与 Finder 一致）。
    ///
    /// 使用 `ByteCountFormatStyle` 而非 `ByteCountFormatter`：前者是值类型且 `Sendable`，
    /// 可在 Swift 6 严格并发下安全跨线程调用；`Formatter` 子类不是 `Sendable`，
    /// 从后台线程调用会触发并发检查警告。
    nonisolated static func string(_ bytes: Int64) -> String {
        bytes.formatted(
            .byteCount(
                style: .file,
                allowedUnits: allowedUnits,
                spellsOutZero: false,
                includesActualByteCount: false
            )
        )
    }

    /// 已用百分比，容量为 0 时返回 0（避免除零产生 NaN 显示成乱码）。
    nonisolated static func usagePercent(used: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }
}
