import AppKit
import XCTest

@MainActor
final class AppIconSelectionOutlineTests: XCTestCase {
    func testBorderFollowsTheImageSilhouetteWithAnEvenGap() throws {
        let outline = try XCTUnwrap(AppIconSelectionOutline.make(for: diamond()))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(outline.border.tiffRepresentation)))
        let scale = CGFloat(bitmap.pixelsWide) / 82
        func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))!.alphaComponent
        }

        // Sample each diagonal, along its normal. A rounded rectangle cannot
        // follow this image, and would miss these border pixels entirely.
        for (x, y, nx, ny): (CGFloat, CGFloat, CGFloat, CGFloat) in [
            (23, 23, -1, -1), (23, 59, -1, 1),
            (59, 23, 1, -1), (59, 59, 1, 1),
        ] {
            let normal = sqrt(CGFloat(0.5))
            XCTAssertGreaterThan(alpha(x + nx * normal * 4, y + ny * normal * 4), 0.5)
            XCTAssertLessThan(alpha(x + nx * normal, y + ny * normal), 0.05)
            XCTAssertLessThan(alpha(x + nx * normal * 8, y + ny * normal * 8), 0.05)
        }
        XCTAssertLessThan(alpha(41, 41), 0.05)
    }

    func testSelectionFillSharesTheOutlineSilhouette() throws {
        let outline = try XCTUnwrap(AppIconSelectionOutline.make(for: diamond()))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(outline.fill.tiffRepresentation)))
        XCTAssertGreaterThan(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.alphaComponent, 0.95)
        XCTAssertLessThan(bitmap.colorAt(x: 10, y: 10)!.alphaComponent, 0.05)
    }

    private func diamond() -> NSImage {
        NSImage(size: NSSize(width: 72, height: 72), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 36, y: 0))
            path.line(to: NSPoint(x: 72, y: 36))
            path.line(to: NSPoint(x: 36, y: 72))
            path.line(to: NSPoint(x: 0, y: 36))
            path.close()
            NSColor.white.setFill()
            path.fill()
            return true
        }
    }
}
