import SwiftUI

struct LogSourcePicker: View {
    @Binding var selection: SettingsLogFile

    var body: some View {
        SettingsChoicePicker(title: selection.title, selection: $selection,
            choices: SettingsLogFile.logs.map { SettingsChoice(value: $0, title: $0.title, section: "Logs") }
                + [SettingsChoice(value: .tunConfig, title: SettingsLogFile.tunConfig.title, section: "Configurations")],
            font: .callout)
            .accessibilityLabel("Source")
    }
}
