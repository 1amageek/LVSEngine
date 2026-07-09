import Foundation

public enum LVSDisagreementClass: String, Sendable, Hashable, Codable {
    case extraction
    case policyInterpretation
    case netlistParsing
    case toolReadiness
    case comparisonMismatch
}

public struct LVSDisagreementClassification: Sendable, Hashable, Codable {
    public let classificationID: String
    public let kind: LVSDisagreementClass
    public let reasonCodes: [String]
    public let primaryBackendID: String
    public let oracleBackendID: String
    public let affectedLayoutComponents: [String]
    public let affectedSchematicComponents: [String]
    public let affectedComponentSignatures: [String]
    public let affectedNets: [String]
    public let diagnosticRuleIDs: [String]
    public let policyReasonCodes: [String]
    public let policySourceLines: [String]
    public let artifactPaths: [String]
    public let suggestedActions: [String]

    public init(
        classificationID: String,
        kind: LVSDisagreementClass,
        reasonCodes: [String],
        primaryBackendID: String,
        oracleBackendID: String,
        affectedLayoutComponents: [String] = [],
        affectedSchematicComponents: [String] = [],
        affectedComponentSignatures: [String] = [],
        affectedNets: [String] = [],
        diagnosticRuleIDs: [String] = [],
        policyReasonCodes: [String] = [],
        policySourceLines: [String] = [],
        artifactPaths: [String] = [],
        suggestedActions: [String] = []
    ) {
        self.classificationID = classificationID
        self.kind = kind
        self.reasonCodes = reasonCodes
        self.primaryBackendID = primaryBackendID
        self.oracleBackendID = oracleBackendID
        self.affectedLayoutComponents = affectedLayoutComponents
        self.affectedSchematicComponents = affectedSchematicComponents
        self.affectedComponentSignatures = affectedComponentSignatures
        self.affectedNets = affectedNets
        self.diagnosticRuleIDs = diagnosticRuleIDs
        self.policyReasonCodes = policyReasonCodes
        self.policySourceLines = policySourceLines
        self.artifactPaths = artifactPaths
        self.suggestedActions = suggestedActions
    }
}

public struct LVSDisagreementClassifier: Sendable {
    public init() {}

