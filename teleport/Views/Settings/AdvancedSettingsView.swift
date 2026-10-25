import SwiftUI

struct AdvancedSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isConfirmingHelperUninstall = false

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
                    Button(viewModel.isUninstallingHelper ? "Uninstalling..." : "Uninstall...") {
                        isConfirmingHelperUninstall = true
                    }
                    .fixedSize()
                    // Allowed while connected: the uninstall disconnects first.
                    .disabled(!viewModel.isHelperInstalled || viewModel.isUninstallingHelper || viewModel.isOperationPending)
                }
                .confirmationDialog(
                    "Uninstall Teleport's privileged helper?",
                    isPresented: $isConfirmingHelperUninstall,
                    titleVisibility: .visible
                ) {
                    Button("Uninstall", role: .destructive) {
                        viewModel.uninstallHelper()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Any running session is disconnected first. The helper's LaunchDaemon, its Xray copy, its state and log under /Library and /var, and its packet filter rules are removed. Your portals and settings stay. TUN mode asks for administrator approval to install the helper again on the next connect; System Proxy mode is not affected.")
                }
            } header: {
                Text("Maintenance")
            } footer: {
                if let message = viewModel.helperUninstallMessage {
                    Text(message)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, -20)
        .navigationTitle("Advanced")
        .onAppear {
            viewModel.refreshHelperInstallationStatus()
        }
    }

    private var helperDescription: String {
        if !viewModel.isHelperInstalled {
            return "Required for TUN mode. Teleport asks for administrator approval to install it when you connect in TUN mode."
        }
        return "Required for TUN mode. Removing it requires administrator approval; Teleport reinstalls it when you next connect in TUN mode."
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

