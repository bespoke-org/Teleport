import SwiftUI

/// Matches the value and circular chevrons of a picker in a grouped settings Form.
struct SettingsValueMenu<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 20, height: 20)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .background(MenuIconVisibility())
    }
}
