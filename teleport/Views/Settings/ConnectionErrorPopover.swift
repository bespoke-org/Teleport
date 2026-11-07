import AppKit
import SwiftUI

/// Diagnostics presented by the connection control without moving the portal list.
struct ConnectionErrorPopover: View {
    let error: ConnectionFailure
    let onDismiss: () -> Void
    @State private var showsDetails = false
    @State private var showsRecovery = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(error.briefSummary)
                    .font(.callout)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(error.briefSummary)
                if let instructions = error.recoveryInstructions {
                    DisclosureGroup("How to fix", isExpanded: $showsRecovery) {
                        ScrollView {
                            Text(instructions)
                                .font(.caption)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 100)
                    }
                    .font(.caption)
                }
                if let details = error.details, !details.isEmpty, details != error.summary {
                    DisclosureGroup("Technical details", isExpanded: $showsDetails) {
                        ScrollView {
                            Text(details)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    }
                    .font(.caption)
                }
                Button("Copy error") {
                    let text = [error.summary, error.details].compactMap { $0 }.joined(separator: "\n\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss connection error")
            .accessibilityLabel("Dismiss connection error")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: error) { _, _ in
            showsDetails = false
            showsRecovery = false
        }
    }
}

/// Observe connection failures without invalidating the settings navigation shell.
struct ConnectionErrorBanner: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        if let error = viewModel.connectionError {
            ConnectionErrorPopover(error: error, onDismiss: viewModel.dismissConnectionError)
                .background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
        }
    }
}
