import AppKit
import SwiftUI
import XCTest

@MainActor
final class SettingsToolbarLayoutTests: XCTestCase {
    func testExpandedPortalSearchReleasesSpaceForLogsAndSurvivesNavigation() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Shared glass toolbar is macOS 26+") }
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = fixture.window
        await awaitUIUpdate("Portals toolbar is attached") {
            window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "portals.actions" } == true
        }
        let toolbar = try XCTUnwrap(window.toolbar)
        let portals = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "portals.actions" })
        XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier.rawValue == "settings.error" },
                       "An empty error item must not reserve space beside the expanding search")

        let commandF = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f",
            charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        var opened = false
        await awaitUIUpdate("Search expands and receives focus") {
            if !opened { opened = window.performKeyEquivalent(with: commandF) }
            return opened && self.searchField(in: window)?.currentEditor() != nil
                && (portals.view?.frame.width ?? 0) > 250
        }
        XCTAssertTrue(isVisible("portals.actions", in: toolbar), "The expanded search, Add and Connect must stay visible")
        let field = try XCTUnwrap(searchField(in: window))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("Paris")
        await awaitUIUpdate("Search text reaches its binding") { field.stringValue == "Paris" }

        fixture.navigation.value.select(.logs)
        await awaitUIUpdate("Logs reclaim the hidden Portals toolbar space") {
            self.isVisible("logs.find", in: toolbar) && self.isVisible("logs.refresh", in: toolbar)
                && self.isVisible("logs.actions", in: toolbar) && (portals.view?.frame.width ?? .infinity) <= 1
        }
        XCTAssertNil(field.currentEditor(), "Leaving Portals releases search focus")
        XCTAssertTrue(portals === toolbar.items.first { $0.itemIdentifier.rawValue == "portals.actions" },
                      "Keep the toolbar item mounted so its search state survives navigation")

        fixture.navigation.value.select(.portals)
        await awaitUIUpdate("Returning restores the expanded search and its query") {
            self.isVisible("portals.actions", in: toolbar)
                && self.searchField(in: window)?.stringValue == "Paris"
                && (portals.view?.frame.width ?? 0) > 250
        }
        XCTAssertTrue(portals === toolbar.items.first { $0.itemIdentifier.rawValue == "portals.actions" })
    }

    func testErrorToolbarItemExistsOnlyWhileAnErrorIsPresent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await awaitUIUpdate("Settings toolbar is attached") { fixture.window.toolbar != nil }
        let toolbar = try XCTUnwrap(fixture.window.toolbar)
        XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier.rawValue == "settings.error" })

        XCTAssertFalse(fixture.model.addConnection(from: "not-a-portal"))
        await awaitUIUpdate("An error adds its native toolbar item") {
            toolbar.items.contains { $0.itemIdentifier.rawValue == "settings.error" }
        }
        fixture.model.clearError()
        await awaitUIUpdate("Clearing the error removes its native toolbar item") {
            !toolbar.items.contains { $0.itemIdentifier.rawValue == "settings.error" }
        }
    }

    private func isVisible(_ id: String, in toolbar: NSToolbar) -> Bool {
        toolbar.visibleItems?.contains { $0.itemIdentifier.rawValue == id } == true
    }

    private func searchField(in window: NSWindow) -> NSSearchField? {
        func find(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField, field.placeholderString == "Search portals" { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let root = window.contentView?.superview else { return nil }
        return find(root)
    }

    @MainActor
    private final class Navigation: ObservableObject {
        @Published var value = SettingsNavigation()
        init() { value.select(.portals) }
    }

    private struct Content: View {
        let model: AppViewModel
        @ObservedObject var navigation: Navigation
        var body: some View { SettingsView(viewModel: model, navigation: $navigation.value) }
    }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("teleport-toolbar-\(UUID())")
        let navigation = Navigation()
        let model: AppViewModel
        let store: ConfigurationStore
        let window: NSWindow

        init(withPortals: Bool = false) throws {
            _ = NSApplication.shared
            let files = IsolatedFileManager(root: root)
            let log = TeleportLog(directoryURL: root, fileName: "test.log")
            store = ConfigurationStore(fileManager: files, keychainService: "dev.x.teleport.toolbar-tests",
                                       keychainAccount: UUID().uuidString, log: log)
            let connection = SavedConnection(id: UUID(), configuration: try ConnectionLinkParser().parse(
                "vless://123e4567-e89b-12d3-a456-426614174000@server.invalid:443?security=tls#Manual"
            ), savedAt: Date())
            let source = SubscriptionSource(id: UUID(), urlString: "https://provider.invalid/sub", title: "Provider",
                                            savedAt: Date(), lastRefreshedAt: Date())
            try store.save(AppSnapshot(savedConnections: withPortals ? [connection] : [],
                                       subscriptionSources: withPortals ? [source] : [],
                                       selectedConnectionID: withPortals ? connection.id : nil, proxyEndpoint: .default))
            let provider = IdleProvider()
            model = AppViewModel(parser: ConnectionLinkParser(), store: store,
                connectionProviderFactory: ConnectionProviderFactory(systemProxyProvider: { provider }, tunProvider: { provider }),
                leakGuard: LeakGuardService(isEnabled: false, log: log),
                subscriptionClient: SubscriptionClient(loadResponse: { _ in throw URLError(.cancelled) }),
                healthProbeService: ConnectionHealthProbeService(),
                systemProxyService: SystemProxyService(fileManager: files, log: log),
                currentUplink: { nil }, log: log)
            window = NSWindow(contentViewController: NSHostingController(rootView: Content(model: model, navigation: navigation)))
            window.isReleasedWhenClosed = false
            window.styleMask.insert(.resizable)
            window.setContentSize(SettingsSidebarLayout.minimumContentSize)
            window.makeKeyAndOrderFront(nil)
        }

        func cleanUp() {
            window.close()
            store.deleteStoredDataForTesting()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class IsolatedFileManager: FileManager {
        let root: URL
        init(root: URL) { self.root = root; super.init() }
        override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
            directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
        }
    }

    private final class IdleProvider: ConnectionProvider, @unchecked Sendable {
        func currentState() async -> ConnectionState { .idle }
        func stateUpdates() -> AsyncStream<ConnectionState> { AsyncStream { $0.yield(.idle); $0.finish() } }
        func connect(_ request: ConnectionRequest) async throws { throw CancellationError() }
        func disconnect() async throws {}
    }
}
