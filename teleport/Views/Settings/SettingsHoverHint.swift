import AppKit
import SwiftUI

/// Immediate pointer help in a separate, non-activating window. It neither
/// changes the row's layout nor takes the field editor's keyboard focus.
struct SettingsHoverHint: NSViewRepresentable {
    let message: String
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> HintView { HintView() }

    func updateNSView(_ view: HintView, context: Context) {
        view.message = message
        view.isHintEnabled = isEnabled
        if !isEnabled { view.hideHint() }
    }

    static func dismantleNSView(_ view: HintView, coordinator: ()) { view.hideHint() }

    final class HintView: NSView {
        var message = "" {
            didSet { if message != oldValue, hintWindow != nil { showHint() } }
        }
        var isHintEnabled = true
        private var tracking: NSTrackingArea?
        private(set) var hintWindow: NSPanel?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            hideHint()
            super.viewWillMove(toWindow: newWindow)
        }

        override func mouseEntered(with event: NSEvent) { showHint() }
        override func mouseExited(with event: NSEvent) { hideHint() }

        private func showHint() {
            guard isHintEnabled, !message.isEmpty, !isHiddenOrHasHiddenAncestor,
                  let window, let screen = window.screen else { return }
            hideHint()
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .popUpMenu
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = true
            panel.animationBehavior = .none
            panel.appearance = window.effectiveAppearance
            let content = NSHostingView(rootView:
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(width: 280, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            )
            panel.contentView = content
            panel.setContentSize(content.fittingSize)
            let anchor = window.convertToScreen(convert(bounds, to: nil))
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            let x = min(max(anchor.midX - panel.frame.width / 2, visible.minX), visible.maxX - panel.frame.width)
            let above = anchor.maxY + 6
            let y = above + panel.frame.height <= visible.maxY ? above : anchor.minY - panel.frame.height - 6
            panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY, y)))
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            hintWindow = panel
        }

        func hideHint() {
            guard let panel = hintWindow else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            hintWindow = nil
        }
    }
}
