//
//  TeleportApp.swift
//  teleport
//
//  Created by Michael Chernigin on 21.04.2026.
//

import AppKit
import Combine
import SwiftUI

final class TeleportAppDelegate: NSObject, NSApplicationDelegate {
    let xrayVersion = XrayVersionModel()
    let mcp = TeleportMCPController()
    var cleanupHandler: ((@escaping () -> Void) -> Void)?
    private var isTerminationPending = false
    private var dockVisibilitySubscription: AnyCancellable?
    private var settingsWindowCloseSubscription: AnyCancellable?
    private weak var settingsWindow: NSWindow?
    private var showsInDock = true
    private var menuBarController: MenuBarController?

    func observeDockVisibility(of viewModel: AppViewModel) {
        dockVisibilitySubscription = viewModel.$showsInDock
            .removeDuplicates()
            .sink { [weak self] showsInDock in
                self?.showsInDock = showsInDock
            }
    }

    func configureMenuBar(viewModel: AppViewModel, onShowSettings: @escaping (SettingsSection?) -> Void) {
        guard menuBarController == nil else { return }
        let controller = MenuBarController(onShowSettings: onShowSettings)
        controller.popover.contentViewController = NSHostingController(rootView:
            MenuBarView(onShowSettings: { [weak controller] in controller?.showSettings() }, viewModel: viewModel)
        )
        controller.observe(viewModel)
        menuBarController = controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIconStore.shared.restoreSelection()
        applyDockVisibility()
        Task { await xrayVersion.load() }
    }

    func observeSettingsWindow(_ window: NSWindow) {
        guard settingsWindow !== window else { return }
        settingsWindow = window
        settingsWindowCloseSubscription = NotificationCenter.default
            .publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak self, weak window] _ in
                // Let the close finish before changing the app's activation policy.
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, !self.isTerminationPending,
                          window?.isVisible != true,
                          self.settingsWindow?.isVisible != true else { return }
                    self.applyDockVisibility()
                }
            }
    }

    private func applyDockVisibility() {
        let application = NSApplication.shared
        let policy: NSApplication.ActivationPolicy = showsInDock ? .regular : .accessory
        guard application.activationPolicy() != policy else { return }
        application.setActivationPolicy(policy)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let cleanupHandler else { return .terminateNow }
        guard !isTerminationPending else { return .terminateLater }

        isTerminationPending = true
        mcp.stop()
        cleanupHandler {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct TeleportEntryPoint {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPLocalTransport.runStdio()
        } else {
            TeleportApp.main()
        }
    }
}

struct TeleportApp: App {
    @NSApplicationDelegateAdaptor(TeleportAppDelegate.self) private var appDelegate
    @StateObject private var viewModel: AppViewModel
    @State private var settingsNavigation = SettingsNavigation()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let viewModel = AppViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)
        appDelegate.observeDockVisibility(of: viewModel)
        appDelegate.mcp.attach(to: viewModel)
        appDelegate.cleanupHandler = { completion in
            viewModel.handleAppTermination(completion: completion)
        }
    }

    var body: some Scene {
        Window("Settings", id: "settings") {
            SettingsView(viewModel: viewModel, navigation: $settingsNavigation)
                .environmentObject(appDelegate.xrayVersion)
                .environmentObject(appDelegate.mcp)
                .focusedSceneValue(\.toggleSettingsSidebar) {
                    NSApplication.shared.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                }
                .background(SettingsWindowObserver(onWindowAvailable: appDelegate.observeSettingsWindow))
        }
        .defaultLaunchBehavior(.suppressed)
        .onChange(of: scenePhase, initial: true) {
            appDelegate.configureMenuBar(viewModel: viewModel) { section in
                if let section { settingsNavigation.select(section) }
                openWindow(id: "settings")
            }
        }
        .windowResizability(.contentSize)
        .commands { SettingsCommands(settingsNavigation: $settingsNavigation) }
    }
}

private struct SettingsWindowObserver: NSViewRepresentable {
    let onWindowAvailable: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindowAvailable = onWindowAvailable
        return view
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        nsView.onWindowAvailable = onWindowAvailable
    }

    final class WindowObserverView: NSView {
        var onWindowAvailable: ((NSWindow) -> Void)?
        private var minimumSizeObservation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            minimumSizeObservation = nil
            if let window {
                // SwiftUI recalculates this when the sidebar changes. Keep the window
                // minimum independent of the split view's animated layout.
                minimumSizeObservation = window.observe(\.contentMinSize, options: [.initial, .new]) { window, _ in
                    let size = window.contentMinSize
                    let minimum = SettingsSidebarLayout.minimumContentSize
                    if size.width < minimum.width || size.height < minimum.height {
                        window.contentMinSize = NSSize(width: max(minimum.width, size.width), height: max(minimum.height, size.height))
                    }
                }
                onWindowAvailable?(window)
            }
        }
    }
}
