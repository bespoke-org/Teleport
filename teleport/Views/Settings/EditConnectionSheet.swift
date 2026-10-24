import AppKit
import SwiftUI

/// Editing a saved connection is editing the text it was added from: the parser
/// is the only thing that knows what a field means, so the sheet hands the raw
/// link or `[Interface]` configuration back verbatim and re-parses on save.
/// The name lives next to the connection rather than inside that text, so it is
/// saved separately.
struct EditConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: AppViewModel
    let connection: SavedConnection

    @State private var nameDraft: String
    @State private var configurationDraft: String
    @FocusState private var isNameFieldFocused: Bool

    init(viewModel: AppViewModel, connection: SavedConnection) {
        self.viewModel = viewModel
        self.connection = connection
        _nameDraft = State(initialValue: connection.customName ?? "")
        _configurationDraft = State(initialValue: connection.configuration.rawLink)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit connection")
                .font(.headline)

            TextField("Name", text: $nameDraft, prompt: Text(connection.configuration.remarks ?? connection.displayName))
                .textFieldStyle(.roundedBorder)
                .focused($isNameFieldFocused)

            TextField("vless://, trojan://, wireguard://, or [Interface]…", text: $configurationDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .lineLimit(6...16)
                .onChange(of: configurationDraft) { _, _ in
                    if viewModel.lastError != nil {
                        viewModel.clearError()
                    }
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
                    viewModel.clearError()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            isNameFieldFocused = true
        }
    }

    private func save() {
        // The name is kept next to the connection, so it survives even when the
        // configuration text fails to parse and the sheet stays open.
        viewModel.renameConnection(id: connection.id, to: nameDraft)

        if configurationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            == connection.configuration.rawLink.trimmingCharacters(in: .whitespacesAndNewlines) {
            dismiss()
            return
        }

        if viewModel.updateConnection(id: connection.id, from: configurationDraft) {
            dismiss()
        }
    }

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

        configurationDraft = contents
    }
}
