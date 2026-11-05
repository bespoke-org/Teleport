import AppKit
import SwiftUI

/// Keeps sidebar sizing stable and leaves selection drawing to the SwiftUI rows.
struct SettingsSidebarLayout: NSViewRepresentable {
    static let sidebarWidth: CGFloat = 200
    static let minimumDetailWidth: CGFloat = 560
    // macOS 15 reserves one point for the split divider. Without it, AppKit
    // grows a minimum-width window by one point when the sidebar is toggled.
    static let minimumContentSize = NSSize(width: sidebarWidth + minimumDetailWidth + 1, height: 500)

    func makeNSView(context: Context) -> SidebarLayoutView { SidebarLayoutView() }

    func updateNSView(_ view: SidebarLayoutView, context: Context) { view.configureSidebar() }

    final class SidebarLayoutView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureSidebar()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureSidebar()
        }

        func configureSidebar() {
            var ancestor = superview
            while let view = ancestor {
                if let splitView = view as? NSSplitView,
                    let controller = splitView.delegate as? NSSplitViewController,
                    let sidebar = controller.splitViewItems.first(where: {
                        $0.behavior == .sidebar && isDescendant(of: $0.viewController.view)
                    })
                {
                    // AppKit's default expansion can add the sidebar width to the window
                    // when its minimum is kept constant while the sidebar is collapsed.
                    // Let the existing pane constraints redistribute the available width.
                    if sidebar.collapseBehavior != .useConstraints {
                        sidebar.collapseBehavior = .useConstraints
                    }
                    useCustomSelection(in: sidebar.viewController.view)
                    return
                }
                ancestor = view.superview
            }
        }

        private func useCustomSelection(in view: NSView) {
            if let table = view as? NSTableView {
                // Keep native selection and keyboard navigation, but let the
                // SwiftUI row background draw the quiet gray selection.
                table.selectionHighlightStyle = .none
                return
            }
            for child in view.subviews {
                useCustomSelection(in: child)
            }
        }
    }
}
