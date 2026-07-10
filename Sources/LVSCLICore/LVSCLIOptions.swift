import Foundation
import LVSEngine

public enum LVSCLIError: Error, LocalizedError, Equatable {
  case missingValue(String)
  case missingRequired(String)
  case invalidValue(argument: String, value: String, expected: String)
  case conflictingArguments(String, String)
  case unknownArgument(String)

  public var errorDescription: String? {
    switch self {
    case .missingValue(let argument):
      return "Missing value after \(argument)"
    case .missingRequired(let argument):
      return "Missing required argument: \(argument)"
    case .invalidValue(let argument, let value, let expected):
      return "Invalid value for \(argument): \(value). Expected \(expected)"
    case .conflictingArguments(let first, let second):
      return "Conflicting arguments: \(first) and \(second)"
    case .unknownArgument(let argument):
      return "Unknown argument: \(argument)"
    }
  }
}

public struct LVSCLIOptions: Sendable, Hashable {
  public let layoutNetlistURL: URL?
  public let layoutGDSURL: URL?
  public let layoutFormat: LVSLayoutFormat?
  public let schematicNetlistURL: URL
  public let topCell: String
  public let technologyURL: URL?
  public let waiverURL: URL?
  public let modelEquivalenceURL: URL?
  public let terminalEquivalenceURL: URL?
  public let devicePolicyURL: URL?
  public let backendID: String?
  public let outputDirectory: URL
  public let timeoutSeconds: Double
  public let emitJSON: Bool

