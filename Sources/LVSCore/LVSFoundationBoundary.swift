@_exported import CircuiteFoundation

/// Canonical evidence view exposed by LVS at the cross-engine boundary.
///
/// The LVS evidence packet remains the domain-specific qualification record.
/// This value is the small, stable representation consumed by flow
/// coordinators and agents.
public struct LVSFoundationEvidence: Sendable, Hashable, Codable, ArtifactProducing,
    EvidenceProviding, DiagnosticReporting
{
    public let evidence: EvidenceManifest
    public let diagnostics: [DesignDiagnostic]

    public var artifacts: [ArtifactReference] { evidence.artifacts }

    public init(
        execution: LVSExecutionResult,
        provenance: ExecutionProvenance,
        artifacts: [ArtifactReference] = []
    ) throws {
        self.evidence = EvidenceManifest(
            provenance: provenance,
            artifacts: artifacts
        )
        self.diagnostics = try execution.result.diagnostics.map(Self.makeDiagnostic)
    }

    private static func makeDiagnostic(_ diagnostic: LVSDiagnostic) throws -> DesignDiagnostic {
        let rawCode = diagnostic.ruleID.map { "lvs.\($0)" } ?? "lvs.\(diagnostic.severity.rawValue)"
        let code = try DiagnosticCode(rawValue: rawCode)
        let severity: DiagnosticSeverity
        switch diagnostic.severity {
        case .info:
            severity = .information
        case .warning:
            severity = .warning
        case .error:
            severity = .error
        }
        let detail = diagnostic.rawLine.isEmpty ? nil : diagnostic.rawLine
        let suggestedActions = diagnostic.suggestedFix.map {
            [SuggestedAction(code: "lvs.repair", summary: $0)]
        } ?? []
        return DesignDiagnostic(
            code: code,
            severity: severity,
            summary: diagnostic.message,
            detail: detail,
            suggestedActions: suggestedActions
        )
    }
}

extension LVSRequest {
    /// Returns the Foundation hierarchy identity for the requested top cell.
    public func designObjectReference() throws -> DesignObjectReference {
        try DesignObjectReference(kind: .cell, identifier: topCell)
    }
}
