import AppKit
import SwiftUI
import XCTest

@MainActor
final class SettingsToolbarLayoutTests: XCTestCase {
    func testPortalFormsOnlyDisplayErrorsFromTheirOwnActions() async throws {
        let provider = PendingProvider()
        let fixture = try Fixture(withPortals: true, systemProxyProvider: provider)
        defer { fixture.cleanUp() }
        await awaitUIUpdate("Initial provider is ready") { fixture.model.canChangeSelection }
        fixture.model.selectConnectionMode(.systemProxy)
        let failure = ConnectionFailure(summary: "Could not verify the connection through this portal.", details: "Probe failed")

        for editing in [false, true] {
            fixture.model.clearError()
            let connection = try XCTUnwrap(fixture.model.savedConnections.first)
            func makeWindow() -> NSWindow {
                let content = editing
                    ? AnyView(EditConnectionSheet(viewModel: fixture.model, connection: connection))
                    : AnyView(AddConnectionSheet(viewModel: fixture.model))
                let window = NSWindow(contentViewController: NSHostingController(rootView: content))
                window.isReleasedWhenClosed = false
                window.makeKeyAndOrderFront(nil)
                return window
            }
            let cleanWindow = makeWindow()
            await awaitUIUpdate("Clean portal form is ready")
            let cleanHeight = try XCTUnwrap(cleanWindow.contentView).fittingSize.height
            cleanWindow.close()

            provider.continuation.yield(.failed(failure))
            await awaitUIUpdate("Connection failure is stored") { fixture.model.lastError == failure.summary }
            let window = makeWindow()
            defer { window.close() }
            await awaitUIUpdate("Portal form opens after a connection failure")
            let root = try XCTUnwrap(window.contentView)
            XCTAssertEqual(root.fittingSize.height, cleanHeight,
                           "Opening a form must not add a row for an earlier connection error")
            XCTAssertEqual(fixture.model.lastError, failure.summary)

            if editing {
                let configuration = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }
                    .first { $0.stringValue == connection.configuration.rawLink })
                XCTAssertTrue(window.makeFirstResponder(configuration))
            }
            let field = try XCTUnwrap(window.firstResponder as? NSTextView)
            XCTAssertTrue(window.makeFirstResponder(field))
            field.selectAll(nil)
            field.insertText("not-a-portal", replacementRange: field.selectedRange())
            await awaitUIUpdate("Invalid draft is entered")
            XCTAssertEqual(fixture.model.lastError, failure.summary, "Typing must preserve connection diagnostics")
            let draftHeight = root.fittingSize.height
            let submit = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            XCTAssertTrue(window.performKeyEquivalent(with: submit))
            await awaitUIUpdate("Validation adds an error row") {
                fixture.model.lastError != nil && fixture.model.lastError != failure.summary
                    && root.fittingSize.height > draftHeight
            }
            let validationHeight = root.fittingSize.height
            provider.continuation.yield(.failed(ConnectionFailure(summary: String(repeating: "Background failure. ", count: 30), details: nil)))
            await awaitUIUpdate("A new connection failure arrives") { fixture.model.lastError?.hasPrefix("Background failure.") == true }
            XCTAssertEqual(root.fittingSize.height, validationHeight,
                           "Background failures must not replace form validation")
            field.insertText("x", replacementRange: field.selectedRange())
            await awaitUIUpdate("Editing removes the validation row") { root.fittingSize.height == draftHeight }
            XCTAssertTrue(fixture.model.lastError?.hasPrefix("Background failure.") == true)
        }
    }

    func testModeSwitchKeepsAppearanceAndLayoutStableWhileProviderStarts() async throws {
        let provider = PendingProvider()
        let fixture = try Fixture(systemProxyProvider: provider)
        defer { fixture.cleanUp() }
        fixture.navigation.value.select(.general)
        await awaitUIUpdate("General settings are ready") { fixture.model.canChangeSelection }
        let controls = descendants(fixture.window.contentView!).compactMap { $0 as? NSSegmentedControl }
        let mode = try XCTUnwrap(controls.first { $0.label(forSegment: 0) == "System Proxy" })
        let order = try XCTUnwrap(controls.first { $0.segmentCount == 3 })
        let originalFrame = order.convert(order.bounds, to: nil)
        let originalAlpha = mode.alphaValue

        fixture.model.selectConnectionMode(.systemProxy)
        await awaitUIUpdate("The new mode is displayed while its provider starts") { mode.selectedSegment == 0 }
        XCTAssertFalse(fixture.model.canChangeSelection)
        XCTAssertTrue(mode.isEnabled, "Provider startup must not flash the native disabled appearance")
        XCTAssertEqual(mode.alphaValue, originalAlpha, "Provider startup must not dim the picker")
        XCTAssertEqual(order.convert(order.bounds, to: nil), originalFrame,
                       "Waiting for the provider must not move Menu bar and Dock")
        XCTAssertFalse(mode.isAccessibilityEnabled())
        let lockedPoint = NSPoint(x: mode.frame.midX, y: mode.frame.midY)
        XCTAssertNil(mode.hitTest(lockedPoint), "Provider startup must block pointer input without changing the glass")
        let tunPoint = mode.convert(NSPoint(x: mode.bounds.width * 0.75, y: mode.bounds.midY), to: nil)
        try click(in: fixture.window, at: tunPoint)
        XCTAssertEqual(fixture.model.connectionMode, .systemProxy)
        XCTAssertEqual(mode.selectedSegment, 0)
        mode.selectedSegment = 1
        mode.sendAction(try XCTUnwrap(mode.action), to: mode.target)
        XCTAssertEqual(fixture.model.connectionMode, .systemProxy, "Input must stay blocked during provider startup")
        XCTAssertEqual(mode.selectedSegment, 0, "Rejected input must restore the displayed selection")
        XCTAssertNil(fixture.model.lastError)

        provider.continuation.yield(.preparing)
        await awaitUIUpdate("The provider is checking for an existing session") {
            fixture.model.connectionState == .preparing
        }
        XCTAssertFalse(fixture.model.canChangeSelection)
        XCTAssertTrue(mode.isEnabled, "Resolving a provider must not look like starting a connection")
        XCTAssertEqual(mode.alphaValue, originalAlpha, "The provider's initial preparing state must not dim the picker")

        provider.continuation.yield(.idle)
        await awaitUIUpdate("The new provider is ready") { fixture.model.canChangeSelection }
        XCTAssertEqual(order.convert(order.bounds, to: nil), originalFrame)
        XCTAssertTrue(mode.isAccessibilityEnabled())
        provider.continuation.yield(.preparing)
        await awaitUIUpdate("Preparing a real connection disables and dims the picker") {
            fixture.model.connectionState == .preparing && !mode.isEnabled && mode.alphaValue < originalAlpha
        }
        provider.continuation.yield(.connecting)
        await awaitUIUpdate("An active connection disables and dims the picker") {
            fixture.model.connectionState == .connecting && !mode.isEnabled && mode.alphaValue < originalAlpha
        }
        XCTAssertTrue(fixture.model.hasActiveConnectionSession)
        provider.continuation.yield(.idle)
        await awaitUIUpdate("Disconnecting restores the picker") { mode.isEnabled && mode.alphaValue == originalAlpha }
        fixture.model.selectConnectionMode(.tun)
        await awaitUIUpdate("TUN is ready again") { fixture.model.canChangeSelection && mode.isEnabled }
        XCTAssertEqual(order.convert(order.bounds, to: nil), originalFrame)
    }

    func testExpandedPortalSearchReleasesSpaceForLogsAndSurvivesNavigation() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Shared glass toolbar is macOS 26+") }
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let window = fixture.window
        await awaitUIUpdate("Portals toolbar is attached") {
            window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "settings.pageActions" } == true
        }
        let toolbar = try XCTUnwrap(window.toolbar)
        let portals = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "settings.pageActions" })
        func assertTrailingInset(file: StaticString = #filePath, line: UInt = #line) throws {
            let view = try XCTUnwrap(portals.view, file: file, line: line)
            let inset = window.frame.width - view.convert(view.bounds, to: nil).maxX
            XCTAssertGreaterThanOrEqual(inset, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(inset, 20, "Inactive toolbar items must not reserve trailing space", file: file, line: line)
        }
        try assertTrailingInset()
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
        XCTAssertTrue(isVisible("settings.pageActions", in: toolbar), "The expanded search, Add and Connect must stay visible")
        try assertTrailingInset()
        let field = try XCTUnwrap(searchField(in: window))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("Paris")
        await awaitUIUpdate("Search text reaches its binding") { field.stringValue == "Paris" }

        fixture.navigation.value.select(.logs)
        await awaitUIUpdate("Logs reclaim the hidden Portals toolbar space") {
            self.isVisible("logs.find", in: toolbar) && self.isVisible("logs.refresh", in: toolbar)
                && self.isVisible("logs.actions", in: toolbar) && (portals.view?.frame.width ?? .infinity) <= 9
        }
        XCTAssertNil(field.currentEditor(), "Leaving Portals releases search focus")
        XCTAssertTrue(portals === toolbar.items.first { $0.itemIdentifier.rawValue == "settings.pageActions" },
                      "Keep the toolbar item mounted so its search state survives navigation")

        fixture.navigation.value.select(.portals)
        await awaitUIUpdate("Returning restores the expanded search and its query") {
            self.isVisible("settings.pageActions", in: toolbar)
                && self.searchField(in: window)?.stringValue == "Paris"
                && (portals.view?.frame.width ?? 0) > 250
        }
        XCTAssertTrue(portals === toolbar.items.first { $0.itemIdentifier.rawValue == "settings.pageActions" })
        try assertTrailingInset()
        window.setContentSize(NSSize(width: 1160, height: SettingsSidebarLayout.minimumContentSize.height))
        await awaitUIUpdate("The resized toolbar settles")
        try assertTrailingInset()
    }

    func testPageSwitchKeepsTheSameNativeToolbarItemsMounted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await awaitUIUpdate("Toolbar is attached") { fixture.window.toolbar != nil }
        let toolbar = try XCTUnwrap(fixture.window.toolbar)
        let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "settings.pageActions" })
        let view = try XCTUnwrap(item.view)
        let visibleIDs = toolbar.visibleItems?.map(\.itemIdentifier)
        for section in [SettingsSection.tunnel, .general, .portals, .general, .tunnel, .portals] {
            fixture.navigation.value.select(section)
            await awaitUIUpdate("Toolbar switches to \(section)")
            XCTAssertEqual(toolbar.visibleItems?.map(\.itemIdentifier), visibleIDs,
                           "Page switches must not invoke AppKit's toolbar item show/hide transitions")
            XCTAssertTrue(item === toolbar.items.first { $0.itemIdentifier.rawValue == "settings.pageActions" })
            XCTAssertTrue(item.view === view, "Keep the same native host across pages")
            XCTAssertGreaterThan(view.bounds.height, 36, "Leave room for pressed glass to expand")
        }
    }

    func testErrorsDoNotAddToolbarItems() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await awaitUIUpdate("Settings toolbar is attached") { fixture.window.toolbar != nil }
        let toolbar = try XCTUnwrap(fixture.window.toolbar)
        let itemIDs = toolbar.items.map(\.itemIdentifier)
        XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier.rawValue == "settings.error" })

        XCTAssertFalse(fixture.model.addConnection(from: "not-a-portal"))
        XCTAssertNotNil(fixture.model.lastError)
        await awaitUIUpdate("Settings update after an error")
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier), itemIDs)
        fixture.model.clearError()
        await awaitUIUpdate("Settings update after clearing an error")
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier), itemIDs)
    }

    func testRoutingToolbarTogglesRoutingAndPreservesAssignmentsWhilePickersAreHidden() async throws {
        let fixture = try Fixture(withPortals: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let window = fixture.window
        let assignments = model.tunnelAssignments
        fixture.navigation.value.select(.tunnel)
        await awaitUIUpdate("Routing toolbar is visible") {
            window.toolbar.map { self.isVisible("settings.pageActions", in: $0) } == true
        }
        let toolbar = try XCTUnwrap(window.toolbar)
        let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "settings.pageActions" })
        let view = try XCTUnwrap(item.view)
        let frame = view.frame
        XCTAssertFalse(model.isSplitTunnelEnabled)
        try click(in: window, at: view.convert(NSPoint(x: view.bounds.maxX - 45, y: view.bounds.midY), to: nil))
        await awaitUIUpdate("Routing turns on") { model.isSplitTunnelEnabled }
        XCTAssertEqual(view.frame, frame, "On and Off use the same toolbar bounds")

        fixture.navigation.value.select(.portals)
        await awaitUIUpdate("Assignments are visible for both owners") {
            self.routingPickers(in: window).count == 2
                && view.frame.width < frame.width
        }
        XCTAssertEqual(model.tunnelAssignments, assignments)
        fixture.navigation.value.select(.tunnel)
        await awaitUIUpdate("Routing control is restored") {
            self.isVisible("settings.pageActions", in: toolbar)
                && (toolbar.items.first { $0.itemIdentifier.rawValue == "settings.pageActions" }?.view?.frame.width ?? 0) > 1
        }
        let restoredView = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "settings.pageActions" }?.view)
        try click(in: window, at: restoredView.convert(NSPoint(x: restoredView.bounds.maxX - 45, y: restoredView.bounds.midY), to: nil))
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
            return self.isVisible("settings.pageActions", in: toolbar)
        }
        let menu = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "settings.pageActions" }?.view)
        let frame = menu.frame
        let existingWindows = Set(NSApp.windows.map(\.windowNumber))
        try click(in: window, at: menu.convert(NSPoint(x: 94, y: menu.bounds.midY), to: nil))
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

        init(withPortals: Bool = false, systemProxyProvider: (any ConnectionProvider)? = nil) throws {
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
                connectionProviderFactory: ConnectionProviderFactory(systemProxyProvider: { systemProxyProvider ?? provider }, tunProvider: { provider }),
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

    private final class PendingProvider: ConnectionProvider, Sendable {
        let stream: AsyncStream<ConnectionState>
        let continuation: AsyncStream<ConnectionState>.Continuation

        init() {
            (stream, continuation) = AsyncStream.makeStream(of: ConnectionState.self)
        }

        func currentState() async -> ConnectionState { .idle }
        func stateUpdates() -> AsyncStream<ConnectionState> { stream }
        func connect(_ request: ConnectionRequest) async throws { throw CancellationError() }
        func disconnect() async throws {}
    }
}
