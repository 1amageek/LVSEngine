import Foundation

package enum SPICEValueNormalizer {
    package static func canonicalize(_ value: Double) -> String {
        guard value.isFinite else {
            return "\(value)"
        }
        if abs(value) < 1e-300 {
            return "0.000000000000e+00"
        }
        return String(format: "%.12e", value)
    }

    package static func canonicalize(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "µ", with: "u")
        guard let parsed = parseNumericValue(normalized) else {
            return normalized
        }
        let scaled = parsed.number * parsed.multiplier
        guard scaled.isFinite else {
            return normalized
        }
        return canonicalize(scaled)
    }

    package static func numericValue(_ value: String) -> Double? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "µ", with: "u")
        guard let parsed = parseNumericValue(normalized) else {
            return nil
        }
        return parsed.number * parsed.multiplier
    }

    private static func parseNumericValue(_ value: String) -> (number: Double, multiplier: Double)? {
        let numberEnd = numericPrefixEnd(in: value)
        guard numberEnd > value.startIndex else {
            return nil
        }
        let numberText = String(value[..<numberEnd])
        guard let number = Double(numberText) else {
            return nil
        }
        let suffix = String(value[numberEnd...])
        guard let multiplier = multiplier(for: suffix) else {
            return nil
        }
        return (number, multiplier)
    }

    private static func numericPrefixEnd(in value: String) -> String.Index {
        var index = value.startIndex
        var sawDigit = false
        var sawDecimalPoint = false
        var sawExponent = false

        if index < value.endIndex, value[index] == "+" || value[index] == "-" {
            index = value.index(after: index)
        }

        while index < value.endIndex {
            let character = value[index]
            if character.isNumber {
                sawDigit = true
                index = value.index(after: index)
                continue
            }
            if character == ".", !sawDecimalPoint, !sawExponent {
                sawDecimalPoint = true
                index = value.index(after: index)
                continue
            }
            if character == "e", sawDigit, !sawExponent {
                let exponentStart = index
                var next = value.index(after: index)
                if next < value.endIndex, value[next] == "+" || value[next] == "-" {
                    next = value.index(after: next)
                }
                guard next < value.endIndex, value[next].isNumber else {
                    return exponentStart
                }
                sawExponent = true
                index = next
                continue
            }
            break
        }
        return sawDigit ? index : value.startIndex
    }

    private static func multiplier(for suffix: String) -> Double? {
        guard !suffix.isEmpty else {
            return 1
        }
        if suffix.hasPrefix("meg") {
            return 1e6
        }
        if suffix.hasPrefix("mil") {
            return 25.4e-6
        }
        guard let first = suffix.first else {
            return 1
        }
        switch first {
        case "t":
            return 1e12
        case "g":
            return 1e9
        case "k":
            return 1e3
        case "m":
            return 1e-3
        case "u":
            return 1e-6
        case "n":
            return 1e-9
        case "p":
            return 1e-12
        case "f":
            return 1e-15
        default:
            return nil
        }
    }
}
