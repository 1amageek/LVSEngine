import Foundation
import Testing
import LVSCore
import LVSCLICore

extension LVSCLIOptionsTests {
@Test func corpusImportsAndAuditsDevicePolicyDeckBeforeNativeExecution() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let layoutURL = root.appending(path: "layout.spice")
    let schematicURL = root.appending(path: "schematic.spice")
    let deckURL = root.appending(path: "setup.tcl")
    let specURL = root.appending(path: "corpus.json")
    let outputDirectory = root.appending(path: "out")
    try """
    .subckt top d g s b
    M1 d g s b sky130_fd_pr__nfet_01v8 W=1 L=0.15
    .ends top
    """.write(to: layoutURL, atomically: true, encoding: .utf8)
    try """
    .subckt top d g s b
    M1 d g s b sky130_fd_pr__nfet_01v8 W=1 L=0.15
    .ends top
    """.write(to: schematicURL, atomically: true, encoding: .utf8)
    try """
    catch {format $env(NETGEN_COLUMNS)}
    lappend devices sky130_fd_pr__nfet_01v8
    permute default
    property default
    equate pins "-circuit1 sky130_fd_pr__nfet_01v8" "-circuit2 sky130_fd_pr__nfet_01v8"
    """.write(to: deckURL, atomically: true, encoding: .utf8)
    let spec = LVSCorpusSpec(
        qualificationPolicy: LVSCorpusQualificationPolicy(
            requiredObservedAssertions: [
                "devicePolicyApplication:complete",
                "devicePolicyImport:satisfied",
                "devicePolicyRule:permute",
            ]
        ),
        cases: [
        LVSCorpusCase(
            caseID: "device-policy-deck",
            layoutNetlistPath: "layout.spice",
            schematicNetlistPath: "schematic.spice",
            topCell: "top",
            devicePolicyDeckPath: "setup.tcl",
            backendID: "native",
            expectedPassed: true,
            requiredAssertions: [
                LVSCorpusAssertionRequirement(
                    assertionID: "policy-import",
                    kind: .devicePolicyImport,
                    expectedValue: "satisfied"
                ),
                LVSCorpusAssertionRequirement(
                    assertionID: "policy-application",
                    kind: .devicePolicyApplication,
                    expectedValue: "complete"
                ),
                LVSCorpusAssertionRequirement(
                    assertionID: "policy-permute",
                    kind: .devicePolicyRule,
                    expectedValue: "permute"
                ),
            ]
        )
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(spec).write(to: specURL, options: [.atomic])

    let exitCode = await LVSCLI.run(arguments: [
        "--corpus", specURL.path(percentEncoded: false),
        "--out", outputDirectory.path(percentEncoded: false),
    ])

    let report = try JSONDecoder().decode(
        LVSCorpusReport.self,
        from: Data(contentsOf: outputDirectory.appending(path: "lvs-corpus-report.json"))
    )
    #expect(exitCode == 0, "\(report.qualification.failures)")
    let result = try #require(report.caseResults.first)
    let resultReportURL = URL(filePath: try #require(result.reportPath))
    let resultReport = try JSONDecoder().decode(
        LVSExecutionResult.self,
        from: Data(contentsOf: resultReportURL)
    )
    #expect(
        result.matched,
        "\(String(describing: resultReport.devicePolicyReport))"
    )
    #expect(
        result.observedAssertions.allSatisfy { $0.status == .passed },
        "\(result.observedAssertions)"
    )
    let policyDirectory = outputDirectory
        .appending(path: "cases/device-policy-deck/generated-device-policy")
    #expect(FileManager.default.fileExists(atPath: policyDirectory.appending(path: "lvs-device-policy.json").path()))
    #expect(FileManager.default.fileExists(atPath: policyDirectory.appending(path: "lvs-device-import-report.json").path()))
    #expect(FileManager.default.fileExists(atPath: policyDirectory.appending(path: "lvs-device-import-audit.json").path()))
}

@Test func corpusCLIRunsCasesAndWritesReport() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let outputDirectory = root.appending(path: "corpus-output")
    let specURL = fixtureCorpusSpecURL("lvs-corpus.json")

    let exitCode = await LVSCLI.run(arguments: [
        "--corpus", specURL.path(percentEncoded: false),
        "--out", outputDirectory.path(percentEncoded: false),
        "--json",
    ])

