import Foundation
import CircuiteFoundation
import LVSCLICore
import LVSCore
import Testing

extension LVSCLIOptionsTests {
  @Test func corpusObservationOptionsParseCheckedAtAndRecordID() throws {
    let options = try LVSCorpusObservationCLIOptions(arguments: [
      "--observations-from-corpus-report", "/tmp/lvs-corpus-report.json",
      "--record-id", "lvs-release-corpus",
      "--out", "/tmp/lvs-observation-export.json",
      "--checked-at", "2026-06-18T00:00:00Z",
      "--json",
    ])

    #expect(options.reportURL.path(percentEncoded: false) == "/tmp/lvs-corpus-report.json")
    #expect(options.recordID == "lvs-release-corpus")
    #expect(options.outputURL?.path(percentEncoded: false) == "/tmp/lvs-observation-export.json")
    #expect(options.checkedAt.timeIntervalSince1970 == 1_781_740_800)
    #expect(options.emitJSON)
  }

  @Test func corpusObservationCLIWritesRetainedArtifact() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let report = qualifiedEvidenceReport(oracleIdentity: independentOracleIdentity())
    let reportURL = root.appending(path: "lvs-corpus-report.json")
    let evidenceURL = root.appending(path: "lvs-observation-export.json")
    try writeJSON(report, to: reportURL)

    let exitCode = await LVSCLI.run(arguments: [
      "--observations-from-corpus-report", reportURL.path(percentEncoded: false),
      "--out", evidenceURL.path(percentEncoded: false),
      "--checked-at", "2026-06-18T00:00:00Z",
    ])

