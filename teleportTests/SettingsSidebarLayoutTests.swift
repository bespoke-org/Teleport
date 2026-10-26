import AppKit
import SwiftUI
import XCTest

@MainActor
final class SettingsSidebarLayoutTests: XCTestCase {
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
        defer { observation.invalidate(); window.close() }
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
                XCTAssertNil(firstChangedFrame, "Window moved or resized while toggling at width \(width), collapsed=\(collapsed): expected \(expectedFrame), first change \(String(describing: firstChangedFrame)), final \(window.frame), minimum \(window.contentMinSize), divider \(split.splitView.dividerThickness)")
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
}

private struct SidebarFixture: View {
    @State private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List { Text("General"); Text("Portals") }
                .listStyle(.sidebar)
                .frame(minWidth: SettingsSidebarLayout.sidebarWidth, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(SettingsSidebarLayout.sidebarWidth)
                .background(SettingsSidebarLayout())
        } detail: {
            Form { Section("Connection") { Text("Mode"); Text("Protect traffic") } }
                .formStyle(.grouped)
                .frame(minWidth: SettingsSidebarLayout.minimumDetailWidth)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minHeight: SettingsSidebarLayout.minimumContentSize.height)
    }
}
