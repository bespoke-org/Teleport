import SwiftUI

struct SubscriptionInfoButton: View {
    let announcement: String
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails.toggle() } label: {
            Image(systemName: "info.circle")
                .frame(width: 20, height: 24)
        }
        .buttonStyle(.borderless)
        .help(announcement)
        .accessibilityLabel("Subscription information")
        .accessibilityValue(announcement)
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            Text(verbatim: announcement)
                .textSelection(.enabled)
                .frame(maxWidth: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}
