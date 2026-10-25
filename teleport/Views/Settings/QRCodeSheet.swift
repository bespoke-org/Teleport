import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct QRPayload: Identifiable {
    let id = UUID()
    let title: String
    let value: String
}

struct QRCodeSheet: View {
    @Environment(\.dismiss) private var dismiss

    let payload: QRPayload

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            Text(payload.title)
                .font(.headline)
                .multilineTextAlignment(.center)

            if let image = qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.white)
                    )
            } else {
                ContentUnavailableView("QR unavailable", systemImage: "qrcode")
            }

            HStack {
                Spacer()

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload.value, forType: .string)
                }

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var qrImage: NSImage? {
        filter.message = Data(payload.value.utf8)

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height))
    }
}
