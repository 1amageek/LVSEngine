public struct LVSWaiverReviewReport: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable {
        case noAction
        case reviewRequired
        case blocked
    }

    public let schemaVersion: Int
    public let status: Status
    public let sourceReportPath: String?
    public let waiverPolicyPath: String?
    public let diagnosticCount: Int
    public let activeErrorCount: Int
    public let matchedDiagnosticCount: Int
    public let unmatchedDiagnosticCount: Int
    public let unusedWaiverIDs: [String]
    public let matches: [Match]
    public let unmatchedDiagnostics: [UnmatchedDiagnostic]
    public let applicationReport: LVSWaiverApplicationReport
    public let suggestedActions: [String]

    public init(
        schemaVersion: Int = 1,
        status: Status,
        sourceReportPath: String? = nil,
        waiverPolicyPath: String? = nil,
        diagnosticCount: Int,
        activeErrorCount: Int,
        matchedDiagnosticCount: Int,
        unmatchedDiagnosticCount: Int,
        unusedWaiverIDs: [String],
        matches: [Match],
        unmatchedDiagnostics: [UnmatchedDiagnostic],
        applicationReport: LVSWaiverApplicationReport,
        suggestedActions: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.status = status
        self.sourceReportPath = sourceReportPath
        self.waiverPolicyPath = waiverPolicyPath
        self.diagnosticCount = diagnosticCount
        self.activeErrorCount = activeErrorCount
        self.matchedDiagnosticCount = matchedDiagnosticCount
        self.unmatchedDiagnosticCount = unmatchedDiagnosticCount
        self.unusedWaiverIDs = unusedWaiverIDs
        self.matches = matches
        self.unmatchedDiagnostics = unmatchedDiagnostics
        self.applicationReport = applicationReport
        self.suggestedActions = suggestedActions
    }

    public struct Match: Sendable, Hashable, Codable {
        public let diagnosticIndex: Int
        public let waiverID: String
        public let ruleID: String?
        public let category: String?
        public let componentSignature: String?
        public let diagnosticMessage: String
        public let waiverReason: String
        public let reviewState: String

        public init(
            diagnosticIndex: Int,
            waiverID: String,
            ruleID: String?,
            category: String?,
            componentSignature: String?,
            diagnosticMessage: String,
            waiverReason: String,
            reviewState: String = "requires-human-approval"
        ) {
            self.diagnosticIndex = diagnosticIndex
            self.waiverID = waiverID
            self.ruleID = ruleID
            self.category = category
            self.componentSignature = componentSignature
            self.diagnosticMessage = diagnosticMessage
            self.waiverReason = waiverReason
            self.reviewState = reviewState
        }
    }

    public struct UnmatchedDiagnostic: Sendable, Hashable, Codable {
        public let diagnosticIndex: Int
        public let ruleID: String?
        public let category: String?
        public let componentSignature: String?
        public let diagnosticMessage: String
        public let suggestedFix: String?

        public init(
            diagnosticIndex: Int,
            ruleID: String?,
            category: String?,
            componentSignature: String?,
            diagnosticMessage: String,
            suggestedFix: String?
        ) {
            self.diagnosticIndex = diagnosticIndex
            self.ruleID = ruleID
            self.category = category
            self.componentSignature = componentSignature
            self.diagnosticMessage = diagnosticMessage
            self.suggestedFix = suggestedFix
        }
    }
}
