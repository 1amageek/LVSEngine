import Foundation
import Testing
import LVSCore
import LVSCLICore

extension LVSCLIOptionsTests {
@Test func capabilitiesCLIReturnsSuccess() async throws {
    let exitCode = await LVSCLI.run(arguments: ["--capabilities", "--json"])

    #expect(exitCode == 0)
}

@Test func actionDomainExporterDescribesLVSPlanningOperations() throws {
    let snapshot = LVSActionDomainExporter().snapshot()

    #expect(snapshot.schemaVersion == 1)
    #expect(snapshot.domainID == "lvs-signoff")
    #expect(snapshot.ownerPackages == ["LVSEngine"])

    let operationIDs = Set(snapshot.operations.map(\.operationID))
    #expect(operationIDs.contains("lvs.run-native"))
    #expect(operationIDs.contains("lvs.inspect-foundry-deck-semantics"))
    #expect(operationIDs.contains("lvs.import-foundry-device-seed"))
    #expect(operationIDs.contains("lvs.audit-device-import"))
    #expect(operationIDs.contains("lvs.qualify-corpus"))
    #expect(operationIDs.contains("lvs.audit-corpus-coverage"))
    #expect(operationIDs.contains("lvs.export-tool-evidence"))
    #expect(operationIDs.contains("lvs.export-evidence-packet"))
    #expect(operationIDs.contains("lvs.export-repair-hints"))
    #expect(operationIDs.contains("lvs.policy-repair"))
    #expect(operationIDs.contains("lvs.waiver-review"))
    #expect(!operationIDs.contains("lvs.diagnostic-to-repair-objective"))

    let repairHints = try #require(snapshot.operations.first { $0.operationID == "lvs.export-repair-hints" })
    #expect(repairHints.maturity == "implemented")
    #expect(repairHints.inputRefs.contains("lvs-report"))
    #expect(repairHints.producedArtifacts.contains("lvs-repair-hints"))
    #expect(repairHints.verificationGates.contains("native-lvs"))

    let policy = try #require(snapshot.operations.first { $0.operationID == "lvs.policy-repair" })
    #expect(policy.maturity == "implemented")
    #expect(policy.producedArtifacts.contains("model-equivalence-policy"))
    #expect(policy.producedArtifacts.contains("terminal-equivalence-policy"))
    #expect(policy.producedArtifacts.contains("policy-artifact"))
    #expect(policy.verificationGates.contains("approval-gate"))

    let waiver = try #require(snapshot.operations.first { $0.operationID == "lvs.waiver-review" })
    #expect(waiver.maturity == "implemented")
    #expect(waiver.producedArtifacts.contains("lvs-waiver-report"))
    #expect(waiver.producedArtifacts.contains("lvs-summary"))
    #expect(waiver.verificationGates.contains("human-review"))

    let run = try #require(snapshot.operations.first { $0.operationID == "lvs.run-native" })
    #expect(run.maturity == "implemented")
    #expect(run.producedArtifacts.contains("lvs-summary"))
    #expect(run.verificationGates.contains("lvs-artifacts"))

    let audit = try #require(snapshot.operations.first { $0.operationID == "lvs.audit-corpus-coverage" })
    #expect(audit.maturity == "implemented")
    #expect(audit.inputRefs.contains("lvs-corpus-report"))
    #expect(audit.producedArtifacts.contains("lvs-corpus-coverage-audit"))
    #expect(audit.verificationGates.contains("coverage-requirements"))

    let deckSemantics = try #require(snapshot.operations.first {
        $0.operationID == "lvs.inspect-foundry-deck-semantics"
    })
    #expect(deckSemantics.producedArtifacts == ["signoff-foundry-deck-semantics"])
    #expect(deckSemantics.preconditions == ["netgen-lvs-deck-readable"])
    #expect(deckSemantics.verificationGates.contains("semantic-coverage"))

    let importSeed = try #require(snapshot.operations.first {
        $0.operationID == "lvs.import-foundry-device-seed"
    })
    #expect(importSeed.maturity == "implemented")
    #expect(importSeed.producedArtifacts.contains("lvs-device-policy-seed"))
    #expect(importSeed.producedArtifacts.contains("lvs-foundry-device-import-report"))
    #expect(importSeed.verificationGates.contains("device-import-audit"))

    let importAudit = try #require(snapshot.operations.first {
        $0.operationID == "lvs.audit-device-import"
    })
    #expect(importAudit.maturity == "implemented")
    #expect(importAudit.inputRefs.contains("lvs-device-policy-seed"))
    #expect(importAudit.producedArtifacts.contains("lvs-device-import-audit"))
    #expect(importSeed.verificationGates.contains("import-coverage"))
}

@Test func actionDomainSnapshotPinsEveryLVSOperationContract() throws {
    let snapshot = LVSActionDomainExporter().snapshot()
    let operationIDs = snapshot.operations.map(\.operationID)

    #expect(operationIDs.count == Set(operationIDs).count)
    #expect(Set(operationIDs) == Set([
        "lvs.run-native",
        "lvs.inspect-foundry-deck-semantics",
        "lvs.import-foundry-device-seed",
        "lvs.audit-device-import",
        "lvs.qualify-corpus",
        "lvs.audit-corpus-coverage",
        "lvs.export-tool-evidence",
        "lvs.export-evidence-packet",
        "lvs.export-repair-hints",
        "lvs.policy-repair",
        "lvs.waiver-review",
    ]))

    for operation in snapshot.operations {
        #expect(!operation.maturity.isEmpty, "\(operation.operationID) must expose maturity")
        #expect(["implemented", "partial", "planned"].contains(operation.maturity))
        #expect(!operation.inputRefs.isEmpty, "\(operation.operationID) must expose input references")
        #expect(!operation.preconditions.isEmpty, "\(operation.operationID) must expose preconditions")
        #expect(!operation.effects.isEmpty, "\(operation.operationID) must expose effects")
        #expect(!operation.producedArtifacts.isEmpty, "\(operation.operationID) must expose produced artifacts")
        #expect(!operation.verificationGates.isEmpty, "\(operation.operationID) must expose verification gates")
        #expect(operation.inputRefs.count == Set(operation.inputRefs).count)
        #expect(operation.preconditions.count == Set(operation.preconditions).count)
        #expect(operation.effects.count == Set(operation.effects).count)
        #expect(operation.producedArtifacts.count == Set(operation.producedArtifacts).count)
        #expect(operation.verificationGates.count == Set(operation.verificationGates).count)
    }

    let implemented = snapshot.operations.filter { $0.maturity == "implemented" }
    #expect(implemented.count == 11)
    let partial = snapshot.operations.filter { $0.maturity == "partial" }.map(\.operationID)
    #expect(partial.isEmpty)
    let planned = snapshot.operations.filter { $0.maturity == "planned" }.map(\.operationID)
    #expect(planned.isEmpty)
}

}
