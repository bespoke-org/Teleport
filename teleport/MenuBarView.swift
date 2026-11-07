import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var appIcons = AppIconStore.shared
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            sectionDivider
            configurationSection
            sectionDivider
            actionSection

            if let error = viewModel.connectionError {
                sectionDivider
                ConnectionErrorPopover(error: error, onDismiss: viewModel.dismissConnectionError)
            } else if let error = viewModel.lastError {
                sectionDivider
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }
        }
        .padding(8)
        .frame(width: 280)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: appIcons.image(for: appIcons.selectedIcon) ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Teleport")
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(headerStatusColor)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(headerStatusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button {
                if viewModel.canDisconnect {
                    viewModel.disconnect()
                } else {
                    viewModel.connect()
                }
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(viewModel.isConnected || viewModel.proxyPhase == .enabled ? Color.green : .primary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(MenuBarPowerButtonStyle())
            .disabled(!viewModel.canConnect && !viewModel.canDisconnect)
            .help(viewModel.canDisconnect ? "Disconnect" : "Connect")
            .accessibilityLabel(viewModel.canDisconnect ? "Disconnect" : "Connect")
            .accessibilityValue(headerStatusText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
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
        if viewModel.isConnected || viewModel.proxyPhase == .enabled {
            return .green
        }
        if viewModel.isAwaitingApproval {
            return .orange
        }
        switch viewModel.connectionPhase {
        case .failed:
            return .red
        case .starting, .stopping:
            return .orange
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
        VStack(alignment: .leading, spacing: 0) {
            Button(action: showSettings) {
                actionLabel("Settings…", shortcut: "⌘ ,")
            }
            .keyboardShortcut(",", modifiers: .command)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                actionLabel("Quit Teleport", shortcut: "⌘ Q")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(MenuBarRowStyle())
    }

    private func actionLabel(_ title: String, shortcut: String? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut {
                Text(shortcut)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func showSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            openWindow(id: "settings")
        }
    }
}

private struct MenuBarPowerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let isHighlighted = isEnabled && (isHovered || configuration.isPressed)
        return configuration.label
            .background(Circle().fill(.primary.opacity(isHighlighted ? 0.25 : 0)))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
    }
}

private struct MenuBarRowStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let isHighlighted = isEnabled && (isHovered || configuration.isPressed)
        return configuration.label
            .foregroundStyle(.primary)
            .opacity(isEnabled ? 1 : 0.4)
            .background {
                if #available(macOS 26.0, *) {
                    ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: true)
                        .fill(.primary.opacity(isHighlighted ? 0.25 : 0))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.primary.opacity(isHighlighted ? 0.25 : 0))
                }
            }
            .onHover { isHovered = $0 }
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
            && lhs.subtitle == rhs.subtitle
            && lhs.canChangeSelection == rhs.canChangeSelection
            && lhs.showsLatency == rhs.showsLatency
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if savedConnectionCount == 0 {
                Text("No saved portals")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(8)
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
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .simultaneousGesture(TapGesture().onEnded {
                    pickerHealthSnapshot = makeHealthSnapshot()
                })
                .menuStyle(.button)
                .buttonStyle(MenuBarRowStyle())
                .menuIndicator(.hidden)
                .help(subtitle)
                .accessibilityLabel("Portal: \(selectedDisplayName)")
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
