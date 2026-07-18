public struct LVSCorpusSpec: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 5

    public let schemaVersion: Int
    public let defaultMaxDurationSeconds: Double?
    public let acceptanceCriteria: LVSCorpusAcceptanceCriteria
    public let implementationScopeCaseID: String?
    public let cases: [LVSCorpusCase]

    public init(
        schemaVersion: Int = LVSCorpusSpec.currentSchemaVersion,
        defaultMaxDurationSeconds: Double? = nil,
        acceptanceCriteria: LVSCorpusAcceptanceCriteria = .strict,
        implementationScopeCaseID: String? = nil,
        cases: [LVSCorpusCase]
    ) {
        self.schemaVersion = schemaVersion
        self.defaultMaxDurationSeconds = defaultMaxDurationSeconds
        self.acceptanceCriteria = acceptanceCriteria
        self.implementationScopeCaseID = implementationScopeCaseID
        self.cases = cases
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case defaultMaxDurationSeconds
        case acceptanceCriteria
        case implementationScopeCaseID
        case cases
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == LVSCorpusSpec.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported LVS corpus schema version \(schemaVersion)."
            )
        }
        defaultMaxDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .defaultMaxDurationSeconds)
        acceptanceCriteria = try container.decode(
            LVSCorpusAcceptanceCriteria.self,
            forKey: .acceptanceCriteria
        )
        implementationScopeCaseID = try container.decodeIfPresent(
            String.self,
            forKey: .implementationScopeCaseID
        )
        cases = try container.decode([LVSCorpusCase].self, forKey: .cases)
    }
}
