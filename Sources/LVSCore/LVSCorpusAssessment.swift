public struct LVSCorpusAssessment: Sendable, Hashable, Codable {
    public let criteria: LVSCorpusAcceptanceCriteria
    public let findings: [LVSCorpusAssessmentFinding]

    public var meetsCriteria: Bool { findings.isEmpty }

    public init(
        criteria: LVSCorpusAcceptanceCriteria,
        findings: [LVSCorpusAssessmentFinding]
    ) {
        self.criteria = criteria
        self.findings = findings
    }
}
