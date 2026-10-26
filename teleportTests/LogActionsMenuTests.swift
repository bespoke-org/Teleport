import AppKit
import XCTest

@MainActor
final class LogActionsMenuTests: XCTestCase {
    func testOpenMenuKeepsTitlesImagesAndActionsAcrossRefreshes() throws {
        let button = LogActionsMenu.MenuButton(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        var copied = ""
        button.items = [
            .init(title: "Copy", symbol: "doc.on.doc") { copied = "original output" },
            .init(title: "Save to file…", symbol: "square.and.arrow.down") {},
            .init(title: "Show in Finder", symbol: "folder") {}
        ]
        let menu = button.makeMenu()
        button.items = [.init(title: "Copy", symbol: "doc.on.doc") { copied = "refreshed output" }]
        XCTAssertEqual(menu.items.map(\.title), ["Copy", "Save to file…", "Show in Finder"])
        XCTAssertTrue(menu.items.allSatisfy { $0.image != nil && !$0.isSeparatorItem })
        if #available(macOS 27.0, *) {
            for item in menu.items {
                // Query the public property dynamically so the test also builds with older SDKs.
                XCTAssertEqual(item.value(forKey: "preferredImageVisibility") as? Int, 1)
            }
        }
        let copy = try XCTUnwrap(menu.items.first)
        _ = button.perform(try XCTUnwrap(copy.action), with: copy)
        XCTAssertEqual(copied, "original output")
        let refreshedCopy = try XCTUnwrap(button.makeMenu().items.first)
        _ = button.perform(try XCTUnwrap(refreshedCopy.action), with: refreshedCopy)
        XCTAssertEqual(copied, "refreshed output")
    }

    func testEmptyOutputActionsStayDisabled() {
        let button = LogActionsMenu.MenuButton()
        button.items = [
            .init(title: "Copy", symbol: "doc.on.doc", isEnabled: false) {},
            .init(title: "Show in Finder", symbol: "folder") {}
        ]
        let menu = button.makeMenu()
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[1].isEnabled)
    }

    func testHitAreaIncludesCircleEdges() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        let button = LogActionsMenu.MenuButton(frame: parent.bounds)
        parent.addSubview(button)
        XCTAssertEqual(button.intrinsicContentSize, NSSize(width: 36, height: 36))
        for point in [NSPoint(x: 2, y: 18), NSPoint(x: 34, y: 18), NSPoint(x: 18, y: 2), NSPoint(x: 18, y: 34)] {
            XCTAssertTrue(parent.hitTest(point) === button, "Miss at \(point)")
        }
    }
}
