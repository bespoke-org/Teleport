import CryptoKit
import Foundation

nonisolated enum GeodataKind: String, CaseIterable {
    case geosite
    case geoip

    var fileName: String { "\(rawValue).dat" }

    var displayName: String {
        switch self {
        case .geosite: return "Geosite"
        case .geoip: return "GeoIP"
        }
    }
}

enum GeodataUpdateError: LocalizedError {
    case invalidURL
    case insecureURL
    case networkFailure(String)
    case invalidResponse
    case emptyPayload
    case tooSmall
    case unreadablePayload(GeodataKind)
    case bundledDefaultMissing

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid https:// URL."
        case .insecureURL:
            return "Geodata must be downloaded over https://. Plain http can be rewritten in transit, and these files decide which traffic leaves the tunnel."
        case let .networkFailure(message):
            return message
        case .invalidResponse:
            return "The server did not return a valid response."
        case .emptyPayload:
            return "The downloaded file was empty."
        case .tooSmall:
            return "The downloaded file is too small to be valid geodata. Check the URL."
        case let .unreadablePayload(kind):
            return "The downloaded file is not readable \(kind.displayName) data. Check that the URL points at \(kind.fileName)."
        case .bundledDefaultMissing:
            return "Teleport's bundled geodata is missing. Reinstall Teleport."
        }
    }
}