    #expect(exitCode == 0)
    let output = try JSONDecoder().decode(
      LVSCorpusObservationExport.self,
      from: Data(contentsOf: evidenceURL)
    )
    #expect(output.observationRecord.observations.findingCodes.isEmpty)
    #expect(output.reportPath == "lvs-corpus-report.json")
    #expect(output.reportArtifact.byteCount == UInt64(try Data(contentsOf: reportURL).count))
  }

  @Test func corpusObservationOptionsRejectOptionTokenAsRecordID() throws {
    let error = try captureError {
      _ = try LVSCorpusObservationCLIOptions(arguments: [
        "--observations-from-corpus-report", "/tmp/lvs-corpus-report.json",
        "--record-id", "--checked-at",
        "2026-06-18T00:00:00Z",
      ])
    }

    #expect(error == .missingValue("--record-id"))
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

  @Test func corpusObservationExportMatchesRuntimeObservationShape() throws {
    let report = qualifiedEvidenceReport(oracleIdentity: independentOracleIdentity())
    let reportData = try JSONEncoder().encode(report)
    let reportDigest = String(repeating: "a", count: 64)

    let export = try LVSCorpusObservationExport(
      reportPath: "reports/lvs-corpus-report.json",
      reportSHA256: reportDigest,
      reportByteCount: UInt64(reportData.count),
      report: report,
      recordID: "lvs-release-corpus",
      observedAt: Date(timeIntervalSince1970: 1_781_740_800)
    )

    #expect(export.schemaVersion == LVSCorpusObservationExport.currentSchemaVersion)
    #expect(export.reportPath == "reports/lvs-corpus-report.json")
    #expect(export.reportArtifact.byteCount == UInt64(reportData.count))
    #expect(export.observationRecord.recordID == "lvs-release-corpus")
    #expect(export.observationRecord.observedAt == "2026-06-18T00:00:00Z")
    #expect(export.observationRecord.artifact.kind == .report)
    #expect(export.observationRecord.artifact.format == .json)
    #expect(export.observationRecord.artifact.digest.algorithm == .sha256)
    #expect(export.observationRecord.artifact.digest.hexadecimalValue == reportDigest)
    #expect(export.observationRecord.observations.acceptanceCriteriaID == "strict")
    #expect(export.observationRecord.observations.observedMetrics["passRate"] == 1)
    #expect(export.observationRecord.observations.observedMetrics["durationBudgetPassRate"] == 1)
    #expect(export.observationRecord.observations.observedMetrics["oracleAgreementRate"] == 1)
    #expect(export.observationRecord.observations.observedCounts["caseCount"] == 2)
    #expect(export.observationRecord.observations.observedCounts["observedAssertionKindCount"] == 3)
    #expect(
      export.observationRecord.observations.observedCounts["oracleReadinessBlockedCaseCount"] == 0)
    #expect(export.observationRecord.observations.observedCounts["requiredObservedAssertionCount"] == 3)
    #expect(export.observationRecord.observations.findingCodes.isEmpty)
    #expect(export.observationRecord.observations.implementationScope?.implementationID == "lvsengine-native")
    #expect(export.observationRecord.observations.implementationScope?.processProfileID == "sky130.production")
    #expect(export.observationRecord.observations.implementationScope?.deckDigest == String(repeating: "1", count: 64))
    #expect(export.observationRecord.observations.observedCounts["independentOracleCaseCount"] == 2)
    #expect(export.observationRecord.observations.observedCounts["nonIndependentOracleCaseCount"] == 0)
    #expect(export.observationRecord.observations.observedCounts["reportIntegrityFailureCount"] == 0)
    #expect(export.oracleScopes.map { $0.implementationID } == ["netgen-external"])

    let encoded = try JSONEncoder().encode(export)
    let payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let observationRecord = try #require(payload["observationRecord"] as? [String: Any])
    let observations = try #require(observationRecord["observations"] as? [String: Any])
    let scope = try #require(observations["implementationScope"] as? [String: Any])
    #expect(scope["binaryDigest"] as? String == String(repeating: "a", count: 64))
    #expect(scope["algorithmVersion"] as? String == "canonical-graph-v2")
  }

  @Test func corpusObservationRecordsSelfOracleFinding() throws {
    let primaryIdentity = nativePrimaryIdentity()
    let report = qualifiedEvidenceReport(oracleIdentity: primaryIdentity)
    let reportData = try JSONEncoder().encode(report)

    let export = try LVSCorpusObservationExport(
      reportPath: "reports/lvs-corpus-report.json",
      reportSHA256: String(repeating: "a", count: 64),
      reportByteCount: UInt64(reportData.count),
      report: report
    )

    #expect(
      export.observationRecord.observations.findingCodes.contains(
        "oracle_implementation_not_independent"
      )
    )
    #expect(export.observationRecord.observations.observedCounts["independentOracleCaseCount"] == 0)
    #expect(export.observationRecord.observations.observedCounts["nonIndependentOracleCaseCount"] == 2)
  }

  @Test func corpusObservationUsesDeclaredPhysicalScopeWithProcessNeutralSupport() throws {
    let base = qualifiedEvidenceReport(oracleIdentity: independentOracleIdentity())
    let physical = try #require(base.caseResults.first)
    let semanticSource = try #require(base.caseResults.last)
    let semanticPrimary = LVSImplementationIdentity(
      implementationID: "lvsengine-native",
      binaryDigest: String(repeating: "a", count: 64),
      algorithmVersion: "canonical-graph-v2",
      processProfileID: "process-neutral",
      deckDigest: "no-deck"
    )
    let semanticOracle = LVSImplementationIdentity(
      implementationID: "netgen-external",
      binaryDigest: String(repeating: "b", count: 64),
      algorithmVersion: "netgen-subprocess",
      processProfileID: "process-neutral",
      deckDigest: "no-deck"
    )
    let semantic = replacingIdentities(
      in: semanticSource,
      primaryIdentity: semanticPrimary,
      oracleIdentity: semanticOracle
    )
    let report = LVSCorpusReport(
      generatedAt: "2026-07-12T00:00:00Z",
      passed: true,
      caseCount: 2,
      matchedCaseCount: 2,
      totalDurationSeconds: physical.durationSeconds + semantic.durationSeconds,
      qualificationScopeCaseID: physical.caseID,
      caseResults: [physical, semantic]
    )
    let reportData = try JSONEncoder().encode(report)

    let export = try LVSCorpusObservationExport(
      reportPath: "reports/lvs-corpus-report.json",
      reportSHA256: String(repeating: "c", count: 64),
      reportByteCount: UInt64(reportData.count),
      report: report
    )

    #expect(export.observationRecord.observations.implementationScope?.processProfileID == "sky130.production")
    #expect(export.observationRecord.observations.implementationScope?.deckDigest == String(repeating: "1", count: 64))
    #expect(export.observationRecord.observations.observedCounts["qualificationScopeCount"] == 1)
  }

  @Test func corpusObservationRecordsInconsistentReport() throws {
    let report = LVSCorpusReport(
      passed: true,
      caseCount: 2,
      matchedCaseCount: 2,
      totalDurationSeconds: 0.25,
      summary: LVSCorpusSummary(
        expectationMatchedCaseCount: 2,
        durationBudgetPassedCaseCount: 2,
        primaryExecutionFailedCaseCount: 0,
        oracleCaseCount: 2,
        oracleAgreementPassedCaseCount: 2,
        oracleExecutionFailedCaseCount: 0,
        failureCategoryCounts: [:],
        passRate: 1,
        oracleAgreementRate: 1
      ),
      caseResults: []
    )
    let reportData = try JSONEncoder().encode(report)

    let export = try LVSCorpusObservationExport(
      reportPath: "reports/lvs-corpus-report.json",
      reportSHA256: String(repeating: "a", count: 64),
      reportByteCount: UInt64(reportData.count),
      report: report
    )

    #expect(
      export.observationRecord.observations.findingCodes.contains(
        "report_case_count_inconsistent"
      )
    )
    #expect(export.observationRecord.observations.observedCounts["reportIntegrityFailureCount"] != 0)
  }

  @Test func corpusObservationRejectsInvalidDigest() throws {
    let report = qualifiedEvidenceReport(oracleIdentity: independentOracleIdentity())
    let reportData = try JSONEncoder().encode(report)

    #expect(throws: ContentDigestError.self) {
      _ = try LVSCorpusObservationExport(
        reportPath: "reports/lvs-corpus-report.json",
        reportSHA256: "invalid",
        reportByteCount: UInt64(reportData.count),
        report: report
      )
    }
  }

  @Test func corpusObservationRejectsAbsoluteReportPath() throws {
    let report = qualifiedEvidenceReport(oracleIdentity: independentOracleIdentity())
    let reportData = try JSONEncoder().encode(report)

    #expect(throws: ArtifactLocationError.self) {
      _ = try LVSCorpusObservationExport(
        reportPath: "/tmp/lvs-corpus-report.json",
        reportSHA256: String(repeating: "a", count: 64),
        reportByteCount: UInt64(reportData.count),
        report: report
      )
    }
  }

  @Test func corpusEvidenceRejectsOracleIntegrityNormalization() throws {
    let integrityDiagnostic = LVSCorpusOracleIntegrityDiagnostic(
      severity: .warning,
      code: "oracle_summary_normalized",
      field: "diagnosticSummary",
      message: "Oracle summary required normalization.",
      observed: ["errorCount=1"],
      canonical: ["errorCount=0"],
      suggestedActions: ["regenerate_lvs_corpus_report"]
    )
    let report = qualifiedEvidenceReport(
      oracleIdentity: independentOracleIdentity(),
      oracleIntegrityDiagnostics: [integrityDiagnostic]
    )
    let reportData = try JSONEncoder().encode(report)
    let digest = String(repeating: "d", count: 64)

    let export = try LVSCorpusObservationExport(
      reportPath: "reports/lvs-corpus-report.json",
      reportSHA256: digest,
      reportByteCount: UInt64(reportData.count),
      report: report
    )
    let packet = LVSCorpusEvidencePacketBuilder().build(
      report: report,
      reportPath: "/tmp/lvs-corpus-report.json",
      reportSHA256: digest
    )

    #expect(
      export.observationRecord.observations.findingCodes.contains(
        "oracle_evidence_integrity_failure"
      )
    )
    #expect(export.observationRecord.observations.observedCounts["oracleIntegrityFailureCount"] == 2)
    #expect(packet.confidence.level == .low)
    #expect(
      packet.diagnostics.contains {
        $0.diagnosticID == "qualified-case:oracle-integrity:0"
          && $0.category == "artifact_integrity"
      }
    )
  }

  @Test func corpusEvidencePacketRequiresScopedIndependentOracleForHighConfidence() {
    let digest = String(repeating: "c", count: 64)
    let independentReport = qualifiedEvidenceReport(oracleIdentity: independentOracleIdentity())
    let independentPacket = LVSCorpusEvidencePacketBuilder().build(
      report: independentReport,
      reportPath: "/tmp/lvs-corpus-report.json",
      reportSHA256: digest
    )

    #expect(independentPacket.confidence.level == .high)
    #expect(independentPacket.qualificationScope?.implementationID == "lvsengine-native")
    #expect(independentPacket.oracleScopes?.map { $0.implementationID } == ["netgen-external"])
    #expect(
      independentPacket.metrics.contains {
        $0.metricID == "summary.independent-oracle-case-count" && $0.count == 2
      }
    )
    #expect(independentPacket.validateIntegrity().isEmpty)

    let selfOracleReport = qualifiedEvidenceReport(oracleIdentity: nativePrimaryIdentity())
    let selfOraclePacket = LVSCorpusEvidencePacketBuilder().build(
      report: selfOracleReport,
      reportPath: "/tmp/lvs-corpus-report.json",
      reportSHA256: digest
    )

    #expect(selfOraclePacket.confidence.level == .low)
    #expect(selfOraclePacket.diagnostics.contains { $0.category == "oracle_independence" })
    #expect(
      selfOraclePacket.readiness.contains {
        $0.component == "lvs-oracle-comparison" && $0.status == .blocked
      }
    )
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
    #expect(packet.confidence.level == .low)
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

  @Test func corpusObservationCLIReportsWithoutApplyingTrustPolicy() async throws {
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
      "--observations-from-corpus-report", reportURL.path(percentEncoded: false),
      "--checked-at", "2026-06-18T00:00:00Z",
      "--json",
    ])

    #expect(evidenceExitCode == 0)
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

