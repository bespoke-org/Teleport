import SwiftUI

/// Draws one neutral selection instead of combining SwiftUI and AppKit highlights.
struct SettingsSidebar: View {
    @Binding var navigation: SettingsNavigation
    @State private var query = ""
    @State private var searchSelection: String?
    @State private var searchFocused = false
    @State private var searchFocusRequest = 0
    @FocusState private var focus: Focus?

    private enum Focus: Hashable {
        case result(String)
    }

    private var results: [SettingsSearchResult] { SettingsSearch.results(for: query) }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 8) {
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 8)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(results) { result in
                        resultButton(result)
                    }
                    if results.isEmpty {
                        Text("No settings found")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .onMoveCommand(perform: moveSelection)
        }
        .frame(minWidth: SettingsSidebarLayout.sidebarWidth, maxHeight: .infinity)
        .navigationSplitViewColumnWidth(SettingsSidebarLayout.sidebarWidth)
        .background(SettingsSidebarLayout())
        .onChange(of: query) { searchSelection = nil }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            SettingsSearchField(
                text: $query, isFocused: $searchFocused, focusRequest: searchFocusRequest,
                onMove: moveSearchSelection,
                onSubmit: {
                    if let result = results.first(where: { $0.id == searchSelection }) ?? results.first { open(result) }
                }
            )
            .frame(height: 16)
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocusRequest += 1
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(searchFocused ? 0.15 : 0), lineWidth: 1)
        }
    }

    private func resultButton(_ result: SettingsSearchResult) -> some View {
        let selected = isSearching ? searchSelection == result.id : navigation.section.sidebarSection == result.section
        return Button {
            open(result)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                SettingsSectionIcon(section: result.section)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).foregroundStyle(.primary)
                    if isSearching, let subtitle = result.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, isSearching ? 6 : 0)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(selected ? 0.08 : 0))
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focus, equals: .result(result.id))
        .focusEffectDisabled()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func open(_ result: SettingsSearchResult) {
        searchSelection = result.id
        navigation.select(result.section)
        focus = .result(result.id)
    }

    private func moveSearchSelection(_ direction: MoveCommandDirection) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex(where: { $0.id == searchSelection })
        switch direction {
        case .down: searchSelection = results[min((current ?? -1) + 1, results.count - 1)].id
        case .up: searchSelection = current.flatMap { $0 > 0 ? results[$0 - 1].id : nil }
        default: break
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { focus == .result($0.id) } ?? 0
        let next: Int
        switch direction {
        case .up:
            if index == 0 {
                searchFocusRequest += 1
                return
            }
            next = index - 1
        case .down: next = min(results.count - 1, index + 1)
        default: return
        }
        open(results[next])
    }
}
