import Foundation

nonisolated enum ConnectionLatencyFormatter {
    static func string(milliseconds: Int, locale: Locale = .current) -> String {
        if milliseconds < 1_000 {
            return "\(milliseconds.formatted(.number.locale(locale))) ms"
        }

        let seconds = (Double(milliseconds) / 1_000).formatted(
            .number.precision(.fractionLength(2)).locale(locale)
        )
        return "\(seconds) s"
    }
}
