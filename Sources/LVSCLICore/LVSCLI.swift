import CryptoKit
import Foundation
import LVSEngine
import SignoffToolSupport

public enum LVSCLI {
  public static let availableBackends = [
    "native",
    "native-gds",
    "netgen",
  ]

  public static func run(arguments: [String]) async -> Int32 {
    do {
      return try await LVSCLICommandExecutor(arguments: arguments).run()
    } catch {
      writeError(error)
      return 1
    }
  }

  static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try data.write(to: url, options: [.atomic])
  }

  static func emitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    let output = FileHandle.standardOutput
    let chunkSize = 32 * 1024
    var offset = 0
    while offset < data.count {
      let end = min(offset + chunkSize, data.count)
      try output.write(contentsOf: Data(data[offset..<end]))
      offset = end
    }
    try output.write(contentsOf: Data("\n".utf8))
  }

  static func writeError(_ error: Error) {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
  }

  static func defaultSignoffPDKProfile() throws -> SignoffPDKProfile {
    try SignoffPDKProfile.bundledDefaultProfile()
  }

  static func lvsNetgenDeckRequirements(from profile: SignoffPDKProfile)
    -> [SignoffDeckRequirement]
  {
    profile.deckRequirements(domain: "lvs", backendID: "netgen")
  }

  static func emitFoundryDeviceImportOutput(
    _ output: LVSFoundryDeviceImportCLIOutput,
    emitJSON: Bool
  ) throws {
    if emitJSON {
      try Self.emitJSON(output)
    } else {
      print("status=\(output.status.rawValue)")
      print("policy=\(output.policyPath)")
      if let reportPath = output.reportPath {
        print("report=\(reportPath)")
      }
      print("devices=\(output.importReport.importedDeviceCount)")
      print("policies=\(output.importReport.importedPolicyRuleCount)")
      print(
        "families=\(output.importReport.deviceFamilyCounts.keys.sorted().joined(separator: ","))")
    }
  }

  static func emitNetgenDeviceImportOutput(
    _ output: LVSNetgenDeviceImportCLIOutput,
    emitJSON: Bool
  ) throws {
    if emitJSON {
      try Self.emitJSON(output)
    } else {
      print("status=\(output.status.rawValue)")
      print("policy=\(output.policyPath)")
      if let reportPath = output.reportPath {
        print("report=\(reportPath)")
      }
      print("devices=\(output.importReport.importedDeviceCount)")
      print("policies=\(output.importReport.importedPolicyRuleCount)")
      print(
        "families=\(output.importReport.deviceFamilyCounts.keys.sorted().joined(separator: ","))")
    }
  }

  static func sha256(data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
