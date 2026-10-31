import Darwin
import Foundation

nonisolated protocol ProxyJournalStoring: AnyObject {
    var exists: Bool { get }
    func acquire() throws
    func release()
    func load() throws -> ProxyJournal?
    func save(_ journal: ProxyJournal?) throws
}

/// The lock stays held for the session, including when the journal contains no
/// changed fields. It also excludes a second process attempting crash recovery.
nonisolated final class ProxyJournalStore: ProxyJournalStoring {
    private let directory: URL
    private let fileManager: FileManager
    private var lockFD: Int32 = -1
    private var url: URL { directory.appendingPathComponent("system-proxy-snapshot.json") }

    init(fileManager: FileManager) {
        self.fileManager = fileManager
        directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("teleport", isDirectory: true)
    }

    deinit { release() }

    var exists: Bool { fileManager.fileExists(atPath: url.path) }

    func acquire() throws {
        guard lockFD == -1 else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("system-proxy.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw SystemProxyError.anotherInstance
        }
        lockFD = fd
    }

    func release() {
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
    }

    func load() throws -> ProxyJournal? {
        guard exists else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SystemProxyError.invalidJournal
        }
        guard object["version"] != nil else { throw SystemProxyError.legacyJournal }
        guard let journal = try? JSONDecoder().decode(ProxyJournal.self, from: data),
            journal.version == ProxyJournal.currentVersion,
            Set(journal.services.map(\.serviceID)).count == journal.services.count
        else {
            throw SystemProxyError.invalidJournal
        }
        for service in journal.services {
            guard !service.serviceID.isEmpty, Set(service.groups.map(\.group)).count == service.groups.count else {
                throw SystemProxyError.invalidJournal
            }
            for group in service.groups {
                guard Set(group.original.keys).union(group.applied.keys).isSubset(of: Set(group.group.keys)) else {
                    throw SystemProxyError.invalidJournal
                }
            }
        }
        return journal
    }

    func save(_ journal: ProxyJournal?) throws {
        precondition(lockFD >= 0)
        guard let journal else {
            if exists { try fileManager.removeItem(at: url) }
            try syncDirectory()
            return
        }
        let data = try JSONEncoder().encode(journal)
        let temporary = directory.appendingPathComponent(".proxy-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer {
            close(fd)
            try? fileManager.removeItem(at: temporary)
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw posixError() }
        guard rename(temporary.path, url.path) == 0 else { throw posixError() }
        try syncDirectory()
    }

    private func syncDirectory() throws {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw posixError() }
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
