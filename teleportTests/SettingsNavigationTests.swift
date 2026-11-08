import XCTest

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testRoutingIsOneSidebarDestination() {
        XCTAssertEqual(SettingsSection.tunnel.title, "Routing")
        XCTAssertTrue(SettingsSection.sidebarSections.contains(.tunnel))
        XCTAssertEqual(SettingsSection.tunnel.sidebarSection, .tunnel)
    }

    func testLogsIsAnAdvancedDestinationWithBackAndForwardHistory() {
        XCTAssertFalse(SettingsSection.sidebarSections.contains(.logs))
        var navigation = SettingsNavigation()
        navigation.select(.advanced)
        navigation.select(.logs)
        XCTAssertEqual(navigation.section, .logs)
        XCTAssertEqual(navigation.section.sidebarSection, .advanced)

        navigation.goBack()
        XCTAssertEqual(navigation.section, .advanced)
        navigation.goForward()
        XCTAssertEqual(navigation.section, .logs)
        XCTAssertEqual(navigation.section.sidebarSection, .advanced)
    }

    func testBackAndForwardFollowVisitedSections() {
        var navigation = SettingsNavigation()
        XCTAssertFalse(navigation.canGoBack)
        XCTAssertFalse(navigation.canGoForward)

        navigation.select(.portals)
        navigation.select(.tunnel)
        navigation.select(.advanced)

        navigation.goBack()
        XCTAssertEqual(navigation.section, .tunnel)
        navigation.goBack()
        XCTAssertEqual(navigation.section, .portals)
        navigation.goBack()
        XCTAssertEqual(navigation.section, .general)
        XCTAssertFalse(navigation.canGoBack)

        navigation.goForward()
        XCTAssertEqual(navigation.section, .portals)
        navigation.goForward()
        XCTAssertEqual(navigation.section, .tunnel)
        navigation.goForward()
        XCTAssertEqual(navigation.section, .advanced)
        XCTAssertFalse(navigation.canGoForward)
    }

    func testNewDestinationAfterGoingBackClearsForwardHistory() {
        var navigation = SettingsNavigation()
        navigation.select(.portals)
        navigation.select(.advanced)
        navigation.goBack()
        navigation.select(.logs)

        XCTAssertFalse(navigation.canGoForward)
        navigation.goForward()
        XCTAssertEqual(navigation.section, .logs)
        navigation.goBack()
        XCTAssertEqual(navigation.section, .portals)
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

    func testNextSidebarSectionFollowsVisibleOrderAndWraps() {
        var navigation = SettingsNavigation()
        for expected: SettingsSection in [.portals, .tunnel, .advanced, .about, .general] {
            navigation.selectNextSidebarSection()
            XCTAssertEqual(navigation.section, expected)
        }
    }

    func testPreviousSidebarSectionFollowsVisibleOrderAndWraps() {
        var navigation = SettingsNavigation()
        for expected: SettingsSection in [.about, .advanced, .tunnel, .portals, .general] {
            navigation.selectPreviousSidebarSection()
            XCTAssertEqual(navigation.section, expected)
        }
    }

    func testSidebarCyclingFromNestedPagesUsesTheirParentSection() {
        var navigation = SettingsNavigation()
        navigation.select(.tunnel)
        navigation.selectNextSidebarSection()
        XCTAssertEqual(navigation.section, .advanced)
        navigation.select(.tunnel)
        navigation.selectPreviousSidebarSection()
        XCTAssertEqual(navigation.section, .portals)

        navigation.select(.logs)
        navigation.selectNextSidebarSection()
        XCTAssertEqual(navigation.section, .about)
        navigation.select(.logs)
        navigation.selectPreviousSidebarSection()
        XCTAssertEqual(navigation.section, .tunnel)
    }

    func testSidebarCyclingRecordsHistoryAndClearsForwardHistory() {
        var navigation = SettingsNavigation()
        navigation.select(.logs)
        navigation.selectNextSidebarSection()
        navigation.goBack()
        XCTAssertEqual(navigation.section, .logs)
        navigation.goForward()
        XCTAssertEqual(navigation.section, .about)

        navigation.goBack()
        navigation.selectPreviousSidebarSection()
        XCTAssertEqual(navigation.section, .tunnel)
        XCTAssertFalse(navigation.canGoForward)
        navigation.goBack()
        XCTAssertEqual(navigation.section, .logs)
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
