import AppKit
import SwiftUI

struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.toggleSettingsSidebar) private var toggleSidebar
    @FocusedBinding(\.settingsNavigation) private var navigation

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("Go") {
            Button("Back") {
                navigation?.goBack()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(navigation?.canGoBack != true)

            Button("Forward") {
                navigation?.goForward()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(navigation?.canGoForward != true)

            Divider()

            Button("Next Section") {
                navigation?.selectNextSidebarSection()
            }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(navigation == nil)

            Button("Previous Section") {
                navigation?.selectPreviousSidebarSection()
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(navigation == nil)
        }
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") {
                toggleSidebar?()
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(toggleSidebar == nil)
        }
    }
}

private struct SettingsSidebarToggleKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct SettingsNavigationKey: FocusedValueKey {
    typealias Value = Binding<SettingsNavigation>
}

extension FocusedValues {
    var settingsNavigation: Binding<SettingsNavigation>? {
        get { self[SettingsNavigationKey.self] }
        set { self[SettingsNavigationKey.self] = newValue }
    }

    var toggleSettingsSidebar: (() -> Void)? {
        get { self[SettingsSidebarToggleKey.self] }
        set { self[SettingsSidebarToggleKey.self] = newValue }
    }
}