  public init(arguments: [String]) throws {
    var layoutNetlistURL: URL?
    var layoutGDSURL: URL?
    var layoutFormat: LVSLayoutFormat?
    var schematicNetlistURL: URL?
    var topCell: String?
    var technologyURL: URL?
    var waiverURL: URL?
    var modelEquivalenceURL: URL?
    var terminalEquivalenceURL: URL?
    var devicePolicyURL: URL?
    var backendID: String?
    var outputDirectory: URL?
    var timeoutSeconds = 300.0
    var emitJSON = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--layout-netlist":
        layoutNetlistURL = URL(
          filePath: try Self.nonEmptyValue(
            after: argument, in: arguments, index: &index, expected: "non-empty path"))
      case "--layout-gds":
        layoutGDSURL = URL(
          filePath: try Self.nonEmptyValue(
            after: argument, in: arguments, index: &index, expected: "non-empty path"))
      case "--format":
        let value = try Self.value(after: argument, in: arguments, index: &index)
        guard let format = LVSLayoutFormat(rawValue: value) else {
          throw LVSCLIError.invalidValue(
            argument: argument,
            value: value,
            expected: "auto, gds, oasis, cif, or dxf"
          )
        }
        layoutFormat = format
      case "--schematic-netlist":
        schematicNetlistURL = URL(
          filePath: try Self.nonEmptyValue(
            after: argument, in: arguments, index: &index, expected: "non-empty path"))
      case "--top-cell":
        topCell = try Self.nonEmptyValue(
          after: argument, in: arguments, index: &index, expected: "non-empty top cell")
      case "--out":
        outputDirectory = URL(
          filePath: try Self.nonEmptyValue(
            after: argument, in: arguments, index: &index, expected: "non-empty path"))
      case "--tech":
        technologyURL = URL(
          filePath: try Self.nonEmptyValue(
            after: argument, in: arguments, index: &index, expected: "non-empty path"))
      case "--waivers":
        waiverURL = URL(
          filePath: try Self.nonEmptyValue(
            after: argument, in: arguments, index: &index, expected: "non-empty path"))
      case "--model-equivalence":
        modelEquivalenceURL = URL(
          filePath: try Self.nonEmptyValue(
            after: argument, in: arguments, index: &index, expected: "non-empty path"))
      case "--terminal-equivalence":
        terminalEquivalenceURL = URL(
          filePath: try Self.nonEmptyValue(
            after: argument, in: arguments, index: &index, expected: "non-empty path"))
      case "--device-policy":
        devicePolicyURL = URL(
          filePath: try Self.nonEmptyValue(
            after: argument, in: arguments, index: &index, expected: "non-empty path"))
      case "--backend":
        backendID = try Self.nonEmptyValue(
          after: argument, in: arguments, index: &index, expected: "non-empty backend ID")
      case "--timeout":
        timeoutSeconds = try Self.positiveFiniteDouble(
          after: argument, in: arguments, index: &index)
      case "--json":
        emitJSON = true
      default:
        throw LVSCLIError.unknownArgument(argument)
      }
      index += 1
    }

    guard !(layoutNetlistURL != nil && layoutGDSURL != nil) else {
      throw LVSCLIError.conflictingArguments("--layout-netlist", "--layout-gds")
    }
    guard layoutNetlistURL != nil || layoutGDSURL != nil else {
      throw LVSCLIError.missingRequired("--layout-netlist or --layout-gds")
    }
    guard let schematicNetlistURL else { throw LVSCLIError.missingRequired("--schematic-netlist") }
    guard let topCell else { throw LVSCLIError.missingRequired("--top-cell") }
    guard let outputDirectory else { throw LVSCLIError.missingRequired("--out") }

    self.layoutNetlistURL = layoutNetlistURL
    self.layoutGDSURL = layoutGDSURL
    self.layoutFormat = layoutFormat
    self.schematicNetlistURL = schematicNetlistURL
    self.topCell = topCell
    self.technologyURL = technologyURL
    self.waiverURL = waiverURL
    self.modelEquivalenceURL = modelEquivalenceURL
    self.terminalEquivalenceURL = terminalEquivalenceURL
    self.devicePolicyURL = devicePolicyURL
    self.backendID = backendID
    self.outputDirectory = outputDirectory
    self.timeoutSeconds = timeoutSeconds
    self.emitJSON = emitJSON
  }

  public func makeRequest() -> LVSRequest {
    let resolvedBackendID = backendID ?? defaultBackendID()
    return LVSRequest(
      layoutNetlistURL: layoutNetlistURL,
      layoutGDSURL: layoutGDSURL,
      layoutFormat: layoutFormat,
      schematicNetlistURL: schematicNetlistURL,
      topCell: topCell,
      technologyURL: technologyURL,
      waiverURL: waiverURL,
      modelEquivalenceURL: modelEquivalenceURL,
      terminalEquivalenceURL: terminalEquivalenceURL,
      devicePolicyURL: devicePolicyURL,
      workingDirectory: outputDirectory,
      backendSelection: LVSBackendSelection(backendID: resolvedBackendID),
      options: LVSOptions(timeoutSeconds: timeoutSeconds)
    )
  }

  private func defaultBackendID() -> String {
    if layoutNetlistURL != nil {
      return "native"
    }
    if technologyURL != nil {
      return "native-gds"
    }
    return "netgen"
  }

  private static func value(after argument: String, in arguments: [String], index: inout Int) throws
    -> String
  {
    try LVSCLIArgumentCursor.value(after: argument, in: arguments, index: &index)
  }

  private static func nonEmptyValue(
    after argument: String,
    in arguments: [String],
    index: inout Int,
    expected: String
  ) throws -> String {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: expected)
  }

  private static func positiveFiniteDouble(
    after argument: String, in arguments: [String], index: inout Int
  ) throws -> Double {
    try LVSCLIArgumentCursor.positiveFiniteDouble(after: argument, in: arguments, index: &index)
  }
}

public struct LVSCorpusCLIOptions: Sendable, Hashable {
  public let specURL: URL
  public let outputDirectory: URL
  public let oracleBackendIDOverride: String?
  public let emitJSON: Bool

