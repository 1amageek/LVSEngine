public struct LVSCorpusReport: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 4

    public let schemaVersion: Int
    public let generatedAt: String?
    public let passed: Bool
    public let caseCount: Int
    public let matchedCaseCount: Int
    public let budgetExceededCaseCount: Int
    public let totalDurationSeconds: Double
    public let runOptions: LVSCorpusRunOptions
    public let implementationScopeCaseID: String?
    public let summary: LVSCorpusSummary
    public let assessment: LVSCorpusAssessment
    public let caseResults: [LVSCorpusCaseResult]

    public init(
        schemaVersion: Int = LVSCorpusReport.currentSchemaVersion,
        generatedAt: String? = nil,
        passed: Bool,
        caseCount: Int,
        matchedCaseCount: Int,
        budgetExceededCaseCount: Int = 0,
        totalDurationSeconds: Double = 0,
        runOptions: LVSCorpusRunOptions = LVSCorpusRunOptions(),
        implementationScopeCaseID: String? = nil,
        summary: LVSCorpusSummary? = nil,
        acceptanceCriteria: LVSCorpusAcceptanceCriteria = .strict,
        assessment: LVSCorpusAssessment? = nil,
        caseResults: [LVSCorpusCaseResult]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.passed = passed
        self.caseCount = caseCount
        self.matchedCaseCount = matchedCaseCount
        self.budgetExceededCaseCount = budgetExceededCaseCount
        self.totalDurationSeconds = totalDurationSeconds
        self.runOptions = runOptions
        self.implementationScopeCaseID = implementationScopeCaseID
        let resolvedSummary = summary ?? LVSCorpusSummary(caseResults: caseResults)
        self.summary = resolvedSummary
        let resolvedCriteria = assessment?.criteria ?? acceptanceCriteria
        let evaluatedAssessment = resolvedCriteria.evaluate(
            passed: passed,
            caseCount: caseCount,
            summary: resolvedSummary
        )
        self.caseResults = caseResults
        let integrityFailures = LVSCorpusReportIntegrityValidator().failures(
            passed: passed,
            caseCount: caseCount,
            matchedCaseCount: matchedCaseCount,
            budgetExceededCaseCount: budgetExceededCaseCount,
            totalDurationSeconds: totalDurationSeconds,
            summary: resolvedSummary,
            caseResults: caseResults
        )
        self.assessment = LVSCorpusAssessment(
            criteria: evaluatedAssessment.criteria,
            findings: Self.mergedFindings(
                canonical: evaluatedAssessment.findings + integrityFailures,
                supplemental: assessment?.findings ?? []
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case passed
        case caseCount
        case matchedCaseCount
        case budgetExceededCaseCount
        case totalDurationSeconds
        case runOptions
        case implementationScopeCaseID
        case summary
        case assessment
        case caseResults
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported LVS corpus report schema version: \(schemaVersion)."
            )
        }
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        passed = try container.decode(Bool.self, forKey: .passed)
        caseCount = try container.decode(Int.self, forKey: .caseCount)
        matchedCaseCount = try container.decode(Int.self, forKey: .matchedCaseCount)
        budgetExceededCaseCount = try container.decode(Int.self, forKey: .budgetExceededCaseCount)
        totalDurationSeconds = try container.decode(Double.self, forKey: .totalDurationSeconds)
        runOptions = try container.decode(LVSCorpusRunOptions.self, forKey: .runOptions)
        implementationScopeCaseID = try container.decodeIfPresent(
            String.self,
            forKey: .implementationScopeCaseID
        )
        caseResults = try container.decode([LVSCorpusCaseResult].self, forKey: .caseResults)
        summary = try container.decode(LVSCorpusSummary.self, forKey: .summary)
        let decodedAssessment = try container.decode(
            LVSCorpusAssessment.self,
            forKey: .assessment
        )
        let integrityFailures = LVSCorpusReportIntegrityValidator().failures(
            passed: passed,
            caseCount: caseCount,
            matchedCaseCount: matchedCaseCount,
            budgetExceededCaseCount: budgetExceededCaseCount,
            totalDurationSeconds: totalDurationSeconds,
            summary: summary,
            caseResults: caseResults
        )
        let evaluatedAssessment = decodedAssessment.criteria.evaluate(
            passed: passed,
            caseCount: caseCount,
            summary: summary
        )
        assessment = LVSCorpusAssessment(
            criteria: evaluatedAssessment.criteria,
            findings: Self.mergedFindings(
                canonical: evaluatedAssessment.findings + integrityFailures,
                supplemental: decodedAssessment.findings
            )
        )
    }

    private static func mergedFindings(
        canonical: [LVSCorpusAssessmentFinding],
        supplemental: [LVSCorpusAssessmentFinding]
    ) -> [LVSCorpusAssessmentFinding] {
        canonical + supplemental.filter { !canonical.contains($0) }
    }
}
