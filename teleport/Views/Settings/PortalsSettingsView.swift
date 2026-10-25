import AppKit
import SwiftUI

/// Owned by Settings so navigation between pages preserves browsing state.
struct PortalsState {
    var query = ""
    var expandedSubscriptions: Set<UUID> = []
    var hasOpened = false

    var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    func matches(_ connection: SavedConnection) -> Bool {
        searchTerm.isEmpty || [
            connection.displayName,
            connection.configuration.host,
            DisplayHostname.unicode(connection.configuration.host),
            connection.configuration.descriptiveSummary,
        ].contains { $0.localizedStandardContains(searchTerm) }
    }

    func matches(_ source: SubscriptionSource) -> Bool {
        !searchTerm.isEmpty && source.displayName.localizedStandardContains(searchTerm)
    }

    func isExpanded(_ sourceID: UUID) -> Bool {
        !searchTerm.isEmpty || expandedSubscriptions.contains(sourceID)
    }

    mutating func toggle(_ sourceID: UUID) {
        if !expandedSubscriptions.insert(sourceID).inserted {
            expandedSubscriptions.remove(sourceID)
        }
    }
}

struct PortalsSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var state: PortalsState
    @State private var isShowingAddSheet = false
    @State private var editingConnection: SavedConnection?
    @State private var renamingConnection: SavedConnection?
    @State private var editingSubscription: SubscriptionSource?
    @State private var qrPayload: QRPayload?
    @State private var removal: PortalRemoval?

    private var isSearching: Bool { !state.searchTerm.isEmpty }
    private var isEmpty: Bool { viewModel.savedConnections.isEmpty && viewModel.subscriptionSources.isEmpty }

    var body: some View {
        let manual = viewModel.manualConnections.filter { state.matches($0) }
        let groups = viewModel.subscriptionSources.compactMap { source -> PortalSubscriptionGroup? in
            let all = viewModel.importedConnections(for: source.id)
            let matches = state.matches(source) ? all : all.filter { state.matches($0) }
            guard !isSearching || state.matches(source) || !matches.isEmpty else { return nil }
            return PortalSubscriptionGroup(source: source, connections: matches, total: all.count)
        }

        VStack(spacing: 12) {
            if isEmpty {
                emptyState
            } else if manual.isEmpty && groups.isEmpty {
                ContentUnavailableView.search(text: state.searchTerm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    if !manual.isEmpty {
                        Section("Standalone") {
                            LazyVStack(spacing: 0) {
                                ForEach(manual) { connection in
                                    connectionRow(connection)
                                    if connection.id != manual.last?.id {
                                        Divider()
                                    }
                                }
                            }
                            // Rows already include vertical padding; avoid doubling it at the section edges.
                            .padding(.vertical, -7)
                        }
                    }
                    if !groups.isEmpty {
                        Section("Subscriptions") {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(groups) { group in
                                    if group.id != groups.first?.id {
                                        Divider()
                                    }
                                    subscriptionHeader(group)
                                    if state.isExpanded(group.id) {
                                        if group.connections.isEmpty {
                                            Text("No portals yet. Update this subscription to import them.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .padding(.leading, 24)
                                                .padding(.vertical, 8)
                                        }
                                        ForEach(group.connections) { connection in
                                            connectionRow(connection)
                                                .padding(.leading, 24)
                                            if connection.id != group.connections.last?.id {
                                                Divider()
                                                    .padding(.leading, 24)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, -7)
                        }
                    }
                }
                .formStyle(.grouped)
                // Match General's net top inset without reserving space above the scroll view.
                .padding(.top, -4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItem(id: "portals.search", placement: .primaryAction) {
                PortalsSearchControl(query: $state.query)
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add portal", systemImage: "plus") { isShowingAddSheet = true }
                    .labelStyle(.iconOnly)
                    .help("Add portal")
            }
        }
        .onAppear {
            guard !state.hasOpened else { return }
            state.hasOpened = true
            if let sourceID = viewModel.savedConnections.first(where: { $0.id == viewModel.selectedConnectionID })?.source?.subscriptionSourceID {
                state.expandedSubscriptions.insert(sourceID)
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            AddConnectionSheet(viewModel: viewModel)
                .background(SettingsDialogWindow())
        }
        .sheet(item: $editingConnection) { connection in
            EditConnectionSheet(viewModel: viewModel, connection: connection)
                .background(SettingsDialogWindow())
        }
        .sheet(item: $renamingConnection) { connection in
            RenamePortalSheet(name: connection.displayName) { name in
                viewModel.renameConnection(id: connection.id, to: name)
            }
            .background(SettingsDialogWindow())
        }
        .sheet(item: $editingSubscription) { source in
            SubscriptionSettingsSheet(source: source) { name, url, interval, filterDuplicates in
                viewModel.updateSubscriptionSettings(id: source.id, customName: name, urlString: url,
                    autoUpdateIntervalMinutes: interval, filterDuplicateImports: filterDuplicates)
            }
            .background(SettingsDialogWindow())
        }
        .sheet(item: $qrPayload) {
            QRCodeSheet(payload: $0)
                .background(SettingsDialogWindow())
        }
        .background {
            SettingsRemovalConfirmation(isPresented: Binding(
                get: { removal != nil }, set: { if !$0 { removal = nil } }
            ), title: "Remove \(removal?.title ?? "portal")?", message: removal?.message ?? "") { [removal] in
                guard let target = removal else { return }
                switch target {
                case .connection(let connection):
                    viewModel.removeConnection(id: connection.id)
                case .subscription(let source):
                    viewModel.removeSubscription(id: source.id)
                    if !viewModel.subscriptionSources.contains(where: { $0.id == source.id }) {
                        state.expandedSubscriptions.remove(source.id)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No portals", systemImage: "network")
        } description: {
            Text("Add a portal link, subscription URL, or configuration file.")
        } actions: {
            Button("Add portal…") { isShowingAddSheet = true }
                .buttonStyle(.borderedProminent)
            if !viewModel.bundledSubscriptionTitles.isEmpty {
                Button("Add community subscriptions") { viewModel.addBundledSubscriptions() }
                Text("Public servers run by anonymous third parties. Their operators can read or alter traffic sent through them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connectionRow(_ connection: SavedConnection) -> some View {
        let selected = connection.id == viewModel.selectedConnectionID
        let health = viewModel.healthCheck(for: connection)
        let ruleCount = viewModel.activeRuleCount(routingThrough: connection.id)
        return HStack(spacing: 8) {
            Button {
                viewModel.selectConnection(id: connection.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connection.displayName)
                            .fontWeight(.regular)
                            .lineLimit(1)
                        Text(connection.configuration.descriptiveSummary)
                            .font(.caption)
                            .foregroundStyle(connection.configuration.securityWarningText == nil ? Color.secondary : .orange)
                            .lineLimit(1)
                            .additionalHelp(connection.configuration.securityWarningText)
                        if !selected && ruleCount > 0 {
                            Text(ruleCount == 1 ? "1 split routing rule" : "\(ruleCount) split routing rules")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canChangeSelection && !selected)
            .accessibilityValue(selected ? "Selected" : "Not selected")

            healthLabel(connection, health: health)
                .frame(width: 100, alignment: .trailing)
                .padding(.trailing, 4)
            rowButton("Test latency", icon: "waveform.path.ecg") {
                viewModel.refreshConnectionHealth(id: connection.id)
            }
            .disabled(viewModel.isRefreshingHealth(for: connection.id) || viewModel.isQueuedHealth(for: connection.id))
            Menu {
                Button(connection.isImported ? "Rename" : "Edit", systemImage: "pencil") {
                    if connection.isImported { renamingConnection = connection }
                    else { editingConnection = connection }
                }
                shareMenu(
                    title: connection.displayName,
                    value: connection.shareableLink,
                    copyTitle: connection.configuration.protocolType == .wireguard || connection.configuration.shareExportNote != nil ? "Copy configuration" : "Copy URL",
                    exportNote: connection.configuration.shareExportNote
                )
                if !connection.isImported {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        removal = .connection(connection)
                    }
                    .disabled(viewModel.isConnectionInUse(id: connection.id))
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 20, height: 24)
            }
            .menuStyle(.borderlessButton)
            .labelStyle(.titleAndIcon)
            .background(MenuIconVisibility())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More portal actions")
            .accessibilityLabel("More actions for \(connection.displayName)")
        }
        .padding(.vertical, 7)
    }

    private func healthLabel(_ connection: SavedConnection, health: ConnectionHealthCheck) -> some View {
        let summary = viewModel.healthSummary(for: connection)
        let status = health.state == .unreachable ? "Unavailable" : health.state == .unknown
            ? (health.checkedAt != nil || health.failureSummary != nil ? "Unknown" : "Not checked")
            : summary
        return VStack(alignment: .trailing, spacing: 3) {
            if health.state == .reachable, let latency = health.latencyMilliseconds {
                Text(ConnectionLatencyFormatter.string(milliseconds: latency))
                    .monospacedDigit()
                    .foregroundStyle(.green)
            } else {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(health.state == .unreachable ? Color.red : .secondary)
            }
        }
        .lineLimit(1)
        .additionalHelp(health.state != .reachable && summary != status ? summary : nil)
        .accessibilityLabel(summary)
    }

    private func subscriptionHeader(_ group: PortalSubscriptionGroup) -> some View {
        let source = group.source
        let expanded = state.isExpanded(source.id)
        let selected = viewModel.savedConnections.first { $0.id == viewModel.selectedConnectionID && $0.source?.subscriptionSourceID == source.id }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    state.toggle(source.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(source.displayName)
                                    .fontWeight(.regular)
                                    .lineLimit(1)
                                if !expanded, let selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                        .help("Selected portal: \(selected.displayName)")
                                        .accessibilityHidden(true)
                                }
                            }
                            HStack(spacing: 8) {
                                Text(isSearching && group.connections.count != group.total
                                    ? "\(group.connections.count) of \(group.total) portals"
                                    : group.total == 1 ? "1 portal" : "\(group.total) portals")
                                if viewModel.isRefreshingSubscription(source.id) {
                                    Text("Updating…")
                                } else if let date = source.lastRefreshedAt {
                                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                                        Text("Updated \(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))")
                                            .help(date.formatted(date: .abbreviated, time: .shortened))
                                    }
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSearching)
                .accessibilityLabel("\(source.displayName), \(expanded ? "expanded" : "collapsed")")
                .accessibilityValue(selected.map { "Selected portal: \($0.displayName)" } ?? "")
                rowButton("Test all portals in subscription", icon: "waveform.path.ecg") {
                    viewModel.refreshSubscriptionHealth(id: source.id)
                }
                .disabled(viewModel.isRefreshingSubscriptionHealth(source.id) || viewModel.isQueuedSubscriptionHealth(source.id))
                Menu {
                    Button("Update", systemImage: "arrow.clockwise") {
                        viewModel.refreshSubscription(id: source.id)
                    }
                    .disabled(viewModel.isRefreshingSubscription(source.id))
                    Button("Edit", systemImage: "pencil") { editingSubscription = source }
                    shareMenu(title: source.displayName, value: source.urlString)
                    Button("Remove", systemImage: "trash", role: .destructive) { removal = .subscription(source) }
                    .disabled(viewModel.importedConnections(for: source.id).contains { viewModel.isConnectionInUse(id: $0.id) })
                } label: {
                    Image(systemName: "ellipsis").frame(width: 20, height: 24)
                }
                .menuStyle(.borderlessButton)
                .labelStyle(.titleAndIcon)
                .background(MenuIconVisibility())
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More subscription actions")
                .accessibilityLabel("More actions for \(source.displayName)")
            }
            if expanded, let error = source.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 8)
    }

    private func rowButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 20, height: 24) }
            .buttonStyle(.borderless)
            .help(title)
            .accessibilityLabel(title)
    }

    private func shareMenu(title: String, value: String, copyTitle: String = "Copy URL", exportNote: String? = nil) -> some View {
        Menu("Share", systemImage: "square.and.arrow.up") {
            Button(copyTitle, systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            .additionalHelp(exportNote)
            Button("Show QR code", systemImage: "qrcode") {
                qrPayload = QRPayload(title: title, value: value)
            }
            .disabled(exportNote != nil)
            .additionalHelp(exportNote)
        }
    }
}

private struct PortalSubscriptionGroup: Identifiable {
    let source: SubscriptionSource
    let connections: [SavedConnection]
    let total: Int
    var id: UUID { source.id }
}

private enum PortalRemoval {
    case connection(SavedConnection)
    case subscription(SubscriptionSource)

    var title: String {
        switch self {
        case .connection(let connection): return connection.displayName
        case .subscription(let source): return source.displayName
        }
    }

    var message: String {
        switch self {
        case .connection: return "This removes the saved portal from Teleport."
        case .subscription: return "This removes the subscription and all its imported portals from Teleport."
        }
    }
}

private struct RenamePortalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename portal").font(.headline)
            TextField("Portal name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(name); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private extension View {
    @ViewBuilder
    func additionalHelp(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            help(text)
        } else {
            self
        }
    }
}
