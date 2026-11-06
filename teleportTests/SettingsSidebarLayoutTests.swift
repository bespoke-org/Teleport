import AppKit
import SwiftUI
import XCTest

@MainActor
final class SettingsSidebarLayoutTests: XCTestCase {
    func testSidebarClickAndArrowKeysSelectPages() async throws {
        _ = NSApplication.shared
        let model = SidebarModel()
        let host = NSHostingController(rootView: SidebarFixture(model: model))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        let split = try XCTUnwrap(splitController(in: host.view))
        let sidebar = try XCTUnwrap(split.splitViewItems.first { $0.behavior == .sidebar })
        let view = sidebar.viewController.view
        let search = try XCTUnwrap(searchField(in: view))
        XCTAssertNil(search.currentEditor(), "Opening Settings must not start editing the search field")
        // Click Portals in the real sidebar, including its focus handling.
        let y: CGFloat = 8 + 28 + 16 + 32 + 16
        let point = view.convert(NSPoint(x: 80, y: view.isFlipped ? y : view.bounds.height - y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(
                try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: 1, pressure: 1
                    )))
        }
        XCTAssertEqual(model.navigation.section, .portals, "Page selection must happen immediately on mouse release")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.navigation.section, .portals)
        let arrowDown = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                isARepeat: false, keyCode: 125
            ))
        window.sendEvent(arrowDown)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.navigation.section, .splitTunneling)
        // There must be no native table selection layer behind our gray buttons.
        XCTAssertNil(tableView(in: view))

        let searchY: CGFloat = 8 + 14
        let searchPoint = view.convert(NSPoint(x: 80, y: view.isFlipped ? searchY : view.bounds.height - searchY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(
                try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: type, location: searchPoint, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: 1, pressure: 1
                    )))
        }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("socks5", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.navigation.section, .splitTunneling, "Typing should not change pages")
        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
            ))
        window.sendEvent(escape)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "", "Escape clears the native text editor and restores sidebar rows")
        editor.insertText("socks5", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        let enter = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
            ))
        window.sendEvent(enter)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.navigation.section, .advanced, "Return opens the matching settings page")

        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(
                try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: type, location: searchPoint, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: 1, pressure: 1
                    )))
        }
        let searchEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        searchEditor.selectAll(nil)
        searchEditor.insertText("proxy", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        window.sendEvent(arrowDown)
        try await Task.sleep(for: .milliseconds(100))
        window.sendEvent(arrowDown)
        try await Task.sleep(for: .milliseconds(100))
        window.sendEvent(enter)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.navigation.section, .splitTunneling, "Down enters results and advances to the second match")
    }

    func testVisitedPagesAreReusedAndNestedPagesAreReleased() async throws {
        _ = NSApplication.shared
        let model = SidebarModel()
        var appearances: [SettingsSection: Int] = [:]
        var disappearances: [SettingsSection: Int] = [:]
        let host = NSHostingController(rootView: PageFixture(model: model, appeared: {
            appearances[$0, default: 0] += 1
        }, disappeared: {
            disappearances[$0, default: 0] += 1
        }))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        for section: SettingsSection in [.portals, .general, .advanced, .logs, .general, .logs, .portals] {
            model.navigation.select(section)
            try await Task.sleep(for: .milliseconds(100))
        }
        for section: SettingsSection in [.general, .portals, .advanced] {
            XCTAssertEqual(appearances[section], 1, "Returning to a page must reuse its controls")
            XCTAssertNil(disappearances[section])
        }
        XCTAssertEqual(appearances[.logs], 2)
        XCTAssertEqual(disappearances[.logs], 2, "Leaving Logs must end its page-scoped work")
    }

    func testScrollViewportExtendsBehindSearchBar() async throws {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: SidebarFixture())
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        let split = try XCTUnwrap(splitController(in: host.view))
        let sidebar = try XCTUnwrap(split.splitViewItems.first { $0.behavior == .sidebar })
        let view = sidebar.viewController.view
        let scroll = try XCTUnwrap(scrollView(in: view))
        let clipFrame = view.convert(scroll.contentView.bounds, from: scroll.contentView)
        let topInset = view.isFlipped ? clipFrame.minY : view.bounds.maxY - clipFrame.maxY
        XCTAssertLessThanOrEqual(topInset, 1, "Rows must scroll behind the search bar, not clip below it")
    }

    func testSidebarTogglesKeepWindowFrameAtMinimumAndLargerWidths() async throws {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: SidebarFixture())
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.styleMask.insert(.resizable)
        // Match the Settings window's minimum-size guard, including while collapsed.
        let observation = window.observe(\.contentMinSize, options: [.initial, .new]) { window, _ in
            let size = window.contentMinSize
            let minimum = SettingsSidebarLayout.minimumContentSize
            if size.width < minimum.width || size.height < minimum.height {
                window.contentMinSize = NSSize(width: max(minimum.width, size.width), height: max(minimum.height, size.height))
            }
        }
        defer {
            observation.invalidate()
            window.close()
        }
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        let split = try XCTUnwrap(splitController(in: host.view))
        let sidebar = try XCTUnwrap(split.splitViewItems.first { $0.behavior == .sidebar })
        XCTAssertEqual(sidebar.collapseBehavior, .useConstraints)

        for width in [SettingsSidebarLayout.minimumContentSize.width, 900, 1100] {
            window.setContentSize(NSSize(width: width, height: 600))
            try await Task.sleep(for: .milliseconds(100))
            let expectedFrame = window.frame
            for collapsed in [true, false, true, false] {
                split.toggleSidebar(nil)
                var firstChangedFrame: NSRect?
                for _ in 0..<25 {
                    try await Task.sleep(for: .milliseconds(20))
                    if firstChangedFrame == nil, window.frame != expectedFrame {
                        firstChangedFrame = window.frame
                    }
                }
                XCTAssertNil(
                    firstChangedFrame,
                    "Window moved or resized while toggling at width \(width), collapsed=\(collapsed): expected \(expectedFrame), first change \(String(describing: firstChangedFrame)), final \(window.frame), minimum \(window.contentMinSize), divider \(split.splitView.dividerThickness)"
                )
                XCTAssertEqual(sidebar.isCollapsed, collapsed)
                if !collapsed {
                    XCTAssertEqual(sidebar.viewController.view.frame.width, SettingsSidebarLayout.sidebarWidth, accuracy: 1)
                }
            }
        }
    }

    private func splitController(in view: NSView) -> NSSplitViewController? {
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
            return controller
        }
        return view.subviews.compactMap { splitController(in: $0) }.first
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap { scrollView(in: $0) }.first
    }

    private func searchField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.accessibilityIdentifier() == "settingsSearch" { return field }
        return view.subviews.compactMap { searchField(in: $0) }.first
    }

    private func tableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.compactMap { tableView(in: $0) }.first
    }
}

private struct SidebarFixture: View {
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State var model = SidebarModel()

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            SettingsSidebar(navigation: $model.navigation)
        } detail: {
            Form {
                Section("Connection") {
                    Text("Mode")
                    Text("Protect traffic")
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: SettingsSidebarLayout.minimumDetailWidth)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minHeight: SettingsSidebarLayout.minimumContentSize.height)
    }
}

@MainActor
@Observable
private final class SidebarModel {
    var navigation = SettingsNavigation()
}

private struct PageFixture: View {
    let model: SidebarModel
    let appeared: (SettingsSection) -> Void
    let disappeared: (SettingsSection) -> Void

    var body: some View {
        SettingsPages(selection: model.navigation.section) { section in
            Text(section.title)
                .onAppear { appeared(section) }
                .onDisappear { disappeared(section) }
        }
        .frame(width: 400, height: 300)
    }
}
