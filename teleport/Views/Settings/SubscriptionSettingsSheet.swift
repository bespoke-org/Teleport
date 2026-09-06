import SwiftUI

struct SubscriptionSettingsSheet: View {
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
                    .font(.subheadline.weight(.semibold))

                TextField("Custom name", text: $customName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Subscription URL")
                    .font(.subheadline.weight(.semibold))

                TextField("https://subscription…", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Auto update")
                    .font(.subheadline.weight(.semibold))

                Picker("Auto update interval", selection: $selectedIntervalMinutes) {
                    ForEach(intervalOptions, id: \.self) { option in
                        Text(intervalLabel(option)).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }

            Toggle("Filter duplicate configs", isOn: $filterDuplicateImports)

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Save") {
                    onSave(customName, urlString, selectedIntervalMinutes, filterDuplicateImports)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
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
