import Foundation
import LVSCore
import LVSPersistence
import Testing

@Suite("LVS artifact contracts")
struct LVSArtifactContractTests {
    @Test func resultV2PassTruthTableRequiresCompletedMatchAndReady() {
        let statuses: [LVSExecutionStatus] = [.completed, .timedOut, .cancelled, .failed]
        let verdicts: [LVSVerificationVerdict] = [.match, .mismatch, .blocked]
        let readinessValues: [LVSReadinessStatus] = [.ready, .blocked]

        for status in statuses {
            for verdict in verdicts {
                for readiness in readinessValues {
                    let result = LVSResult(
                        backendID: "contract-test",
                        toolName: "contract-test",
                        executionStatus: status,
                        verdict: verdict,
                        readiness: readiness,
                        logPath: "",
                        diagnostics: []
                    )
                    let expected = status == .completed && verdict == .match && readiness == .ready
                    #expect(result.passed == expected)
                }
            }
        }
    }

    @Test func resultV2EncodingHasOneAuthoritativeContractAndRejectsV1() throws {
        let result = LVSResult(
            backendID: "contract-test",
            toolName: "contract-test",
            executionStatus: .completed,
            verdict: .match,
            readiness: .ready,
            logPath: "",
            diagnostics: []
        )
        let data = try JSONEncoder().encode(result)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["schemaVersion"] as? Int == LVSResult.currentSchemaVersion)
        #expect(object["passed"] == nil)
        #expect(object["completed"] == nil)

        let v1 = Data(#"{"schemaVersion":1,"backendID":"native","toolName":"native","executionStatus":"completed","verdict":"match","readiness":"ready","blockingReasons":[],"logPath":"","diagnostics":[]}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LVSResult.self, from: v1)
        }
    }

    @Test func artifactManifestV2OmitsLegacyAliasesAndRejectsIncompleteContract() throws {
        let manifest = LVSArtifactManifest(
            generatedAt: "2026-07-12T00:00:00Z",
            backendID: "native",
            toolName: "native",
            executionStatus: .completed,
            verdict: .match,
            readiness: .ready,
            blockingReasons: [],
            inputs: [],
            outputs: [],
            diagnosticSummary: LVSDiagnosticSummary(
                infoCount: 0,
                warningCount: 0,
                errorCount: 0
            )
        )
        let data = try JSONEncoder().encode(manifest)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["schemaVersion"] as? Int == LVSArtifactManifest.currentSchemaVersion)
        #expect(object["passed"] == nil)
        #expect(object["completed"] == nil)

        let incomplete = Data(#"{"schemaVersion":2,"generatedAt":"2026-07-12T00:00:00Z","backendID":"native","toolName":"native","inputs":[],"outputs":[],"diagnosticSummary":{"infoCount":0,"warningCount":0,"errorCount":0,"waivedErrorCount":0}}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LVSArtifactManifest.self, from: incomplete)
        }
    }

    @Test func runSummaryV2OmitsDerivedStatusAliasesAndRejectsV1() throws {
        let report = LVSRunSummaryReport(
            reportURL: nil,
            manifestURL: nil,
            summary: LVSRunSummary(
                executionStatus: .completed,
                verdict: .match,
                readiness: .ready,
                blockingReasons: [],
                backendID: "native",
                toolName: "native",
                topCell: "top",
                layoutInputKind: "layout-netlist",
                diagnosticSummary: LVSDiagnosticSummary(
                    infoCount: 0,
                    warningCount: 0,
                    errorCount: 0
                ),
                activeMismatchCount: 0,
                waivedMismatchCount: 0,
                mismatchBuckets: [],
                extractedLayoutNetlistURL: nil,
                unusedWaiverIDs: []
            )
        )
        let data = try JSONEncoder().encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let summary = try #require(object["summary"] as? [String: Any])

        #expect(summary["status"] == nil)
        #expect(summary["passed"] == nil)
        #expect(summary["completed"] == nil)

        let v1 = Data(#"{"schemaVersion":1,"summary":{}}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LVSRunSummaryReport.self, from: v1)
        }
    }

    @Test func nonWaivableDiagnosticCannotBeWaived() throws {
        let diagnostic = LVSDiagnostic(
            severity: .error,
            message: "Required semantic evidence is incomplete.",
            ruleID: "LVS_POLICY_BLOCKED",
            category: "readiness",
            rawLine: "blocked",
            waiverDisposition: .nonWaivable
        )
        let waiver = LVSWaiver(
            id: "attempted-readiness-waiver",
            reason: "Must not apply",
            ruleID: "LVS_POLICY_BLOCKED"
        )
        let reviewer = LVSWaiverReviewer()
        let reviewed = try reviewer.reviewedDiagnostics(
            diagnostics: [diagnostic],
            waiverFile: LVSWaiverFile(waivers: [waiver])
        )
        let retained = try #require(reviewed.first)

        #expect(!retained.isWaived)
        #expect(retained.waiverID == nil)
        #expect(retained.effectiveWaiverDisposition == .nonWaivable)
    }

    @Test func devicePolicyReportRejectsMissingEvidenceProjections() {
        let data = Data("""
        {
          "schemaVersion": 1,
          "kind": "lvs-device-policy-application-report",
          "generatedAt": "2026-07-10T00:00:00Z",
          "status": "complete",
          "policyPath": "/tmp/policy.json",
          "seedSourcePath": "/tmp/devices.tcl"
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LVSDevicePolicyApplicationReport.self, from: data)
        }
    }

    @Test func devicePolicyRunSummaryRejectsMissingCounts() {
        let data = Data(#"{"status":"complete"}"#.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LVSDevicePolicyRunSummary.self, from: data)
        }
    }

    @Test func oracleComparisonRejectsMissingDisagreementClassifications() {
        let data = Data("""
        {
          "primaryBackendID": "native",
          "oracleBackendID": "netgen",
          "passedMatched": true,
          "activeErrorRuleIDsMatched": true,
          "diagnosticSummaryMatched": true,
          "primaryPassed": true,
          "oraclePassed": true,
          "primaryActiveErrorRuleIDs": [],
          "oracleActiveErrorRuleIDs": [],
          "primaryDiagnosticSummary": {
            "infoCount": 0,
            "warningCount": 0,
            "errorCount": 0,
            "waivedErrorCount": 0
          },
          "oracleDiagnosticSummary": {
            "infoCount": 0,
            "warningCount": 0,
            "errorCount": 0,
            "waivedErrorCount": 0
          },
          "mismatchReasons": []
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LVSCorpusOracleComparison.self, from: data)
        }
    }
}
