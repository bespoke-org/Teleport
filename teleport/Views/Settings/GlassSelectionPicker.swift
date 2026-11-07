import SwiftUI

struct GlassSelectionOption: Identifiable {
    let id: String
    let title: String
    var systemImage: String?
    var section: String?
    var isEnabled = true
}

/// An anchored selection surface with the same material as its glass control.
/// Native Menu uses its own menu-window material instead of the label's glass.
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
                .presentationBackground(.clear)
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
    @FocusState private var hasKeyboardFocus: Bool

    private var height: CGFloat {
        let sections = Set(options.compactMap(\.section)).count
        return min(CGFloat(options.count * 38 + sections * 25), 320)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        if let section = option.section,
                           index == 0 || options[index - 1].section != section {
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
            .modifier(SettingsGlassPopoverSurface())
            .focusable()
            .focusEffectDisabled()
            .focused($hasKeyboardFocus)
            .onAppear {
                hasKeyboardFocus = true
                highlightedID = options.first { $0.id == selectedID && $0.isEnabled }?.id
                    ?? options.first { $0.isEnabled }?.id
                if let highlightedID { proxy.scrollTo(highlightedID) }
            }
            .onChange(of: highlightedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onMoveCommand { direction in
                guard direction == .up || direction == .down else { return }
                let enabled = options.filter(\.isEnabled)
                guard !enabled.isEmpty else { return }
                let current = enabled.firstIndex { $0.id == highlightedID } ?? 0
                let step = direction == .up ? -1 : 1
                highlightedID = enabled[(current + step + enabled.count) % enabled.count].id
            }
            .onKeyPress(.return) {
                guard let option = options.first(where: { $0.id == highlightedID && $0.isEnabled }) else { return .ignored }
                onSelect(option.id)
                return .handled
            }
            .onExitCommand(perform: onDismiss)
        }
    }

    private func optionButton(_ option: GlassSelectionOption) -> some View {
        Button { onSelect(option.id) } label: {
            HStack(spacing: 9) {
                if let systemImage = option.systemImage {
                    Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 18)
                        .accessibilityHidden(true)
                }
                Text(option.title)
                    .fontWeight(option.id == selectedID ? .semibold : .regular)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background {
                if option.id == selectedID {
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
        .accessibilityAddTraits(option.id == selectedID ? .isSelected : [])
    }
}

struct SettingsGlassPopoverSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}
