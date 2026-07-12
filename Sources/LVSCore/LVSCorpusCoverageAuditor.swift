import Foundation

public struct LVSCorpusCoverageAuditor: Sendable {
    public init() {}

    public func audit(
        report: LVSCorpusReport,
        reportPath: String? = nil,
        policy: LVSCorpusCoverageAuditPolicy = .netgenFoundryExpansion,
        auditID: String? = nil,
        checkedAt: Date? = nil
    ) -> LVSCorpusCoverageAudit {
        let observedAssertions = Set(report.summary.observedAssertionCounts.keys)
        let requiredAssertions = Set(policy.requirements.flatMap(\.requiredObservedAssertions))
        var missingRequirements = missingPolicyRequirements(
            report: report,
            policy: policy,
            observedAssertions: observedAssertions
        )
        if !policy.validationErrors.isEmpty {
            missingRequirements.append(LVSCorpusCoverageAudit.MissingRequirement(
                requirementID: "coverage-policy-validity",
                title: "Coverage policy validity",
                missingAssertions: [],
                observedCaseCount: 0,
                requiredCaseCount: 1,
                reason: policy.validationErrors.joined(separator: " "),
                suggestedActions: ["repair_lvs_corpus_coverage_policy"]
            ))
        }
        let freshness = reportFreshness(
            report: report,
            policy: policy,
            checkedAt: checkedAt
        )
        if let missingRequirement = freshness.missingRequirement {
            missingRequirements.append(missingRequirement)
        }

        if policy.requireQualifiedCorpus, !report.qualification.qualified {
            missingRequirements.append(LVSCorpusCoverageAudit.MissingRequirement(
                requirementID: "qualified-corpus",
                title: "Qualified corpus",
                missingAssertions: [],
                observedCaseCount: report.matchedCaseCount,
                requiredCaseCount: report.caseCount,
                reason: "The corpus qualification did not pass.",
                suggestedActions: ["inspect_lvs_corpus_failures", "fix_or_mark_blocked_lvs_oracle_cases"]
            ))
        }
        if policy.requireOracleAgreement, report.summary.oracleCaseCount == 0 {
            missingRequirements.append(LVSCorpusCoverageAudit.MissingRequirement(
                requirementID: "oracle-agreement",
                title: "Oracle agreement",
                missingAssertions: [],
                observedCaseCount: 0,
                requiredCaseCount: max(1, report.caseCount),
                reason: "No oracle comparison cases are present.",
                suggestedActions: ["run_lvs_corpus_with_netgen_oracle"]
            ))
        } else if policy.requireOracleAgreement,
                  report.summary.oracleAgreementPassedCaseCount < report.summary.oracleCaseCount {
            missingRequirements.append(LVSCorpusCoverageAudit.MissingRequirement(
                requirementID: "oracle-agreement",
                title: "Oracle agreement",
                missingAssertions: [],
                observedCaseCount: report.summary.oracleAgreementPassedCaseCount,
                requiredCaseCount: report.summary.oracleCaseCount,
                reason: "One or more oracle comparison cases disagree or are blocked.",
                suggestedActions: ["inspect_lvs_oracle_comparison", "classify_lvs_oracle_disagreement"]
            ))
        }
        if report.caseCount < policy.minimumCaseCount {
            missingRequirements.append(LVSCorpusCoverageAudit.MissingRequirement(
                requirementID: "minimum-case-count",
                title: "Minimum case count",
                missingAssertions: [],
                observedCaseCount: report.caseCount,
                requiredCaseCount: policy.minimumCaseCount,
                reason: "The corpus has fewer cases than the policy requires.",
                suggestedActions: ["add_lvs_oracle_corpus_cases"]
            ))
        }

        let missingRequirementIDs = Set(missingRequirements.map(\.requirementID))
        let suggestedActions = missingRequirements.flatMap { requirement in
            requirement.suggestedActions.map { action in
                LVSCorpusCoverageAudit.SuggestedAction(
                    actionID: action,
                    requirementID: requirement.requirementID,
                    reason: requirement.reason
                )
            }
        }
        let status: LVSCorpusCoverageAuditStatus = missingRequirements.isEmpty ? .satisfied : .incomplete
        let coveredRequiredAssertions = requiredAssertions.intersection(observedAssertions)
        let requiredRequirementCount = policy.requirements.count
            + (policy.requireQualifiedCorpus ? 1 : 0)
            + (policy.requireOracleAgreement ? 1 : 0)
            + (policy.maxReportAgeSeconds == nil ? 0 : 1)
            + (policy.minimumCaseCount > 0 ? 1 : 0)
            + (policy.validationErrors.isEmpty ? 0 : 1)
        return LVSCorpusCoverageAudit(
            auditID: auditID ?? defaultAuditID(reportPath: reportPath, policyID: policy.policyID),
            status: status,
            policyID: policy.policyID,
            reportPath: reportPath,
            summary: LVSCorpusCoverageAudit.Summary(
                caseCount: report.caseCount,
                matchedCaseCount: report.matchedCaseCount,
                qualified: report.qualification.qualified,
                oracleCaseCount: report.summary.oracleCaseCount,
                oracleAgreementPassedCaseCount: report.summary.oracleAgreementPassedCaseCount,
                requiredRequirementCount: requiredRequirementCount,
                satisfiedRequirementCount: max(0, requiredRequirementCount - missingRequirementIDs.count),
                missingRequirementCount: missingRequirementIDs.count,
                observedAssertionCount: observedAssertions.count,
                requiredAssertionCount: requiredAssertions.count,
                coveredRequiredAssertionCount: coveredRequiredAssertions.count,
                reportGeneratedAt: report.generatedAt,
                checkedAt: freshness.checkedAtString,
                reportAgeSeconds: freshness.ageSeconds
            ),
            observedAssertions: observedAssertions.sorted(),
            missingRequirements: missingRequirements,
            suggestedActions: uniqueSuggestedActions(suggestedActions)
        )
    }

