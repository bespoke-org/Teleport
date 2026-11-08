import AppKit
import SwiftUI

struct SettingsView: View {
    // Each page observes the model itself. Connection updates should
    // not invalidate the navigation shell and all of its sidebar icons.
    let viewModel: AppViewModel
    @Binding var navigation: SettingsNavigation
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var portalsState = PortalsState()
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebar(navigation: $navigation)
        } detail: {
            detailContent
                .frame(minWidth: SettingsSidebarLayout.minimumDetailWidth)
                .padding(.top, navigation.section == .portals || navigation.section == .tunnel ? 0 : 16)
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
            // A principal item keeps page actions trailing in a SwiftUI Window.
            // Give it a real size so AppKit can measure it without warnings.
            if #available(macOS 26.0, *) {
                ToolbarItem(id: "settings.titleSpacer", placement: .principal) {
                    Color.clear.frame(width: 1, height: 1)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(id: "settings.titleSpacer", placement: .principal) {
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            SettingsErrorToolbar(viewModel: viewModel, onOpenLogs: { navigation.select(.logs) })
            PortalsToolbar(state: $portalsState, isActive: navigation.section == .portals,
                           connection: PortalsConnectionButton(viewModel: viewModel))
        }
        .focusedSceneValue(\.settingsNavigation, $navigation)
        .navigationSplitViewStyle(.balanced)
        .transaction(value: navigation.section) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .frame(minHeight: SettingsSidebarLayout.minimumContentSize.height)
    }

    private var detailContent: some View {
        SettingsPages(selection: navigation.section) { section in
            sectionView(section)
        }
        .onChange(of: navigation.section, initial: true) { _, section in
            if section == .general { viewModel.refreshStartsAtLoginStatus() }
            if section == .general || section == .advanced { viewModel.refreshHelperInstallationStatus() }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView(viewModel: viewModel)
        case .portals:
            PortalsSettingsView(viewModel: viewModel, state: $portalsState)
        case .tunnel:
            TunnelSettingsView(viewModel: viewModel)
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
            .background(section.iconGradient, in: RoundedRectangle(cornerRadius: 5))
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
                LabeledContent {
                    SettingsSegmentedPicker(title: "Connection mode", selection: Binding(
                        get: { viewModel.connectionMode }, set: viewModel.selectConnectionMode
                    ), choices: ConnectionMode.allCases.map {
                        SettingsChoice(value: $0, title: $0.displayName)
                    })
                    .frame(width: 220, height: 28)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connection mode")
                        Text(modeDescription(for: viewModel.connectionMode))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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

                LabeledContent("Portal order") {
                    SettingsSegmentedPicker(title: "Portal order", selection: Binding(
                        get: { viewModel.subscriptionConnectionSort }, set: viewModel.selectSubscriptionConnectionSort
                    ), choices: SubscriptionConnectionSort.allCases.map {
                        SettingsChoice(value: $0, title: $0.displayName)
                    })
                    .frame(width: 220, height: 28)
                }
                .help("Original follows the order in each subscription. Refresh existing subscriptions to restore their original order.")
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

            AppIconPicker(store: .shared)
        }
        .formStyle(.grouped)
        .padding(.top, -20)
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
    case tunnel
    case advanced
    case logs
    case about

    var id: Self { self }

    static var sidebarSections: [Self] { allCases.filter { $0 != .logs } }

    var sidebarSection: Self {
        switch self {
        case .logs: return .advanced
        default: return self
        }
    }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .portals:
            return "Portals"
        case .tunnel:
            return "Routing"
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
            return InterfaceSymbol.portal
        case .tunnel:
            return InterfaceSymbol.routing
        case .advanced:
            return "slider.horizontal.3"
        case .logs:
            return "doc.text.magnifyingglass"
        case .about:
            return "info.circle"
        }
    }

    var iconGradient: LinearGradient {
        let colors: [Color]
        switch self {
        case .general:
            colors = [
                Color(red: 180.0 / 255, green: 189.0 / 255, blue: 200.0 / 255),
                iconColor,
                Color(red: 98.0 / 255, green: 111.0 / 255, blue: 129.0 / 255),
            ]
        case .portals:
            colors = [
                Color(red: 217.0 / 255, green: 87.0 / 255, blue: 241.0 / 255),
                Color(red: 178.0 / 255, green: 50.0 / 255, blue: 232.0 / 255),
                Color(red: 116.0 / 255, green: 52.0 / 255, blue: 200.0 / 255),
            ]
        case .tunnel:
            colors = [
                Color(red: 103.0 / 255, green: 223.0 / 255, blue: 148.0 / 255),
                iconColor,
                Color(red: 19.0 / 255, green: 161.0 / 255, blue: 125.0 / 255),
            ]
        case .advanced:
            colors = [
                Color(red: 255.0 / 255, green: 189.0 / 255, blue: 69.0 / 255),
                iconColor,
                Color(red: 240.0 / 255, green: 106.0 / 255, blue: 61.0 / 255),
            ]
        case .logs, .about:
            colors = [
                Color(red: 102.0 / 255, green: 197.0 / 255, blue: 255.0 / 255),
                iconColor,
                Color(red: 75.0 / 255, green: 84.0 / 255, blue: 210.0 / 255),
            ]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    var iconColor: Color {
        switch self {
        case .general:
            return .gray
        case .portals:
            return Color(red: 143.0 / 255, green: 76.0 / 255, blue: 219.0 / 255)
        case .tunnel:
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
    SettingsView(viewModel: AppViewModel(), navigation: .constant(SettingsNavigation()))
}
