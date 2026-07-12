import Foundation
import LVSEngine
import SignoffToolSupport

struct LVSCLICommandExecutor: Sendable {
  let arguments: [String]

  func run() async throws -> Int32 {
    switch LVSCLICommandMode(arguments: arguments) {
    case .listBackends:
      return listBackends()
    case .foundryDeckSemantics:
      return try foundryDeckSemantics()
    case .importNetgenDevices:
      return try importNetgenDevices()
    case .auditNetgenDeviceImport:
      return try auditNetgenDeviceImport()
    case .importFoundryNetgenDevices:
      return try importFoundryNetgenDevices()
    case .capabilities:
      return try capabilities()
    case .actionDomain:
      return try actionDomain()
    case .evidencePacketFromCorpusReport:
      return try evidencePacketFromCorpusReport()
    case .auditCorpusCoverage:
      return try auditCorpusCoverage()
    case .evidenceFromCorpusReport:
      return try evidenceFromCorpusReport()
    case .repairHintsFromReport:
      return try repairHintsFromReport()
    case .reviewWaiversFromReport:
      return try reviewWaiversFromReport()
    case .qualifyCorpusReport:
      return try qualifyCorpusReport()
    case .corpus:
      return try await corpus()
    case .runLVS:
      return try await runLVS()
    }
  }

  private func listBackends() -> Int32 {
    for backendID in LVSCLI.availableBackends {
      print(backendID)
    }
    return 0
  }

  private func foundryDeckSemantics() throws -> Int32 {
    let options = try LVSFoundryDeckSemanticCLIOptions(arguments: arguments)
    let signoffProfile = try LVSCLI.defaultSignoffPDKProfile()
    let report = SignoffDeckSemanticInventory.inspect(
      profile: signoffProfile,
      requirements: LVSCLI.lvsNetgenDeckRequirements(from: signoffProfile),
      environment: options.environment(overriding: ProcessInfo.processInfo.environment)
    )
    if options.emitJSON {
      try LVSCLI.emitJSON(report)
    } else {
      print("status=\(report.status.rawValue)")
      print("kind=\(report.kind)")
      if let pdkRoot = report.pdkRoot {
        print("pdk_root=\(pdkRoot)")
      }
      for result in report.coverageTagResults {
        print("\(result.tag)=\(result.status.rawValue) evidence=\(result.evidenceCount)")
      }
    }
    return options.requirePassed && report.status != .passed ? 2 : 0
  }

  private func importNetgenDevices() throws -> Int32 {
    let options = try LVSNetgenDeviceImportCLIOptions(arguments: arguments)
    let importResult = try NetgenLVSDeviceDeckImporter.importDeviceDeck(from: options.setupURL)
    try LVSCLI.writeJSON(importResult.seed, to: options.policyURL)
    if let reportURL = options.reportURL {
      try LVSCLI.writeJSON(importResult.report, to: reportURL)
    }
    let output = LVSNetgenDeviceImportCLIOutput(
      status: importResult.report.status,
      policyPath: options.policyURL.path(percentEncoded: false),
      reportPath: options.reportURL?.path(percentEncoded: false),
      seed: importResult.seed,
      importReport: importResult.report
    )
    try LVSCLI.emitNetgenDeviceImportOutput(output, emitJSON: options.emitJSON)
    if importResult.report.status == .blocked {
      return 2
    }
    return options.requireComplete && importResult.report.status != .complete ? 2 : 0
  }

  private func auditNetgenDeviceImport() throws -> Int32 {
    let options = try LVSNetgenDeviceImportAuditCLIOptions(arguments: arguments)
    let seed = try decoded(NetgenLVSDevicePolicySeed.self, from: options.seedURL).value
    let report = try decoded(NetgenLVSDeviceDeckImportReport.self, from: options.reportURL).value
    let policy = try netgenDeviceImportAuditPolicy(from: options.policyURL)
    let audit = NetgenLVSDeviceDeckImportAuditor().audit(
      seed: seed,
      report: report,
      seedPath: options.seedURL.path(percentEncoded: false),
      reportPath: options.reportURL.path(percentEncoded: false),
      policy: policy
    )
    if let outputURL = options.outputURL {
      try LVSCLI.writeJSON(audit, to: outputURL)
    }
    if options.emitJSON {
      try LVSCLI.emitJSON(audit)
    } else {
      print("status=\(audit.status.rawValue)")
      print("policy=\(audit.policyID)")
      print(
        "requirements=\(audit.summary.satisfiedRequirementCount)/\(audit.summary.requirementCount)")
      if let outputURL = options.outputURL {
        print("audit=\(outputURL.path(percentEncoded: false))")
      }
    }
    return options.requireSatisfied && audit.status != .satisfied ? 2 : 0
  }

