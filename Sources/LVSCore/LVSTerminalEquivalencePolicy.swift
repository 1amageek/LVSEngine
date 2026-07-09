import Foundation

public struct LVSTerminalEquivalencePolicy: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let rules: [LVSTerminalEquivalenceRule]

    public init(
        schemaVersion: Int = 1,
        rules: [LVSTerminalEquivalenceRule]
    ) {
        self.schemaVersion = schemaVersion
        self.rules = rules
    }

    public static let defaultSPICEPrimitive = LVSTerminalEquivalencePolicy(
        rules: [
            LVSTerminalEquivalenceRule(kind: "mos", pinCount: 4, equivalentPinGroups: [[0, 2]]),
            LVSTerminalEquivalenceRule(kind: "resistor", pinCount: 2, equivalentPinGroups: [[0, 1]]),
            LVSTerminalEquivalenceRule(kind: "capacitor", pinCount: 2, equivalentPinGroups: [[0, 1]]),
            LVSTerminalEquivalenceRule(kind: "inductor", pinCount: 2, equivalentPinGroups: [[0, 1]]),
        ]
    )
}

public struct LVSTerminalEquivalenceRule: Sendable, Hashable, Codable {
    public let kind: String
    public let model: String?
    public let pinCount: Int?
    public let equivalentPinGroups: [[Int]]

    public init(
        kind: String,
        model: String? = nil,
        pinCount: Int? = nil,
        equivalentPinGroups: [[Int]]
    ) {
        self.kind = kind
        self.model = model
        self.pinCount = pinCount
        self.equivalentPinGroups = equivalentPinGroups
    }
}

public struct LVSTerminalEquivalenceResolver: Sendable, Hashable {
    private struct Selector: Sendable, Hashable {
        let kind: String
        let model: String?
    }

    private struct ResolvedRule: Sendable, Hashable {
        let selector: Selector
        let pinCount: Int?
        let groups: [[Int]]
    }

    private let rules: [ResolvedRule]

    public init(policies: [LVSTerminalEquivalencePolicy]) throws {
        var rules: [ResolvedRule] = []

        for policy in policies {
            guard policy.schemaVersion == 1 else {
                throw LVSError.invalidInput(
                    "Unsupported terminal equivalence policy schemaVersion \(policy.schemaVersion)."
                )
            }
            for rule in policy.rules {
                let normalizedRule = try Self.normalized(rule)
                let selector = Selector(kind: normalizedRule.kind, model: normalizedRule.model)
                rules.append(ResolvedRule(
                    selector: selector,
                    pinCount: normalizedRule.pinCount,
                    groups: normalizedRule.groups
                ))
            }
        }

        self.rules = rules
    }

    public static func defaultSPICEPrimitive() throws -> LVSTerminalEquivalenceResolver {
        try LVSTerminalEquivalenceResolver(policies: [.defaultSPICEPrimitive])
    }

    public func equivalentPinGroups(kind: String, model: String?, pinCount: Int) -> [[Int]] {
        let kindOnlySelector = Selector(kind: Self.normalizedName(kind), model: nil)
        let modelSelector = Selector(
            kind: Self.normalizedName(kind),
            model: model.map(Self.normalizedName)
        )
        return Self.normalizedGroups(
            groups(for: kindOnlySelector, pinCount: pinCount)
                + groups(for: modelSelector, pinCount: pinCount)
        )
    }

    private func groups(for selector: Selector, pinCount: Int) -> [[Int]] {
        rules.flatMap { rule in
            guard rule.selector == selector else { return [[Int]]() }
            if let expectedPinCount = rule.pinCount, expectedPinCount != pinCount {
                return []
            }
            return rule.groups.filter { group in
                group.allSatisfy { $0 < pinCount }
            }
        }
    }

    private static func normalized(_ rule: LVSTerminalEquivalenceRule) throws -> (
        kind: String,
        model: String?,
        pinCount: Int?,
        groups: [[Int]]
    ) {
        let kind = normalizedName(rule.kind)
        guard !kind.isEmpty else {
            throw LVSError.invalidInput("Terminal equivalence rule kind must not be empty.")
        }
        let model = rule.model.map(normalizedName).flatMap { $0.isEmpty ? nil : $0 }
        if let pinCount = rule.pinCount, pinCount <= 0 {
            throw LVSError.invalidInput(
                "Terminal equivalence rule for \(kind) has invalid pinCount \(pinCount)."
            )
        }
        guard !rule.equivalentPinGroups.isEmpty else {
            throw LVSError.invalidInput(
                "Terminal equivalence rule for \(kind) must declare equivalentPinGroups."
            )
        }

        var usedPins = Set<Int>()
        var normalizedGroups: [[Int]] = []
        for group in rule.equivalentPinGroups {
            let normalizedGroup = Array(Set(group)).sorted()
            guard normalizedGroup.count >= 2 else {
                throw LVSError.invalidInput(
                    "Terminal equivalence group for \(kind) must contain at least two unique pin indices."
                )
            }
            guard normalizedGroup.allSatisfy({ $0 >= 0 }) else {
                throw LVSError.invalidInput(
                    "Terminal equivalence group for \(kind) contains a negative pin index."
                )
            }
            if let pinCount = rule.pinCount, normalizedGroup.contains(where: { $0 >= pinCount }) {
                throw LVSError.invalidInput(
                    "Terminal equivalence group for \(kind) references a pin index outside pinCount \(pinCount)."
                )
            }
            let overlap = usedPins.intersection(normalizedGroup)
            guard overlap.isEmpty else {
                throw LVSError.invalidInput(
                    "Terminal equivalence rule for \(kind) assigns a pin index to multiple groups."
                )
            }
            usedPins.formUnion(normalizedGroup)
            normalizedGroups.append(normalizedGroup)
        }

        return (
            kind: kind,
            model: model,
            pinCount: rule.pinCount,
            groups: normalizedGroups
        )
    }

    private static func normalizedGroups(_ groups: [[Int]]) -> [[Int]] {
        Array(Set(groups)).sorted { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count < rhs.count
            }
            return lhs.lexicographicallyPrecedes(rhs)
        }
    }

    private static func normalizedName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

}
