public enum LVSCorpusCoverageAuditStatus: String, Sendable, Hashable, Codable {
    case satisfied
    case incomplete
}

public struct LVSCorpusCoverageAudit: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let auditID: String
    public let status: LVSCorpusCoverageAuditStatus
    public let policyID: String
    public let reportPath: String?
    public let summary: Summary
    public let observedCoverageTags: [String]
    public let missingRequirements: [MissingRequirement]
    public let suggestedActions: [SuggestedAction]

    public init(
        schemaVersion: Int = LVSCorpusCoverageAudit.currentSchemaVersion,
        auditID: String,
        status: LVSCorpusCoverageAuditStatus,
        policyID: String,
        reportPath: String? = nil,
        summary: Summary,
        observedCoverageTags: [String],
        missingRequirements: [MissingRequirement] = [],
        suggestedActions: [SuggestedAction] = []
    ) {
        self.schemaVersion = schemaVersion
        self.auditID = auditID
        self.status = status
        self.policyID = policyID
        self.reportPath = reportPath
        self.summary = summary
        self.observedCoverageTags = Array(Set(observedCoverageTags.filter { !$0.isEmpty })).sorted()
        self.missingRequirements = missingRequirements.sorted { lhs, rhs in
            lhs.requirementID < rhs.requirementID
        }
        self.suggestedActions = suggestedActions.sorted { lhs, rhs in
            lhs.actionID < rhs.actionID
        }
    }

    public struct Summary: Sendable, Hashable, Codable {
        public let caseCount: Int
        public let matchedCaseCount: Int
        public let qualified: Bool
        public let oracleCaseCount: Int
        public let oracleAgreementPassedCaseCount: Int
        public let requiredRequirementCount: Int
        public let satisfiedRequirementCount: Int
        public let missingRequirementCount: Int
        public let observedCoverageTagCount: Int
        public let requiredCoverageTagCount: Int
        public let coveredRequiredCoverageTagCount: Int
        public let reportGeneratedAt: String?
        public let checkedAt: String?
        public let reportAgeSeconds: Double?

        public init(
            caseCount: Int,
            matchedCaseCount: Int,
            qualified: Bool,
            oracleCaseCount: Int,
            oracleAgreementPassedCaseCount: Int,
            requiredRequirementCount: Int,
            satisfiedRequirementCount: Int,
            missingRequirementCount: Int,
            observedCoverageTagCount: Int,
            requiredCoverageTagCount: Int,
            coveredRequiredCoverageTagCount: Int,
            reportGeneratedAt: String? = nil,
            checkedAt: String? = nil,
            reportAgeSeconds: Double? = nil
        ) {
            self.caseCount = caseCount
            self.matchedCaseCount = matchedCaseCount
            self.qualified = qualified
            self.oracleCaseCount = oracleCaseCount
            self.oracleAgreementPassedCaseCount = oracleAgreementPassedCaseCount
            self.requiredRequirementCount = requiredRequirementCount
            self.satisfiedRequirementCount = satisfiedRequirementCount
            self.missingRequirementCount = missingRequirementCount
            self.observedCoverageTagCount = observedCoverageTagCount
            self.requiredCoverageTagCount = requiredCoverageTagCount
            self.coveredRequiredCoverageTagCount = coveredRequiredCoverageTagCount
            self.reportGeneratedAt = reportGeneratedAt
            self.checkedAt = checkedAt
            self.reportAgeSeconds = reportAgeSeconds
        }
    }

    public struct MissingRequirement: Sendable, Hashable, Codable {
        public let requirementID: String
        public let title: String
        public let missingCoverageTags: [String]
        public let observedCaseCount: Int
        public let requiredCaseCount: Int
        public let reason: String
        public let suggestedActions: [String]

        public init(
            requirementID: String,
            title: String,
            missingCoverageTags: [String],
            observedCaseCount: Int,
            requiredCaseCount: Int,
            reason: String,
            suggestedActions: [String]
        ) {
            self.requirementID = requirementID
            self.title = title
            self.missingCoverageTags = Array(Set(missingCoverageTags.filter { !$0.isEmpty })).sorted()
            self.observedCaseCount = observedCaseCount
            self.requiredCaseCount = requiredCaseCount
            self.reason = reason
            self.suggestedActions = Array(Set(suggestedActions.filter { !$0.isEmpty })).sorted()
        }
    }

    public struct SuggestedAction: Sendable, Hashable, Codable {
        public let actionID: String
        public let requirementID: String
        public let reason: String

        public init(actionID: String, requirementID: String, reason: String) {
            self.actionID = actionID
            self.requirementID = requirementID
            self.reason = reason
        }
    }
}
