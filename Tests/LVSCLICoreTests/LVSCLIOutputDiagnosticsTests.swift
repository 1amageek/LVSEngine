import Foundation
import Testing
import LVSCore
import LVSCLICore

extension LVSCLIOptionsTests {
@Test func corpusReportRejectsMissingEvidenceProjections() {
    let data = Data("""
    {
      "schemaVersion" : 1,
      "passed" : true,
      "caseCount" : 0,
      "matchedCaseCount" : 0,
      "budgetExceededCaseCount" : 0,
      "totalDurationSeconds" : 0,
      "caseResults" : []
    }
    """.utf8)

    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(LVSCorpusReport.self, from: data)
    }
}

@Test func cliOutputIncludesStructuredDiagnostics() {
    let diagnostic = LVSDiagnostic(
        severity: .error,
        message: "Component signature count differs",
        ruleID: "LVS_COMPONENT_MISMATCH",
        category: "componentCountMismatch",
        componentSignature: "mos|nmos|out,in,vss,vss|",
        layoutCount: 1,
        schematicCount: 0,
        suggestedFix: "Compare extracted and schematic devices.",
        rawLine: "signature=mos|nmos layout=1 schematic=0"
    )
    let output = LVSCLIOutput(result: LVSExecutionResult(
        request: LVSRequest(
            layoutNetlistURL: URL(filePath: "/tmp/layout.spice"),
            schematicNetlistURL: URL(filePath: "/tmp/schematic.spice"),
            topCell: "inv"
        ),
        result: LVSResult(
            backendID: "native",
            toolName: "NativeLVS",
            executionStatus: .completed,
            verdict: .mismatch,
            readiness: .ready,
            logPath: "",
            diagnostics: [diagnostic]
        ),
        waiverReport: LVSWaiverApplicationReport(
            waivedDiagnosticCount: 0,
            appliedWaivers: [],
            unusedWaiverIDs: ["unused"]
        )
    ))

    #expect(output.status == "failed")
    #expect(output.diagnosticSummary.errorCount == 1)
    #expect(output.runSummary.activeMismatchCount == 1)
    #expect(output.runSummary.waivedMismatchCount == 0)
    #expect(output.runSummary.mismatchBuckets.first?.ruleID == "LVS_COMPONENT_MISMATCH")
    #expect(output.runSummary.mismatchBuckets.first?.componentSignature == "mos|nmos|out,in,vss,vss|")
    #expect(output.diagnostics == [diagnostic])
    #expect(output.waiverReport?.unusedWaiverIDs == ["unused"])
}

@Test func malformedWaiverMarkerDoesNotHideErrorDiagnostic() {
    let blankIDDiagnostic = LVSDiagnostic(
        severity: .error,
        message: "Component signature count differs",
        ruleID: "LVS_COMPONENT_MISMATCH",
        category: "componentCountMismatch",
        componentSignature: "mos|nmos|out,in,vss,vss|",
        suggestedFix: "Compare extracted and schematic devices.",
        waiverID: " ",
        waiverReason: "Known fixture mismatch",
        rawLine: "signature=mos|nmos layout=1 schematic=0"
    )
    let missingReasonDiagnostic = LVSDiagnostic(
        severity: .error,
        message: "Parameter value differs",
        ruleID: "LVS_PARAMETER_MISMATCH",
        category: "parameterMismatch",
        componentSignature: "mos|pmos|out,in,vdd,vdd|",
        suggestedFix: "Check model parameters.",
        waiverID: "waive-without-reason",
        waiverReason: nil,
        rawLine: "parameter=w"
    )
    let result = LVSResult(
        backendID: "native",
        toolName: "NativeLVS",
        executionStatus: .completed,
        verdict: .mismatch,
        readiness: .ready,
        logPath: "",
        diagnostics: [blankIDDiagnostic, missingReasonDiagnostic]
    )
    let output = LVSCLIOutput(result: LVSExecutionResult(
        request: LVSRequest(
            layoutNetlistURL: URL(filePath: "/tmp/layout.spice"),
            schematicNetlistURL: URL(filePath: "/tmp/schematic.spice"),
            topCell: "inv"
        ),
        result: result
    ))

    #expect(!blankIDDiagnostic.isWaived)
    #expect(!missingReasonDiagnostic.isWaived)
    #expect(!result.passed)
    #expect(output.status == "failed")
    #expect(output.diagnosticSummary.errorCount == 2)
    #expect(output.diagnosticSummary.waivedErrorCount == 0)
    #expect(output.runSummary.activeMismatchCount == 2)
    #expect(output.runSummary.waivedMismatchCount == 0)
}

}
