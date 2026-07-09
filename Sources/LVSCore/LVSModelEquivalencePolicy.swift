import Foundation

public struct LVSModelEquivalencePolicy: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let groups: [LVSModelEquivalenceGroup]

    public init(
        schemaVersion: Int = 1,
        groups: [LVSModelEquivalenceGroup]
    ) {
        self.schemaVersion = schemaVersion
        self.groups = groups
    }

    public func canonicalModelMap() throws -> [String: String] {
        guard schemaVersion == 1 else {
            throw LVSError.invalidInput("Unsupported model equivalence policy schemaVersion \(schemaVersion).")
        }

        var map: [String: String] = [:]
        for group in groups {
            let canonical = Self.normalizedModelName(group.canonicalModel)
            guard !canonical.isEmpty else {
                throw LVSError.invalidInput("Model equivalence canonicalModel must not be empty.")
            }

            let aliases = ([canonical] + group.aliases.map(Self.normalizedModelName))
                .filter { !$0.isEmpty }
            guard !aliases.isEmpty else {
                throw LVSError.invalidInput("Model equivalence group for \(canonical) has no usable model names.")
            }

            for alias in Set(aliases) {
                if let existing = map[alias], existing != canonical {
                    throw LVSError.invalidInput(
                        "Model equivalence alias \(alias) maps to both \(existing) and \(canonical)."
                    )
                }
                map[alias] = canonical
            }
        }
        return map
    }

    private static func normalizedModelName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

public struct LVSModelEquivalenceGroup: Sendable, Hashable, Codable {
    public let canonicalModel: String
    public let aliases: [String]

    public init(
        canonicalModel: String,
        aliases: [String]
    ) {
        self.canonicalModel = canonicalModel
        self.aliases = aliases
    }
}
