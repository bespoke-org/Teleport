import XCTest

@MainActor
final class PortalsSettingsTests: XCTestCase {
    func testSearchMatchesNameHostAndProtocolWithoutMatchingCredentials() throws {
        let configuration = try ConnectionLinkParser().parse(
            "vless://123e4567-e89b-12d3-a456-426614174000@vpn.example.com:443?security=tls&type=tcp#Paris"
        )
        let connection = SavedConnection(id: UUID(), configuration: configuration, savedAt: Date(), customName: "Café Paris")
        var state = PortalsState()
        for query in ["PARIS", " cafe ", "vpn.example", "vless", " \n "] {
            state.query = query
            XCTAssertTrue(state.matches(connection), query)
        }
        for query in ["London", "123e4567-e89b-12d3-a456-426614174000"] {
            state.query = query
            XCTAssertFalse(state.matches(connection), query)
        }
    }

    func testSearchExpandsCollapsedGroupsWithoutChangingSavedExpansion() {
        let openID = UUID()
        let closedID = UUID()
        var state = PortalsState()
        state.toggle(openID)
        XCTAssertTrue(state.isExpanded(openID))
        XCTAssertFalse(state.isExpanded(closedID))

        state.query = "Paris"
        XCTAssertTrue(state.isExpanded(openID))
        XCTAssertTrue(state.isExpanded(closedID))
        state.query = ""
        XCTAssertTrue(state.isExpanded(openID))
        XCTAssertFalse(state.isExpanded(closedID))
        state.toggle(openID)
        XCTAssertFalse(state.isExpanded(openID))
    }

    func testSubscriptionSearchUsesDisplayNameWithoutSearchingPrivateURL() {
        let source = SubscriptionSource(id: UUID(), urlString: "https://example.com/private-token", title: "Europe", savedAt: Date())
        var state = PortalsState()
        state.query = " EUROPE "
        XCTAssertTrue(state.matches(source))
        state.query = "private-token"
        XCTAssertFalse(state.matches(source))
        state.query = ""
        XCTAssertFalse(state.matches(source))
    }
}
