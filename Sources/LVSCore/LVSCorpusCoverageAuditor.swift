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
        let observedTags = Set(report.summary.coverageTagCounts.keys)
        let requiredTags = Set(policy.requirements.flatMap(\.requiredCoverageTags))
        var missingRequirements = missingPolicyRequirements(
            report: report,
            policy: policy,
            observedTags: observedTags
        )
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
                missingCoverageTags: [],
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
                missingCoverageTags: [],
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
                missingCoverageTags: [],
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
                missingCoverageTags: [],
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
        let coveredRequiredTags = requiredTags.intersection(observedTags)
        let requiredRequirementCount = policy.requirements.count
            + (policy.requireQualifiedCorpus ? 1 : 0)
            + (policy.requireOracleAgreement ? 1 : 0)
            + (policy.maxReportAgeSeconds == nil ? 0 : 1)
            + (policy.minimumCaseCount > 0 ? 1 : 0)
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
                observedCoverageTagCount: observedTags.count,
                requiredCoverageTagCount: requiredTags.count,
                coveredRequiredCoverageTagCount: coveredRequiredTags.count,
                reportGeneratedAt: report.generatedAt,
                checkedAt: freshness.checkedAtString,
                reportAgeSeconds: freshness.ageSeconds
            ),
            observedCoverageTags: observedTags.sorted(),
            missingRequirements: missingRequirements,
            suggestedActions: uniqueSuggestedActions(suggestedActions)
        )
    }

    private func missingPolicyRequirements(
        report: LVSCorpusReport,
        policy: LVSCorpusCoverageAuditPolicy,
        observedTags: Set<String>
    ) -> [LVSCorpusCoverageAudit.MissingRequirement] {
        policy.requirements.compactMap { requirement in
            let requiredTags = Set(requirement.requiredCoverageTags)
            let missingTags = requiredTags.subtracting(observedTags).sorted()
            let observedCaseCount = report.caseResults.filter { result in
                let resultTags = Set(result.coverageTags)
                return requiredTags.isEmpty || !resultTags.intersection(requiredTags).isEmpty
            }.count
            guard !missingTags.isEmpty || observedCaseCount < requirement.minimumCaseCount else {
                return nil
            }
            return LVSCorpusCoverageAudit.MissingRequirement(
                requirementID: requirement.requirementID,
                title: requirement.title,
                missingCoverageTags: missingTags,
                observedCaseCount: observedCaseCount,
                requiredCaseCount: requirement.minimumCaseCount,
                reason: missingTags.isEmpty
                    ? "The required coverage tags exist, but too few cases contain this requirement coverage."
                    : "Required coverage tags are missing from the corpus report.",
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
            missingCoverageTags: [],
            observedCaseCount: observedAgeSeconds.map { max(0, Int($0)) } ?? 0,
            requiredCaseCount: Int(requiredAgeSeconds),
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
}
