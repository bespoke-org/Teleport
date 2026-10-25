import SwiftUI

struct SplitTunnelTester: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var destination = ""
    @State private var fieldClickScope = SettingsClickAwayScope()
    @FocusState private var isDestinationFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            TextField("Destination", text: $destination, prompt: Text("Domain or IP address"))
                .labelsHidden()
                .accessibilityLabel("Destination")
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($isDestinationFocused)
                .onExitCommand { isDestinationFocused = false }
                .background(SettingsClickAwayRegion(scope: fieldClickScope))
                .background(SettingsClickAwayMonitor(scope: fieldClickScope, isActive: isDestinationFocused) {
                    isDestinationFocused = false
                })
            Group {
                if destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter a destination to test.")
                        .foregroundStyle(.secondary)
                } else {
                    result
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if viewModel.connectionMode != .tun {
                warning("Preview only. Applies in TUN mode.")
            } else if !viewModel.isSplitTunnelEnabled {
                warning("Preview only. Split routing is off.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func warning(_ message: String) -> some View {
        Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .help(message)
            .accessibilityLabel(message)
    }

    @ViewBuilder private var result: some View {
        let match = viewModel.matchingSplitTunnelRule(for: destination)
        if viewModel.hasEnabledSplitTunnelGeodataRules, !viewModel.isSplitTunnelGeodataReady {
            ProgressView("Loading geodata…").controlSize(.small)
        } else {
            let action = match?.action ?? viewModel.splitTunnelDefaultAction
            HStack(spacing: 6) {
                Text(routeDescription(action, portalID: match?.connectionID))
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text("· " + (match.map { "Matches \(SplitTunnelPresentation.destination($0))" } ?? "Unmatched traffic"))
                    .font(.caption).foregroundStyle(.secondary)
                if let id = match?.connectionID,
                   !viewModel.savedConnections.contains(where: { $0.id == id }) {
                    warning("The rule’s portal is unavailable. Uses the selected portal.")
                }
            }
        }
    }

    private func routeDescription(_ action: SplitTunnelRuleAction, portalID: UUID?) -> String {
        guard action == .proxy else { return action.displayName }
        let portal = portalID.flatMap { id in viewModel.savedConnections.first { $0.id == id } } ?? viewModel.selectedConnection
        return portal.map { "Proxy via \($0.displayName)" } ?? "Proxy via selected portal"
    }
}
