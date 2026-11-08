import SwiftUI

struct RoutingToolbar: ToolbarContent {
    let viewModel: AppViewModel
    let isActive: Bool
    let onNewProfile: () -> Void

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(id: "routing.profile", placement: .primaryAction) {
                RoutingEditorProfilePicker(viewModel: viewModel, onNewProfile: onNewProfile)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .settingsToolbarItemVisibility(isActive)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: "routing.toggle", placement: .primaryAction) {
                RoutingToggleButton(viewModel: viewModel)
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .padding(.leading, 8)
                    .settingsToolbarItemVisibility(isActive)
            }
            .sharedBackgroundVisibility(.hidden)
        } else if isActive {
            ToolbarItem(id: "routing.profile", placement: .primaryAction) {
                RoutingEditorProfilePicker(viewModel: viewModel, onNewProfile: onNewProfile)
            }
            ToolbarItem(id: "routing.toggle", placement: .primaryAction) {
                RoutingToggleButton(viewModel: viewModel)
            }
        }
    }
}

private struct RoutingEditorProfilePicker: View {
    @ObservedObject var viewModel: AppViewModel
    let onNewProfile: () -> Void
    @State private var isShowingLibrary = false

    var body: some View {
        Button { isShowingLibrary.toggle() } label: {
            HStack(spacing: 8) {
                Text(viewModel.selectedSplitTunnelProfile?.name ?? "Profile")
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .frame(width: 180, height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Editing profile")
        .accessibilityValue(viewModel.selectedSplitTunnelProfile?.name ?? "None")
        .help("Editing profile: \(viewModel.selectedSplitTunnelProfile?.name ?? "None")")
        .popover(isPresented: $isShowingLibrary, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            RoutingProfileLibrary(viewModel: viewModel, onOpenProfile: { isShowingLibrary = false }, onNewProfile: {
                isShowingLibrary = false
                onNewProfile()
            })
                .frame(width: 280, height: 380)
        }
    }
}

private struct RoutingToggleButton: View {
    @ObservedObject var viewModel: AppViewModel

    private var isAvailable: Bool { viewModel.connectionMode == .tun }
    private var isOn: Bool { isAvailable && viewModel.isSplitTunnelEnabled }

    var body: some View {
        Button {
            viewModel.setSplitTunnelEnabled(!viewModel.isSplitTunnelEnabled)
        } label: {
            Label(isOn ? "On" : "Off", systemImage: InterfaceSymbol.routing)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? Color.green : .primary)
                .frame(width: 82, height: 36)
                .contentShape(Capsule())
        }
        .disabled(!isAvailable)
        .help(isAvailable
            ? (isOn ? "Turn routing off" : "Turn routing on")
            : "Routing is available in TUN mode")
        .accessibilityLabel("Split routing")
        .accessibilityValue(isAvailable ? (isOn ? "On" : "Off") : "Unavailable in System Proxy mode")
    }
}
