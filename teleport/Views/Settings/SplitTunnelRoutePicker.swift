import SwiftUI

struct SplitTunnelRoutePicker: View {
    @ObservedObject var viewModel: AppViewModel
    let action: SplitTunnelRuleAction
    let connectionID: UUID?
    let onSelect: (SplitTunnelRuleAction, UUID?) -> Void

    var body: some View {
        SettingsValueMenu(title: title) {
            Button(markedTitle("Direct", selected: action == .direct), systemImage: "arrow.up.right") { onSelect(.direct, nil) }
            Menu(markedTitle("Proxy", selected: action == .proxy), systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
                portalButton("Selected portal", id: nil)
                Divider()
                if !viewModel.manualConnectionPickerItems.isEmpty {
                    Text("Standalone")
                    ForEach(viewModel.manualConnectionPickerItems) { portal in
                        portalButton(portal.displayName, id: portal.id)
                    }
                }
                if !viewModel.subscriptionPickerItems.isEmpty {
                    Text("Subscriptions")
                    ForEach(viewModel.subscriptionPickerItems) { source in
                        subscriptionMenu(source)
                    }
                }
            }
            Button(markedTitle("Block", selected: action == .block), systemImage: "hand.raised") { onSelect(.block, nil) }
        }
        .frame(maxWidth: 180, alignment: .trailing)
        .accessibilityLabel("Route")
        .accessibilityValue(title)
    }

    private func subscriptionMenu(_ source: SubscriptionPickerItem) -> some View {
        let portals = viewModel.importedConnectionPickerItems(for: source.id)
        let containsSelection = action == .proxy && portals.contains { $0.id == connectionID }
        return Menu(markedTitle("\(source.displayName) (\(portals.count))", selected: containsSelection)) {
            if portals.isEmpty {
                Button("No portals") {}
                    .disabled(true)
            } else {
                ForEach(portals) { portal in
                    portalButton(portal.displayName, id: portal.id)
                }
            }
        }
    }

    private func portalButton(_ name: String, id: UUID?) -> some View {
        Button(markedTitle(name, selected: action == .proxy && connectionID == id)) {
            onSelect(.proxy, id)
        }
    }

    private func markedTitle(_ title: String, selected: Bool) -> String {
        selected ? "✓ \(title)" : title
    }

    private var title: String {
        guard action == .proxy, let connectionID else { return action.displayName }
        let portal = viewModel.savedConnections.first { $0.id == connectionID }
        return "Proxy: \(portal?.displayName ?? "Unavailable portal")"
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
