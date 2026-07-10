public struct LVSCorpusOracleComparison: Sendable, Hashable, Codable {
    public let primaryBackendID: String
    public let oracleBackendID: String
    public let passedMatched: Bool
    public let activeErrorRuleIDsMatched: Bool
    public let diagnosticSummaryMatched: Bool
    public let primaryPassed: Bool
    public let oraclePassed: Bool
    public let primaryActiveErrorRuleIDs: [String]
    public let oracleActiveErrorRuleIDs: [String]
    public let primaryDiagnosticSummary: LVSDiagnosticSummary
    public let oracleDiagnosticSummary: LVSDiagnosticSummary
    public let mismatchReasons: [String]
    public let disagreementClassifications: [LVSDisagreementClassification]

    public init(
        primaryBackendID: String,
        oracleBackendID: String,
        passedMatched: Bool,
        activeErrorRuleIDsMatched: Bool,
        diagnosticSummaryMatched: Bool,
        primaryPassed: Bool,
        oraclePassed: Bool,
        primaryActiveErrorRuleIDs: [String],
        oracleActiveErrorRuleIDs: [String],
        primaryDiagnosticSummary: LVSDiagnosticSummary,
        oracleDiagnosticSummary: LVSDiagnosticSummary,
        mismatchReasons: [String],
        disagreementClassifications: [LVSDisagreementClassification] = []
    ) {
        self.primaryBackendID = primaryBackendID
        self.oracleBackendID = oracleBackendID
        self.passedMatched = passedMatched
        self.activeErrorRuleIDsMatched = activeErrorRuleIDsMatched
        self.diagnosticSummaryMatched = diagnosticSummaryMatched
        self.primaryPassed = primaryPassed
        self.oraclePassed = oraclePassed
        self.primaryActiveErrorRuleIDs = primaryActiveErrorRuleIDs
        self.oracleActiveErrorRuleIDs = oracleActiveErrorRuleIDs
        self.primaryDiagnosticSummary = primaryDiagnosticSummary
        self.oracleDiagnosticSummary = oracleDiagnosticSummary
        self.mismatchReasons = mismatchReasons
        self.disagreementClassifications = disagreementClassifications
    }

    public var agreementPassed: Bool {
        passedMatched && activeErrorRuleIDsMatched && diagnosticSummaryMatched
    }

    private enum CodingKeys: String, CodingKey {
        case primaryBackendID
        case oracleBackendID
        case passedMatched
        case activeErrorRuleIDsMatched
        case diagnosticSummaryMatched
        case primaryPassed
        case oraclePassed
        case primaryActiveErrorRuleIDs
        case oracleActiveErrorRuleIDs
        case primaryDiagnosticSummary
        case oracleDiagnosticSummary
        case mismatchReasons
        case disagreementClassifications
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primaryBackendID = try container.decode(String.self, forKey: .primaryBackendID)
        oracleBackendID = try container.decode(String.self, forKey: .oracleBackendID)
        passedMatched = try container.decode(Bool.self, forKey: .passedMatched)
        activeErrorRuleIDsMatched = try container.decode(Bool.self, forKey: .activeErrorRuleIDsMatched)
        diagnosticSummaryMatched = try container.decode(Bool.self, forKey: .diagnosticSummaryMatched)
        primaryPassed = try container.decode(Bool.self, forKey: .primaryPassed)
        oraclePassed = try container.decode(Bool.self, forKey: .oraclePassed)
        primaryActiveErrorRuleIDs = try container.decode([String].self, forKey: .primaryActiveErrorRuleIDs)
        oracleActiveErrorRuleIDs = try container.decode([String].self, forKey: .oracleActiveErrorRuleIDs)
        primaryDiagnosticSummary = try container.decode(LVSDiagnosticSummary.self, forKey: .primaryDiagnosticSummary)
        oracleDiagnosticSummary = try container.decode(LVSDiagnosticSummary.self, forKey: .oracleDiagnosticSummary)
        mismatchReasons = try container.decode([String].self, forKey: .mismatchReasons)
        disagreementClassifications = try container.decode(
            [LVSDisagreementClassification].self,
            forKey: .disagreementClassifications
        )
    }
}
