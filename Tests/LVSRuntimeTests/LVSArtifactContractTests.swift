import Foundation
import LVSCore
import Testing

@Suite("LVS artifact contracts")
struct LVSArtifactContractTests {
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
