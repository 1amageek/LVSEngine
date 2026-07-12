public struct LVSCorpusSpec: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let defaultMaxDurationSeconds: Double?
    public let qualificationPolicy: LVSCorpusQualificationPolicy
    public let qualificationScopeCaseID: String?
    public let cases: [LVSCorpusCase]

    public init(
        schemaVersion: Int = LVSCorpusSpec.currentSchemaVersion,
        defaultMaxDurationSeconds: Double? = nil,
        qualificationPolicy: LVSCorpusQualificationPolicy = .strict,
        qualificationScopeCaseID: String? = nil,
        cases: [LVSCorpusCase]
    ) {
        self.schemaVersion = schemaVersion
        self.defaultMaxDurationSeconds = defaultMaxDurationSeconds
        self.qualificationPolicy = qualificationPolicy
        self.qualificationScopeCaseID = qualificationScopeCaseID
        self.cases = cases
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case defaultMaxDurationSeconds
        case qualificationPolicy
        case qualificationScopeCaseID
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
        qualificationPolicy = try container.decodeIfPresent(
            LVSCorpusQualificationPolicy.self,
            forKey: .qualificationPolicy
        ) ?? .strict
        qualificationScopeCaseID = try container.decodeIfPresent(
            String.self,
            forKey: .qualificationScopeCaseID
        )
        cases = try container.decode([LVSCorpusCase].self, forKey: .cases)
    }
}
