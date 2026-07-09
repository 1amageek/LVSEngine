import Foundation
import LVSCore
import Testing

@Suite("LVS corpus oracle result")
struct LVSCorpusOracleResultTests {
    @Test func oracleResultNormalizesDiagnosticDerivedFields() throws {
        let result = LVSCorpusOracleResult(
            backendID: "netgen",
            passed: false,
            activeErrorRuleIDs: ["STALE_RULE"],
            diagnostics: [
                LVSDiagnostic(
                    severity: .warning,
                    message: "Terminal order differs.",
                    ruleID: "LVS_TERMINAL_WARNING",
                    rawLine: "warning"
                ),
                LVSDiagnostic(
                    severity: .error,
                    message: "Model mismatch.",
                    ruleID: "LVS_MODEL_MISMATCH",
                    rawLine: "model mismatch"
                ),
                LVSDiagnostic(
                    severity: .error,
                    message: "Waived port mismatch.",
                    ruleID: "LVS_PORT_MISMATCH",
                    waiverID: "waive-port",
                    waiverReason: "Known fixture waiver",
                    rawLine: "waived mismatch"
                ),
            ],
            diagnosticSummary: LVSDiagnosticSummary(infoCount: 0, warningCount: 0, errorCount: 0),
            durationSeconds: 0.12,
            agreementPassed: false,
            failureReasons: ["oracle_agreement_mismatch"],
            reportPath: "/tmp/oracle/lvs-report.json",
            manifestPath: "/tmp/oracle/lvs-artifact-manifest.json",
            extractedLayoutNetlistPath: nil
        )

        #expect(result.activeErrorRuleIDs == ["LVS_MODEL_MISMATCH"])
        #expect(result.diagnosticSummary == LVSDiagnosticSummary(
            infoCount: 0,
            warningCount: 1,
            errorCount: 1,
            waivedErrorCount: 1
        ))
        #expect(result.integrityDiagnostics.map(\.code) == [
            "lvs_oracle_active_rule_ids_normalized",
            "lvs_oracle_diagnostic_summary_normalized",
        ])
        #expect(result.integrityDiagnostics.allSatisfy { !$0.suggestedActions.isEmpty })
    }

    @Test func decoderNormalizesInconsistentArtifactWithDiagnostics() throws {
        let json = """
        {
          "backendID": "netgen",
          "passed": false,
          "activeErrorRuleIDs": ["STALE_RULE"],
          "diagnostics": [
            {
              "severity": "error",
              "message": "Model mismatch.",
              "ruleID": "LVS_MODEL_MISMATCH",
              "rawLine": "model mismatch"
            }
          ],
          "diagnosticSummary": {
            "infoCount": 0,
            "warningCount": 0,
            "errorCount": 0,
            "waivedErrorCount": 0
          },
          "durationSeconds": 0.01,
          "agreementPassed": false,
          "failureReasons": ["oracle_agreement_mismatch"],
          "executionError": null,
          "reportPath": "/tmp/report.json",
          "manifestPath": "/tmp/manifest.json",
          "extractedLayoutNetlistPath": null
        }
        """

        let result = try JSONDecoder().decode(
            LVSCorpusOracleResult.self,
            from: Data(json.utf8)
        )

        #expect(result.activeErrorRuleIDs == ["LVS_MODEL_MISMATCH"])
        #expect(result.diagnosticSummary.errorCount == 1)
        #expect(result.integrityDiagnostics.contains {
            $0.code == "lvs_oracle_diagnostic_summary_normalized"
                && $0.suggestedActions.contains("compare_oracle_summary_with_diagnostics")
        })
    }

    @Test func legacyArtifactWithoutDiagnosticsKeepsExplicitSummary() throws {
        let json = """
        {
          "backendID": "native",
          "passed": false,
          "activeErrorRuleIDs": ["LVS_MODEL_MISMATCH"],
          "diagnosticSummary": {
            "infoCount": 0,
            "warningCount": 0,
            "errorCount": 1,
            "waivedErrorCount": 0
          },
          "durationSeconds": 0.01,
          "agreementPassed": true,
          "failureReasons": [],
          "executionError": null,
          "reportPath": "/tmp/report.json",
          "manifestPath": "/tmp/manifest.json",
          "extractedLayoutNetlistPath": null
        }
        """

        let result = try JSONDecoder().decode(
            LVSCorpusOracleResult.self,
            from: Data(json.utf8)
        )

        #expect(result.activeErrorRuleIDs == ["LVS_MODEL_MISMATCH"])
        #expect(result.diagnosticSummary.errorCount == 1)
        #expect(result.integrityDiagnostics.isEmpty)
        #expect(result.readinessStatus == .ready)
    }
}
