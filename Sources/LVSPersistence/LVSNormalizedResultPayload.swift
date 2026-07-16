import LVSCore
import LVSGraph

struct LVSNormalizedResultPayload: Encodable {
    let backendID: String
    let executionStatus: LVSExecutionStatus
    let verdict: LVSVerificationVerdict
    let readiness: LVSReadinessStatus
    let blockingReasons: [LVSBlockingReason]
    let diagnostics: [LVSDiagnostic]
    let correspondence: LVSCorrespondence?
    let extractionEvidence: LVSExtractionEvidence?
}
