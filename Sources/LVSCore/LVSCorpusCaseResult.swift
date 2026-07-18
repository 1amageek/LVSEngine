public struct LVSCorpusCaseResult: Sendable, Hashable, Codable {
    public let caseID: String
    public let matched: Bool
    public let expectedPassed: Bool
    public let actualPassed: Bool
    public let expectedActiveErrorRuleIDs: [String]
    public let actualActiveErrorRuleIDs: [String]
    public let coverageTags: [String]
    public let expectationMatched: Bool
    public let durationSeconds: Double
    public let expectedMaxDurationSeconds: Double?
    public let durationBudgetPassed: Bool
    public let failureReasons: [String]
    public let executionError: String?
    public let diagnosticSummary: LVSDiagnosticSummary
    public let reportPath: String?
    public let manifestPath: String?
    public let extractedLayoutNetlistPath: String?
    public let primaryProvenance: LVSCorpusCaseProvenance?
    public let oracleResult: LVSCorpusOracleResult?
    public let oracleComparison: LVSCorpusOracleComparison?
    public let observedAssertions: [LVSCorpusObservedAssertion]

    public init(
        caseID: String,
        matched: Bool,
        expectedPassed: Bool,
        actualPassed: Bool,
        expectedActiveErrorRuleIDs: [String],
        actualActiveErrorRuleIDs: [String],
        coverageTags: [String] = [],
        expectationMatched: Bool,
        durationSeconds: Double,
        expectedMaxDurationSeconds: Double?,
        durationBudgetPassed: Bool,
        failureReasons: [String],
        executionError: String? = nil,
        diagnosticSummary: LVSDiagnosticSummary,
        reportPath: String?,
        manifestPath: String?,
        extractedLayoutNetlistPath: String?,
        primaryProvenance: LVSCorpusCaseProvenance? = nil,
        oracleResult: LVSCorpusOracleResult? = nil,
        oracleComparison: LVSCorpusOracleComparison? = nil,
        observedAssertions: [LVSCorpusObservedAssertion] = []
    ) {
        self.caseID = caseID
        self.matched = matched
        self.expectedPassed = expectedPassed
        self.actualPassed = actualPassed
        self.expectedActiveErrorRuleIDs = expectedActiveErrorRuleIDs
        self.actualActiveErrorRuleIDs = actualActiveErrorRuleIDs
        self.coverageTags = Array(Set(coverageTags.filter { !$0.isEmpty })).sorted()
        self.expectationMatched = expectationMatched
        self.durationSeconds = durationSeconds
        self.expectedMaxDurationSeconds = expectedMaxDurationSeconds
        self.durationBudgetPassed = durationBudgetPassed
        self.failureReasons = failureReasons
        self.executionError = executionError
        self.diagnosticSummary = diagnosticSummary
        self.reportPath = reportPath
        self.manifestPath = manifestPath
        self.extractedLayoutNetlistPath = extractedLayoutNetlistPath
        self.primaryProvenance = primaryProvenance
        self.oracleResult = oracleResult
        self.oracleComparison = oracleComparison
        self.observedAssertions = observedAssertions.sorted { $0.assertionID < $1.assertionID }
    }

    private enum CodingKeys: String, CodingKey {
        case caseID
        case matched
        case expectedPassed
        case actualPassed
        case expectedActiveErrorRuleIDs
        case actualActiveErrorRuleIDs
        case coverageTags
        case expectationMatched
        case durationSeconds
        case expectedMaxDurationSeconds
        case durationBudgetPassed
        case failureReasons
        case executionError
        case diagnosticSummary
        case reportPath
        case manifestPath
        case extractedLayoutNetlistPath
        case primaryProvenance
        case oracleResult
        case oracleComparison
        case observedAssertions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        caseID = try container.decode(String.self, forKey: .caseID)
        guard !caseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .caseID,
                in: container,
                debugDescription: "LVS corpus case identifiers must not be empty."
            )
        }
        matched = try container.decode(Bool.self, forKey: .matched)
        expectedPassed = try container.decode(Bool.self, forKey: .expectedPassed)
        actualPassed = try container.decode(Bool.self, forKey: .actualPassed)
        expectedActiveErrorRuleIDs = try container.decode([String].self, forKey: .expectedActiveErrorRuleIDs)
        actualActiveErrorRuleIDs = try container.decode([String].self, forKey: .actualActiveErrorRuleIDs)
        coverageTags = Array(Set(try container.decode(
            [String].self,
            forKey: .coverageTags
        ))).filter { !$0.isEmpty }.sorted()
        expectationMatched = try container.decode(Bool.self, forKey: .expectationMatched)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        guard durationSeconds.isFinite, durationSeconds >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .durationSeconds,
                in: container,
                debugDescription: "durationSeconds must be finite and zero or greater."
            )
        }
        expectedMaxDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .expectedMaxDurationSeconds)
        if let expectedMaxDurationSeconds {
            guard expectedMaxDurationSeconds.isFinite, expectedMaxDurationSeconds >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .expectedMaxDurationSeconds,
                    in: container,
                    debugDescription: "expectedMaxDurationSeconds must be finite and zero or greater."
                )
            }
        }
        durationBudgetPassed = try container.decode(Bool.self, forKey: .durationBudgetPassed)
        if let expectedMaxDurationSeconds,
           durationBudgetPassed != (durationSeconds <= expectedMaxDurationSeconds) {
            throw DecodingError.dataCorruptedError(
                forKey: .durationBudgetPassed,
                in: container,
                debugDescription: "durationBudgetPassed must match the retained duration and limit."
            )
        }
        failureReasons = try container.decode([String].self, forKey: .failureReasons)
        executionError = try container.decodeIfPresent(String.self, forKey: .executionError)
        diagnosticSummary = try container.decode(LVSDiagnosticSummary.self, forKey: .diagnosticSummary)
        reportPath = try container.decodeIfPresent(String.self, forKey: .reportPath)
        manifestPath = try container.decodeIfPresent(String.self, forKey: .manifestPath)
        extractedLayoutNetlistPath = try container.decodeIfPresent(String.self, forKey: .extractedLayoutNetlistPath)
        primaryProvenance = try container.decodeIfPresent(LVSCorpusCaseProvenance.self, forKey: .primaryProvenance)
        oracleResult = try container.decodeIfPresent(LVSCorpusOracleResult.self, forKey: .oracleResult)
        oracleComparison = try container.decodeIfPresent(LVSCorpusOracleComparison.self, forKey: .oracleComparison)
        observedAssertions = try container.decode(
            [LVSCorpusObservedAssertion].self,
            forKey: .observedAssertions
        )
    }
}
