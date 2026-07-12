import Foundation

public struct LVSCorpusToolEvidenceExport: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 2

    public struct FileReference: Sendable, Hashable, Codable {
        public let path: String
        public let kind: String
        public let format: String
        public let sha256: String?

        public init(
            path: String,
            kind: String = "report",
            format: String = "JSON",
            sha256: String? = nil
        ) {
            self.path = path
            self.kind = kind
            self.format = format
            self.sha256 = sha256
        }
    }

    public struct QualificationSummary: Sendable, Hashable, Codable {
        public let qualified: Bool
        public let policyID: String?
        public let observedMetrics: [String: Double]
        public let observedCounts: [String: Int]
        public let failureCodes: [String]
        public let scope: QualificationScope?

        public init(
            qualified: Bool,
            policyID: String?,
            observedMetrics: [String: Double],
            observedCounts: [String: Int],
            failureCodes: [String],
            scope: QualificationScope?
        ) {
            self.qualified = qualified
            self.policyID = policyID
            self.observedMetrics = observedMetrics
            self.observedCounts = observedCounts
            self.failureCodes = failureCodes
            self.scope = scope
        }
    }

    public struct QualificationScope: Sendable, Hashable, Codable {
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

    public struct ToolEvidence: Sendable, Hashable, Codable {
        public let evidenceID: String
        public let kind: String
        public let artifact: FileReference
        public let qualification: QualificationSummary
        public let checkedAt: String

        public init(
            evidenceID: String,
            kind: String = "corpus",
            artifact: FileReference,
            qualification: QualificationSummary,
            checkedAt: String
        ) {
            self.evidenceID = evidenceID
            self.kind = kind
            self.artifact = artifact
            self.qualification = qualification
            self.checkedAt = checkedAt
        }
    }

    public let schemaVersion: Int
    public let status: String
    public let reportPath: String
    public let reportSHA256: String?
    public let summary: LVSCorpusSummary
    public let toolEvidence: ToolEvidence
    public let oracleScopes: [QualificationScope]

    public init(
        schemaVersion: Int = LVSCorpusToolEvidenceExport.currentSchemaVersion,
        reportPath: String,
        reportSHA256: String? = nil,
        report: LVSCorpusReport,
        evidenceID: String? = nil,
        checkedAt: Date = Date()
    ) {
        let assessment = LVSCorpusEvidenceAssessment(report: report)
        var failureCodes = report.qualification.failures.map(\.code) + assessment.failureCodes
        if !Self.isValidSHA256(reportSHA256) {
            failureCodes.append("report_artifact_digest_missing_or_invalid")
        }
        if reportPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failureCodes.append("report_artifact_path_missing")
        }
        failureCodes = Array(Set(failureCodes)).sorted()
        let qualified = assessment.qualified && failureCodes.isEmpty

        self.schemaVersion = schemaVersion
        self.status = qualified ? "passed" : "failed"
        self.reportPath = reportPath
        self.reportSHA256 = reportSHA256
        self.summary = report.summary
        self.oracleScopes = assessment.oracleIdentities.map(QualificationScope.init(identity:))
        self.toolEvidence = ToolEvidence(
            evidenceID: evidenceID ?? Self.defaultEvidenceID(reportPath: reportPath),
            artifact: FileReference(path: reportPath, sha256: reportSHA256),
            qualification: QualificationSummary(
                qualified: qualified,
                policyID: report.qualification.policy == .strict ? "strict" : "custom",
                observedMetrics: Self.observedMetrics(report, assessment: assessment),
                observedCounts: Self.observedCounts(report, assessment: assessment),
                failureCodes: failureCodes,
                scope: assessment.qualificationScope.map(QualificationScope.init(identity:))
            ),
            checkedAt: Self.iso8601String(from: checkedAt)
        )
    }

    private static func defaultEvidenceID(reportPath: String) -> String {
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
            "requiredObservedAssertionCount": report.qualification.policy.requiredObservedAssertions.count,
            "completePrimaryIdentityCaseCount": assessment.completePrimaryIdentityCaseCount,
            "independentOracleCaseCount": assessment.independentOracleCaseCount,
            "independentOracleAgreementPassedCaseCount": assessment.independentOracleAgreementPassedCaseCount,
            "nonIndependentOracleCaseCount": assessment.nonIndependentOracleCaseCount,
            "oracleIntegrityFailureCount": assessment.oracleIntegrityFailureCount,
            "reportIntegrityFailureCount": assessment.reportIntegrityFailureCodes.count,
            "qualificationScopeCount": assessment.qualificationScope == nil ? 0 : 1,
        ]
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func isValidSHA256(_ digest: String?) -> Bool {
        guard let digest else { return false }
        let normalized = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count == 64 else { return false }
        return normalized.allSatisfy { character in
            character.isNumber || ("a"..."f").contains(character.lowercased())
        }
    }
}
