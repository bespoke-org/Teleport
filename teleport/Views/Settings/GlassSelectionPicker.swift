import SwiftUI

struct GlassSelectionOption: Identifiable {
    let id: String
    let title: String
    var systemImage: String?
    var section: String?
    var isEnabled = true
    var children: [GlassSelectionOption]?

    func containsSelection(_ selectedID: String?) -> Bool {
        id == selectedID || children?.contains { $0.containsSelection(selectedID) } == true
    }
}

/// An anchored selection surface. The native popover owns its material and arrow.
struct GlassSelectionPicker<Label: View>: View {
    let options: [GlassSelectionOption]
    let selectedID: String?
    let onSelect: (String) -> Void
    var onOpen: (() -> [GlassSelectionOption])? = nil
    @ViewBuilder var label: Label
    // The content and its presentation must change atomically. Separate state
    // for options and visibility can present the initial empty array on first click.
    private struct Presentation: Identifiable {
        let id = UUID()
        let options: [GlassSelectionOption]
        let selectedID: String?
    }
    @State private var presentation: Presentation?

    var body: some View {
        Button {
            if presentation == nil {
                presentation = Presentation(options: onOpen?() ?? options, selectedID: selectedID)
            } else {
                presentation = nil
            }
        } label: { label }
            .popover(item: $presentation, attachmentAnchor: .rect(.bounds), arrowEdge: .top) { content in
                GlassSelectionList(options: content.options, selectedID: content.selectedID) { id in
                    presentation = nil
                    onSelect(id)
                } onDismiss: {
                    presentation = nil
                }
            }
    }
}

struct GlassSelectionList: View {
    let options: [GlassSelectionOption]
    let selectedID: String?
    let onSelect: (String) -> Void
    let onDismiss: () -> Void
    @State private var hoveredID: String?
    @State private var highlightedID: String?
    @State private var path: [GlassSelectionOption] = []
    @FocusState private var hasKeyboardFocus: Bool

    private var height: CGFloat {
        func measuredHeight(_ options: [GlassSelectionOption]) -> CGFloat {
            let sections = Set(options.compactMap(\.section)).count
            let ownHeight = CGFloat(options.count * 38 + sections * 25)
            return max(ownHeight, options.compactMap(\.children).map(measuredHeight).max() ?? 0)
        }
        return min(max(measuredHeight(options), 38), 320)
    }

    private var activeOptions: [GlassSelectionOption] { path.last?.children ?? options }
    private var isHierarchical: Bool { options.contains { $0.children != nil } }

    var body: some View {
        VStack(spacing: 0) {
            if isHierarchical {
                HStack(spacing: 8) {
                    Button(action: goBack) {
                        Image(systemName: "chevron.left").frame(width: 24, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(path.isEmpty)
                    .opacity(path.isEmpty ? 0 : 1)
                    .accessibilityLabel("Back")
                    Text(path.last?.title ?? "Portals")
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.top, 8)
                Divider().padding(.top, 4)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if activeOptions.isEmpty {
                            Text("No imported portals")
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                        ForEach(Array(activeOptions.enumerated()), id: \.element.id) { index, option in
                            if let section = option.section,
                               index == 0 || activeOptions[index - 1].section != section {
                                Text(section)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.top, 6)
                            }
                            optionButton(option)
                                .id(option.id)
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.hidden)
                .frame(width: 320, height: height + 16)
                .focusable()
                .focusEffectDisabled()
                .focused($hasKeyboardFocus)
                .onAppear {
                    hasKeyboardFocus = true
                    highlightSelection()
                    if let highlightedID { proxy.scrollTo(highlightedID) }
                }
                .onChange(of: highlightedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onMoveCommand { direction in
                    if direction == .left { goBack(); return }
                    if direction == .right {
                        if let option = activeOptions.first(where: { $0.id == highlightedID && $0.children != nil }) { activate(option) }
                        return
                    }
                    guard direction == .up || direction == .down else { return }
                    let enabled = activeOptions.filter(\.isEnabled)
                    guard !enabled.isEmpty else { return }
                    let current = enabled.firstIndex { $0.id == highlightedID } ?? 0
                    let step = direction == .up ? -1 : 1
                    highlightedID = enabled[(current + step + enabled.count) % enabled.count].id
                }
                .onKeyPress(.return) {
                    guard let option = activeOptions.first(where: { $0.id == highlightedID && $0.isEnabled }) else { return .ignored }
                    activate(option)
                    return .handled
                }
                .onExitCommand(perform: onDismiss)
            }
        }
        .frame(width: 320)
    }

    private func highlightSelection() {
        highlightedID = activeOptions.first { $0.isEnabled && $0.containsSelection(selectedID) }?.id
            ?? activeOptions.first { $0.isEnabled }?.id
        hoveredID = nil
    }

    private func activate(_ option: GlassSelectionOption) {
        guard option.isEnabled else { return }
        if option.children != nil {
            path.append(option)
            highlightSelection()
        } else {
            onSelect(option.id)
        }
    }

    private func goBack() {
        guard let parent = path.popLast() else { return }
        highlightedID = parent.id
        hoveredID = nil
    }

    private func optionButton(_ option: GlassSelectionOption) -> some View {
        Button { activate(option) } label: {
            HStack(spacing: 9) {
                if let systemImage = option.systemImage {
                    Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 18)
                        .accessibilityHidden(true)
                }
                Text(option.title)
                    .fontWeight(option.containsSelection(selectedID) ? .semibold : .regular)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let children = option.children {
                    Text("\(children.count)").foregroundStyle(.secondary).monospacedDigit()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background {
                if option.containsSelection(selectedID) {
                    RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.10))
                } else if option.isEnabled && (hoveredID == option.id || highlightedID == option.id) {
                    RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.05))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!option.isEnabled)
        .opacity(option.isEnabled ? 1 : 0.45)
        .focusable(false)
        .onHover { hoveredID = $0 ? option.id : nil }
        .accessibilityAddTraits(option.containsSelection(selectedID) ? .isSelected : [])
    }
}
