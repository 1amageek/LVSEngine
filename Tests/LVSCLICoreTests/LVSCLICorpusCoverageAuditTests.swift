import Foundation
import Testing
import LVSCore
import LVSCLICore

extension LVSCLIOptionsTests {
@Test func netgenExternalCorpusSpecDeclaresExpandedOracleCoverage() throws {
    let specURL = externalOracleFixtureURL("lvs-netgen-corpus.json")
    let spec = try JSONDecoder().decode(LVSCorpusSpec.self, from: Data(contentsOf: specURL))

    #expect(spec.defaultMaxDurationSeconds == 30)
    #expect(spec.cases.count == 11)
    #expect(Set(spec.cases.compactMap(\.backendID)) == ["netgen"])
    #expect(Set(spec.cases.compactMap(\.oracleBackendID)) == ["netgen"])
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("external.netgen"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("layout.spice"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.match"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.hierarchy"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.device-breadth"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.sources"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.controlled-sources"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.independent-sources"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.inductor"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.symmetric-terminals"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.mos-source-drain-permutation"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.passive-terminal-permutation"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.parallel-devices"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.netgen.policy-gap.global-nets"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.netgen.policy-gap.multiplicity"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.input.gds"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.extract.connectivity"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.terminal-equivalence-policy"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.diode-terminal-equivalence"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.parameter-mismatch"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.netgen.policy-gap.terminal-equivalence"))
    #expect(spec.qualificationPolicy.requiredCoverageTags.contains("lvs.netgen.policy-gap.parameter-mismatch"))
    #expect(spec.cases.contains {
        $0.caseID == "netgen-model-mismatch"
            && !$0.expectedPassed
            && $0.expectedActiveErrorRuleIDs == ["LVS_MISMATCH"]
    })
    #expect(spec.cases.contains {
        $0.caseID == "netgen-hierarchical-model-mismatch"
            && !$0.expectedPassed
            && $0.coverageTags.contains("lvs.hierarchy")
    })
    #expect(spec.cases.contains {
        $0.caseID == "netgen-device-breadth"
            && $0.expectedPassed
            && $0.coverageTags.contains("lvs.bjt")
            && $0.coverageTags.contains("lvs.diode")
    })
    #expect(spec.cases.contains {
        $0.caseID == "netgen-source-breadth"
            && $0.expectedPassed
            && $0.coverageTags.contains("lvs.inductor")
            && $0.coverageTags.contains("lvs.controlled-sources")
    })
    #expect(spec.cases.contains {
        $0.caseID == "netgen-global-supply-policy-gap"
            && !$0.expectedPassed
            && $0.coverageTags.contains("lvs.netgen.policy-gap.global-nets")
    })
    #expect(spec.cases.contains {
        $0.caseID == "netgen-multiplicity-policy-gap"
            && !$0.expectedPassed
            && $0.coverageTags.contains("lvs.netgen.policy-gap.multiplicity")
    })
    #expect(spec.cases.contains {
        $0.caseID == "netgen-standard-gds-extraction"
            && $0.expectedPassed
            && $0.layoutGDSPath == "sky130_fd_sc_hd__inv_1.gds"
            && $0.coverageTags.contains("lvs.input.gds")
            && $0.coverageTags.contains("lvs.extract.devices")
    })
    #expect(spec.cases.contains {
        $0.caseID == "netgen-terminal-equivalence-policy-gap"
            && !$0.expectedPassed
            && $0.expectedActiveErrorRuleIDs == ["LVS_MISMATCH"]
            && $0.terminalEquivalencePath == "../LVSCorpus/terminal-equivalence-policy.json"
            && $0.coverageTags.contains("lvs.netgen.policy-gap.terminal-equivalence")
    })
    #expect(spec.cases.contains {
        $0.caseID == "netgen-parameter-policy-gap"
            && $0.expectedPassed
            && $0.coverageTags.contains("lvs.parameter-mismatch")
            && $0.coverageTags.contains("lvs.netgen.policy-gap.parameter-mismatch")
    })
}

