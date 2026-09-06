import AppKit
import SwiftUI

struct AddConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: AppViewModel
    @State private var draftLink = ""
    @FocusState private var isLinkFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add connection")
                .font(.headline)

            Text("Paste a VLESS, Trojan, WireGuard, or subscription link, or a WireGuard configuration.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("vless://, trojan://, wireguard://, https://subscription…, or [Interface]…", text: $draftLink, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .lineLimit(3...12)
                .focused($isLinkFieldFocused)
                .onChange(of: draftLink) { _, _ in
                    if viewModel.lastError != nil {
                        viewModel.clearError()
                    }
                }
                .onSubmit {
                    submit()
                }

            if let error = viewModel.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Import file…") {
                    importConfigurationFile()
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Add") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            isLinkFieldFocused = true
        }
    }

    private func submit() {
        if viewModel.addConnection(from: draftLink) {
            dismiss()
        }
    }

    /// WireGuard peers are handed out as `.conf` files, so importing one is just a
    /// different way of filling the same field: the text stays visible and editable
    /// before it is parsed.
    private func importConfigurationFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a WireGuard configuration file"

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            viewModel.reportImportFailure("That file is not readable as text")
            return
        }

        draftLink = contents
        isLinkFieldFocused = true
    }
}
