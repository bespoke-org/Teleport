import AppKit
import SwiftUI

struct TunnelSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isShowingProfilesPopover = false
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
                targetSettings
                    .padding(.vertical, 8)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                    .listRowBackground(Color.clear)
            }
            .listSectionSeparator(.hidden)

            if viewModel.selectedTunnelTarget == nil {
                ContentUnavailableView("Add a subscription or portal", systemImage: InterfaceSymbol.portal,
                    description: Text("Its routing settings will appear here."))
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
                .listSectionSeparator(.hidden)

                GeodataSettingsView(viewModel: viewModel, horizontalInset: horizontalInset)

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

    private var targetSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    targetMenu
                    Spacer(minLength: 12)
                    if viewModel.selectedTunnelTarget != nil { profileControls }
                }
                VStack(alignment: .leading, spacing: 10) {
                    targetMenu
                    if viewModel.selectedTunnelTarget != nil { profileControls }
                }
            }
            if let profile = viewModel.selectedSplitTunnelProfile, !viewModel.inheritsSubscriptionTunnel {
                let users = viewModel.tunnelProfileUsers(id: profile.id)
                if users.count > 1 {
                    Label("Personal profile shared by \(users.count) tunnels", systemImage: InterfaceSymbol.routing)
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Changes apply to: " + users.joined(separator: ", "))
                }
            }
        }
    }

    private var targetMenu: some View {
        GlassSelectionPicker(
            options: targetOptions,
            selectedID: viewModel.selectedTunnelTarget?.id,
            onSelect: { id in
                if let target = viewModel.tunnelTargets.first(where: { $0.id == id }) {
                    viewModel.selectTunnelTarget(target)
                }
            }
        ) {
            HStack(spacing: 8) {
                Image(systemName: viewModel.selectedTunnelTarget.map(targetIcon) ?? InterfaceSymbol.portal)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(selectedTargetName)
                    .font(.headline)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(TunnelScopeGlass())
        .disabled(viewModel.tunnelTargets.isEmpty)
        .accessibilityLabel("Configure routing for")
        .accessibilityValue(selectedTargetDescription)
        .help(selectedTargetDescription)
    }

    private var targetOptions: [GlassSelectionOption] {
        viewModel.tunnelTargets.map { target in
            GlassSelectionOption(id: target.id, title: viewModel.tunnelTargetName(target),
                                 systemImage: targetIcon(target), section: targetSection(target))
        }
    }

    private var selectedTargetDescription: String {
        guard let target = viewModel.selectedTunnelTarget else { return selectedTargetName }
        return targetSection(target) + ": " + selectedTargetName
    }

    private var profileControls: some View {
        HStack(spacing: 8) {
            GlassSelectionPicker(
                options: profileOptions,
                selectedID: viewModel.inheritsSubscriptionTunnel ? "inherit" : viewModel.selectedSplitTunnelProfileID?.uuidString,
                onSelect: { id in
                    if id == "inherit" { viewModel.setInheritsSubscriptionTunnel(true) }
                    else if let profileID = UUID(uuidString: id) { viewModel.selectSplitTunnelProfile(id: profileID) }
                }
            ) {
                HStack(spacing: 8) {
                    Text(viewModel.inheritsSubscriptionTunnel
                        ? "Inherited"
                        : "Personal: " + (viewModel.selectedSplitTunnelProfile?.name ?? "Select profile"))
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .modifier(TunnelScopeGlass())
            .accessibilityLabel("Routing settings source")
            Button { isShowingProfilesPopover.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(TunnelScopeGlass(isCircular: true))
            .help("Manage personal profiles")
            .accessibilityLabel("Manage profiles")
            .popover(isPresented: $isShowingProfilesPopover, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                TunnelProfilesPopover(viewModel: viewModel)
                    .modifier(SettingsGlassPopoverSurface())
                    .presentationBackground(.clear)
            }
        }
    }

    private var profileOptions: [GlassSelectionOption] {
        var options: [GlassSelectionOption] = []
        if case .subscription = viewModel.selectedTunnelTarget {
            options.append(GlassSelectionOption(id: "inherit", title: viewModel.providerTunnelProfile == nil
                ? "No subscription profile available" : "Inherit from subscription", systemImage: InterfaceSymbol.inheritedProfile,
                isEnabled: viewModel.providerTunnelProfile != nil))
        }
        options += viewModel.personalTunnelProfiles.map { profile in
            GlassSelectionOption(id: profile.id.uuidString, title: profile.name, systemImage: InterfaceSymbol.tunnelProfile,
                                 section: "Personal profiles")
        }
        return options
    }

    private var selectedTargetName: String {
        viewModel.selectedTunnelTarget.map(viewModel.tunnelTargetName) ?? "Select subscription or portal"
    }

    private func targetIcon(_ target: TunnelTarget) -> String {
        switch target {
        case .subscription: return InterfaceSymbol.subscription
        case .connection: return InterfaceSymbol.portal
        }
    }

    private func targetSection(_ target: TunnelTarget) -> String {
        switch target {
        case .subscription: "Subscriptions"
        case .connection: "Standalone portals"
        }
    }

    private var providerSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let profile = viewModel.providerTunnelProfile {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Inherited from subscription", systemImage: InterfaceSymbol.inheritedProfile)
                            .font(.headline)
                        Text(profile.isRoutingEnabled
                            ? "\(profile.rules.count) rules · Unmatched: \(profile.defaultAction.displayName)"
                            : "All traffic via proxy")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Create personal copy", systemImage: "doc.on.doc") {
                        viewModel.customizeTunnelProfile()
                    }
                    .buttonStyle(.borderless)
                    .help("Create an editable copy. The original keeps updating with the subscription.")
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
                if case let .subscription(id) = viewModel.selectedTunnelTarget,
                   let notice = viewModel.subscriptionSources.first(where: { $0.id == id })?.lastError {
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

/// Glass identifies the context and its actions; the editor keeps quiet surfaces.
private struct TunnelScopeGlass: ViewModifier {
    var isCircular = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if isCircular {
                content.glassEffect(.regular.interactive(), in: Circle())
            } else {
                content.glassEffect(.regular.interactive(), in: Capsule())
            }
        } else {
            if isCircular {
                content.background(.regularMaterial, in: Circle())
            } else {
                content.background(.regularMaterial, in: Capsule())
            }
        }
    }
}
