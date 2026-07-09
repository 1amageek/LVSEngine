import Foundation

struct SPICEExpressionEvaluator {
    private let characters: [Character]
    private let parameters: [String: String]
    private var index: Int = 0

    private init(expression: String, parameters: [String: String]) {
        self.characters = Array(expression.lowercased().replacingOccurrences(of: "µ", with: "u"))
        self.parameters = parameters
    }

    static func evaluate(_ expression: String, parameters: [String: String]) -> Double? {
        var parser = SPICEExpressionEvaluator(expression: expression, parameters: parameters)
        guard let value = parser.parseExpression() else {
            return nil
        }
        parser.skipWhitespace()
        guard parser.index == parser.characters.count else {
            return nil
        }
        return value.isFinite ? value : nil
    }

    private mutating func parseExpression() -> Double? {
        guard var value = parseTerm() else {
            return nil
        }
        while true {
            skipWhitespace()
            if consume("+") {
                guard let rhs = parseTerm() else { return nil }
                value += rhs
                continue
            }
            if consume("-") {
                guard let rhs = parseTerm() else { return nil }
                value -= rhs
                continue
            }
            return value
        }
    }

    private mutating func parseTerm() -> Double? {
        guard var value = parseFactor() else {
            return nil
        }
        while true {
            skipWhitespace()
            if consume("*") {
                guard let rhs = parseFactor() else { return nil }
                value *= rhs
                continue
            }
            if consume("/") {
                guard let rhs = parseFactor(), abs(rhs) > 1e-300 else {
                    return nil
                }
                value /= rhs
                continue
            }
            return value
        }
    }

    private mutating func parseFactor() -> Double? {
        skipWhitespace()
        if consume("+") {
            return parseFactor()
        }
        if consume("-") {
            guard let value = parseFactor() else {
                return nil
            }
            return -value
        }
        if consume("(") {
            guard let value = parseExpression() else {
                return nil
            }
            skipWhitespace()
            return consume(")") ? value : nil
        }
        if consume("{") {
            guard let value = parseExpression() else {
                return nil
            }
            skipWhitespace()
            return consume("}") ? value : nil
        }
        if let numeric = parseNumericLiteral() {
            return numeric
        }
        return parseParameterReference()
    }

    private mutating func parseNumericLiteral() -> Double? {
        let start = index
        var sawDigit = false
        var sawDecimalPoint = false
        var sawExponent = false
        while index < characters.count {
            let character = characters[index]
            if character.isNumber {
                sawDigit = true
                index += 1
                continue
            }
            if character == ".", !sawDecimalPoint, !sawExponent {
                sawDecimalPoint = true
                index += 1
                continue
            }
            if character == "e", sawDigit, !sawExponent {
                let exponentIndex = index
                var next = index + 1
                if next < characters.count, characters[next] == "+" || characters[next] == "-" {
                    next += 1
                }
                guard next < characters.count, characters[next].isNumber else {
                    index = exponentIndex
                    break
                }
                sawExponent = true
                index = next
                continue
            }
            break
        }
        guard sawDigit else {
            index = start
            return nil
        }
        while index < characters.count, isScaleSuffixCharacter(characters[index]) {
            index += 1
        }
        let literal = String(characters[start..<index])
        guard let value = SPICEValueNormalizer.numericValue(literal) else {
            index = start
            return nil
        }
        return value
    }

    private mutating func parseParameterReference() -> Double? {
        let start = index
        while index < characters.count, isIdentifierCharacter(characters[index]) {
            index += 1
        }
        guard index > start else {
            return nil
        }
        let name = String(characters[start..<index])
        guard let rawValue = parameters[name] else {
            return nil
        }
        if let numericValue = SPICEValueNormalizer.numericValue(rawValue) {
            return numericValue
        }
        let expression = rawValue.hasPrefix("{") && rawValue.hasSuffix("}")
            ? String(rawValue.dropFirst().dropLast())
            : rawValue
        guard expression != name else {
            return nil
        }
        return SPICEExpressionEvaluator.evaluate(expression, parameters: parameters)
    }

    private func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "."
    }

    private func isScaleSuffixCharacter(_ character: Character) -> Bool {
        character.isLetter
    }

    private mutating func consume(_ expected: Character) -> Bool {
        skipWhitespace()
        guard index < characters.count, characters[index] == expected else {
            return false
        }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
    }
}
