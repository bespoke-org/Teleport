import AppKit
import Combine

enum AppIcon: String, CaseIterable, Identifiable {
    case graphite
    case purple
    case greenBlue
    case orange

    static let defaultIcon: AppIcon = .graphite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .purple: return "Purple"
        case .greenBlue: return "Teal & Blue"
        case .orange: return "Orange & Red"
        case .graphite: return "Graphite"
        }
    }

    func image(in bundle: Bundle = .main) -> NSImage? {
        let name: String
        switch self {
        case .purple: name = "AppIconPurple"
        case .greenBlue: name = "AppIconGreenBlue"
        case .orange: name = "AppIconOrange"
        case .graphite: name = "AppIconGraphite"
        }
        guard let url = bundle.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

@MainActor
final class AppIconStore: ObservableObject {
    static let shared = AppIconStore()
    static let defaultsKey = "appearance.appIcon"

    @Published private(set) var selectedIcon: AppIcon
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let loadImage: @MainActor (AppIcon) -> NSImage?
    private let setApplicationImage: @MainActor (NSImage?) -> Void
    private var images: [AppIcon: NSImage] = [:]

    init(
        defaults: UserDefaults = .standard,
        loadImage: @escaping @MainActor (AppIcon) -> NSImage? = { $0.image() },
        setApplicationImage: @escaping @MainActor (NSImage?) -> Void = { NSApplication.shared.applicationIconImage = $0 }
    ) {
        self.defaults = defaults
        self.loadImage = loadImage
        self.setApplicationImage = setApplicationImage
        selectedIcon = defaults.string(forKey: Self.defaultsKey).flatMap(AppIcon.init(rawValue:)) ?? AppIcon.defaultIcon
    }

    func image(for icon: AppIcon) -> NSImage? {
        if let image = images[icon] { return image }
        guard let image = loadImage(icon) else { return nil }
        images[icon] = image
        return image
    }

    func select(_ icon: AppIcon) {
        guard apply(icon) else { return }
        selectedIcon = icon
        defaults.set(icon.rawValue, forKey: Self.defaultsKey)
        errorMessage = nil
    }

    func restoreSelection() {
        if !apply(selectedIcon) {
            select(.defaultIcon)
        }
    }

    private func apply(_ icon: AppIcon) -> Bool {
        if icon == .defaultIcon {
            // Let macOS render the bundled Icon Composer icon for the default.
            setApplicationImage(nil)
            return true
        }
        guard let image = image(for: icon) else {
            errorMessage = "This icon could not be loaded. Please try reinstalling Teleport."
            return false
        }
        // Flattened Icon Composer exports fill the canvas. Unlike a native
        // app icon, applicationIconImage doesn't add the macOS grid inset.
        let dockImage = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            let inset = rect.width * 100 / 1024
            image.draw(in: rect.insetBy(dx: inset, dy: inset))
            return true
        }
        setApplicationImage(dockImage)
        return true
    }
}
