import Foundation
import XCTest

final class GeodataTests: XCTestCase {
    /// Redirects the Application Support base directory to a throwaway location so
    /// GeodataUpdateService.store writes to a temp path instead of the developer's
    /// real ~/Library/Application Support/teleport/geodata store.
    private final class TempFileManager: FileManager {
        let root: URL
        private(set) var contentsEqualCallCount = 0

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

        override func contentsEqual(atPath path1: String, andPath path2: String) -> Bool {
            contentsEqualCallCount += 1
            return super.contentsEqual(atPath: path1, andPath: path2)
        }
    }

    func testStoreReportsWhetherBytesChanged() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-verify-geodata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = GeodataUpdateService(fileManager: TempFileManager(root: root))
        let payloadA = Data(repeating: 0xAB, count: 8192)
        let payloadB = Data(repeating: 0xCD, count: 8192)

        let firstWrite = try service.store(payloadA, for: .geosite)
        XCTAssert(firstWrite, "expected the first write of a new file to report changed == true")

        let identicalRewrite = try service.store(payloadA, for: .geosite)
        XCTAssert(!identicalRewrite, "expected rewriting identical bytes to report changed == false")

        let changedRewrite = try service.store(payloadB, for: .geosite)
        XCTAssert(changedRewrite, "expected writing different bytes to report changed == true")

