import Foundation

public struct LVSWaiverReviewer: Sendable {
    public init() {}

    public func review(
        result: LVSExecutionResult,
        waiverFile: LVSWaiverFile,
        sourceReportPath: String? = nil,
        waiverPolicyPath: String? = nil
    ) throws -> LVSWaiverReviewReport {
        try review(
            diagnostics: result.result.diagnostics,
            waiverFile: waiverFile,
            sourceReportPath: sourceReportPath,
            waiverPolicyPath: waiverPolicyPath
        )
    }

    public func review(
        diagnostics: [LVSDiagnostic],
        waiverFile: LVSWaiverFile,
        sourceReportPath: String? = nil,
        waiverPolicyPath: String? = nil
    ) throws -> LVSWaiverReviewReport {
        try validate(waiverFile: waiverFile)
        var usedWaiverIDs: Set<String> = []
        var matchedWaivers: [LVSWaiverReviewReport.Match] = []
        var unmatchedDiagnostics: [LVSWaiverReviewReport.UnmatchedDiagnostic] = []
        var appliedWaivers: [LVSAppliedWaiver] = []

        for (index, diagnostic) in diagnostics.enumerated()
        where diagnostic.severity == .error && !diagnostic.isWaived {
            guard diagnostic.effectiveWaiverDisposition == .waivable else {
                unmatchedDiagnostics.append(LVSWaiverReviewReport.UnmatchedDiagnostic(
                    diagnosticIndex: index,
                    ruleID: diagnostic.ruleID,
                    category: diagnostic.category,
                    componentSignature: diagnostic.componentSignature,
                    diagnosticMessage: diagnostic.message,
                    suggestedFix: diagnostic.suggestedFix
                ))
                continue
            }
            guard let waiver = waiverFile.waivers.first(where: { matches(diagnostic: diagnostic, waiver: $0) }) else {
                unmatchedDiagnostics.append(LVSWaiverReviewReport.UnmatchedDiagnostic(
                    diagnosticIndex: index,
                    ruleID: diagnostic.ruleID,
                    category: diagnostic.category,
                    componentSignature: diagnostic.componentSignature,
                    diagnosticMessage: diagnostic.message,
                    suggestedFix: diagnostic.suggestedFix
                ))
                continue
            }
            usedWaiverIDs.insert(waiver.id)
            appliedWaivers.append(LVSAppliedWaiver(
                waiverID: waiver.id,
                ruleID: diagnostic.ruleID,
                diagnosticMessage: diagnostic.message
            ))
            matchedWaivers.append(LVSWaiverReviewReport.Match(
                diagnosticIndex: index,
                waiverID: waiver.id,
                ruleID: diagnostic.ruleID,
                category: diagnostic.category,
                componentSignature: diagnostic.componentSignature,
                diagnosticMessage: diagnostic.message,
                waiverReason: waiver.reason
            ))
        }

        let unusedWaiverIDs = waiverFile.waivers.map(\.id).filter { !usedWaiverIDs.contains($0) }
        let applicationReport = LVSWaiverApplicationReport(
            waivedDiagnosticCount: appliedWaivers.count,
            appliedWaivers: appliedWaivers,
            unusedWaiverIDs: unusedWaiverIDs
        )
        let activeErrorCount = matchedWaivers.count + unmatchedDiagnostics.count
        return LVSWaiverReviewReport(
            status: status(activeErrorCount: activeErrorCount, unmatchedCount: unmatchedDiagnostics.count),
            sourceReportPath: sourceReportPath,
            waiverPolicyPath: waiverPolicyPath,
            diagnosticCount: diagnostics.count,
            activeErrorCount: activeErrorCount,
            matchedDiagnosticCount: matchedWaivers.count,
            unmatchedDiagnosticCount: unmatchedDiagnostics.count,
            unusedWaiverIDs: unusedWaiverIDs,
            matches: matchedWaivers,
            unmatchedDiagnostics: unmatchedDiagnostics,
            applicationReport: applicationReport,
            suggestedActions: suggestedActions(matches: matchedWaivers, unmatchedDiagnostics: unmatchedDiagnostics)
        )
    }