private func qualifiedEvidenceReport(
  oracleIdentity: LVSImplementationIdentity,
  oracleIntegrityDiagnostics: [LVSCorpusOracleIntegrityDiagnostic] = []
) -> LVSCorpusReport {
  let primaryIdentity = nativePrimaryIdentity()
  let zeroSummary = LVSDiagnosticSummary(infoCount: 0, warningCount: 0, errorCount: 0)
  let primaryProvenance = LVSCorpusCaseProvenance(
    backendID: "native",
    reportPath: "/tmp/primary/lvs-report.json",
    manifestPath: "/tmp/primary/lvs-artifact-manifest.json",
    extractedLayoutNetlistPath: nil,
    implementationIdentity: primaryIdentity
  )
  let oracleProvenance = LVSCorpusCaseProvenance(
    backendID: oracleIdentity.implementationID,
    reportPath: "/tmp/oracle/lvs-report.json",
    manifestPath: "/tmp/oracle/lvs-artifact-manifest.json",
    extractedLayoutNetlistPath: nil,
    implementationIdentity: oracleIdentity
  )
  let oracleResult = LVSCorpusOracleResult(
    backendID: oracleIdentity.implementationID,
    passed: true,
    activeErrorRuleIDs: [],
    diagnosticSummary: zeroSummary,
    integrityDiagnostics: oracleIntegrityDiagnostics,
    durationSeconds: 0.1,
    agreementPassed: true,
    readinessStatus: .ready,
    failureReasons: [],
    reportPath: oracleProvenance.reportPath,
    manifestPath: oracleProvenance.manifestPath,
    extractedLayoutNetlistPath: nil,
    provenance: oracleProvenance
  )
  let caseResult = LVSCorpusCaseResult(
    caseID: "qualified-case",
    matched: true,
    expectedPassed: true,
    actualPassed: true,
    expectedActiveErrorRuleIDs: [],
    actualActiveErrorRuleIDs: [],
    expectationMatched: true,
    durationSeconds: 0.2,
    expectedMaxDurationSeconds: 1,
    durationBudgetPassed: true,
    failureReasons: [],
    diagnosticSummary: zeroSummary,
    reportPath: primaryProvenance.reportPath,
    manifestPath: primaryProvenance.manifestPath,
    extractedLayoutNetlistPath: nil,
    primaryProvenance: primaryProvenance,
    oracleResult: oracleResult,
    observedAssertions: [
      LVSCorpusObservedAssertion(
        assertionID: "verdict-match",
        kind: .verdict,
        status: .passed,
        expectedValue: "match",
        observedValue: "match",
        sourceArtifactRefs: [primaryProvenance.reportPath!]
      ),
      LVSCorpusObservedAssertion(
        assertionID: "duration-match",
        kind: .durationBudget,
        status: .passed,
        expectedValue: "within-budget",
        observedValue: "0.2",
        sourceArtifactRefs: [primaryProvenance.reportPath!]
      ),
    ]
  )
  let mismatchSummary = LVSDiagnosticSummary(infoCount: 0, warningCount: 0, errorCount: 1)
  let mismatchOracle = LVSCorpusOracleResult(
    backendID: oracleIdentity.implementationID,
    passed: false,
    activeErrorRuleIDs: ["LVS_MODEL_MISMATCH"],
    diagnosticSummary: mismatchSummary,
    integrityDiagnostics: oracleIntegrityDiagnostics,
    durationSeconds: 0.1,
    agreementPassed: true,
    readinessStatus: .ready,
    failureReasons: [],
    reportPath: oracleProvenance.reportPath,
    manifestPath: oracleProvenance.manifestPath,
    extractedLayoutNetlistPath: nil,
    provenance: oracleProvenance
  )
  let mismatchCaseResult = LVSCorpusCaseResult(
    caseID: "qualified-mismatch-case",
    matched: true,
    expectedPassed: false,
    actualPassed: false,
    expectedActiveErrorRuleIDs: ["LVS_MODEL_MISMATCH"],
    actualActiveErrorRuleIDs: ["LVS_MODEL_MISMATCH"],
    expectationMatched: true,
    durationSeconds: 0.2,
    expectedMaxDurationSeconds: 1,
    durationBudgetPassed: true,
    failureReasons: [],
    diagnosticSummary: mismatchSummary,
    reportPath: primaryProvenance.reportPath,
    manifestPath: primaryProvenance.manifestPath,
    extractedLayoutNetlistPath: nil,
    primaryProvenance: primaryProvenance,
    oracleResult: mismatchOracle,
    observedAssertions: [
      LVSCorpusObservedAssertion(
        assertionID: "verdict-mismatch",
        kind: .verdict,
        status: .passed,
        expectedValue: "mismatch",
        observedValue: "mismatch",
        sourceArtifactRefs: [primaryProvenance.reportPath!]
      ),
      LVSCorpusObservedAssertion(
        assertionID: "duration-mismatch",
        kind: .durationBudget,
        status: .passed,
        expectedValue: "within-budget",
        observedValue: "0.2",
        sourceArtifactRefs: [primaryProvenance.reportPath!]
      ),
    ]
  )
  return LVSCorpusReport(
    generatedAt: "2026-07-12T00:00:00Z",
    passed: true,
    caseCount: 2,
    matchedCaseCount: 2,
    totalDurationSeconds: 0.4,
    caseResults: [caseResult, mismatchCaseResult]
  )
}