@Test func corpusCoverageAuditReportsMissingFoundryExpansionDimensions() throws {
    let report = netgenExpandedCoverageReport()

    let audit = LVSCorpusCoverageAuditor().audit(
        report: report,
        reportPath: "/tmp/lvs-netgen-corpus-report.json"
    )

    #expect(audit.status == .incomplete)
    #expect(audit.summary.caseCount == 8)
    #expect(audit.summary.qualified)
    #expect(audit.summary.oracleAgreementPassedCaseCount == 8)
    #expect(audit.summary.requiredRequirementCount == 15)
    #expect(audit.missingRequirements.map(\.requirementID) == [
        "diode-terminal-policy-gap-coverage",
        "parameter-policy-coverage",
        "pin-policy-coverage",
        "standard-layout-extraction-coverage",
    ])
    #expect(audit.observedCoverageTags.contains("lvs.netgen.policy-gap.global-nets"))
    #expect(audit.suggestedActions.contains {
        $0.actionID == "add_extracted_layout_netgen_oracle_cases"
            && $0.requirementID == "standard-layout-extraction-coverage"
    })
}

@Test func corpusCoverageAuditSatisfiesPolicyWhenExpansionTagsExist() throws {
    let report = netgenExpandedCoverageReport(extraCoverageCases: [
        ("netgen-standard-gds-policy", [
            "external.netgen",
            "layout.gds",
            "lvs.extract.connectivity",
            "lvs.extract.devices",
            "lvs.input.gds",
            "lvs.diode-terminal-equivalence",
            "lvs.netgen.policy-gap.parameter-mismatch",
            "lvs.netgen.policy-gap.terminal-equivalence",
            "lvs.parameter-mismatch",
            "lvs.terminal-equivalence-policy",
        ]),
    ])

    let audit = LVSCorpusCoverageAuditor().audit(
        report: report,
        reportPath: "/tmp/lvs-netgen-expanded-corpus-report.json"
    )

    #expect(audit.status == .satisfied)
    #expect(audit.missingRequirements.isEmpty)
    #expect(audit.summary.requiredRequirementCount == 15)
    #expect(audit.summary.requiredCoverageTagCount == 29)
    #expect(audit.summary.satisfiedRequirementCount == audit.summary.requiredRequirementCount)
    #expect(audit.summary.coveredRequiredCoverageTagCount == audit.summary.requiredCoverageTagCount)
}

@Test func corpusCoverageAuditRejectsStaleRetainedReport() throws {
    let report = netgenExpandedCoverageReport(
        generatedAt: "2026-06-01T00:00:00Z",
        extraCoverageCases: [
            ("netgen-standard-gds-policy", [
                "external.netgen",
                "layout.gds",
                "lvs.extract.connectivity",
                "lvs.extract.devices",
                "lvs.input.gds",
                "lvs.diode-terminal-equivalence",
                "lvs.netgen.policy-gap.parameter-mismatch",
                "lvs.netgen.policy-gap.terminal-equivalence",
                "lvs.parameter-mismatch",
                "lvs.terminal-equivalence-policy",
            ]),
        ]
    )
    let policy = LVSCorpusCoverageAuditPolicy(
        policyID: "lvs.retained-report-freshness-test",
        minimumCaseCount: 1,
        maxReportAgeSeconds: 60,
        requirements: []
    )

    let audit = LVSCorpusCoverageAuditor().audit(
        report: report,
        reportPath: "/tmp/lvs-corpus-report.json",
        policy: policy,
        checkedAt: ISO8601DateFormatter().date(from: "2026-06-01T00:02:00Z")
    )

    #expect(audit.status == .incomplete)
    #expect(audit.summary.reportGeneratedAt == "2026-06-01T00:00:00Z")
    #expect(audit.summary.reportAgeSeconds == 120)
    #expect(audit.missingRequirements.contains {
        $0.requirementID == "retained-report-freshness"
            && $0.suggestedActions.contains("rerun_lvs_corpus_and_retain_report")
    })
}

