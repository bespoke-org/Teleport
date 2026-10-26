import SwiftUI

/// Diagnostics presented by the connection control without moving the portal list.
struct ConnectionErrorPopover: View {
    let error: ConnectionFailure
    let onDismiss: () -> Void
    @State private var showsDetails = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(error.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let details = error.details, !details.isEmpty, details != error.summary {
                    DisclosureGroup("Details", isExpanded: $showsDetails) {
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
        .frame(width: 280)
        .onChange(of: error) { _, _ in showsDetails = false }
    }
}
