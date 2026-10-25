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
            if size.width < 760 || size.height < 500 {
                window.contentMinSize = NSSize(width: max(760, size.width), height: max(500, size.height))
            }
        }
        defer { observation.invalidate(); window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        let split = try XCTUnwrap(splitController(in: host.view))
        let sidebar = try XCTUnwrap(split.splitViewItems.first { $0.behavior == .sidebar })
        XCTAssertEqual(sidebar.collapseBehavior, .useConstraints)

        for width in [760.0, 900.0, 1100.0] {
            window.setContentSize(NSSize(width: width, height: 600))
            try await Task.sleep(for: .milliseconds(100))
            let expectedFrame = window.frame
            for collapsed in [true, false, true, false] {
                split.toggleSidebar(nil)
                var movedDuringAnimation = false
                for _ in 0..<25 {
                    try await Task.sleep(for: .milliseconds(20))
                    movedDuringAnimation = movedDuringAnimation || window.frame != expectedFrame
                }
                XCTAssertFalse(movedDuringAnimation, "Window moved or resized while toggling at width \(width)")
                XCTAssertEqual(sidebar.isCollapsed, collapsed)
                if !collapsed {
                    XCTAssertEqual(sidebar.viewController.view.frame.width, 200, accuracy: 1)
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
                .frame(minWidth: 200, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(200)
                .background(SettingsSidebarLayout())
        } detail: {
            Form { Section("Connection") { Text("Mode"); Text("Protect traffic") } }
                .formStyle(.grouped)
                .frame(minWidth: 560)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minHeight: 500)
    }
}
