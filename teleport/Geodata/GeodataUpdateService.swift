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
    case networkFailure(String)
    case invalidResponse
    case emptyPayload
    case tooSmall
    case bundledDefaultMissing

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid http:// or https:// URL."
        case let .networkFailure(message):
            return message
        case .invalidResponse:
            return "The server did not return a valid response."
        case .emptyPayload:
            return "The downloaded file was empty."
        case .tooSmall:
            return "The downloaded file is too small to be valid geodata. Check the URL."
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
    /// Real geosite.dat/geoip.dat files are several megabytes; this is a floor
    /// well below that meant only to catch obviously-wrong downloads (HTML
    /// error pages, truncated transfers), not to validate the format itself.
    // TODO(gpt-5.6-sol): Size is not an integrity or format check. These bytes are
    // later parsed by a root Xray process, so accept HTTPS only and validate the
    // expected protobuf structure plus a trusted digest/signature before storing
    // or copying an update across the privilege boundary.
    private static let minimumPlausibleByteCount = 4096

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func customFileURL(for kind: GeodataKind) -> URL {
        customDirectoryURL.appendingPathComponent(kind.fileName)
    }

    func hasCustomGeodata(for kind: GeodataKind) -> Bool {
        fileManager.fileExists(atPath: customFileURL(for: kind).path)
    }

    @discardableResult
    func downloadAndStore(kind: GeodataKind, from url: URL) throws -> Int {
        let data = try download(kind: kind, from: url)
        try store(data, for: kind)
        return data.count
    }

    func download(kind: GeodataKind, from url: URL) throws -> Data {
        let data = try downloadData(from: url)
        guard !data.isEmpty else { throw GeodataUpdateError.emptyPayload }
        guard data.count >= Self.minimumPlausibleByteCount else { throw GeodataUpdateError.tooSmall }
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

    // TODO(gpt-5.6-sol): Make downloads async, cancellable, and size-bounded while
    // streaming. `dataTask` currently buffers an unbounded response in memory, and
    // the UI's Cancel action only discards the eventual result; it cannot cancel
    // this synchronous semaphore wait or the underlying network transfer.
    private func downloadData(from url: URL) throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let session = URLSession(configuration: .ephemeral)
        let semaphore = DispatchSemaphore(value: 0)

        var responseData: Data?
        var response: URLResponse?
        var responseError: Error?

        let task = session.dataTask(with: request) { data, urlResponse, error in
            responseData = data
            response = urlResponse
            responseError = error
            semaphore.signal()
        }

        task.resume()
        semaphore.wait()
        session.finishTasksAndInvalidate()

        if let responseError {
            throw GeodataUpdateError.networkFailure(responseError.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeodataUpdateError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw GeodataUpdateError.networkFailure("Download failed with status \(httpResponse.statusCode)")
        }

        guard let responseData, !responseData.isEmpty else {
            throw GeodataUpdateError.emptyPayload
        }

        return responseData
    }

    private var customDirectoryURL: URL {
        applicationSupportDirectoryURL.appendingPathComponent("geodata", isDirectory: true)
    }

    private var applicationSupportDirectoryURL: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("teleport", isDirectory: true)
    }
}
