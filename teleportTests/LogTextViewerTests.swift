import AppKit
import SwiftUI
import XCTest

@MainActor
final class LogTextViewerTests: XCTestCase {
    private final class Input: ObservableObject {
        @Published var text = (0..<200).map { "Log event \($0)\n" }.joined()
        @Published var source = SettingsLogFile.app
        @Published var findID = 0
        @Published var jumpID = 0
    }
    private struct Harness: View {
        @ObservedObject var input: Input
        var body: some View {
            LogTextViewer(text: input.text, source: input.source, findID: input.findID, jumpID: input.jumpID)
        }
    }
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Native view did not finish updating")
    }
    private func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTextView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
    }
    private func visibleLine(_ text: NSTextView, _ scroll: NSScrollView) -> String {
        let layout = text.layoutManager!
        let point = NSPoint(x: 0, y: max(0, scroll.contentView.bounds.minY - text.textContainerOrigin.y))
        let glyph = layout.glyphIndex(for: point, in: text.textContainer!)
        let index = layout.characterIndexForGlyph(at: min(glyph, layout.numberOfGlyphs - 1))
        let string = text.string as NSString
        return string.substring(with: string.lineRange(for: NSRange(location: index, length: 0)))
    }

    func testLiveUpdatesPreserveReadingPositionAndSelectionWhenTailRolls() async throws {
        let input = Input()
        let host = NSHostingView(rootView: Harness(input: input))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        await settle { self.findScroll(in: host)?.documentView is NSTextView }
        let scroll = try XCTUnwrap(findScroll(in: host))
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        await settle { text.string == input.text }
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY, text.bounds.maxY - 4)

        input.text += "New latest event\n"
        await settle { text.string == input.text }
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY, text.bounds.maxY - 4)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scroll.reflectScrolledClipView(scroll.contentView)
        let line = visibleLine(text, scroll)
        let selected = (text.string as NSString).range(of: "Log event 50")
        text.setSelectedRange(selected)
        input.text += "Another event\n"
        await settle { text.string == input.text }
        XCTAssertEqual(scroll.contentView.bounds.minY, 600, accuracy: 1)
        XCTAssertEqual(text.selectedRange(), selected)

        input.text = input.text.components(separatedBy: "\n").dropFirst(10).joined(separator: "\n") + "Tail rolled\n"
        await settle { text.string == input.text }
        XCTAssertEqual(visibleLine(text, scroll), line)
        XCTAssertEqual((text.string as NSString).substring(with: text.selectedRange()), "Log event 50")
    }

    func testFindJumpAndConfigurationSourceNavigation() async throws {
        let input = Input()
        let host = NSHostingView(rootView: Harness(input: input))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        await settle { self.findScroll(in: host)?.documentView is NSTextView }
        let scroll = try XCTUnwrap(findScroll(in: host))
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        await settle { text.string == input.text }
        input.findID += 1
        await settle { scroll.isFindBarVisible }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 150))
        input.jumpID += 1
        await settle { !scroll.isFindBarVisible && scroll.contentView.bounds.maxY >= text.bounds.maxY - 4 }

        input.source = .tunConfig
        input.text = "{\n" + input.text + "}\n"
        await settle { text.string == input.text }
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
    }
}
