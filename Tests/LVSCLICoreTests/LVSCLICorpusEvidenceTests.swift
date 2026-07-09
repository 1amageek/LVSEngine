import Foundation
import LVSCLICore
import LVSCore
import Testing

extension LVSCLIOptionsTests {
  @Test func corpusEvidenceOptionsParseCheckedAtAndEvidenceID() throws {
    let options = try LVSCorpusEvidenceCLIOptions(arguments: [
      "--evidence-from-corpus-report", "/tmp/lvs-corpus-report.json",
      "--evidence-id", "lvs-release-corpus",
      "--checked-at", "2026-06-18T00:00:00Z",
      "--json",
    ])

    #expect(options.reportURL.path(percentEncoded: false) == "/tmp/lvs-corpus-report.json")
    #expect(options.evidenceID == "lvs-release-corpus")
    #expect(options.checkedAt.timeIntervalSince1970 == 1_781_740_800)
    #expect(options.emitJSON)
  }

  @Test func corpusEvidenceOptionsRejectOptionTokenAsEvidenceID() throws {
    let error = try captureError {
      _ = try LVSCorpusEvidenceCLIOptions(arguments: [
        "--evidence-from-corpus-report", "/tmp/lvs-corpus-report.json",
        "--evidence-id", "--checked-at",
        "2026-06-18T00:00:00Z",
      ])
    }

    #expect(error == .missingValue("--evidence-id"))
  }

  @Test func evidencePacketOptionsParseReportOutputAndPacketID() throws {
    let options = try LVSEvidencePacketCLIOptions(arguments: [
      "--evidence-packet-from-corpus-report", "/tmp/lvs-corpus-report.json",
      "--out", "/tmp/lvs-evidence-packet.json",
      "--packet-id", "lvs-evidence-release",
      "--json",
    ])

    #expect(options.reportURL.path(percentEncoded: false) == "/tmp/lvs-corpus-report.json")
    #expect(options.outputURL?.path(percentEncoded: false) == "/tmp/lvs-evidence-packet.json")
    #expect(options.packetID == "lvs-evidence-release")
    #expect(options.artifactRootURL == nil)
    #expect(options.emitJSON)
  }

  @Test func evidencePacketOptionsParseArtifactRoot() throws {
    let options = try LVSEvidencePacketCLIOptions(arguments: [
      "--evidence-packet-from-corpus-report", "/tmp/lvs-corpus-report.json",
      "--artifact-root", "/tmp/lvs-corpus-artifacts",
    ])

    #expect(options.artifactRootURL?.path(percentEncoded: false) == "/tmp/lvs-corpus-artifacts")
  }

