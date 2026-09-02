import Darwin
import Foundation

func consoleUserIDs() -> (uid: uid_t, gid: gid_t) {
    var statInfo = stat()
    if stat("/dev/console", &statInfo) == 0 {
        return (statInfo.st_uid, statInfo.st_gid)
    }
    return (0, 0)
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
