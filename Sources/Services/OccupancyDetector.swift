import Foundation
import OSLog

/// 卷占用情况的检测结果。
///
/// **为什么需要 `unknown` 而不是用空数组兜底**：
/// 在 App Sandbox 下进程枚举能力不可用（实测 `lsof` 输出 0 行、`proc_listallpids` 返回 0）。
/// 若沿用「返回空数组」表示「没检测到进程」，上层会把它理解成「没有进程占用」，从而直接
/// 执行推出——把「检测失败」静默当成「安全」是危险默认值的典型形态。
/// 因此检测能力缺失必须是一个显式状态，由 UI 明确告知用户「无法检测」。
enum OccupancyResult: Sendable, Equatable {

    /// 已确认没有进程访问该卷。
    case none

    /// 检测到有进程访问该卷。
    case occupied([OccupyingProcess])

    /// 当前环境无法判断（例如运行在 App Sandbox 内）。
    case unknown

    /// 直发（非沙盒）构建下，lsof 因未授予「完全磁盘访问」而拿不到其他进程。
    /// 与 `.unknown` 的区别：`.unknown` 是环境硬限制（沙盒），`.needsFullDiskAccess`
    /// 是用户可补救的权限缺口——引导去系统设置授权后检测即可恢复。
    case needsFullDiskAccess

    var processes: [OccupyingProcess] {
        if case .occupied(let list) = self { return list }
        return []
    }
}

/// 卷占用检测。
///
/// 采用「能力探测 + 降级」而非无条件调用：先判断当前进程是否运行在 App Sandbox 内，
/// 沙盒下直接返回 ``OccupancyResult/unknown``，不浪费一次注定失败的子进程调用，
/// 也不会让上层误判为「无占用」。
class OccupancyDetector: @unchecked Sendable {
    static let shared = OccupancyDetector()

    /// 开放给测试注入 mock 子类；生产环境一律使用 `shared`。
    init() {}

    private static let logger = Logger(subsystem: "com.diskejector.app", category: "Occupancy")

    /// lsof 单次调用的最长等待时间，超时即视为检测失败。
    private static let lsofTimeoutNanoseconds: UInt64 = 5 * 1_000_000_000

