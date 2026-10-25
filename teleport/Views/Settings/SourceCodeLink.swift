import SwiftUI

struct SourceCodeLink: View {
    let destination: URL

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            Link(destination: destination) {
                Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .focused($isFocused)
            .accessibilityLabel("Source code")
            .accessibilityHint("View Teleport on GitHub. Give us a Star, it would really help!")

            SourceCodeStarPrompt(isRevealed: isHovered || isFocused)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

struct SourceCodeStarPrompt: View {
    let isRevealed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let words = ["Give", "us", "a", "Star,", "it", "would", "really", "help!"]

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "star.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.linearGradient(colors: [.yellow, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .orange.opacity(isRevealed ? 0.25 : 0), radius: 3)
                .rotationEffect(.degrees(reduceMotion || isRevealed ? 0 : -90))
                .scaleEffect(reduceMotion || isRevealed ? 1 : 0.25)
                .opacity(isRevealed ? 1 : 0)
                .animation(revealAnimation, value: isRevealed)
                .frame(width: 20, height: 20)

            HStack(spacing: 3) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    Text(word)
                        .offset(y: reduceMotion || isRevealed ? 0 : 5)
                        .opacity(isRevealed ? 1 : 0)
                        .animation(wordAnimation(index), value: isRevealed)
                }
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
        }
        // Reserve the reveal's space so hovering never shifts the form or its hit area.
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var revealAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.12) }
        return isRevealed ? .spring(duration: 0.55, bounce: 0.45) : .easeOut(duration: 0.15)
    }

    private func wordAnimation(_ index: Int) -> Animation {
        if reduceMotion { return .easeOut(duration: 0.12) }
        return isRevealed
            ? .spring(duration: 0.35, bounce: 0.15).delay(0.08 + Double(index) * 0.045)
            : .easeOut(duration: 0.12)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        SourceCodeLink(destination: URL(string: "https://github.com/bespoke-org/Teleport")!)
        SourceCodeStarPrompt(isRevealed: true)
    }
    .padding(30)
}
