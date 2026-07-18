public struct LVSCorpusAcceptanceCriteria: Sendable, Hashable, Codable {
    public static let strict = LVSCorpusAcceptanceCriteria(
        requiredObservedAssertions: [
            "durationBudget:within-budget",
            "verdict:match",
            "verdict:mismatch",
        ]
    )

    public let requireCorpusPassed: Bool
    public let minimumPassRate: Double
    public let minimumDurationBudgetPassRate: Double
    public let minimumOracleCaseCount: Int?
    public let minimumOracleAgreementRate: Double?
    public let allowPrimaryExecutionFailures: Bool
    public let allowOracleExecutionFailures: Bool
    public let requiredCoverageTags: [String]
    public let requiredObservedAssertions: [String]
    public let allowBlockedAssertions: Bool
    public let allowFailedAssertions: Bool

    private enum CodingKeys: String, CodingKey {
        case requireCorpusPassed
        case minimumPassRate
        case minimumDurationBudgetPassRate
        case minimumOracleCaseCount
        case minimumOracleAgreementRate
        case allowPrimaryExecutionFailures
        case allowOracleExecutionFailures
        case requiredCoverageTags
        case requiredObservedAssertions
        case allowBlockedAssertions
        case allowFailedAssertions
    }

    public init(
        requireCorpusPassed: Bool = true,
        minimumPassRate: Double = 1,
        minimumDurationBudgetPassRate: Double = 1,
        minimumOracleCaseCount: Int? = nil,
        minimumOracleAgreementRate: Double? = nil,
        allowPrimaryExecutionFailures: Bool = false,
        allowOracleExecutionFailures: Bool = false,
        requiredCoverageTags: [String] = [],
        requiredObservedAssertions: [String] = [],
        allowBlockedAssertions: Bool = false,
        allowFailedAssertions: Bool = false
    ) {
        self.requireCorpusPassed = requireCorpusPassed
        self.minimumPassRate = minimumPassRate
        self.minimumDurationBudgetPassRate = minimumDurationBudgetPassRate
        self.minimumOracleCaseCount = minimumOracleCaseCount
        self.minimumOracleAgreementRate = minimumOracleAgreementRate
        self.allowPrimaryExecutionFailures = allowPrimaryExecutionFailures
        self.allowOracleExecutionFailures = allowOracleExecutionFailures
        self.requiredCoverageTags = Self.normalizedValues(requiredCoverageTags)
        self.requiredObservedAssertions = Self.normalizedAssertions(requiredObservedAssertions)
        self.allowBlockedAssertions = allowBlockedAssertions
        self.allowFailedAssertions = allowFailedAssertions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requireCorpusPassed = try container.decode(Bool.self, forKey: .requireCorpusPassed)
        minimumPassRate = try container.decode(Double.self, forKey: .minimumPassRate)
        minimumDurationBudgetPassRate = try container.decode(
            Double.self,
            forKey: .minimumDurationBudgetPassRate
        )
        guard container.contains(.minimumOracleCaseCount),
              container.contains(.minimumOracleAgreementRate) else {
            throw DecodingError.keyNotFound(
                CodingKeys.minimumOracleCaseCount,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "LVS corpus acceptance criteria must declare every fail-closed gate."
                )
            )
        }
        minimumOracleCaseCount = try container.decodeIfPresent(Int.self, forKey: .minimumOracleCaseCount)
        minimumOracleAgreementRate = try container.decodeIfPresent(Double.self, forKey: .minimumOracleAgreementRate)
        allowPrimaryExecutionFailures = try container.decode(
            Bool.self,
            forKey: .allowPrimaryExecutionFailures
        )
        allowOracleExecutionFailures = try container.decode(
            Bool.self,
            forKey: .allowOracleExecutionFailures
        )
        requiredCoverageTags = Self.normalizedValues(try container.decode(
            [String].self,
            forKey: .requiredCoverageTags
        ))
        requiredObservedAssertions = Self.normalizedAssertions(try container.decode(
            [String].self,
            forKey: .requiredObservedAssertions
        ))
        allowBlockedAssertions = try container.decode(
            Bool.self,
            forKey: .allowBlockedAssertions
        )
        allowFailedAssertions = try container.decode(
            Bool.self,
            forKey: .allowFailedAssertions
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requireCorpusPassed, forKey: .requireCorpusPassed)
        try container.encode(minimumPassRate, forKey: .minimumPassRate)
        try container.encode(minimumDurationBudgetPassRate, forKey: .minimumDurationBudgetPassRate)
        try container.encode(minimumOracleCaseCount, forKey: .minimumOracleCaseCount)
        try container.encode(minimumOracleAgreementRate, forKey: .minimumOracleAgreementRate)
        try container.encode(allowPrimaryExecutionFailures, forKey: .allowPrimaryExecutionFailures)
        try container.encode(allowOracleExecutionFailures, forKey: .allowOracleExecutionFailures)
        try container.encode(requiredCoverageTags, forKey: .requiredCoverageTags)
        try container.encode(requiredObservedAssertions, forKey: .requiredObservedAssertions)
        try container.encode(allowBlockedAssertions, forKey: .allowBlockedAssertions)
        try container.encode(allowFailedAssertions, forKey: .allowFailedAssertions)
    }

    public func evaluate(
        passed: Bool,
        caseCount: Int,
        summary: LVSCorpusSummary
    ) -> LVSCorpusAssessment {
        var findings = validationFailures()
        if caseCount == 0 {
            findings.append(LVSCorpusAssessmentFinding(
                code: "empty_corpus",
                message: "The corpus did not run any cases.",
                observedCount: 0,
                requiredCount: 1
            ))
        }
        if requireCorpusPassed && !passed {
            findings.append(LVSCorpusAssessmentFinding(
                code: "corpus_not_passed",
                message: "The corpus did not pass every case, duration budget, and oracle agreement gate."
            ))
        }
        if summary.passRate < minimumPassRate {
            findings.append(LVSCorpusAssessmentFinding(
                code: "pass_rate_below_minimum",
                message: "The corpus pass rate is below the required threshold.",
                observedDouble: summary.passRate,
                requiredDouble: minimumPassRate
            ))
        }
        let durationBudgetPassRate = caseCount == 0
            ? 0
            : Double(summary.durationBudgetPassedCaseCount) / Double(caseCount)
        if durationBudgetPassRate < minimumDurationBudgetPassRate {
            findings.append(LVSCorpusAssessmentFinding(
                code: "duration_budget_pass_rate_below_minimum",
                message: "The corpus duration-budget pass rate is below the required threshold.",
                observedDouble: durationBudgetPassRate,
                requiredDouble: minimumDurationBudgetPassRate
            ))
        }
        if let minimumOracleCaseCount,
           summary.oracleCaseCount < minimumOracleCaseCount {
            findings.append(LVSCorpusAssessmentFinding(
                code: "oracle_case_count_below_minimum",
                message: "The corpus did not run enough oracle comparison cases.",
                observedCount: summary.oracleCaseCount,
                requiredCount: minimumOracleCaseCount
            ))
        }
        if let minimumOracleAgreementRate {
            if let oracleAgreementRate = summary.oracleAgreementRate {
                if oracleAgreementRate < minimumOracleAgreementRate {
                    findings.append(LVSCorpusAssessmentFinding(
                        code: "oracle_agreement_rate_below_minimum",
                        message: "The corpus oracle agreement rate is below the required threshold.",
                        observedDouble: oracleAgreementRate,
                        requiredDouble: minimumOracleAgreementRate
                    ))
                }
            } else {
                findings.append(LVSCorpusAssessmentFinding(
                    code: "oracle_agreement_rate_missing",
                    message: "The corpus acceptance criteria requires oracle agreement, but no oracle cases ran.",
                    observedCount: summary.oracleCaseCount
                ))
            }
        }
        if !allowPrimaryExecutionFailures && summary.primaryExecutionFailedCaseCount > 0 {
            findings.append(LVSCorpusAssessmentFinding(
                code: "primary_execution_failed",
                message: "One or more primary corpus cases failed to execute.",
                observedCount: summary.primaryExecutionFailedCaseCount,
                requiredCount: 0
            ))
        }
        if !allowOracleExecutionFailures && summary.oracleExecutionFailedCaseCount > 0 {
            findings.append(LVSCorpusAssessmentFinding(
                code: "oracle_execution_failed",
                message: "One or more oracle corpus cases failed to execute.",
                observedCount: summary.oracleExecutionFailedCaseCount,
                requiredCount: 0
            ))
        }
        let missingCoverageTags = requiredCoverageTags.filter {
            summary.coverageTagCounts[$0] == nil
        }
        if !missingCoverageTags.isEmpty {
            findings.append(LVSCorpusAssessmentFinding(
                code: "required_coverage_missing",
                message: "The corpus is missing one or more required coverage tags.",
                observedCount: requiredCoverageTags.count - missingCoverageTags.count,
                requiredCount: requiredCoverageTags.count,
                observedText: summary.coverageTagCounts.keys.sorted().joined(separator: ","),
                requiredText: missingCoverageTags.joined(separator: ",")
            ))
        }
        let missingAssertions = requiredObservedAssertions.filter {
            summary.observedAssertionCounts[$0] == nil
        }
        if !missingAssertions.isEmpty {
            findings.append(LVSCorpusAssessmentFinding(
                code: "required_observed_assertion_missing",
                message: "The corpus is missing one or more successful observed assertions.",
                observedCount: requiredObservedAssertions.count - missingAssertions.count,
                requiredCount: requiredObservedAssertions.count,
                observedText: summary.observedAssertionCounts.keys.sorted().joined(separator: ","),
                requiredText: missingAssertions.joined(separator: ",")
            ))
        }
        if !allowFailedAssertions && summary.failedAssertionCount > 0 {
            findings.append(LVSCorpusAssessmentFinding(
                code: "observed_assertion_failed",
                message: "One or more required observed assertions failed.",
                observedCount: summary.failedAssertionCount,
                requiredCount: 0
            ))
        }
        if !allowBlockedAssertions && summary.blockedAssertionCount > 0 {
            findings.append(LVSCorpusAssessmentFinding(
                code: "observed_assertion_blocked",
                message: "One or more required observed assertions were blocked.",
                observedCount: summary.blockedAssertionCount,
                requiredCount: 0
            ))
        }
        return LVSCorpusAssessment(criteria: self, findings: findings)
    }

    private func validationFailures() -> [LVSCorpusAssessmentFinding] {
        var findings: [LVSCorpusAssessmentFinding] = []
        if minimumPassRate < 0 || minimumPassRate > 1 || !minimumPassRate.isFinite {
            findings.append(LVSCorpusAssessmentFinding(
                code: "invalid_minimum_pass_rate",
                message: "minimumPassRate must be a finite value between 0 and 1.",
                observedDouble: minimumPassRate
            ))
        }
        if minimumDurationBudgetPassRate < 0
            || minimumDurationBudgetPassRate > 1
            || !minimumDurationBudgetPassRate.isFinite {
            findings.append(LVSCorpusAssessmentFinding(
                code: "invalid_minimum_duration_budget_pass_rate",
                message: "minimumDurationBudgetPassRate must be a finite value between 0 and 1.",
                observedDouble: minimumDurationBudgetPassRate
            ))
        }
        if let minimumOracleAgreementRate,
           minimumOracleAgreementRate < 0
            || minimumOracleAgreementRate > 1
            || !minimumOracleAgreementRate.isFinite {
            findings.append(LVSCorpusAssessmentFinding(
                code: "invalid_minimum_oracle_agreement_rate",
                message: "minimumOracleAgreementRate must be a finite value between 0 and 1.",
                observedDouble: minimumOracleAgreementRate
            ))
        }
        if let minimumOracleCaseCount,
           minimumOracleCaseCount < 0 {
            findings.append(LVSCorpusAssessmentFinding(
                code: "invalid_minimum_oracle_case_count",
                message: "minimumOracleCaseCount must be zero or greater.",
                observedCount: minimumOracleCaseCount
            ))
        }
        return findings
    }

    private static func normalizedAssertions(_ assertions: [String]) -> [String] {
        normalizedValues(assertions)
    }

    private static func normalizedValues(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }
}
