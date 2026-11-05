import SwiftUI

struct AppIconPicker: View {
    @ObservedObject var store: AppIconStore

    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82, maximum: 82), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(AppIcon.allCases) { icon in
                    AppIconOption(icon: icon, image: store.image(for: icon), isSelected: store.selectedIcon == icon) {
                        store.select(icon)
                    }
                }
            }
        } header: {
            Text("App icon")
        } footer: {
            if let error = store.errorMessage {
                Text(error).foregroundStyle(.red)
            }
        }
    }
}

private struct AppIconOption: View {
    let icon: AppIcon
    let image: NSImage?
    let isSelected: Bool
    let select: () -> Void
    @State private var outline: AppIconSelectionOutline?

    var body: some View {
        Button(action: select) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                }
            }
            .frame(width: 72, height: 72)
            .padding(5)
            .background {
                if isSelected, let outline {
                    Image(nsImage: outline.fill)
                        .renderingMode(.template)
                        .foregroundStyle(Color.accentColor.opacity(0.1))
                }
            }
            .overlay {
                if isSelected, let outline {
                    Image(nsImage: outline.border)
                        .renderingMode(.template)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(icon.displayName)
        .accessibilityLabel(icon.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onAppear {
            if outline == nil, let image {
                outline = AppIconSelectionOutline.make(for: image)
            }
        }
    }
}
