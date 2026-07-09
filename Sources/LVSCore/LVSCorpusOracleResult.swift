public struct LVSCorpusOracleIntegrityDiagnostic: Sendable, Hashable, Codable {
    public enum Severity: String, Sendable, Hashable, Codable {
        case warning
        case error
    }

    public let severity: Severity
    public let code: String
    public let field: String
    public let message: String
    public let observed: [String]
    public let canonical: [String]
    public let suggestedActions: [String]

    public init(
        severity: Severity,
        code: String,
        field: String,
        message: String,
        observed: [String],
        canonical: [String],
        suggestedActions: [String]
    ) {
        self.severity = severity
        self.code = code
        self.field = field
        self.message = message
        self.observed = observed
        self.canonical = canonical
        self.suggestedActions = suggestedActions.filter { !$0.isEmpty }
    }
}

public struct LVSCorpusOracleResult: Sendable, Hashable, Codable {
    public let backendID: String
    public let passed: Bool
    public let activeErrorRuleIDs: [String]
    public let diagnostics: [LVSDiagnostic]
    public let diagnosticSummary: LVSDiagnosticSummary
    public let integrityDiagnostics: [LVSCorpusOracleIntegrityDiagnostic]
    public let durationSeconds: Double
    public let agreementPassed: Bool
    public let readinessStatus: LVSCorpusOracleReadinessStatus
    public let readinessDiagnostics: [String]
    public let failureReasons: [String]
    public let executionError: String?
    public let reportPath: String?
    public let manifestPath: String?
    public let extractedLayoutNetlistPath: String?
    public let devicePolicyReport: LVSDevicePolicyApplicationReport?
    public let provenance: LVSCorpusCaseProvenance?

    private enum CodingKeys: String, CodingKey {
        case backendID
        case passed
        case activeErrorRuleIDs
        case diagnostics
        case diagnosticSummary
        case integrityDiagnostics
        case durationSeconds
        case agreementPassed
        case readinessStatus
        case readinessDiagnostics
        case failureReasons
        case executionError
        case reportPath
        case manifestPath
        case extractedLayoutNetlistPath
        case devicePolicyReport
        case provenance
    }

    public init(
        backendID: String,
        passed: Bool,
        activeErrorRuleIDs: [String],
        diagnostics: [LVSDiagnostic] = [],
        diagnosticSummary: LVSDiagnosticSummary,
        integrityDiagnostics: [LVSCorpusOracleIntegrityDiagnostic] = [],
        durationSeconds: Double,
        agreementPassed: Bool,
        readinessStatus: LVSCorpusOracleReadinessStatus = .ready,
        readinessDiagnostics: [String] = [],
        failureReasons: [String],
        executionError: String? = nil,
        reportPath: String?,
        manifestPath: String?,
        extractedLayoutNetlistPath: String?,
        devicePolicyReport: LVSDevicePolicyApplicationReport? = nil,
        provenance: LVSCorpusCaseProvenance? = nil
    ) {
        let canonical = Self.canonicalDiagnostics(
            activeErrorRuleIDs: activeErrorRuleIDs,
            diagnostics: diagnostics,
            diagnosticSummary: diagnosticSummary
        )
        self.backendID = backendID
        self.passed = passed
        self.activeErrorRuleIDs = canonical.activeErrorRuleIDs
        self.diagnostics = diagnostics
        self.diagnosticSummary = canonical.diagnosticSummary
        self.integrityDiagnostics = integrityDiagnostics + canonical.integrityDiagnostics
        self.durationSeconds = durationSeconds
        self.agreementPassed = agreementPassed
        self.readinessStatus = readinessStatus
        self.readinessDiagnostics = readinessDiagnostics
        self.failureReasons = failureReasons
        self.executionError = executionError
        self.reportPath = reportPath
        self.manifestPath = manifestPath
        self.extractedLayoutNetlistPath = extractedLayoutNetlistPath
        self.devicePolicyReport = devicePolicyReport
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backendID = try container.decode(String.self, forKey: .backendID)
        passed = try container.decode(Bool.self, forKey: .passed)
        let decodedActiveErrorRuleIDs = try container.decode([String].self, forKey: .activeErrorRuleIDs)
        let decodedDiagnostics = try container.decodeIfPresent([LVSDiagnostic].self, forKey: .diagnostics) ?? []
        let decodedDiagnosticSummary = try container.decode(LVSDiagnosticSummary.self, forKey: .diagnosticSummary)
        let decodedIntegrityDiagnostics = try container.decodeIfPresent(
            [LVSCorpusOracleIntegrityDiagnostic].self,
            forKey: .integrityDiagnostics
        ) ?? []
        let canonical = Self.canonicalDiagnostics(
            activeErrorRuleIDs: decodedActiveErrorRuleIDs,
            diagnostics: decodedDiagnostics,
            diagnosticSummary: decodedDiagnosticSummary
        )
        activeErrorRuleIDs = canonical.activeErrorRuleIDs
        diagnostics = decodedDiagnostics
        diagnosticSummary = canonical.diagnosticSummary
        integrityDiagnostics = decodedIntegrityDiagnostics + canonical.integrityDiagnostics
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        agreementPassed = try container.decode(Bool.self, forKey: .agreementPassed)
        failureReasons = try container.decode([String].self, forKey: .failureReasons)
        executionError = try container.decodeIfPresent(String.self, forKey: .executionError)
        reportPath = try container.decodeIfPresent(String.self, forKey: .reportPath)
        manifestPath = try container.decodeIfPresent(String.self, forKey: .manifestPath)
        extractedLayoutNetlistPath = try container.decodeIfPresent(
            String.self,
            forKey: .extractedLayoutNetlistPath
        )
        devicePolicyReport = try container.decodeIfPresent(
            LVSDevicePolicyApplicationReport.self,
            forKey: .devicePolicyReport
        )
        provenance = try container.decodeIfPresent(LVSCorpusCaseProvenance.self, forKey: .provenance)
        readinessStatus = try container.decodeIfPresent(
            LVSCorpusOracleReadinessStatus.self,
            forKey: .readinessStatus
        ) ?? (executionError == nil ? .ready : .blocked)
        readinessDiagnostics = try container.decodeIfPresent(
            [String].self,
            forKey: .readinessDiagnostics
        ) ?? []
    }

