import Foundation
import Testing
import LVSCore
import LVSCLICore

extension LVSCLIOptionsTests {
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
    #expect(report.summary.oracleReadinessBlockedCaseCount == 0)
    #expect(report.summary.failureCategoryCounts.isEmpty)
    #expect(report.summary.coverageTagCounts["lvs.match"] == 22)
    #expect(report.summary.coverageTagCounts["lvs.port-mismatch"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.model-mismatch"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.parameter-mismatch"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.parameter-mismatch.subckt"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.hierarchy"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.model-mismatch.hierarchical"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.subckt-parameter"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.symmetric-terminals"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.mos-source-drain-permutation"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.passive-terminal-permutation"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.diode-terminal-equivalence"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.terminal-equivalence-policy"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.extract.connectivity"] == 8)
    #expect(report.summary.coverageTagCounts["lvs.extract.devices"] == 8)
    #expect(report.summary.coverageTagCounts["lvs.extract.nmos"] == 7)
    #expect(report.summary.coverageTagCounts["lvs.extract.pmos"] == 2)
    #expect(report.summary.coverageTagCounts["lvs.extract.cmos-inverter"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.extract.policy"] == 2)
    #expect(report.summary.coverageTagCounts["lvs.input.gds"] == 5)
    #expect(report.summary.coverageTagCounts["lvs.input.oasis"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.input.cif"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.input.dxf"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.numeric-parameters"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.global-nets"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.device-breadth"] == 2)
    #expect(report.summary.coverageTagCounts["lvs.diode"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.bjt"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.inductor"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.independent-sources"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.controlled-sources"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.sources"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.multiplicity"] == 2)
    #expect(report.summary.coverageTagCounts["lvs.parallel-devices"] == 2)
    #expect(report.summary.coverageTagCounts["lvs.series-devices"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.device-policy"] == 2)
    #expect(report.summary.coverageTagCounts["lvs.device-policy.parallel"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.device-policy.series"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.model-equivalence"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.model-alias"] == 1)
    #expect(report.summary.coverageTagCounts["spice.global"] == 1)
    #expect(report.summary.coverageTagCounts["spice.continuation"] == 1)
    #expect(report.summary.coverageTagCounts["spice.include"] == 1)
    #expect(report.summary.coverageTagCounts["spice.inline-comment"] == 1)
    #expect(report.summary.coverageTagCounts["spice.lib"] == 1)
    #expect(report.summary.coverageTagCounts["spice.option-scale"] == 1)
    #expect(report.summary.coverageTagCounts["spice.param"] == 1)
    #expect(report.summary.coverageTagCounts["spice.param-expression"] == 1)
    #expect(report.summary.coverageTagCounts["spice.scale-suffix"] == 1)
    #expect(report.summary.coverageTagCounts["passive.numeric-equivalence"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.model-mismatch.waived"] == 1)
    #expect(report.summary.coverageTagCounts["lvs.waiver"] == 1)
    #expect(report.qualification.qualified)
    #expect(report.qualification.policy.requiredCoverageTags == [
        "lvs.bjt",
        "lvs.controlled-sources",
        "lvs.device-breadth",
        "lvs.device-policy",
        "lvs.device-policy.parallel",
        "lvs.device-policy.series",
        "lvs.diode",
        "lvs.diode-terminal-equivalence",
        "lvs.extract.cmos-inverter",
        "lvs.extract.connectivity",
        "lvs.extract.devices",
        "lvs.extract.nmos",
        "lvs.extract.pmos",
        "lvs.extract.policy",
        "lvs.global-nets",
        "lvs.hierarchy",
        "lvs.independent-sources",
        "lvs.inductor",
        "lvs.input.cif",
        "lvs.input.dxf",
        "lvs.input.gds",
        "lvs.input.oasis",
        "lvs.match",
        "lvs.model-alias",
        "lvs.model-equivalence",
        "lvs.model-mismatch",
        "lvs.mos-source-drain-permutation",
        "lvs.multiplicity",
        "lvs.numeric-parameters",
        "lvs.parallel-devices",
        "lvs.parameter-mismatch",
        "lvs.passive-terminal-permutation",
        "lvs.port-mismatch",
        "lvs.series-devices",
        "lvs.sources",
        "lvs.subckt-parameter",
        "lvs.symmetric-terminals",
        "lvs.terminal-equivalence-policy",
        "lvs.waiver",
        "spice.continuation",
        "spice.include",
        "spice.inline-comment",
        "spice.lib",
        "spice.option-scale",
        "spice.param",
        "spice.param-expression",
    ])
    #expect(report.qualification.failures.isEmpty)
    #expect(report.caseResults.allSatisfy { $0.durationBudgetPassed })
    #expect(report.caseResults.allSatisfy { $0.expectedMaxDurationSeconds == 10 })
    #expect(report.caseResults.allSatisfy { $0.failureReasons.isEmpty })
    #expect(report.caseResults.allSatisfy { !$0.coverageTags.isEmpty })
    #expect(Set(report.caseResults.compactMap { $0.oracleResult?.backendID }) == ["native", "native-gds"])
    #expect(report.caseResults.allSatisfy { $0.oracleResult?.agreementPassed == true })
    #expect(report.caseResults.allSatisfy { $0.oracleResult?.readinessStatus == .ready })
    #expect(report.caseResults.allSatisfy { $0.oracleResult?.readinessDiagnostics.isEmpty == true })
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
            && $0.coverageTags.contains("lvs.input.gds")
            && $0.coverageTags.contains("lvs.extract.devices")
            && $0.coverageTags.contains("lvs.extract.connectivity")
    })
    #expect(report.caseResults.contains {
        $0.caseID == "standard-gds-pmos-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
            && $0.coverageTags.contains("lvs.extract.pmos")
    })
    #expect(report.caseResults.contains {
        $0.caseID == "standard-gds-cmos-inverter-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
            && $0.coverageTags.contains("lvs.extract.cmos-inverter")
    })
    #expect(report.caseResults.contains {
        $0.caseID == "standard-gds-parallel-nmos-policy-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
            && $0.coverageTags.contains("lvs.extract.policy")
            && $0.coverageTags.contains("lvs.device-policy.parallel")
            && $0.extractedLayoutNetlistPath != nil
    })
    #expect(report.caseResults.contains {
        $0.caseID == "standard-gds-series-nmos-policy-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
            && $0.coverageTags.contains("lvs.extract.policy")
            && $0.coverageTags.contains("lvs.device-policy.series")
            && $0.extractedLayoutNetlistPath != nil
    })
    #expect(report.caseResults.contains {
        $0.caseID == "standard-oasis-nmos-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
            && $0.coverageTags.contains("lvs.input.oasis")
            && $0.coverageTags.contains("lvs.extract.nmos")
    })
    #expect(report.caseResults.contains {
        $0.caseID == "standard-cif-nmos-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
            && $0.coverageTags.contains("lvs.input.cif")
            && $0.coverageTags.contains("lvs.extract.nmos")
    })
    #expect(report.caseResults.contains {
        $0.caseID == "standard-dxf-nmos-match"
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
            && $0.coverageTags.contains("lvs.input.dxf")
            && $0.coverageTags.contains("lvs.extract.nmos")
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
            && $0.actualPassed
            && $0.actualActiveErrorRuleIDs.isEmpty
            && $0.diagnosticSummary.waivedErrorCount == 1
    })
    #expect(report.caseResults.allSatisfy { $0.reportPath != nil && $0.manifestPath != nil })
}

}