  private func importFoundryNetgenDevices() throws -> Int32 {
    let options = try LVSFoundryDeviceImportCLIOptions(arguments: arguments)
    let signoffProfile = try LVSCLI.defaultSignoffPDKProfile()
    let semanticReport = foundrySemanticReport(options: options, profile: signoffProfile)
    guard semanticReport.status == .passed, let pdkRoot = semanticReport.pdkRoot else {
      return try emitBlockedFoundryImport(options: options, semanticReport: semanticReport)
    }
    let importResult = try NetgenLVSDeviceDeckImporter.importDeviceDeck(
      from: SignoffPDKLocator.requiredFileURL(
        in: pdkRoot,
        profile: signoffProfile,
        requirementID: "netgen"
      ),
      generatedAt: semanticReport.generatedAt
    )
    try LVSCLI.writeJSON(importResult.seed, to: options.policyURL)
    if let reportURL = options.reportURL {
      try LVSCLI.writeJSON(importResult.report, to: reportURL)
    }
    let output = foundryDeviceImportOutput(
      importResult: importResult,
      options: options,
      semanticReport: semanticReport
    )
    try LVSCLI.emitFoundryDeviceImportOutput(output, emitJSON: options.emitJSON)
    if importResult.report.status == .blocked {
      return 2
    }
    return options.requireComplete && importResult.report.status != .complete ? 2 : 0
  }

  private func capabilities() throws -> Int32 {
    let options = try LVSCapabilityCLIOptions(arguments: arguments)
    let snapshot = LVSCapabilitySnapshotProvider().snapshot()
    if options.emitJSON {
      try LVSCLI.emitJSON(snapshot)
    } else {
      print("engine=\(snapshot.engineID)")
      print("qualification_evidence=\(snapshot.qualificationBinding.evidenceArtifactID)")
      print("backend_selection=evidence-bound")
      print("backends=\(snapshot.backends.map(\.backendID).joined(separator: ","))")
      print("corpus=\(snapshot.corpus.committedSpecPath)")
    }
    return 0
  }

  private func actionDomain() throws -> Int32 {
    let options = try LVSActionDomainCLIOptions(arguments: arguments)
    let snapshot = LVSActionDomainExporter().snapshot()
    if options.emitJSON {
      try LVSCLI.emitJSON(snapshot)
    } else {
      print("action_domain=\(snapshot.domainID)")
      print("operations=\(snapshot.operations.count)")
    }
    return 0
  }

  private func evidencePacketFromCorpusReport() throws -> Int32 {
    let options = try LVSEvidencePacketCLIOptions(arguments: arguments)
    let decodedReport = try decoded(LVSCorpusReport.self, from: options.reportURL)
    let packet = LVSCorpusEvidencePacketBuilder().build(
      report: decodedReport.value,
      reportPath: options.reportURL.path(percentEncoded: false),
      reportSHA256: LVSCLI.sha256(data: decodedReport.data),
      packetID: options.packetID,
      allowedArtifactRootPath: options.artifactRootURL?.path(percentEncoded: false)
    )
    try validateEvidencePacket(packet)
    if let outputURL = options.outputURL {
      try LVSCLI.writeJSON(packet, to: outputURL)
    }
    if options.emitJSON {
      try LVSCLI.emitJSON(packet)
    } else {
      print("status=packet-produced")
      print("packet_id=\(packet.packetID)")
      print("diagnostics=\(packet.diagnostics.count)")
      print("decision_hints=\(packet.decisionHints.count)")
      if let outputURL = options.outputURL {
        print("packet=\(outputURL.path(percentEncoded: false))")
      }
    }
    return 0
  }

  private func validateEvidencePacket(_ packet: LVSEvidencePacket) throws {
    let integrityIssues = packet.validateIntegrity()
    if !integrityIssues.isEmpty {
      let issueCodes = integrityIssues.map(\.code).joined(separator: ",")
      throw LVSError.invalidInput("LVS evidence packet failed integrity validation: \(issueCodes)")
    }
  }

