import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            configurationSection
            actionSection

            if let error = viewModel.connectionError?.summary ?? viewModel.lastError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private var header: some View {
        HStack(alignment: .top) {
            Text("Teleport")
                .font(.headline)

            Spacer()

            Text(headerStatusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(headerStatusColor)
        }
    }

    private var headerStatusText: String {
        if viewModel.isConnected || viewModel.proxyPhase == .enabled {
            return "Connected"
        }

        if viewModel.isAwaitingApproval {
            return "Awaiting approval"
        }

        switch viewModel.connectionPhase {
        case .starting:
            return "Connecting"
        case .stopping:
            return "Disconnecting"
        case .failed:
            return "Error"
        case .unconfigured:
            return "No config"
        case .ready, .stopped, .running:
            return "Disconnected"
        }
    }

    private var headerStatusColor: Color {
        switch viewModel.connectionPhase {
        case .failed:
            return .red
        case .starting, .stopping:
            return .orange
        case _ where viewModel.proxyPhase == .enabled:
            return Color(NSColor.systemGreen.withAlphaComponent(0.72))
        case .unconfigured:
            return .secondary
        default:
            return .secondary
        }
    }

    private var configurationSection: some View {
        ConnectionPickerSection(
            savedConnectionCount: viewModel.savedConnections.count,
            manualItems: viewModel.manualConnectionPickerItems,
            subscriptionItems: viewModel.subscriptionPickerItems,
            importedItemsBySourceID: viewModel.importedConnectionPickerItemsBySourceID,
            selectedConnectionID: viewModel.selectedConnectionID,
            selectedDisplayName: viewModel.selectedConnection?.displayName ?? "Select portal",
            subtitle: connectionSubtitle,
            canChangeSelection: viewModel.canChangeSelection,
            showsLatency: viewModel.showsLatencyInMenuBarPicker,
            makeHealthSnapshot: viewModel.healthSnapshotForPicker,
            healthSummary: viewModel.healthSummary(for:),
            onSelect: { id in viewModel.selectConnection(id: id) }
        )
        .equatable()
    }

    private var connectionSubtitle: String {
        guard let selectedConnection = viewModel.selectedConnection else {
            return "Choose a portal"
        }

        let healthSummary = viewModel.healthSummary(for: selectedConnection)
        if let source = viewModel.subscriptionSource(for: selectedConnection) {
            return "From \(source.displayName) • \(healthSummary)"
        }

        return "Manual • \(healthSummary)"
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(viewModel.canDisconnect ? "Disconnect" : "Connect") {
                    if viewModel.canDisconnect {
                        viewModel.disconnect()
                    } else {
                        viewModel.connect()
                    }
                }
                .disabled(!viewModel.canConnect && !viewModel.canDisconnect)

                Button("Settings") {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        openWindow(id: "settings")
                    }
                }

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}

private struct ConnectionPickerSection: View, Equatable {
    let savedConnectionCount: Int
    let manualItems: [ConnectionPickerItem]
    let subscriptionItems: [SubscriptionPickerItem]
    let importedItemsBySourceID: [UUID: [ConnectionPickerItem]]
    let selectedConnectionID: UUID?
    let selectedDisplayName: String
    let subtitle: String
    let canChangeSelection: Bool
    let showsLatency: Bool
    let makeHealthSnapshot: () -> [UUID: ConnectionHealthCheck]
    let healthSummary: (ConnectionHealthCheck) -> String
    let onSelect: (UUID) -> Void

    @State private var pickerHealthSnapshot: [UUID: ConnectionHealthCheck] = [:]

    static func == (lhs: ConnectionPickerSection, rhs: ConnectionPickerSection) -> Bool {
        lhs.savedConnectionCount == rhs.savedConnectionCount
            && lhs.manualItems == rhs.manualItems
            && lhs.subscriptionItems == rhs.subscriptionItems
            && lhs.importedItemsBySourceID == rhs.importedItemsBySourceID
            && lhs.selectedConnectionID == rhs.selectedConnectionID
            && lhs.selectedDisplayName == rhs.selectedDisplayName
            && lhs.canChangeSelection == rhs.canChangeSelection
            && lhs.showsLatency == rhs.showsLatency
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if savedConnectionCount == 0 {
                Text("No saved portals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    if !manualItems.isEmpty {
                        Text("Standalone")
                        ForEach(manualItems) { connection in
                            connectionSelectionButton(connection)
                        }
                    }

                    if !subscriptionItems.isEmpty {
                        Text("Subscriptions")
                        ForEach(subscriptionItems) { source in
                            subscriptionMenu(source)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedDisplayName)
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.up.chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
                .simultaneousGesture(TapGesture().onEnded {
                    pickerHealthSnapshot = makeHealthSnapshot()
                })
                .menuStyle(.borderlessButton)
                .disabled(!canChangeSelection)
            }
        }
        .onAppear {
            pickerHealthSnapshot = makeHealthSnapshot()
        }
    }

    @ViewBuilder
    private func subscriptionMenu(_ source: SubscriptionPickerItem) -> some View {
        let connections = importedItemsBySourceID[source.id] ?? []

        Menu {
            if connections.isEmpty {
                Button("No imported configs") {}
                    .disabled(true)
            } else {
                ForEach(connections) { connection in
                    connectionSelectionButton(connection)
                }
            }
        } label: {
            Text("\(source.displayName) (\(connections.count))")
        }
    }

    @ViewBuilder
    private func connectionSelectionButton(_ connection: ConnectionPickerItem) -> some View {
        Button {
            onSelect(connection.id)
        } label: {
            let isSelected = connection.id == selectedConnectionID
            let prefix = isSelected ? "✓ " : ""
            Text(prefix + connectionLabel(for: connection))
        }
    }

    private func connectionLabel(for connection: ConnectionPickerItem) -> String {
        guard showsLatency, let healthCheck = pickerHealthSnapshot[connection.id] else {
            return connection.displayName
        }
        return "\(connection.displayName) • \(healthSummary(healthCheck))"
    }
}

#Preview {
    MenuBarView(viewModel: AppViewModel())
}