private func nativePrimaryIdentity() -> LVSImplementationIdentity {
  LVSImplementationIdentity(
    implementationID: "lvsengine-native",
    binaryDigest: String(repeating: "a", count: 64),
    algorithmVersion: "canonical-graph-v2",
    processProfileID: "sky130.production",
    deckDigest: String(repeating: "1", count: 64)
  )
}

private func independentOracleIdentity() -> LVSImplementationIdentity {
  LVSImplementationIdentity(
    implementationID: "netgen-external",
    binaryDigest: String(repeating: "b", count: 64),
    algorithmVersion: "netgen-subprocess",
    processProfileID: "sky130.production",
    deckDigest: String(repeating: "2", count: 64)
  )
}

private func replacingIdentities(
  in result: LVSCorpusCaseResult,
  primaryIdentity: LVSImplementationIdentity,
  oracleIdentity: LVSImplementationIdentity
) -> LVSCorpusCaseResult {
  let primary = result.primaryProvenance.map { provenance in
    LVSCorpusCaseProvenance(
      backendID: provenance.backendID,
      inputArtifacts: provenance.inputArtifacts,
      outputArtifacts: provenance.outputArtifacts,
      reportPath: provenance.reportPath,
      manifestPath: provenance.manifestPath,
      extractedLayoutNetlistPath: provenance.extractedLayoutNetlistPath,
      implementationIdentity: primaryIdentity
    )
  }
  let oracle = result.oracleResult.map { oracle in
    let provenance = oracle.provenance.map { provenance in
      LVSCorpusCaseProvenance(
        backendID: provenance.backendID,
        inputArtifacts: provenance.inputArtifacts,
        outputArtifacts: provenance.outputArtifacts,
        reportPath: provenance.reportPath,
        manifestPath: provenance.manifestPath,
        extractedLayoutNetlistPath: provenance.extractedLayoutNetlistPath,
        implementationIdentity: oracleIdentity
      )
    }
    return LVSCorpusOracleResult(
      backendID: oracle.backendID,
      passed: oracle.passed,
      activeErrorRuleIDs: oracle.activeErrorRuleIDs,
      diagnostics: oracle.diagnostics,
      diagnosticSummary: oracle.diagnosticSummary,
      integrityDiagnostics: oracle.integrityDiagnostics,
      durationSeconds: oracle.durationSeconds,
      agreementPassed: oracle.agreementPassed,
      readinessStatus: oracle.readinessStatus,
      readinessDiagnostics: oracle.readinessDiagnostics,
      failureReasons: oracle.failureReasons,
      executionError: oracle.executionError,
      reportPath: oracle.reportPath,
      manifestPath: oracle.manifestPath,
      extractedLayoutNetlistPath: oracle.extractedLayoutNetlistPath,
      devicePolicyReport: oracle.devicePolicyReport,
      provenance: provenance
    )
  }
  return LVSCorpusCaseResult(
    caseID: result.caseID,
    matched: result.matched,
    expectedPassed: result.expectedPassed,
    actualPassed: result.actualPassed,
    expectedActiveErrorRuleIDs: result.expectedActiveErrorRuleIDs,
    actualActiveErrorRuleIDs: result.actualActiveErrorRuleIDs,
    expectationMatched: result.expectationMatched,
    durationSeconds: result.durationSeconds,
    expectedMaxDurationSeconds: result.expectedMaxDurationSeconds,
    durationBudgetPassed: result.durationBudgetPassed,
    failureReasons: result.failureReasons,
    executionError: result.executionError,
    diagnosticSummary: result.diagnosticSummary,
    reportPath: result.reportPath,
    manifestPath: result.manifestPath,
    extractedLayoutNetlistPath: result.extractedLayoutNetlistPath,
    primaryProvenance: primary,
    oracleResult: oracle,
    oracleComparison: result.oracleComparison,
    observedAssertions: result.observedAssertions
  )
}