@Test func corpusCoverageAuditDoesNotEmitNegativeObservedAgeForFutureRetainedReport() throws {
    let report = netgenExpandedCoverageReport(
        generatedAt: "2026-06-01T00:02:00Z",
        extraCoverageCases: [
            ("netgen-standard-gds-policy", [
                "external.netgen",
                "layout.gds",
                "lvs.extract.connectivity",
                "lvs.extract.devices",
                "lvs.input.gds",
                "lvs.diode-terminal-equivalence",
                "lvs.netgen.policy-gap.parameter-mismatch",
                "lvs.netgen.policy-gap.terminal-equivalence",
                "lvs.parameter-mismatch",
                "lvs.terminal-equivalence-policy",
            ]),
        ]
    )
    let policy = LVSCorpusCoverageAuditPolicy(
        policyID: "lvs.retained-report-future-test",
        minimumCaseCount: 1,
        maxReportAgeSeconds: 60,
        requirements: []
    )

    let audit = LVSCorpusCoverageAuditor().audit(
        report: report,
        reportPath: "/tmp/lvs-corpus-report.json",
        policy: policy,
        checkedAt: ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")
    )

    let freshness = try #require(audit.missingRequirements.first {
        $0.requirementID == "retained-report-freshness"
    })
    #expect(audit.status == .incomplete)
    #expect(audit.summary.reportAgeSeconds == -120)
    #expect(freshness.observedCaseCount == 0)
    #expect(freshness.reason.contains("newer than checkedAt"))
}

@Test func corpusCoverageAuditRejectsOracleMismatchEvenWhenReportIsMarkedPassed() throws {
    var caseResults = netgenExpandedCoverageReport(extraCoverageCases: [
        ("netgen-standard-gds-policy", [
            "external.netgen",
            "layout.gds",
            "lvs.extract.connectivity",
            "lvs.extract.devices",
            "lvs.input.gds",
            "lvs.diode-terminal-equivalence",
            "lvs.netgen.policy-gap.parameter-mismatch",
            "lvs.netgen.policy-gap.terminal-equivalence",
            "lvs.parameter-mismatch",
            "lvs.terminal-equivalence-policy",
        ]),
    ]).caseResults
    let firstCase = caseResults[0]
    caseResults[0] = LVSCorpusCaseResult(
        caseID: firstCase.caseID,
        matched: true,
        expectedPassed: firstCase.expectedPassed,
        actualPassed: firstCase.actualPassed,
        expectedActiveErrorRuleIDs: firstCase.expectedActiveErrorRuleIDs,
        actualActiveErrorRuleIDs: firstCase.actualActiveErrorRuleIDs,
        coverageTags: firstCase.coverageTags,
        expectationMatched: firstCase.expectationMatched,
        durationSeconds: firstCase.durationSeconds,
        expectedMaxDurationSeconds: firstCase.expectedMaxDurationSeconds,
        durationBudgetPassed: firstCase.durationBudgetPassed,
        failureReasons: ["oracle-agreement: native and Netgen verdicts differ"],
        diagnosticSummary: firstCase.diagnosticSummary,
        reportPath: firstCase.reportPath,
        manifestPath: firstCase.manifestPath,
        extractedLayoutNetlistPath: firstCase.extractedLayoutNetlistPath,
        primaryProvenance: firstCase.primaryProvenance,
        oracleResult: LVSCorpusOracleResult(
            backendID: "netgen",
            passed: false,
            activeErrorRuleIDs: ["LVS_PORT_MISMATCH"],
            diagnosticSummary: LVSDiagnosticSummary(infoCount: 0, warningCount: 0, errorCount: 1),
            durationSeconds: 0.1,
            agreementPassed: false,
            failureReasons: ["oracle-agreement: native and Netgen verdicts differ"],
            reportPath: "/tmp/\(firstCase.caseID)/oracle-netgen/lvs-report.json",
            manifestPath: "/tmp/\(firstCase.caseID)/oracle-netgen/lvs-artifact-manifest.json",
            extractedLayoutNetlistPath: nil
        ),
        oracleComparison: firstCase.oracleComparison
    )
    let report = LVSCorpusReport(
        generatedAt: "2026-06-01T00:00:00Z",
        passed: true,
        caseCount: caseResults.count,
        matchedCaseCount: caseResults.count,
        budgetExceededCaseCount: 0,
        totalDurationSeconds: 1,
        summary: LVSCorpusSummary(caseResults: caseResults),
        qualification: LVSCorpusQualificationResult(
            policy: LVSCorpusQualificationPolicy(
                requireCorpusPassed: false,
                minimumPassRate: 0,
                minimumDurationBudgetPassRate: 0
            ),
            failures: []
        ),
        caseResults: caseResults
    )

    let audit = LVSCorpusCoverageAuditor().audit(report: report, reportPath: "/tmp/lvs-corpus-report.json")

    #expect(audit.status == .incomplete)
    #expect(audit.missingRequirements.contains {
        $0.requirementID == "oracle-agreement"
            && $0.reason.contains("oracle comparison cases disagree")
    })
    #expect(audit.suggestedActions.contains {
        $0.actionID == "classify_lvs_oracle_disagreement"
    })
}

