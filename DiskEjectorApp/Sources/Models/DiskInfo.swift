import Foundation

struct DiskInfo: Identifiable, Hashable {
    let id: String
    let bsdName: String
    let volumeName: String
    let mountPath: String
    let totalBytes: Int64
    let usedBytes: Int64
    let freeBytes: Int64
    let isEjectable: Bool

    var displayName: String {
        volumeName.isEmpty ? bsdName : volumeName
    }

    var totalFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var usedFormatted: String {
        ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
    }

    var freeFormatted: String {
        ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
    }

    var usagePercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    var capacityLabel: String {
        "\(totalFormatted) / 已用: \(usedFormatted) / 剩余: \(freeFormatted)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DiskInfo, rhs: DiskInfo) -> Bool {
        lhs.id == rhs.id
    }
}
