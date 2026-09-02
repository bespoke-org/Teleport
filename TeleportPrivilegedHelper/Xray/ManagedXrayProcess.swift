import Darwin
import Foundation

struct ManagedXrayProcess: Sendable {
    let installedXrayPath: String

    func isManagedXrayRunning(helperStateDirectoryPath: String) -> Bool {
        validatedManagedXrayPID(helperStateDirectoryPath: helperStateDirectoryPath) != nil
    }

    func validatedManagedXrayPID(helperStateDirectoryPath: String) -> pid_t? {
        let pidFilePath = helperStateDirectoryPath + "/xray-tun.pid"
        guard let pid = managedXrayPID(pidFilePath: pidFilePath, expectedOwner: 0),
              isInstalledXrayProcess(pid: pid) else {
            return nil
        }
        return pid
    }

    func terminateManagedXray(helperStateDirectoryPath: String) throws {
        let pidFilePath = helperStateDirectoryPath + "/xray-tun.pid"
        guard let pid = managedXrayPID(pidFilePath: pidFilePath, expectedOwner: 0),
              isInstalledXrayProcess(pid: pid) else {
            return
        }
        try terminateInstalledXray(pid: pid)
    }

    func terminateLegacyManagedXray(stateDirectoryPath: String) throws {
        let pidFilePath = stateDirectoryPath + "/xray-tun.pid"
        guard let pid = managedXrayPID(pidFilePath: pidFilePath, expectedOwner: consoleUserIDs().uid),
              isInstalledXrayProcess(pid: pid) else {
            return
        }
        try terminateInstalledXray(pid: pid)
    }

    private func terminateInstalledXray(pid: pid_t) throws {
        try signalInstalledXray(pid: pid, signal: SIGTERM)
        for _ in 0 ..< 10 {
            usleep(200_000)
            if !isInstalledXrayProcess(pid: pid) {
                return
            }
        }
        try signalInstalledXray(pid: pid, signal: SIGKILL)
    }

    func managedXrayPID(pidFilePath: String, expectedOwner: uid_t) -> pid_t? {
        var statInfo = stat()
        guard lstat(pidFilePath, &statInfo) == 0,
              (statInfo.st_mode & S_IFMT) == S_IFREG,
              statInfo.st_uid == expectedOwner,
              statInfo.st_size > 0,
              statInfo.st_size <= 32,
              let rawPID = try? String(contentsOfFile: pidFilePath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(rawPID),
              pid > 0 else {
            return nil
        }
        return pid
    }

    private func signalInstalledXray(pid: pid_t, signal: Int32) throws {
        guard isInstalledXrayProcess(pid: pid) else {
            return
        }
        guard Darwin.kill(pid, signal) == 0 || errno == ESRCH else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private func isInstalledXrayProcess(pid: pid_t) -> Bool {
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return false }
        let processPath = URL(fileURLWithPath: String(cString: pathBuffer)).resolvingSymlinksInPath().path
        let expectedPath = URL(fileURLWithPath: installedXrayPath).resolvingSymlinksInPath().path
        return processPath == expectedPath
    }
}