    private static func canonicalDiagnostics(
        activeErrorRuleIDs: [String],
        diagnostics: [LVSDiagnostic],
        diagnosticSummary: LVSDiagnosticSummary
    ) -> (
        activeErrorRuleIDs: [String],
        diagnosticSummary: LVSDiagnosticSummary,
        integrityDiagnostics: [LVSCorpusOracleIntegrityDiagnostic]
    ) {
        guard !diagnostics.isEmpty else {
            return (
                sortedUnique(activeErrorRuleIDs),
                diagnosticSummary,
                []
            )
        }

        let canonicalRuleIDs = canonicalActiveErrorRuleIDs(in: diagnostics)
        let canonicalSummary = canonicalDiagnosticSummary(for: diagnostics)
        var integrityDiagnostics: [LVSCorpusOracleIntegrityDiagnostic] = []
        let normalizedObservedRuleIDs = sortedUnique(activeErrorRuleIDs)
        if normalizedObservedRuleIDs != canonicalRuleIDs {
            integrityDiagnostics.append(LVSCorpusOracleIntegrityDiagnostic(
                severity: .warning,
                code: "lvs_oracle_active_rule_ids_normalized",
                field: "activeErrorRuleIDs",
                message: "Oracle active error rule IDs were normalized from diagnostics.",
                observed: normalizedObservedRuleIDs,
                canonical: canonicalRuleIDs,
                suggestedActions: [
                    "regenerate_lvs_corpus_report",
                    "inspect_oracle_diagnostics",
                ]
            ))
        }
        if diagnosticSummary != canonicalSummary {
            integrityDiagnostics.append(LVSCorpusOracleIntegrityDiagnostic(
                severity: .warning,
                code: "lvs_oracle_diagnostic_summary_normalized",
                field: "diagnosticSummary",
                message: "Oracle diagnostic summary was normalized from diagnostics.",
                observed: summaryTokens(diagnosticSummary),
                canonical: summaryTokens(canonicalSummary),
                suggestedActions: [
                    "regenerate_lvs_corpus_report",
                    "compare_oracle_summary_with_diagnostics",
                ]
            ))
        }
        return (
            canonicalRuleIDs,
            canonicalSummary,
            integrityDiagnostics
        )
    }

    private static func canonicalActiveErrorRuleIDs(in diagnostics: [LVSDiagnostic]) -> [String] {
        sortedUnique(
            diagnostics
                .filter { $0.severity == .error && !$0.isWaived }
                .map { $0.ruleID ?? "unclassified" }
        )
    }

    private static func canonicalDiagnosticSummary(for diagnostics: [LVSDiagnostic]) -> LVSDiagnosticSummary {
        diagnostics.reduce(into: LVSDiagnosticSummary(infoCount: 0, warningCount: 0, errorCount: 0)) { summary, diagnostic in
            switch diagnostic.severity {
            case .info:
                summary = LVSDiagnosticSummary(
                    infoCount: summary.infoCount + 1,
                    warningCount: summary.warningCount,
                    errorCount: summary.errorCount,
                    waivedErrorCount: summary.waivedErrorCount
                )
            case .warning:
                summary = LVSDiagnosticSummary(
                    infoCount: summary.infoCount,
                    warningCount: summary.warningCount + 1,
                    errorCount: summary.errorCount,
                    waivedErrorCount: summary.waivedErrorCount
                )
            case .error:
                summary = LVSDiagnosticSummary(
                    infoCount: summary.infoCount,
                    warningCount: summary.warningCount,
                    errorCount: summary.errorCount + (diagnostic.isWaived ? 0 : 1),
                    waivedErrorCount: summary.waivedErrorCount + (diagnostic.isWaived ? 1 : 0)
                )
            }
        }
    }

    private static func summaryTokens(_ summary: LVSDiagnosticSummary) -> [String] {
        [
            "infoCount=\(summary.infoCount)",
            "warningCount=\(summary.warningCount)",
            "errorCount=\(summary.errorCount)",
            "waivedErrorCount=\(summary.waivedErrorCount)",
        ]
    }

    private static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }
}
