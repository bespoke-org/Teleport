import Foundation

/// Append-only file log shared by the app and the root helper.
///
/// Written to a file rather than `os_log` because the reason to have it at all is
/// reading it *after* the incident: `log show` keeps only a rolling window, and a
/// laptop restart or a Wi-Fi outage that wedges the machine has to leave something
/// behind that can still be read (and attached to a bug report) hours later.
///
/// `@unchecked Sendable` means thread safety is promised by this implementation —
/// every mutation happens on `queue` — rather than verified by the compiler.
nonisolated final class TeleportLog: @unchecked Sendable {
    enum Level: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    /// The app writes under the user's Logs directory (visible in Console.app and
    /// in Finder); the helper runs as root with no home directory of its own and
    /// writes next to the rest of its root-owned state.
    static let shared: TeleportLog = {
        let log = TeleportLog(
            directoryURL: defaultDirectoryURL(),
            fileName: getuid() == 0 ? "helper.log" : "teleport.log"
        )
        // Writes are queued, so a process that ends without draining the queue loses
        // its last lines — which for a short-lived tool is most of them, and for the
        // app is the part written while something was going wrong.
        //
        // Registering from inside the initializer is safe: `shared` is assigned before
        // any exit handler can run, and `flush` blocks on the log queue, which nothing
        // else holds once the process is on its way out.
        atexit { TeleportLog.shared.flush() }
        return log
    }()

    /// Rotation keeps the log bounded without a daily job. 5 MB holds several weeks
    /// of lifecycle events, and three rotated files behind the live one survive a
    /// few reboots of noise.
    private let maximumBytes: Int
    private let rotatedGenerations: Int

    private let directoryURL: URL
    private let fileName: String
    private let queue = DispatchQueue(label: "dev.x.teleport.log", qos: .utility)
    private var handle: FileHandle?

    init(directoryURL: URL, fileName: String, maximumBytes: Int = 5 * 1024 * 1024, rotatedGenerations: Int = 3) {
        self.directoryURL = directoryURL
        self.fileName = fileName
        self.maximumBytes = maximumBytes
        self.rotatedGenerations = rotatedGenerations
    }

    var fileURL: URL {
        directoryURL.appendingPathComponent(fileName)
    }

    // MARK: - Writing

    func info(_ subsystem: String, _ message: String) { write(.info, subsystem, message) }
    func warn(_ subsystem: String, _ message: String) { write(.warn, subsystem, message) }
    func error(_ subsystem: String, _ message: String) { write(.error, subsystem, message) }

    func write(_ level: Level, _ subsystem: String, _ message: String) {
        let line = "\(Self.timestamp()) \(level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) [\(subsystem)] \(message)\n"
        queue.async { [weak self] in
            self?.appendOnQueue(Data(line.utf8))
        }
    }

    /// Multi-line output (a routing table, a resolver configuration) indented under a
    /// heading, so a dump stays visually distinct from the event lines around it.
    func dump(_ subsystem: String, _ title: String, _ body: String) {
        var text = "\(Self.timestamp()) \(Level.info.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) [\(subsystem)] ----- \(title) -----\n"
        for bodyLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            text += "    \(bodyLine)\n"
        }
        text += "\(Self.timestamp()) \(Level.info.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) [\(subsystem)] ----- end \(title) -----\n"
        queue.async { [weak self] in
            self?.appendOnQueue(Data(text.utf8))
        }
    }

    /// Flushes anything still queued. Call before the process exits, otherwise the
    /// last events before a crash-adjacent shutdown are the ones that go missing.
    func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    // MARK: - File handling

    private func appendOnQueue(_ data: Data) {
        // One stat per write serves two purposes: it sizes the file for rotation, and
        // it notices when someone deleted the log underneath an open handle. Without
        // the second check, writes would keep landing in an unlinked inode until the
        // next rotation, and the user who cleared the log would see nothing new.
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        if attributes == nil, handle != nil {
            try? handle?.close()
            handle = nil
        }
        let currentBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if currentBytes + data.count > maximumBytes {
            rotateOnQueue()
        }
        guard let handle = handleOnQueue() else { return }
        try? handle.write(contentsOf: data)
    }

    private func handleOnQueue() -> FileHandle? {
        if let handle { return handle }

        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let path = fileURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let opened = try? FileHandle(forWritingTo: fileURL) else { return nil }
        _ = try? opened.seekToEnd()
        handle = opened
        return opened
    }

    private func rotateOnQueue() {
        try? handle?.close()
        handle = nil

        let fileManager = FileManager.default
        // Shift generations from the oldest down, so nothing is overwritten while a
        // younger file still needs its slot.
        try? fileManager.removeItem(at: rotatedURL(generation: rotatedGenerations))
        for generation in stride(from: rotatedGenerations - 1, through: 1, by: -1) {
            let source = rotatedURL(generation: generation)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.moveItem(at: source, to: rotatedURL(generation: generation + 1))
        }
        try? fileManager.moveItem(at: fileURL, to: rotatedURL(generation: 1))
    }

    private func rotatedURL(generation: Int) -> URL {
        directoryURL.appendingPathComponent("\(fileName).\(generation)")
    }

    private static func defaultDirectoryURL() -> URL {
        if getuid() == 0 {
            return URL(fileURLWithPath: PrivilegedHelperConstants.helperStateDirectoryPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Teleport", isDirectory: true)
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Public so other files written alongside this log (Xray's own output) can
    /// stamp their separators in the same format and be lined up by eye.
    static func timestamp() -> String {
        formatter.string(from: Date())
    }
}

/// Formatting helpers for values that appear in log lines.
///
/// This is not where secrets are removed. Connection links carry user ids and
/// passwords, and the only protection is that no call site passes a link, a
/// `SavedConnection`, or anything that prints one. These helpers keep the parts
/// that make an entry useful — which server, which error — short and uniform.
nonisolated enum LogFormat {
    static func host(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "<none>" }
        return value
    }

    /// A UUID is an identifier here, not a secret, but a full one adds noise to
    /// every line. The prefix is enough to correlate entries within a session.
    static func id(_ value: UUID?) -> String {
        guard let value else { return "<none>" }
        return String(value.uuidString.prefix(8))
    }

    /// Only the description an error type chose to publish. `String(describing:)`
    /// would print associated values, and a parse error's associated value is the
    /// input that failed to parse — which for a link is the secret itself.
    static func error(_ value: Error?) -> String {
        guard let value else { return "<none>" }
        if let described = (value as? LocalizedError)?.errorDescription {
            return described
        }
        return (value as NSError).localizedDescription
    }
}
