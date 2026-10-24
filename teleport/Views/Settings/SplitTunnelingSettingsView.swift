import SwiftUI

struct SplitTunnelingSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    var onOpenGeodata: () -> Void = {}
    @State private var newRuleValue = ""
    @State private var newRuleAction: SplitTunnelRuleAction = .direct
    /// `nil` means the session's default connection.
    @State private var newRuleConnectionID: UUID?
    @State private var addRuleErrorMessage: String?
    @State private var testerValue = ""
    @State private var isShowingProfilesSheet = false

    var body: some View {
        // One scroll view for the whole pane. A List mixed with non-scrolling
        // siblings in a VStack reported an unbounded ideal width that collapsed
        // the split view's sidebar, and a grouped Form fixed that — but a Form on
        // macOS does not honor `.onMove`, so the rules could not be reordered.
        // A List holding every section keeps the single scroll view and gets
        // drag-to-reorder back; the Connections tab lives in the same pane the
        // same way.
        List {
            Section {
                Toggle(
                    isOn: Binding(
                        get: { viewModel.isSplitTunnelEnabled },
                        set: { viewModel.setSplitTunnelEnabled($0) }
                    )
                ) {
                    Text("Split tunneling")
                    Text("Route specific domains or IP/CIDR ranges directly, through the proxy, or block them, while TUN mode is active. This matches destinations, not individual apps — macOS has no supported per-app TUN routing outside managed (MDM) configurations.")
                }

                if viewModel.connectionMode != .tun {
                    Label(
                        "Split tunneling is configured here but only applies in TUN mode. System Proxy mode ignores these rules.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            profileSection
            defaultActionSection
            addRuleSection
            rulesSection
            testerSection
        }
        .listStyle(.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Split Tunneling")
        .sheet(isPresented: $isShowingProfilesSheet) {
            SplitTunnelProfilesSheet(viewModel: viewModel)
        }
    }

    private var profileSection: some View {
        Section {
            Picker(
                "Profile",
                selection: Binding(
                    get: { viewModel.selectedSplitTunnelProfileID ?? viewModel.splitTunnelProfiles.first?.id },
                    set: { newID in
                        if let newID {
                            viewModel.selectSplitTunnelProfile(id: newID)
                        }
                    }
                )
            ) {
                ForEach(viewModel.splitTunnelProfiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }

            Button("Manage Profiles…", systemImage: "gearshape") {
                isShowingProfilesSheet = true
            }
        }
    }

    private var defaultActionSection: some View {
        Section {
            Picker(
                selection: Binding(
                    get: { viewModel.splitTunnelDefaultAction == .direct ? SplitTunnelRuleAction.direct : .proxy },
                    set: { viewModel.setSplitTunnelDefaultAction($0) }
                )
            ) {
                Text(SplitTunnelRuleAction.proxy.displayName).tag(SplitTunnelRuleAction.proxy)
                Text(SplitTunnelRuleAction.direct.displayName).tag(SplitTunnelRuleAction.direct)
            } label: {
                Text("Unmatched traffic")
                Text(viewModel.splitTunnelDefaultAction == .direct
                    ? "Whitelist mode: only destinations matched below use the proxy; everything else stays direct."
                    : "Everything not matched below goes through the proxy; add rules to send specific destinations direct.")
            }
        }
    }

    private var addRuleSection: some View {
        Section {
            TextField(
                "Domain, IP/CIDR, geosite:category, or geoip:category — paste a list to add several at once",
                text: $newRuleValue,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1 ... 6)
            .onSubmit(addRule)

            // The action picker and Add button only matter once there is something
            // to add; showing them for an empty field invites clicks that do nothing.
            if !newRuleValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Picker("Action", selection: $newRuleAction) {
                    ForEach(SplitTunnelRuleAction.allCases) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .pickerStyle(.segmented)

                if newRuleAction == .proxy, viewModel.savedConnections.count > 1 {
                    // A labeled form row, like Action above it: the bare picker read
                    // as a stray control with no idea what it selected.
                    connectionPicker(
                        selection: Binding(
                            get: { newRuleConnectionID },
                            set: { newRuleConnectionID = $0 }
                        ),
                        label: "Connection"
                    )
                }

                if let addRuleErrorMessage {
                    Text(addRuleErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("Add", action: addRule)
                        .keyboardShortcut(.defaultAction)
                }
            }
        } header: {
            Text("Add rule")
        } footer: {
            HStack(spacing: 4) {
                Text("Match whole categories with geosite:name or geoip:name (e.g. geosite:google, geoip:private).")
                Button("Manage geodata", action: onOpenGeodata)
                    .buttonStyle(.link)
            }
        }
    }

    private var rulesSection: some View {
        Section {
            if viewModel.splitTunnelRules.isEmpty {
                Text("No rules yet — add a domain, IP/CIDR, or geosite category above.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.splitTunnelRules) { rule in
                    ruleRow(rule)
                }
                .onMove { offsets, destination in
                    viewModel.moveSplitTunnelRules(fromOffsets: offsets, toOffset: destination)
                }
            }
        } header: {
            Text("Rules")
        } footer: {
            Text("Rules are evaluated top to bottom; the first match wins. Drag to reorder.")
        }
    }

    private var testerSection: some View {
        Section {
            LabeledContent {
                TextField("Destination", text: $testerValue, prompt: Text("maps.google.com or 10.0.0.5"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            } label: {
                Label("Destination", systemImage: "magnifyingglass")
            }

            if testerValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Type a domain or IP. The matching rule and its action appear here as you type.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                if viewModel.hasEnabledSplitTunnelGeodataRules, !viewModel.isSplitTunnelGeodataReady {
                    Label(
                        "Loading geosite/geoip data for the tester…",
                        systemImage: "hourglass"
                    )
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }

                if let match = viewModel.matchingSplitTunnelRule(for: testerValue) {
                    if viewModel.connectionMode != .tun {
                        Label(
                            "Would match \"\(displayValue(match))\" → \(match.action.displayName), but System Proxy mode ignores split tunneling",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .font(.caption)
                    } else if viewModel.isSplitTunnelEnabled {
                        Label(
                            "Matches \"\(displayValue(match))\" → \(match.action.displayName)",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        .font(.caption)
                    } else {
                        Label(
                            "Would match \"\(displayValue(match))\" → \(match.action.displayName), but split tunneling is off",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .font(.caption)
                    }
                } else {
                    Label(
                        "No rule matches — uses default: \(viewModel.splitTunnelDefaultAction.displayName)",
                        systemImage: "arrow.triangle.branch"
                    )
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }

                Text("Domain rules apply when Xray can sniff the server name (TLS, HTTP, QUIC); other flows are matched by IP rules only.")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
        } header: {
            Text("Test a domain or IP")
        }
    }

    private func ruleRow(_ rule: SplitTunnelRule) -> some View {
        HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { rule.isEnabled },
                    set: { viewModel.setSplitTunnelRuleEnabled(id: rule.id, isEnabled: $0) }
                )
            )
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(displayValue(rule))
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(kindLabel(rule.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(rule.isEnabled ? 1 : 0.45)

            Spacer()

            Picker(
                "",
                selection: Binding(
                    get: { rule.action },
                    set: { viewModel.setSplitTunnelRuleAction(id: rule.id, action: $0) }
                )
            ) {
                ForEach(SplitTunnelRuleAction.allCases) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)
            .opacity(rule.isEnabled ? 1 : 0.45)

            if rule.action == .proxy, viewModel.savedConnections.count > 1 {
                connectionPicker(
                    selection: Binding(
                        get: { rule.connectionID },
                        set: { viewModel.setSplitTunnelRuleConnection(id: rule.id, connectionID: $0) }
                    )
                )
                .frame(width: 150)
                .opacity(rule.isEnabled ? 1 : 0.45)
            }

            Button(role: .destructive) {
                viewModel.removeSplitTunnelRule(id: rule.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    /// Every saved connection can be picked here: choosing one is what puts it in
    /// the session, so there is nothing to enable elsewhere first. The default
    /// entry means "whatever connection is selected", which is how rules written
    /// before this existed behave.
    @ViewBuilder
    private func connectionPicker(selection: Binding<UUID?>, label: String? = nil) -> some View {
        Picker(label ?? "Connection", selection: selection) {
            // The unassigned entry is simply the selected connection by name: it is
            // the one the rule follows, and naming the mechanism instead of the
            // connection told the reader nothing.
            Text(viewModel.selectedConnection?.displayName ?? "Selected connection")
                .tag(UUID?.none)
            ForEach(viewModel.savedConnections.filter { $0.id != viewModel.selectedConnectionID }) { connection in
                Text(connection.displayName)
                    .tag(Optional(connection.id))
            }
            // A rule can outlive the connection it named (a removed subscription
            // entry, say). Keep an entry for it so the picker shows the rule's real
            // state instead of an empty selection; the config falls back to the
            // selected connection until it is repointed.
            if let missingConnectionID = selection.wrappedValue,
               !viewModel.savedConnections.contains(where: { $0.id == missingConnectionID }) {
                Text("Unavailable connection").tag(Optional(missingConnectionID))
            }
        }
        // The rules list has its own columns and no room for a repeated label.
        .modifier(HiddenLabel(isHidden: label == nil))
    }

    /// A domain rule only accepts the ASCII form, which is what Xray matches; it
    /// is shown readable.
    private func displayValue(_ rule: SplitTunnelRule) -> String {
        guard rule.kind == .domain else { return rule.value }
        let prefix = rule.value.hasPrefix("full:") ? "full:" : ""
        return prefix + DisplayHostname.unicode(String(rule.value.dropFirst(prefix.count)))
    }

    private func kindLabel(_ kind: SplitTunnelRuleKind) -> String {
        switch kind {
        case .domain: return "Domain"
        case .ip: return "IP/CIDR"
        case .geosite: return "Geosite"
        case .geoip: return "GeoIP"
        }
    }

    private func addRule() {
        let candidates = newRuleValue
            .components(separatedBy: CharacterSet(charactersIn: "\n\r,"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard candidates.count > 1 else {
            // Single entry: keep the exact typed/pasted value (including any
            // leading/trailing content the user may still be editing) rather
            // than the split-and-trimmed form used for bulk pasted lists.
            let result = viewModel.addSplitTunnelRule(value: newRuleValue, action: newRuleAction, connectionID: newRuleConnectionID)
            switch result {
            case .success:
                newRuleValue = ""
                addRuleErrorMessage = nil
            case let .failure(error):
                addRuleErrorMessage = error.errorDescription
            }
            return
        }

        // Bulk add: pasting a newline- or comma-separated list adds one rule per
        // entry, skipping invalid ones instead of rejecting the whole paste.
        var failures: [String] = []
        for candidate in candidates {
            if case let .failure(error) = viewModel.addSplitTunnelRule(value: candidate, action: newRuleAction, connectionID: newRuleConnectionID) {
                failures.append("\(candidate) (\(error.errorDescription ?? "invalid"))")
            }
        }

        if failures.isEmpty {
            newRuleValue = ""
            addRuleErrorMessage = nil
        } else {
            newRuleValue = ""
            addRuleErrorMessage = "Skipped \(failures.count) invalid entr\(failures.count == 1 ? "y" : "ies"): " + failures.joined(separator: ", ")
        }
    }
}

/// `labelsHidden()` takes no condition, so hiding a label conditionally needs a
/// modifier of its own.
private struct HiddenLabel: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        if isHidden {
            content.labelsHidden()
        } else {
            content
        }
    }
}
