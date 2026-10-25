import AppKit
import SwiftUI

struct LogSourcePicker: NSViewRepresentable {
    @Binding var selection: SettingsLogFile

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.setAccessibilityLabel("Source")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Logs"))
        for source in SettingsLogFile.logs {
            menu.addItem(sourceItem(source))
        }
        menu.addItem(.sectionHeader(title: "Configurations"))
        menu.addItem(sourceItem(.tunConfig))
        button.menu = menu
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectSource(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        button.select(button.itemArray.first { ($0.representedObject as? String) == selection.rawValue })
    }

    private func sourceItem(_ source: SettingsLogFile) -> NSMenuItem {
        let item = NSMenuItem(title: source.title, action: nil, keyEquivalent: "")
        item.representedObject = source.rawValue
        return item
    }

    final class Coordinator: NSObject {
        var selection: Binding<SettingsLogFile>

        init(selection: Binding<SettingsLogFile>) { self.selection = selection }

        @objc func selectSource(_ button: NSPopUpButton) {
            guard let rawValue = button.selectedItem?.representedObject as? String,
                  let source = SettingsLogFile(rawValue: rawValue) else { return }
            selection.wrappedValue = source
        }
    }
}
