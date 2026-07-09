import Foundation
import LVSCLICore
import LVSCore
import Testing

extension LVSCLIOptionsTests {
  @Test func layoutNetlistDefaultsToNative() throws {
    let options = try LVSCLIOptions(arguments: [
      "--layout-netlist", "/tmp/layout.spice",
      "--schematic-netlist", "/tmp/schematic.spice",
      "--top-cell", "inv",
      "--out", "/tmp/lvs",
      "--tech", "/tmp/tech.json",
    ])

    #expect(options.makeRequest().backendSelection.backendID == "native")
  }

  @Test func layoutGDSWithTechDefaultsToNativeGDS() throws {
    let options = try LVSCLIOptions(arguments: [
      "--layout-gds", "/tmp/layout.oas",
      "--schematic-netlist", "/tmp/schematic.spice",
      "--top-cell", "inv",
      "--tech", "/tmp/tech.json",
      "--waivers", "/tmp/lvs-waivers.json",
      "--model-equivalence", "/tmp/lvs-model-equivalence.json",
      "--terminal-equivalence", "/tmp/lvs-terminal-equivalence.json",
      "--device-policy", "/tmp/lvs-device-policy.json",
      "--format", "oasis",
      "--out", "/tmp/lvs",
      "--json",
    ])

    let request = options.makeRequest()
    #expect(request.backendSelection.backendID == "native-gds")
    #expect(request.layoutFormat == .oasis)
    #expect(request.waiverURL?.path(percentEncoded: false) == "/tmp/lvs-waivers.json")
    #expect(
      request.modelEquivalenceURL?.path(percentEncoded: false) == "/tmp/lvs-model-equivalence.json")
    #expect(
      request.terminalEquivalenceURL?.path(percentEncoded: false)
        == "/tmp/lvs-terminal-equivalence.json")
    #expect(request.devicePolicyURL?.path(percentEncoded: false) == "/tmp/lvs-device-policy.json")
    #expect(options.emitJSON)
  }

  @Test func layoutGDSWithoutTechDefaultsToNetgen() throws {
    let options = try LVSCLIOptions(arguments: [
      "--layout-gds", "/tmp/layout.gds",
      "--schematic-netlist", "/tmp/schematic.spice",
      "--top-cell", "inv",
      "--out", "/tmp/lvs",
    ])

    #expect(options.makeRequest().backendSelection.backendID == "netgen")
  }

  @Test func invalidFormatThrows() throws {
    let error = try captureError {
      _ = try LVSCLIOptions(arguments: [
        "--layout-gds", "/tmp/layout.gds",
        "--schematic-netlist", "/tmp/schematic.spice",
        "--top-cell", "inv",
        "--out", "/tmp/lvs",
        "--format", "lef",
      ])
    }

    #expect(
      error
        == .invalidValue(
          argument: "--format",
          value: "lef",
          expected: "auto, gds, oasis, cif, or dxf"
        ))
  }

  @Test func invalidTimeoutThrows() throws {
    let error = try captureError {
      _ = try LVSCLIOptions(arguments: [
        "--layout-netlist", "/tmp/layout.spice",
        "--schematic-netlist", "/tmp/schematic.spice",
        "--top-cell", "inv",
        "--out", "/tmp/lvs",
        "--timeout", "abc",
      ])
    }

    #expect(
      error
        == .invalidValue(
          argument: "--timeout",
          value: "abc",
          expected: "positive finite seconds"
        ))
  }

  @Test func zeroTimeoutThrows() throws {
    let error = try captureError {
      _ = try LVSCLIOptions(arguments: [
        "--layout-netlist", "/tmp/layout.spice",
        "--schematic-netlist", "/tmp/schematic.spice",
        "--top-cell", "inv",
        "--out", "/tmp/lvs",
        "--timeout", "0",
      ])
    }

    #expect(
      error
        == .invalidValue(
          argument: "--timeout",
          value: "0",
          expected: "positive finite seconds"
        ))
  }

  @Test func layoutNetlistAndGDSCannotBeSpecifiedTogether() throws {
    let error = try captureError {
      _ = try LVSCLIOptions(arguments: [
        "--layout-netlist", "/tmp/layout.spice",
        "--layout-gds", "/tmp/layout.gds",
        "--schematic-netlist", "/tmp/schematic.spice",
        "--top-cell", "inv",
        "--out", "/tmp/lvs",
      ])
    }

    #expect(error == .conflictingArguments("--layout-netlist", "--layout-gds"))
  }

  @Test func runOptionsRejectOptionTokenAsPathValue() throws {
    let error = try captureError {
      _ = try LVSCLIOptions(arguments: [
        "--layout-netlist", "--schematic-netlist",
        "/tmp/schematic.spice",
        "--top-cell", "inv",
        "--out", "/tmp/lvs",
      ])
    }

    #expect(error == .missingValue("--layout-netlist"))
  }

  @Test func runOptionsRejectEmptyTopCell() throws {
    let error = try captureError {
      _ = try LVSCLIOptions(arguments: [
        "--layout-netlist", "/tmp/layout.spice",
        "--schematic-netlist", "/tmp/schematic.spice",
        "--top-cell", "",
        "--out", "/tmp/lvs",
      ])
    }

    #expect(
      error
        == .invalidValue(
          argument: "--top-cell",
          value: "",
          expected: "non-empty top cell"
        ))
  }

  @Test func nativeCLIWritesReportAndManifest() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let outputDirectory = root.appending(path: "artifacts")
    let layoutURL = root.appending(path: "layout.spice")
    let schematicURL = root.appending(path: "schematic.spice")
    let layoutNetlist = """
      .subckt inv in out vdd vss
      M1 out in vdd vdd pmos W=1u L=0.15u
      M2 out in vss vss sky130_fd_pr__nfet_01v8 W=1u L=0.15u
      .ends inv
      """
    let schematicNetlist = """
      .subckt inv in out vdd vss
      M1 out in vdd vdd pmos W=1u L=0.15u
      M2 out in vss vss nmos W=1u L=0.15u
      .ends inv
      """
    let modelEquivalenceURL = root.appending(path: "model-equivalence.json")
    let terminalEquivalenceURL = root.appending(path: "terminal-equivalence.json")
    let policy = """
      {
        "schemaVersion" : 1,
        "groups" : [
          {
            "canonicalModel" : "nmos",
            "aliases" : ["sky130_fd_pr__nfet_01v8"]
          }
        ]
      }
      """
    let terminalPolicy = """
      {
        "schemaVersion" : 1,
        "rules" : [
          {
            "equivalentPinGroups" : [[0, 1]],
            "kind" : "diode",
            "pinCount" : 2
          }
        ]
      }
      """
    try layoutNetlist.write(to: layoutURL, atomically: true, encoding: .utf8)
    try schematicNetlist.write(to: schematicURL, atomically: true, encoding: .utf8)
    try policy.write(to: modelEquivalenceURL, atomically: true, encoding: .utf8)
    try terminalPolicy.write(to: terminalEquivalenceURL, atomically: true, encoding: .utf8)

    let exitCode = await LVSCLI.run(arguments: [
      "--layout-netlist", layoutURL.path(percentEncoded: false),
      "--schematic-netlist", schematicURL.path(percentEncoded: false),
      "--top-cell", "inv",
      "--model-equivalence", modelEquivalenceURL.path(percentEncoded: false),
      "--terminal-equivalence", terminalEquivalenceURL.path(percentEncoded: false),
      "--out", outputDirectory.path(percentEncoded: false),
      "--json",
    ])

    #expect(exitCode == 0)
    let reportURL = try onlyArtifact(in: outputDirectory, prefix: "lvs-report-")
    let manifestURL = try onlyArtifact(in: outputDirectory, prefix: "lvs-artifact-manifest-")
    let report = try JSONDecoder().decode(
      LVSExecutionResult.self, from: Data(contentsOf: reportURL))
    let manifest = try JSONDecoder().decode(
      LVSArtifactManifest.self, from: Data(contentsOf: manifestURL))

    #expect(report.result.passed)
    #expect(canonicalPath(report.artifactManifestURL) == canonicalPath(manifestURL))
    #expect(manifest.backendID == "native")
    #expect(manifest.passed)
    #expect(manifest.inputs.contains { $0.id == "input-layout-netlist" && $0.sha256 != nil })
    #expect(manifest.inputs.contains { $0.id == "input-schematic-netlist" && $0.sha256 != nil })
    #expect(
      manifest.inputs.contains {
        $0.id == "input-model-equivalence" && $0.kind == .modelEquivalence && $0.sha256 != nil
      })
    #expect(
      manifest.inputs.contains {
        $0.id == "input-terminal-equivalence" && $0.kind == .terminalEquivalence && $0.sha256 != nil
      })
    #expect(manifest.outputs.contains { $0.id == "report" && $0.sha256 != nil })
  }

  @Test func nativeCLIConsumesDevicePolicySeed() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let outputDirectory = root.appending(path: "artifacts")
    let layoutURL = root.appending(path: "layout.spice")
    let schematicURL = root.appending(path: "schematic.spice")
    let devicePolicyURL = root.appending(path: "device-policy.json")
    try """
    .subckt diode_cell out vss
    D1 out vss sky130_fd_pr__diode_pw2nd_05v5 AREA=1
    .ends diode_cell
    """.write(to: layoutURL, atomically: true, encoding: .utf8)
    try """
    .subckt diode_cell out vss
    D1 vss out sky130_fd_pr__diode_pw2nd_05v5 AREA=1
    .ends diode_cell
    """.write(to: schematicURL, atomically: true, encoding: .utf8)
    try """
    {
      "schemaVersion" : 1,
      "kind" : "lvs-device-policy-seed",
      "generatedAt" : "2026-06-23T00:00:00Z",
      "sourcePath" : "sky130A_setup.tcl",
      "devices" : [
        {
          "deviceName" : "sky130_fd_pr__diode_pw2nd_05v5",
          "family" : "diode",
          "sourceLineNumber" : 10,
          "sourceLine" : "lappend devices sky130_fd_pr__diode_pw2nd_05v5"
        }
      ],
      "policyRules" : [
        {
          "kind" : "permute",
          "arguments" : ["-circuit1 sky130_fd_pr__diode_pw2nd_05v5", "1", "2"],
          "sourceLineNumber" : 12,
          "sourceLine" : "permute \\"-circuit1 sky130_fd_pr__diode_pw2nd_05v5\\" 1 2"
        }
      ]
    }
    """.write(to: devicePolicyURL, atomically: true, encoding: .utf8)

    let exitCode = await LVSCLI.run(arguments: [
      "--layout-netlist", layoutURL.path(percentEncoded: false),
      "--schematic-netlist", schematicURL.path(percentEncoded: false),
      "--top-cell", "diode_cell",
      "--device-policy", devicePolicyURL.path(percentEncoded: false),
      "--out", outputDirectory.path(percentEncoded: false),
      "--json",
    ])

    #expect(exitCode == 0)
    let reportURL = try onlyArtifact(in: outputDirectory, prefix: "lvs-report-")
    let manifestURL = try onlyArtifact(in: outputDirectory, prefix: "lvs-artifact-manifest-")
    let report = try JSONDecoder().decode(
      LVSExecutionResult.self, from: Data(contentsOf: reportURL))
    let manifest = try JSONDecoder().decode(
      LVSArtifactManifest.self, from: Data(contentsOf: manifestURL))
    #expect(report.result.passed, "\(report.result.diagnostics.map(\.message))")
    #expect(report.devicePolicyReport?.status == .complete)
    #expect(report.devicePolicyReport?.policyRuleCount == 1)
    #expect(report.devicePolicyReport?.appliedRuleCount == 1)
    #expect(report.devicePolicyReport?.appliedRuleCountsByKind["permute"] == 1)
    #expect(report.devicePolicyReport?.policyRuleCountsByKind["permute"] == 1)
    #expect(report.devicePolicyReport?.ignoredRuleCountsByReason.isEmpty == true)
    #expect(report.devicePolicyReport?.unobservedRuleCount == 0)
    #expect(report.devicePolicyReport?.unobservedRuleCountsByKind.isEmpty == true)
    #expect(manifest.devicePolicyReport?.appliedRuleCountsByKind["permute"] == 1)
    let devicePolicySummary = try #require(
      LVSCLIOutput(result: report).runSummary.devicePolicySummary)
    #expect(devicePolicySummary.policyRuleCount == 1)
    #expect(devicePolicySummary.appliedRuleCountsByKind["permute"] == 1)
    #expect(devicePolicySummary.unobservedRuleCount == 0)
    #expect(
      manifest.inputs.contains {
        $0.id == "input-device-policy" && $0.kind == .devicePolicy && $0.sha256 != nil
      })
  }

  @Test func nativeCLIAppliesWaiverFile() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let outputDirectory = root.appending(path: "artifacts")
    let layoutURL = root.appending(path: "layout.spice")
    let schematicURL = root.appending(path: "schematic.spice")
    let waiverURL = root.appending(path: "lvs-waivers.json")
    try """
    .subckt inv in out vdd vss
    M1 out in vdd vdd pmos
    .ends inv
    """.write(to: layoutURL, atomically: true, encoding: .utf8)
    try """
    .subckt inv in out vdd vss
    M1 out in vdd vdd pmos_mismatch
    .ends inv
    """.write(to: schematicURL, atomically: true, encoding: .utf8)
    try """
    {
      "schemaVersion" : 1,
      "waivers" : [
        {
          "category" : "modelMismatch",
          "id" : "waive-component-count",
          "reason" : "Known fixture mismatch",
          "ruleID" : "LVS_MODEL_MISMATCH"
        }
      ]
    }
    """.write(to: waiverURL, atomically: true, encoding: .utf8)

    let exitCode = await LVSCLI.run(arguments: [
      "--layout-netlist", layoutURL.path(percentEncoded: false),
      "--schematic-netlist", schematicURL.path(percentEncoded: false),
      "--top-cell", "inv",
      "--waivers", waiverURL.path(percentEncoded: false),
      "--out", outputDirectory.path(percentEncoded: false),
      "--json",
    ])

    #expect(exitCode == 0)
    let reportURL = try onlyArtifact(in: outputDirectory, prefix: "lvs-report-")
    let report = try JSONDecoder().decode(
      LVSExecutionResult.self, from: Data(contentsOf: reportURL))
    #expect(report.result.passed)
    #expect(report.result.diagnostics.allSatisfy { $0.waiverID == "waive-component-count" })
    #expect(report.waiverReport?.waivedDiagnosticCount == 1)
  }

  @Test func waiverReviewerBuildsHumanReviewReport() throws {
    let diagnostics = [
      LVSDiagnostic(
        severity: .error,
        message: "Component signature count differs",
        ruleID: "LVS_COMPONENT_MISMATCH",
        category: "componentCountMismatch",
        componentSignature: "mos|nmos|out,in,vss,vss|",
        suggestedFix: "Compare extracted and schematic devices.",
        rawLine: "signature=mos|nmos layout=1 schematic=0"
      ),
      LVSDiagnostic(
        severity: .error,
        message: "Parameter value differs",
        ruleID: "LVS_PARAMETER_MISMATCH",
        category: "parameterMismatch",
        componentSignature: "mos|pmos|out,in,vdd,vdd|",
        suggestedFix: "Check model parameters.",
        rawLine: "parameter=w"
      ),
    ]
    let waiverFile = LVSWaiverFile(waivers: [
      LVSWaiver(
        id: "waive-known-nmos",
        reason: "Known NMOS fixture mismatch",
        ruleID: "LVS_COMPONENT_MISMATCH",
        category: "componentCountMismatch",
        componentSignature: "mos|nmos|out,in,vss,vss|"
      ),
      LVSWaiver(
        id: "unused-waiver",
        reason: "Unused",
        ruleID: "LVS_MODEL_MISMATCH"
      ),
    ])

    let report = try LVSWaiverReviewer().review(
      diagnostics: diagnostics,
      waiverFile: waiverFile,
      sourceReportPath: "artifacts/lvs-report.json",
      waiverPolicyPath: "policy/lvs-waivers.json"
    )
    let reviewedDiagnostics = try LVSWaiverReviewer().reviewedDiagnostics(
      diagnostics: diagnostics,
      waiverFile: waiverFile
    )

    #expect(report.status == .blocked)
    #expect(report.diagnosticCount == 2)
    #expect(report.activeErrorCount == 2)
    #expect(report.matchedDiagnosticCount == 1)
    #expect(report.unmatchedDiagnosticCount == 1)
    #expect(report.matches.first?.waiverID == "waive-known-nmos")
    #expect(report.matches.first?.reviewState == "requires-human-approval")
    #expect(report.unmatchedDiagnostics.first?.ruleID == "LVS_PARAMETER_MISMATCH")
    #expect(report.unusedWaiverIDs == ["unused-waiver"])
    #expect(report.applicationReport.waivedDiagnosticCount == 1)
    #expect(report.suggestedActions.contains("inspect-unmatched-lvs-diagnostics"))
    #expect(reviewedDiagnostics[0].waiverID == "waive-known-nmos")
    #expect(reviewedDiagnostics[1].waiverID == nil)

    let data = try JSONEncoder().encode(report)
    let decoded = try JSONDecoder().decode(LVSWaiverReviewReport.self, from: data)
    #expect(decoded == report)
  }

  @Test func waiverReviewerRejectsUnscopedWaiver() throws {
    let diagnostics = [
      LVSDiagnostic(
        severity: .error,
        message: "Component signature count differs",
        ruleID: "LVS_COMPONENT_MISMATCH",
        category: "componentCountMismatch",
        componentSignature: "mos|nmos|out,in,vss,vss|",
        rawLine: "signature=mos|nmos layout=1 schematic=0"
      ),
    ]
    let waiverFile = LVSWaiverFile(waivers: [
      LVSWaiver(
        id: "blanket-waiver",
        reason: "This would waive every diagnostic without a scoped selector."
      ),
    ])

    #expect(throws: LVSError.unscopedWaiver(id: "blanket-waiver")) {
      _ = try LVSWaiverReviewer().review(
        diagnostics: diagnostics,
        waiverFile: waiverFile
      )
    }
    #expect(throws: LVSError.unscopedWaiver(id: "blanket-waiver")) {
      _ = try LVSWaiverReviewer().reviewedDiagnostics(
        diagnostics: diagnostics,
        waiverFile: waiverFile
      )
    }
  }

  @Test func waiverReviewerRejectsUnsupportedSchemaVersion() throws {
    let diagnostics = [
      LVSDiagnostic(
        severity: .error,
        message: "Component signature count differs",
        ruleID: "LVS_COMPONENT_MISMATCH",
        category: "componentCountMismatch",
        componentSignature: "mos|nmos|out,in,vss,vss|",
        rawLine: "signature=mos|nmos layout=1 schematic=0"
      ),
    ]
    let waiverFile = LVSWaiverFile(schemaVersion: 999, waivers: [
      LVSWaiver(
        id: "waive-known",
        reason: "Known scoped mismatch",
        ruleID: "LVS_COMPONENT_MISMATCH"
      ),
    ])

    do {
      _ = try LVSWaiverReviewer().review(
        diagnostics: diagnostics,
        waiverFile: waiverFile
      )
      Issue.record("Expected waiverApplicationFailed")
    } catch LVSError.waiverApplicationFailed(let message) {
      #expect(message.contains("lvs_waiver_schema_version_unsupported"))
      #expect(message.contains("999"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func waiverReviewerRejectsBlankIDAndReason() throws {
    let diagnostics = [
      LVSDiagnostic(
        severity: .error,
        message: "Component signature count differs",
        ruleID: "LVS_COMPONENT_MISMATCH",
        category: "componentCountMismatch",
        componentSignature: "mos|nmos|out,in,vss,vss|",
        rawLine: "signature=mos|nmos layout=1 schematic=0"
      ),
    ]
    let blankIDFile = LVSWaiverFile(waivers: [
      LVSWaiver(
        id: " ",
        reason: "Known scoped mismatch",
        ruleID: "LVS_COMPONENT_MISMATCH"
      ),
    ])
    let blankReasonFile = LVSWaiverFile(waivers: [
      LVSWaiver(
        id: "waive-known",
        reason: " ",
        ruleID: "LVS_COMPONENT_MISMATCH"
      ),
    ])

    #expect(throws: LVSError.invalidWaiver(id: " ", reason: "blank-id")) {
      _ = try LVSWaiverReviewer().review(
        diagnostics: diagnostics,
        waiverFile: blankIDFile
      )
    }
    #expect(throws: LVSError.invalidWaiver(id: "waive-known", reason: "blank-reason")) {
      _ = try LVSWaiverReviewer().reviewedDiagnostics(
        diagnostics: diagnostics,
        waiverFile: blankReasonFile
      )
    }
  }

  @Test func waiverReviewerReclassifiesMalformedActiveMarker() throws {
    let diagnostics = [
      LVSDiagnostic(
        severity: .error,
        message: "Component signature count differs",
        ruleID: "LVS_COMPONENT_MISMATCH",
        category: "componentCountMismatch",
        componentSignature: "mos|nmos|out,in,vss,vss|",
        waiverID: " ",
        waiverReason: nil,
        rawLine: "signature=mos|nmos layout=1 schematic=0"
      ),
    ]
    let waiverFile = LVSWaiverFile(waivers: [
      LVSWaiver(
        id: "waive-component-count",
        reason: "Reviewed component count mismatch.",
        ruleID: "LVS_COMPONENT_MISMATCH"
      ),
    ])

    let reviewed = try LVSWaiverReviewer().reviewedDiagnostics(
      diagnostics: diagnostics,
      waiverFile: waiverFile
    )

    #expect(reviewed.count == 1)
    #expect(reviewed[0].waiverID == "waive-component-count")
    #expect(reviewed[0].waiverReason == "Reviewed component count mismatch.")
    #expect(reviewed[0].isWaived)
  }

  @Test func waiverReviewCLIWritesReviewReport() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let reportURL = root.appending(path: "lvs-report.json")
    let waiverURL = root.appending(path: "lvs-waivers.json")
    let reviewURL = root.appending(path: "review/lvs-waiver-review.json")
    let result = LVSExecutionResult(
      request: LVSRequest(
        layoutNetlistURL: URL(filePath: "/tmp/layout.spice"),
        schematicNetlistURL: URL(filePath: "/tmp/schematic.spice"),
        topCell: "inv"
      ),
      result: LVSResult(
        backendID: "native",
        toolName: "NativeLVS",
        success: true,
        completed: true,
        logPath: "",
        diagnostics: [
          LVSDiagnostic(
            severity: .error,
            message: "Component signature count differs",
            ruleID: "LVS_COMPONENT_MISMATCH",
            category: "componentCountMismatch",
            componentSignature: "mos|nmos|out,in,vss,vss|",
            rawLine: "signature=mos|nmos layout=1 schematic=0"
          )
        ]
      )
    )
    let waiverFile = LVSWaiverFile(waivers: [
      LVSWaiver(
        id: "waive-known-nmos",
        reason: "Known NMOS fixture mismatch",
        ruleID: "LVS_COMPONENT_MISMATCH",
        category: "componentCountMismatch",
        componentSignature: "mos|nmos|out,in,vss,vss|"
      )
    ])
    try writeJSON(result, to: reportURL)
    try writeJSON(waiverFile, to: waiverURL)

    let exitCode = await LVSCLI.run(arguments: [
      "--review-waivers-from-report", reportURL.path(percentEncoded: false),
      "--waivers", waiverURL.path(percentEncoded: false),
      "--report-out", reviewURL.path(percentEncoded: false),
      "--json",
    ])

    #expect(exitCode == 0)
    let report = try JSONDecoder().decode(
      LVSWaiverReviewReport.self,
      from: Data(contentsOf: reviewURL)
    )
    #expect(report.status == .reviewRequired)
    #expect(report.sourceReportPath == reportURL.path(percentEncoded: false))
    #expect(report.waiverPolicyPath == waiverURL.path(percentEncoded: false))
    #expect(report.matchedDiagnosticCount == 1)
    #expect(report.unmatchedDiagnosticCount == 0)
    #expect(report.suggestedActions.contains("human-review-waiver-candidates"))
  }

}
