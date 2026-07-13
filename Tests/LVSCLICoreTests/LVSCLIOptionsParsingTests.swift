import Foundation
import LVSCLICore
import LVSCore
import Testing

extension LVSCLIOptionsTests {
  @Test func actionDomainOptionsParseJSONFlag() throws {
    let options = try LVSActionDomainCLIOptions(arguments: ["--action-domain", "--json"])

    #expect(options.emitJSON)
  }

  @Test func waiverReviewOptionsParseInputsAndOutput() throws {
    let options = try LVSWaiverReviewCLIOptions(arguments: [
      "--review-waivers-from-report", "/tmp/lvs-report.json",
      "--waivers", "/tmp/lvs-waivers.json",
      "--report-out", "/tmp/lvs-waiver-review.json",
      "--json",
    ])

    #expect(options.reportURL.path(percentEncoded: false) == "/tmp/lvs-report.json")
    #expect(options.waiverURL.path(percentEncoded: false) == "/tmp/lvs-waivers.json")
    #expect(options.outputURL?.path(percentEncoded: false) == "/tmp/lvs-waiver-review.json")
    #expect(options.emitJSON)
  }

  @Test func capabilityOptionsParseJSONFlag() throws {
    let options = try LVSCapabilityCLIOptions(arguments: ["--capabilities", "--json"])

    #expect(options.emitJSON)
  }

  @Test func foundryDeckSemanticOptionsParsePDKRootAndRequirePassed() throws {
    let options = try LVSFoundryDeckSemanticCLIOptions(arguments: [
      "--foundry-deck-semantics",
      "--pdk-root", "/tmp/pdks",
      "--require-passed",
      "--json",
    ])

    #expect(options.pdkRoot == "/tmp/pdks")
    #expect(options.requirePassed)
    #expect(options.emitJSON)
    #expect(options.environment(overriding: [:])["PDK_ROOT"] == "/tmp/pdks")
  }

  @Test func foundryDeviceImportOptionsParseOutputsAndCompletionGate() throws {
    let options = try LVSFoundryDeviceImportCLIOptions(arguments: [
      "--import-foundry-netgen-devices",
      "--pdk-root", "/tmp/pdks",
      "--policy-out", "/tmp/lvs-device-policy.json",
      "--report-out", "/tmp/lvs-device-import.json",
      "--require-complete",
      "--json",
    ])

    #expect(options.pdkRoot == "/tmp/pdks")
    #expect(options.policyURL.path(percentEncoded: false) == "/tmp/lvs-device-policy.json")
    #expect(options.reportURL?.path(percentEncoded: false) == "/tmp/lvs-device-import.json")
    #expect(options.requireComplete)
    #expect(options.emitJSON)
    #expect(options.environment(overriding: [:])["PDK_ROOT"] == "/tmp/pdks")
  }