  private func auditCorpusCoverage() throws -> Int32 {
    let options = try LVSCorpusCoverageAuditCLIOptions(arguments: arguments)
    let report = try decoded(LVSCorpusReport.self, from: options.reportURL).value
    let audit = LVSCorpusCoverageAuditor().audit(
      report: report,
      reportPath: options.reportURL.path(percentEncoded: false),
      policy: try corpusCoverageAuditPolicy(from: options.policyURL),
      auditID: options.auditID,
      checkedAt: options.checkedAt
    )
    if let outputURL = options.outputURL {
      try LVSCLI.writeJSON(audit, to: outputURL)
    }
    if options.emitJSON {
      try LVSCLI.emitJSON(audit)
    } else {
      print("status=\(audit.status.rawValue)")
      print("policy=\(audit.policyID)")
      print("missing_requirements=\(audit.summary.missingRequirementCount)")
      if let outputURL = options.outputURL {
        print("audit=\(outputURL.path(percentEncoded: false))")
      }
    }
    return audit.status == .satisfied ? 0 : 2
  }

  private func evidenceFromCorpusReport() throws -> Int32 {
    let options = try LVSCorpusEvidenceCLIOptions(arguments: arguments)
    let decodedReport = try decoded(LVSCorpusReport.self, from: options.reportURL)
    let output = LVSCorpusToolEvidenceExport(
      reportPath: options.reportURL.path(percentEncoded: false),
      reportSHA256: LVSCLI.sha256(data: decodedReport.data),
      report: decodedReport.value,
      evidenceID: options.evidenceID,
      checkedAt: options.checkedAt
    )
    if let outputURL = options.outputURL {
      try LVSCLI.writeJSON(output, to: outputURL)
    }
    if options.emitJSON {
      try LVSCLI.emitJSON(output)
    } else {
      print("status=\(output.status)")
      print("evidence_id=\(output.toolEvidence.evidenceID)")
      print("report=\(output.reportPath)")
      if let outputURL = options.outputURL {
        print("evidence=\(outputURL.path(percentEncoded: false))")
      }
    }
    return output.toolEvidence.qualification.qualified ? 0 : 2
  }

  private func repairHintsFromReport() throws -> Int32 {
    let options = try LVSRepairHintsCLIOptions(arguments: arguments)
    let report = try LVSRepairHintBuilder().build(reportURL: options.reportURL)
    if options.emitJSON {
      try LVSCLI.emitJSON(report)
    } else {
      print("status=\(report.status)")
      print("report=\(options.reportURL.path(percentEncoded: false))")
      print("active_diagnostics=\(report.activeDiagnosticCount)")
      print("hints=\(report.hintCount)")
      print("unsupported_diagnostics=\(report.unsupportedDiagnostics.count)")
    }
    return 0
  }

  private func reviewWaiversFromReport() throws -> Int32 {
    let options = try LVSWaiverReviewCLIOptions(arguments: arguments)
    let lvsReport = try decoded(LVSExecutionResult.self, from: options.reportURL).value
    let waiverFile = try decoded(LVSWaiverFile.self, from: options.waiverURL).value
    let review = try LVSWaiverReviewer().review(
      result: lvsReport,
      waiverFile: waiverFile,
      sourceReportPath: options.reportURL.path(percentEncoded: false),
      waiverPolicyPath: options.waiverURL.path(percentEncoded: false)
    )
    if let outputURL = options.outputURL {
      try LVSCLI.writeJSON(review, to: outputURL)
    }
    if options.emitJSON {
      try LVSCLI.emitJSON(review)
    } else {
      print("status=\(review.status.rawValue)")
      print("active_errors=\(review.activeErrorCount)")
      print("matched=\(review.matchedDiagnosticCount)")
      print("unmatched=\(review.unmatchedDiagnosticCount)")
      if let outputURL = options.outputURL {
        print("report=\(outputURL.path(percentEncoded: false))")
      }
    }
    return review.status == .blocked ? 2 : 0
  }

