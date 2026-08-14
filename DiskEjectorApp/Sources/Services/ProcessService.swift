import Foundation

class ProcessService: @unchecked Sendable {
    static let shared = ProcessService()
    
    private init() {}
    
    func findProcessesAccessingDisk(mountPath: String) -> [ProcessInfo] {
        print("Finding processes for mount path: \(mountPath)")
        
        // 首先尝试使用 lsof 命令，使用更简单的参数
        let lsofProcesses = tryLsofCommand(mountPath: mountPath)
        if !lsofProcesses.isEmpty {
            print("Found processes using lsof: \(lsofProcesses.count)")
            return lsofProcesses
        }
        
        // 如果 lsof 没有找到进程，尝试使用 ps 命令
        let psProcesses = tryPsCommand(mountPath: mountPath)
        if !psProcesses.isEmpty {
            print("Found processes using ps: \(psProcesses.count)")
            return psProcesses
        }
        
        // 如果都没有找到进程，返回空数组
        print("No processes found using any method, returning empty array")
        return []
    }
    
    private func tryLsofCommand(mountPath: String) -> [ProcessInfo] {
        let task = Process()
        let pipe = Pipe()
        
        task.launchPath = "/usr/sbin/lsof"
        task.arguments = [mountPath]
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            
            // 添加超时机制，最多等待 2 秒
            let timeout = DispatchTime.now() + .seconds(2)
            let semaphore = DispatchSemaphore(value: 0)
            
            DispatchQueue.global().async {
                task.waitUntilExit()
                semaphore.signal()
            }
            
            if semaphore.wait(timeout: timeout) == .timedOut {
                print("lsof command timed out")
                task.terminate()
                return []
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            print("lsof output (first 500 chars): \(String(output.prefix(500)))")
            
            return parseLsofOutput(output)
        } catch {
            print("Error running lsof: \(error)")
            return []
        }
    }
    
    private func parseLsofOutput(_ output: String) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []
        let lines = output.split(separator: "\n")
        
        // 跳过标题行
        for line in lines.dropFirst() {
            let components = line.split(separator: " ", omittingEmptySubsequences: true)
            if components.count >= 9 {
                let name = String(components[0])
                let pidStr = String(components[1])
                let path = components[8...].joined(separator: " ")
                
                if let pid = Int(pidStr) {
                    processes.append(ProcessInfo(pid: Int32(pid), name: name, path: path))
                    print("Found process with lsof: \(name) (PID: \(pid))")
                }
            }
        }
        
        print("Found \(processes.count) processes with lsof")
        return processes
    }
    
    private func tryPsCommand(mountPath: String) -> [ProcessInfo] {
        let task = Process()
        let pipe = Pipe()
        
        task.launchPath = "/bin/ps"
        task.arguments = ["-axo", "pid,comm,command"]
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            
            // 添加超时机制，最多等待 2 秒
            let timeout = DispatchTime.now() + .seconds(2)
            let semaphore = DispatchSemaphore(value: 0)
            
            DispatchQueue.global().async {
                task.waitUntilExit()
                semaphore.signal()
            }
            
            if semaphore.wait(timeout: timeout) == .timedOut {
                print("ps command timed out")
                task.terminate()
                return []
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            return parsePsOutput(output, mountPath: mountPath)
        } catch {
            print("Error running ps: \(error)")
            return []
        }
    }
    
    private func parsePsOutput(_ output: String, mountPath: String) -> [ProcessInfo] {
        var processes: [ProcessInfo] = []
        let lines = output.split(separator: "\n")
        
        // 跳过标题行
        for line in lines.dropFirst() {
            let components = line.split(separator: " ", omittingEmptySubsequences: true)
            if components.count >= 3 {
                let pidStr = String(components[0])
                let name = String(components[1])
                let command = components[2...].joined(separator: " ")
                
                if let pid = Int(pidStr), command.contains(mountPath) {
                    processes.append(ProcessInfo(pid: Int32(pid), name: name, path: command))
                    print("Found process with ps: \(name) (PID: \(pid))")
                }
            }
        }
        
        print("Found \(processes.count) processes with ps")
        return processes
    }
    
    func killProcess(pid: Int) {
        let task = Process()
        task.launchPath = "/bin/kill"
        task.arguments = ["-9", String(pid)]
        
        do {
            try task.run()
            task.waitUntilExit()
            print("Killed process with PID: \(pid)")
        } catch {
            print("Error killing process: \(error)")
        }
    }
}