    /// 当前进程是否运行在 App Sandbox 内。
    ///
    /// 系统在启动沙盒进程时会注入 `APP_SANDBOX_CONTAINER_ID` 环境变量，这是判断沙盒状态
    /// 最轻量的方式（无需私有 API）。
    nonisolated static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// 是否已授予「完全磁盘访问」（FDA）。
    ///
    /// **为什么需要独立探测**：直发版下 `lsof` 在未授权时返回 0 行，与「确实无占用」无法区分。
    /// 把空结果一律当「无占用」会在未授权时误导用户强卸、损坏数据；一律当「需授权」又会在
    /// 已授权但无占用时错误地弹出授权引导（正是此前被反馈的 bug）。
    /// 因此先做一项与 lsof 无关的 FDA 能力探测：尝试读取 TCC 受保护的用户数据目录
    /// （Mail / Messages 等）——这些目录在无 FDA 时被系统拦截（`EACCES`），授予后可读。
    /// 任一受保护目录「存在且可读」即视为已授权。
    ///
    /// **探针选型（本机实测）**：`~/Library/Mail`、`~/Library/Messages`、
    /// `~/Library/Containers/com.apple.mail`、`~/Library/Containers/com.apple.iChat`
    /// 在无 FDA 的进程下均返回 `EACCES`，确认其受 TCC 保护、可作可靠探针；
    /// 而 `~/Library/Application Support/AddressBook` 等在无 FDA 时也可读，不可用作探针，已排除。
    nonisolated static func isFullDiskAccessAuthorized() -> Bool {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/Library/Mail",
            "\(home)/Library/Messages",
            "\(home)/Library/Containers/com.apple.mail",
            "\(home)/Library/Containers/com.apple.iChat",
            // 追加一组「必然存在」的 TCC 受保护目录做兜底探针，避免用户没装 Mail/Messages
            // 时四个候选全缺失 → 直接判 false（把「没装」误判成「没授权」）。
            "\(home)/Library/Application Support/com.apple.TCC",
            "\(home)/Library/Safari",
            "\(home)/Library/HomeKit",
            "\(home)/Library/IdentityServices",
            "\(home)/Library/Cookies",
            "\(home)/Library/Caches/com.apple.Safari",
        ]
        let fm = FileManager.default
        for path in candidates {
            let exists = fm.fileExists(atPath: path)
            // **判据必须是「实际列举目录内容」，不是 `isReadableFile`**：
            // `isReadableFile` 走 `access(R_OK)`，只校验 POSIX 权限位，**不触发 TCC 判定**，
            // 结果与真实的 TCC 放行状态可能相反。TCC 在 open/readdir 层拦截，
            // 因此「能否 contentsOfDirectory」才是授权状态的真实证据。
            guard exists else { continue }  // 缺失不计数（避免把「没装 Mail」误判为未授权）
            if (try? fm.contentsOfDirectory(atPath: path)) != nil {
                logger.info("FDA 探针命中: \(path, privacy: .public)")
                return true
            }
        }
        logger.info("FDA 探针全部不可列举，判定未授权")
        return false
    }

    /// 检测访问指定卷的进程。
    ///
    /// 该调用可能耗时（子进程执行），应在后台上下文调用。
    func detect(mountPath: String) async -> OccupancyResult {
        if Self.isSandboxed {
            Self.logger.info("运行于沙盒内，进程枚举不可用，返回 unknown")
            return .unknown
        }

        // 先独立探测 FDA 授权状态：未授权时 lsof 必然拿不到其他进程，直接给「需授权」，
        // 由 UI 在标题栏居中展示引导；授权后再看 lsof 输出区分「占用 / 无占用」。
        // 不能把 lsof 空输出直接当「无占用」——那样会在未授权时误导用户强卸、损坏数据；
        // 也不能一律当「需授权」——那样会在已授权但无占用时错误地弹出授权引导。
        let authorized = Self.isFullDiskAccessAuthorized()

        guard let output = await Self.lsofOutput(mountPath: mountPath) else {
            // 子进程启动失败/超时：按授权状态保守兜底，不把失败当「安全」。
            return authorized ? .none : .needsFullDiskAccess
        }

        let processes = Self.parseLsof(output)
        if !processes.isEmpty {
            // 能列出进程即证明已授权，直接返回占用列表（核心价值）。
            return .occupied(processes)
        }
        // lsof 空行：已授权 → 确实无占用（可安全推出）；未授权 → 提示授权。
        return authorized ? .none : .needsFullDiskAccess
    }

    /// 同步版本，仅供 `--diagnostics` 一次性自检使用。
    ///
    ///  diagnostics 是退出即止的开发者工具，不需要并发；同步执行可彻底避开
    /// 「主线程 `group.wait()` 阻塞」与「`static main()` 返回后进程不等异步 Task」两类生命周期陷阱，
    /// 比用 `Task { await ... }` + `RunLoop` 更可预测。
    func detectSync(mountPath: String) -> OccupancyResult {
        if Self.isSandboxed {
            return .unknown
        }
        let authorized = Self.isFullDiskAccessAuthorized()
        guard let output = Self.lsofOutputSync(mountPath: mountPath) else {
            return authorized ? .none : .needsFullDiskAccess
        }
        let processes = Self.parseLsof(output)
        if !processes.isEmpty {
            return .occupied(processes)
        }
        return authorized ? .none : .needsFullDiskAccess
    }

    /// 同步执行 lsof 并读取全部输出（diagnostics 使用）。
    private static func lsofOutputSync(mountPath: String) -> String? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-Fpcn0", mountPath]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            logger.warning("lsof 启动失败: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - lsof

    /// 执行 lsof 并取回输出。
    ///
    /// **两处必须的修正**（对比旧实现）：
    /// 1. **先读后等**：旧实现先 `waitUntilExit()` 再 `readDataToEndOfFile()`。管道缓冲只有
    ///    64KB，lsof 输出很容易超过（本机 `lsof /` 实测 4.7MB），此时子进程阻塞在写管道、
    ///    父进程阻塞在等退出，形成永久死锁。必须先把管道读干再等退出。
    /// 2. **stderr 不进管道**：旧实现把 stdout 与 stderr 接到同一个 Pipe，两者会互相抢占
    ///    缓冲。这里直接丢弃 stderr，避免它填满缓冲后阻塞子进程。
    nonisolated private static func lsofOutput(mountPath: String) async -> String? {
        let task = Process()
        let pipe = Pipe()
        // `-Fpcn0`：机器可读输出（p=PID、c=命令名、n=路径），记录以 NUL 分隔。
        // 不用默认表格格式——它按空格切列，进程名含空格时会错位，见 ``parseLsof`` 的说明。
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-Fpcn0", mountPath]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            logger.warning("lsof 启动失败: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let reader = Task.detached(priority: .utility) { () -> String in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }

        let output: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { await reader.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: lsofTimeoutNanoseconds)
                return nil
            }
            // 取先完成的那个结果，然后取消另一个
            guard let first = await group.next() else { return nil }
            group.cancelAll()
            return first
        }

        guard let output else {
            // 超时：终止子进程，管道随之关闭，reader 会返回
            task.terminate()
            logger.error("lsof 超时（\(Self.lsofTimeoutNanoseconds / 1_000_000_000)s），已终止")
            return nil
        }
        return output
    }

    /// 解析 `lsof -F` 的机器可读输出。
    ///
    /// **为什么用 `-F` 而不是默认表格格式**：默认输出按空格切列，而进程名本身可以含空格
    /// （`Google Chrome Helper`、`Microsoft Word` 等），一旦出现，PID 列就会错位，
    /// 解析出的 pid 其实是名字的第二个单词——`Int32(...)` 转换失败，该进程被静默丢弃。
    /// 表现为「占用检测时灵时不灵」，且只在特定应用占用时才复现，极难定位。
    /// `-F` 格式以 `p`/`c`/`n` 前缀标识字段，不存在歧义。
    ///
    /// 字段含义：`p` = PID，`c` = 命令名，`n` = 文件路径。
    ///
    /// **输出结构是「每个字段后跟一个 NUL」，不是「每条记录后跟一个 NUL」**——
    /// 这点必须实测确认，凭直觉按记录切分会得到一串孤立字段，解析结果恒为空。
    /// 本机实测 `lsof -Fpcn0 /Volumes/wenbo-data` 的原始字节：
    /// `p17917\0cIINA\0\nf9\0n/Volumes/.../03.mp4\0`
    /// 因此这里以「遇到 `p` 字段」作为一条新记录的开始。
    ///
    /// 同一进程可能通过多个 fd 访问同一卷，因此输出里会出现多组字段；这里按 PID 去重。
    static func parseLsof(_ output: String) -> [OccupyingProcess] {
        var byPid: [Int32: OccupyingProcess] = [:]
        var pid: Int32?
        var command: String?
        var path: String?

        /// 结束当前进程记录并入结果集。
        func commit() {
            defer {
                pid = nil
                command = nil
                path = nil
            }
            guard let pid, let command, !command.isEmpty else { return }
            // 保留首个路径即可：UI 只需要一个代表路径，重复展示同一进程没有意义。
            if byPid[pid] == nil {
                byPid[pid] = OccupyingProcess(pid: pid, name: command, path: path ?? "")
            }
        }

        for rawField in output.split(separator: "\0", omittingEmptySubsequences: true) {
            // **lsof 会在「每条记录组」前插入一个 `\n`**（除最开头第一组）：
            // 实测多进程输出 `p5340\0cIINA\0\nf9\0n...\0\np39298\0ctail\0\nf3\0n...\0\n`。
            // 若不先剥掉前导 `\n`，后续进程的 `p` 字段会变成 `\np39298`，`field.first` 得到
            // `\n` 而被当作未知字段丢弃 → 只有一个进程被解析出，且名字会被后一个进程覆盖。
            // 这正是「多进程只显示一个、且进程名张冠李戴」的根因。
            let field = rawField.drop { $0 == "\n" || $0 == "\r" }
            guard let tag = field.first, field.count > 1 else { continue }
            let value = String(field.dropFirst())
            switch tag {
            case "p":
                commit()  // 上一个进程结束
                pid = Int32(value)
            case "c":
                command = value
            case "n":
                path = value
            default:
                // 其他字段（f 文件描述符、u 用户等）本应用不到。
                // 注意 `f` 字段前会带一个换行，其首字符是 `\n`，在此被自然跳过。
                break
            }
        }
        commit()  // 提交最后一条

        return byPid.values.sorted { $0.pid < $1.pid }
    }
}
