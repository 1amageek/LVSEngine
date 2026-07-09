import Foundation
import Testing
import LVSCore
import LVSCLICore

extension LVSCLIOptionsTests {
@Test func repairHintBuilderMapsActiveDiagnosticsToEngineOwnedOperations() throws {
    let result = makeRepairHintExecutionResult()
    let report = LVSRepairHintBuilder().build(result: result, reportURL: URL(filePath: "/tmp/lvs-report.json"))

    #expect(report.schemaVersion == 1)
    #expect(report.status == "partial")
    #expect(report.backendID == "native")
    #expect(report.topCell == "inv")
    #expect(report.activeDiagnosticCount == 5)
    #expect(report.hintCount == 4)
    #expect(report.unsupportedDiagnosticIndexes == [4])
    let unsupported = try #require(report.unsupportedDiagnostics.first)
    #expect(unsupported.sourceDiagnosticIndex == 4)
    #expect(unsupported.code == "lvs-repair-unsupported-lvs-component-mismatch")
    #expect(unsupported.severity == .error)
    #expect(unsupported.message == "Component count differs")
    #expect(unsupported.ruleID == "LVS_COMPONENT_MISMATCH")
    #expect(unsupported.category == "componentCountMismatch")
    #expect(unsupported.suggestedActions.contains("Compare extracted devices."))
    #expect(!unsupported.reason.isEmpty)

    let portHint = try #require(report.hints.first { $0.operationID == "layout.add-label" })
    #expect(portHint.hintID == "lvs-repair-0-LVS_PORT_MISMATCH")
    #expect(portHint.sourceDiagnosticIndex == 0)
    #expect(portHint.confidence == "high")
    #expect(portHint.ruleID == "LVS_PORT_MISMATCH")
    #expect(portHint.category == "portMismatch")
    #expect(portHint.layoutPorts == ["in", "out"])
    #expect(portHint.schematicPorts == ["in", "out", "vdd"])
    #expect(portHint.stringParameters["portName"] == "vdd")
    #expect(portHint.stringParameters["labelText"] == "vdd")
    #expect(portHint.stringParameters["netName"] == "vdd")
    #expect(portHint.verificationGates.contains("native-drc"))

    let policyHint = try #require(report.hints.first { $0.ruleID == "LVS_MODEL_MISMATCH" })
    #expect(policyHint.sourceDiagnosticIndex == 1)
    #expect(policyHint.confidence == "medium")
    #expect(policyHint.ruleID == "LVS_MODEL_MISMATCH")
    #expect(policyHint.layoutModel == "sky130_fd_pr__nfet_01v8")
    #expect(policyHint.schematicModel == "nmos")
    #expect(policyHint.stringParameters["policyKind"] == "model-equivalence")
    #expect(policyHint.stringParameters["layoutModel"] == "sky130_fd_pr__nfet_01v8")
    #expect(policyHint.stringParameters["schematicModel"] == "nmos")
    #expect(policyHint.verificationGates.contains("approval-gate"))

    let terminalPolicyHint = try #require(report.hints.first {
        $0.ruleID == "LVS_TERMINAL_EQUIVALENCE_MISMATCH"
    })
    #expect(terminalPolicyHint.sourceDiagnosticIndex == 2)
    #expect(terminalPolicyHint.operationID == "lvs.policy-repair")
    #expect(terminalPolicyHint.stringParameters["policyKind"] == "terminal-equivalence")
    #expect(terminalPolicyHint.stringParameters["terminalKind"] == "diode")
    #expect(terminalPolicyHint.stringParameters["terminalPinCount"] == "2")
    #expect(terminalPolicyHint.stringParameters["equivalentPinGroups"] == "[[0,1]]")
    #expect(terminalPolicyHint.layoutPorts == ["in", "vss"])
    #expect(terminalPolicyHint.schematicPorts == ["vss", "in"])
    #expect(terminalPolicyHint.verificationGates.contains("approval-gate"))

    let parameterHint = try #require(report.hints.first {
        $0.operationID == "simulation.set-netlist-parameters"
    })
    #expect(parameterHint.sourceDiagnosticIndex == 3)
    #expect(parameterHint.ruleID == "LVS_PARAMETER_MISMATCH")
    #expect(parameterHint.category == "parameterMismatch")
    #expect(parameterHint.parameterName == "w")
    #expect(parameterHint.layoutValue == "1u")
    #expect(parameterHint.schematicValue == "2u")
    #expect(parameterHint.stringParameters["layoutComponentName"] == "M1")
    #expect(parameterHint.stringParameters["schematicComponentName"] == "M1")
    #expect(parameterHint.stringParameters["assignmentName"] == "M1.w")
    #expect(parameterHint.stringParameters["lvsEditedNetlistRole"] == "layout")
    #expect(parameterHint.numericParameters?["assignmentValue"] == 2e-6)
    #expect(parameterHint.verificationGates == ["artifact-integrity", "native-lvs"])
}

@Test func repairHintReportDecodesLegacyUnsupportedIndexOnlyArtifacts() throws {
    let data = try #require(
        """
        {
          "schemaVersion": 1,
          "status": "ready",
          "reportURL": null,
          "backendID": "native",
          "topCell": "inv",
          "activeDiagnosticCount": 1,
          "hintCount": 0,
          "hints": [],
          "unsupportedDiagnosticIndexes": [0]
        }
        """.data(using: .utf8)
    )

    let report = try JSONDecoder().decode(LVSRepairHintReport.self, from: data)

    #expect(report.unsupportedDiagnosticIndexes == [0])
    #expect(report.unsupportedDiagnostics == [])
}

@Test func repairHintsCLIReadsSavedReport() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let reportURL = root.appending(path: "lvs-report.json")
    try writeJSON(makeRepairHintExecutionResult(), to: reportURL)

    let exitCode = await LVSCLI.run(arguments: [
        "--repair-hints-from-report", reportURL.path(percentEncoded: false),
        "--json",
    ])

    #expect(exitCode == 0)
}

}
