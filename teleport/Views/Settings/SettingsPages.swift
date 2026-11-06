import SwiftUI

/// Retain visited sidebar pages so switching back does not rebuild their native controls.
/// Nested pages stay transient, including Logs whose refresh task must stop on departure.
struct SettingsPages<Content: View>: View {
    let selection: SettingsSection
    @ViewBuilder let content: (SettingsSection) -> Content
    @State private var visited: Set<SettingsSection> = []

    var body: some View {
        ZStack {
            ForEach(SettingsSection.sidebarSections) { section in
                if selection == section || visited.contains(section) {
                    content(section)
                        .opacity(selection == section ? 1 : 0)
                        .allowsHitTesting(selection == section)
                        .accessibilityHidden(selection != section)
                        .disabled(selection != section)
                        .onAppear { visited.insert(section) }
                }
            }
            if !SettingsSection.sidebarSections.contains(selection) {
                content(selection)
                    .id(selection)
            }
        }
    }
}