    public func classify(
        primaryBackendID: String,
        oracleBackendID: String,
        primaryPassed: Bool,
        oraclePassed: Bool,
        primaryDiagnostics: [LVSDiagnostic],
        oracleDiagnostics: [LVSDiagnostic],
        primaryExecutionError: String? = nil,
        oracleExecutionError: String? = nil,
        primaryReadinessStatus: LVSCorpusOracleReadinessStatus = .ready,
        oracleReadinessStatus: LVSCorpusOracleReadinessStatus = .ready,
        primaryProvenance: LVSCorpusCaseProvenance? = nil,
        oracleProvenance: LVSCorpusCaseProvenance? = nil,
        primaryDevicePolicyReport: LVSDevicePolicyApplicationReport? = nil,
        oracleDevicePolicyReport: LVSDevicePolicyApplicationReport? = nil,
        mismatchReasons: [String] = []
    ) -> [LVSDisagreementClassification] {
        let diagnostics = primaryDiagnostics + oracleDiagnostics
        let executionErrors = [primaryExecutionError, oracleExecutionError].compactMap { $0 }
        let provenances = [primaryProvenance, oracleProvenance].compactMap { $0 }
        let policyReports = [primaryDevicePolicyReport, oracleDevicePolicyReport].compactMap { $0 }
        let toolReadinessDiagnostics = diagnostics.filter(isToolReadinessDiagnostic)
        let extractionDiagnostics = diagnostics.filter(isExtractionDiagnostic)
        let netlistParsingDiagnostics = diagnostics.filter(isNetlistParsingDiagnostic)
        let policyDiagnostics = diagnostics.filter(isPolicyDiagnostic)
        let toolReadinessErrors = executionErrors.filter(isToolReadinessError)
        let extractionErrors = executionErrors.filter(isExtractionError)
        let netlistParsingErrors = executionErrors.filter(isNetlistParsingError)

        var classifications: [LVSDisagreementClassification] = []
        if primaryReadinessStatus == .blocked
            || oracleReadinessStatus == .blocked
            || !toolReadinessErrors.isEmpty {
            classifications.append(classification(
                kind: .toolReadiness,
                reasonCodes: reasonCodes(
                    base: ["tool-readiness-blocked"],
                    diagnostics: toolReadinessDiagnostics,
                    executionErrors: toolReadinessErrors,
                    policyReports: []
                ),
                primaryBackendID: primaryBackendID,
                oracleBackendID: oracleBackendID,
                diagnostics: toolReadinessDiagnostics,
                provenances: provenances,
                policyReports: [],
                suggestedActions: [
                    "check_lvs_tool_readiness",
                    "inspect_backend_selection",
                    "install_or_configure_external_oracle",
                ]
            ))
        }

        if !extractionDiagnostics.isEmpty || !extractionErrors.isEmpty {
            classifications.append(classification(
                kind: .extraction,
                reasonCodes: reasonCodes(
                    base: ["layout-extraction-disagreement"],
                    diagnostics: extractionDiagnostics,
                    executionErrors: extractionErrors,
                    policyReports: []
                ),
                primaryBackendID: primaryBackendID,
                oracleBackendID: oracleBackendID,
                diagnostics: extractionDiagnostics,
                provenances: provenances,
                policyReports: [],
                suggestedActions: [
                    "inspect_extracted_layout_netlist",
                    "verify_layout_labels_and_device_recognition",
                    "compare_extraction_artifacts",
                ]
            ))
        }

        if !netlistParsingDiagnostics.isEmpty || !netlistParsingErrors.isEmpty {
            classifications.append(classification(
                kind: .netlistParsing,
                reasonCodes: reasonCodes(
                    base: ["netlist-parsing-disagreement"],
                    diagnostics: netlistParsingDiagnostics,
                    executionErrors: netlistParsingErrors,
                    policyReports: []
                ),
                primaryBackendID: primaryBackendID,
                oracleBackendID: oracleBackendID,
                diagnostics: netlistParsingDiagnostics,
                provenances: provenances,
                policyReports: [],
                suggestedActions: [
                    "inspect_layout_and_schematic_netlist_parse",
                    "check_subckt_ports_and_includes",
                    "normalize_spice_constructs",
                ]
            ))
        }

        if !policyDiagnostics.isEmpty
            || policyReports.contains(where: isPolicyReportActionable) {
            classifications.append(classification(
                kind: .policyInterpretation,
                reasonCodes: reasonCodes(
                    base: ["device-policy-interpretation-disagreement"],
                    diagnostics: policyDiagnostics,
                    executionErrors: [],
                    policyReports: policyReports
                ),
                primaryBackendID: primaryBackendID,
                oracleBackendID: oracleBackendID,
                diagnostics: policyDiagnostics,
                provenances: provenances,
                policyReports: policyReports,
                suggestedActions: [
                    "inspect_device_policy_application_report",
                    "review_ignored_and_unobserved_policy_rules",
                    "compare_native_policy_with_oracle_deck",
                ]
            ))
        }

        if classifications.isEmpty && (!mismatchReasons.isEmpty || primaryPassed != oraclePassed) {
            classifications.append(classification(
                kind: .comparisonMismatch,
                reasonCodes: normalizedReasonCodes(
                    mismatchReasons.isEmpty ? ["passed-mismatch"] : mismatchReasons
                ),
                primaryBackendID: primaryBackendID,
                oracleBackendID: oracleBackendID,
                diagnostics: diagnostics,
                provenances: provenances,
                policyReports: policyReports,
                suggestedActions: [
                    "inspect_lvs_mismatch_diagnostics",
                    "compare_primary_and_oracle_reports",
                    "decide_if_native_or_oracle_result_is_authoritative",
                ]
            ))
        }

        return classifications
    }

    private func classification(
        kind: LVSDisagreementClass,
        reasonCodes: [String],
        primaryBackendID: String,
        oracleBackendID: String,
        diagnostics: [LVSDiagnostic],
        provenances: [LVSCorpusCaseProvenance],
        policyReports: [LVSDevicePolicyApplicationReport],
        suggestedActions: [String]
    ) -> LVSDisagreementClassification {
        LVSDisagreementClassification(
            classificationID: "lvs-disagreement-\(kind.rawValue)",
            kind: kind,
            reasonCodes: sortedUnique(reasonCodes),
            primaryBackendID: primaryBackendID,
            oracleBackendID: oracleBackendID,
            affectedLayoutComponents: sortedUnique(diagnostics.compactMap(\.layoutComponentName)),
            affectedSchematicComponents: sortedUnique(diagnostics.compactMap(\.schematicComponentName)),
            affectedComponentSignatures: sortedUnique(diagnostics.compactMap(\.componentSignature)),
            affectedNets: affectedNets(from: diagnostics),
            diagnosticRuleIDs: sortedUnique(diagnostics.compactMap(\.ruleID)),
            policyReasonCodes: policyReasonCodes(from: policyReports),
            policySourceLines: sortedUnique(policyReports.flatMap { report in
                report.ignoredRules.compactMap(\.sourceLine) + report.unobservedRules.compactMap(\.sourceLine)
            }),
            artifactPaths: artifactPaths(from: provenances),
            suggestedActions: suggestedActions
        )
    }