@Test func corpusCoverageAuditCLIWritesMissingRequirements() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let reportURL = root.appending(path: "lvs-corpus-report.json")
    let auditURL = root.appending(path: "lvs-corpus-coverage-audit.json")
    try writeJSON(netgenExpandedCoverageReport(), to: reportURL)

    let exitCode = await LVSCLI.run(arguments: [
        "--audit-corpus-coverage", reportURL.path(percentEncoded: false),
        "--out", auditURL.path(percentEncoded: false),
        "--audit-id", "netgen-foundry-expansion-check",
    ])

    #expect(exitCode == 2)
    let audit = try JSONDecoder().decode(
        LVSCorpusCoverageAudit.self,
        from: Data(contentsOf: auditURL)
    )
    #expect(audit.auditID == "netgen-foundry-expansion-check")
    #expect(audit.status == .incomplete)
    #expect(audit.policyID == "lvs.netgen-foundry-expansion.v1")
    #expect(audit.missingRequirements.contains {
        $0.requirementID == "pin-policy-coverage"
            && $0.missingCoverageTags == [
                "lvs.netgen.policy-gap.terminal-equivalence",
                "lvs.terminal-equivalence-policy",
            ]
    })
}

@Test func corpusCoverageAuditCLIRejectsStaleRetainedReport() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let reportURL = root.appending(path: "lvs-corpus-report.json")
    let policyURL = root.appending(path: "lvs-corpus-coverage-policy.json")
    let auditURL = root.appending(path: "lvs-corpus-coverage-audit.json")
    try writeJSON(netgenExpandedCoverageReport(generatedAt: "2026-06-01T00:00:00Z"), to: reportURL)
    try writeJSON(
        LVSCorpusCoverageAuditPolicy(
            policyID: "lvs.retained-report-freshness-test",
            minimumCaseCount: 1,
            maxReportAgeSeconds: 60,
            requirements: []
        ),
        to: policyURL
    )

    let exitCode = await LVSCLI.run(arguments: [
        "--audit-corpus-coverage", reportURL.path(percentEncoded: false),
        "--coverage-policy", policyURL.path(percentEncoded: false),
        "--checked-at", "2026-06-01T00:02:00Z",
        "--out", auditURL.path(percentEncoded: false),
        "--json",
    ])

    #expect(exitCode == 2)
    let audit = try JSONDecoder().decode(
        LVSCorpusCoverageAudit.self,
        from: Data(contentsOf: auditURL)
    )
    #expect(audit.summary.checkedAt == "2026-06-01T00:02:00Z")
    #expect(audit.summary.reportAgeSeconds == 120)
    #expect(audit.missingRequirements.contains { $0.requirementID == "retained-report-freshness" })
}

