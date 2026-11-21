import AppKit
import SwiftUI
import QuartzCore
import XCTest

@MainActor
final class MenuBarControllerTests: XCTestCase {
    func testCompositorAdvancesMasksWithoutChangingButtonImage() async throws {
        _ = NSApplication.shared
        let controller = MenuBarController(autosaveName: nil, onShowSettings: { _ in })
        defer { controller.stop() }
        let button = try XCTUnwrap(controller.statusItem.button)
        let target = button.target
        let action = button.action
        let state = MenuBarIconAnimator.State(phase: .running, proxyPhase: .enabled, animates: true)
        controller.animator.update(state)
        let view = try XCTUnwrap(controller.animator.animationView)
        let animation = try XCTUnwrap(view.maskLayer.animation(forKey: MenuBarAnimationView.animationKey) as? CAKeyframeAnimation)
        XCTAssertEqual(animation.duration, 4.5)
        XCTAssertEqual(animation.calculationMode, .discrete)
        XCTAssertEqual(animation.repeatCount, .infinity)
        let frames = try XCTUnwrap(animation.values as? [CGImage])
        XCTAssertEqual(frames.count, 37)
        XCTAssertEqual(animation.keyTimes?.count, 37)
        XCTAssertEqual(animation.keyTimes?.last, 1)
        XCTAssertEqual(frames[0].width, 36)
        XCTAssertEqual(frames[0].height, 36)
        XCTAssertNotEqual(frames[0].dataProvider?.data as Data?, frames[1].dataProvider?.data as Data?)
        XCTAssertTrue(frames[0] === frames.last)
        let placeholder = try XCTUnwrap(button.image)
        XCTAssertTrue(placeholder.isTemplate)
        XCTAssertEqual(placeholder.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(button.accessibilityLabel(), "Teleport connected")
        var imageChanges = 0
        let observation = button.observe(\.image) { _, _ in
            MainActor.assumeIsolated { imageChanges += 1 }
        }
        defer { observation.invalidate() }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(imageChanges, 0, "Animation must not trigger the expensive NSStatusBarButton.image setter")
        XCTAssertTrue(button.image === placeholder)
        controller.animator.update(state)
        XCTAssertTrue(controller.animator.animationView === view, "Unchanged state must not restart animation")
        XCTAssertTrue(controller.statusItem.button === button)
        XCTAssertTrue(button.target === target)
        XCTAssertEqual(button.action, action)
        XCTAssertNil(view.hitTest(NSPoint(x: view.bounds.midX, y: view.bounds.midY)))
    }

    func testDisablingAnimationAndDisconnectingRemoveCompositorWork() throws {
        _ = NSApplication.shared
        let controller = MenuBarController(autosaveName: nil, onShowSettings: { _ in })
        defer { controller.stop() }
        let button = try XCTUnwrap(controller.statusItem.button)
        controller.animator.update(.init(phase: .running, proxyPhase: .enabled, animates: true))
        let view = try XCTUnwrap(controller.animator.animationView)
        controller.animator.update(.init(phase: .running, proxyPhase: .enabled, animates: false))
        XCTAssertNil(view.maskLayer.animationKeys())
        XCTAssertNil(view.superview)
        XCTAssertNil(controller.animator.animationView)
        let still = try XCTUnwrap(button.image)
        XCTAssertFalse(still === MenuBarIconImageFactory.placeholder)
        XCTAssertEqual(still.representations.compactMap { ($0 as? NSBitmapImageRep)?.pixelsWide }, [18, 36])

        controller.animator.update(.init(phase: .running, proxyPhase: .enabled, animates: true))
        XCTAssertNotNil(controller.animator.animationView)
        controller.animator.update(.init(phase: .stopped, proxyPhase: .disabled, animates: true))
        XCTAssertNil(controller.animator.animationView)
        XCTAssertEqual(button.accessibilityLabel(), "Teleport")
        XCTAssertFalse(button.image === still)
        controller.animator.update(.init(phase: .starting, proxyPhase: .enabling, animates: true))
        XCTAssertNil(controller.animator.animationView, "Static transition outlines need no compositor animation")
    }

    func testAnimatedIconFollowsAppearanceAndHighlight() throws {
        _ = NSApplication.shared
        let button = NSStatusBarButton()
        let view = try XCTUnwrap(MenuBarAnimationView(button: button, phase: .running, proxyPhase: .enabled))
        defer { view.stop() }
        view.appearance = NSAppearance(named: .aqua)
        view.viewDidChangeEffectiveAppearance()
        let light = try XCTUnwrap(view.iconLayer.backgroundColor)
        view.appearance = NSAppearance(named: .darkAqua)
        view.viewDidChangeEffectiveAppearance()
        let dark = try XCTUnwrap(view.iconLayer.backgroundColor)
        XCTAssertNotEqual(light, dark)
        view.appearance = NSAppearance(named: .aqua)
        view.viewDidChangeEffectiveAppearance()
        // Drive AppKit's pre-draw callback for each button state without a live menu bar.
        button.highlight(true)
        view.viewWillDraw()
        XCTAssertNotEqual(view.iconLayer.backgroundColor, light)
        button.highlight(false)
        view.viewWillDraw()
        XCTAssertEqual(view.iconLayer.backgroundColor, light)
    }

    func testPrimaryClickTogglesPopoverAndSettingsClosesIt() async throws {
        _ = NSApplication.shared
        var selected: [SettingsSection?] = []
        let controller = MenuBarController(autosaveName: nil, onShowSettings: { selected.append($0) })
        defer { controller.stop() }
        controller.animator.update(.init(phase: .running, proxyPhase: .enabled, animates: true))
        controller.popover.contentViewController = NSHostingController(rootView: Text("Menu").padding())
        // AppKit installs the status item in the menu bar on the next run-loop turn.
        try await Task.sleep(for: .milliseconds(150))
        controller.handleClick(nil)
        XCTAssertTrue(controller.popover.isShown)
        controller.handleClick(nil)
        XCTAssertFalse(controller.popover.isShown)
        controller.handleClick(nil)
        XCTAssertTrue(controller.popover.isShown)
        controller.showSettings()
        XCTAssertFalse(controller.popover.isShown)
        XCTAssertEqual(selected.count, 1)
        XCTAssertNil(selected[0], "The primary Settings action preserves the selected page")
        controller.showSettings(.general)
        XCTAssertEqual(selected.last!, .general)
    }

    func testSecondaryClicksShowContextMenuWithoutOpeningPopover() async throws {
        _ = NSApplication.shared
        let controller = MenuBarController(autosaveName: nil, onShowSettings: { _ in })
        defer { controller.stop() }
        controller.animator.update(.init(phase: .running, proxyPhase: .enabled, animates: true))
        controller.popover.contentViewController = NSHostingController(rootView: Text("Menu").padding())
        // AppKit installs the status item in the menu bar on the next run-loop turn.
        try await Task.sleep(for: .milliseconds(150))
        let button = try XCTUnwrap(controller.statusItem.button)
        let window = try XCTUnwrap(button.window)
        var trackingCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu,
                      menu === controller.contextMenu.activeMenu else { return }
                trackingCount += 1
                XCTAssertFalse(controller.popover.isShown)
                let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                    MainActor.assumeIsolated { menu.cancelTracking() }
                }
                RunLoop.main.add(timer, forMode: .common)
                RunLoop.main.add(timer, forMode: .eventTracking)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for (type, flags): (NSEvent.EventType, NSEvent.ModifierFlags) in [(.rightMouseUp, []), (.leftMouseUp, .control)] {
            controller.handleClick(nil)
            // Status-item scene installation and popover presentation can finish
            // asynchronously on a fresh test host. Wait for the observed state.
            let deadline = ContinuousClock.now + .seconds(2)
            while !controller.popover.isShown && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(controller.popover.isShown)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            controller.handleClick(event)
            XCTAssertFalse(controller.popover.isShown)
            XCTAssertNil(controller.statusItem.menu)
        }
        XCTAssertEqual(trackingCount, 2)
    }

    func testStopAndDeallocationRemoveAnimation() async throws {
        _ = NSApplication.shared
        let controller = MenuBarController(autosaveName: nil, onShowSettings: { _ in })
        controller.animator.update(.init(phase: .running, proxyPhase: .enabled, animates: true))
        let view = try XCTUnwrap(controller.animator.animationView)
        controller.stop()
        controller.stop()
        XCTAssertNil(view.maskLayer.animationKeys())
        XCTAssertNil(view.superview)
        controller.handleClick(nil)
        XCTAssertFalse(controller.popover.isShown)

        let button = NSStatusBarButton()
        var animator: MenuBarIconAnimator? = MenuBarIconAnimator(button: button)
        animator?.update(.init(phase: .running, proxyPhase: .enabled, animates: true))
        let orphaned = try XCTUnwrap(animator?.animationView)
        animator = nil
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(orphaned.maskLayer.animationKeys())
        XCTAssertNil(orphaned.superview)
    }
}
