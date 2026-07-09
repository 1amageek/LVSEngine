public struct LVSUnsupportedRepairDiagnostic: Codable, Sendable, Hashable {
    public let sourceDiagnosticIndex: Int
    public let code: String
    public let severity: LVSDiagnostic.Severity
    public let message: String
    public let ruleID: String?
    public let category: String?
    public let suggestedFix: String?
    public let rawLine: String
    public let reason: String
    public let suggestedActions: [String]

    public init(
        sourceDiagnosticIndex: Int,
        code: String,
        severity: LVSDiagnostic.Severity,
        message: String,
        ruleID: String?,
        category: String?,
        suggestedFix: String?,
        rawLine: String,
        reason: String,
        suggestedActions: [String]
    ) {
        self.sourceDiagnosticIndex = sourceDiagnosticIndex
        self.code = code
        self.severity = severity
        self.message = message
        self.ruleID = ruleID
        self.category = category
        self.suggestedFix = suggestedFix
        self.rawLine = rawLine
        self.reason = reason
        self.suggestedActions = suggestedActions
    }
}
