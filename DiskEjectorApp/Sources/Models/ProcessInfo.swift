import Foundation

struct ProcessInfo: Identifiable, Hashable {
    let id = UUID()
    let pid: Int32
    let name: String
    let path: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
    }

    static func == (lhs: ProcessInfo, rhs: ProcessInfo) -> Bool {
        lhs.pid == rhs.pid
    }
}
