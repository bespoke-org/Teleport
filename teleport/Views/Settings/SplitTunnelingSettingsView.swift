import SwiftUI

struct SplitTunnelingSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    var onOpenGeodata: () -> Void = {}
    @State private var newRuleValue = ""
    @State private var newRuleAction: SplitTunnelRuleAction = .direct
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

            Picker("Action", selection: $newRuleAction) {
                ForEach(SplitTunnelRuleAction.allCases) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .pickerStyle(.segmented)

            if let addRuleErrorMessage {
                Text(addRuleErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Add", action: addRule)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newRuleValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            TextField("e.g. maps.google.com or 10.0.0.5", text: $testerValue)

            if !testerValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
            }
        } header: {
            Text("Test a domain or IP")
        } footer: {
            Text("Domain and geosite rules match the server name that Xray sniffs from TLS, HTTP, and QUIC traffic. Connections without a recognizable hostname are matched by IP and geoip rules only, so a domain match here is not a guarantee for every protocol.")
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

            Button(role: .destructive) {
                viewModel.removeSplitTunnelRule(id: rule.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
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
            let result = viewModel.addSplitTunnelRule(value: newRuleValue, action: newRuleAction)
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
            if case let .failure(error) = viewModel.addSplitTunnelRule(value: candidate, action: newRuleAction) {
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
