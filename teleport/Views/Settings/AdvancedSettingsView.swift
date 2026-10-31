import SwiftUI

struct AdvancedSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    let onOpenLogs: () -> Void
    @State private var isConfirmingHelperUninstall = false
    @AppStorage(SystemStateDump.defaultsKey) private var capturesNetworkState = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("HTTP/HTTPS")
                    Spacer()
                    TextField(
                        "HTTP/HTTPS proxy port",
                        value: Binding(
                            get: { viewModel.proxyEndpoint.httpPort },
                            set: { viewModel.setProxyEndpoint(httpPort: $0) }
                        ),
                        format: .number.grouping(.never)
                    )
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.hasActiveConnectionSession)
                }

                HStack {
                    Text("SOCKS5")
                    Spacer()
                    TextField(
                        "SOCKS5 proxy port",
                        value: Binding(
                            get: { viewModel.proxyEndpoint.socksPort },
                            set: { viewModel.setProxyEndpoint(socksPort: $0) }
                        ),
                        format: .number.grouping(.never)
                    )
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.hasActiveConnectionSession)
                }
            } header: {
                Text("Local proxy ports")
            } footer: {
                Text(proxyPortsFooter)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Privileged helper")
                        Text(helperDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(viewModel.isUninstallingHelper ? "Uninstalling..." : "Uninstall") {
                        isConfirmingHelperUninstall = true
                    }
                    .fixedSize()
                    // Allowed while connected: the uninstall disconnects first.
                    .disabled(!viewModel.isHelperInstalled || viewModel.isUninstallingHelper || viewModel.isOperationPending)
                }
                .background(SettingsRemovalConfirmation(
                    isPresented: $isConfirmingHelperUninstall,
                    title: "Uninstall Teleport's privileged helper?",
                    message: "Any running session is disconnected first. The helper's LaunchDaemon, its Xray copy, its state and log under /Library and /var, and its packet filter rules are removed. Your portals and settings stay. Teleport asks for administrator approval to install the helper again on the next connect in either mode.",
                    actionTitle: "Uninstall",
                    onRemove: viewModel.uninstallHelper
                ))

            } header: {
                Text("Maintenance")
            } footer: {
                if let message = viewModel.helperUninstallMessage {
                    Text(message)
                }
            }

            Section("Diagnostics") {
                Toggle(isOn: $capturesNetworkState) {
                    Text("Capture network state")
                    Text("Records routes, DNS, firewall and proxy settings around network changes. May slow down connecting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(action: onOpenLogs) {
                    HStack(spacing: 12) {
                        SettingsSectionIcon(section: .logs)
                        Text("Logs")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
        .padding(.top, -20)
        .navigationTitle("Nerd Shit")
        .onAppear {
            viewModel.refreshHelperInstallationStatus()
        }
    }

    private var helperDescription: String {
        if !viewModel.isHelperInstalled {
            return "Required for system proxy settings and TUN routing. Teleport asks for administrator approval to install it on the first connection."
        }
        return "Used by both connection modes. Removing it requires administrator approval; Teleport reinstalls it when you next connect."
    }

    private var proxyPortsFooter: String {
        if viewModel.connectionPhase == .failed || viewModel.proxyPhase == .failed {
            return "Ports are locked because the last connection attempt failed. Click Disconnect in the menu bar to clear the error, then change ports."
        }
        if viewModel.hasActiveConnectionSession {
            return "Disconnect before changing ports. Teleport listens on 127.0.0.1."
        }
        return "Teleport listens on 127.0.0.1."
    }
}

