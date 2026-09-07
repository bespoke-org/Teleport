import AppKit
import SwiftUI

struct ConnectionsSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var expandedSubscriptionIDs: Set<UUID> = []
    @State private var editingSubscription: SubscriptionSource?
    @State private var qrPayload: QRPayload?
    @State private var activeShareMenu: ShareMenuPayload?
    @State private var isShowingAddSheet = false
    @State private var isHoveringAddButton = false
    /// The connection being renamed, and the name being typed for it.
    @State private var renamingConnectionID: UUID?
    @State private var renameDraft = ""
    @FocusState private var isRenameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.savedConnections.isEmpty && viewModel.subscriptionSources.isEmpty {
                VStack {
                    Spacer(minLength: 0)
                    ContentUnavailableView(
                        "No connections",
                        systemImage: "tray",
                        description: Text("Add a VLESS, Trojan, or subscription link to get started.")
                    )
                    .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !viewModel.manualConnections.isEmpty {
                        Section("Saved connections") {
                            ForEach(viewModel.manualConnections) { connection in
                                manualConnectionRow(connection)
                            }
                        }
                    }

                    Section("Subscriptions") {
                        if viewModel.subscriptionSources.isEmpty {
                            Text("No subscriptions yet")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(viewModel.subscriptionSources) { source in
                                subscriptionHeaderRow(source)

                                if expandedSubscriptionIDs.contains(source.id) {
                                    subscriptionExpandedRows(source)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Spacer()

                Button {
                    isShowingAddSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(isHoveringAddButton ? .blue : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            isHoveringAddButton
                                ? AnyShapeStyle(Color.blue.opacity(0.16))
                                : AnyShapeStyle(.ultraThinMaterial),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isHoveringAddButton ? Color.blue.opacity(0.35) : Color.white.opacity(0.18),
                                    lineWidth: 0.8
                                )
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHoveringAddButton = hovering
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $isShowingAddSheet) {
            AddConnectionSheet(viewModel: viewModel)
        }
        .sheet(item: $editingSubscription) { source in
            SubscriptionSettingsSheet(
                source: source,
                onSave: { customName, urlString, autoUpdateIntervalMinutes, filterDuplicateImports in
                    viewModel.updateSubscriptionSettings(
                        id: source.id,
                        customName: customName,
                        urlString: urlString,
                        autoUpdateIntervalMinutes: autoUpdateIntervalMinutes,
                        filterDuplicateImports: filterDuplicateImports
                    )
                }
            )
        }
        .sheet(item: $qrPayload) { payload in
            QRCodeSheet(payload: payload)
        }
    }

    @ViewBuilder
    private func manualConnectionRow(_ connection: SavedConnection) -> some View {
        let isSelected = connection.id == viewModel.selectedConnectionID
        let configuration = connection.configuration
        let health = viewModel.healthCheck(for: connection)

        HStack(spacing: 12) {
            if renamingConnectionID == connection.id {
                renameField(connection, isSelected: isSelected)
            } else {
            Button {
                viewModel.selectConnection(id: connection.id)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            connectionNameView(connection)
                            connectionHealthRow(connection, health: health)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(configuration.descriptiveSummary)
                                .font(.caption)
                                .foregroundStyle(configuration.securityWarningText == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                            splitTunnelUsageLabel(connection)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canChangeSelection && !isSelected)
            }

            // Renaming is a visible control, not a right-click discovery: the row's
            // own button only changes the selection, so there is nowhere on the name
            // itself to click for this.
            if !connection.isImported {
                Button {
                    beginRename(connection)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename this connection")
            }

            Button {
                viewModel.refreshConnectionHealth(id: connection.id)
            } label: {
                Image(systemName: healthActionIcon(for: health))
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isRefreshingHealth(for: connection.id) || viewModel.isQueuedHealth(for: connection.id))

            shareButton(
                title: connection.configuration.displayName,
                value: connection.configuration.rawLink,
                copyTitle: shareCopyTitle(for: connection.configuration)
            )

            Button(role: .destructive) {
                viewModel.removeConnection(id: connection.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(isSelected && !viewModel.canChangeSelection)
        }
        .padding(.vertical, 4)
        // On the row rather than on the name: while a session is running the row's
        // selection button is disabled, and a disabled control shows no context
        // menu — renaming has nothing to do with changing the selection.
        .contextMenu {
            // Imported entries take their name from the subscription and would be
            // renamed back on the next refresh.
            if !connection.isImported {
                Button("Rename…") { beginRename(connection) }
            }
        }
    }

    @ViewBuilder
    private func subscriptionHeaderRow(_ source: SubscriptionSource) -> some View {
        let isExpanded = expandedSubscriptionIDs.contains(source.id)
        let isRefreshingHealth = viewModel.isRefreshingSubscriptionHealth(source.id)
        let isQueuedHealth = viewModel.isQueuedSubscriptionHealth(source.id)

        HStack(alignment: .top, spacing: 10) {
            Button {
                toggleSubscription(source.id)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(source.displayName)
                                .font(.subheadline.weight(.semibold))

                            if viewModel.isRefreshingSubscription(source.id) {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        Text(subscriptionSummary(for: source))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            shareButton(
                title: source.displayName,
                value: source.urlString
            )

            Button {
                editingSubscription = source
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)

            Button {
                viewModel.refreshSubscription(id: source.id)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isRefreshingSubscription(source.id))

            Button {
                viewModel.refreshSubscriptionHealth(id: source.id)
            } label: {
                Image(systemName: subscriptionHealthActionIcon(isRefreshing: isRefreshingHealth, isQueued: isQueuedHealth))
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshingHealth || isQueuedHealth)

            Button(role: .destructive) {
                expandedSubscriptionIDs.remove(source.id)
                viewModel.removeSubscription(id: source.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func subscriptionExpandedRows(_ source: SubscriptionSource) -> some View {
        if let error = source.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.leading, 20)
        }

        let importedConnections = viewModel.importedConnections(for: source.id)
        if importedConnections.isEmpty {
            Text("No imported configs yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        } else {
            ForEach(importedConnections) { connection in
                importedConnectionRow(connection)
                    .padding(.leading, 20)
            }
        }
    }

    @ViewBuilder
    private func importedConnectionRow(_ connection: SavedConnection) -> some View {
        let isSelected = connection.id == viewModel.selectedConnectionID
        let configuration = connection.configuration
        let health = viewModel.healthCheck(for: connection)

        HStack(spacing: 12) {
            Button {
                viewModel.selectConnection(id: connection.id)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(configuration.displayName)
                                .foregroundStyle(.primary)
                            connectionHealthRow(connection, health: health)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(configuration.descriptiveSummary)
                                .font(.caption)
                                .foregroundStyle(configuration.securityWarningText == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                            splitTunnelUsageLabel(connection)
                        }
                    }

                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canChangeSelection && !isSelected)

            Button {
                viewModel.refreshConnectionHealth(id: connection.id)
            } label: {
                Image(systemName: healthActionIcon(for: health))
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isRefreshingHealth(for: connection.id) || viewModel.isQueuedHealth(for: connection.id))

            shareButton(
                title: configuration.displayName,
                value: configuration.rawLink,
                copyTitle: shareCopyTitle(for: configuration)
            )
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func connectionHealthRow(_ connection: SavedConnection, health: ConnectionHealthCheck) -> some View {
        HStack(spacing: 6) {
            Image(systemName: healthIcon(for: health))
                .font(.body.weight(.semibold))
                .foregroundStyle(healthColor(for: health))

            Text(viewModel.healthSummary(for: connection))
                .font(.body)
                .foregroundStyle(healthColor(for: health))
                .lineLimit(1)
        }
    }

    private func healthIcon(for health: ConnectionHealthCheck) -> String {
        switch health.state {
        case .reachable:
            return "checkmark.circle.fill"
        case .unreachable:
            return "xmark.octagon.fill"
        case .queued:
            return "clock.badge"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private func healthColor(for health: ConnectionHealthCheck) -> Color {
        switch health.state {
        case .reachable:
            return Color(NSColor.systemGreen)
        case .unreachable:
            return .red
        case .queued:
            return .secondary
        case .checking:
            return .orange
        case .unknown:
            return .secondary
        }
    }

    private func healthActionIcon(for health: ConnectionHealthCheck) -> String {
        switch health.state {
        case .queued:
            return "clock.badge"
        case .checking:
            return "hourglass"
        case .unknown, .reachable, .unreachable:
            return "waveform.path.ecg"
        }
    }

    private func subscriptionHealthActionIcon(isRefreshing: Bool, isQueued: Bool) -> String {
        if isRefreshing {
            return "hourglass"
        }

        if isQueued {
            return "clock.badge"
        }

        return "waveform.path.ecg"
    }

    /// A link with no name reads as host:port, which says nothing about what the
    /// connection is for.
    @ViewBuilder
    private func connectionNameView(_ connection: SavedConnection) -> some View {
        Text(connection.configuration.displayName)
            .foregroundStyle(.primary)
    }

    /// Replaces the row's selection button while renaming. It has to sit outside
    /// that button: the button is disabled while a session is running, and a
    /// disabled container refuses input for everything inside it, including a text
    /// field. Renaming does not change the selection, so it stays available.
    @ViewBuilder
    private func renameField(_ connection: SavedConnection, isSelected: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($isRenameFieldFocused)
                .onSubmit { commitRename(connection) }
                .onExitCommand { renamingConnectionID = nil }

            Button("Save") { commitRename(connection) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel") { renamingConnectionID = nil }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beginRename(_ connection: SavedConnection) {
        renameDraft = connection.configuration.remarks ?? connection.configuration.displayName
        renamingConnectionID = connection.id
        isRenameFieldFocused = true
    }

    private func commitRename(_ connection: SavedConnection) {
        viewModel.renameConnection(id: connection.id, to: renameDraft)
        renamingConnectionID = nil
    }

    /// A connection that is not the selected one still joins the session when a
    /// split-tunnel rule routes through it. This says so where the connection is,
    /// rather than asking the user to opt in separately.
    @ViewBuilder
    private func splitTunnelUsageLabel(_ connection: SavedConnection) -> some View {
        let ruleCount = viewModel.activeRuleCount(routingThrough: connection.id)
        if connection.id != viewModel.selectedConnectionID, ruleCount > 0 {
            Text(ruleCount == 1 ? "1 split-tunnel rule" : "\(ruleCount) split-tunnel rules")
                .font(.caption)
                .foregroundStyle(.tint)
        }
    }

    /// A WireGuard peer is shared as its configuration file rather than a URL.
    private func shareCopyTitle(for configuration: ConnectionConfiguration) -> String {
        configuration.protocolType == .wireguard ? "Copy configuration" : "Copy URL"
    }

    @ViewBuilder
    private func shareButton(title: String, value: String, copyTitle: String = "Copy URL") -> some View {
        let payload = ShareMenuPayload(title: title, value: value)
        let isPresented = Binding(
            get: { activeShareMenu == payload },
            set: { newValue in
                activeShareMenu = newValue ? payload : nil
            }
        )

        Button {
            activeShareMenu = activeShareMenu == payload ? nil : payload
        } label: {
            actionIcon("square.and.arrow.up")
        }
        .buttonStyle(.borderless)
        .popover(isPresented: isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            ShareActionPopover(
                copyTitle: copyTitle,
                onCopy: {
                    copyToClipboard(value)
                    activeShareMenu = nil
                },
                onShowQR: {
                    qrPayload = QRPayload(title: title, value: value)
                    activeShareMenu = nil
                }
            )
        }
    }

    @ViewBuilder
    private func actionIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.primary)
            .frame(width: 15, height: 15, alignment: .center)
            .contentShape(Rectangle())
    }

    private func toggleSubscription(_ id: UUID) {
        if expandedSubscriptionIDs.contains(id) {
            expandedSubscriptionIDs.remove(id)
        } else {
            expandedSubscriptionIDs.insert(id)
        }
    }

    private func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func subscriptionSummary(for source: SubscriptionSource) -> String {
        let importedCount = viewModel.importedConnectionCount(for: source.id)
        let configText = importedCount == 1 ? "1 config" : "\(importedCount) configs"
        let intervalText: String

        if let interval = source.autoUpdateIntervalMinutes, interval > 0 {
            intervalText = "auto \(formattedInterval(interval))"
        } else {
            intervalText = "auto off"
        }

        if let lastRefreshedAt = source.lastRefreshedAt {
            return "\(configText) • \(intervalText) • updated \(lastRefreshedAt.formatted(date: .abbreviated, time: .shortened))"
        }

        return "\(configText) • \(intervalText)"
    }

    private func formattedInterval(_ minutes: Int) -> String {
        if minutes % 1440 == 0 {
            let days = minutes / 1440
            return days == 1 ? "every day" : "every \(days)d"
        }

        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "hourly" : "every \(hours)h"
        }

        return "every \(minutes)m"
    }
}
