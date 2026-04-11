import Foundation
import DiskArbitration

class DiskService {
    static let shared = DiskService()
    
    private init() {}
    
    func fetchExternalDisks() -> [DiskInfo] {
        var disks: [DiskInfo] = []
        
        let session = DASessionCreate(kCFAllocatorDefault)
        let mountedVolumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: .skipHiddenVolumes) ?? []
        
        print("Found \(mountedVolumes.count) mounted volumes")
        
        for volumeURL in mountedVolumes {
            do {
                let values = try volumeURL.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsRemovableKey])
                
                print("Processing volume: \(volumeURL.path)")
                print("Volume values: \(values)")
                
                let isRemovable = values.volumeIsRemovable ?? false
                print("Volume is removable: \(isRemovable)")
                
                // 检查是否是外部磁盘：要么是可移动的，要么不是根目录且不在 /System 或 /Library 中
                let isExternal = isRemovable || 
                               (volumeURL.path != "/" && 
                                !volumeURL.path.hasPrefix("/System") && 
                                !volumeURL.path.hasPrefix("/Library") &&
                                volumeURL.path.hasPrefix("/Volumes"))
                
                print("Volume is external: \(isExternal)")
                
                if isExternal {
                    if let volumeName = values.volumeName, 
                       let totalCapacity = values.volumeTotalCapacity, 
                       let availableCapacity = values.volumeAvailableCapacity {
                        
                        // 跳过系统盘
                        if volumeName == "Macintosh HD" {
                            print("Skipping system disk: \(volumeName)")
                            continue
                        }
                        
                        let usedBytes = totalCapacity - availableCapacity
                        
                        let diskInfo = DiskInfo(
                            id: volumeURL.path,
                            bsdName: volumeURL.lastPathComponent,
                            volumeName: volumeName,
                            mountPath: volumeURL.path,
                            totalBytes: Int64(totalCapacity),
                            usedBytes: Int64(usedBytes),
                            freeBytes: Int64(availableCapacity),
                            isEjectable: true
                        )
                        
                        disks.append(diskInfo)
                        print("Added disk: \(volumeName)")
                    }
                }
            } catch {
                print("Error getting disk info: \(error)")
            }
        }
        
        print("Returning \(disks.count) disks")
        return disks
    }
    
    /// 安全推出磁盘：先终止占用进程，再执行 diskutil unmount force
    func ejectDisk(_ disk: DiskInfo, killProcesses: [ProcessInfo], completion: @escaping (Result<Void, Error>) -> Void) {
        // 移到后台线程执行耗时操作，避免阻塞主线程
        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Terminate occupying processes
            for proc in killProcesses {
                ProcessService.shared.killProcess(pid: Int(proc.pid))
            }

            // Step 2: Execute eject command immediately without unnecessary delay
            self.runEjectCommand(disk: disk) { result in
                // 回到主线程执行 completion
                DispatchQueue.main.async {
                    completion(result)
                }
            }
        }
    }
    
    private func runEjectCommand(disk: DiskInfo, completion: @escaping (Result<Void, Error>) -> Void) {
        let task = Process()
        let pipe = Pipe()
        
        task.launchPath = "/usr/sbin/diskutil"
        task.arguments = ["unmount", "force", disk.mountPath]
        task.standardOutput = pipe
        task.standardError = pipe
        
        print("=== Running eject command ===")
        print("Command: /usr/sbin/diskutil unmount force \(disk.mountPath)")
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            print("Command exit status: \(task.terminationStatus)")
            print("Command output: \(output)")
            
            if task.terminationStatus == 0 {
                print("Disk ejected successfully: \(disk.volumeName)")
                completion(.success(()))
            } else {
                print("Failed to eject disk: \(output)")
                completion(.failure(NSError(domain: "DiskService", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])))
            }
        } catch {
            print("Error running diskutil: \(error)")
            completion(.failure(error))
        }
    }
}