  @Test func foundryDeviceImportOptionsRejectRemovedSky130Alias() throws {
    #expect(throws: LVSCLIError.self) {
      try LVSFoundryDeviceImportCLIOptions(arguments: [
        "--import-sky130-netgen-devices",
        "--policy-out", "/tmp/lvs-device-policy.json",
      ])
    }
  }

  @Test func netgenDeviceImportOptionsParseExplicitSetupAndOutputs() throws {
    let options = try LVSNetgenDeviceImportCLIOptions(arguments: [
      "--import-netgen-devices",
      "--netgen-setup", "/tmp/pdk/libs.tech/netgen/process_setup.tcl",
      "--policy-out", "/tmp/lvs-device-policy.json",
      "--report-out", "/tmp/lvs-device-import.json",
      "--require-complete",
      "--json",
    ])

    #expect(
      options.setupURL.path(percentEncoded: false) == "/tmp/pdk/libs.tech/netgen/process_setup.tcl")
    #expect(options.policyURL.path(percentEncoded: false) == "/tmp/lvs-device-policy.json")
    #expect(options.reportURL?.path(percentEncoded: false) == "/tmp/lvs-device-import.json")
    #expect(options.requireComplete)
    #expect(options.emitJSON)
  }

  @Test func netgenDeviceImportAuditOptionsParseInputsAndPolicy() throws {
    let options = try LVSNetgenDeviceImportAuditCLIOptions(arguments: [
      "--audit-netgen-device-import",
      "--policy-seed", "/tmp/lvs-device-policy.json",
      "--import-report", "/tmp/lvs-device-import.json",
      "--audit-policy", "/tmp/lvs-device-import-audit-policy.json",
      "--audit-out", "/tmp/lvs-device-import-audit.json",
      "--require-satisfied",
      "--json",
    ])

    #expect(options.seedURL.path(percentEncoded: false) == "/tmp/lvs-device-policy.json")
    #expect(options.reportURL.path(percentEncoded: false) == "/tmp/lvs-device-import.json")
    #expect(
      options.policyURL?.path(percentEncoded: false) == "/tmp/lvs-device-import-audit-policy.json")
    #expect(options.outputURL?.path(percentEncoded: false) == "/tmp/lvs-device-import-audit.json")
    #expect(options.requireSatisfied)
    #expect(options.emitJSON)
  }

  @Test func foundryDeviceImportOptionsRejectOptionTokenAsPolicyOutput() throws {
    let error = try captureError {
      _ = try LVSFoundryDeviceImportCLIOptions(arguments: [
        "--import-foundry-netgen-devices",
        "--policy-out", "--report-out",
        "/tmp/lvs-device-import.json",
      ])
    }

    #expect(error == .missingValue("--policy-out"))
  }

  @Test func netgenDeviceImportAuditOptionsRejectOptionTokenAsPolicySeed() throws {
    let error = try captureError {
      _ = try LVSNetgenDeviceImportAuditCLIOptions(arguments: [
        "--audit-netgen-device-import",
        "--policy-seed", "--import-report",
        "/tmp/lvs-device-import.json",
      ])
    }

    #expect(error == .missingValue("--policy-seed"))
  }

  @Test func devicePolicySeedSummaryDoesNotInlinePolicyRules() throws {
    let seed = NetgenLVSDevicePolicySeed(
      generatedAt: "2026-06-23T00:00:00Z",
      sourcePath: "sky130A_setup.tcl",
      devices: [
        NetgenLVSDeviceDescriptor(
          deviceName: "sky130_fd_pr__diode_pw2nd_05v5",
          family: "diode",
          sourceLineNumber: 2,
          sourceLine: "lappend devices sky130_fd_pr__diode_pw2nd_05v5"
        )
      ],
      policyRules: [
        NetgenLVSPolicyRule(
          kind: "permute",
          arguments: ["-circuit1 sky130_fd_pr__diode_pw2nd_05v5", "1", "2"],
          sourceLineNumber: 4,
          sourceLine: "permute \"-circuit1 sky130_fd_pr__diode_pw2nd_05v5\" 1 2"
        ),
        NetgenLVSPolicyRule(
          kind: "property",
          arguments: ["-circuit1 $cell", "parallel", "enable"],
          sourceLineNumber: 12,
          sourceLine: "property \"-circuit1 $cell\" parallel enable"
        ),
      ]
    )
    let report = NetgenLVSDeviceDeckImportReport(
      generatedAt: "2026-06-23T00:00:00Z",
      status: .complete,
      sourcePath: "sky130A_setup.tcl",
      supportedFamilies: ["diode"],
      importedDeviceCount: 1,
      importedPolicyRuleCount: 2,
      skippedLineCount: 0,
      deviceFamilyCounts: ["diode": 1],
      policyRuleCounts: ["permute": 1, "property": 1],
      diagnostics: []
    )

    let summary = LVSDevicePolicySeedSummary(seed: seed, report: report)

    #expect(summary.deviceCount == 1)
    #expect(summary.policyRuleCount == 2)
    #expect(summary.unresolvedPolicyRuleCount == 1)
    let encoded = try JSONEncoder().encode(summary)
    let json = try #require(String(data: encoded, encoding: .utf8))
    #expect(!json.contains("policyRules"))
    #expect(json.contains("unresolvedPolicyRuleCount"))
  }

  @Test func capabilitySnapshotDescribesStandaloneEngineSurface() throws {
    let snapshot = LVSCapabilitySnapshotProvider().snapshot()

    #expect(snapshot.schemaVersion == 3)
    #expect(snapshot.engineID == "lvsengine")
    #expect(snapshot.ownerPackage == "LVSEngine")
    #expect(snapshot.qualificationBinding.evidenceArtifactID == "lvs-tool-evidence-export")
    #expect(snapshot.qualificationBinding.requiredIdentityFields.contains("processProfileID"))
    #expect(snapshot.qualificationBinding.requiredIdentityFields.contains("extractionDeckDigest"))
    #expect(snapshot.actionDomain.domainID == "lvs-signoff")
    #expect(
      snapshot.corpus.committedSpecPath
        == "Tests/LVSCLICoreTests/Fixtures/ExternalOracle/lvs-production-corpus.json")
    #expect(snapshot.corpus.reportArtifact == "lvs-corpus-report")
    #expect(snapshot.corpus.requiredObservedAssertions.contains("oracleAgreement:true"))
    #expect(snapshot.corpus.requiredObservedAssertions.contains("oracleIndependence:ready"))
    #expect(snapshot.corpus.requiredObservedAssertions.contains("determinism:stable"))
    #expect(snapshot.corpus.requiredObservedAssertions.contains("cancellation:cancelled"))
    #expect(snapshot.corpus.requiredObservedAssertions.contains("extractionArtifact"))
    #expect(
      snapshot.corpus.requiredObservedAssertions.contains(
        "extractionProductionEligibility:eligible"
      )
    )

    let nativeGDS = try #require(snapshot.backends.first { $0.backendID == "native-gds" })
    #expect(nativeGDS.executionMode == "in-process")
    #expect(!nativeGDS.requiresExternalTool)
    #expect(nativeGDS.inputFormats.contains("gds"))
    #expect(nativeGDS.inputFormats.contains("oasis"))
    #expect(nativeGDS.inputFormats.contains("cif"))
    #expect(nativeGDS.inputFormats.contains("dxf"))
    #expect(nativeGDS.requiredInputs.contains("technology-json"))
    #expect(nativeGDS.producedArtifacts.contains("extracted-layout-netlist"))
    #expect(nativeGDS.limitations.contains { $0.contains("sky130.open-pdk.digital-mos.signoff") })

    let netgen = try #require(snapshot.backends.first { $0.backendID == "netgen" })
    #expect(netgen.requiresExternalTool)

    #expect(snapshot.artifacts.contains { $0.artifactID == "lvs-summary" })
    #expect(snapshot.artifacts.contains { $0.artifactID == "lvs-repair-hints" })
    #expect(snapshot.artifacts.contains { $0.artifactID == "extracted-layout-netlist" })
    #expect(snapshot.artifacts.contains { $0.artifactID == "signoff-foundry-deck-semantics" })
    #expect(snapshot.artifacts.contains { $0.artifactID == "lvs-device-policy-seed" })
    #expect(snapshot.artifacts.contains { $0.artifactID == "lvs-foundry-device-import-report" })
    #expect(snapshot.artifacts.contains { $0.artifactID == "lvs-device-import-audit" })
    #expect(snapshot.artifacts.contains { $0.artifactID == "lvs-device-policy-application-report" })
    #expect(snapshot.artifacts.contains { $0.artifactID == "lvs-corpus-coverage-audit" })
    #expect(snapshot.artifacts.contains { $0.artifactID == "lvs-corpus-report" })
    #expect(snapshot.artifacts.contains { $0.artifactID == "lvs-tool-evidence-export" })
    #expect(snapshot.artifacts.contains { $0.artifactID == "model-equivalence-policy" })
    #expect(snapshot.artifacts.contains { $0.artifactID == "terminal-equivalence-policy" })
    #expect(snapshot.artifacts.contains { $0.artifactID == "policy-artifact" })
    #expect(snapshot.artifacts.contains { $0.artifactID == "design-diff" })
    #expect(snapshot.artifacts.contains { $0.artifactID == "planning-problem" })
    #expect(snapshot.artifacts.first {
      $0.artifactID == "model-equivalence-policy"
    }?.producer == "Xcircuite.CandidatePlanExecutor")
    #expect(snapshot.artifacts.first {
      $0.artifactID == "planning-problem"
    }?.producer == "Xcircuite.DiagnosticPlanningProblemBuilder")
    #expect(snapshot.agentContracts.contains { $0.contains("typed request/result") })
    #expect(snapshot.agentContracts.contains { $0.contains("repair-hint") })
    #expect(snapshot.agentContracts.contains { $0.contains("--audit-corpus-coverage") })
    #expect(snapshot.agentContracts.contains { $0.contains("--foundry-deck-semantics") })
    #expect(snapshot.agentContracts.contains { $0.contains("--import-netgen-devices") })
    #expect(snapshot.agentContracts.contains { $0.contains("--import-foundry-netgen-devices") })
    #expect(snapshot.agentContracts.contains { $0.contains("--audit-netgen-device-import") })
    #expect(!snapshot.agentContracts.contains { $0.contains("--import-sky130-netgen-devices") })
    #expect(snapshot.agentContracts.contains { $0.contains("seedSummary") })
    #expect(snapshot.agentContracts.contains { $0.contains("lvsengine --device-policy") })
    let data = try JSONEncoder().encode(snapshot)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["status"] == nil)
    #expect(object["preferredBackendID"] == nil)
    #expect(object["openMilestones"] == nil)
    let encodedBackends = try #require(object["backends"] as? [[String: Any]])
    #expect(encodedBackends.allSatisfy { $0["qualificationTags"] == nil })
    #expect(encodedBackends.allSatisfy { $0["maturity"] == nil })
    let decoded = try JSONDecoder().decode(LVSCapabilitySnapshot.self, from: data)
    #expect(decoded == snapshot)

    var unsupportedV1Payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    unsupportedV1Payload["schemaVersion"] = 1
    let unsupportedV1Data = try JSONSerialization.data(withJSONObject: unsupportedV1Payload)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(LVSCapabilitySnapshot.self, from: unsupportedV1Data)
    }
  }

  @Test func capabilitySnapshotCoversProducedArtifactContracts() throws {
    let snapshot = LVSCapabilitySnapshotProvider().snapshot()
    let artifactIDs = Set(snapshot.artifacts.map(\.artifactID))
    #expect(snapshot.artifacts.count == artifactIDs.count)

    for artifact in snapshot.artifacts {
      #expect(!artifact.artifactID.isEmpty)
      #expect(!artifact.format.isEmpty, "\(artifact.artifactID) must declare a format")
      #expect(!artifact.producer.isEmpty, "\(artifact.artifactID) must declare a producer")
      #expect(!artifact.consumer.isEmpty, "\(artifact.artifactID) must declare consumers")
    }

    for backend in snapshot.backends {
      for artifactID in backend.producedArtifacts {
        #expect(
          artifactIDs.contains(artifactID),
          "\(backend.backendID) produced artifact \(artifactID) must have an artifact contract"
        )
      }
    }

    #expect(
      artifactIDs.contains(snapshot.corpus.reportArtifact),
      "Corpus report artifact must have an artifact contract"
    )

    for operation in snapshot.actionDomain.operations {
      for artifactID in operation.producedArtifacts {
        #expect(
          artifactIDs.contains(artifactID),
          "\(operation.operationID) produced artifact \(artifactID) must have an artifact contract"
        )
      }
    }
  }

}
