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

    func testRoutingToolbarTogglesRoutingAndPreservesAssignmentsWhilePickersAreHidden() async throws {
        let fixture = try Fixture(withPortals: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let window = fixture.window
        let assignments = model.tunnelAssignments
        fixture.navigation.value.select(.tunnel)
        await awaitUIUpdate("Routing toolbar is visible") {
            window.toolbar.map { self.isVisible("routing.toggle", in: $0) } == true
        }
        let toolbar = try XCTUnwrap(window.toolbar)
        let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "routing.toggle" })
        let view = try XCTUnwrap(item.view)
        let frame = view.frame
        XCTAssertFalse(model.isSplitTunnelEnabled)
        try click(in: window, at: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        await awaitUIUpdate("Routing turns on") { model.isSplitTunnelEnabled }
        XCTAssertEqual(view.frame, frame, "On and Off use the same toolbar bounds")

        fixture.navigation.value.select(.portals)
        await awaitUIUpdate("Assignments are visible for both owners") {
            self.routingPickers(in: window).count == 2
                && (!toolbar.items.contains { $0 === item } || view.frame.width <= 1)
        }
        XCTAssertEqual(model.tunnelAssignments, assignments)
        fixture.navigation.value.select(.tunnel)
        await awaitUIUpdate("Routing control is restored") {
            self.isVisible("routing.toggle", in: toolbar)
                && (toolbar.items.first { $0.itemIdentifier.rawValue == "routing.toggle" }?.view?.frame.width ?? 0) > 1
        }
        let restoredView = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "routing.toggle" }?.view)
        try click(in: window, at: restoredView.convert(NSPoint(x: restoredView.bounds.midX, y: restoredView.bounds.midY), to: nil))
        await awaitUIUpdate("Routing turns off") { !model.isSplitTunnelEnabled }
        fixture.navigation.value.select(.portals)
        await awaitUIUpdate("Disabled routing hides its assignment controls") {
            self.routingPickers(in: window).isEmpty
        }
        XCTAssertEqual(model.tunnelAssignments, assignments, "Hiding assignments must not reset them")
    }

    func testProfileNameEditingAndDefaultRouteKeepLayoutStable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = fixture.window
        let model = fixture.model
        fixture.navigation.value.select(.tunnel)
        await awaitUIUpdate("The routing editor is laid out") {
            self.descendants(window.contentView!).contains { ($0 as? NSTextField)?.accessibilityLabel() == "Profile name" }
        }
        let field = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Profile name" })
        let route = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSSegmentedControl }
            .first { $0.label(forSegment: 0) == "Proxy" })
        let original = model.selectedSplitTunnelProfile!.name
        for width in [761.0, 1000.0, 1160.0] {
            window.setContentSize(NSSize(width: width, height: 760))
            await awaitUIUpdate("Resized routing page settles")
            let nameFrame = field.convert(field.bounds, to: nil)
            let routeFrame = route.convert(route.bounds, to: nil)
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.selectAll(nil)
            editor.insertText("A much longer name that must stay on one line while editing", replacementRange: editor.selectedRange())
            await awaitUIUpdate("The name draft is rendered")
            XCTAssertEqual(field.convert(field.bounds, to: nil), nameFrame)
            XCTAssertEqual(route.convert(route.bounds, to: nil), routeFrame)
            try key("\u{1b}", code: 53, in: window)
            await awaitUIUpdate("Escape restores the name")
            XCTAssertEqual(model.selectedSplitTunnelProfile?.name, original)
            XCTAssertEqual(field.stringValue, original)
            XCTAssertEqual(field.convert(field.bounds, to: nil), nameFrame)
            XCTAssertEqual(route.convert(route.bounds, to: nil), routeFrame)
            for action in [SplitTunnelRuleAction.direct, .proxy] {
                model.setSplitTunnelDefaultAction(action)
                await awaitUIUpdate("The default route description changes")
                XCTAssertEqual(route.convert(route.bounds, to: nil), routeFrame,
                               "Changing description must not resize or shift its row")
            }
        }
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Renamed", replacementRange: editor.selectedRange())
        try key("\r", code: 36, in: window)
        await awaitUIUpdate("Return saves the profile name") { model.selectedSplitTunnelProfile?.name == "Renamed" }
        XCTAssertTrue(window.makeFirstResponder(field))
        let secondEdit = try XCTUnwrap(field.currentEditor() as? NSTextView)
        secondEdit.selectAll(nil)
        secondEdit.insertText("Saved on blur", replacementRange: secondEdit.selectedRange())
        window.makeFirstResponder(nil)
        await awaitUIUpdate("Leaving the field saves the profile name") {
            model.selectedSplitTunnelProfile?.name == "Saved on blur"
        }
    }

    func testToolbarCreatesProfileWithoutSheetAndFocusesItsName() async throws {
        let fixture = try Fixture(withPortals: true)
        defer { fixture.cleanUp() }
        let window = fixture.window
        let model = fixture.model
        let assignments = model.tunnelAssignments
        fixture.navigation.value.select(.tunnel)
        await awaitUIUpdate("Profile menu and routing switch fit in the toolbar") {
            guard let toolbar = window.toolbar else { return false }
            return self.isVisible("routing.profile", in: toolbar) && self.isVisible("routing.toggle", in: toolbar)
        }
        let menu = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "routing.profile" }?.view)
        let frame = menu.frame
        let existingWindows = Set(NSApp.windows.map(\.windowNumber))
        try click(in: window, at: menu.convert(NSPoint(x: menu.bounds.midX, y: menu.bounds.midY), to: nil))
        await awaitUIUpdate("Clicking the profile opens the manager directly") {
            NSApp.windows.contains { !existingWindows.contains($0.windowNumber) && $0.isVisible && $0.frame.height > 100 }
        }
        let library = try XCTUnwrap(NSApp.windows.first { !existingWindows.contains($0.windowNumber) && $0.isVisible })
        let commandN = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: library.windowNumber, context: nil, characters: "n",
            charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45))
        var created = false
        await awaitUIUpdate("The manager's New profile button is available") {
            if !created { created = library.performKeyEquivalent(with: commandN) }
            return created
        }
        await awaitUIUpdate("The new profile name is ready for typing") {
            model.selectedSplitTunnelProfile?.name == "новый профиль"
                && (window.firstResponder as? NSTextView)?.string == "новый профиль"
        }
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(model.personalTunnelProfiles.count, 2)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("Work", replacementRange: editor.selectedRange())
        try key("\r", code: 36, in: window)
        await awaitUIUpdate("The typed name is saved") { model.selectedSplitTunnelProfile?.name == "Work" }
        XCTAssertEqual(menu.frame, frame)
        XCTAssertFalse(library.isVisible, "Creating a profile closes the manager")
        XCTAssertEqual(model.tunnelAssignments, assignments)
        XCTAssertEqual(menu.frame, frame)
    }

    private func routingPickers(in window: NSWindow) -> [NSPopUpButton] {
        descendants(window.contentView!).compactMap { $0 as? NSPopUpButton }.filter { $0.title == "Default" }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func click(in window: NSWindow, at point: NSPoint) throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        window.sendEvent(try event(.leftMouseDown))
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(pending)
        }
    }

    private func key(_ text: String, code: UInt16, in window: NSWindow) throws {
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)))
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
