import Foundation

/// Internal developer configuration, deliberately separate from the sealed connection snapshot.
/// UserDefaults stores one JSON string so JSON null is distinct from a missing key and from zero.
nonisolated struct XrayLogPolicy: Decodable, Sendable {
    let maxLogSize: Int?
    let retentionDays: Int?

    static let defaultsKey = "xrayLogPolicy"
    static let standard = try! XrayLogPolicy(maxLogSize: 5 * 1024 * 1024, retentionDays: 7)

    init(maxLogSize: Int?, retentionDays: Int?) throws {
        guard maxLogSize.map({ $0 > 0 }) ?? true,
              retentionDays.map({ $0 > 0 }) ?? true else {
            throw CocoaError(.coderInvalidValue)
        }
        self.maxLogSize = maxLogSize
        self.retentionDays = retentionDays
    }

    enum CodingKeys: String, CodingKey {
        case maxLogSize = "max_log_size"
        case retentionDays = "retention_days"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maxLogSize: values.contains(.maxLogSize) ? values.decodeIfPresent(Int.self, forKey: .maxLogSize) : Self.standard.maxLogSize,
            retentionDays: values.contains(.retentionDays) ? values.decodeIfPresent(Int.self, forKey: .retentionDays) : Self.standard.retentionDays
        )
    }

    static func load(defaults: UserDefaults = .standard) throws -> Self {
        guard let json = defaults.string(forKey: defaultsKey) else { return .standard }
        return try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}

/// Queue-confined raw-byte sink. No asynchronous write queue and no formatting of child output.
nonisolated final class XrayLogSink {
    // Health probes can run alongside the active connection. No sink keeps an open
    // generation between appends; serialize path mutation across all runtime instances.
    private static let diskLock = NSLock()
    private let directory: URL
    private let policy: XrayLogPolicy
    private let clock: () -> Date
    private let calendar: Calendar
    private let write: (FileHandle, Data) throws -> Void
    private var handle: FileHandle?
    private var size = 0
    private var day: Date
    private var retainedOnDay: Date?
    private let fm = FileManager.default
    private var currentURL: URL { directory.appendingPathComponent("xray.log") }

    init(directory: URL, policy: XrayLogPolicy, clock: @escaping () -> Date = Date.init,
         calendar: Calendar = .current,
         write: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) throws {
        self.directory = directory
        self.policy = policy
        self.clock = clock
        self.calendar = calendar
        self.write = write
        day = calendar.startOfDay(for: clock())
        Self.diskLock.lock()
        defer { close(); Self.diskLock.unlock() }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Normalize legacy oversized generations with bounded streaming IO, not Data(contentsOf:).
        for url in try ownedFiles() { try normalize(url) }
        let attributes = try? fm.attributesOfItem(atPath: currentURL.path)
        if let modified = attributes?[.modificationDate] as? Date {
            day = calendar.startOfDay(for: modified)
        }
        try open()
        try maintain()
    }

    deinit { close() }

    func append(_ data: Data) throws {
        Self.diskLock.lock()
        defer { close(); Self.diskLock.unlock() }
        let attrs = try fm.attributesOfItem(atPath: currentURL.path)
        if let modified = attrs[.modificationDate] as? Date {
            day = calendar.startOfDay(for: modified)
        }
        try open()
        try maintain()
        var offset = 0
        while offset < data.count {
            if let maximum = policy.maxLogSize, size >= maximum { try rotate() }
            let room = policy.maxLogSize.map { $0 - size } ?? (data.count - offset)
            let count = min(room, data.count - offset, 16 * 1024)
            let chunk = Data(data[data.startIndex + offset ..< data.startIndex + offset + count])
            guard let handle else { throw CocoaError(.fileWriteUnknown) }
            try write(handle, chunk)
            size += count
            offset += count
        }
        try fm.setAttributes([.modificationDate: clock()], ofItemAtPath: currentURL.path)
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    private func open() throws {
        if !fm.fileExists(atPath: currentURL.path) {
            guard fm.createFile(atPath: currentURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try fm.setAttributes([.modificationDate: clock()], ofItemAtPath: currentURL.path)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: currentURL.path)
        let opened = try FileHandle(forWritingTo: currentURL)
        do {
            size = Int(try opened.seekToEnd())
            handle = opened
        } catch {
            try? opened.close()
            throw error
        }
    }

    private func maintain() throws {
        let today = calendar.startOfDay(for: clock())
        if day != today { try rotate() }
        // Retention is independent of size rotation, including idle/new sessions.
        guard retainedOnDay != today else { return }
        if let days = policy.retentionDays,
           let cutoff = calendar.date(byAdding: .day, value: -days, to: today) {
            for url in try ownedFiles() where url != currentURL {
                let attrs = try fm.attributesOfItem(atPath: url.path)
                if let date = attrs[.modificationDate] as? Date, date < cutoff {
                    try fm.removeItem(at: url)
                }
            }
        }
        retainedOnDay = today
    }

    private func rotate() throws {
        close()
        // UUID prevents overwriting prior runs or several size rotations within a second.
        let archive = directory.appendingPathComponent("xray.log.\(Int(day.timeIntervalSince1970)).\(UUID().uuidString)")
        try fm.moveItem(at: currentURL, to: archive)
        try fm.setAttributes([.modificationDate: day], ofItemAtPath: archive.path)
        day = calendar.startOfDay(for: clock())
        try open()
    }

    private func ownedFiles() throws -> [URL] {
        try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { url in
            let name = url.lastPathComponent
            if name == "xray.log" || name == "xray.log.1" { return true }
            let parts = name.split(separator: ".")
            return parts.count == 4 && parts[0] == "xray" && parts[1] == "log"
                && Int(parts[2]) != nil && UUID(uuidString: String(parts[3])) != nil
        }
    }

    private func normalize(_ url: URL) throws {
        let original = try fm.attributesOfItem(atPath: url.path)
        guard original[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnsupportedScheme) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard let maximum = policy.maxLogSize else { return }
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let bytes = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        guard bytes > UInt64(maximum) else { return }
        let temporary = directory.appendingPathComponent(".xray-normalize-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        try input.seek(toOffset: bytes - UInt64(maximum))
        var remaining = maximum
        while remaining > 0 {
            let chunk = try input.read(upToCount: min(remaining, 16 * 1024)) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            remaining -= chunk.count
        }
        try output.close()
        // POSIX rename atomically replaces only this known log, preserving permissions and age.
        try fm.setAttributes([.modificationDate: attrs[.modificationDate] ?? clock()], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
