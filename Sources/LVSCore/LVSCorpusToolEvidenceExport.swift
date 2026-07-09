import Foundation

public struct LVSCorpusToolEvidenceExport: Sendable, Hashable, Codable {
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

        public init(
            qualified: Bool,
            policyID: String?,
            observedMetrics: [String: Double],
            observedCounts: [String: Int],
            failureCodes: [String]
        ) {
            self.qualified = qualified
            self.policyID = policyID
            self.observedMetrics = observedMetrics
            self.observedCounts = observedCounts
            self.failureCodes = failureCodes
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

    public init(
        schemaVersion: Int = 1,
        reportPath: String,
        reportSHA256: String? = nil,
        report: LVSCorpusReport,
        evidenceID: String? = nil,
        checkedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.status = report.qualification.qualified ? "passed" : "failed"
        self.reportPath = reportPath
        self.reportSHA256 = reportSHA256
        self.summary = report.summary
        self.toolEvidence = ToolEvidence(
            evidenceID: evidenceID ?? Self.defaultEvidenceID(reportPath: reportPath),
            artifact: FileReference(path: reportPath, sha256: reportSHA256),
            qualification: QualificationSummary(
                qualified: report.qualification.qualified,
                policyID: report.qualification.policy == .strict ? "strict" : "custom",
                observedMetrics: Self.observedMetrics(report),
                observedCounts: Self.observedCounts(report),
                failureCodes: report.qualification.failures.map(\.code)
            ),
            checkedAt: Self.iso8601String(from: checkedAt)
        )
    }

    private static func defaultEvidenceID(reportPath: String) -> String {
        let filename = URL(filePath: reportPath).deletingPathExtension().lastPathComponent
        return filename.isEmpty ? "lvs-corpus" : "lvs-corpus:\(filename)"
    }

    private static func observedMetrics(_ report: LVSCorpusReport) -> [String: Double] {
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
        return metrics
    }

    private static func observedCounts(_ report: LVSCorpusReport) -> [String: Int] {
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
            "coverageTagCount": report.summary.coverageTagCounts.count,
            "requiredCoverageTagCount": report.qualification.policy.requiredCoverageTags.count,
            "coveredRequiredCoverageTagCount": coveredRequiredCoverageTagCount(report),
        ]
    }

    private static func coveredRequiredCoverageTagCount(_ report: LVSCorpusReport) -> Int {
        report.qualification.policy.requiredCoverageTags.filter { report.summary.coverageTagCounts[$0] != nil }.count
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