@Test func corpusCLIOverridesOracleBackendForQualificationLane() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let outputDirectory = root.appending(path: "corpus-output")
    let specURL = fixtureCorpusSpecURL("lvs-corpus.json")

    let exitCode = await LVSCLI.run(arguments: [
        "--corpus", specURL.path(percentEncoded: false),
        "--out", outputDirectory.path(percentEncoded: false),
        "--oracle-backend", "missing-oracle",
        "--json",
    ])

    #expect(exitCode == 2)
    let reportURL = outputDirectory.appending(path: "lvs-corpus-report.json")
    let report = try JSONDecoder().decode(LVSCorpusReport.self, from: Data(contentsOf: reportURL))
    let expectedOracleCaseCount = report.caseResults.count
    #expect(report.runOptions.oracleBackendIDOverride == "missing-oracle")
    #expect(report.summary.oracleCaseCount == expectedOracleCaseCount)
    #expect(report.summary.oracleExecutionFailedCaseCount == expectedOracleCaseCount)
    #expect(report.summary.oracleReadinessBlockedCaseCount == expectedOracleCaseCount)
    #expect(report.summary.failureCategoryCounts["oracle_execution_failed"] == expectedOracleCaseCount)
    #expect(report.caseResults.allSatisfy { $0.oracleResult?.backendID == "missing-oracle" })
    #expect(report.caseResults.allSatisfy { $0.oracleResult?.agreementPassed == false })
    #expect(report.caseResults.allSatisfy { $0.oracleResult?.readinessStatus == .blocked })
    #expect(report.caseResults.allSatisfy {
        $0.oracleResult?.readinessDiagnostics.contains {
            $0.contains("Unsupported LVS backend: missing-oracle")
        } == true
    })
    #expect(report.qualification.failures.map(\.code).contains("oracle_execution_failed"))
}

@Test func corpusCLIFailsWhenDurationBudgetIsExceeded() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let outputDirectory = root.appending(path: "corpus-output")
    let specURL = fixtureCorpusSpecURL("lvs-corpus-tight-budget.json")

    let exitCode = await LVSCLI.run(arguments: [
        "--corpus", specURL.path(percentEncoded: false),
        "--out", outputDirectory.path(percentEncoded: false),
        "--json",
    ])

    #expect(exitCode == 2)
    let reportURL = outputDirectory.appending(path: "lvs-corpus-report.json")
    let report = try JSONDecoder().decode(LVSCorpusReport.self, from: Data(contentsOf: reportURL))
    #expect(!report.passed)
    #expect(report.caseCount == 1)
    #expect(report.matchedCaseCount == 0)
    #expect(report.budgetExceededCaseCount == 1)
    #expect(report.summary.passRate == 0)
    #expect(report.summary.failureCategoryCounts["duration_exceeded"] == 1)
    #expect(report.summary.oracleCaseCount == 0)
    #expect(!report.qualification.qualified)
    let failureCodes = Set(report.qualification.failures.map(\.code))
    #expect(failureCodes.contains("corpus_not_passed"))
    #expect(failureCodes.contains("pass_rate_below_minimum"))
    #expect(failureCodes.contains("duration_budget_pass_rate_below_minimum"))
    let result = try #require(report.caseResults.first)
    #expect(result.expectationMatched)
    #expect(!result.durationBudgetPassed)
    #expect(result.failureReasons.contains { $0.hasPrefix("duration_exceeded:") })
}

