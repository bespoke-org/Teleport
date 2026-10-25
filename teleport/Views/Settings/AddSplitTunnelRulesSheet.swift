import SwiftUI

struct AddSplitTunnelRulesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: AppViewModel
    @State private var destinations = ""
    @State private var action: SplitTunnelRuleAction = .direct
    @State private var connectionID: UUID?
    @State private var errorMessage: String?
    @FocusState private var isDestinationFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add rules").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Destinations", text: $destinations,
                          prompt: Text("example.com, 10.0.0.0/8, geosite:google"), axis: .vertical)
                    .labelsHidden()
                    .accessibilityLabel("Destinations")
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3 ... 8)
                    .focused($isDestinationFocused)
                Text("Enter domains, IP ranges, or geodata categories. Separate entries with commas or new lines.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Route")
                Spacer()
                SplitTunnelRoutePicker(viewModel: viewModel, action: action, connectionID: connectionID) { route, portal in
                    action = route
                    connectionID = portal
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: addRules)
                    .keyboardShortcut(.defaultAction)
                    .disabled(SplitTunnelPresentation.candidates(destinations).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { isDestinationFocused = true }
    }

    private func addRules() {
        let candidates = SplitTunnelPresentation.candidates(destinations)
        var failures: [String] = []
        for candidate in candidates {
            if case .failure = viewModel.addSplitTunnelRule(value: candidate, action: action, connectionID: connectionID) {
                failures.append(candidate)
            }
        }
        if failures.isEmpty {
            dismiss()
        } else {
            // Leave only rejected entries, so retrying cannot add successes twice.
            destinations = failures.joined(separator: "\n")
            let added = candidates.count - failures.count
            let prefix = added > 0 ? "Added \(added) rule\(added == 1 ? "" : "s"). " : ""
            errorMessage = prefix + "Check the remaining destinations. Use a domain, IP/CIDR, geosite:category, or geoip:category."
        }
    }
}
