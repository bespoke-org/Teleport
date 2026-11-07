import SwiftUI

struct SplitTunnelRoutePicker: View {
    @ObservedObject var viewModel: AppViewModel
    let action: SplitTunnelRuleAction
    let connectionID: UUID?
    let onSelect: (SplitTunnelRuleAction, UUID?) -> Void
    @State private var isHovered = false

    static let controlWidth: CGFloat = 150

    var body: some View {
        GlassSelectionPicker(options: routeOptions, selectedID: selectedID, onSelect: { id in
            switch id {
            case "default": onSelect(.proxy, nil)
            case "direct": onSelect(.direct, nil)
            case "block": onSelect(.block, nil)
            default:
                guard let portalID = UUID(uuidString: id) else { return }
                onSelect(.proxy, portalID)
            }
        }) {
            HStack(spacing: 7) {
                Text(routeTitle)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(width: Self.controlWidth, height: 28)
            .background(.primary.opacity(isHovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Route")
        .accessibilityValue(action == .proxy ? "Proxy, " + portalTitle : routeTitle)
        .help(action == .proxy ? "Proxy through " + portalTitle : routeTitle)
    }

    private var selectedID: String {
        switch action {
        case .proxy: connectionID?.uuidString ?? "default"
        case .direct: "direct"
        case .block: "block"
        }
    }

    private var routeTitle: String {
        switch action {
        case .proxy: connectionID == nil ? "Proxy" : "Proxy · " + portalTitle
        case .direct: "Direct"
        case .block: "Block"
        }
    }

    private var routeOptions: [GlassSelectionOption] {
        [
            GlassSelectionOption(id: "default", title: "Proxy · Selected portal", systemImage: InterfaceSymbol.portal),
            GlassSelectionOption(id: "direct", title: "Direct", systemImage: InterfaceSymbol.directRoute),
            GlassSelectionOption(id: "block", title: "Block", systemImage: InterfaceSymbol.blockedRoute)
        ] + portalOptions
    }

    private var portalOptions: [GlassSelectionOption] {
        var options: [GlassSelectionOption] = []
        options += viewModel.manualConnectionPickerItems.map {
            GlassSelectionOption(id: $0.id.uuidString, title: $0.displayName, systemImage: InterfaceSymbol.portal, section: "Standalone")
        }
        for source in viewModel.subscriptionPickerItems {
            options += viewModel.importedConnectionPickerItems(for: source.id).map {
                GlassSelectionOption(id: $0.id.uuidString, title: $0.displayName, systemImage: InterfaceSymbol.portal, section: source.displayName)
            }
        }
        if let connectionID, !viewModel.savedConnections.contains(where: { $0.id == connectionID }) {
            options.append(GlassSelectionOption(id: connectionID.uuidString, title: "Unavailable portal", isEnabled: false))
        }
        return options
    }

    private var portalTitle: String {
        guard let connectionID else { return "Selected portal" }
        return viewModel.savedConnections.first { $0.id == connectionID }?.displayName ?? "Unavailable portal"
    }
}

enum SplitTunnelPresentation {
    static func destination(_ rule: SplitTunnelRule) -> String {
        guard rule.kind == .domain else { return rule.value }
        let prefix = rule.value.hasPrefix("full:") ? "full:" : ""
        return prefix + DisplayHostname.unicode(String(rule.value.dropFirst(prefix.count)))
    }

    static func candidates(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "\n\r,"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
