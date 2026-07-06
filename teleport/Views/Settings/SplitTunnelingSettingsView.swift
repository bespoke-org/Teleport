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
        VStack(alignment: .leading, spacing: 14) {
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

            profileSection

            addRuleSection

            if viewModel.splitTunnelRules.isEmpty {
                ContentUnavailableView(
                    "No split-tunnel rules",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Add a domain, IP/CIDR, or geosite category rule above.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.splitTunnelRules) { rule in
                        ruleRow(rule)
                    }
                    .onMove { offsets, destination in
                        viewModel.moveSplitTunnelRules(fromOffsets: offsets, toOffset: destination)
                    }
                }
                .listStyle(.inset)
            }

            testerSection
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $isShowingProfilesSheet) {
            SplitTunnelProfilesSheet(viewModel: viewModel)
        }
    }

    private var profileSection: some View {
        HStack(spacing: 10) {
            Text("Profile")
                .font(.subheadline.weight(.medium))

            Picker(
                "",
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
            .labelsHidden()
            .frame(maxWidth: 220)

            Button("Manage Profiles…", systemImage: "gearshape") {
                isShowingProfilesSheet = true
            }

            Spacer()
        }
    }

    private var testerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Test a domain or IP")
                .font(.subheadline.weight(.medium))

            TextField("e.g. maps.google.com or 10.0.0.5", text: $testerValue)
                .textFieldStyle(.roundedBorder)

            if !testerValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                        "No rule matches — uses default proxy behavior",
                        systemImage: "arrow.triangle.branch"
                    )
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }

                if SplitTunnelRuleMatcher.hasUntestableGeodataRules(in: viewModel.splitTunnelRules) {
                    Label(
                        "Geosite/geoip category rules are resolved by Xray and can't be checked here.",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
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
        .padding(.vertical, 2)
    }

    private var addRuleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add new rule")
                .font(.subheadline.weight(.medium))

            HStack(alignment: .top, spacing: 10) {
                TextField("Domain, IP/CIDR, geosite:category, or geoip:category — paste a list to add several at once", text: $newRuleValue, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 6)
                    .onSubmit(addRule)

                Picker("", selection: $newRuleAction) {
                    ForEach(SplitTunnelRuleAction.allCases) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)

                Button("Add", action: addRule)
                    .disabled(newRuleValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let addRuleErrorMessage {
                Text(addRuleErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 4) {
                Text("Match whole categories with geosite:name or geoip:name (e.g. geosite:google, geoip:private).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Manage geodata", action: onOpenGeodata)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.top, 2)
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
