import Foundation
import Testing
import LVSCore
import LVSCLICore

extension LVSCLIOptionsTests {
@Test func repairHintsOptionsParseReportAndJSONFlag() throws {
    let options = try LVSRepairHintsCLIOptions(arguments: [
        "--repair-hints-from-report", "/tmp/lvs-report.json",
        "--json",
    ])

    #expect(options.reportURL.path(percentEncoded: false) == "/tmp/lvs-report.json")
    #expect(options.emitJSON)
}

@Test func foundryDeckSemanticsCLIPassesWithNetgenDeckOnly() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    try writeNetgenLVSDeck(root: root)

    let exitCode = await LVSCLI.run(arguments: [
        "--foundry-deck-semantics",
        "--pdk-root", root.path(percentEncoded: false),
        "--require-passed",
        "--json",
    ])

    #expect(exitCode == 0)
}

@Test func foundryDeckSemanticsCLIBlocksMissingNetgenDeckWhenRequired() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }

    let exitCode = await LVSCLI.run(arguments: [
        "--foundry-deck-semantics",
        "--pdk-root", root.path(percentEncoded: false),
        "--require-passed",
        "--json",
    ])

    #expect(exitCode == 2)
}

@Test func foundryDeviceImportCLIWritesPolicySeedAndReport() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    try writeNetgenLVSDeck(root: root)
    let outputDirectory = root.appending(path: "outputs")
    let policyURL = outputDirectory.appending(path: "lvs-device-policy.json")
    let reportURL = outputDirectory.appending(path: "lvs-device-import.json")

    let exitCode = await LVSCLI.run(arguments: [
        "--import-foundry-netgen-devices",
        "--pdk-root", root.path(percentEncoded: false),
        "--policy-out", policyURL.path(percentEncoded: false),
        "--report-out", reportURL.path(percentEncoded: false),
        "--require-complete",
        "--json",
    ])

    #expect(exitCode == 0)
    let seed = try JSONDecoder().decode(
        NetgenLVSDevicePolicySeed.self,
        from: try Data(contentsOf: policyURL)
    )
    let report = try JSONDecoder().decode(
        NetgenLVSDeviceDeckImportReport.self,
        from: try Data(contentsOf: reportURL)
    )
    #expect(seed.kind == "lvs-device-policy-seed")
    #expect(seed.devices.count == 6)
    #expect(seed.policyRules.count == 18)
    #expect(seed.policyRules.allSatisfy {
        !$0.arguments.joined(separator: " ").contains("$dev")
    })
    #expect(report.status == .complete)
    #expect(report.importedDeviceCount == 6)
    #expect(report.deviceFamilyCounts["mos"] == 1)
    #expect(report.deviceFamilyCounts["inductor"] == 1)
    #expect(report.policyRuleCounts["equate-pins"] == 6)
}

@Test func netgenDeviceImportCLIWritesPolicySeedAndReportFromExplicitSetup() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    try writeNetgenLVSDeck(root: root)
    let setupURL = root.appending(path: "sky130A/libs.tech/netgen/sky130A_setup.tcl")
    let outputDirectory = root.appending(path: "outputs")
    let policyURL = outputDirectory.appending(path: "generic-lvs-device-policy.json")
    let reportURL = outputDirectory.appending(path: "generic-lvs-device-import.json")

    let exitCode = await LVSCLI.run(arguments: [
        "--import-netgen-devices",
        "--netgen-setup", setupURL.path(percentEncoded: false),
        "--policy-out", policyURL.path(percentEncoded: false),
        "--report-out", reportURL.path(percentEncoded: false),
        "--require-complete",
        "--json",
    ])

    #expect(exitCode == 0)
    let seed = try JSONDecoder().decode(
        NetgenLVSDevicePolicySeed.self,
        from: try Data(contentsOf: policyURL)
    )
    let report = try JSONDecoder().decode(
        NetgenLVSDeviceDeckImportReport.self,
        from: try Data(contentsOf: reportURL)
    )
    #expect(seed.sourcePath == setupURL.path(percentEncoded: false))
    #expect(seed.devices.count == 6)
    #expect(seed.policyRules.count == 18)
    #expect(report.status == .complete)
    #expect(report.importedDeviceCount == 6)
    #expect(report.policyRuleCounts["equate-pins"] == 6)
}

@Test func netgenDeviceImportAuditCLIWritesSatisfiedAudit() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    try writeNetgenLVSDeck(root: root)
    let setupURL = root.appending(path: "sky130A/libs.tech/netgen/sky130A_setup.tcl")
    let outputDirectory = root.appending(path: "outputs")
    let policyURL = outputDirectory.appending(path: "generic-lvs-device-policy.json")
    let reportURL = outputDirectory.appending(path: "generic-lvs-device-import.json")
    let auditURL = outputDirectory.appending(path: "generic-lvs-device-import-audit.json")

    let importExitCode = await LVSCLI.run(arguments: [
        "--import-netgen-devices",
        "--netgen-setup", setupURL.path(percentEncoded: false),
        "--policy-out", policyURL.path(percentEncoded: false),
        "--report-out", reportURL.path(percentEncoded: false),
        "--require-complete",
        "--json",
    ])
    #expect(importExitCode == 0)

    let auditExitCode = await LVSCLI.run(arguments: [
        "--audit-netgen-device-import",
        "--policy-seed", policyURL.path(percentEncoded: false),
        "--import-report", reportURL.path(percentEncoded: false),
        "--audit-out", auditURL.path(percentEncoded: false),
        "--require-satisfied",
        "--json",
    ])

    #expect(auditExitCode == 0)
    let audit = try JSONDecoder().decode(
        NetgenLVSDeviceDeckImportAudit.self,
        from: try Data(contentsOf: auditURL)
    )
    #expect(audit.status == .satisfied)
    #expect(audit.policyID == "lvs-device-seed-readiness-v1")
    #expect(audit.summary.importedDeviceCount == 6)
    #expect(audit.summary.unresolvedPolicyRuleCount == 0)
    #expect(audit.requirements.contains { $0.requirementID == "seed-report-consistency" })
}

@Test func foundryDeviceImportCLIBlocksMissingNetgenDeck() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let outputDirectory = root.appending(path: "outputs")
    let policyURL = outputDirectory.appending(path: "lvs-device-policy.json")
    let reportURL = outputDirectory.appending(path: "lvs-device-import.json")

    let exitCode = await LVSCLI.run(arguments: [
        "--import-foundry-netgen-devices",
        "--pdk-root", root.path(percentEncoded: false),
        "--policy-out", policyURL.path(percentEncoded: false),
        "--report-out", reportURL.path(percentEncoded: false),
        "--json",
    ])

    #expect(exitCode == 2)
    let report = try JSONDecoder().decode(
        NetgenLVSDeviceDeckImportReport.self,
        from: try Data(contentsOf: reportURL)
    )
    #expect(report.status == .blocked)
    #expect(report.importedDeviceCount == 0)
}

}