    public func reviewedDiagnostics(
        diagnostics: [LVSDiagnostic],
        waiverFile: LVSWaiverFile
    ) throws -> [LVSDiagnostic] {
        try validate(waiverFile: waiverFile)
        return diagnostics.map { diagnostic in
            guard diagnostic.severity == .error,
                  !diagnostic.isWaived,
                  diagnostic.effectiveWaiverDisposition == .waivable,
                  let waiver = waiverFile.waivers.first(where: { matches(diagnostic: diagnostic, waiver: $0) }) else {
                return diagnostic
            }
            return diagnostic.applyingWaiver(waiver)
        }
    }

    private func validate(waiverFile: LVSWaiverFile) throws {
        guard waiverFile.schemaVersion == LVSWaiverFile.currentSchemaVersion else {
            throw LVSError.waiverApplicationFailed(
                "lvs_waiver_schema_version_unsupported: schemaVersion \(waiverFile.schemaVersion)"
            )
        }
        let ids = try waiverFile.waivers.map { waiver in
            let id = waiver.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw LVSError.invalidWaiver(id: waiver.id, reason: "blank-id")
            }
            let reason = waiver.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else {
                throw LVSError.invalidWaiver(id: id, reason: "blank-reason")
            }
            return id
        }
        guard Set(ids).count == ids.count else {
            throw LVSError.waiverApplicationFailed("Waiver IDs must be unique.")
        }
        for waiver in waiverFile.waivers where !hasScopedSelector(waiver) {
            throw LVSError.unscopedWaiver(id: waiver.id)
        }
    }

    private func hasScopedSelector(_ waiver: LVSWaiver) -> Bool {
        containsValue(waiver.ruleID)
            || containsValue(waiver.category)
            || containsValue(waiver.componentSignature)
            || containsValues(waiver.layoutPorts)
            || containsValues(waiver.schematicPorts)
            || containsValue(waiver.messageContains)
    }

    private func containsValue(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func containsValues(_ values: [String]?) -> Bool {
        guard let values else {
            return false
        }
        return values.contains { containsValue($0) }
    }

    private func matches(diagnostic: LVSDiagnostic, waiver: LVSWaiver) -> Bool {
        if let ruleID = waiver.ruleID, diagnostic.ruleID != ruleID {
            return false
        }
        if let category = waiver.category, diagnostic.category != category {
            return false
        }
        if let componentSignature = waiver.componentSignature,
           diagnostic.componentSignature != componentSignature {
            return false
        }
        if let layoutPorts = waiver.layoutPorts, diagnostic.layoutPorts != layoutPorts {
            return false
        }
        if let schematicPorts = waiver.schematicPorts, diagnostic.schematicPorts != schematicPorts {
            return false
        }
        if let messageContains = waiver.messageContains,
           !diagnostic.message.localizedCaseInsensitiveContains(messageContains) {
            return false
        }
        return true
    }

    private func status(
        activeErrorCount: Int,
        unmatchedCount: Int
    ) -> LVSWaiverReviewReport.Status {
        if unmatchedCount > 0 {
            return .blocked
        }
        if activeErrorCount > 0 {
            return .reviewRequired
        }
        return .noAction
    }

    private func suggestedActions(
        matches: [LVSWaiverReviewReport.Match],
        unmatchedDiagnostics: [LVSWaiverReviewReport.UnmatchedDiagnostic]
    ) -> [String] {
        if !unmatchedDiagnostics.isEmpty {
            return ["inspect-unmatched-lvs-diagnostics", "author-waiver-policy", "rerun-lvs-waiver-review"]
        }
        if !matches.isEmpty {
            return ["human-review-waiver-candidates", "approve-or-reject-waivers", "rerun-lvs-with-approved-waivers"]
        }
        return ["continue-signoff"]
    }
}