  @Test func evidencePacketOptionsRejectEmptyPacketID() throws {
    let error = try captureError {
      _ = try LVSEvidencePacketCLIOptions(arguments: [
        "--evidence-packet-from-corpus-report", "/tmp/lvs-corpus-report.json",
        "--packet-id", "",
      ])
    }

    #expect(
      error
        == .invalidValue(
          argument: "--packet-id",
          value: "",
          expected: "non-empty packet ID"
        ))
  }

  @Test func evidencePacketOptionsRejectOptionTokenAsArtifactRoot() throws {
    let error = try captureError {
      _ = try LVSEvidencePacketCLIOptions(arguments: [
        "--evidence-packet-from-corpus-report", "/tmp/lvs-corpus-report.json",
        "--artifact-root", "--json",
      ])
    }

    #expect(error == .missingValue("--artifact-root"))
  }

  @Test func corpusToolEvidenceExportMatchesRuntimeEvidenceShape() throws {
    let report = LVSCorpusReport(
      passed: true,
      caseCount: 2,
      matchedCaseCount: 2,
      budgetExceededCaseCount: 0,
      totalDurationSeconds: 0.25,
      summary: LVSCorpusSummary(
        expectationMatchedCaseCount: 2,
        durationBudgetPassedCaseCount: 2,
        primaryExecutionFailedCaseCount: 0,
        oracleCaseCount: 2,
        oracleAgreementPassedCaseCount: 2,
        oracleExecutionFailedCaseCount: 0,
        oracleReadinessBlockedCaseCount: 0,
        failureCategoryCounts: [:],
        passRate: 1,
        oracleAgreementRate: 1
      ),
      caseResults: []
    )

    let export = LVSCorpusToolEvidenceExport(
      reportPath: "/tmp/lvs-corpus-report.json",
      reportSHA256: "abc123",
      report: report,
      evidenceID: "lvs-release-corpus",
      checkedAt: Date(timeIntervalSince1970: 1_781_740_800)
    )

    #expect(export.status == "passed")
    #expect(export.toolEvidence.evidenceID == "lvs-release-corpus")
    #expect(export.toolEvidence.kind == "corpus")
    #expect(export.toolEvidence.checkedAt == "2026-06-18T00:00:00Z")
    #expect(export.toolEvidence.artifact.kind == "report")
    #expect(export.toolEvidence.artifact.format == "JSON")
    #expect(export.toolEvidence.artifact.sha256 == "abc123")
    #expect(export.toolEvidence.qualification.qualified)
    #expect(export.toolEvidence.qualification.policyID == "strict")
    #expect(export.toolEvidence.qualification.observedMetrics["passRate"] == 1)
    #expect(export.toolEvidence.qualification.observedMetrics["durationBudgetPassRate"] == 1)
    #expect(export.toolEvidence.qualification.observedMetrics["oracleAgreementRate"] == 1)
    #expect(export.toolEvidence.qualification.observedCounts["caseCount"] == 2)
    #expect(export.toolEvidence.qualification.observedCounts["coverageTagCount"] == 0)
    #expect(
      export.toolEvidence.qualification.observedCounts["oracleReadinessBlockedCaseCount"] == 0)
    #expect(export.toolEvidence.qualification.observedCounts["requiredCoverageTagCount"] == 0)
    #expect(
      export.toolEvidence.qualification.observedCounts["coveredRequiredCoverageTagCount"] == 0)
    #expect(export.toolEvidence.qualification.failureCodes.isEmpty)
  }

  @Test func corpusEvidencePacketBuildsAgentDecisionMaterial() throws {
    let report = failingLVSCorpusReport()
    let reportSHA256 = String(repeating: "a", count: 64)

    let packet = LVSCorpusEvidencePacketBuilder().build(
      report: report,
      reportPath: "/tmp/lvs-corpus-report.json",
      reportSHA256: reportSHA256,
      packetID: "lvs-evidence-release"
    )

    #expect(packet.packetID == "lvs-evidence-release")
    #expect(packet.domain == "lvs.signoff-evidence")
    #expect(packet.inputs.first?.sha256 == reportSHA256)
    #expect(packet.validateIntegrity().isEmpty)
    #expect(
      packet.readiness.contains { $0.component == "lvs-corpus-evidence" && $0.status == .ready })
    #expect(
      packet.readiness.contains { $0.component == "lvs-layout-extraction" && $0.status == .ready })
    #expect(
      packet.readiness.contains { $0.component == "lvs-oracle-comparison" && $0.status == .blocked }
    )
    #expect(packet.metrics.contains { $0.metricID == "summary.pass-rate" && $0.value == 0 })
    #expect(
      packet.metrics.contains {
        $0.metricID == "case-model.actual-active-error-rule-count" && $0.count == 1
      })
    #expect(packet.artifacts.contains { $0.kind == "extracted-layout-netlist" })
    #expect(packet.diagnostics.contains { $0.category == "expectation_mismatch" })
    #expect(packet.diagnostics.contains { $0.category == "model_mismatch" })
    #expect(
      packet.diagnostics.contains {
        $0.ruleID == "LVS_MODEL_MISMATCH" && $0.category == "model_mismatch"
      })
    let modelDiagnostic = try #require(
      packet.diagnostics.first {
        $0.diagnosticID == "case-model:failure:0"
      })
    #expect(modelDiagnostic.layoutModel == "sky130_fd_pr__nfet_01v8")
    #expect(modelDiagnostic.schematicModel == "sky130_fd_pr__pfet_01v8")
    #expect(packet.diagnostics.contains { $0.category == "oracle_readiness" })
    #expect(packet.diagnostics.contains { $0.category == "oracle_agreement" })
    #expect(
      packet.decisionHints.contains {
        $0.hintID == "lvs:model_mismatch"
          && $0.suggestedActions.contains("consider_model_equivalence_policy")
      })
    #expect(packet.confidence.level == .medium)
  }

  @Test func evidencePacketIntegrityValidationReportsBrokenReferences() throws {
    let packet = LVSEvidencePacket(
      packetID: "broken-packet",
      domain: "lvs.signoff-evidence",
      subject: LVSEvidenceSubject(kind: "lvs-corpus", identifier: "broken-report"),
      intent: LVSEvidenceIntent(summary: "Expose broken packet for validation."),
      inputs: [
        LVSEvidenceArtifactRef(
          artifactID: "artifact-a",
          path: " report.json ",
          role: "source",
          kind: "report",
          format: "JSON",
          sha256: "abc"
        ),
      ],
      readiness: [
        LVSEvidenceReadiness(
          component: "lvs-corpus",
          status: .ready,
          reason: "ready",
          artifactIDs: ["missing-artifact"]
        ),
      ],
      artifacts: [
        LVSEvidenceArtifactRef(
          artifactID: "artifact-a",
          path: "../case/report.json",
          role: "run-artifact",
          kind: "case-report",
          format: "JSON"
        ),
      ],
      normalizedViews: [
        LVSEvidenceNormalizedView(
          viewID: "summary",
          kind: "summary",
          scope: "corpus",
          sourceArtifactIDs: ["missing-artifact"]
        ),
      ],
      metrics: [
        LVSEvidenceMetric(metricID: "metric-a", name: "Pass rate", value: .infinity),
        LVSEvidenceMetric(metricID: "metric-a", name: "Duplicate", count: -1),
      ],
      diagnostics: [
        LVSEvidenceDiagnostic(
          diagnosticID: "diagnostic-a",
          severity: .error,
          category: "model_mismatch",
          message: "Mismatch",
          artifactIDs: ["missing-artifact"]
        ),
        LVSEvidenceDiagnostic(
          diagnosticID: "diagnostic-a",
          severity: .warning,
          category: "oracle_agreement",
          message: "Duplicate diagnostic"
        ),
      ],
      confidence: LVSEvidenceConfidence(
        level: .low,
        reason: "Broken packet",
        evidenceCount: -1,
        limitationCount: -1
      ),
      decisionHints: [
        LVSEvidenceDecisionHint(
          hintID: "hint-a",
          priority: .high,
          summary: "Review missing diagnostic.",
          diagnosticIDs: ["missing-diagnostic"]
        ),
      ]
    )

    let issues = packet.validateIntegrity()
    let issueCodes = Set(issues.map(\.code))

    #expect(issueCodes.contains("lvs_evidence_duplicate_artifact_id"))
    #expect(issueCodes.contains("lvs_evidence_invalid_sha256"))
    #expect(issueCodes.contains("lvs_evidence_artifact_path_has_whitespace"))
    #expect(issueCodes.contains("lvs_evidence_artifact_path_has_relative_component"))
    #expect(issueCodes.contains("lvs_evidence_dangling_artifact_reference"))
    #expect(issueCodes.contains("lvs_evidence_duplicate_metric_id"))
    #expect(issueCodes.contains("lvs_evidence_non_finite_metric_value"))
    #expect(issueCodes.contains("lvs_evidence_negative_metric_count"))
    #expect(issueCodes.contains("lvs_evidence_duplicate_diagnostic_id"))
    #expect(issueCodes.contains("lvs_evidence_dangling_diagnostic_reference"))
    #expect(issueCodes.contains("lvs_evidence_negative_confidence_evidence_count"))
    #expect(issueCodes.contains("lvs_evidence_negative_confidence_limitation_count"))
    #expect(issues.allSatisfy { !$0.fieldPath.isEmpty })
    #expect(issues.allSatisfy { !$0.suggestedActions.isEmpty })
  }

  @Test func corpusEvidencePacketQuarantinesUnsafeArtifactPaths() throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let artifactRoot = root.appending(path: "artifacts")
    let trustedReportPath = artifactRoot.appending(path: "case-safe/lvs-report.json")
      .path(percentEncoded: false)
    let outsideManifestPath = root.appending(path: "outside/lvs-artifact-manifest.json")
      .path(percentEncoded: false)
    let report = LVSCorpusReport(
      passed: true,
      caseCount: 1,
      matchedCaseCount: 1,
      totalDurationSeconds: 0.1,
      caseResults: [
        LVSCorpusCaseResult(
          caseID: "case-safe",
          matched: true,
          expectedPassed: true,
          actualPassed: true,
          expectedActiveErrorRuleIDs: [],
          actualActiveErrorRuleIDs: [],
          expectationMatched: true,
          durationSeconds: 0.1,
          expectedMaxDurationSeconds: 1,
          durationBudgetPassed: true,
          failureReasons: [],
          diagnosticSummary: LVSDiagnosticSummary(infoCount: 0, warningCount: 0, errorCount: 0),
          reportPath: trustedReportPath,
          manifestPath: outsideManifestPath,
          extractedLayoutNetlistPath: "https://example.invalid/extracted-layout.spice"
        ),
      ]
    )

    let packet = LVSCorpusEvidencePacketBuilder().build(
      report: report,
      reportPath: root.appending(path: "lvs-corpus-report.json").path(percentEncoded: false),
      allowedArtifactRootPath: artifactRoot.path(percentEncoded: false)
    )

    #expect(packet.artifacts.contains { $0.artifactID == "case-safe:reportPath" })
    #expect(!packet.artifacts.contains { $0.artifactID == "case-safe:manifestPath" })
    #expect(!packet.artifacts.contains { $0.path.contains("://") })
    #expect(!packet.readiness.contains { $0.component == "lvs-layout-extraction" })
    #expect(packet.diagnostics.contains { $0.category == "artifact_integrity" })
    #expect(
      packet.readiness.contains {
        $0.component == "lvs-evidence-artifacts" && $0.status == .blocked
      })
    #expect(packet.confidence.level == .low)
    #expect(
      packet.decisionHints.contains {
        $0.hintID == "lvs:artifact_integrity"
          && $0.suggestedActions.contains("inspect_lvs_corpus_artifact_paths")
      })
  }

  @Test func corpusEvidencePacketUsesSafeCaseNamespaces() throws {
    let report = LVSCorpusReport(
      passed: true,
      caseCount: 3,
      matchedCaseCount: 3,
      totalDurationSeconds: 0.3,
      caseResults: [
        evidenceCaseResult(caseID: "case/one"),
        evidenceCaseResult(caseID: "case one"),
        evidenceCaseResult(caseID: "case/one"),
      ]
    )

    let packet = LVSCorpusEvidencePacketBuilder().build(
      report: report,
      reportPath: "/tmp/lvs-corpus-report.json"
    )

    #expect(packet.metrics.contains { $0.metricID == "case-one.duration-seconds" })
    #expect(packet.metrics.contains { $0.metricID == "case-one-2.duration-seconds" })
    #expect(packet.metrics.contains { $0.metricID == "case-one-3.duration-seconds" })
    #expect(packet.diagnostics.contains { $0.diagnosticID == "lvs-case:case-one:case-id-unsafe" })
    #expect(packet.diagnostics.contains { $0.diagnosticID == "lvs-case:case-one:case-id-duplicate" })
    #expect(
      packet.diagnostics.contains {
        $0.diagnosticID == "lvs-case:case-one-2:case-id-namespace-collision"
      })
    #expect(
      packet.diagnostics.allSatisfy {
        !$0.diagnosticID.contains("/") && !$0.diagnosticID.contains(" ")
      })
    #expect(packet.confidence.level == .low)
  }

  @Test func evidencePacketCLIExportsFailedCorpusAsDecisionMaterial() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let reportURL = root.appending(path: "lvs-corpus-report.json")
    let packetURL = root.appending(path: "lvs-evidence-packet.json")
    try writeJSON(failingLVSCorpusReport(), to: reportURL)

    let exitCode = await LVSCLI.run(arguments: [
      "--evidence-packet-from-corpus-report", reportURL.path(percentEncoded: false),
      "--out", packetURL.path(percentEncoded: false),
      "--packet-id", "lvs-evidence-release",
    ])

    #expect(exitCode == 0)
    let packet = try JSONDecoder().decode(
      LVSEvidencePacket.self,
      from: Data(contentsOf: packetURL)
    )
    #expect(packet.packetID == "lvs-evidence-release")
    #expect(packet.diagnostics.contains { $0.category == "model_mismatch" })
    #expect(packet.decisionHints.contains { $0.hintID == "lvs:oracle_readiness" })
    #expect(packet.validateIntegrity().isEmpty)
  }

  @Test func evidencePacketCLIPassesArtifactRootIntoPacketBuilder() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let artifactRoot = root.appending(path: "artifacts")
    let reportURL = root.appending(path: "lvs-corpus-report.json")
    let packetURL = root.appending(path: "lvs-evidence-packet.json")
    let report = LVSCorpusReport(
      passed: true,
      caseCount: 1,
      matchedCaseCount: 1,
      caseResults: [
        LVSCorpusCaseResult(
          caseID: "case-safe",
          matched: true,
          expectedPassed: true,
          actualPassed: true,
          expectedActiveErrorRuleIDs: [],
          actualActiveErrorRuleIDs: [],
          expectationMatched: true,
          durationSeconds: 0.1,
          expectedMaxDurationSeconds: 1,
          durationBudgetPassed: true,
          failureReasons: [],
          diagnosticSummary: LVSDiagnosticSummary(infoCount: 0, warningCount: 0, errorCount: 0),
          reportPath: root.appending(path: "outside/lvs-report.json").path(percentEncoded: false),
          manifestPath: nil,
          extractedLayoutNetlistPath: nil
        ),
      ]
    )
    try writeJSON(report, to: reportURL)

    let exitCode = await LVSCLI.run(arguments: [
      "--evidence-packet-from-corpus-report", reportURL.path(percentEncoded: false),
      "--artifact-root", artifactRoot.path(percentEncoded: false),
      "--out", packetURL.path(percentEncoded: false),
    ])

    #expect(exitCode == 0)
    let packet = try JSONDecoder().decode(
      LVSEvidencePacket.self,
      from: Data(contentsOf: packetURL)
    )
    #expect(packet.artifacts.isEmpty)
    #expect(packet.diagnostics.contains { $0.category == "artifact_integrity" })
    #expect(packet.confidence.level == .low)
    #expect(packet.validateIntegrity().isEmpty)
  }

  @Test func corpusEvidenceCLIUsesQualificationForExitStatus() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let outputDirectory = root.appending(path: "corpus-output")
    let specURL = fixtureCorpusSpecURL("lvs-corpus-tight-budget.json")

    let corpusExitCode = await LVSCLI.run(arguments: [
      "--corpus", specURL.path(percentEncoded: false),
      "--out", outputDirectory.path(percentEncoded: false),
      "--json",
    ])
    #expect(corpusExitCode == 2)

    let reportURL = outputDirectory.appending(path: "lvs-corpus-report.json")
    let evidenceExitCode = await LVSCLI.run(arguments: [
      "--evidence-from-corpus-report", reportURL.path(percentEncoded: false),
      "--checked-at", "2026-06-18T00:00:00Z",
      "--json",
    ])

    #expect(evidenceExitCode == 2)
  }

}

private func evidenceCaseResult(caseID: String) -> LVSCorpusCaseResult {
  LVSCorpusCaseResult(
    caseID: caseID,
    matched: true,
    expectedPassed: true,
    actualPassed: true,
    expectedActiveErrorRuleIDs: [],
    actualActiveErrorRuleIDs: [],
    expectationMatched: true,
    durationSeconds: 0.1,
    expectedMaxDurationSeconds: 1,
    durationBudgetPassed: true,
    failureReasons: [],
    diagnosticSummary: LVSDiagnosticSummary(infoCount: 0, warningCount: 0, errorCount: 0),
    reportPath: nil,
    manifestPath: nil,
    extractedLayoutNetlistPath: nil
  )
}
