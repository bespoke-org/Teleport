import SwiftUI

/// Assignment is visible on its owner. Opening the editor is a separate action.
struct PortalRoutingProfilePicker: View {
    @ObservedObject var viewModel: AppViewModel
    let target: TunnelTarget
    let onOpenProfile: (UUID) -> Void

    private var profile: SplitTunnelProfile? { viewModel.tunnelProfile(for: target) }

    var body: some View {
        Menu {
            Picker("Routing profile", selection: Binding(
                get: { viewModel.personalTunnelProfileID(for: target) },
                set: { viewModel.assignTunnelProfile($0, to: target) }
            )) {
                if case let .subscription(sourceID) = target,
                   let provider = viewModel.providerTunnelProfile(for: sourceID) {
                    Text("From subscription: " + provider.name).tag(Optional<UUID>.none)
                    Divider()
                }
                ForEach(viewModel.personalTunnelProfiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Open profile", systemImage: "arrow.up.forward.square") {
                if let id = profile?.id { onOpenProfile(id) }
            }
            .disabled(profile == nil)
        } label: {
            Label(profile?.name ?? "Select profile", systemImage: InterfaceSymbol.routing)
                .lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .background(MenuIconVisibility())
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.primary.opacity(0.06), in: Capsule())
        .frame(maxWidth: 240, alignment: .leading)
        .accessibilityLabel("Routing profile for \(viewModel.tunnelTargetName(target))")
        .accessibilityValue(profile?.name ?? "Select profile")
        .help("Routing profile: \(profile?.name ?? "Select profile")")
    }
}
