import AppKit
import SwiftUI

struct TunnelSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var nameFocusID: UUID?
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
        // Rules participate in the page List, sharing its scrolling and native reordering.
        return List {
            Section {
                profileHeader
                    .padding(.vertical, 8)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                    .listRowBackground(Color.clear)
            }
            .listSectionSeparator(.hidden)

            if viewModel.selectedSplitTunnelProfile == nil {
                ContentUnavailableView("No routing profiles", systemImage: InterfaceSymbol.tunnelProfile,
                    description: Text("Create a profile to configure routing rules."))
            } else {
                if !viewModel.canEditTunnelProfile {
                    Section {
                        providerSummary
                            .padding(.vertical, 8)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                            .listRowBackground(RoundedRectangle(cornerRadius: 10).fill(sectionBackground).padding(.horizontal, horizontalInset))
                    }
                    .listSectionSeparator(.hidden)
                }
                Section {
                    settingsBlock
                        .disabled(!viewModel.canEditTunnelProfile)
                        .padding(.vertical, 8)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                        .listRowBackground(RoundedRectangle(cornerRadius: 10).fill(sectionBackground).padding(.horizontal, horizontalInset))
                }
                .listSectionSeparator(.hidden)

                Section {
                    sectionHeading("Rules", horizontalInset: horizontalInset)
                    ruleColumnHeadings
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                        .listRowBackground(
                            UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
                                .fill(sectionBackground).padding(.horizontal, horizontalInset)
                        )
                    if viewModel.splitTunnelRules.isEmpty {
                        Text("No rules yet")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                            .listRowBackground(sectionBackground.padding(.horizontal, horizontalInset))
                    } else {
                        ForEach(viewModel.splitTunnelRules) { rule in
                            ruleRow(rule)
                                .disabled(!viewModel.canEditTunnelProfile)
                                .moveDisabled(!viewModel.canEditTunnelProfile)
                                .foregroundStyle(.primary)
                                .padding(.vertical, 5)
                                .padding(.horizontal, 10)
                                .overlay(alignment: .bottom) {
                                    if rule.id != viewModel.splitTunnelRules.last?.id {
                                        Divider().opacity(0.35).padding(.horizontal, 10)
                                    }
                                }
                                .background(SettingsClickAwayRegion(scope: ruleClickScope))
                                .contentShape(Rectangle())
                                .onTapGesture { selectedRuleID = rule.id }
                                .accessibilityElement(children: .contain)
                                .accessibilityAddTraits(selectedRuleID == rule.id ? .isSelected : [])
                                .accessibilityAction(named: "Select rule") { selectedRuleID = rule.id }
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                                .listRowBackground(
                                    Rectangle().fill(selectedRuleID == rule.id
                                        ? Color.accentColor.opacity(0.15) : sectionBackground)
                                    .padding(.horizontal, horizontalInset)
                                )
                        }
                        .onMove { viewModel.moveSplitTunnelRules(fromOffsets: $0, toOffset: $1) }
                    }
                    if viewModel.canEditTunnelProfile {
                        ruleActions
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                        .listRowBackground(
                            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                                .fill(sectionBackground)
                                .overlay(alignment: .top) { Divider() }
                                .padding(.horizontal, horizontalInset)
                        )
                    }
                }
                .listSectionSeparator(.hidden)

                if viewModel.canEditTunnelProfile {
                    GeodataSettingsView(viewModel: viewModel, horizontalInset: horizontalInset)
                }

                Section {
                    sectionHeading("Test route", horizontalInset: horizontalInset)
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
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        // The editor starts below the toolbar, while its rows can still scroll
        // underneath the glass. Match the other settings pages' top spacing.
        .contentMargins(.top, 16, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsClickAwayMonitor(scope: ruleClickScope, isActive: selectedRuleID != nil) {
            selectedRuleID = nil
        })
        .onChange(of: viewModel.selectedSplitTunnelProfileID) { _, _ in selectedRuleID = nil }
        .onChange(of: viewModel.splitTunnelRules.map(\.id)) { _, ids in
            if let selectedRuleID, !ids.contains(selectedRuleID) { self.selectedRuleID = nil }
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
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
            .padding(.bottom, 8)
            // A regular row scrolls away; native Section headers pin in a List.
            // Compensate List's 16-point content inset to match grouped Form headings.
            .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset - 6, bottom: 0, trailing: horizontalInset))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
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
            Text("\(viewModel.splitTunnelRules.count) \(viewModel.splitTunnelRules.count == 1 ? "rule" : "rules")")
                .font(.caption)
                .padding(.trailing, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.canEditTunnelProfile ? "Editing profile" : "Viewing profile")
                        .font(.caption).foregroundStyle(.secondary)
                    if let profile = viewModel.selectedSplitTunnelProfile {
                        RoutingProfileNameField(name: profile.name, isEditable: viewModel.canEditTunnelProfile,
                                                requestsFocus: nameFocusID == profile.id,
                                                onFocus: { nameFocusID = nil }) { name in
                            viewModel.renameSplitTunnelProfile(id: profile.id, name: name)
                        }
                            .id(profile.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let profile = viewModel.selectedSplitTunnelProfile {
                let users = viewModel.tunnelProfileTargets(id: profile.id)
                if users.isEmpty {
                    Text("Not assigned. Choose this profile in a subscription or portal’s settings to use it.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    DisclosureGroup(viewModel.tunnelProfileUsageDescription(id: profile.id)) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(users) { target in
                                Label(viewModel.tunnelTargetName(target), systemImage: targetIcon(target))
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                    if viewModel.canEditTunnelProfile {
                        Text("Edits apply everywhere this profile is used. Assign profiles in Portals.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func targetIcon(_ target: TunnelTarget) -> String {
        switch target {
        case .subscription: InterfaceSymbol.subscription
        case .connection: InterfaceSymbol.portal
        }
    }

    private var providerSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let profile = viewModel.selectedSplitTunnelProfile, let sourceID = profile.subscriptionSourceID {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("From " + viewModel.tunnelTargetName(.subscription(sourceID)), systemImage: InterfaceSymbol.inheritedProfile)
                            .font(.headline)
                        Text(profile.isRoutingEnabled
                            ? "\(profile.rules.count) rules · Unmatched: \(profile.defaultAction.displayName)"
                            : "All traffic via proxy")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Create personal copy", systemImage: "doc.on.doc") {
                        viewModel.copySplitTunnelProfile(id: profile.id)
                    }
                    .buttonStyle(.borderless)
                    .help("Create an independent editable copy without changing assignments. The original keeps updating with the subscription.")
                }
                Text("Read-only. Updates with the subscription. A personal copy can be edited, but its rules will no longer follow provider updates.")
                    .font(.caption).foregroundStyle(.secondary)
                if !profile.isRoutingEnabled {
                    Text("This provider has disabled routing for its profile. Its rules are not applied even when Split routing is on. Create a personal copy to use these rules.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !viewModel.updatingSelectedProfileGeodataKinds.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("Downloading geodata…")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                } else if let error = viewModel.geodataProfileError {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button("Retry") { viewModel.downloadSelectedProfileGeodata() }
                    }
                } else {
                    let ready = GeodataKind.allCases.allSatisfy { kind in
                        switch viewModel.profileGeodataStatus(kind: kind) {
                        case .bundled, .ready: return true
                        default: return false
                        }
                    }
                    HStack {
                        Label(ready ? "Geodata ready" : "Geodata download paused", systemImage: ready ? "checkmark.circle" : "pause.circle")
                            .font(.caption).foregroundStyle(.secondary)
                        if !ready { Button("Retry") { viewModel.downloadSelectedProfileGeodata() } }
                    }
                }
                if let notice = viewModel.subscriptionSources.first(where: { $0.id == sourceID })?.lastError {
                    DisclosureGroup("Subscription notice") {
                        Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var settingsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Unmatched traffic")
                    ZStack(alignment: .topLeading) {
                        Text("Destinations that don't match a rule connect directly.")
                            .opacity(viewModel.splitTunnelDefaultAction == .direct ? 1 : 0)
                            .accessibilityHidden(viewModel.splitTunnelDefaultAction != .direct)
                        Text("Destinations that don't match a rule use the selected portal.")
                            .opacity(viewModel.splitTunnelDefaultAction == .direct ? 0 : 1)
                            .accessibilityHidden(viewModel.splitTunnelDefaultAction == .direct)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                SettingsSegmentedPicker(title: "Unmatched traffic", selection: Binding(
                    get: { viewModel.splitTunnelDefaultAction },
                    set: { viewModel.setSplitTunnelDefaultAction($0) }
                ), choices: [
                    SettingsChoice(value: SplitTunnelRuleAction.proxy, title: "Proxy"),
                    SettingsChoice(value: SplitTunnelRuleAction.direct, title: "Direct")
                ])
                .frame(width: 220, height: 28)
            }
            if viewModel.connectionMode != .tun {
                Label("Applies only in TUN mode", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var ruleColumnHeadings: some View {
        HStack(spacing: 12) {
            Text("Destination").frame(maxWidth: .infinity, alignment: .leading)
            Text("Route")
                .padding(.leading, 10)
                .frame(width: SplitTunnelRoutePicker.controlWidth, alignment: .leading)
            Text("Enabled").frame(width: 48)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().opacity(0.5).padding(.horizontal, 10) }
        .accessibilityAddTraits(.isHeader)
    }

    private func ruleRow(_ rule: SplitTunnelRule) -> some View {
        HStack(spacing: 12) {
            Text(SplitTunnelPresentation.destination(rule))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(rule.isEnabled ? 1 : 0.45)
            SplitTunnelRoutePicker(viewModel: viewModel, action: rule.action, connectionID: rule.connectionID) { action, portal in
                viewModel.setSplitTunnelRuleAction(id: rule.id, action: action)
                viewModel.setSplitTunnelRuleConnection(id: rule.id, connectionID: portal)
            }
            .opacity(rule.isEnabled ? 1 : 0.45)
            Toggle("Enable \(SplitTunnelPresentation.destination(rule))", isOn: Binding(
                get: { rule.isEnabled },
                set: { viewModel.setSplitTunnelRuleEnabled(id: rule.id, isEnabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .frame(width: 48)
        }
    }

}
