import AppKit
import CoreImage

/// Trace the rendered enclosure instead of approximating its corners with a rounded rectangle.
@MainActor
struct AppIconSelectionOutline {
    let border: NSImage
    let fill: NSImage

    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func make(for image: NSImage) -> AppIconSelectionOutline? {
        let scale: CGFloat = 2
        let iconSize: CGFloat = 72
        let padding: CGFloat = 5
        let lineWidth: CGFloat = 2
        let size = iconSize + padding * 2
        let canvas = CGRect(x: 0, y: 0, width: size * scale, height: size * scale)
        guard let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let bitmap = CGContext(
                data: nil, width: Int(canvas.width), height: Int(canvas.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        bitmap.interpolationQuality = .high
        bitmap.clear(canvas)
        bitmap.draw(original, in: canvas.insetBy(dx: padding * scale, dy: padding * scale))
        guard let raster = bitmap.makeImage() else { return nil }
        let silhouette = CIImage(cgImage: raster)
        let outer = silhouette.applyingFilter(
            "CIMorphologyMaximum",
            parameters: [
                kCIInputRadiusKey: padding * scale
            ])
        let inner = silhouette.applyingFilter(
            "CIMorphologyMaximum",
            parameters: [
                kCIInputRadiusKey: (padding - lineWidth) * scale
            ])
        let border = outer.applyingFilter(
            "CISourceOutCompositing",
            parameters: [
                kCIInputBackgroundImageKey: inner
            ])
        guard let borderImage = context.createCGImage(border, from: canvas),
            let fillImage = context.createCGImage(outer, from: canvas)
        else { return nil }
        let displaySize = NSSize(width: size, height: size)
        return AppIconSelectionOutline(
            border: NSImage(cgImage: borderImage, size: displaySize),
            fill: NSImage(cgImage: fillImage, size: displaySize)
        )
    }
}