@Test func corpusCLIUsesQualificationPolicyForExitStatus() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let outputDirectory = root.appending(path: "corpus-output")
    let specURL = root.appending(path: "threshold-corpus.json")
    let layoutNetlistPath = try copyCorpusFixture("layout.spice", to: root)
    let schematicNetlistPath = try copyCorpusFixture("matching-schematic.spice", to: root)
    try writeJSON(LVSCorpusSpec(
        defaultMaxDurationSeconds: 0.000000000001,
        qualificationPolicy: LVSCorpusQualificationPolicy(
            requireCorpusPassed: false,
            minimumPassRate: 0,
            minimumDurationBudgetPassRate: 0
        ),
        cases: [
            LVSCorpusCase(
                caseID: "matching-threshold",
                layoutNetlistPath: layoutNetlistPath,
                schematicNetlistPath: schematicNetlistPath,
                topCell: "inv",
                backendID: "native",
                expectedPassed: true
            ),
        ]
    ), to: specURL)

    let exitCode = await LVSCLI.run(arguments: [
        "--corpus", specURL.path(percentEncoded: false),
        "--out", outputDirectory.path(percentEncoded: false),
        "--json",
    ])

    #expect(exitCode == 0)
    let reportURL = outputDirectory.appending(path: "lvs-corpus-report.json")
    let report = try JSONDecoder().decode(LVSCorpusReport.self, from: Data(contentsOf: reportURL))
    #expect(!report.passed)
    #expect(report.summary.failureCategoryCounts["duration_exceeded"] == 1)
    #expect(report.qualification.qualified)
    #expect(!report.qualification.policy.requireCorpusPassed)
    #expect(report.qualification.policy.minimumDurationBudgetPassRate == 0)
}

@Test func corpusCLIRequiresCoverageTagsForQualification() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let outputDirectory = root.appending(path: "corpus-output")
    let specURL = root.appending(path: "coverage-corpus.json")
    let layoutNetlistPath = try copyCorpusFixture("layout.spice", to: root)
    let schematicNetlistPath = try copyCorpusFixture("matching-schematic.spice", to: root)
    try writeJSON(LVSCorpusSpec(
        qualificationPolicy: LVSCorpusQualificationPolicy(
            requiredCoverageTags: ["lvs.hierarchy", "lvs.match"]
        ),
        cases: [
            LVSCorpusCase(
                caseID: "matching-coverage",
                layoutNetlistPath: layoutNetlistPath,
                schematicNetlistPath: schematicNetlistPath,
                topCell: "inv",
                backendID: "native",
                expectedPassed: true,
                coverageTags: ["lvs.match"]
            ),
        ]
    ), to: specURL)

    let exitCode = await LVSCLI.run(arguments: [
        "--corpus", specURL.path(percentEncoded: false),
        "--out", outputDirectory.path(percentEncoded: false),
        "--json",
    ])

    #expect(exitCode == 2)
    let reportURL = outputDirectory.appending(path: "lvs-corpus-report.json")
    let report = try JSONDecoder().decode(LVSCorpusReport.self, from: Data(contentsOf: reportURL))
    #expect(report.passed)
    #expect(report.summary.coverageTagCounts == ["lvs.match": 1])
    let failure = try #require(report.qualification.failures.first { $0.code == "required_coverage_missing" })
    #expect(failure.observedCount == 1)
    #expect(failure.requiredCount == 2)
    #expect(failure.observedText == "lvs.match")
    #expect(failure.requiredText == "lvs.hierarchy")
}

@Test func corpusReportQualificationCLIRechecksSavedReport() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let outputDirectory = root.appending(path: "corpus-output")
    let policyURL = root.appending(path: "permissive-policy.json")
    let specURL = fixtureCorpusSpecURL("lvs-corpus-tight-budget.json")

    let corpusExitCode = await LVSCLI.run(arguments: [
        "--corpus", specURL.path(percentEncoded: false),
        "--out", outputDirectory.path(percentEncoded: false),
        "--json",
    ])
    #expect(corpusExitCode == 2)

    let reportURL = outputDirectory.appending(path: "lvs-corpus-report.json")
    let embeddedExitCode = await LVSCLI.run(arguments: [
        "--qualify-corpus-report", reportURL.path(percentEncoded: false),
        "--json",
    ])
    #expect(embeddedExitCode == 2)

    try writeJSON(LVSCorpusQualificationPolicy(
        requireCorpusPassed: false,
        minimumPassRate: 0,
        minimumDurationBudgetPassRate: 0
    ), to: policyURL)

    let overriddenExitCode = await LVSCLI.run(arguments: [
        "--qualify-corpus-report", reportURL.path(percentEncoded: false),
        "--qualification-policy", policyURL.path(percentEncoded: false),
        "--json",
    ])
    #expect(overriddenExitCode == 0)
}

}
