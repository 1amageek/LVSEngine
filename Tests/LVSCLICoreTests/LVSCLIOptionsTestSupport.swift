import Foundation
import Testing
import LVSCore
import LVSCLICore

extension LVSCLIOptionsTests {
func captureError(_ operation: () throws -> Void) throws -> LVSCLIError? {
    do {
        try operation()
        return nil
    } catch let error as LVSCLIError {
        return error
    } catch {
        throw error
    }
}

func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "LVSCLIOptionsTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func removeTemporaryDirectory(_ directory: URL) {
    do {
        try FileManager.default.removeItem(at: directory)
    } catch {
        Issue.record("Failed to remove temporary directory: \(error.localizedDescription)")
    }
}

func onlyArtifact(in directory: URL, prefix: String) throws -> URL {
    let matches = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(prefix) }
    #expect(matches.count == 1)
    return try #require(matches.first)
}

func canonicalPath(_ url: URL?) -> String? {
    url?.resolvingSymlinksInPath().path(percentEncoded: false)
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try data.write(to: url, options: [.atomic])
}

@discardableResult
func copyCorpusFixture(_ name: String, to directory: URL) throws -> String {
    let destination = directory.appending(path: name)
    try FileManager.default.copyItem(at: fixtureCorpusSpecURL(name), to: destination)
    return name
}

func failingLVSCorpusReport() -> LVSCorpusReport {
    LVSCorpusReport(
        passed: false,
        caseCount: 1,
        matchedCaseCount: 0,
        budgetExceededCaseCount: 0,
        totalDurationSeconds: 0.21,
        caseResults: [
            LVSCorpusCaseResult(
                caseID: "case-model",
                matched: false,
                expectedPassed: true,
                actualPassed: false,
                expectedActiveErrorRuleIDs: ["LVS_MATCH"],
                actualActiveErrorRuleIDs: ["LVS_MODEL_MISMATCH"],
                expectationMatched: false,
                durationSeconds: 0.21,
                expectedMaxDurationSeconds: 1,
                durationBudgetPassed: true,
                failureReasons: [
                    "model-mismatch: layout sky130_fd_pr__nfet_01v8 schematic sky130_fd_pr__pfet_01v8",
                ],
                diagnosticSummary: LVSDiagnosticSummary(
                    infoCount: 0,
                    warningCount: 0,
                    errorCount: 1
                ),
                reportPath: "/tmp/case-model/lvs-report.json",
                manifestPath: "/tmp/case-model/lvs-artifact-manifest.json",
                extractedLayoutNetlistPath: "/tmp/case-model/extracted-layout.spice",
                oracleResult: LVSCorpusOracleResult(
                    backendID: "netgen",
                    passed: false,
                    activeErrorRuleIDs: ["LVS_MODEL_MISMATCH"],
                    diagnosticSummary: LVSDiagnosticSummary(
                        infoCount: 0,
                        warningCount: 0,
                        errorCount: 1
                    ),
                    durationSeconds: 0,
                    agreementPassed: false,
                    readinessStatus: .blocked,
                    readinessDiagnostics: ["Netgen LVS oracle is not available for this case."],
                    failureReasons: [
                        "oracle-agreement: native and Netgen model mismatch diagnostics differ",
                    ],
                    reportPath: "/tmp/case-model/oracle-lvs-report.json",
                    manifestPath: "/tmp/case-model/oracle-lvs-artifact-manifest.json",
                    extractedLayoutNetlistPath: "/tmp/case-model/oracle-extracted-layout.spice"
                )
            ),
        ]
    )
}

func writeNetgenLVSDeck(root: URL) throws {
    try writeText(
        """
        lappend devices sky130_fd_pr__nfet_01v8
        lappend devices sky130_fd_pr__res_generic_m1
        lappend devices sky130_fd_pr__diode_pw2nd_05v5
        lappend devices sky130_fd_pr__cap_mim_m3_1
        lappend devices sky130_fd_pr__npn_05v5
        lappend devices sky130_fd_pr__ind_04_01
        foreach dev $devices {
            permute "-circuit1 $dev" 1 2
            property "-circuit1 $dev" parallel enable
            equate pins "-circuit1 $dev" "-circuit2 $dev"
        }
        """,
        to: root.appending(path: "sky130A/libs.tech/netgen/sky130A_setup.tcl")
    )
}

