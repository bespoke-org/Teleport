import XCTest

final class ConnectionFailurePresentationTests: XCTestCase {
    func testCompactNoticeSeparatesCauseFromRecoveryWithoutLosingEither() {
        let message = "Geosite category ‘RU’ is missing. Download the subscription's geodata in Settings → Tunnel, or edit the routing rule."
        let failure = ConnectionFailure(summary: message, details: "Technical diagnostic")
        XCTAssertEqual(failure.briefSummary, "Geosite category ‘RU’ is missing.")
        XCTAssertEqual(failure.recoveryInstructions, "Download the subscription's geodata in Settings → Tunnel, or edit the routing rule.")
        XCTAssertEqual(failure.summary, message, "Copying and exporting the error must retain all recovery steps")
        XCTAssertEqual(failure.details, "Technical diagnostic")
    }

    func testShortMessagesRemainComplete() {
        let failure = ConnectionFailure(summary: "Administrator approval was cancelled.", details: nil)
        XCTAssertEqual(failure.briefSummary, failure.summary)
        XCTAssertNil(failure.recoveryInstructions)
    }

    func testFileExtensionsAreNotMistakenForSentenceBoundaries() {
        let failure = ConnectionFailure(summary: "The geosite.dat file is missing. Download the profile again.", details: nil)
        XCTAssertEqual(failure.briefSummary, "The geosite.dat file is missing.")
        XCTAssertEqual(failure.recoveryInstructions, "Download the profile again.")
    }
}
