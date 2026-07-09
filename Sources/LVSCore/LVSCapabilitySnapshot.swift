public struct LVSCapabilitySnapshot: Codable, Sendable, Hashable {
    public struct Backend: Codable, Sendable, Hashable {
        public let backendID: String
        public let maturity: String
        public let executionMode: String
        public let requiresExternalTool: Bool
        public let inputFormats: [String]
        public let requiredInputs: [String]
        public let producedArtifacts: [String]
        public let diagnosticCategories: [String]
        public let qualificationTags: [String]
        public let limitations: [String]

        public init(
            backendID: String,
            maturity: String,
            executionMode: String,
            requiresExternalTool: Bool,
            inputFormats: [String],
            requiredInputs: [String],
            producedArtifacts: [String],
            diagnosticCategories: [String],
            qualificationTags: [String],
            limitations: [String]
        ) {
            self.backendID = backendID
            self.maturity = maturity
            self.executionMode = executionMode
            self.requiresExternalTool = requiresExternalTool
            self.inputFormats = inputFormats
            self.requiredInputs = requiredInputs
            self.producedArtifacts = producedArtifacts
            self.diagnosticCategories = diagnosticCategories
            self.qualificationTags = qualificationTags
            self.limitations = limitations
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
        public let requiredCoverageTags: [String]

        public init(
            runner: String,
            cliFlag: String,
            committedSpecPath: String,
            reportArtifact: String,
            evidenceExportFlag: String,
            qualificationPolicy: String,
            requiredCoverageTags: [String]
        ) {
            self.runner = runner
            self.cliFlag = cliFlag
            self.committedSpecPath = committedSpecPath
            self.reportArtifact = reportArtifact
            self.evidenceExportFlag = evidenceExportFlag
            self.qualificationPolicy = qualificationPolicy
            self.requiredCoverageTags = requiredCoverageTags
        }
    }

    public let schemaVersion: Int
    public let engineID: String
    public let ownerPackage: String
    public let status: String
    public let preferredBackendID: String
    public let backends: [Backend]
    public let artifacts: [ArtifactContract]
    public let corpus: CorpusContract
    public let actionDomain: LVSActionDomainSnapshot
    public let agentContracts: [String]
    public let openMilestones: [String]

    public init(
        schemaVersion: Int = 1,
        engineID: String,
        ownerPackage: String,
        status: String,
        preferredBackendID: String,
        backends: [Backend],
        artifacts: [ArtifactContract],
        corpus: CorpusContract,
        actionDomain: LVSActionDomainSnapshot,
        agentContracts: [String],
        openMilestones: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.engineID = engineID
        self.ownerPackage = ownerPackage
        self.status = status
        self.preferredBackendID = preferredBackendID
        self.backends = backends
        self.artifacts = artifacts
        self.corpus = corpus
        self.actionDomain = actionDomain
        self.agentContracts = agentContracts
        self.openMilestones = openMilestones
    }
}
