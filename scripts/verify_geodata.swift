import Foundation

@main
struct VerifyGeodata {
    static func main() throws {
        try testGeodataSettingsDefaultsWhenMissing()
        try testGeodataSettingsRoundTrip()
        try testGeodataKindFileNames()
        try testGeodataUpdateErrorDescriptionsAreNonEmpty()
        try testStoreReportsWhetherBytesChanged()
        print("verify_geodata: all checks passed")
    }

    /// Redirects the Application Support base directory to a throwaway location so
    /// GeodataUpdateService.store writes to a temp path instead of the developer's
    /// real ~/Library/Application Support/teleport/geodata store.
    private final class TempFileManager: FileManager {
        let root: URL
        init(root: URL) {
            self.root = root
            super.init()
        }

        override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
            if directory == .applicationSupportDirectory {
                return [root]
            }
            return super.urls(for: directory, in: domainMask)
        }
    }

    private static func testStoreReportsWhetherBytesChanged() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-verify-geodata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = GeodataUpdateService(fileManager: TempFileManager(root: root))
        let payloadA = Data(repeating: 0xAB, count: 8192)
        let payloadB = Data(repeating: 0xCD, count: 8192)

        let firstWrite = try service.store(payloadA, for: .geosite)
        precondition(firstWrite, "expected the first write of a new file to report changed == true")

        let identicalRewrite = try service.store(payloadA, for: .geosite)
        precondition(!identicalRewrite, "expected rewriting identical bytes to report changed == false")

        let changedRewrite = try service.store(payloadB, for: .geosite)
        precondition(changedRewrite, "expected writing different bytes to report changed == true")

        precondition(service.hasCustomGeodata(for: .geosite), "expected the stored custom file to exist")
        precondition(!service.hasCustomGeodata(for: .geoip), "expected only the written kind to exist")
    }

    private static func testGeodataSettingsDefaultsWhenMissing() throws {
        let legacyJSON = """
        {
          "savedConnections": [],
          "subscriptionSources": [],
          "proxyEndpoint": { "host": "127.0.0.1", "httpPort": 8080, "socksPort": 1080 }
        }
        """
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: Data(legacyJSON.utf8))
        precondition(decoded.geodataSettings.geositeURLString == nil, "expected no custom geosite URL by default")
        precondition(decoded.geodataSettings.geoipURLString == nil, "expected no custom geoip URL by default")
        precondition(decoded.geodataSettings.autoUpdateIntervalMinutes == nil, "expected auto-update off by default")
        precondition(decoded.geodataSettings.geositeLastUpdatedAt == nil)
        precondition(decoded.geodataSettings.geoipLastError == nil)
    }

    private static func testGeodataSettingsRoundTrip() throws {
        let settings = GeodataSourceSettings(
            geositeURLString: "https://example.com/geosite.dat",
            geoipURLString: "https://example.com/geoip.dat",
            autoUpdateIntervalMinutes: 1440,
            geositeLastUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            geoipLastUpdatedAt: nil,
            geositeLastError: nil,
            geoipLastError: "Download failed with status 404"
        )
        let snapshot = AppSnapshot(
            savedConnections: [],
            subscriptionSources: [],
            selectedConnectionID: nil,
            proxyEndpoint: .default,
            geodataSettings: settings
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: data)

        precondition(decoded.geodataSettings.geositeURLString == "https://example.com/geosite.dat")
        precondition(decoded.geodataSettings.geoipURLString == "https://example.com/geoip.dat")
        precondition(decoded.geodataSettings.autoUpdateIntervalMinutes == 1440)
        precondition(decoded.geodataSettings.geositeLastUpdatedAt == settings.geositeLastUpdatedAt)
        precondition(decoded.geodataSettings.geoipLastUpdatedAt == nil)
        precondition(decoded.geodataSettings.geositeLastError == nil)
        precondition(decoded.geodataSettings.geoipLastError == "Download failed with status 404")
    }

    private static func testGeodataKindFileNames() throws {
        precondition(GeodataKind.geosite.fileName == "geosite.dat")
        precondition(GeodataKind.geoip.fileName == "geoip.dat")
        precondition(GeodataKind.allCases.count == 2)
    }

    private static func testGeodataUpdateErrorDescriptionsAreNonEmpty() throws {
        let errors: [GeodataUpdateError] = [
            .invalidURL,
            .networkFailure("boom"),
            .invalidResponse,
            .emptyPayload,
            .tooSmall,
            .bundledDefaultMissing
        ]
        for error in errors {
            precondition(!(error.errorDescription ?? "").isEmpty, "expected a non-empty description for \(error)")
        }
    }
}