  private func qualifyCorpusReport() throws -> Int32 {
    let options = try LVSCorpusQualificationCLIOptions(arguments: arguments)
    let report = try decoded(LVSCorpusReport.self, from: options.reportURL).value
    let qualification = try corpusQualification(
      report: report, policyURL: options.qualificationPolicyURL)
    if options.emitJSON {
      let output = LVSCorpusQualificationCLIOutput(
        reportPath: options.reportURL.path(percentEncoded: false),
        report: report,
        qualification: qualification
      )
      try LVSCLI.emitJSON(output)
    } else {
      print("status=\(qualification.qualified ? "passed" : "failed")")
      print("report=\(options.reportURL.path(percentEncoded: false))")
      if !qualification.failures.isEmpty {
        print("failures=\(qualification.failures.map(\.code).joined(separator: ","))")
      }
    }
    return qualification.qualified ? 0 : 2
  }

  private func corpus() async throws -> Int32 {
    let options = try LVSCorpusCLIOptions(arguments: arguments)
    let report = try await LVSCorpusRunner().run(
      specURL: options.specURL,
      outputDirectory: options.outputDirectory,
      options: options.runOptions
    )
    let reportURL = options.outputDirectory.appending(path: "lvs-corpus-report.json")
    if options.emitJSON {
      try LVSCLI.emitJSON(
        LVSCorpusCLIOutput(reportPath: reportURL.path(percentEncoded: false), report: report))
    } else {
      print("status=\(report.qualification.qualified ? "passed" : "failed")")
      print("report=\(reportURL.path(percentEncoded: false))")
    }
    return report.qualification.qualified ? 0 : 2
  }

  private func runLVS() async throws -> Int32 {
    let options = try LVSCLIOptions(arguments: arguments)
    let result = try await DefaultLVSEngine().run(options.makeRequest())
    if options.emitJSON {
      try LVSCLI.emitJSON(LVSCLIOutput(result: result))
    } else {
      print("status=\(result.result.passed ? "passed" : "failed")")
      if let reportURL = result.reportURL {
        print("report=\(reportURL.path(percentEncoded: false))")
      }
      if let manifestURL = result.artifactManifestURL {
        print("manifest=\(manifestURL.path(percentEncoded: false))")
      }
      if let extracted = result.extractedLayoutNetlistURL {
        print("extracted_layout_netlist=\(extracted.path(percentEncoded: false))")
      }
    }
    return result.result.passed ? 0 : 2
  }
}

private enum LVSCLICommandMode: Sendable {
  case listBackends
  case foundryDeckSemantics
  case importNetgenDevices
  case auditNetgenDeviceImport
  case importFoundryNetgenDevices
  case capabilities
  case actionDomain
  case evidencePacketFromCorpusReport
  case auditCorpusCoverage
  case evidenceFromCorpusReport
  case repairHintsFromReport
  case reviewWaiversFromReport
  case qualifyCorpusReport
  case corpus
  case runLVS

  init(arguments: [String]) {
    if arguments == ["--list-backends"] {
      self = .listBackends
    } else if arguments.contains("--foundry-deck-semantics") {
      self = .foundryDeckSemantics
    } else if arguments.contains("--import-netgen-devices") {
      self = .importNetgenDevices
    } else if arguments.contains("--audit-netgen-device-import") {
      self = .auditNetgenDeviceImport
    } else if Self.importsFoundryNetgenDevices(arguments) {
      self = .importFoundryNetgenDevices
    } else if arguments.contains("--capabilities") {
      self = .capabilities
    } else if arguments.contains("--action-domain") {
      self = .actionDomain
    } else if arguments.contains("--evidence-packet-from-corpus-report") {
      self = .evidencePacketFromCorpusReport
    } else if arguments.contains("--audit-corpus-coverage") {
      self = .auditCorpusCoverage
    } else if arguments.contains("--evidence-from-corpus-report") {
      self = .evidenceFromCorpusReport
    } else if arguments.contains("--repair-hints-from-report") {
      self = .repairHintsFromReport
    } else if arguments.contains("--review-waivers-from-report") {
      self = .reviewWaiversFromReport
    } else if arguments.contains("--qualify-corpus-report") {
      self = .qualifyCorpusReport
    } else if arguments.contains("--corpus") {
      self = .corpus
    } else {
      self = .runLVS
    }
  }

  private static func importsFoundryNetgenDevices(_ arguments: [String]) -> Bool {
    arguments.contains(LVSFoundryDeviceImportCLIOptions.importFlag)
  }
}

