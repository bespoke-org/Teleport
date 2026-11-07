import SwiftUI

struct SubscriptionSettingsPopover: View {
    @Environment(\.dismiss) private var dismiss

    let source: SubscriptionSource
    let onSave: (String, String, Int?, Bool) -> Void

    @State private var customName: String
    @State private var urlString: String
    @State private var selectedIntervalMinutes: Int?
    @State private var filterDuplicateImports: Bool

    private let intervalOptions: [Int?] = [nil, 5, 15, 30, 60, 180, 360, 720, 1440]

    init(source: SubscriptionSource, onSave: @escaping (String, String, Int?, Bool) -> Void) {
        self.source = source
        self.onSave = onSave
        _customName = State(initialValue: source.title)
        _urlString = State(initialValue: source.urlString)
        _selectedIntervalMinutes = State(initialValue: source.autoUpdateIntervalMinutes)
        _filterDuplicateImports = State(initialValue: source.filterDuplicateImports)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Subscription settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.caption).foregroundStyle(.secondary)

                TextField("Custom name", text: $customName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Subscription URL")
                    .font(.caption).foregroundStyle(.secondary)

                TextField("https://subscription…", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
            }

            HStack {
                Label("Auto update", systemImage: "clock.arrow.circlepath")
                Spacer()
                SettingsChoicePicker(
                    title: intervalLabel(selectedIntervalMinutes), selection: $selectedIntervalMinutes,
                    choices: intervalOptions.map { SettingsChoice(value: $0, title: intervalLabel($0)) },
                    font: .callout
                )
                .accessibilityLabel("Auto update interval")
            }
            .font(.callout)

            Toggle("Skip duplicate portals", isOn: $filterDuplicateImports)
                .toggleStyle(.switch)
                .controlSize(.small)

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onSave(customName, urlString, selectedIntervalMinutes, filterDuplicateImports)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func intervalLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "Off" }
        switch minutes {
        case 5:
            return "Every 5 minutes"
        case 15:
            return "Every 15 minutes"
        case 30:
            return "Every 30 minutes"
        case 60:
            return "Every hour"
        case 180:
            return "Every 3 hours"
        case 360:
            return "Every 6 hours"
        case 720:
            return "Every 12 hours"
        case 1440:
            return "Every day"
        default:
            return "Every \(minutes) minutes"
        }
    }
}
