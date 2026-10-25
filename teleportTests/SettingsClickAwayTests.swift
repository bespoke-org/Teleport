import AppKit
import XCTest

@MainActor
final class SettingsClickAwayTests: XCTestCase {
    func testClicksInsideRowsAndActionBarPreserveSelectionButOutsideClearsIt() {
        let window = makeWindow()
        defer { window.close() }
        let scope = SettingsClickAwayScope()
        let row = region(in: window, scope: scope, frame: NSRect(x: 30, y: 100, width: 300, height: 30))
        _ = region(in: window, scope: scope, frame: NSRect(x: 30, y: 70, width: 300, height: 24))
        let monitor = SettingsClickAwayMonitor.MonitorView()
        monitor.scope = scope
        monitor.isActive = true
        var isSelected = true
        monitor.onClickAway = { isSelected = false }
        window.contentView!.addSubview(monitor)
        defer { monitor.stopMonitoring() }

        monitor.handleClick(click(in: window, at: NSPoint(x: 60, y: 110)))
        XCTAssertTrue(isSelected)
        monitor.handleClick(click(in: window, at: NSPoint(x: 60, y: 80)))
        XCTAssertTrue(isSelected, "The minus button must keep its selected rule until its action runs")
        monitor.handleClick(click(in: window, at: NSPoint(x: 400, y: 110)))
        XCTAssertFalse(isSelected)

        isSelected = true
        row.isHidden = true
        monitor.handleClick(click(in: window, at: NSPoint(x: 60, y: 110)))
        XCTAssertFalse(isSelected, "Hidden regions must not preserve selection")
    }

    func testInactiveMonitorAndClicksInAnotherWindowDoNotDismiss() {
        let window = makeWindow()
        let otherWindow = makeWindow()
        defer { window.close(); otherWindow.close() }
        let monitor = SettingsClickAwayMonitor.MonitorView()
        monitor.scope = SettingsClickAwayScope()
        var dismissCount = 0
        monitor.onClickAway = { dismissCount += 1 }
        window.contentView!.addSubview(monitor)
        defer { monitor.stopMonitoring() }

        monitor.handleClick(click(in: window, at: NSPoint(x: 20, y: 20)))
        XCTAssertEqual(dismissCount, 0)
        monitor.isActive = true
        monitor.handleClick(click(in: otherWindow, at: NSPoint(x: 20, y: 20)))
        XCTAssertEqual(dismissCount, 0)
        monitor.handleClick(click(in: window, at: NSPoint(x: 20, y: 20)))
        XCTAssertEqual(dismissCount, 1)
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func region(in window: NSWindow, scope: SettingsClickAwayScope, frame: NSRect) -> NSView {
        let view = SettingsClickAwayRegion.RegionView(frame: frame)
        view.scope = scope
        window.contentView!.addSubview(view)
        return view
    }

    private func click(in window: NSWindow, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                          clickCount: 1, pressure: 1)!
    }
}
