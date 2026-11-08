import SwiftUI

/// The page controls stay mounted inside Settings' shared toolbar slot.
struct PortalsToolbar<ConnectionControl: View>: View {
    @Binding var state: PortalsState
    let isActive: Bool
    let connection: ConnectionControl

    var body: some View {
        HStack(spacing: 8) {
            if #available(macOS 26.0, *) {
                search
                    .glassEffect(.regular.interactive(), in: Capsule())
                add
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                connection
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
            } else {
                search
                add
                connection
            }
        }
        .settingsToolbarItemVisibility(isActive)
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

extension View {
    func settingsToolbarItemVisibility(_ isActive: Bool) -> some View {
        opacity(isActive ? 1 : 0)
            // Collapse inactive controls inside the shared slot, retaining their state.
            // Do not clip: interactive glass expands beyond the resting bounds.
            .frame(width: isActive ? nil : 1, height: 36)
            .disabled(!isActive)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}
