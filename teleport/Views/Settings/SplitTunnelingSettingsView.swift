import AppKit
import SwiftUI

struct SplitTunnelingSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    var onOpenGeodata: () -> Void = {}
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
                settingsBlock
                    .padding(.vertical, 8)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset))
                    .listRowBackground(RoundedRectangle(cornerRadius: 10).fill(sectionBackground).padding(.horizontal, horizontalInset))
            }
            .listSectionSeparator(.hidden)

            Section {
                Button(action: onOpenGeodata) {
                    HStack(spacing: 12) {
                        SettingsSectionIcon(section: .geodata)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Geodata")
                            Text("Domain and IP lists used by split routing rules.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Split Routing")
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
                    Text("Profile")
                    Text("Each profile keeps its own rules. Only one is active at a time.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                SettingsValueMenu(title: viewModel.splitTunnelProfiles.first { $0.id == viewModel.selectedSplitTunnelProfileID }?.name ?? "Profile") {
                    Picker("Profile", selection: Binding(
                        get: { viewModel.selectedSplitTunnelProfileID },
                        set: { if let id = $0 { viewModel.selectSplitTunnelProfile(id: id) } }
                    )) {
                        ForEach(viewModel.splitTunnelProfiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Button("Manage profiles", systemImage: "slider.horizontal.3") { isShowingProfilesSheet = true }
                }
                .accessibilityLabel("Profile")
            }
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
