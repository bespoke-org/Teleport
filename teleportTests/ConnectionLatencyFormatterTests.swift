import Foundation
import XCTest

final class ConnectionLatencyFormatterTests: XCTestCase {
    func testMillisecondsBelowOneSecond() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(ConnectionLatencyFormatter.string(milliseconds: 42, locale: locale), "42 ms")
        XCTAssertEqual(ConnectionLatencyFormatter.string(milliseconds: 999, locale: locale), "999 ms")
    }

    func testSecondsUseTwoDecimalPlaces() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(ConnectionLatencyFormatter.string(milliseconds: 1_000, locale: locale), "1.00 s")
        XCTAssertEqual(ConnectionLatencyFormatter.string(milliseconds: 5_324, locale: locale), "5.32 s")
        XCTAssertEqual(ConnectionLatencyFormatter.string(milliseconds: 5_326, locale: locale), "5.33 s")
    }

    func testLocaleControlsDecimalSeparator() {
        XCTAssertEqual(ConnectionLatencyFormatter.string(milliseconds: 5_324, locale: Locale(identifier: "ru_RU")), "5,32 s")
    }
}
