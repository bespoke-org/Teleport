import Foundation
import XCTest

final class TunnelProfileTests: XCTestCase {
    func testSubscriptionsResolveIndependentlyAndPersonalProfilesCanBeShared() {
        let first = UUID(), second = UUID(), manual = UUID()
        let personal = SplitTunnelProfile(name: "Shared", geodataSources: .init(geositeURLString: "https://personal.example/sites.dat"))
        let provider = SplitTunnelProfile(name: "Provider", subscriptionSourceID: first,
                                          geodataSources: .init(geositeURLString: "https://provider.example/sites.dat"))
        let profiles = [personal, provider]
        let assignments = [TunnelProfileAssignment(target: .subscription(second), personalProfileID: personal.id),
                           TunnelProfileAssignment(target: .connection(manual), personalProfileID: personal.id)]
        XCTAssertEqual(TunnelProfileResolver.profile(for: .subscription(first), profiles: profiles, assignments: assignments), provider)
        XCTAssertEqual(TunnelProfileResolver.profile(for: .subscription(second), profiles: profiles, assignments: assignments), personal)
        XCTAssertEqual(TunnelProfileResolver.profile(for: .connection(manual), profiles: profiles, assignments: assignments), personal)
    }

    func testExplicitPersonalChoiceOverridesOnlyItsSubscription() {
        let source = UUID(), other = UUID()
        let personal = SplitTunnelProfile(name: "Mine")
        let provider = SplitTunnelProfile(name: "Provider", subscriptionSourceID: source)
        let otherProvider = SplitTunnelProfile(name: "Other", subscriptionSourceID: other)
        let assignments = [TunnelProfileAssignment(target: .subscription(source), personalProfileID: personal.id)]
        let profiles = [personal, provider, otherProvider]
        XCTAssertEqual(TunnelProfileResolver.profile(for: .subscription(source), profiles: profiles, assignments: assignments)?.id, personal.id)
        XCTAssertEqual(TunnelProfileResolver.profile(for: .subscription(other), profiles: profiles, assignments: assignments)?.id, otherProvider.id)
    }

    func testAssignmentsAndProfileSourcesPersistTogether() throws {
        let profile = SplitTunnelProfile(name: "Mine", geodataSources: .init(geoipURLString: "https://provider.example/geoip.dat"))
        let assignment = TunnelProfileAssignment(target: .connection(UUID()), personalProfileID: profile.id)
        let snapshot = AppSnapshot(savedConnections: [], selectedConnectionID: nil, proxyEndpoint: .default,
                                   splitTunnelProfiles: [profile], tunnelAssignments: [assignment])
        XCTAssertEqual(try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testLegacyGlobalProfileRemainsAssignedToExistingSubscriptions() throws {
        let source = UUID(), profile = UUID()
        let json = """
        {"subscriptionSources":[{"id":"\(source)","urlString":"https://example.com/sub","title":"Provider","savedAt":0}],
         "splitTunnelProfiles":[{"id":"\(profile)","name":"Mine","rules":[]}],
         "selectedSplitTunnelProfileID":"\(profile)","isSplitTunnelEnabled":true,
         "geodataSettings":{"geositeURLString":"https://example.com/geosite.dat"}}
        """
        let snapshot = try JSONDecoder().decode(AppSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.tunnelAssignments, [.init(target: .subscription(source), personalProfileID: profile)])
        XCTAssertEqual(snapshot.splitTunnelProfiles[0].geodataSources?.geositeURLString, "https://example.com/geosite.dat")
        XCTAssertTrue(snapshot.splitTunnelProfiles[0].isRoutingEnabled)
    }

    func testSavingAnInactiveProfileDoesNotCopyAnotherProfilesActiveSources() throws {
        let profile = SplitTunnelProfile(name: "Bundled data")
        let snapshot = AppSnapshot(savedConnections: [], selectedConnectionID: nil, proxyEndpoint: .default,
            splitTunnelProfiles: [profile], geodataSettings: .init(geositeURLString: "https://other.example/sites.dat"),
            tunnelAssignments: [])
        let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertNil(restored.splitTunnelProfiles[0].geodataSources)
    }

    func testLegacyProviderSelectionBecomesASavedPersonalCopyForExistingTargets() throws {
        let source = UUID(), profile = UUID()
        let json = """
        {"subscriptionSources":[{"id":"\(source)","urlString":"https://example.com/sub","title":"Provider","savedAt":0}],
         "splitTunnelProfiles":[{"id":"\(profile)","name":"Provider","rules":[],"subscriptionSourceID":"\(source)"}],
         "selectedSplitTunnelProfileID":"\(profile)","isSplitTunnelEnabled":false,
         "geodataSettings":{"geoipURLString":"https://example.com/geoip.dat"}}
        """
        let restored = try JSONDecoder().decode(AppSnapshot.self, from: Data(json.utf8))
        let personal = try XCTUnwrap(restored.splitTunnelProfiles.first { $0.subscriptionSourceID == nil })
        XCTAssertFalse(personal.isRoutingEnabled)
        XCTAssertEqual(personal.geodataSources?.geoipURLString, "https://example.com/geoip.dat")
        XCTAssertEqual(restored.tunnelAssignments.first?.personalProfileID, personal.id)
        XCTAssertEqual(restored.splitTunnelProfiles.first { $0.id == profile }?.subscriptionSourceID, source)
        XCTAssertEqual(try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(restored)), restored)
    }
}
