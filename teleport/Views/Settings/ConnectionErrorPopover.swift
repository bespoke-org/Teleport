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
            .help("Dismiss error")
            .accessibilityLabel("Dismiss error")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: error) { _, _ in
            showsDetails = false
            showsRecovery = false
        }
    }
}

/// Stays available after the diagnostic is dismissed, while Connect retries.
struct LeakGuardRecoveryControl: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        if viewModel.canAllowDirectTraffic {
            VStack(alignment: .leading, spacing: 6) {
                Text("Leak guard may still be blocking direct traffic.")
                    .font(.caption)
                Button("Allow direct traffic", action: viewModel.allowDirectTraffic)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}