  public init(arguments: [String]) throws {
    var specURL: URL?
    var outputDirectory: URL?
    var oracleBackendIDOverride: String?
    var emitJSON = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--corpus":
        specURL = URL(
          filePath: try Self.nonEmptyPath(after: argument, in: arguments, index: &index))
      case "--out":
        outputDirectory = URL(
          filePath: try Self.nonEmptyPath(after: argument, in: arguments, index: &index))
      case "--oracle-backend":
        oracleBackendIDOverride = try Self.nonEmptyValue(
          after: argument, in: arguments, index: &index)
      case "--json":
        emitJSON = true
      default:
        throw LVSCLIError.unknownArgument(argument)
      }
      index += 1
    }
    guard let specURL else { throw LVSCLIError.missingRequired("--corpus") }
    guard let outputDirectory else { throw LVSCLIError.missingRequired("--out") }
    self.specURL = specURL
    self.outputDirectory = outputDirectory
    self.oracleBackendIDOverride = oracleBackendIDOverride
    self.emitJSON = emitJSON
  }

  public var runOptions: LVSCorpusRunOptions {
    LVSCorpusRunOptions(oracleBackendIDOverride: oracleBackendIDOverride)
  }

  private static func value(after argument: String, in arguments: [String], index: inout Int) throws
    -> String
  {
    try LVSCLIArgumentCursor.value(after: argument, in: arguments, index: &index)
  }

  private static func nonEmptyValue(
    after argument: String, in arguments: [String], index: inout Int
  ) throws -> String {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: "non-empty backend ID")
  }

  private static func nonEmptyPath(after argument: String, in arguments: [String], index: inout Int)
    throws -> String
  {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: "non-empty path")
  }
}

public struct LVSCorpusQualificationCLIOptions: Sendable, Hashable {
  public let reportURL: URL
  public let qualificationPolicyURL: URL?
  public let emitJSON: Bool

  public init(arguments: [String]) throws {
    var reportURL: URL?
    var qualificationPolicyURL: URL?
    var emitJSON = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--qualify-corpus-report":
        reportURL = URL(
          filePath: try Self.nonEmptyPath(after: argument, in: arguments, index: &index))
      case "--qualification-policy":
        qualificationPolicyURL = URL(
          filePath: try Self.nonEmptyPath(after: argument, in: arguments, index: &index))
      case "--json":
        emitJSON = true
      default:
        throw LVSCLIError.unknownArgument(argument)
      }
      index += 1
    }
    guard let reportURL else { throw LVSCLIError.missingRequired("--qualify-corpus-report") }
    self.reportURL = reportURL
    self.qualificationPolicyURL = qualificationPolicyURL
    self.emitJSON = emitJSON
  }

  private static func value(after argument: String, in arguments: [String], index: inout Int) throws
    -> String
  {
    try LVSCLIArgumentCursor.value(after: argument, in: arguments, index: &index)
  }

  private static func nonEmptyPath(after argument: String, in arguments: [String], index: inout Int)
    throws -> String
  {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: "non-empty path")
  }
}

public struct LVSCorpusEvidenceCLIOptions: Sendable, Hashable {
  public let reportURL: URL
  public let evidenceID: String?
  public let checkedAt: Date
  public let emitJSON: Bool

  public init(arguments: [String], now: Date = Date()) throws {
    var reportURL: URL?
    var evidenceID: String?
    var checkedAt = now
    var emitJSON = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--evidence-from-corpus-report":
        reportURL = URL(
          filePath: try Self.nonEmptyPath(after: argument, in: arguments, index: &index))
      case "--evidence-id":
        evidenceID = try Self.nonEmptyValue(
          after: argument, in: arguments, index: &index, expected: "non-empty evidence ID")
      case "--checked-at":
        let value = try Self.value(after: argument, in: arguments, index: &index)
        checkedAt = try Self.iso8601Date(argument: argument, value: value)
      case "--json":
        emitJSON = true
      default:
        throw LVSCLIError.unknownArgument(argument)
      }
      index += 1
    }
    guard let reportURL else { throw LVSCLIError.missingRequired("--evidence-from-corpus-report") }
    self.reportURL = reportURL
    self.evidenceID = evidenceID
    self.checkedAt = checkedAt
    self.emitJSON = emitJSON
  }

  private static func value(after argument: String, in arguments: [String], index: inout Int) throws
    -> String
  {
    try LVSCLIArgumentCursor.value(after: argument, in: arguments, index: &index)
  }

  private static func nonEmptyValue(
    after argument: String,
    in arguments: [String],
    index: inout Int,
    expected: String
  ) throws -> String {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: expected)
  }

  private static func nonEmptyPath(after argument: String, in arguments: [String], index: inout Int)
    throws -> String
  {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: "non-empty path")
  }

  private static func iso8601Date(argument: String, value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [
      .withInternetDateTime,
      .withFractionalSeconds,
    ]
    if let date = formatter.date(from: value) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: value) {
      return date
    }
    throw LVSCLIError.invalidValue(
      argument: argument,
      value: value,
      expected: "ISO 8601 timestamp"
    )
  }
}

