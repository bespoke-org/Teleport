import Foundation

/// The readable form of a hostname, for display only: what is stored, sent to
/// Xray and shared stays the ASCII form DNS needs.
///
/// An `xn--` label is shown decoded only when it decodes (RFC 3492) to Cyrillic
/// letters, digits and hyphens. A label that mixes Cyrillic with Latin letters,
/// the usual way to fake a familiar name, keeps its `xn--` form, as does a label
/// in another script or one that does not decode.
nonisolated enum DisplayHostname {
    static func unicode(_ host: String) -> String {
        host.split(separator: ".", omittingEmptySubsequences: false)
            .map { decodedCyrillicLabel($0) ?? String($0) }
            .joined(separator: ".")
    }

    private static func decodedCyrillicLabel(_ label: Substring) -> String? {
        guard label.lowercased().hasPrefix("xn--"),
              let scalars = punycodeDecoded(label.dropFirst(4)),
              scalars.contains(where: isCyrillic),
              scalars.allSatisfy({ isCyrillic($0) || (0x30...0x39).contains($0.value) || $0 == "-" }) else {
            return nil
        }
        var decoded = ""
        decoded.unicodeScalars.append(contentsOf: scalars)
        return decoded
    }

    private static func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
        (0x0400...0x04FF).contains(scalar.value)
    }

    // RFC 3492 section 5 parameters.
    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700

    /// RFC 3492 section 6.2. Returns nil for input that is not valid Punycode.
    private static func punycodeDecoded(_ input: Substring) -> [Unicode.Scalar]? {
        guard input.allSatisfy(\.isASCII) else { return nil }

        var output: [Unicode.Scalar] = []
        var encoded = input
        if let delimiter = input.lastIndex(of: "-") {
            output = Array(input[..<delimiter].unicodeScalars)
            encoded = input[input.index(after: delimiter)...]
        }

        let digits = Array(encoded.unicodeScalars)
        var position = 0
        var n = 128
        var i = 0
        var bias = 72
        while position < digits.count {
            let oldI = i
            var weight = 1
            var k = base
            while true {
                guard position < digits.count, let digit = digitValue(digits[position]) else { return nil }
                position += 1
                let (step, stepOverflow) = digit.multipliedReportingOverflow(by: weight)
                let (sum, sumOverflow) = i.addingReportingOverflow(step)
                guard !stepOverflow, !sumOverflow else { return nil }
                i = sum
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if digit < t { break }
                let (nextWeight, weightOverflow) = weight.multipliedReportingOverflow(by: base - t)
                guard !weightOverflow else { return nil }
                weight = nextWeight
                k += base
            }

            let length = output.count + 1
            bias = adapt(delta: i - oldI, length: length, isFirst: oldI == 0)
            let (nextN, nOverflow) = n.addingReportingOverflow(i / length)
            guard !nOverflow, nextN <= 0x10FFFF, let scalar = Unicode.Scalar(UInt32(nextN)) else { return nil }
            n = nextN
            i %= length
            output.insert(scalar, at: i)
            i += 1
        }
        return output
    }

    private static func adapt(delta: Int, length: Int, isFirst: Bool) -> Int {
        var delta = isFirst ? delta / damp : delta / 2
        delta += delta / length
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }

    private static func digitValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 0x30...0x39: return Int(scalar.value) - 0x30 + 26
        case 0x41...0x5A: return Int(scalar.value) - 0x41
        case 0x61...0x7A: return Int(scalar.value) - 0x61
        default: return nil
        }
    }
}
