public struct LVSCorpusReportIntegrityValidator: Sendable {
    public init() {}

    public func failures(
        passed: Bool,
        caseCount: Int,
        matchedCaseCount: Int,
        budgetExceededCaseCount: Int,
        totalDurationSeconds: Double,
        summary: LVSCorpusSummary,
        caseResults: [LVSCorpusCaseResult]
    ) -> [LVSCorpusAssessmentFinding] {
        var failures: [LVSCorpusAssessmentFinding] = []
        let canonicalSummary = LVSCorpusSummary(caseResults: caseResults)
        appendCountFailure(
            code: "report_case_count_inconsistent",
            message: "Report caseCount does not match the retained case results.",
            observed: caseCount,
            canonical: caseResults.count,
            to: &failures
        )
        appendCountFailure(
            code: "report_matched_case_count_inconsistent",
            message: "Report matchedCaseCount does not match the retained case results.",
            observed: matchedCaseCount,
            canonical: caseResults.filter(\.matched).count,
            to: &failures
        )
        appendCountFailure(
            code: "report_budget_count_inconsistent",
            message: "Report budgetExceededCaseCount does not match the retained case results.",
            observed: budgetExceededCaseCount,
            canonical: caseResults.filter { !$0.durationBudgetPassed }.count,
            to: &failures
        )
        let canonicalPassed = !caseResults.isEmpty && caseResults.allSatisfy(\.matched)
        if passed != canonicalPassed {
            failures.append(LVSCorpusAssessmentFinding(
                code: "report_passed_inconsistent",
                message: "Report passed does not match the retained case results.",
                observedText: "\(passed)",
                requiredText: "\(canonicalPassed)"
            ))
        }
        let canonicalDuration = caseResults.reduce(0) { $0 + $1.durationSeconds }
        if !totalDurationSeconds.isFinite || abs(totalDurationSeconds - canonicalDuration) > 1e-9 {
            failures.append(LVSCorpusAssessmentFinding(
                code: "report_duration_inconsistent",
                message: "Report totalDurationSeconds does not match the retained case results.",
                observedDouble: totalDurationSeconds,
                requiredDouble: canonicalDuration
            ))
        }
        if summary != canonicalSummary {
            failures.append(LVSCorpusAssessmentFinding(
                code: "report_summary_inconsistent",
                message: "Report summary does not match values derived from retained case results."
            ))
        }
        let normalizedCaseIDs = caseResults.map {
            $0.caseID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if normalizedCaseIDs.contains(where: \.isEmpty) {
            failures.append(LVSCorpusAssessmentFinding(
                code: "report_case_id_empty",
                message: "Retained case identifiers must not be empty."
            ))
        }
        let duplicateCaseIDs = Dictionary(grouping: normalizedCaseIDs, by: { $0 })
            .filter { !$0.key.isEmpty && $0.value.count > 1 }
            .keys
            .sorted()
        if !duplicateCaseIDs.isEmpty {
            failures.append(LVSCorpusAssessmentFinding(
                code: "report_case_id_duplicate",
                message: "Retained case identifiers must be unique.",
                observedCount: duplicateCaseIDs.count,
                requiredCount: 0,
                observedText: duplicateCaseIDs.joined(separator: ",")
            ))
        }
        let invalidDurationCaseIDs = caseResults.filter {
            !$0.durationSeconds.isFinite || $0.durationSeconds < 0
        }.map(\.caseID)
        if !invalidDurationCaseIDs.isEmpty {
            failures.append(LVSCorpusAssessmentFinding(
                code: "report_case_duration_invalid",
                message: "Retained case durations must be finite and zero or greater.",
                observedCount: invalidDurationCaseIDs.count,
                requiredCount: 0,
                observedText: invalidDurationCaseIDs.sorted().joined(separator: ",")
            ))
        }
        let invalidBudgetCaseIDs = caseResults.filter { result in
            guard let maximum = result.expectedMaxDurationSeconds else {
                return false
            }
            guard maximum.isFinite, maximum >= 0, result.durationSeconds.isFinite else {
                return true
            }
            return result.durationBudgetPassed != (result.durationSeconds <= maximum)
        }.map(\.caseID)
        if !invalidBudgetCaseIDs.isEmpty {
            failures.append(LVSCorpusAssessmentFinding(
                code: "report_case_duration_budget_inconsistent",
                message: "Retained duration-budget verdicts must match their duration limits.",
                observedCount: invalidBudgetCaseIDs.count,
                requiredCount: 0,
                observedText: invalidBudgetCaseIDs.sorted().joined(separator: ",")
            ))
        }
        return failures
    }

    private func appendCountFailure(
        code: String,
        message: String,
        observed: Int,
        canonical: Int,
        to failures: inout [LVSCorpusAssessmentFinding]
    ) {
        guard observed != canonical else { return }
        failures.append(LVSCorpusAssessmentFinding(
            code: code,
            message: message,
            observedCount: observed,
            requiredCount: canonical
        ))
    }
}