public struct LVSEvidencePacketCLIOptions: Sendable, Hashable {
  public let reportURL: URL
  public let outputURL: URL?
  public let packetID: String?
  public let artifactRootURL: URL?
  public let emitJSON: Bool

  public init(arguments: [String]) throws {
    var reportURL: URL?
    var outputURL: URL?
    var packetID: String?
    var artifactRootURL: URL?
    var emitJSON = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--evidence-packet-from-corpus-report":
        reportURL = URL(
          filePath: try Self.nonEmptyPath(after: argument, in: arguments, index: &index))
      case "--out":
        outputURL = URL(
          filePath: try Self.nonEmptyPath(after: argument, in: arguments, index: &index))
      case "--packet-id":
        packetID = try Self.nonEmptyValue(
          after: argument, in: arguments, index: &index, expected: "non-empty packet ID")
      case "--artifact-root":
        artifactRootURL = URL(
          filePath: try Self.nonEmptyPath(after: argument, in: arguments, index: &index))
      case "--json":
        emitJSON = true
      default:
        throw LVSCLIError.unknownArgument(argument)
      }
      index += 1
    }
    guard let reportURL else {
      throw LVSCLIError.missingRequired("--evidence-packet-from-corpus-report")
    }
    self.reportURL = reportURL
    self.outputURL = outputURL
    self.packetID = packetID
    self.artifactRootURL = artifactRootURL
    self.emitJSON = emitJSON
  }

  private static func value(after argument: String, in arguments: [String], index: inout Int) throws
    -> String
  {
    try LVSCLIArgumentCursor.value(after: argument, in: arguments, index: &index)
  }

  private static func nonEmptyValue(
    after argument: String,
    in arguments: [String],
    index: inout Int,
    expected: String
  ) throws -> String {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: expected)
  }

  private static func nonEmptyPath(after argument: String, in arguments: [String], index: inout Int)
    throws -> String
  {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: "non-empty path")
  }
}

public struct LVSCorpusCoverageAuditCLIOptions: Sendable, Hashable {
  public let reportURL: URL
  public let policyURL: URL?
  public let outputURL: URL?
  public let auditID: String?
  public let checkedAt: Date?
  public let emitJSON: Bool

  public init(arguments: [String]) throws {
    var reportURL: URL?
    var policyURL: URL?
    var outputURL: URL?
    var auditID: String?
    var checkedAt: Date?
    var emitJSON = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--audit-corpus-coverage":
        reportURL = URL(
          filePath: try Self.nonEmptyPath(after: argument, in: arguments, index: &index))
      case "--coverage-policy":
        policyURL = URL(
          filePath: try Self.nonEmptyPath(after: argument, in: arguments, index: &index))
      case "--out":
        outputURL = URL(
          filePath: try Self.nonEmptyPath(after: argument, in: arguments, index: &index))
      case "--audit-id":
        auditID = try Self.nonEmptyValue(
          after: argument, in: arguments, index: &index, expected: "non-empty audit ID")
      case "--checked-at":
        let value = try Self.value(after: argument, in: arguments, index: &index)
        checkedAt = try Self.iso8601Date(argument: argument, value: value)
      case "--json":
        emitJSON = true
      default:
        throw LVSCLIError.unknownArgument(argument)
      }
      index += 1
    }
    guard let reportURL else {
      throw LVSCLIError.missingRequired("--audit-corpus-coverage")
    }
    self.reportURL = reportURL
    self.policyURL = policyURL
    self.outputURL = outputURL
    self.auditID = auditID
    self.checkedAt = checkedAt
    self.emitJSON = emitJSON
  }

  private static func value(after argument: String, in arguments: [String], index: inout Int) throws
    -> String
  {
    try LVSCLIArgumentCursor.value(after: argument, in: arguments, index: &index)
  }

  private static func nonEmptyValue(
    after argument: String,
    in arguments: [String],
    index: inout Int,
    expected: String
  ) throws -> String {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: expected)
  }

  private static func nonEmptyPath(after argument: String, in arguments: [String], index: inout Int)
    throws -> String
  {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: "non-empty path")
  }

  private static func iso8601Date(argument: String, value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [
      .withInternetDateTime,
      .withFractionalSeconds,
    ]
    if let date = formatter.date(from: value) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: value) {
      return date
    }
    throw LVSCLIError.invalidValue(
      argument: argument,
      value: value,
      expected: "ISO 8601 timestamp"
    )
  }
}

