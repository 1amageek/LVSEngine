import Foundation
import CircuiteFoundation

public struct LVSCorpusObservationExport: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 4

    public struct ObservationSet: Sendable, Hashable, Codable {
        public let acceptanceCriteriaID: String?
        public let observedMetrics: [String: Double]
        public let observedCounts: [String: Int]
        public let findingCodes: [String]
        public let implementationScope: ImplementationScope?

        public init(
            acceptanceCriteriaID: String?,
            observedMetrics: [String: Double],
            observedCounts: [String: Int],
            findingCodes: [String],
            implementationScope: ImplementationScope?
        ) {
            self.acceptanceCriteriaID = acceptanceCriteriaID
            self.observedMetrics = observedMetrics
            self.observedCounts = observedCounts
            self.findingCodes = findingCodes
            self.implementationScope = implementationScope
        }
    }

    public struct ImplementationScope: Sendable, Hashable, Codable {
        public let implementationID: String
        public let binaryDigest: String
        public let algorithmVersion: String
        public let processProfileID: String
        public let deckDigest: String

        public init(identity: LVSImplementationIdentity) {
            implementationID = identity.implementationID
            binaryDigest = identity.binaryDigest
            algorithmVersion = identity.algorithmVersion
            processProfileID = identity.processProfileID
            deckDigest = identity.deckDigest
        }
    }

    public struct ObservationRecord: Sendable, Hashable, Codable {
        public let recordID: String
        public let artifact: ArtifactReference
        public let observations: ObservationSet
        public let observedAt: String

        public init(
            recordID: String,
            artifact: ArtifactReference,
            observations: ObservationSet,
            observedAt: String
        ) {
            self.recordID = recordID
            self.artifact = artifact
            self.observations = observations
            self.observedAt = observedAt
        }
    }

    public let schemaVersion: Int
    public let reportArtifact: ArtifactReference
    public let summary: LVSCorpusSummary
    public let observationRecord: ObservationRecord
    public let oracleScopes: [ImplementationScope]

    public init(
        schemaVersion: Int = LVSCorpusObservationExport.currentSchemaVersion,
        reportPath: String,
        reportSHA256: String,
        reportByteCount: UInt64,
        report: LVSCorpusReport,
        recordID: String? = nil,
        observedAt: Date = Date()
    ) throws {
        let assessment = LVSCorpusEvidenceAssessment(report: report)
        var failureCodes = report.assessment.findings.map(\.code) + assessment.failureCodes
        failureCodes = Array(Set(failureCodes)).sorted()
        self.schemaVersion = schemaVersion
        self.reportArtifact = ArtifactReference(
            id: try ArtifactID(rawValue: "lvs-corpus-report"),
            locator: ArtifactLocator(
                location: try ArtifactLocation(workspaceRelativePath: reportPath),
                role: .input,
                kind: .report,
                format: .json
            ),
            digest: try ContentDigest(
                algorithm: .sha256,
                hexadecimalValue: reportSHA256
            ),
            byteCount: reportByteCount
        )
        self.summary = report.summary
        self.oracleScopes = assessment.oracleIdentities.map(ImplementationScope.init(identity:))
        self.observationRecord = ObservationRecord(
            recordID: recordID ?? Self.defaultRecordID(reportPath: reportPath),
            artifact: reportArtifact,
            observations: ObservationSet(
                acceptanceCriteriaID: report.assessment.criteria == .strict ? "strict" : "custom",
                observedMetrics: Self.observedMetrics(report, assessment: assessment),
                observedCounts: Self.observedCounts(report, assessment: assessment),
                findingCodes: failureCodes,
                implementationScope: assessment.implementationScope.map(ImplementationScope.init(identity:))
            ),
            observedAt: Self.iso8601String(from: observedAt)
        )
    }

    public var reportPath: String { reportArtifact.path }
    public var reportSHA256: String { reportArtifact.digest.hexadecimalValue }

    private static func defaultRecordID(reportPath: String) -> String {
        let filename = URL(filePath: reportPath).deletingPathExtension().lastPathComponent
        return filename.isEmpty ? "lvs-corpus" : "lvs-corpus:\(filename)"
    }

    private static func observedMetrics(
        _ report: LVSCorpusReport,
        assessment: LVSCorpusEvidenceAssessment
    ) -> [String: Double] {
        var metrics = [
            "passRate": report.summary.passRate,
            "durationBudgetPassRate": report.caseCount == 0
                ? 0
                : Double(report.summary.durationBudgetPassedCaseCount) / Double(report.caseCount),
            "totalDurationSeconds": report.totalDurationSeconds,
        ]
        if let oracleAgreementRate = report.summary.oracleAgreementRate {
            metrics["oracleAgreementRate"] = oracleAgreementRate
        }
        if report.summary.oracleCaseCount > 0 {
            metrics["independentOracleRate"] = Double(assessment.independentOracleCaseCount)
                / Double(report.summary.oracleCaseCount)
        }
        return metrics
    }

    private static func observedCounts(
        _ report: LVSCorpusReport,
        assessment: LVSCorpusEvidenceAssessment
    ) -> [String: Int] {
        [
            "caseCount": report.caseCount,
            "matchedCaseCount": report.matchedCaseCount,
            "budgetExceededCaseCount": report.budgetExceededCaseCount,
            "durationBudgetPassedCaseCount": report.summary.durationBudgetPassedCaseCount,
            "oracleCaseCount": report.summary.oracleCaseCount,
            "oracleAgreementPassedCaseCount": report.summary.oracleAgreementPassedCaseCount,
            "primaryExecutionFailedCaseCount": report.summary.primaryExecutionFailedCaseCount,
            "oracleExecutionFailedCaseCount": report.summary.oracleExecutionFailedCaseCount,
            "oracleReadinessBlockedCaseCount": report.summary.oracleReadinessBlockedCaseCount,
            "observedAssertionKindCount": report.summary.observedAssertionCounts.count,
            "failedAssertionCount": report.summary.failedAssertionCount,
            "blockedAssertionCount": report.summary.blockedAssertionCount,
            "requiredObservedAssertionCount": report.assessment.criteria.requiredObservedAssertions.count,
            "completePrimaryIdentityCaseCount": assessment.completePrimaryIdentityCaseCount,
            "independentOracleCaseCount": assessment.independentOracleCaseCount,
            "independentOracleAgreementPassedCaseCount": assessment.independentOracleAgreementPassedCaseCount,
            "nonIndependentOracleCaseCount": assessment.nonIndependentOracleCaseCount,
            "oracleIntegrityFailureCount": assessment.oracleIntegrityFailureCount,
            "reportIntegrityFailureCount": assessment.reportIntegrityFailureCodes.count,
            "implementationScopeCount": assessment.implementationScope == nil ? 0 : 1,
        ]
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

}
