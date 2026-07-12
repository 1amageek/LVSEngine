import Foundation
import LVSCore

public protocol LVSArtifactPersisting: Sendable {
    func save(
        _ executionResult: LVSExecutionResult,
        to directory: URL
    ) throws -> LVSArtifactSaveResult
}