    private func reasonCodes(
        base: [String],
        diagnostics: [LVSDiagnostic],
        executionErrors: [String],
        policyReports: [LVSDevicePolicyApplicationReport]
    ) -> [String] {
        var codes = base
        codes += diagnostics.compactMap(\.ruleID).map(normalizedReasonCode)
        codes += diagnostics.compactMap(\.category).map(normalizedReasonCode)
        codes += executionErrors.map(errorReasonCode)
        codes += policyReasonCodes(from: policyReports)
        return sortedUnique(codes)
    }

    private func normalizedReasonCodes(_ reasons: [String]) -> [String] {
        sortedUnique(reasons.map(normalizedReasonCode))
    }

    private func policyReasonCodes(from reports: [LVSDevicePolicyApplicationReport]) -> [String] {
        sortedUnique(reports.flatMap { report in
            report.ignoredRules.map(\.reasonCode) + report.unobservedRules.map(\.reasonCode)
        }.map(normalizedReasonCode))
    }

    private func affectedNets(from diagnostics: [LVSDiagnostic]) -> [String] {
        sortedUnique(diagnostics.flatMap { diagnostic in
            (diagnostic.layoutPorts ?? []) + (diagnostic.schematicPorts ?? [])
        })
    }

    private func artifactPaths(from provenances: [LVSCorpusCaseProvenance]) -> [String] {
        sortedUnique(provenances.flatMap { provenance in
            provenance.inputArtifacts.map(\.path)
                + provenance.outputArtifacts.map(\.path)
                + [provenance.reportPath, provenance.manifestPath, provenance.extractedLayoutNetlistPath].compactMap { $0 }
        })
    }

    private func isToolReadinessError(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("unsupported lvs backend")
            || normalized.contains("backend unavailable")
            || normalized.contains("not located")
            || normalized.contains("missing tool")
            || normalized.contains("toolchain")
            || normalized.contains("install")
    }

    private func isToolReadinessDiagnostic(_ diagnostic: LVSDiagnostic) -> Bool {
        containsAny(diagnosticTokens(diagnostic), needles: [
            "readiness",
            "unsupported lvs backend",
            "backend unavailable",
            "not located",
            "missing tool",
            "toolchain",
            "install",
        ])
    }

    private func isExtractionDiagnostic(_ diagnostic: LVSDiagnostic) -> Bool {
        containsAny(diagnosticTokens(diagnostic), needles: ["extraction", "extract_lvs", "layout extraction"])
    }

    private func isExtractionError(_ value: String) -> Bool {
        containsAny([value.lowercased()], needles: ["extract", "layout extraction", "extracted layout"])
    }

    private func isNetlistParsingDiagnostic(_ diagnostic: LVSDiagnostic) -> Bool {
        containsAny(diagnosticTokens(diagnostic), needles: ["parse", "parser", "netlist parsing", "subckt", "include"])
    }

    private func isNetlistParsingError(_ value: String) -> Bool {
        containsAny([value.lowercased()], needles: ["parse", "parser", "decode", "subckt", "include", "netlist"])
    }

    private func isPolicyDiagnostic(_ diagnostic: LVSDiagnostic) -> Bool {
        containsAny(diagnosticTokens(diagnostic), needles: ["devicepolicy", "device policy", "policy"])
    }

    private func isPolicyReportActionable(_ report: LVSDevicePolicyApplicationReport) -> Bool {
        report.status != .complete || report.ignoredRuleCount > 0 || report.unobservedRuleCount > 0
    }

    private func diagnosticTokens(_ diagnostic: LVSDiagnostic) -> [String] {
        [
            diagnostic.ruleID,
            diagnostic.category,
            diagnostic.message,
            diagnostic.rawLine,
            diagnostic.suggestedFix,
        ]
        .compactMap { $0?.lowercased() }
    }

    private func containsAny(_ values: [String], needles: [String]) -> Bool {
        values.contains { value in
            needles.contains { value.contains($0) }
        }
    }

    private func errorReasonCode(_ message: String) -> String {
        let normalized = normalizedReasonCode(message)
        return normalized.isEmpty ? "execution-error" : normalized
    }

    private func normalizedReasonCode(_ value: String) -> String {
        value
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : "-"
            }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" {
                    return
                }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }
}
