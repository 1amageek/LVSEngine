public struct LVSCapabilitySnapshot: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 3

    public struct Backend: Codable, Sendable, Hashable {
        public let backendID: String
        public let executionMode: String
        public let requiresExternalTool: Bool
        public let inputFormats: [String]
        public let requiredInputs: [String]
        public let producedArtifacts: [String]
        public let diagnosticCategories: [String]
        public let limitations: [String]

        public init(
            backendID: String,
            executionMode: String,
            requiresExternalTool: Bool,
            inputFormats: [String],
            requiredInputs: [String],
            producedArtifacts: [String],
            diagnosticCategories: [String],
            limitations: [String]
        ) {
            self.backendID = backendID
            self.executionMode = executionMode
            self.requiresExternalTool = requiresExternalTool
            self.inputFormats = inputFormats
            self.requiredInputs = requiredInputs
            self.producedArtifacts = producedArtifacts
            self.diagnosticCategories = diagnosticCategories
            self.limitations = limitations
        }
    }

    public struct QualificationBinding: Codable, Sendable, Hashable {
        public let evidenceArtifactID: String
        public let evaluator: String
        public let backendSelectionPolicy: String
        public let requiredIdentityFields: [String]
        public let freshnessPolicy: String

        public init(
            evidenceArtifactID: String,
            evaluator: String,
            backendSelectionPolicy: String,
            requiredIdentityFields: [String],
            freshnessPolicy: String
        ) {
            self.evidenceArtifactID = evidenceArtifactID
            self.evaluator = evaluator
            self.backendSelectionPolicy = backendSelectionPolicy
            self.requiredIdentityFields = requiredIdentityFields
            self.freshnessPolicy = freshnessPolicy
        }
    }

    public struct ArtifactContract: Codable, Sendable, Hashable {
        public let artifactID: String
        public let format: String
        public let producer: String
        public let consumer: [String]

        public init(
            artifactID: String,
            format: String,
            producer: String,
            consumer: [String]
        ) {
            self.artifactID = artifactID
            self.format = format
            self.producer = producer
            self.consumer = consumer
        }
    }

    public struct CorpusContract: Codable, Sendable, Hashable {
        public let runner: String
        public let cliFlag: String
        public let committedSpecPath: String
        public let reportArtifact: String
        public let evidenceExportFlag: String
        public let qualificationPolicy: String
        public let requiredObservedAssertions: [String]

        public init(
            runner: String,
            cliFlag: String,
            committedSpecPath: String,
            reportArtifact: String,
            evidenceExportFlag: String,
            qualificationPolicy: String,
            requiredObservedAssertions: [String]
        ) {
            self.runner = runner
            self.cliFlag = cliFlag
            self.committedSpecPath = committedSpecPath
            self.reportArtifact = reportArtifact
            self.evidenceExportFlag = evidenceExportFlag
            self.qualificationPolicy = qualificationPolicy
            self.requiredObservedAssertions = requiredObservedAssertions
        }
    }

    public let schemaVersion: Int
    public let engineID: String
    public let ownerPackage: String
    public let qualificationBinding: QualificationBinding
    public let backends: [Backend]
    public let artifacts: [ArtifactContract]
    public let corpus: CorpusContract
    public let actionDomain: LVSActionDomainSnapshot
    public let agentContracts: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case engineID
        case ownerPackage
        case qualificationBinding
        case backends
        case artifacts
        case corpus
        case actionDomain
        case agentContracts
    }

    public init(
        schemaVersion: Int = LVSCapabilitySnapshot.currentSchemaVersion,
        engineID: String,
        ownerPackage: String,
        qualificationBinding: QualificationBinding,
        backends: [Backend],
        artifacts: [ArtifactContract],
        corpus: CorpusContract,
        actionDomain: LVSActionDomainSnapshot,
        agentContracts: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.engineID = engineID
        self.ownerPackage = ownerPackage
        self.qualificationBinding = qualificationBinding
        self.backends = backends
        self.artifacts = artifacts
        self.corpus = corpus
        self.actionDomain = actionDomain
        self.agentContracts = agentContracts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported LVS capability snapshot schema version \(schemaVersion)."
            )
        }
        engineID = try container.decode(String.self, forKey: .engineID)
        ownerPackage = try container.decode(String.self, forKey: .ownerPackage)
        qualificationBinding = try container.decode(QualificationBinding.self, forKey: .qualificationBinding)
        backends = try container.decode([Backend].self, forKey: .backends)
        artifacts = try container.decode([ArtifactContract].self, forKey: .artifacts)
        corpus = try container.decode(CorpusContract.self, forKey: .corpus)
        actionDomain = try container.decode(LVSActionDomainSnapshot.self, forKey: .actionDomain)
        agentContracts = try container.decode([String].self, forKey: .agentContracts)
    }
}