    #expect(exitCode == 0)
    let reportURL = outputDirectory.appending(path: "lvs-corpus-report.json")
    let report = try JSONDecoder().decode(LVSCorpusReport.self, from: Data(contentsOf: reportURL))
    #expect(report.passed)
    #expect(report.caseCount == 28)
    #expect(report.matchedCaseCount == 28)
    #expect(report.budgetExceededCaseCount == 0)
    #expect(report.totalDurationSeconds >= 0)
    #expect(report.summary.passRate == 1)
    #expect(report.summary.oracleCaseCount == 28)
    #expect(report.summary.oracleAgreementPassedCaseCount == 28)
    #expect(report.summary.oracleAgreementRate == 1)
    #expect(report.summary.primaryExecutionFailedCaseCount == 0)
    #expect(report.summary.oracleExecutionFailedCaseCount == 0)
    #expect(report.summary.oracleReadinessBlockedCaseCount == 28)
    #expect(report.summary.failureCategoryCounts.isEmpty)
    #expect(report.qualification.qualified)
    #expect(report.qualification.policy.requiredObservedAssertions == [
        "diagnosticRule:LVS_MODEL_MISMATCH",
        "diagnosticRule:LVS_PARAMETER_MISMATCH",
        "diagnosticRule:LVS_PORT_MISMATCH",
        "durationBudget:within-budget",
        "verdict:match",
        "verdict:mismatch",
    ])
    #expect(report.qualification.failures.isEmpty)
    #expect(report.caseResults.allSatisfy { $0.durationBudgetPassed })
    #expect(report.caseResults.allSatisfy { $0.expectedMaxDurationSeconds == 10 })
    #expect(report.caseResults.allSatisfy { $0.failureReasons.isEmpty })
    #expect(Set(report.caseResults.compactMap { $0.oracleResult?.backendID }) == ["native", "native-gds"])
    #expect(report.caseResults.allSatisfy { $0.oracleResult?.agreementPassed == true })
    #expect(report.caseResults.allSatisfy { $0.oracleResult?.readinessStatus == .blocked })
    #expect(report.caseResults.allSatisfy { $0.oracleResult?.readinessDiagnostics.isEmpty == false })
    #expect(report.caseResults.allSatisfy { $0.oracleResult?.reportPath != nil })
    #expect(report.caseResults.allSatisfy { $0.oracleResult?.manifestPath != nil })
    #expect(report.caseResults.allSatisfy { $0.primaryProvenance?.inputArtifacts.isEmpty == false })
    #expect(report.caseResults.allSatisfy { $0.primaryProvenance?.outputArtifacts.isEmpty == false })
    #expect(report.caseResults.allSatisfy { $0.oracleResult?.provenance?.inputArtifacts.isEmpty == false })
    #expect(report.caseResults.allSatisfy { $0.oracleResult?.provenance?.outputArtifacts.isEmpty == false })
    #expect(report.caseResults.allSatisfy { $0.oracleComparison?.agreementPassed == true })
    #expect(report.caseResults.allSatisfy { $0.oracleComparison?.mismatchReasons.isEmpty == true })
    #expect(report.caseResults.contains {
        $0.caseID == "port-mismatch" && $0.actualActiveErrorRuleIDs == ["LVS_PORT_MISMATCH"]
    })
    #expect(report.caseResults.contains {
        $0.caseID == "standard-gds-nmos-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "standard-gds-pmos-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "standard-gds-cmos-inverter-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "standard-gds-parallel-nmos-policy-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
            && $0.extractedLayoutNetlistPath != nil
    })
    #expect(report.caseResults.contains {
        $0.caseID == "standard-gds-series-nmos-policy-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
            && $0.extractedLayoutNetlistPath != nil
    })
    #expect(report.caseResults.contains {
        $0.caseID == "standard-oasis-nmos-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "standard-cif-nmos-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "standard-dxf-nmos-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "model-mismatch"
            && $0.actualActiveErrorRuleIDs == ["LVS_MODEL_MISMATCH"]
    })
    #expect(report.caseResults.contains {
        $0.caseID == "parameter-mismatch"
            && $0.actualActiveErrorRuleIDs == ["LVS_PARAMETER_MISMATCH"]
    })
    #expect(report.caseResults.contains {
        $0.caseID == "hierarchical-model-mismatch"
            && $0.actualActiveErrorRuleIDs == ["LVS_MODEL_MISMATCH"]
    })
    #expect(report.caseResults.contains {
        $0.caseID == "subckt-parameter-mismatch"
            && $0.actualActiveErrorRuleIDs == ["LVS_PARAMETER_MISMATCH"]
    })
    #expect(report.caseResults.contains {
        $0.caseID == "symmetric-terminals"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "terminal-equivalence-policy"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "numeric-equivalent-parameters"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "include-param-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "param-expression-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "lib-section-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "continuation-inline-comment-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "option-scale-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "global-supply-nets"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "device-breadth"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "source-breadth"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "multiplicity"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "model-equivalence"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
    })
    #expect(report.caseResults.contains {
        $0.caseID == "waived-model-mismatch"
            && !$0.actualPassed
            && $0.matched
            && $0.actualActiveErrorRuleIDs.isEmpty
            && $0.diagnosticSummary.waivedErrorCount == 1
    })
    #expect(report.caseResults.allSatisfy { $0.reportPath != nil && $0.manifestPath != nil })
}

}
