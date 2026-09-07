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
        // A grouped Form is the idiomatic container for a NavigationSplitView
        // detail pane (see the General/Geodata tabs). A raw VStack wrapping a
        // greedy List reports an unbounded ideal width that makes the balanced
        // split view collapse the sidebar, so everything here lives in Form
        // sections instead — including the reorderable rules list.
        Form {
            Section {
                Toggle(
                    isOn: Binding(
                        get: { viewModel.isSplitTunnelEnabled },
                        set: { viewModel.setSplitTunnelEnabled($0) }
                    )
                ) {
                    Text("Split tunneling")
                    Text("Route specific domains or IP/CIDR ranges directly, through the proxy, or block them, while VPN mode is active. This matches destinations, not individual apps — macOS has no supported per-app VPN routing outside managed (MDM) configurations.")
                }

                if viewModel.connectionMode != .vpn {
                    Label(
                        "Split tunneling is configured here but only applies in VPN mode. System Proxy mode ignores these rules.",
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
        .formStyle(.grouped)
        .padding(.top, -20)
        .padding(.leading, -8)
        .padding(.trailing, -6)
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
                    if viewModel.connectionMode != .vpn {
                        Label(
                            "Would match \"\(match.value)\" → \(match.action.displayName), but System Proxy mode ignores split tunneling",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .font(.caption)
                    } else if viewModel.isSplitTunnelEnabled {
                        Label(
                            "Matches \"\(match.value)\" → \(match.action.displayName)",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        .font(.caption)
                    } else {
                        Label(
                            "Would match \"\(match.value)\" → \(match.action.displayName), but split tunneling is off",
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
                Text(rule.value)
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

            // Only proxy rules choose a connection, but the slot is kept for every
            // row so the action pickers and delete buttons stay in one column
            // instead of shifting from row to row.
            if viewModel.savedConnections.count > 1 {
                Group {
                    if rule.action == .proxy {
                        connectionPicker(
                            selection: Binding(
                                get: { rule.connectionID },
                                set: { viewModel.setSplitTunnelRuleConnection(id: rule.id, connectionID: $0) }
                            )
                        )
                    } else {
                        Color.clear
                    }
                }
                // Leading, not centered: a picker centred in a fixed column makes
                // every row's connection name start at a different x.
                .frame(width: 150, alignment: .leading)
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