    private func missingPolicyRequirements(
        report: LVSCorpusReport,
        policy: LVSCorpusCoverageAuditPolicy,
        observedAssertions: Set<String>
    ) -> [LVSCorpusCoverageAudit.MissingRequirement] {
        policy.requirements.compactMap { requirement in
            let requiredAssertions = Set(requirement.requiredObservedAssertions)
            let observedCaseCount = report.caseResults.filter { result in
                let resultAssertions = Set(result.observedAssertions.filter { $0.status == .passed }.map(\.coverageKey))
                return result.matched && requiredAssertions.isSubset(of: resultAssertions)
            }.count
            let jointlyObservedAssertions = Set(report.caseResults.filter(\.matched).flatMap { result in
                result.observedAssertions.filter { $0.status == .passed }.map(\.coverageKey)
            })
            let missingAssertions = requiredAssertions.subtracting(jointlyObservedAssertions).sorted()
            guard !missingAssertions.isEmpty || observedCaseCount < requirement.minimumCaseCount else {
                return nil
            }
            return LVSCorpusCoverageAudit.MissingRequirement(
                requirementID: requirement.requirementID,
                title: requirement.title,
                missingAssertions: missingAssertions,
                observedCaseCount: observedCaseCount,
                requiredCaseCount: requirement.minimumCaseCount,
                reason: missingAssertions.isEmpty
                    ? "The required observed assertions exist, but too few cases contain this requirement coverage."
                    : "Required observed assertions are missing from the corpus report.",
                suggestedActions: requirement.suggestedActions
            )
        }
    }

    private func uniqueSuggestedActions(
        _ actions: [LVSCorpusCoverageAudit.SuggestedAction]
    ) -> [LVSCorpusCoverageAudit.SuggestedAction] {
        var seen: Set<String> = []
        var result: [LVSCorpusCoverageAudit.SuggestedAction] = []
        for action in actions.sorted(by: { $0.actionID < $1.actionID }) {
            let key = "\(action.actionID):\(action.requirementID)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(action)
        }
        return result
    }

    private func defaultAuditID(reportPath: String?, policyID: String) -> String {
        guard let reportPath, !reportPath.isEmpty else {
            return "lvs-corpus-coverage-audit:\(policyID)"
        }
        return "lvs-corpus-coverage-audit:\(policyID):\(reportPath)"
    }

    private func reportFreshness(
        report: LVSCorpusReport,
        policy: LVSCorpusCoverageAuditPolicy,
        checkedAt: Date?
    ) -> (
        checkedAtString: String?,
        ageSeconds: Double?,
        missingRequirement: LVSCorpusCoverageAudit.MissingRequirement?
    ) {
        guard let maxReportAgeSeconds = policy.maxReportAgeSeconds else {
            return (checkedAt.map { iso8601String(from: $0) }, nil, nil)
        }
        guard let checkedAt else {
            return (
                nil,
                nil,
                freshnessMissingRequirement(
                    observedAgeSeconds: nil,
                    requiredAgeSeconds: maxReportAgeSeconds,
                    reason: "The coverage audit policy requires a checkedAt timestamp."
                )
            )
        }
        let checkedAtString = iso8601String(from: checkedAt)
        guard let generatedAt = report.generatedAt, !generatedAt.isEmpty else {
            return (
                checkedAtString,
                nil,
                freshnessMissingRequirement(
                    observedAgeSeconds: nil,
                    requiredAgeSeconds: maxReportAgeSeconds,
                    reason: "The retained LVS corpus report does not include generatedAt."
                )
            )
        }
        guard let generatedAtDate = iso8601Date(from: generatedAt) else {
            return (
                checkedAtString,
                nil,
                freshnessMissingRequirement(
                    observedAgeSeconds: nil,
                    requiredAgeSeconds: maxReportAgeSeconds,
                    reason: "The retained LVS corpus report generatedAt timestamp is invalid."
                )
            )
        }
        let ageSeconds = checkedAt.timeIntervalSince(generatedAtDate)
        if ageSeconds < 0 {
            return (
                checkedAtString,
                ageSeconds,
                freshnessMissingRequirement(
                    observedAgeSeconds: ageSeconds,
                    requiredAgeSeconds: maxReportAgeSeconds,
                    reason: "The retained LVS corpus report generatedAt timestamp is newer than checkedAt."
                )
            )
        }
        if ageSeconds > maxReportAgeSeconds {
            return (
                checkedAtString,
                ageSeconds,
                freshnessMissingRequirement(
                    observedAgeSeconds: ageSeconds,
                    requiredAgeSeconds: maxReportAgeSeconds,
                    reason: "The retained LVS corpus report is older than the coverage audit policy allows."
                )
            )
        }
        return (checkedAtString, ageSeconds, nil)
    }

    private func freshnessMissingRequirement(
        observedAgeSeconds: Double?,
        requiredAgeSeconds: Double,
        reason: String
    ) -> LVSCorpusCoverageAudit.MissingRequirement {
        LVSCorpusCoverageAudit.MissingRequirement(
            requirementID: "retained-report-freshness",
            title: "Retained report freshness",
            missingAssertions: [],
            observedCaseCount: observedAgeSeconds.map(boundedNonnegativeInt) ?? 0,
            requiredCaseCount: boundedNonnegativeInt(requiredAgeSeconds),
            reason: reason,
            suggestedActions: ["rerun_lvs_corpus_and_retain_report"]
        )
    }

    private func iso8601Date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func boundedNonnegativeInt(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        guard value < Double(Int.max) else { return Int.max }
        return Int(value)
    }
}
