import Darwin
import Foundation

/// Written only by the administrator-authorized installation transaction.
nonisolated struct HelperInstallationManifest: Codable, Equatable, Sendable {
    let helperVersion: String
    let appCDHashes: [String]
    let helperCDHashes: [String]
    let xraySHA256: String

    var isValid: Bool {
        helperVersion == PrivilegedHelperConstants.version
            && Self.validCodeHashes(appCDHashes)
            && Self.validCodeHashes(helperCDHashes)
            && Self.isHex(xraySHA256, count: 64)
    }

    var clientRequirement: String { Self.requirement(for: appCDHashes) }
    var helperRequirement: String { Self.requirement(for: helperCDHashes) }

    private static func requirement(for hashes: [String]) -> String {
        hashes.map { "cdhash H\"\($0)\"" }.joined(separator: " or ")
    }

    private static func validCodeHashes(_ hashes: [String]) -> Bool {
        (1...2).contains(hashes.count) && Set(hashes).count == hashes.count
            && hashes.allSatisfy { isHex($0, count: 40) }
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    /// Reject links and writable/unowned policy files. Read and inspect the same
    /// descriptor so replacing a pathname cannot swap the object after validation.
    static func loadApproved(at path: String = PrivilegedHelperConstants.installationManifestPath) -> Self? {
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        while true {
            var info = stat()
            guard lstat(parent.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == 0, info.st_mode & 0o022 == 0 else { return nil }
            if parent.path == "/" { break }
            parent.deleteLastPathComponent()
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == 0, info.st_mode & 0o022 == 0,
              info.st_size > 0, info.st_size <= 4096,
              let data = try? file.read(upToCount: 4097), data.count <= 4096,
              let manifest = try? JSONDecoder().decode(Self.self, from: data),
              manifest.isValid else { return nil }
        return manifest
    }
}
