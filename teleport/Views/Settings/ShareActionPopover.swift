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
    let onCopy: () -> Void
    let onShowQR: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        }
        .padding(10)
        .frame(width: 180)
    }
}