public struct LVSActionDomainCLIOptions: Sendable, Hashable {
  public let emitJSON: Bool

  public init(arguments: [String]) throws {
    var sawActionDomain = false
    var emitJSON = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--action-domain":
        sawActionDomain = true
      case "--json":
        emitJSON = true
      default:
        throw LVSCLIError.unknownArgument(argument)
      }
      index += 1
    }
    guard sawActionDomain else { throw LVSCLIError.missingRequired("--action-domain") }
    self.emitJSON = emitJSON
  }
}

public struct LVSRepairHintsCLIOptions: Sendable, Hashable {
  public let reportURL: URL
  public let emitJSON: Bool

  public init(arguments: [String]) throws {
    var reportURL: URL?
    var emitJSON = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--repair-hints-from-report":
        reportURL = URL(
          filePath: try Self.nonEmptyPath(after: argument, in: arguments, index: &index))
      case "--json":
        emitJSON = true
      default:
        throw LVSCLIError.unknownArgument(argument)
      }
      index += 1
    }
    guard let reportURL else { throw LVSCLIError.missingRequired("--repair-hints-from-report") }
    self.reportURL = reportURL
    self.emitJSON = emitJSON
  }

  private static func value(after argument: String, in arguments: [String], index: inout Int) throws
    -> String
  {
    try LVSCLIArgumentCursor.value(after: argument, in: arguments, index: &index)
  }

  private static func nonEmptyPath(after argument: String, in arguments: [String], index: inout Int)
    throws -> String
  {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: "non-empty path")
  }
}

public struct LVSWaiverReviewCLIOptions: Sendable, Hashable {
  public let reportURL: URL
  public let waiverURL: URL
  public let outputURL: URL?
  public let emitJSON: Bool

  public init(arguments: [String]) throws {
    var reportURL: URL?
    var waiverURL: URL?
    var outputURL: URL?
    var emitJSON = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--review-waivers-from-report":
        reportURL = URL(
          filePath: try Self.nonEmptyPath(after: argument, in: arguments, index: &index))
      case "--waivers":
        waiverURL = URL(
          filePath: try Self.nonEmptyPath(after: argument, in: arguments, index: &index))
      case "--report-out":
        outputURL = URL(
          filePath: try Self.nonEmptyPath(after: argument, in: arguments, index: &index))
      case "--json":
        emitJSON = true
      default:
        throw LVSCLIError.unknownArgument(argument)
      }
      index += 1
    }
    guard let reportURL else { throw LVSCLIError.missingRequired("--review-waivers-from-report") }
    guard let waiverURL else { throw LVSCLIError.missingRequired("--waivers") }
    self.reportURL = reportURL
    self.waiverURL = waiverURL
    self.outputURL = outputURL
    self.emitJSON = emitJSON
  }

  private static func value(after argument: String, in arguments: [String], index: inout Int) throws
    -> String
  {
    try LVSCLIArgumentCursor.value(after: argument, in: arguments, index: &index)
  }

  private static func nonEmptyPath(after argument: String, in arguments: [String], index: inout Int)
    throws -> String
  {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: "non-empty path")
  }
}

