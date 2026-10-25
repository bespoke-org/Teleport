import Combine
import Foundation

nonisolated enum SettingsLogFile: String, CaseIterable, Identifiable, Sendable {
    case app, helper, systemProxy, tun, tunControl, tunConfig

    var id: Self { self }
    var isConfiguration: Bool { self == .tunConfig }
    static var logs: [Self] { allCases.filter { !$0.isConfiguration } }

    var title: String {
        switch self {
        case .app: return "Teleport"
        case .helper: return "Privileged helper"
        case .systemProxy: return "Xray (System Proxy)"
        case .tun: return "Xray (TUN)"
        case .tunControl: return "Tunnel setup"
        case .tunConfig: return "TUN configuration"
        }
    }

    var helperLogName: String? {
        switch self {
        case .app, .systemProxy: return nil
        case .helper: return "helper.log"
        case .tun: return "xray-tun.log"
        case .tunControl: return "xray-tun-control.log"
        case .tunConfig: return "xray-tun-config.json"
        }
    }

    var url: URL {
        if let helperLogName {
            return URL(fileURLWithPath: PrivilegedHelperConstants.helperStateDirectoryPath, isDirectory: true)
                .appendingPathComponent(helperLogName)
        }
        if self == .app { return TeleportLog.shared.fileURL }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("teleport/xray.log")
    }

    var missingExplanation: String {
        switch self {
        case .app: return "Teleport hasn’t written this log yet."
        case .systemProxy: return "Connect in System Proxy mode to create this log."
        case .helper: return "The privileged helper hasn’t written this log yet."
        case .tunConfig: return "Connect in TUN mode to generate a configuration."
        case .tun, .tunControl: return "Connect in TUN mode to create this log."
        }
    }
}

nonisolated struct LogSnapshot: Sendable {
    var text: String
    var isMissing = false
    var isTruncated = false
    var refreshedAt = Date()
}

nonisolated enum LogReader {
    static let maximumBytes = 256 * 1024

    static func read(_ source: SettingsLogFile) async throws -> LogSnapshot {
        if let name = source.helperLogName {
            let response = try await PrivilegedHelperClient().readLog(logName: name, maxBytes: maximumBytes)
            return snapshot(from: response.payload)
        }
        return try await BlockingWork.run { try readFile(source.url) }
    }

    static func snapshot(from response: DiagnosticsResponse) -> LogSnapshot {
        var text = response.text
        // The helper includes a display notice in its bounded response. Show that
        // in the status bar instead, so copying/saving keeps only the file contents.
        if response.wasTruncated, text.hasPrefix("… showing last "), let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return LogSnapshot(text: text, isMissing: response.metadata.hasPrefix("Missing: "),
                           isTruncated: response.wasTruncated)
    }

    static func readFile(_ url: URL, maximumBytes: Int = maximumBytes) throws -> LogSnapshot {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return LogSnapshot(text: "", isMissing: true)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ReadError.notRegularFile
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let limit = UInt64(max(1, maximumBytes))
        let offset = size > limit ? size - limit : 0
        try handle.seek(toOffset: offset)
        var data = try handle.read(upToCount: Int(limit)) ?? Data()
        // A tail may begin inside a UTF-8 scalar. Drop continuation bytes only;
        // invalid bytes elsewhere are replaced rather than hiding the entire log.
        if offset > 0 {
            while let first = data.first, first & 0xC0 == 0x80 { data.removeFirst() }
        }
        return LogSnapshot(text: String(decoding: data, as: UTF8.self), isTruncated: offset > 0)
    }

    private enum ReadError: LocalizedError {
        case notRegularFile
        var errorDescription: String? { "This path is not a regular file." }
    }
}

@MainActor
final class LogReaderModel: ObservableObject {
    @Published private(set) var source: SettingsLogFile = .app
    @Published private(set) var snapshot: LogSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    private var requestID = UUID()
    private let read: (SettingsLogFile) async throws -> LogSnapshot

    init(read: @escaping (SettingsLogFile) async throws -> LogSnapshot = { try await LogReader.read($0) }) {
        self.read = read
    }

    func select(_ source: SettingsLogFile) {
        guard self.source != source else { return }
        requestID = UUID()
        self.source = source
        snapshot = nil
        error = nil
        isLoading = false
    }

    func refresh(_ source: SettingsLogFile) async {
        guard !Task.isCancelled else { return }
        select(source)
        let request = UUID()
        requestID = request
        isLoading = true
        defer { if requestID == request { isLoading = false } }
        do {
            let result = try await read(source)
            guard requestID == request, !Task.isCancelled else { return }
            snapshot = result
            error = nil
        } catch {
            guard requestID == request, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
