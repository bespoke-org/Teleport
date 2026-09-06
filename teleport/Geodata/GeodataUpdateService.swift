import Foundation

enum GeodataKind: String, CaseIterable {
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
    case tooLarge
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
        case .tooLarge:
            return "The download exceeded the size limit for geodata. Check the URL."
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
/// gets delivered to the privileged helper for VPN mode.
struct GeodataUpdateService {
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

    /// Real geodata is a few megabytes; this ceiling only stops a wrong or hostile
    /// URL from making the app read an unbounded file into memory.
    private static let maximumPlausibleByteCount = 64 * 1024 * 1024

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
        let destination = customFileURL(for: kind)
        let changed = (try? Data(contentsOf: destination)) != data
        try data.write(to: destination, options: .atomic)
        return changed
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
        try fileManager.createDirectory(at: resolvedDirectoryURL, withIntermediateDirectories: true)

        for kind in GeodataKind.allCases {
            let sourceURL = try resolvedSourceURL(for: kind, bundle: bundle)
            let destinationURL = resolvedDirectoryURL.appendingPathComponent(kind.fileName)

            if fileManager.fileExists(atPath: destinationURL.path),
               fileManager.contentsEqual(atPath: sourceURL.path, andPath: destinationURL.path) {
                continue
            }
            // Custom files live in a user-writable directory and are only checked at
            // download time, so re-validate whatever actually changed before it is
            // copied into the directory the privileged helper is pointed at. Bundled
            // defaults are covered by the app signature and skipped, which also keeps
            // the common (unchanged) path free of any parsing.
            if sourceURL == customFileURL(for: kind) {
                try GeodataFormat.validate(Data(contentsOf: sourceURL), kind: kind)
            }
            try? fileManager.removeItem(at: destinationURL)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }

        return resolvedDirectoryURL
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

        // `download(for:)` streams to a temporary file, so the size can be rejected
        // before anything is read into memory. `data(for:)` would have to buffer the
        // whole response first, which is precisely what the ceiling exists to stop.
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

        let attributes = try? fileManager.attributesOfItem(atPath: temporaryURL.path)
        guard let byteCount = attributes?[.size] as? Int else {
            throw GeodataUpdateError.invalidResponse
        }
        guard byteCount <= Self.maximumPlausibleByteCount else {
            throw GeodataUpdateError.tooLarge
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