/// Downloads, stores, and resolves geosite.dat/geoip.dat. Custom files a user
/// supplies by URL are kept separately from Teleport's bundled defaults; the
/// "resolved" directory always contains exactly one usable file per kind
/// (custom override if present, otherwise the bundled default) and is what
/// gets delivered to the privileged helper for TUN mode.
nonisolated struct GeodataUpdateService {
    struct CachedDownload: Sendable {
        let data: Data
        let updatedAt: Date
    }

    struct PreparedUpdate: Sendable {
        let stagedURL: URL
        let updatedAt: Date
        let changed: Bool
    }

    private struct CacheReceipt: Codable {
        let updatedAt: Date
        let digest: String
    }

    private struct ResolvedAssetStamp: Codable, Equatable {
        let sourcePath: String
        let byteCount: Int
        let modificationTime: TimeInterval
    }

    private static let resolvedManifestFileName = ".source-manifest.json"

    /// A floor well below real geodata size, kept as a cheap first rejection; the
    /// actual check is `GeodataFormat.validate`.
    ///
    /// Note on what is and is not guaranteed: downloads are HTTPS-only and must
    /// parse as the expected kind before being stored, which covers corruption,
    /// error pages and wrong URLs. It is not authenticity — a well-formed file from
    /// a source you should not have trusted parses fine. A pinned digest cannot fix
    /// that either, since geodata legitimately changes and the URL is user-supplied,
    /// so the source itself remains the thing being trusted.
    private static let minimumPlausibleByteCount = 4096

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The single rule for what counts as a geodata source. https only: these files
    /// decide which traffic leaves the tunnel, so a payload that can be rewritten in
    /// transit is not acceptable.
    static func validatedSourceURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              let url = components.url else {
            return nil
        }
        return url
    }

    func customFileURL(for kind: GeodataKind) -> URL {
        customDirectoryURL.appendingPathComponent(kind.fileName)
    }

    func hasCustomGeodata(for kind: GeodataKind) -> Bool {
        fileManager.fileExists(atPath: customFileURL(for: kind).path)
    }

    private func cacheURL(for kind: GeodataKind, source: URL) -> URL {
        let key = SHA256.hash(data: Data(source.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return customDirectoryURL.appendingPathComponent("sources", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true).appendingPathComponent(kind.fileName)
    }

    func cachedDownload(for kind: GeodataKind, source: URL) -> CachedDownload? {
        let file = cacheURL(for: kind, source: source)
        guard let data = try? Data(contentsOf: file),
              let receiptData = try? Data(contentsOf: file.appendingPathExtension("json")),
              let receipt = try? JSONDecoder().decode(CacheReceipt.self, from: receiptData),
              receipt.digest == Self.digest(data),
              (try? GeodataFormat.validate(data, kind: kind)) != nil else { return nil }
        return CachedDownload(data: data, updatedAt: receipt.updatedAt)
    }

    func cacheDownload(_ download: CachedDownload, for kind: GeodataKind, source: URL) throws {
        try GeodataFormat.validate(download.data, kind: kind)
        let file = cacheURL(for: kind, source: source)
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try download.data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let receipt = CacheReceipt(updatedAt: download.updatedAt, digest: Self.digest(download.data))
        try JSONEncoder().encode(receipt).write(to: file.appendingPathExtension("json"), options: .atomic)
    }

    /// Preserve downloads made before the per-source cache was introduced.
    func cacheCurrentDownload(for kind: GeodataKind, source: URL?, updatedAt: Date?) throws {
        guard let source, let updatedAt, cachedDownload(for: kind, source: source) == nil,
              let data = try? Data(contentsOf: customFileURL(for: kind)),
              (try? GeodataFormat.validate(data, kind: kind)) != nil else { return }
        try cacheDownload(CachedDownload(data: data, updatedAt: updatedAt), for: kind, source: source)
    }

    /// Prepare off the main actor; publishing the file is a separate, atomic step
    /// so a cancelled or superseded request cannot replace the active dataset.
    func prepareUpdate(
        kind: GeodataKind, from source: URL, useCache: Bool,
        download: (@Sendable (GeodataKind, URL) async throws -> Data)? = nil
    ) async throws -> PreparedUpdate {
        let cached = useCache ? await BlockingWork.run { cachedDownload(for: kind, source: source) } : nil
        let result: CachedDownload
        if let cached {
            result = cached
        } else {
            let data: Data
            if let download { data = try await download(kind, source) }
            else { data = try await self.download(kind: kind, from: source) }
            try Task.checkCancellation()
            result = CachedDownload(data: data, updatedAt: Date())
            try await BlockingWork.run { try cacheDownload(result, for: kind, source: source) }
        }
        try Task.checkCancellation()
        return try await BlockingWork.run {
            try fileManager.createDirectory(at: customDirectoryURL, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let stagedURL = customDirectoryURL.appendingPathComponent(".\(kind.rawValue)-\(UUID().uuidString).pending")
            try result.data.write(to: stagedURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedURL.path)
            return PreparedUpdate(stagedURL: stagedURL, updatedAt: result.updatedAt,
                                  changed: (try? Data(contentsOf: customFileURL(for: kind))) != result.data)
        }
    }

    func activate(_ update: PreparedUpdate, for kind: GeodataKind) throws {
        guard update.changed else {
            discard(update)
            return
        }
        let destination = customFileURL(for: kind)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: update.stagedURL)
        } else {
            try fileManager.moveItem(at: update.stagedURL, to: destination)
        }
    }

    func discard(_ update: PreparedUpdate) {
        try? fileManager.removeItem(at: update.stagedURL)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func download(kind: GeodataKind, from url: URL) async throws -> Data {
        let data = try await downloadData(from: url)
        guard !data.isEmpty else { throw GeodataUpdateError.emptyPayload }
        guard data.count >= Self.minimumPlausibleByteCount else { throw GeodataUpdateError.tooSmall }
        // Parse before storing: these bytes are about to be written where a root
        // Xray process will read them.
        try GeodataFormat.validate(data, kind: kind)
        return data
    }

    /// Writes the downloaded payload to the custom store and reports whether it
    /// differs from what was already there, so callers can skip an expensive
    /// live-tunnel bounce when a (scheduled) re-download produced identical bytes.
    @discardableResult
    func store(_ data: Data, for kind: GeodataKind) throws -> Bool {
        try fileManager.createDirectory(at: customDirectoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: customDirectoryURL.path)
        let destination = customFileURL(for: kind)
        if (try? Data(contentsOf: destination)) == data {
            return false
        }
        try data.write(to: destination, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return true
    }

    func removeCustomGeodata(for kind: GeodataKind) throws {
        let file = customFileURL(for: kind)
        guard fileManager.fileExists(atPath: file.path) else { return }
        try fileManager.removeItem(at: file)
    }

    /// Ensures a directory exists containing exactly one geosite.dat and one
    /// geoip.dat, preferring custom downloads over the bundled defaults, and
    /// returns it. Only rewrites a resolved file when its source changed, so
    /// this is cheap to call on every connect.
    func resolvedAssetDirectoryURL(bundle: Bundle = .main) throws -> URL {
        let resolvedDirectoryURL = applicationSupportDirectoryURL.appendingPathComponent("geodata-resolved", isDirectory: true)
        let manifestURL = resolvedDirectoryURL.appendingPathComponent(Self.resolvedManifestFileName)
        try fileManager.createDirectory(at: resolvedDirectoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: resolvedDirectoryURL.path)

        var manifest = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode([String: ResolvedAssetStamp].self, from: $0) } ?? [:]
        var manifestChanged = false

        for kind in GeodataKind.allCases {
            let sourceURL = try resolvedSourceURL(for: kind, bundle: bundle)
            let destinationURL = resolvedDirectoryURL.appendingPathComponent(kind.fileName)
            let sourceStamp = try resolvedAssetStamp(for: sourceURL, kind: kind)

            if fileManager.fileExists(atPath: destinationURL.path),
               manifest[kind.rawValue] == sourceStamp {
                continue
            }
            // Custom files live in a user-writable directory and are only checked at
            // download time, so re-validate whatever actually changed before it is
            // copied into the directory the privileged helper is pointed at. Bundled
            // defaults are covered by the app signature and skipped.
            if sourceURL == customFileURL(for: kind) {
                try GeodataFormat.validate(Data(contentsOf: sourceURL), kind: kind)
            }
            try? fileManager.removeItem(at: destinationURL)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
            manifest[kind.rawValue] = sourceStamp
            manifestChanged = true
        }

        if manifestChanged || !fileManager.fileExists(atPath: manifestURL.path) {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        }
        return resolvedDirectoryURL
    }

    private func resolvedAssetStamp(for sourceURL: URL, kind: GeodataKind) throws -> ResolvedAssetStamp {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let byteCount = values.fileSize,
              let modificationDate = values.contentModificationDate else {
            throw GeodataUpdateError.unreadablePayload(kind)
        }
        return ResolvedAssetStamp(
            sourcePath: sourceURL.standardizedFileURL.path,
            byteCount: byteCount,
            modificationTime: modificationDate.timeIntervalSince1970
        )
    }

    private func resolvedSourceURL(for kind: GeodataKind, bundle: Bundle) throws -> URL {
        let customURL = customFileURL(for: kind)
        if fileManager.fileExists(atPath: customURL.path) {
            return customURL
        }
        guard let bundledURL = bundle.url(forResource: kind.rawValue, withExtension: "dat") else {
            throw GeodataUpdateError.bundledDefaultMissing
        }
        return bundledURL
    }

    /// Cancellable by construction: cancelling the surrounding `Task` propagates into
    /// `URLSession`, so the UI's Cancel action stops the transfer itself rather than
    /// discarding a download that keeps running.
    private func downloadData(from url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw GeodataUpdateError.insecureURL
        }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        // `download(for:)` streams the network response to a temporary file instead
        // of buffering it during transfer. The completed payload is then loaded for
        // protobuf validation without imposing an arbitrary dataset-size ceiling.
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GeodataUpdateError.networkFailure(error.localizedDescription)
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeodataUpdateError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw GeodataUpdateError.networkFailure("Download failed with status \(httpResponse.statusCode)")
        }

        return try Data(contentsOf: temporaryURL)
    }

    private var customDirectoryURL: URL {
        applicationSupportDirectoryURL.appendingPathComponent("geodata", isDirectory: true)
    }

    private var applicationSupportDirectoryURL: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("teleport", isDirectory: true)
    }
}
