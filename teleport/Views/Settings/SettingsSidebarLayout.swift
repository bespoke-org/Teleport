import AppKit
import SwiftUI

/// Keeps sidebar animation inside the window instead of letting AppKit grow it.
struct SettingsSidebarLayout: NSViewRepresentable {
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
                   }) {
                    // AppKit's default expansion can add the sidebar width to the window
                    // when its minimum is kept constant while the sidebar is collapsed.
                    // Let the existing pane constraints redistribute the available width.
                    sidebar.collapseBehavior = .useConstraints
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
