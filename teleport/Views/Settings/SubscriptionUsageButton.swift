import SwiftUI

struct SubscriptionUsageButton: View {
    let usage: SubscriptionUsage
    @State private var showsDetails = false

    private var summary: String {
        let used = usage.usedBytes.map(bytes) ?? "Unknown"
        let total = usage.totalBytes.map { $0 == 0 ? "Unlimited" : bytes($0) } ?? "Unknown"
        return "Used \(used) / \(total)"
    }

    var body: some View {
        Button { showsDetails.toggle() } label: {
            ZStack {
                Circle().stroke(.secondary.opacity(0.2), lineWidth: 3)
                if let fraction = usage.fractionUsed {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    Image(systemName: usage.totalBytes == 0 ? "infinity" : "questionmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            .frame(width: 20, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(summary)
        .accessibilityLabel("Subscription traffic usage")
        .accessibilityValue(summary)
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            Text(summary)
                .monospacedDigit()
                .padding(12)
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }
}
