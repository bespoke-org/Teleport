import AppKit
import SwiftUI

struct TunnelSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isShowingProfilesSheet = false
    @State private var isShowingAddSheet = false
    @State private var selectedRuleID: UUID?
    @State private var ruleClickScope = SettingsClickAwayScope()

    private let sectionBackground = Color.primary.opacity(0.035)
    // Match the card width of the grouped Forms used by the other settings pages.
    private let maximumContentWidth: CGFloat = 704

    var body: some View {
        GeometryReader { geometry in
            settingsList(horizontalInset: max(20, (geometry.size.width - maximumContentWidth) / 2))
        }
    }

    private func settingsList(horizontalInset: CGFloat) -> some View {
        let rowColors = NSColor.alternatingContentBackgroundColors
        // Keep native List reordering and one scrolling surface for the page.
        return List {
            Section {
                targetSettings
                    .padding(.vertical, 8)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                    .listRowBackground(RoundedRectangle(cornerRadius: 10).fill(sectionBackground).padding(.horizontal, horizontalInset))
            }
            .listSectionSeparator(.hidden)

            if viewModel.selectedTunnelTarget == nil {
                ContentUnavailableView("Add a subscription or portal", systemImage: "network",
                    description: Text("Its tunnel settings will appear here."))
            } else if viewModel.inheritsSubscriptionTunnel {
                Section {
                    providerSummary
                        .padding(.vertical, 8)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                        .listRowBackground(RoundedRectangle(cornerRadius: 10).fill(sectionBackground).padding(.horizontal, horizontalInset))
                }
                .listSectionSeparator(.hidden)
            } else {
                Section {
                    settingsBlock
                        .padding(.vertical, 8)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                        .listRowBackground(RoundedRectangle(cornerRadius: 10).fill(sectionBackground).padding(.horizontal, horizontalInset))
                }
                .listSectionSeparator(.hidden)

                Section {
                    if viewModel.splitTunnelRules.isEmpty {
                        Text("No rules yet")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                            .listRowBackground(
                                UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
                                    .fill(sectionBackground).padding(.horizontal, horizontalInset)
                            )
                    } else {
                        ForEach(Array(viewModel.splitTunnelRules.enumerated()), id: \.element.id) { index, rule in
                            ruleRow(rule)
                                .foregroundStyle(.primary)
                                .padding(.vertical, 5)
                                .padding(.horizontal, 10)
                                .padding(.top, index == 0 ? 10 : 0)
                                .padding(.bottom, index == viewModel.splitTunnelRules.count - 1 ? 10 : 0)
                                .background(SettingsClickAwayRegion(scope: ruleClickScope))
                                .contentShape(Rectangle())
                                .onTapGesture { selectedRuleID = rule.id }
                                .accessibilityElement(children: .contain)
                                .accessibilityAddTraits(selectedRuleID == rule.id ? .isSelected : [])
                                .accessibilityAction(named: "Select rule") { selectedRuleID = rule.id }
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                                .listRowBackground(
                                    ZStack {
                                        UnevenRoundedRectangle(
                                            topLeadingRadius: index == 0 ? 10 : 0,
                                            topTrailingRadius: index == 0 ? 10 : 0
                                        ).fill(sectionBackground)
                                        UnevenRoundedRectangle(
                                            topLeadingRadius: index == 0 ? 6 : 0,
                                            bottomLeadingRadius: index == viewModel.splitTunnelRules.count - 1 ? 6 : 0,
                                            bottomTrailingRadius: index == viewModel.splitTunnelRules.count - 1 ? 6 : 0,
                                            topTrailingRadius: index == 0 ? 6 : 0
                                        ).fill(selectedRuleID == rule.id
                                            ? Color.accentColor.opacity(0.2)
                                            : Color(nsColor: rowColors[index % rowColors.count]))
                                            .padding(.horizontal, 10)
                                            .padding(.top, index == 0 ? 10 : 0)
                                            .padding(.bottom, index == viewModel.splitTunnelRules.count - 1 ? 10 : 0)
                                    }
                                    .padding(.horizontal, horizontalInset)
                                )
                        }
                        .onMove { viewModel.moveSplitTunnelRules(fromOffsets: $0, toOffset: $1) }
                    }
                    ruleActions
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                        .listRowBackground(
                            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                                .fill(Color(nsColor: rowColors.last ?? .controlBackgroundColor))
                                .overlay(alignment: .top) { Divider() }
                                .padding(.horizontal, horizontalInset)
                        )
                } header: {
                    sectionHeading("Rules", horizontalInset: horizontalInset)
                }
                .listSectionSeparator(.hidden)

                GeodataSettingsView(viewModel: viewModel)
                    .listRowInsets(EdgeInsets(top: 6, leading: horizontalInset + 10, bottom: 6, trailing: horizontalInset + 10))

                Section {
                    SplitTunnelTester(viewModel: viewModel)
                        .padding(.vertical, 10)
                        .padding(.bottom, 20)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10).fill(sectionBackground)
                                .padding(.horizontal, horizontalInset)
                                .padding(.bottom, 20)
                        )
                } header: {
                    sectionHeading("Test route", horizontalInset: horizontalInset)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsClickAwayMonitor(scope: ruleClickScope, isActive: selectedRuleID != nil) {
            selectedRuleID = nil
        })
        .onChange(of: viewModel.selectedSplitTunnelProfileID) { _, _ in selectedRuleID = nil }
        .onChange(of: viewModel.splitTunnelRules.map(\.id)) { _, ids in
            if let selectedRuleID, !ids.contains(selectedRuleID) { self.selectedRuleID = nil }
        }
        .sheet(isPresented: $isShowingProfilesSheet) {
            SplitTunnelProfilesSheet(viewModel: viewModel)
                .background(SettingsDialogWindow())
        }
        .sheet(isPresented: $isShowingAddSheet) {
            AddSplitTunnelRulesSheet(viewModel: viewModel)
                .background(SettingsDialogWindow())
        }
    }

    private func sectionHeading(_ title: String, horizontalInset: CGFloat) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            // List adds 16 points; grouped Form headings sit 10 points inside their cards.
            .padding(.horizontal, horizontalInset - 6)
            .padding(.bottom, 4)
    }

    private var ruleActions: some View {
        HStack(spacing: 0) {
            Button {
                isShowingAddSheet = true
            } label: {
                Image(systemName: "plus").frame(width: 28, height: 24).contentShape(Rectangle())
            }
            .accessibilityLabel("Add rule")
            .help("Add rule")
            .background(SettingsClickAwayRegion(scope: ruleClickScope))
            Divider().frame(height: 14)
            Button {
                guard let selectedRuleID else { return }
                viewModel.removeSplitTunnelRule(id: selectedRuleID)
                self.selectedRuleID = nil
            } label: {
                Image(systemName: "minus").frame(width: 28, height: 24).contentShape(Rectangle())
            }
            .disabled(selectedRuleID == nil)
            .accessibilityLabel("Remove selected rule")
            .help("Remove selected rule")
            .background(SettingsClickAwayRegion(scope: ruleClickScope))
            Spacer()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var targetSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Configure tunnel for", selection: Binding(
                get: { viewModel.selectedTunnelTarget },
                set: { if let target = $0 { viewModel.selectTunnelTarget(target) } }
            )) {
                ForEach(viewModel.tunnelTargets) { target in
                    switch target {
                    case .subscription:
                        Label(viewModel.tunnelTargetName(target), systemImage: "rectangle.stack").tag(Optional(target))
                    case .connection:
                        Label(viewModel.tunnelTargetName(target), systemImage: "network").tag(Optional(target))
                    }
                }
            }
            if viewModel.selectedTunnelTarget != nil {
                if viewModel.providerTunnelProfile != nil {
                    Picker("Settings", selection: Binding(
                        get: { viewModel.inheritsSubscriptionTunnel },
                        set: { viewModel.setInheritsSubscriptionTunnel($0) }
                    )) {
                        Text("Subscription settings").tag(true)
                        Text("Personal profile").tag(false)
                    }
                    .pickerStyle(.segmented)
                } else {
                    Text("Choose a personal profile for this subscription or portal.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !viewModel.inheritsSubscriptionTunnel {
                    HStack {
                        Picker("Personal profile", selection: Binding(
                            get: { viewModel.selectedSplitTunnelProfileID },
                            set: { if let id = $0 { viewModel.selectSplitTunnelProfile(id: id) } }
                        )) {
                            ForEach(viewModel.personalTunnelProfiles) { profile in
                                Text(profile.name).tag(Optional(profile.id))
                            }
                        }
                        Button("Manage profiles") { isShowingProfilesSheet = true }
                    }
                    if let id = viewModel.selectedSplitTunnelProfileID {
                        Text("Used by: " + viewModel.tunnelProfileUsers(id: id).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var providerSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let profile = viewModel.providerTunnelProfile {
                Text(profile.name).font(.headline)
                Text(profile.isRoutingEnabled
                    ? "\(profile.rules.count) routing rules · Unmatched traffic: \(profile.defaultAction.displayName)"
                    : "All traffic uses the selected portal.")
                    .foregroundStyle(.secondary)
                Text("Rules and geodata update with this subscription.")
                    .font(.caption).foregroundStyle(.secondary)
                if case let .subscription(id) = viewModel.selectedTunnelTarget,
                   let warning = viewModel.subscriptionSources.first(where: { $0.id == id })?.lastError {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                if !viewModel.updatingGeodataKinds.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Downloading geodata…") }
                } else if let error = viewModel.geodataProfileError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Geodata ready", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                if viewModel.geodataLastAttemptSources == viewModel.selectedProfileGeodataSources,
                   let error = viewModel.geodataSettings.geositeLastError ?? viewModel.geodataSettings.geoipLastError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Button("Customize this profile") { viewModel.customizeTunnelProfile() }
                    Button("Download geodata") { viewModel.downloadSelectedProfileGeodata(forceDownload: true) }
                        .disabled(!viewModel.updatingGeodataKinds.isEmpty || viewModel.isOperationPending)
                }
                Text("Customization creates a personal copy. Subscription updates keep the original profile current.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var settingsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Split routing", isOn: Binding(
                get: { viewModel.isSplitTunnelEnabled },
                set: { viewModel.setSplitTunnelEnabled($0) }
            ))
            .toggleStyle(.switch)

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Unmatched traffic")
                    Text(viewModel.splitTunnelDefaultAction == .direct
                        ? "Destinations that don't match a rule connect directly."
                        : "Destinations that don't match a rule use the selected portal.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                SettingsValueMenu(title: viewModel.splitTunnelDefaultAction.displayName) {
                    Picker("Unmatched traffic", selection: Binding(
                        get: { viewModel.splitTunnelDefaultAction },
                        set: { viewModel.setSplitTunnelDefaultAction($0) }
                    )) {
                        Text("Proxy").tag(SplitTunnelRuleAction.proxy)
                        Text("Direct").tag(SplitTunnelRuleAction.direct)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .accessibilityLabel("Unmatched traffic")
            }
            if viewModel.connectionMode != .tun {
                Label("Applies only in TUN mode", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func ruleRow(_ rule: SplitTunnelRule) -> some View {
        HStack(spacing: 10) {
            Toggle("Enable \(SplitTunnelPresentation.destination(rule))", isOn: Binding(
                get: { rule.isEnabled },
                set: { viewModel.setSplitTunnelRuleEnabled(id: rule.id, isEnabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            Text(SplitTunnelPresentation.destination(rule))
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(rule.isEnabled ? 1 : 0.45)
            Spacer(minLength: 8)
            SplitTunnelRoutePicker(viewModel: viewModel, action: rule.action, connectionID: rule.connectionID) { action, portal in
                viewModel.setSplitTunnelRuleAction(id: rule.id, action: action)
                viewModel.setSplitTunnelRuleConnection(id: rule.id, connectionID: portal)
            }
            .opacity(rule.isEnabled ? 1 : 0.45)
        }
    }
}
