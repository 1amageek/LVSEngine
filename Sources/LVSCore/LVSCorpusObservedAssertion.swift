public enum LVSCorpusAssertionStatus: String, Sendable, Hashable, Codable {
    case passed
    case failed
    case blocked
}

public enum LVSCorpusAssertionKind: String, Sendable, Hashable, Codable {
    case verdict
    case faultClass
    case readiness
    case diagnosticRule
    case reportArtifact
    case manifestArtifact
    case correspondenceArtifact
    case extractionArtifact
    case extractionProfileReadiness
    case structureClass
    case hierarchyDepth
    case oracleAgreement
    case oracleIndependence
    case durationBudget
    case searchBudget
    case memoryBudget
    case cancellation
    case determinism
    case devicePolicyImport
    case devicePolicyApplication
    case devicePolicyRule
}

public struct LVSCorpusAssertionRequirement: Sendable, Hashable, Codable {
    public let assertionID: String
    public let kind: LVSCorpusAssertionKind
    public let expectedValue: String?

    public init(
        assertionID: String,
        kind: LVSCorpusAssertionKind,
        expectedValue: String? = nil
    ) {
        self.assertionID = assertionID
        self.kind = kind
        self.expectedValue = expectedValue
    }
}

public struct LVSCorpusObservedAssertion: Sendable, Hashable, Codable {
    public let assertionID: String
    public let kind: LVSCorpusAssertionKind
    public let status: LVSCorpusAssertionStatus
    public let expectedValue: String?
    public let observedValue: String?
    public let sourceArtifactRefs: [String]
    public let failureCode: String?

    public init(
        assertionID: String,
        kind: LVSCorpusAssertionKind,
        status: LVSCorpusAssertionStatus,
        expectedValue: String? = nil,
        observedValue: String? = nil,
        sourceArtifactRefs: [String] = [],
        failureCode: String? = nil
    ) {
        self.assertionID = assertionID
        self.kind = kind
        self.status = status
        self.expectedValue = expectedValue
        self.observedValue = observedValue
        self.sourceArtifactRefs = Array(Set(sourceArtifactRefs)).sorted()
        self.failureCode = failureCode
    }

    public var coverageKey: String {
        expectedValue.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue
    }
}

public enum LVSCorpusOracleComparisonMode: String, Sendable, Hashable, Codable {
    case verdict
    case verdictAndFaultClass
    case strictDiagnostics
}

public struct LVSCorpusHardExecutionBudget: Sendable, Hashable, Codable {
    public let maximumDurationSeconds: Double?
    public let maximumSearchStates: Int?
    public let maximumSearchDepth: Int?
    public let maximumWorkingSetBytes: Int?
    public let determinismRunCount: Int

    public init(
        maximumDurationSeconds: Double? = nil,
        maximumSearchStates: Int? = nil,
        maximumSearchDepth: Int? = nil,
        maximumWorkingSetBytes: Int? = nil,
        determinismRunCount: Int = 1
    ) {
        self.maximumDurationSeconds = maximumDurationSeconds
        self.maximumSearchStates = maximumSearchStates
        self.maximumSearchDepth = maximumSearchDepth
        self.maximumWorkingSetBytes = maximumWorkingSetBytes
        self.determinismRunCount = determinismRunCount
    }
}
