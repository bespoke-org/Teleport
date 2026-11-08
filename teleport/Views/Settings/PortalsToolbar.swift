import SwiftUI

/// Keep the native item list stable when pages change. Inserting and removing
/// these items makes AppKit update the layout of the entire glass toolbar.
struct PortalsToolbar<ConnectionControl: View>: ToolbarContent {
    @Binding var state: PortalsState
    let isActive: Bool
    let connection: ConnectionControl

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(id: "portals.actions", placement: .primaryAction) {
                // Own the gap between our custom glass shapes. Native toolbar
                // spacers do not reliably separate items with hidden backgrounds.
                HStack(spacing: 8) {
                    search
                        .glassEffect(.regular.interactive(), in: Capsule())
                    add
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: Circle())
                    connection
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .padding(.trailing, 4)
                .visibility(isActive)
            }
            .sharedBackgroundVisibility(.hidden)
        } else if isActive {
            // Earlier macOS versions cannot hide an item's shared background.
            ToolbarItem(id: "portals.search", placement: .primaryAction) { search }
            ToolbarItem(id: "portals.add", placement: .primaryAction) { add }
            ToolbarItem(id: "portals.connection", placement: .primaryAction) { connection }
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

struct PortalsConnectionButton: View {
    @ObservedObject var viewModel: AppViewModel

    private var actionTitle: String { viewModel.canDisconnect ? "Disconnect" : "Connect" }

    var body: some View {
        Button {
            if viewModel.canDisconnect {
                viewModel.disconnect()
            } else {
                viewModel.connect()
            }
        } label: {
            Label(actionTitle, systemImage: "power")
                .labelStyle(.iconOnly)
                .font(.system(size: 17))
                .foregroundStyle(viewModel.isConnected || viewModel.proxyPhase == .enabled ? Color.green : .primary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .disabled(!viewModel.canConnect && !viewModel.canDisconnect)
        .help(actionTitle)
        .accessibilityLabel(actionTitle)
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