        XCTAssert(service.hasCustomGeodata(for: .geosite), "expected the stored custom file to exist")
        XCTAssert(!service.hasCustomGeodata(for: .geoip), "expected only the written kind to exist")
    }

    func testResolvedAssetsUseMetadataManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-verify-geodata-resolved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileManager = TempFileManager(root: root)
        let service = GeodataUpdateService(fileManager: fileManager)
        try service.store(geositeFixture(), for: .geosite)
        try service.store(geoipFixture(), for: .geoip)

        let resolved = try service.resolvedAssetDirectoryURL()
        _ = try service.resolvedAssetDirectoryURL()
        XCTAssert(fileManager.contentsEqualCallCount == 0, "expected repeated resolution to avoid full-file comparisons")
        XCTAssert(
            fileManager.fileExists(atPath: resolved.appendingPathComponent(".source-manifest.json").path),
            "expected a small source metadata manifest"
        )

        let changed = geositeFixture(domain: "changed.example.com")
        try service.store(changed, for: .geosite)
        _ = try service.resolvedAssetDirectoryURL()
        let refreshed = try Data(contentsOf: resolved.appendingPathComponent("geosite.dat"))
        XCTAssert(refreshed == changed, "expected changed source metadata to refresh the resolved asset")
    }

    func testGeodataSettingsDefaultsWhenMissing() throws {
        let legacyJSON = """
        {
          "savedConnections": [],
          "subscriptionSources": [],
          "proxyEndpoint": { "host": "127.0.0.1", "httpPort": 8080, "socksPort": 1080 }
        }
        """
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: Data(legacyJSON.utf8))
        XCTAssert(decoded.geodataSettings.geositeURLString == nil, "expected no custom geosite URL by default")
        XCTAssert(decoded.geodataSettings.geoipURLString == nil, "expected no custom geoip URL by default")
        XCTAssert(decoded.geodataSettings.autoUpdateIntervalMinutes == nil, "expected auto-update off by default")
        XCTAssert(decoded.geodataSettings.geositeLastUpdatedAt == nil)
        XCTAssert(decoded.geodataSettings.geoipLastError == nil)
    }

    func testGeodataSettingsRoundTrip() throws {
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

        XCTAssert(decoded.geodataSettings.geositeURLString == "https://example.com/geosite.dat")
        XCTAssert(decoded.geodataSettings.geoipURLString == "https://example.com/geoip.dat")
        XCTAssert(decoded.geodataSettings.autoUpdateIntervalMinutes == 1440)
        XCTAssert(decoded.geodataSettings.geositeLastUpdatedAt == settings.geositeLastUpdatedAt)
        XCTAssert(decoded.geodataSettings.geoipLastUpdatedAt == nil)
        XCTAssert(decoded.geodataSettings.geositeLastError == nil)
        XCTAssert(decoded.geodataSettings.geoipLastError == "Download failed with status 404")
    }

    // MARK: - Protobuf fixtures

    private func varint(_ value: Int) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining != 0
        return bytes
    }

    private func tag(_ field: Int, _ wireType: Int) -> [UInt8] {
        varint(field << 3 | wireType)
    }

    private func lengthDelimited(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        tag(field, 2) + varint(payload.count) + payload
    }

    private var oversizedIntVarint: [UInt8] {
        Array(repeating: 0xFF, count: 9) + [0x01]
    }

    /// One `geosite.dat` entry: country "test" holding the domain "example.com".
    private func geositeFixture(domain value: String = "example.com") -> Data {
        let domain = tag(1, 0) + varint(2) + lengthDelimited(2, Array(value.utf8))
        let site = lengthDelimited(1, Array("test".utf8)) + lengthDelimited(2, domain)
        return Data(lengthDelimited(1, site))
    }

    /// One `geoip.dat` entry: country "cn" holding the range 1.2.3.4/24.
    private func geoipFixture() -> Data {
        let cidr = lengthDelimited(1, [1, 2, 3, 4]) + tag(2, 0) + varint(24)
        let country = lengthDelimited(1, Array("cn".utf8)) + lengthDelimited(2, cidr)
        return Data(lengthDelimited(1, country))
    }

    // MARK: - Tests

    func testSourceURLRequiresHTTPS() throws {
        XCTAssert(GeodataUpdateService.validatedSourceURL("https://example.com/geosite.dat") != nil)
        XCTAssert(
            GeodataUpdateService.validatedSourceURL("http://example.com/geosite.dat") == nil,
            "plain http must be refused: geodata decides which traffic leaves the tunnel"
        )
        XCTAssert(GeodataUpdateService.validatedSourceURL("HTTPS://example.com/x.dat") != nil, "scheme match must be case-insensitive")
        XCTAssert(GeodataUpdateService.validatedSourceURL("file:///etc/passwd") == nil)
        XCTAssert(GeodataUpdateService.validatedSourceURL("https:///no-host.dat") == nil)
        XCTAssert(GeodataUpdateService.validatedSourceURL("not a url") == nil)
    }

    func testFormatValidationRejectsUnusablePayloads() throws {
        try GeodataFormat.validate(geositeFixture(), kind: .geosite)
        try GeodataFormat.validate(geoipFixture(), kind: .geoip)

        for kind in GeodataKind.allCases {
            expectRejected(Data("<!DOCTYPE html><html><body>404</body></html>".utf8), kind: kind, what: "an HTML error page")
            expectRejected(Data(), kind: kind, what: "an empty payload")
            expectRejected(geositeFixture().prefix(3), kind: kind, what: "a truncated transfer")
        }
    }

    /// Each kind's records skip cleanly as the other's, so a cross-kind file parses
    /// into a dictionary of empty entries rather than failing outright. Requiring
    /// real content is what catches it.
    func testFormatValidationRejectsTheOtherKind() throws {
        expectRejected(geoipFixture(), kind: .geosite, what: "a geoip file offered as geosite")
        expectRejected(geositeFixture(), kind: .geoip, what: "a geosite file offered as geoip")
    }

    func testFormatValidationRejectsOversizedIntegerVarints() throws {
        let oversizedLength = Data(tag(1, 2) + oversizedIntVarint)
        expectRejected(oversizedLength, kind: .geosite, what: "a length larger than Int.max")

        let domain = tag(1, 0) + oversizedIntVarint + lengthDelimited(2, Array("example.com".utf8))
        let site = lengthDelimited(1, Array("test".utf8)) + lengthDelimited(2, domain)
        expectRejected(Data(lengthDelimited(1, site)), kind: .geosite, what: "a domain type larger than Int.max")

        let cidr = lengthDelimited(1, [10, 0, 0, 0]) + tag(2, 0) + oversizedIntVarint
        let country = lengthDelimited(1, Array("test".utf8)) + lengthDelimited(2, cidr)
        expectRejected(Data(lengthDelimited(1, country)), kind: .geoip, what: "a CIDR prefix larger than Int.max")
    }

    private func expectRejected(_ data: Data, kind: GeodataKind, what: String) {
        do {
            try GeodataFormat.validate(data, kind: kind)
            XCTFail("expected \(what) to be rejected as \(kind.fileName)")
        } catch {
            // Expected.
        }
    }

    func testGeodataUpdateErrorDescriptionsAreNonEmpty() throws {
        let errors: [GeodataUpdateError] = [
            .invalidURL,
            .networkFailure("boom"),
            .invalidResponse,
            .emptyPayload,
            .tooSmall,
            .insecureURL,
            .unreadablePayload(.geosite),
            .unreadablePayload(.geoip),
            .bundledDefaultMissing
        ]
        for error in errors {
            XCTAssert(!(error.errorDescription ?? "").isEmpty, "expected a non-empty description for \(error)")
        }
    }
}