func writeText(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try text.write(to: url, atomically: true, encoding: .utf8)
}

func makeRepairHintExecutionResult() throws -> LVSExecutionResult {
    try LVSExecutionResult.inProcess(
        request: LVSRequest(
            layoutNetlistURL: URL(filePath: "/tmp/layout.spice"),
            schematicNetlistURL: URL(filePath: "/tmp/schematic.spice"),
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ),
        result: LVSResult(
            backendID: "native",
            toolName: "NativeLVS",
            executionStatus: .completed,
            verdict: .mismatch,
            readiness: .ready,
            logPath: "",
            diagnostics: [
                LVSDiagnostic(
                    severity: .error,
                    message: "Layout and schematic ports differ",
                    ruleID: "LVS_PORT_MISMATCH",
                    category: "portMismatch",
                    layoutPorts: ["in", "out"],
                    schematicPorts: ["in", "out", "vdd"],
                    suggestedFix: "Add missing layout port labels.",
                    rawLine: "layout_ports=in,out schematic_ports=in,out,vdd"
                ),
                LVSDiagnostic(
                    severity: .error,
                    message: "Model mismatch",
                    ruleID: "LVS_MODEL_MISMATCH",
                    category: "modelMismatch",
                    componentSignature: "mos|nmos|out,in,vss,vss|",
                    layoutModel: "sky130_fd_pr__nfet_01v8",
                    schematicModel: "nmos",
                    suggestedFix: "Review model equivalence policy.",
                    rawLine: "layout_model=sky130_fd_pr__nfet_01v8 schematic_model=nmos"
                ),
                LVSDiagnostic(
                    severity: .error,
                    message: "Terminal equivalence mismatch",
                    ruleID: "LVS_TERMINAL_EQUIVALENCE_MISMATCH",
                    category: "terminalEquivalence",
                    componentSignature: "diode|diode|in,vss|",
                    layoutModel: "diode",
                    schematicModel: "diode",
                    layoutPorts: ["in", "vss"],
                    schematicPorts: ["vss", "in"],
                    suggestedFix: "Review terminal equivalence policy.",
                    rawLine: "layout_ports=in,vss schematic_ports=vss,in"
                ),
                LVSDiagnostic(
                    severity: .error,
                    message: "Component parameter differs",
                    ruleID: "LVS_PARAMETER_MISMATCH",
                    category: "parameterMismatch",
                    componentSignature: "mos|nmos|out,in,vss,vss||nmos",
                    layoutModel: "nmos",
                    schematicModel: "nmos",
                    parameterName: "w",
                    layoutValue: "1u",
                    schematicValue: "2u",
                    suggestedFix: "Align the w parameter for the matching device topology.",
                    rawLine: "topology=mos|nmos parameter=w layout=1e-6 schematic=2e-6",
                    layoutComponentName: "M1",
                    schematicComponentName: "M1"
                ),
                LVSDiagnostic(
                    severity: .error,
                    message: "Component count differs",
                    ruleID: "LVS_COMPONENT_MISMATCH",
                    category: "componentCountMismatch",
                    componentSignature: "res|rpoly|in,out|",
                    layoutCount: 0,
                    schematicCount: 1,
                    suggestedFix: "Compare extracted devices.",
                    rawLine: "layout=0 schematic=1"
                ),
                LVSDiagnostic(
                    severity: .error,
                    message: "Waived model mismatch",
                    ruleID: "LVS_MODEL_MISMATCH",
                    category: "modelMismatch",
                    layoutModel: "waived_model",
                    schematicModel: "nmos",
                    waiverID: "waive-known-model",
                    waiverReason: "Known fixture mismatch",
                    rawLine: "waived"
                ),
            ]
        )
    )
}

func fixtureCorpusSpecURL(_ name: String) -> URL {
    guard let url = Bundle.module.url(
        forResource: name,
        withExtension: nil,
        subdirectory: "Fixtures/LVSCorpus"
    ) else {
        preconditionFailure("Packaged LVS corpus fixture '\(name)' is unavailable.")
    }
    return url
}

func externalOracleFixtureURL(_ name: String) -> URL {
    guard let url = Bundle.module.url(
        forResource: name,
        withExtension: nil,
        subdirectory: "Fixtures/ExternalOracle"
    ) else {
        preconditionFailure("Packaged LVS external-oracle fixture '\(name)' is unavailable.")
    }
    return url
}
}
