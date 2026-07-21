import CryptoKit
import Foundation
import LVSGraph

public struct LVSNormalizedResultDigester: Sendable {
    public init() {}

    public func digest(_ executionResult: LVSExecutionResult) throws -> String {
        let payload = Payload(
            backendID: executionResult.result.backendID,
            executionStatus: executionResult.result.executionStatus,
            verdict: executionResult.result.verdict,
            readiness: executionResult.result.readiness,
            blockingReasons: executionResult.result.blockingReasons.sorted { $0.code < $1.code },
            diagnostics: executionResult.result.diagnostics.sorted {
                ($0.ruleID ?? "", $0.rawLine) < ($1.ruleID ?? "", $1.rawLine)
            },
            correspondence: executionResult.correspondence,
            extractionEvidence: executionResult.extractionEvidence
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(payload))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private struct Payload: Encodable {
        let backendID: String
        let executionStatus: LVSExecutionStatus
        let verdict: LVSVerificationVerdict
        let readiness: LVSReadinessStatus
        let blockingReasons: [LVSBlockingReason]
        let diagnostics: [LVSDiagnostic]
        let correspondence: LVSCorrespondence?
        let extractionEvidence: LVSExtractionEvidence?
    }
}
