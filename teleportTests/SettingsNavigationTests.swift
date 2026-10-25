import XCTest

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testBackAndForwardFollowVisitedSections() {
        var navigation = SettingsNavigation()
        XCTAssertFalse(navigation.canGoBack)
        XCTAssertFalse(navigation.canGoForward)

        navigation.select(.connections)
        navigation.select(.splitTunneling)
        navigation.select(.geodata)

        navigation.goBack()
        XCTAssertEqual(navigation.section, .splitTunneling)
        navigation.goBack()
        XCTAssertEqual(navigation.section, .connections)
        navigation.goBack()
        XCTAssertEqual(navigation.section, .general)
        XCTAssertFalse(navigation.canGoBack)

        navigation.goForward()
        XCTAssertEqual(navigation.section, .connections)
        navigation.goForward()
        XCTAssertEqual(navigation.section, .splitTunneling)
        navigation.goForward()
        XCTAssertEqual(navigation.section, .geodata)
        XCTAssertFalse(navigation.canGoForward)
    }

    func testNewDestinationAfterGoingBackClearsForwardHistory() {
        var navigation = SettingsNavigation()
        navigation.select(.connections)
        navigation.select(.geodata)
        navigation.goBack()
        navigation.select(.logs)

        XCTAssertFalse(navigation.canGoForward)
        navigation.goForward()
        XCTAssertEqual(navigation.section, .logs)
        navigation.goBack()
        XCTAssertEqual(navigation.section, .connections)
    }

    func testSelectingCurrentSectionPreservesForwardHistory() {
        var navigation = SettingsNavigation()
        navigation.select(.advanced)
        navigation.goBack()
        navigation.select(.general)

        XCTAssertFalse(navigation.canGoBack)
        XCTAssertTrue(navigation.canGoForward)
        navigation.goForward()
        XCTAssertEqual(navigation.section, .advanced)
        navigation.goBack()
        XCTAssertFalse(navigation.canGoBack)
    }

    func testNavigatingBeyondHistoryDoesNothing() {
        var navigation = SettingsNavigation()
        navigation.goBack()
        navigation.goForward()
        XCTAssertEqual(navigation.section, .general)

        navigation.select(.about)
        navigation.goForward()
        XCTAssertEqual(navigation.section, .about)
        navigation.goBack()
        XCTAssertEqual(navigation.section, .general)
        navigation.goBack()
        XCTAssertEqual(navigation.section, .general)
    }
}
