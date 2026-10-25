import XCTest

@MainActor
final class GeodataSourceDraftTests: XCTestCase {
    func testRecognizesBundledAndExistingProviders() {
        XCTAssertEqual(GeodataSourceDraft(settings: .init()).choice, .bundled)
        for provider in GeodataSourceDraft.presets {
            let settings = GeodataSourceSettings(geositeURLString: provider.geositeURLString,
                                                geoipURLString: provider.geoipURLString)
            let draft = GeodataSourceDraft(settings: settings)
            XCTAssertEqual(draft.choice, .provider(provider.id))
            XCTAssertEqual(draft.urls, GeodataSourceDraft.savedURLs(settings))
        }
    }

    func testCustomDraftKeepsEditsSeparateAndRequiresBothURLs() {
        let settings = GeodataSourceSettings(geositeURLString: "https://example.com/old.dat")
        var draft = GeodataSourceDraft(settings: settings)
        XCTAssertEqual(draft.choice, .custom)
        draft.geositeURL = "  https://example.com/new.dat\n"
        draft.geoipURL = "  "
        XCTAssertEqual(draft.urls.geosite, "https://example.com/new.dat")
        XCTAssertNil(draft.urls.geoip)
        XCTAssertNotNil(draft.validationError(for: .geoip))
        draft.geoipURL = "https://example.com/geoip.dat"
        XCTAssertNil(draft.validationError(for: .geosite))
        XCTAssertNil(draft.validationError(for: .geoip))
        XCTAssertEqual(settings.geositeURLString, "https://example.com/old.dat")
        draft.choice = .bundled
        XCTAssertFalse(draft.urls.usesDownloads)
        XCTAssertNil(draft.validationError(for: .geosite))
        XCTAssertNil(draft.validationError(for: .geoip))
        draft.choice = .custom
        XCTAssertEqual(draft.urls.geosite, "https://example.com/new.dat")
    }

    func testValidationRejectsInvalidDownloadsButAcceptsBundledData() {
        var draft = GeodataSourceDraft(settings: .init())
        draft.choice = .custom
        for value in ["http://example.com/geosite.dat", "not a URL", "https://"] {
            draft.geositeURL = value
            XCTAssertNotNil(draft.validationError(for: .geosite), value)
        }
        draft.geositeURL = "https://example.com/geosite.dat"
        XCTAssertNil(draft.validationError(for: .geosite))
        draft.geositeURL = ""
        XCTAssertNotNil(draft.validationError(for: .geosite))
        XCTAssertFalse(draft.urls.usesDownloads)
    }
}
