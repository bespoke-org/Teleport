import Foundation

@main
struct VerifyGeodata {
    static func main() throws {
        try testGeodataSettingsDefaultsWhenMissing()
        try testGeodataSettingsRoundTrip()
        try testGeodataKindFileNames()
        try testGeodataUpdateErrorDescriptionsAreNonEmpty()
        print("verify_geodata: all checks passed")
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
