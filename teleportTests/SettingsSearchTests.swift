import XCTest

final class SettingsSearchTests: XCTestCase {
    func testEmptyQueryRestoresTopLevelSidebar() {
        XCTAssertEqual(SettingsSearch.results(for: " \n ").map(\.section), SettingsSection.sidebarSections)
    }

    func testSearchFindsSettingLabelsAndAliases() {
        XCTAssertEqual(SettingsSearch.results(for: "  APP ícon ").map(\.title), ["App icon"])
        XCTAssertEqual(SettingsSearch.results(for: "kill switch").map(\.section), [.general])
        XCTAssertEqual(SettingsSearch.results(for: "socks5").map(\.section), [.advanced])
        XCTAssertEqual(SettingsSearch.results(for: "routing").first?.section, .tunnel)
        XCTAssertEqual(SettingsSearch.results(for: "tunnel").first?.section, .tunnel)
    }

    func testAllWordsMustMatchOneSetting() {
        XCTAssertEqual(SettingsSearch.results(for: "automatic login").map(\.title), ["Launch at login"])
        XCTAssertTrue(SettingsSearch.results(for: "login firewall").isEmpty)
        XCTAssertTrue(SettingsSearch.results(for: "nonexistent setting").isEmpty)
    }

    func testNestedPagesHaveDirectDestinationsAndNoDuplicateResults() {
        let logs = SettingsSearch.results(for: "logs")
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.section, .logs)
        XCTAssertEqual(logs.first?.subtitle, "Nerd Shit")
        XCTAssertEqual(SettingsSearch.results(for: "geodata").first?.section, .tunnel)
    }
}
