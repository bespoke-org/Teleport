import SwiftUI

struct SettingsChoice<Value: Hashable> {
    let value: Value
    let title: String
    var section: String?
}

/// Compact value selection for longer lists. Short choices use inline segments.
struct SettingsChoicePicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [SettingsChoice<Value>]
    var font: Font = .body

    var body: some View {
        GlassSelectionPicker(
            options: choices.enumerated().map { index, choice in
                GlassSelectionOption(id: String(index), title: choice.title, section: choice.section)
            },
            selectedID: choices.firstIndex { $0.value == selection }.map(String.init),
            onSelect: { id in
                guard let index = Int(id), choices.indices.contains(index) else { return }
                guard choices[index].value != selection else { return }
                selection = choices[index].value
            }
        ) {
            HStack(spacing: 7) {
                Text(title).font(font).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
    }
}
