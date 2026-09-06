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

            Text("Paste a VLESS, Trojan, or subscription link.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("vless://, trojan://, or https://subscription…", text: $draftLink, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .lineLimit(3...6)
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
}
