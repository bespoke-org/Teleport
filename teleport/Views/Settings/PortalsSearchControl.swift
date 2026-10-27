import AppKit
import SwiftUI

struct PortalsSearchControl: View {
    @Binding var query: String
    var isAvailable: Bool
    // Leave room for Add at the minimum Settings window width.
    private static let searchFieldWidth: CGFloat = 170
    @State private var isSearchExpanded = false
    @State private var focusRequest = 0
    @State private var searchControlWidth: CGFloat = 36
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(query: Binding<String>, isAvailable: Bool = true) {
        _query = query
        self.isAvailable = isAvailable
        let expanded = !query.wrappedValue.isEmpty
        _isSearchExpanded = State(initialValue: expanded)
        // Returning to an existing search should not animate the whole toolbar.
        _searchControlWidth = State(initialValue: expanded ? Self.searchFieldWidth : 36)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if isSearchExpanded || searchControlWidth > 36 {
                PortalsToolbarSearchField(text: $query,
                    isActive: isAvailable && isSearchExpanded && searchControlWidth == Self.searchFieldWidth,
                    focusRequest: focusRequest,
                    onDismiss: closeSearch)
                    .frame(width: Self.searchFieldWidth, height: 28)
                    .opacity(min(1, (Double(searchControlWidth) - 36) / 60))
                    .allowsHitTesting(isSearchExpanded)
            }
            Button {
                focusRequest += 1
                isSearchExpanded = true
            } label: {
                Label("Search portals", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search portals")
            .help("Search portals")
            .keyboardShortcut("f", modifiers: .command)
            .opacity(isSearchExpanded ? 0 : 1)
            .allowsHitTesting(!isSearchExpanded)
            .accessibilityHidden(isSearchExpanded)
        }
        .frame(width: searchControlWidth, height: 36, alignment: .leading)
        .clipped()
        .task(id: isSearchExpanded ? Self.searchFieldWidth : 36) {
            await resizeSearchControl()
        }
    }

    private func resizeSearchControl() async {
        let target: CGFloat = isSearchExpanded ? Self.searchFieldWidth : 36
        let initial = searchControlWidth
        guard initial != target else { return }
        guard !reduceMotion else {
            searchControlWidth = target
            return
        }

        // NSToolbar measures SwiftUI at its final animated size. Supply the
        // intermediate widths so AppKit also resizes the surrounding toolbar shape.
        let clock = ContinuousClock()
        let start = clock.now
        while !Task.isCancelled {
            let elapsed = start.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let progress = min(1, seconds / 0.25)
            let eased = progress * progress * (3 - 2 * progress)
            searchControlWidth = initial + (target - initial) * eased
            if progress == 1 { return }
            do { try await Task.sleep(for: .milliseconds(8)) }
            catch { return }
        }
    }

    private func closeSearch() {
        query = ""
        isSearchExpanded = false
    }
}

/// Focus after expansion and AppKit attachment, when the field has room to edit.
private struct PortalsToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let isActive: Bool
    let focusRequest: Int
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SearchField {
        let field = SearchField()
        field.placeholderString = "Search portals"
        field.setAccessibilityLabel("Search portals")
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.onClickAway = { [weak coordinator = context.coordinator] in
            guard let coordinator, coordinator.parent.text.isEmpty else { return }
            coordinator.parent.onDismiss()
        }
        return field
    }

    func updateNSView(_ field: SearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.wantsSearchFocus = isActive
        field.focusRequest = focusRequest
        if !isActive, let editor = field.currentEditor(),
           field.window?.firstResponder === editor {
            field.window?.makeFirstResponder(nil)
        }
        field.focusIfReady()
    }

    static func dismantleNSView(_ field: SearchField, coordinator: Coordinator) {
        field.stopMonitoringOutsideClicks()
    }

    final class SearchField: NSSearchField {
        private var outsideClickMonitor: Any?
        var onClickAway: (() -> Void)?
        var wantsSearchFocus = false
        var focusRequest = 0
        private var lastFocusRequest: Int?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoringOutsideClicks()
            lastFocusRequest = nil
            guard window != nil else { return }
            // Blank SwiftUI content does not necessarily take first responder.
            // Explicitly end editing while allowing the original click through.
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      let editor = self.currentEditor(), window.firstResponder === editor,
                      !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                window.makeFirstResponder(nil)
                self.onClickAway?()
                return event
            }
            focusIfReady()
        }

        func focusIfReady() {
            guard wantsSearchFocus, lastFocusRequest != focusRequest, let window else { return }
            let request = focusRequest
            lastFocusRequest = request
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window, self.wantsSearchFocus,
                      self.focusRequest == request else { return }
                window.makeFirstResponder(self)
            }
        }

        func stopMonitoringOutsideClicks() {
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
                self.outsideClickMonitor = nil
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PortalsToolbarSearchField
        init(_ parent: PortalsToolbarSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            control.window?.makeFirstResponder(nil)
            parent.onDismiss()
            return true
        }
    }
}
