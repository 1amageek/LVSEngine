import LVSCore
import Testing

struct LVSCorpusAssessmentTests {
    @Test
    func coverageRequiresAnObservedPassingAssertion() {
        let failed = caseResult(
            caseID: "failed",
            matched: false,
            observedAssertions: [observedVerdict(.failed, value: "mismatch")]
        )
        let passed = caseResult(
            caseID: "passed",
            matched: true,
            observedAssertions: [observedVerdict(.passed, value: "match")]
        )

        let summary = LVSCorpusSummary(caseResults: [failed, passed])

        #expect(summary.observedAssertionCounts["verdict:mismatch"] == nil)
        #expect(summary.observedAssertionCounts["verdict:match"] == 1)
    }

    @Test
    func implementationIdentityRejectsSelfOracle() {
        let primary = LVSImplementationIdentity(
            implementationID: "netgen-external",
            binaryDigest: "binary",
            algorithmVersion: "netgen",
            processProfileID: "sky130",
            deckDigest: "deck"
        )
        let same = primary
        let independent = LVSImplementationIdentity(
            implementationID: "lvsengine-native",
            binaryDigest: "other-binary",
            algorithmVersion: "canonical-graph-v2",
            processProfileID: "sky130",
            deckDigest: "deck"
        )

        #expect(!same.isIndependent(from: primary))
        #expect(independent.isIndependent(from: primary))
    }

    @Test
    func inconsistentReportCannotMeetAcceptanceCriteria() {
        let result = caseResult(
            caseID: "retained",
            matched: false,
            observedAssertions: [observedVerdict(.failed, value: "match")]
        )
        let forgedSummary = LVSCorpusSummary(
            expectationMatchedCaseCount: 1,
            durationBudgetPassedCaseCount: 1,
            primaryExecutionFailedCaseCount: 0,
            oracleCaseCount: 0,
            oracleAgreementPassedCaseCount: 0,
            oracleExecutionFailedCaseCount: 0,
            failureCategoryCounts: [:],
            observedAssertionCounts: ["verdict:match": 1],
            passRate: 1,
            oracleAgreementRate: nil
        )
        let report = LVSCorpusReport(
            passed: true,
            caseCount: 1,
            matchedCaseCount: 1,
            totalDurationSeconds: result.durationSeconds,
            summary: forgedSummary,
            assessment: LVSCorpusAssessment(
                criteria: .strict,
                findings: []
            ),
            caseResults: [result]
        )

        #expect(!report.assessment.meetsCriteria)
        let failureCodes = Set(report.assessment.findings.map(\.code))
        #expect(failureCodes.contains("report_passed_inconsistent"))
        #expect(failureCodes.contains("report_matched_case_count_inconsistent"))
        #expect(failureCodes.contains("report_summary_inconsistent"))
    }

    private func caseResult(
        caseID: String,
        matched: Bool,
        observedAssertions: [LVSCorpusObservedAssertion]
    ) -> LVSCorpusCaseResult {
        LVSCorpusCaseResult(
            caseID: caseID,
            matched: matched,
            expectedPassed: true,
            actualPassed: matched,
            expectedActiveErrorRuleIDs: [],
            actualActiveErrorRuleIDs: [],
            expectationMatched: matched,
            durationSeconds: 0.1,
            expectedMaxDurationSeconds: 1,
            durationBudgetPassed: true,
            failureReasons: matched ? [] : ["expectation_mismatch"],
            diagnosticSummary: LVSDiagnosticSummary(
                infoCount: 0,
                warningCount: 0,
                errorCount: matched ? 0 : 1
            ),
            reportPath: nil,
            manifestPath: nil,
            extractedLayoutNetlistPath: nil,
            observedAssertions: observedAssertions
        )
    }

    private func observedVerdict(
        _ status: LVSCorpusAssertionStatus,
        value: String
    ) -> LVSCorpusObservedAssertion {
        LVSCorpusObservedAssertion(
            assertionID: "verdict",
            kind: .verdict,
            status: status,
            expectedValue: value,
            observedValue: value,
            sourceArtifactRefs: ["manifest.json"]
        )
    }
}