public struct LVSFoundryDeckSemanticCLIOptions: Sendable, Hashable {
  public let pdkRoot: String?
  public let requirePassed: Bool
  public let emitJSON: Bool

  public init(arguments: [String]) throws {
    var sawFoundryDeckSemantics = false
    var pdkRoot: String?
    var requirePassed = false
    var emitJSON = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--foundry-deck-semantics":
        sawFoundryDeckSemantics = true
      case "--pdk-root":
        pdkRoot = try Self.nonEmptyValue(after: argument, in: arguments, index: &index)
      case "--require-passed":
        requirePassed = true
      case "--json":
        emitJSON = true
      default:
        throw LVSCLIError.unknownArgument(argument)
      }
      index += 1
    }
    guard sawFoundryDeckSemantics else {
      throw LVSCLIError.missingRequired("--foundry-deck-semantics")
    }
    self.pdkRoot = pdkRoot
    self.requirePassed = requirePassed
    self.emitJSON = emitJSON
  }

  public func environment(overriding base: [String: String]) -> [String: String] {
    var environment = base
    if let pdkRoot {
      environment["PDK_ROOT"] = pdkRoot
    }
    return environment
  }

  private static func value(after argument: String, in arguments: [String], index: inout Int) throws
    -> String
  {
    try LVSCLIArgumentCursor.value(after: argument, in: arguments, index: &index)
  }

  private static func nonEmptyValue(
    after argument: String, in arguments: [String], index: inout Int
  ) throws -> String {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: "non-empty path")
  }
}

public struct LVSNetgenDeviceImportCLIOptions: Sendable, Hashable {
  public let setupURL: URL
  public let policyURL: URL
  public let reportURL: URL?
  public let requireComplete: Bool
  public let emitJSON: Bool

  public init(arguments: [String]) throws {
    var sawImport = false
    var setupURL: URL?
    var policyURL: URL?
    var reportURL: URL?
    var requireComplete = false
    var emitJSON = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--import-netgen-devices":
        sawImport = true
      case "--netgen-setup":
        setupURL = URL(
          filePath: try Self.nonEmptyValue(after: argument, in: arguments, index: &index))
      case "--policy-out":
        policyURL = URL(
          filePath: try Self.nonEmptyValue(after: argument, in: arguments, index: &index))
      case "--report-out":
        reportURL = URL(
          filePath: try Self.nonEmptyValue(after: argument, in: arguments, index: &index))
      case "--require-complete":
        requireComplete = true
      case "--json":
        emitJSON = true
      default:
        throw LVSCLIError.unknownArgument(argument)
      }
      index += 1
    }
    guard sawImport else { throw LVSCLIError.missingRequired("--import-netgen-devices") }
    guard let setupURL else { throw LVSCLIError.missingRequired("--netgen-setup") }
    guard let policyURL else { throw LVSCLIError.missingRequired("--policy-out") }
    self.setupURL = setupURL
    self.policyURL = policyURL
    self.reportURL = reportURL
    self.requireComplete = requireComplete
    self.emitJSON = emitJSON
  }

  private static func value(after argument: String, in arguments: [String], index: inout Int) throws
    -> String
  {
    try LVSCLIArgumentCursor.value(after: argument, in: arguments, index: &index)
  }

  private static func nonEmptyValue(
    after argument: String, in arguments: [String], index: inout Int
  ) throws -> String {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: "non-empty path")
  }
}

public struct LVSFoundryDeviceImportCLIOptions: Sendable, Hashable {
  public static let importFlag = "--import-foundry-netgen-devices"

  public let pdkRoot: String?
  public let policyURL: URL
  public let reportURL: URL?
  public let requireComplete: Bool
  public let emitJSON: Bool

