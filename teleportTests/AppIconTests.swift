import AppKit
import XCTest

@MainActor
final class AppIconTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "AppIconTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testSelectionAppliesImmediatelyAndRestoresOnNextLaunch() {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        for icon in [AppIcon.purple, .greenBlue, .orange] {
            var applied: NSImage?
            let store = AppIconStore(defaults: defaults, loadImage: { _ in image }, setApplicationImage: { applied = $0 })
            store.select(icon)
            XCTAssertNotNil(applied, "Alternate icons, including purple, override the bundled graphite icon")
            XCTAssertTrue(store.image(for: icon) === image)
            XCTAssertEqual(defaults.string(forKey: AppIconStore.defaultsKey), icon.rawValue)

            applied = nil
            let relaunched = AppIconStore(defaults: defaults, loadImage: { _ in image }, setApplicationImage: { applied = $0 })
            XCTAssertEqual(relaunched.selectedIcon, icon)
            relaunched.restoreSelection()
            XCTAssertNotNil(applied)
            XCTAssertTrue(relaunched.image(for: icon) === image)

            relaunched.select(.graphite)
            XCTAssertNil(applied)
            XCTAssertEqual(relaunched.selectedIcon, .graphite)
            XCTAssertEqual(defaults.string(forKey: AppIconStore.defaultsKey), AppIcon.graphite.rawValue)
        }
    }

    func testMissingImageKeepsCurrentSelectionAndIcon() {
        var calls = 0
        let store = AppIconStore(defaults: defaults, loadImage: { _ in nil }, setApplicationImage: { _ in calls += 1 })
        store.select(.greenBlue)
        XCTAssertEqual(store.selectedIcon, .graphite)
        XCTAssertNil(defaults.string(forKey: AppIconStore.defaultsKey))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(calls, 0)
    }

    func testUnavailableSavedIconFallsBackToBundledDefault() {
        defaults.set(AppIcon.greenBlue.rawValue, forKey: AppIconStore.defaultsKey)
        var restoredDefault = false
        let store = AppIconStore(defaults: defaults, loadImage: { _ in nil }, setApplicationImage: { restoredDefault = $0 == nil })
        store.restoreSelection()
        XCTAssertEqual(store.selectedIcon, .graphite)
        XCTAssertTrue(restoredDefault)
        XCTAssertEqual(defaults.string(forKey: AppIconStore.defaultsKey), AppIcon.graphite.rawValue)
    }

    func testUnknownPreferenceUsesGraphite() {
        defaults.set("removed-variant", forKey: AppIconStore.defaultsKey)
        var restoredDefault = false
        let store = AppIconStore(defaults: defaults, setApplicationImage: { restoredDefault = $0 == nil })
        XCTAssertEqual(store.selectedIcon, .graphite)
        store.restoreSelection()
        XCTAssertTrue(restoredDefault)
    }

    func testFreshInstallUsesBundledGraphiteWithoutLoadingAnAlternateImage() {
        var loads = 0
        var restoredDefault = false
        let store = AppIconStore(
            defaults: defaults,
            loadImage: { _ in
                loads += 1
                return nil
            }, setApplicationImage: { restoredDefault = $0 == nil })
        XCTAssertEqual(store.selectedIcon, .graphite)
        store.restoreSelection()
        XCTAssertTrue(restoredDefault)
        XCTAssertEqual(loads, 0)
    }

    func testAlternateDockIconHasNativePaddingWithoutAccumulatingInsets() throws {
        let source = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            NSColor.cyan.setFill()
            rect.fill()
            return true
        }
        var applied: NSImage?
        let store = AppIconStore(defaults: defaults, loadImage: { _ in source }, setApplicationImage: { applied = $0 })

        for _ in 0..<2 {
            store.select(.greenBlue)
            let image = try XCTUnwrap(applied)
            let bitmap = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
            NSGraphicsContext.restoreGraphicsState()

            for point in [(90, 512), (934, 512), (512, 90), (512, 934)] {
                XCTAssertEqual(bitmap.colorAt(x: point.0, y: point.1)?.alphaComponent, 0)
            }
            for point in [(110, 512), (914, 512), (512, 110), (512, 914)] {
                XCTAssertEqual(bitmap.colorAt(x: point.0, y: point.1)?.alphaComponent, 1)
            }
            XCTAssertTrue(store.image(for: .greenBlue) === source, "Keep the full-size preview separate from the Dock image")
        }
    }
}
