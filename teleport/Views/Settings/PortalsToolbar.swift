import SwiftUI

/// Keep the native item list stable when pages change. Inserting and removing
/// these items makes AppKit update the layout of the entire glass toolbar.
struct PortalsToolbar: ToolbarContent {
    @Binding var state: PortalsState
    let isActive: Bool

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(id: "portals.search", placement: .primaryAction) {
                search
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .visibility(isActive)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(id: "portals.add", placement: .primaryAction) {
                add
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .visibility(isActive)
            }
            .sharedBackgroundVisibility(.hidden)
        } else if isActive {
            // Earlier macOS versions cannot hide an item's shared background.
            ToolbarItem(id: "portals.search", placement: .primaryAction) { search }
            ToolbarItem(id: "portals.add", placement: .primaryAction) { add }
        }
    }

    private var search: some View {
        PortalsSearchControl(query: $state.query, isAvailable: isActive)
    }

    private var add: some View {
        Button {
            state.isShowingAddSheet = true
        } label: {
            Label("Add portal", systemImage: "plus")
                .labelStyle(.iconOnly)
                .font(.system(size: 17))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .keyboardShortcut("n", modifiers: .command)
        .help("Add portal")
    }
}

private extension View {
    func visibility(_ isActive: Bool) -> some View {
        opacity(isActive ? 1 : 0)
            .disabled(!isActive)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}