  public init(arguments: [String]) throws {
    var sawImport = false
    var pdkRoot: String?
    var policyURL: URL?
    var reportURL: URL?
    var requireComplete = false
    var emitJSON = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case Self.importFlag:
        sawImport = true
      case "--pdk-root":
        pdkRoot = try Self.nonEmptyValue(after: argument, in: arguments, index: &index)
      case "--policy-out":
        policyURL = URL(
          filePath: try Self.nonEmptyValue(after: argument, in: arguments, index: &index))
      case "--report-out":
        reportURL = URL(
          filePath: try Self.nonEmptyValue(after: argument, in: arguments, index: &index))
      case "--require-complete":
        requireComplete = true
      case "--json":
        emitJSON = true
      default:
        throw LVSCLIError.unknownArgument(argument)
      }
      index += 1
    }
    guard sawImport else { throw LVSCLIError.missingRequired(Self.importFlag) }
    guard let policyURL else { throw LVSCLIError.missingRequired("--policy-out") }
    self.pdkRoot = pdkRoot
    self.policyURL = policyURL
    self.reportURL = reportURL
    self.requireComplete = requireComplete
    self.emitJSON = emitJSON
  }

  public func environment(overriding base: [String: String]) -> [String: String] {
    var environment = base
    if let pdkRoot {
      environment["PDK_ROOT"] = pdkRoot
    }
    return environment
  }

  private static func value(after argument: String, in arguments: [String], index: inout Int) throws
    -> String
  {
    try LVSCLIArgumentCursor.value(after: argument, in: arguments, index: &index)
  }

  private static func nonEmptyValue(
    after argument: String, in arguments: [String], index: inout Int
  ) throws -> String {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: "non-empty path")
  }
}

public struct LVSNetgenDeviceImportAuditCLIOptions: Sendable, Hashable {
  public let seedURL: URL
  public let reportURL: URL
  public let outputURL: URL?
  public let policyURL: URL?
  public let requireSatisfied: Bool
  public let emitJSON: Bool

  public init(arguments: [String]) throws {
    var sawAudit = false
    var seedURL: URL?
    var reportURL: URL?
    var outputURL: URL?
    var policyURL: URL?
    var requireSatisfied = false
    var emitJSON = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--audit-netgen-device-import":
        sawAudit = true
      case "--policy-seed":
        seedURL = URL(
          filePath: try Self.nonEmptyValue(after: argument, in: arguments, index: &index))
      case "--import-report":
        reportURL = URL(
          filePath: try Self.nonEmptyValue(after: argument, in: arguments, index: &index))
      case "--audit-out":
        outputURL = URL(
          filePath: try Self.nonEmptyValue(after: argument, in: arguments, index: &index))
      case "--audit-policy":
        policyURL = URL(
          filePath: try Self.nonEmptyValue(after: argument, in: arguments, index: &index))
      case "--require-satisfied":
        requireSatisfied = true
      case "--json":
        emitJSON = true
      default:
        throw LVSCLIError.unknownArgument(argument)
      }
      index += 1
    }
    guard sawAudit else { throw LVSCLIError.missingRequired("--audit-netgen-device-import") }
    guard let seedURL else { throw LVSCLIError.missingRequired("--policy-seed") }
    guard let reportURL else { throw LVSCLIError.missingRequired("--import-report") }
    self.seedURL = seedURL
    self.reportURL = reportURL
    self.outputURL = outputURL
    self.policyURL = policyURL
    self.requireSatisfied = requireSatisfied
    self.emitJSON = emitJSON
  }

  private static func value(after argument: String, in arguments: [String], index: inout Int) throws
    -> String
  {
    try LVSCLIArgumentCursor.value(after: argument, in: arguments, index: &index)
  }

  private static func nonEmptyValue(
    after argument: String, in arguments: [String], index: inout Int
  ) throws -> String {
    try LVSCLIArgumentCursor.nonEmptyValue(
      after: argument, in: arguments, index: &index, expected: "non-empty path")
  }
}

public struct LVSCapabilityCLIOptions: Sendable, Hashable {
  public let emitJSON: Bool

  public init(arguments: [String]) throws {
    var sawCapabilities = false
    var emitJSON = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--capabilities":
        sawCapabilities = true
      case "--json":
        emitJSON = true
      default:
        throw LVSCLIError.unknownArgument(argument)
      }
      index += 1
    }
    guard sawCapabilities else { throw LVSCLIError.missingRequired("--capabilities") }
    self.emitJSON = emitJSON
  }
}
