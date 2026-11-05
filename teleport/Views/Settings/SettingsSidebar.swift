import SwiftUI

/// Draws one neutral selection instead of combining SwiftUI and AppKit highlights.
struct SettingsSidebar: View {
    @Binding var navigation: SettingsNavigation
    @FocusState private var focusedSection: SettingsSection?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(SettingsSection.sidebarSections) { section in
                    Button {
                        navigation.select(section)
                        focusedSection = section
                    } label: {
                        Label {
                            Text(section.title).foregroundStyle(.primary)
                        } icon: {
                            SettingsSectionIcon(section: section)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(navigation.section.sidebarSection == section ? 0.08 : 0))
                        }
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($focusedSection, equals: section)
                    .focusEffectDisabled()
                    .accessibilityAddTraits(navigation.section.sidebarSection == section ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .onMoveCommand { direction in
            let sections = SettingsSection.sidebarSections
            guard let index = sections.firstIndex(of: focusedSection ?? navigation.section.sidebarSection) else { return }
            let next: Int
            switch direction {
            case .up: next = max(0, index - 1)
            case .down: next = min(sections.count - 1, index + 1)
            default: return
            }
            focusedSection = sections[next]
            navigation.select(sections[next])
        }
        .frame(minWidth: SettingsSidebarLayout.sidebarWidth, maxHeight: .infinity)
        .navigationSplitViewColumnWidth(SettingsSidebarLayout.sidebarWidth)
        .background(SettingsSidebarLayout())
    }
}