extension LVSCLICommandExecutor {
  private func decoded<T: Decodable>(
    _ type: T.Type,
    from url: URL
  ) throws -> (value: T, data: Data) {
    let data = try Data(contentsOf: url)
    return (try JSONDecoder().decode(type, from: data), data)
  }

  private func netgenDeviceImportAuditPolicy(
    from policyURL: URL?
  ) throws -> NetgenLVSDeviceDeckImportAuditPolicy {
    guard let policyURL else {
      return .deviceSeedReadiness
    }
    return try decoded(NetgenLVSDeviceDeckImportAuditPolicy.self, from: policyURL).value
  }

  private func corpusCoverageAuditPolicy(from policyURL: URL?) throws
    -> LVSCorpusCoverageAuditPolicy
  {
    guard let policyURL else {
      return .netgenFoundryExpansion
    }
    return try decoded(LVSCorpusCoverageAuditPolicy.self, from: policyURL).value
  }

  private func corpusQualification(
    report: LVSCorpusReport,
    policyURL: URL?
  ) throws -> LVSCorpusQualificationResult {
    guard let policyURL else {
      return report.qualification
    }
    let policy = try decoded(LVSCorpusQualificationPolicy.self, from: policyURL).value
    return policy.evaluate(
      passed: report.passed, caseCount: report.caseCount, summary: report.summary)
  }

  private func foundrySemanticReport(
    options: LVSFoundryDeviceImportCLIOptions,
    profile: SignoffPDKProfile
  ) -> SignoffDeckSemanticReport {
    SignoffDeckSemanticInventory.inspect(
      profile: profile,
      requirements: LVSCLI.lvsNetgenDeckRequirements(from: profile),
      environment: options.environment(overriding: ProcessInfo.processInfo.environment)
    )
  }

  private func emitBlockedFoundryImport(
    options: LVSFoundryDeviceImportCLIOptions,
    semanticReport: SignoffDeckSemanticReport
  ) throws -> Int32 {
    let generatedAt = semanticReport.generatedAt
    let seed = NetgenLVSDevicePolicySeed(
      generatedAt: generatedAt,
      sourcePath: "",
      devices: [],
      policyRules: []
    )
    let report = blockedFoundryImportReport(
      generatedAt: generatedAt, semanticReport: semanticReport)
    try LVSCLI.writeJSON(seed, to: options.policyURL)
    if let reportURL = options.reportURL {
      try LVSCLI.writeJSON(report, to: reportURL)
    }
    let output = LVSFoundryDeviceImportCLIOutput(
      status: .blocked,
      policyPath: options.policyURL.path(percentEncoded: false),
      reportPath: options.reportURL?.path(percentEncoded: false),
      seed: seed,
      importReport: report,
      semanticReport: semanticReport
    )
    try LVSCLI.emitFoundryDeviceImportOutput(output, emitJSON: options.emitJSON)
    return 2
  }

  private func blockedFoundryImportReport(
    generatedAt: String,
    semanticReport: SignoffDeckSemanticReport
  ) -> NetgenLVSDeviceDeckImportReport {
    NetgenLVSDeviceDeckImportReport(
      generatedAt: generatedAt,
      status: .blocked,
      sourcePath: "",
      supportedFamilies: [],
      importedDeviceCount: 0,
      importedPolicyRuleCount: 0,
      skippedLineCount: 0,
      deviceFamilyCounts: [:],
      policyRuleCounts: [:],
      diagnostics: semanticReport.failures.map {
        NetgenLVSDeviceDeckImportDiagnostic(
          code: $0.code,
          message: "Netgen LVS semantic inspection failed for \($0.coverageTag)."
        )
      }
    )
  }

  private func foundryDeviceImportOutput(
    importResult: NetgenLVSDeviceDeckImport,
    options: LVSFoundryDeviceImportCLIOptions,
    semanticReport: SignoffDeckSemanticReport
  ) -> LVSFoundryDeviceImportCLIOutput {
    LVSFoundryDeviceImportCLIOutput(
      status: importResult.report.status,
      policyPath: options.policyURL.path(percentEncoded: false),
      reportPath: options.reportURL?.path(percentEncoded: false),
      seed: importResult.seed,
      importReport: importResult.report,
      semanticReport: semanticReport
    )
  }
}
