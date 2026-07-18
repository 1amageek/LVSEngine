import Foundation
import LVSCore
import Testing

struct LVSCorpusAssessmentTests {
    @Test
    func acceptanceCriteriaDecodingRequiresEveryGate() throws {
        let criteria = LVSCorpusAcceptanceCriteria()
        let requiredKeys = [
            "requireCorpusPassed",
            "minimumPassRate",
            "minimumDurationBudgetPassRate",
            "minimumOracleCaseCount",
            "minimumOracleAgreementRate",
            "allowPrimaryExecutionFailures",
            "allowOracleExecutionFailures",
            "requiredCoverageTags",
            "requiredObservedAssertions",
            "allowBlockedAssertions",
            "allowFailedAssertions",
        ]

        for key in requiredKeys {
            let encoded = try JSONEncoder().encode(criteria)
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(LVSCorpusAcceptanceCriteria.self, from: data)
            }
        }
    }

    @Test
    func summaryDecodingRequiresCurrentObservationCounts() throws {
        let summary = LVSCorpusSummary(caseResults: [])
        let requiredKeys = [
            "observedAssertionCounts",
            "coverageTagCounts",
            "failedAssertionCount",
            "blockedAssertionCount",
        ]

        for key in requiredKeys {
            let encoded = try JSONEncoder().encode(summary)
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(LVSCorpusSummary.self, from: data)
            }
        }
    }

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
    func coverageTagsRequireACompletedCase() {
        let failed = caseResult(
            caseID: "failed",
            matched: false,
            coverageTags: ["lvs.failure-path"],
            observedAssertions: []
        )
        let passed = caseResult(
            caseID: "passed",
            matched: true,
            coverageTags: ["lvs.match", "lvs.match"],
            observedAssertions: []
        )

        let summary = LVSCorpusSummary(caseResults: [failed, passed])

        #expect(summary.coverageTagCounts == ["lvs.match": 1])
    }

    @Test
    func acceptanceCriteriaRejectMissingRequiredCoverage() {
        let result = caseResult(
            caseID: "passed",
            matched: true,
            coverageTags: ["lvs.match"],
            observedAssertions: []
        )
        let summary = LVSCorpusSummary(caseResults: [result])
        let criteria = LVSCorpusAcceptanceCriteria(
            requiredCoverageTags: ["lvs.match", "lvs.missing"]
        )

        let assessment = criteria.evaluate(passed: true, caseCount: 1, summary: summary)

        #expect(!assessment.meetsCriteria)
        #expect(assessment.findings.map(\.code).contains("required_coverage_missing"))
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

    @Test
    func duplicateCaseIdentifiersCannotInflateRetainedEvidence() {
        let result = caseResult(
            caseID: "duplicate",
            matched: true,
            coverageTags: ["lvs.match"],
            observedAssertions: [observedVerdict(.passed, value: "match")]
        )
        let results = [result, result]
        let report = LVSCorpusReport(
            passed: true,
            caseCount: results.count,
            matchedCaseCount: results.count,
            totalDurationSeconds: results.reduce(0) { $0 + $1.durationSeconds },
            summary: LVSCorpusSummary(caseResults: results),
            acceptanceCriteria: LVSCorpusAcceptanceCriteria(
                minimumOracleCaseCount: nil,
                requiredCoverageTags: ["lvs.match"],
                requiredObservedAssertions: ["verdict:match"]
            ),
            caseResults: results
        )

        #expect(!report.assessment.meetsCriteria)
        #expect(report.assessment.findings.contains { $0.code == "report_case_id_duplicate" })
    }

    @Test
    func reportSchemaVersionIdentifiesTheAssessmentContract() throws {
        let result = caseResult(
            caseID: "retained",
            matched: true,
            observedAssertions: [observedVerdict(.passed, value: "match")]
        )
        let report = LVSCorpusReport(
            passed: true,
            caseCount: 1,
            matchedCaseCount: 1,
            totalDurationSeconds: result.durationSeconds,
            implementationScopeCaseID: result.caseID,
            caseResults: [result]
        )
        let data = try JSONEncoder().encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["schemaVersion"] as? Int == 4)
        #expect(object["assessment"] is [String: Any])
        #expect(object["qualification"] == nil)
        #expect(object["implementationScopeCaseID"] as? String == result.caseID)
        #expect(object["qualificationScopeCaseID"] == nil)

        var legacyVersionObject = object
        legacyVersionObject["schemaVersion"] = 3
        let legacyVersionData = try JSONSerialization.data(withJSONObject: legacyVersionObject)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LVSCorpusReport.self, from: legacyVersionData)
        }
    }

    private func caseResult(
        caseID: String,
        matched: Bool,
        coverageTags: [String] = [],
        observedAssertions: [LVSCorpusObservedAssertion]
    ) -> LVSCorpusCaseResult {
        LVSCorpusCaseResult(
            caseID: caseID,
            matched: matched,
            expectedPassed: true,
            actualPassed: matched,
            expectedActiveErrorRuleIDs: [],
            actualActiveErrorRuleIDs: [],
            coverageTags: coverageTags,
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
