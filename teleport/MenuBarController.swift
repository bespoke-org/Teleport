import AppKit
import Combine

/// Owns the status button independently of SwiftUI's label snapshot machinery.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    let statusItem: NSStatusItem
    let popover = NSPopover()
    let contextMenu: MenuBarContextMenuController
    let animator: MenuBarIconAnimator
    private var stateSubscription: AnyCancellable?
    private let onShowSettings: (SettingsSection?) -> Void
    private var isStopped = false

    init(autosaveName: String? = "TeleportMenuBarItem", onShowSettings: @escaping (SettingsSection?) -> Void,
         onQuit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.onShowSettings = onShowSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        animator = MenuBarIconAnimator(button: statusItem.button!)
        contextMenu = MenuBarContextMenuController(onQuit: onQuit)
        super.init()
        statusItem.autosaveName = autosaveName
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        contextMenu.start { [weak self] section in self?.showSettings(section) }
    }

    func observe(_ viewModel: AppViewModel) {
        stateSubscription = Publishers.CombineLatest3(
            viewModel.$connectionState,
            viewModel.$savedConnections.map { !$0.isEmpty }.removeDuplicates(),
            viewModel.$animatesMenuBarIcon
        )
        .map { state, hasConfiguration, animates in
            let presentation = ConnectionPresentation(state: state, hasConfiguration: hasConfiguration)
            return MenuBarIconAnimator.State(phase: presentation.connectionPhase,
                                            proxyPhase: presentation.proxyPhase, animates: animates)
        }
        .removeDuplicates()
        .sink { [weak self] state in self?.animator.update(state) }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        handleClick(NSApp.currentEvent)
    }

    func handleClick(_ event: NSEvent?) {
        guard !isStopped else { return }
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            contextMenu.showMenu(for: statusItem)
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button, popover.contentViewController != nil {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            button.highlight(true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }

    func showSettings(_ section: SettingsSection? = nil) {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        onShowSettings(section)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        stateSubscription = nil
        animator.stop()
        contextMenu.stop()
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

@MainActor
final class MenuBarIconAnimator {
    struct State: Equatable {
        let phase: ConnectionPhase
        let proxyPhase: ProxyPhase
        let animates: Bool

        // The disconnected/transition outlines have no changing pixels.
        var shouldAnimate: Bool { animates && proxyPhase == .enabled }
    }

    private weak var button: NSStatusBarButton?
    private var state: State?
    private(set) var animationView: MenuBarAnimationView?

    init(button: NSStatusBarButton) {
        self.button = button
    }

    func update(_ state: State) {
        guard self.state != state else { return }
        stop()
        self.state = state
        guard let button else { return }
        button.setAccessibilityLabel(state.proxyPhase == .enabled ? "Teleport connected" : "Teleport")
        if state.shouldAnimate {
            // Keep the button image stable: assigning it every frame makes AppKit
            // redraw all status-item replicas, even when the image is unchanged.
            button.image = MenuBarIconImageFactory.placeholder
            if let view = MenuBarAnimationView(button: button, phase: state.phase, proxyPhase: state.proxyPhase) {
                animationView = view
                button.addSubview(view)
                return
            }
        }
        button.image = MenuBarIconImageFactory.image(for: state.phase, proxyPhase: state.proxyPhase,
                                                    frame: 0, isAnimated: false)
    }

    func stop() {
        animationView?.stop()
        animationView?.removeFromSuperview()
        animationView = nil
        state = nil
    }

    deinit {
        // The button retains its subviews; release an orphaned compositor animation
        // even if an owner forgets the normal, synchronous stop() path.
        let view = animationView
        Task { @MainActor in
            view?.stop()
            view?.removeFromSuperview()
        }
    }
}
