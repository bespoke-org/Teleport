import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var navigation = SettingsNavigation()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var portalsState = PortalsState()
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(SettingsSection.sidebarSections, selection: Binding<SettingsSection?>(
                get: { navigation.section.sidebarSection },
                set: { section in
                    if let section { navigation.select(section) }
                }
            )) { section in
                Button {
                    navigation.select(section)
                } label: {
                    Label {
                        Text(section.title)
                    } icon: {
                        SettingsSectionIcon(section: section)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tag(section as SettingsSection?)
            }
            .listStyle(.sidebar)
            .frame(minWidth: SettingsSidebarLayout.sidebarWidth, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(SettingsSidebarLayout.sidebarWidth)
            .background(SettingsSidebarLayout())
        } detail: {
            selectedSectionView
                .frame(minWidth: SettingsSidebarLayout.minimumDetailWidth)
                .padding(.top, navigation.section == .portals || navigation.section == .splitTunneling ? 0 : 16)
                .navigationTitle(navigation.section.title)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button("Back", systemImage: "chevron.left") {
                        navigation.goBack()
                    }
                    .labelStyle(.iconOnly)
                    .help("Back")
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!navigation.canGoBack)

                    Button("Forward", systemImage: "chevron.right") {
                        navigation.goForward()
                    }
                    .labelStyle(.iconOnly)
                    .help("Forward")
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!navigation.canGoForward)
                }
                .controlGroupStyle(.navigation)
            }
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .focusedSceneValue(\.settingsNavigation, $navigation)
        .navigationSplitViewStyle(.balanced)
        .frame(minHeight: SettingsSidebarLayout.minimumContentSize.height)
    }

    @ViewBuilder
    private var selectedSectionView: some View {
        switch navigation.section {
        case .general:
            GeneralSettingsView(viewModel: viewModel)
        case .portals:
            PortalsSettingsView(viewModel: viewModel, state: $portalsState)
        case .splitTunneling:
            SplitTunnelingSettingsView(viewModel: viewModel, onOpenGeodata: { navigation.select(.geodata) })
        case .geodata:
            GeodataSettingsView(viewModel: viewModel)
        case .advanced:
            AdvancedSettingsView(viewModel: viewModel, onOpenLogs: { navigation.select(.logs) })
        case .logs:
            LogsSettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}

struct SettingsSectionIcon: View {
    let section: SettingsSection

    private var image: Image {
        if section == .portals {
            return Image(nsImage: MenuBarIconImageFactory.image(
                for: .running, proxyPhase: .disabled, frame: 0, isAnimated: false
            ))
            .renderingMode(.template)
        }
        // Sidebar labels override a SwiftUI symbol's font weight. Configure the
        // native image first so the glasses keep their thicker frames.
        if section == .advanced,
           let symbol = NSImage(systemSymbolName: section.systemImage, accessibilityDescription: nil)?
               .withSymbolConfiguration(.init(pointSize: 13, weight: .heavy)) {
            return Image(nsImage: symbol).renderingMode(.template)
        }
        return Image(systemName: section.systemImage)
    }

    private var iconSize: CGFloat {
        switch section {
        case .advanced: return 20
        case .portals: return 15
        default: return 13
        }
    }

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .symbolVariant(.none)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: iconSize, height: iconSize)
            .offset(x: section == .portals ? -1 : 0)
            .frame(width: 20, height: 20)
            .background(section.iconColor.gradient, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
            .accessibilityHidden(true)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section {
                Picker(
                    selection: Binding(
                        get: { viewModel.connectionMode },
                        set: { viewModel.selectConnectionMode($0) }
                    )
                ) {
                    ForEach(ConnectionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    Text("Connection mode")
                    Text(modeDescription(for: viewModel.connectionMode))
                }
                .pickerStyle(.menu)
                .disabled(!viewModel.canChangeSelection || viewModel.hasActiveConnectionSession)

                Toggle(
                    isOn: Binding(
                        get: { viewModel.isLeakGuardEnabled },
                        set: { viewModel.setLeakGuardEnabled($0) }
                    )
                ) {
                    Text("Protect traffic during tunnel interruptions")
                    Text(viewModel.connectionMode == .tun
                        ? "Blocks apps from using your regular internet connection while the tunnel reconnects. Local network access and DNS remain available."
                        : "Available in TUN mode.")
                }
                .disabled(viewModel.connectionMode != .tun)
                .help("If a hotel or airport sign-in page will not load, temporarily turn off tunnel protection.")
            } header: {
                Text("Connection")
            } footer: {
                if let restriction = modeRestriction {
                    Text(restriction)
                }
            }

            Section("Menu bar and Dock") {
                Toggle(
                    isOn: Binding(
                        get: { viewModel.showsInDock },
                        set: { viewModel.setShowsInDock($0) }
                    )
                ) {
                    Text("Show Teleport in Dock")
                    Text("Takes effect when Settings closes.")
                }

                Toggle(
                    "Animate menu bar icon",
                    isOn: Binding(
                        get: { viewModel.animatesMenuBarIcon },
                        set: { viewModel.setAnimatesMenuBarIcon($0) }
                    )
                )

                Toggle(
                    "Show portal latency",
                    isOn: Binding(
                        get: { viewModel.showsLatencyInMenuBarPicker },
                        set: { viewModel.setShowsLatencyInMenuBarPicker($0) }
                    )
                )

                Picker(
                    selection: Binding(
                        get: { viewModel.subscriptionConnectionSort },
                        set: { viewModel.selectSubscriptionConnectionSort($0) }
                    )
                ) {
                    ForEach(SubscriptionConnectionSort.allCases) { sort in
                        Text(sort.displayName).tag(sort)
                    }
                } label: {
                    Text("Portal order")
                }
                .pickerStyle(.menu)
            }

            Section("Startup") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { viewModel.startsAtLogin },
                        set: { viewModel.setStartsAtLogin($0) }
                    )
                )

                Toggle(
                    isOn: Binding(
                        get: { viewModel.connectsOnLaunch },
                        set: { viewModel.setConnectsOnLaunch($0) }
                    )
                ) {
                    Text("Connect on launch")
                    Text("Uses the selected portal and mode.")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, -20)
        .navigationTitle("General")
        .onAppear {
            viewModel.refreshStartsAtLoginStatus()
            viewModel.refreshHelperInstallationStatus()
        }
    }

    private func modeDescription(for mode: ConnectionMode) -> String {
        switch mode {
        case .systemProxy:
            return "Routes apps that use macOS proxy settings."
        case .tun:
            if !viewModel.isHelperInstalled {
                return "Routes device traffic with split routing exceptions. The first connection requires administrator approval to install a helper."
            }
            return "Routes device traffic with split routing exceptions."
        }
    }

    private var modeRestriction: String? {
        if viewModel.connectionPhase == .failed || viewModel.proxyPhase == .failed {
            return "Click Disconnect in the menu bar to clear the failed session before changing mode."
        }
        if viewModel.hasActiveConnectionSession {
            return "Disconnect to change mode."
        }
        if !viewModel.canChangeSelection {
            return "Connection mode is temporarily unavailable."
        }
        return nil
    }
}

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case portals
    case splitTunneling
    case geodata
    case advanced
    case logs
    case about

    var id: Self { self }

    static var sidebarSections: [Self] { allCases.filter { $0 != .logs && $0 != .geodata } }

    var sidebarSection: Self {
        switch self {
        case .logs: return .advanced
        case .geodata: return .splitTunneling
        default: return self
        }
    }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .portals:
            return "Portals"
        case .splitTunneling:
            return "Split Routing"
        case .geodata:
            return "Geodata"
        case .advanced:
            return "Nerd Shit"
        case .logs:
            return "Logs"
        case .about:
            return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .portals:
            return "oval.portrait"
        case .splitTunneling:
            return "arrow.triangle.branch"
        case .geodata:
            return "globe"
        case .advanced:
            return "eyeglasses"
        case .logs:
            return "terminal"
        case .about:
            return "info.circle"
        }
    }

    var iconColor: Color {
        switch self {
        case .general:
            return .gray
        case .portals:
            return Color(red: 143.0 / 255, green: 76.0 / 255, blue: 219.0 / 255)
        case .splitTunneling, .geodata:
            return Color(red: 50.0 / 255, green: 184.0 / 255, blue: 83.0 / 255)
        case .advanced:
            return .orange
        case .logs:
            return .blue
        case .about:
            return .blue
        }
    }
}

#Preview {
    SettingsView(viewModel: AppViewModel())
}
