import SwiftUI

struct QRPayload: Identifiable {
    let id = UUID()
    let title: String
    let value: String
}

struct ShareMenuPayload: Equatable {
    let title: String
    let value: String
}

struct ShareActionPopover: View {
    let copyTitle: String
    var exportNote: String? = nil
    let onCopy: () -> Void
    let onShowQR: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let exportNote {
                Text(exportNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
            }
            Button {
                onCopy()
            } label: {
                Label(copyTitle, systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                onShowQR()
            } label: {
                Label("Show QR", systemImage: "qrcode")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(exportNote != nil)
        }
        .padding(10)
        .frame(width: exportNote == nil ? 180 : 260)
    }
}
