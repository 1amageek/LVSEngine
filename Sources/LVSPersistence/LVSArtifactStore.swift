import Foundation
import LVSCore

public struct LVSArtifactStore: Sendable {
    public init() {}

    public func save(_ executionResult: LVSExecutionResult, to directory: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let reportURL = directory.appending(path: "lvs-report-\(UUID().uuidString).json")
            let data = try encoder.encode(executionResult)
            try data.write(to: reportURL, options: [.atomic])
            return reportURL
        } catch {
            throw LVSError.artifactWriteFailed(error.localizedDescription)
        }
    }
}
