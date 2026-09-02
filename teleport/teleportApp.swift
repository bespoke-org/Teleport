//
//  TeleportApp.swift
//  teleport
//
//  Created by Michael Chernigin on 21.04.2026.
//

import AppKit
import SwiftUI

final class TeleportAppDelegate: NSObject, NSApplicationDelegate {
    var cleanupHandler: ((@escaping () -> Void) -> Void)?
    private var isTerminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let cleanupHandler else { return .terminateNow }
        guard !isTerminationPending else { return .terminateLater }

        isTerminationPending = true
        cleanupHandler {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct TeleportApp: App {
    @NSApplicationDelegateAdaptor(TeleportAppDelegate.self) private var appDelegate
    @StateObject private var viewModel: AppViewModel

    init() {
        let viewModel = AppViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)
        appDelegate.cleanupHandler = { completion in
            viewModel.handleAppTermination(completion: completion)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            MenuBarIconView(
                phase: viewModel.connectionPhase,
                proxyPhase: viewModel.proxyPhase,
                animates: viewModel.animatesMenuBarIcon
            )
            .frame(width: 18, height: 18)
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
    }
}
