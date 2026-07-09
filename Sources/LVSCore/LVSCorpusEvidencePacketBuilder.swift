import Foundation

public struct LVSCorpusEvidencePacketBuilder: Sendable {
    public init() {}

    public func build(
        report: LVSCorpusReport,
        reportPath: String,
        reportSHA256: String? = nil,
        packetID: String? = nil,
        allowedArtifactRootPath: String? = nil
    ) -> LVSEvidencePacket {
        let caseContexts = caseContexts(report.caseResults)
        let inputs = inputRefs(reportPath: reportPath, reportSHA256: reportSHA256)
        let artifactBuild = artifactRefs(
            contexts: caseContexts,
            allowedArtifactRootPath: allowedArtifactRootPath
        )
        let artifacts = artifactBuild.refs
        let integrityDiagnostics = caseContexts.flatMap(\.diagnostics) + artifactBuild.diagnostics
        let diagnostics = diagnostics(
            report: report,
            contexts: caseContexts,
            artifactRefs: inputs + artifacts
        ) + integrityDiagnostics
        return LVSEvidencePacket(
            packetID: packetID ?? defaultPacketID(reportPath: reportPath),
            domain: "lvs.signoff-evidence",
            subject: LVSEvidenceSubject(
                kind: "lvs-corpus",
                identifier: reportPath,
                backendID: report.runOptions.oracleBackendIDOverride
            ),
            intent: LVSEvidenceIntent(
                summary: "Expose retained LVS corpus observations as decision material.",
                designContext: "LVS corpus qualification with connectivity, model, parameter, port, policy, extraction, and oracle gates.",
                requestedObservations: [
                    "corpus-readiness",
                    "qualification-gates",
                    "connectivity-mismatch",
                    "model-mismatch",
                    "parameter-mismatch",
                    "port-mismatch",
                    "layout-extraction",
                    "oracle-agreement",
                    "coverage-tags",
                    "policy-repair-diagnostics",
                ]
            ),
            inputs: inputs,
            readiness: readiness(
                report: report,
                reportArtifactID: inputs.first?.artifactID,
                artifactRefs: artifacts,
                integrityDiagnostics: integrityDiagnostics
            ),
            artifacts: artifacts,
            normalizedViews: normalizedViews(report: report, artifactRefs: inputs + artifacts),
            metrics: metrics(report: report, contexts: caseContexts),
            diagnostics: diagnostics,
            confidence: confidence(report: report, diagnostics: diagnostics),
            decisionHints: decisionHints(diagnostics: diagnostics, report: report),
            coverageTags: report.summary.coverageTagCounts.keys.sorted(),
            relatedEvidenceIDs: ["lvs-corpus:\(URL(filePath: reportPath).deletingPathExtension().lastPathComponent)"]
        )
    }

    private func defaultPacketID(reportPath: String) -> String {
        let filename = URL(filePath: reportPath).deletingPathExtension().lastPathComponent
        return filename.isEmpty ? "lvs-evidence-packet:corpus" : "lvs-evidence-packet:corpus:\(filename)"
    }

    private func inputRefs(reportPath: String, reportSHA256: String?) -> [LVSEvidenceArtifactRef] {
        [
            LVSEvidenceArtifactRef(
                artifactID: "lvs-corpus-report",
                path: reportPath,
                role: "evidence-source",
                kind: "lvs-corpus-report",
                format: "JSON",
                sha256: reportSHA256
            )
        ]
    }

    private struct EvidenceCaseContext: Sendable {
        let result: LVSCorpusCaseResult
        let caseKey: String
        let payloadCaseID: String?
        let diagnostics: [LVSEvidenceDiagnostic]
    }

    private struct ArtifactRefBuildResult: Sendable {
        var refs: [LVSEvidenceArtifactRef]
        var diagnostics: [LVSEvidenceDiagnostic]
    }

    private func caseContexts(_ results: [LVSCorpusCaseResult]) -> [EvidenceCaseContext] {
        var rawCaseIDCounts: [String: Int] = [:]
        for result in results {
            let trimmedCaseID = result.caseID.trimmingCharacters(in: .whitespacesAndNewlines)
            rawCaseIDCounts[trimmedCaseID, default: 0] += 1
        }

        var namespaceCounts: [String: Int] = [:]
        return results.enumerated().map { index, result in
            let trimmedCaseID = result.caseID.trimmingCharacters(in: .whitespacesAndNewlines)
            var baseKey = sanitizedIdentifierToken(trimmedCaseID)
            if baseKey.isEmpty {
                baseKey = "case-\(index + 1)"
            }
            let namespaceOccurrence = namespaceCounts[baseKey, default: 0] + 1
            namespaceCounts[baseKey] = namespaceOccurrence
            let caseKey = namespaceOccurrence == 1 ? baseKey : "\(baseKey)-\(namespaceOccurrence)"
            var diagnostics: [LVSEvidenceDiagnostic] = []

            if trimmedCaseID.isEmpty {
                diagnostics.append(caseIDDiagnostic(
                    caseKey: caseKey,
                    issueID: "case-id-empty",
                    caseID: nil,
                    reason: "The LVS corpus case ID is empty and cannot be used as a stable evidence namespace."
                ))
            } else if let reason = caseIDValidationFailure(result.caseID) {
                diagnostics.append(caseIDDiagnostic(
                    caseKey: caseKey,
                    issueID: "case-id-unsafe",
                    caseID: trimmedCaseID,
                    reason: "The LVS corpus case ID is not safe to trust: \(reason)."
                ))
            }

            if rawCaseIDCounts[trimmedCaseID, default: 0] > 1 {
                diagnostics.append(caseIDDiagnostic(
                    caseKey: caseKey,
                    issueID: "case-id-duplicate",
                    caseID: trimmedCaseID.isEmpty ? nil : trimmedCaseID,
                    reason: "The LVS corpus case ID is duplicated and would otherwise collide in evidence IDs."
                ))
            } else if namespaceOccurrence > 1 {
                diagnostics.append(caseIDDiagnostic(
                    caseKey: caseKey,
                    issueID: "case-id-namespace-collision",
                    caseID: trimmedCaseID.isEmpty ? nil : trimmedCaseID,
                    reason: "The LVS corpus case ID normalizes to an evidence namespace already used by another case."
                ))
            }

            return EvidenceCaseContext(
                result: result,
                caseKey: caseKey,
                payloadCaseID: trimmedCaseID.isEmpty ? nil : trimmedCaseID,
                diagnostics: diagnostics
            )
        }
    }

    private func artifactRefs(
        contexts: [EvidenceCaseContext],
        allowedArtifactRootPath: String?
    ) -> ArtifactRefBuildResult {
        var result = ArtifactRefBuildResult(refs: [], diagnostics: [])
        for context in contexts {
            appendCaseRef(
                &result,
                path: context.result.reportPath,
                context: context,
                role: "run-artifact",
                kind: "lvs-case-report",
                format: "JSON",
                sourceField: "reportPath",
                allowedArtifactRootPath: allowedArtifactRootPath
            )
            appendCaseRef(
                &result,
                path: context.result.manifestPath,
                context: context,
                role: "run-artifact",
                kind: "lvs-artifact-manifest",
                format: "JSON",
                sourceField: "manifestPath",
                allowedArtifactRootPath: allowedArtifactRootPath
            )
            appendCaseRef(
                &result,
                path: context.result.extractedLayoutNetlistPath,
                context: context,
                role: "normalized",
                kind: "extracted-layout-netlist",
                format: "SPICE",
                sourceField: "extractedLayoutNetlistPath",
                allowedArtifactRootPath: allowedArtifactRootPath
            )
            appendCaseRef(
                &result,
                path: context.result.oracleResult?.reportPath,
                context: context,
                role: "oracle-artifact",
                kind: "lvs-oracle-report",
                format: "JSON",
                sourceField: "oracleReportPath",
                allowedArtifactRootPath: allowedArtifactRootPath
            )
            appendCaseRef(
                &result,
                path: context.result.oracleResult?.manifestPath,
                context: context,
                role: "oracle-artifact",
                kind: "lvs-oracle-artifact-manifest",
                format: "JSON",
                sourceField: "oracleManifestPath",
                allowedArtifactRootPath: allowedArtifactRootPath
            )
            appendCaseRef(
                &result,
                path: context.result.oracleResult?.extractedLayoutNetlistPath,
                context: context,
                role: "oracle-artifact",
                kind: "oracle-extracted-layout-netlist",
                format: "SPICE",
                sourceField: "oracleExtractedLayoutNetlistPath",
                allowedArtifactRootPath: allowedArtifactRootPath
            )
        }
        return result
    }

    private func appendCaseRef(
        _ result: inout ArtifactRefBuildResult,
        path: String?,
        context: EvidenceCaseContext,
        role: String,
        kind: String,
        format: String,
        sourceField: String,
        allowedArtifactRootPath: String?
    ) {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let reason = artifactPathValidationFailure(path, allowedArtifactRootPath: allowedArtifactRootPath) {
            result.diagnostics.append(artifactPathDiagnostic(
                caseKey: context.caseKey,
                caseID: context.payloadCaseID,
                sourceField: sourceField,
                rawPath: path,
                reason: reason
            ))
            return
        }
        result.refs.append(LVSEvidenceArtifactRef(
            artifactID: "\(context.caseKey):\(sourceField)",
            path: path,
            role: role,
            kind: kind,
            format: format,
            caseID: context.payloadCaseID
        ))
    }

    private func readiness(
        report: LVSCorpusReport,
        reportArtifactID: String?,
        artifactRefs: [LVSEvidenceArtifactRef],
        integrityDiagnostics: [LVSEvidenceDiagnostic]
    ) -> [LVSEvidenceReadiness] {
        let artifactIntegrityReadiness = integrityDiagnostics.isEmpty
            ? []
            : [
                LVSEvidenceReadiness(
                    component: "lvs-evidence-artifacts",
                    status: .blocked,
                    reason: "One or more LVS corpus evidence identifiers or artifact references are not safe to trust.",
                    artifactIDs: [reportArtifactID].compactMap { $0 },
                    suggestedActions: artifactIntegritySuggestedActions()
                ),
            ]
        let caseCount = report.caseCount
        if caseCount == 0 {
            return [
                LVSEvidenceReadiness(
                    component: "lvs-corpus-evidence",
                    status: .unknown,
                    reason: "The corpus report contains no cases.",
                    artifactIDs: [reportArtifactID].compactMap { $0 },
                    suggestedActions: ["add_lvs_corpus_cases"]
                )
            ] + artifactIntegrityReadiness
        }
        if report.summary.primaryExecutionFailedCaseCount == caseCount {
            return [
                LVSEvidenceReadiness(
                    component: "lvs-corpus-evidence",
                    status: .blocked,
                    reason: "Every primary LVS corpus case failed before usable diagnostics were produced.",
                    artifactIDs: [reportArtifactID].compactMap { $0 },
                    suggestedActions: [
                        "inspect_lvs_backend_logs",
                        "verify_lvs_netlists_and_policy_inputs",
                    ]
                )
            ] + artifactIntegrityReadiness
        }
        var values = [
            LVSEvidenceReadiness(
                component: "lvs-corpus-evidence",
                status: .ready,
                reason: "At least one retained LVS corpus case produced usable signoff evidence.",
                artifactIDs: [reportArtifactID].compactMap { $0 }
            )
        ]
        if artifactRefs.contains(where: { $0.kind == "extracted-layout-netlist" }) {
            values.append(LVSEvidenceReadiness(
                component: "lvs-layout-extraction",
                status: .ready,
                reason: "At least one retained case includes an extracted layout netlist artifact."
            ))
        }
        if report.summary.oracleCaseCount > 0 {
            values.append(LVSEvidenceReadiness(
                component: "lvs-oracle-comparison",
                status: report.summary.oracleReadinessBlockedCaseCount == 0 ? .ready : .blocked,
                reason: report.summary.oracleReadinessBlockedCaseCount == 0
                    ? "Oracle comparison evidence is available."
                    : "One or more oracle comparison cases were blocked before agreement could be evaluated.",
                suggestedActions: report.summary.oracleReadinessBlockedCaseCount == 0
                    ? []
                    : ["inspect_lvs_oracle_readiness", "inspect_lvs_oracle_logs"]
            ))
        } else {
            values.append(LVSEvidenceReadiness(
                component: "lvs-oracle-comparison",
                status: .unknown,
                reason: "No oracle comparison cases are present in this corpus report.",
                suggestedActions: ["run_lvs_corpus_with_oracle_backend_when_benchmarking"]
            ))
        }
        return values + artifactIntegrityReadiness
    }

    private func normalizedViews(
        report: LVSCorpusReport,
        artifactRefs: [LVSEvidenceArtifactRef]
    ) -> [LVSEvidenceNormalizedView] {
        [
            LVSEvidenceNormalizedView(
                viewID: "lvs-corpus-summary",
                kind: "signoff-corpus-summary",
                scope: "lvs-corpus",
                summaryMetrics: summaryMetrics(report),
                summaryCounts: summaryCounts(report),
                sourceArtifactIDs: artifactRefs.map(\.artifactID)
            )
        ]
    }

    private func metrics(
        report: LVSCorpusReport,
        contexts: [EvidenceCaseContext]
    ) -> [LVSEvidenceMetric] {
        var values: [LVSEvidenceMetric] = [
            LVSEvidenceMetric(metricID: "summary.pass-rate", name: "passRate", value: report.summary.passRate),
            LVSEvidenceMetric(
                metricID: "summary.duration-budget-pass-rate",
                name: "durationBudgetPassRate",
                value: durationBudgetPassRate(report)
            ),
            LVSEvidenceMetric(
                metricID: "summary.total-duration-seconds",
                name: "totalDurationSeconds",
                value: report.totalDurationSeconds,
                unit: "s"
            ),
            LVSEvidenceMetric(metricID: "summary.case-count", name: "caseCount", count: report.caseCount),
            LVSEvidenceMetric(
                metricID: "summary.matched-case-count",
                name: "matchedCaseCount",
                count: report.matchedCaseCount
            ),
            LVSEvidenceMetric(
                metricID: "summary.budget-exceeded-case-count",
                name: "budgetExceededCaseCount",
                count: report.budgetExceededCaseCount
            ),
        ]
        if let oracleAgreementRate = report.summary.oracleAgreementRate {
            values.append(LVSEvidenceMetric(
                metricID: "summary.oracle-agreement-rate",
                name: "oracleAgreementRate",
                value: oracleAgreementRate
            ))
        }
        for context in contexts {
            values.append(contentsOf: caseMetrics(context))
        }
        return values
    }

    private func caseMetrics(_ context: EvidenceCaseContext) -> [LVSEvidenceMetric] {
        let result = context.result
        return [
            LVSEvidenceMetric(
                metricID: "\(context.caseKey).duration-seconds",
                name: "durationSeconds",
                value: result.durationSeconds,
                unit: "s",
                caseID: context.payloadCaseID
            ),
            LVSEvidenceMetric(
                metricID: "\(context.caseKey).expected-active-error-rule-count",
                name: "expectedActiveErrorRuleCount",
                count: result.expectedActiveErrorRuleIDs.count,
                caseID: context.payloadCaseID
            ),
            LVSEvidenceMetric(
                metricID: "\(context.caseKey).actual-active-error-rule-count",
                name: "actualActiveErrorRuleCount",
                count: result.actualActiveErrorRuleIDs.count,
                caseID: context.payloadCaseID
            ),
            LVSEvidenceMetric(
                metricID: "\(context.caseKey).error-count",
                name: "errorCount",
                count: result.diagnosticSummary.errorCount,
                caseID: context.payloadCaseID
            ),
            LVSEvidenceMetric(
                metricID: "\(context.caseKey).waived-error-count",
                name: "waivedErrorCount",
                count: result.diagnosticSummary.waivedErrorCount,
                caseID: context.payloadCaseID
            ),
        ]
    }

    private func diagnostics(
        report: LVSCorpusReport,
        contexts: [EvidenceCaseContext],
        artifactRefs: [LVSEvidenceArtifactRef]
    ) -> [LVSEvidenceDiagnostic] {
        var values: [LVSEvidenceDiagnostic] = []
        for failure in report.qualification.failures {
            values.append(LVSEvidenceDiagnostic(
                diagnosticID: "qualification:\(failure.code)",
                severity: .error,
                category: category(qualificationCode: failure.code),
                message: failure.message,
                artifactIDs: ["lvs-corpus-report"],
                suggestedActions: suggestedActions(category: category(qualificationCode: failure.code))
            ))
        }
        for context in contexts {
            appendCaseDiagnostics(
                &values,
                context: context,
                artifactIDs: artifactIDs(for: context, artifactRefs: artifactRefs)
            )
        }
        return values
    }

    private func appendCaseDiagnostics(
        _ values: inout [LVSEvidenceDiagnostic],
        context: EvidenceCaseContext,
        artifactIDs: [String]
    ) {
        let result = context.result
        if let executionError = result.executionError {
            values.append(LVSEvidenceDiagnostic(
                diagnosticID: "\(context.caseKey):primary-execution",
                severity: .error,
                category: "primary_execution",
                message: executionError,
                caseID: context.payloadCaseID,
                artifactIDs: artifactIDs,
                suggestedActions: suggestedActions(category: "primary_execution")
            ))
        }
        if !result.expectationMatched {
            values.append(LVSEvidenceDiagnostic(
                diagnosticID: "\(context.caseKey):expectation-mismatch",
                severity: .error,
                category: "expectation_mismatch",
                message: "Expected LVS pass state or active rule IDs did not match observed native LVS output.",
                caseID: context.payloadCaseID,
                artifactIDs: artifactIDs,
                suggestedActions: suggestedActions(category: "expectation_mismatch")
            ))
        }
        if !result.durationBudgetPassed {
            values.append(LVSEvidenceDiagnostic(
                diagnosticID: "\(context.caseKey):duration-budget",
                severity: .warning,
                category: "duration_budget",
                message: "The LVS case exceeded its expected duration budget.",
                caseID: context.payloadCaseID,
                artifactIDs: artifactIDs,
                suggestedActions: suggestedActions(category: "duration_budget")
            ))
        }
        for (index, ruleID) in result.actualActiveErrorRuleIDs.enumerated() {
            let category = category(ruleID: ruleID)
            values.append(LVSEvidenceDiagnostic(
                diagnosticID: "\(context.caseKey):active-rule:\(index)",
                severity: .error,
                category: category,
                message: "Active LVS error rule \(ruleID) was observed.",
                caseID: context.payloadCaseID,
                ruleID: ruleID,
                artifactIDs: artifactIDs,
                suggestedActions: suggestedActions(category: category)
            ))
        }
        for (index, reason) in result.failureReasons.enumerated() {
            let category = category(failureReason: reason)
            let fields = diagnosticFields(category: category, reason: reason)
            values.append(LVSEvidenceDiagnostic(
                diagnosticID: "\(context.caseKey):failure:\(index)",
                severity: .error,
                category: category,
                message: reason,
                caseID: context.payloadCaseID,
                componentSignature: fields.componentSignature,
                layoutModel: fields.layoutModel,
                schematicModel: fields.schematicModel,
                parameterName: fields.parameterName,
                layoutValue: fields.layoutValue,
                schematicValue: fields.schematicValue,
                layoutPorts: fields.layoutPorts,
                schematicPorts: fields.schematicPorts,
                artifactIDs: artifactIDs,
                suggestedActions: suggestedActions(category: category)
            ))
        }
        if let oracle = result.oracleResult {
            appendOracleDiagnostics(&values, context: context, oracle: oracle, artifactIDs: artifactIDs)
        }
    }

    private func appendOracleDiagnostics(
        _ values: inout [LVSEvidenceDiagnostic],
        context: EvidenceCaseContext,
        oracle: LVSCorpusOracleResult,
        artifactIDs: [String]
    ) {
        if oracle.readinessStatus == .blocked {
            values.append(LVSEvidenceDiagnostic(
                diagnosticID: "\(context.caseKey):oracle-readiness",
                severity: .error,
                category: "oracle_readiness",
                message: oracle.readinessDiagnostics.joined(separator: "; "),
                caseID: context.payloadCaseID,
                artifactIDs: artifactIDs,
                suggestedActions: suggestedActions(category: "oracle_readiness")
            ))
        }
        if let executionError = oracle.executionError {
            values.append(LVSEvidenceDiagnostic(
                diagnosticID: "\(context.caseKey):oracle-execution",
                severity: .error,
                category: "oracle_execution",
                message: executionError,
                caseID: context.payloadCaseID,
                artifactIDs: artifactIDs,
                suggestedActions: suggestedActions(category: "oracle_execution")
            ))
        }
        if !oracle.agreementPassed {
            values.append(LVSEvidenceDiagnostic(
                diagnosticID: "\(context.caseKey):oracle-agreement",
                severity: .error,
                category: "oracle_agreement",
                message: "Native LVS and oracle LVS did not agree for this case.",
                caseID: context.payloadCaseID,
                artifactIDs: artifactIDs,
                suggestedActions: suggestedActions(category: "oracle_agreement")
            ))
        }
        for (index, reason) in oracle.failureReasons.enumerated() {
            let category = category(failureReason: reason)
            values.append(LVSEvidenceDiagnostic(
                diagnosticID: "\(context.caseKey):oracle-failure:\(index)",
                severity: .error,
                category: category,
                message: reason,
                caseID: context.payloadCaseID,
                artifactIDs: artifactIDs,
                suggestedActions: suggestedActions(category: category)
            ))
        }
    }

    private func artifactIDs(
        for context: EvidenceCaseContext,
        artifactRefs: [LVSEvidenceArtifactRef]
    ) -> [String] {
        let prefix = "\(context.caseKey):"
        return artifactRefs
            .filter { $0.artifactID.hasPrefix(prefix) }
            .map(\.artifactID)
    }

    private func confidence(
        report: LVSCorpusReport,
        diagnostics: [LVSEvidenceDiagnostic]
    ) -> LVSEvidenceConfidence {
        let evidenceCount = report.caseResults.filter { $0.executionError == nil }.count
        if diagnostics.contains(where: { $0.category == "artifact_integrity" }) {
            return LVSEvidenceConfidence(
                level: .low,
                reason: "One or more LVS corpus artifact references or evidence identifiers are unsafe to trust.",
                evidenceCount: evidenceCount,
                limitationCount: diagnostics.count
            )
        }
        if report.caseCount == 0 {
            return LVSEvidenceConfidence(
                level: .low,
                reason: "No LVS corpus cases are available.",
                evidenceCount: 0,
                limitationCount: diagnostics.count
            )
        }
        if evidenceCount == 0 {
            return LVSEvidenceConfidence(
                level: .low,
                reason: "Every primary LVS case failed before diagnostics could be used.",
                evidenceCount: 0,
                limitationCount: diagnostics.count
            )
        }
        if report.qualification.qualified {
            return LVSEvidenceConfidence(
                level: .high,
                reason: "The LVS corpus is qualified under its policy.",
                evidenceCount: evidenceCount,
                limitationCount: diagnostics.count
            )
        }
        return LVSEvidenceConfidence(
            level: .medium,
            reason: "The LVS corpus produced usable evidence, but qualification diagnostics remain.",
            evidenceCount: evidenceCount,
            limitationCount: diagnostics.count
        )
    }

    private func decisionHints(
        diagnostics: [LVSEvidenceDiagnostic],
        report: LVSCorpusReport
    ) -> [LVSEvidenceDecisionHint] {
        if diagnostics.isEmpty {
            return [
                LVSEvidenceDecisionHint(
                    hintID: "lvs-corpus-qualified",
                    priority: .low,
                    summary: "Use the qualified LVS corpus as a trusted native signoff evidence source.",
                    suggestedActions: ["use_lvs_evidence_for_repair_gate"]
                )
            ]
        }
        var groups: [String: [LVSEvidenceDiagnostic]] = [:]
        for diagnostic in diagnostics {
            groups[diagnostic.category, default: []].append(diagnostic)
        }
        return groups.keys.sorted().map { category in
            let groupedDiagnostics = groups[category] ?? []
            return LVSEvidenceDecisionHint(
                hintID: "lvs:\(category)",
                priority: priority(category: category, report: report),
                summary: summary(category: category, count: groupedDiagnostics.count),
                diagnosticIDs: groupedDiagnostics.map(\.diagnosticID),
                suggestedActions: suggestedActions(category: category)
            )
        }
    }

    private func summaryMetrics(_ report: LVSCorpusReport) -> [String: Double] {
        var values = [
            "passRate": report.summary.passRate,
            "durationBudgetPassRate": durationBudgetPassRate(report),
            "totalDurationSeconds": report.totalDurationSeconds,
        ]
        if let oracleAgreementRate = report.summary.oracleAgreementRate {
            values["oracleAgreementRate"] = oracleAgreementRate
        }
        return values
    }

    private func summaryCounts(_ report: LVSCorpusReport) -> [String: Int] {
        [
            "caseCount": report.caseCount,
            "matchedCaseCount": report.matchedCaseCount,
            "budgetExceededCaseCount": report.budgetExceededCaseCount,
            "durationBudgetPassedCaseCount": report.summary.durationBudgetPassedCaseCount,
            "primaryExecutionFailedCaseCount": report.summary.primaryExecutionFailedCaseCount,
            "oracleCaseCount": report.summary.oracleCaseCount,
            "oracleAgreementPassedCaseCount": report.summary.oracleAgreementPassedCaseCount,
            "oracleExecutionFailedCaseCount": report.summary.oracleExecutionFailedCaseCount,
            "oracleReadinessBlockedCaseCount": report.summary.oracleReadinessBlockedCaseCount,
            "coverageTagCount": report.summary.coverageTagCounts.count,
            "qualificationFailureCount": report.qualification.failures.count,
            "extractedLayoutNetlistCaseCount": report.caseResults.filter { $0.extractedLayoutNetlistPath != nil }.count,
        ]
    }

    private func durationBudgetPassRate(_ report: LVSCorpusReport) -> Double {
        report.caseCount == 0
            ? 0
            : Double(report.summary.durationBudgetPassedCaseCount) / Double(report.caseCount)
    }

    private func category(qualificationCode: String) -> String {
        switch qualificationCode {
        case "required_coverage_missing":
            return "coverage_gap"
        case "primary_execution_failed":
            return "primary_execution"
        case "oracle_execution_failed":
            return "oracle_execution"
        case "oracle_case_count_below_minimum",
             "oracle_agreement_rate_missing",
             "oracle_agreement_rate_below_minimum":
            return "oracle_agreement"
        case "duration_budget_pass_rate_below_minimum":
            return "duration_budget"
        case "pass_rate_below_minimum",
             "corpus_not_passed":
            return "corpus_gate"
        default:
            return "qualification_failure"
        }
    }

    private func category(ruleID: String) -> String {
        switch ruleID {
        case "LVS_PORT_MISMATCH", "LVS_TERMINAL_EQUIVALENCE_MISMATCH":
            return "port_mismatch"
        case "LVS_MODEL_MISMATCH":
            return "model_mismatch"
        case "LVS_PARAMETER_MISMATCH", "LVS_MULTIPLICITY_MISMATCH":
            return "parameter_mismatch"
        case "LVS_COMPONENT_COUNT_MISMATCH":
            return "component_count_mismatch"
        default:
            return "rule_set_mismatch"
        }
    }

    private func category(failureReason: String) -> String {
        if let separatorIndex = failureReason.firstIndex(of: ":") {
            return normalizedCategory(String(failureReason[..<separatorIndex]))
        }
        return normalizedCategory(failureReason)
    }

    private func normalizedCategory(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "port_mismatch", "pin_mismatch":
            return "port_mismatch"
        case "model_mismatch", "device_model_mismatch":
            return "model_mismatch"
        case "parameter_mismatch", "param_mismatch":
            return "parameter_mismatch"
        case "component_count_mismatch", "count_mismatch":
            return "component_count_mismatch"
        default:
            return normalized
        }
    }

    private func diagnosticFields(
        category: String,
        reason: String
    ) -> (
        componentSignature: String?,
        layoutModel: String?,
        schematicModel: String?,
        parameterName: String?,
        layoutValue: String?,
        schematicValue: String?,
        layoutPorts: [String],
        schematicPorts: [String]
    ) {
        let tokens = reason
            .replacingOccurrences(of: ";", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let componentSignature = value(after: "component", in: tokens)
        let layoutValue = value(after: "layout", in: tokens)
        let schematicValue = value(after: "schematic", in: tokens)
        switch category {
        case "model_mismatch":
            return (
                componentSignature: componentSignature,
                layoutModel: layoutValue,
                schematicModel: schematicValue,
                parameterName: nil,
                layoutValue: nil,
                schematicValue: nil,
                layoutPorts: [],
                schematicPorts: []
            )
        case "parameter_mismatch":
            return (
                componentSignature: componentSignature,
                layoutModel: nil,
                schematicModel: nil,
                parameterName: value(after: "parameter", in: tokens),
                layoutValue: layoutValue,
                schematicValue: schematicValue,
                layoutPorts: [],
                schematicPorts: []
            )
        case "port_mismatch":
            return (
                componentSignature: componentSignature,
                layoutModel: nil,
                schematicModel: nil,
                parameterName: nil,
                layoutValue: nil,
                schematicValue: nil,
                layoutPorts: listValue(after: "layout", in: tokens),
                schematicPorts: listValue(after: "schematic", in: tokens)
            )
        default:
            return (
                componentSignature: componentSignature,
                layoutModel: nil,
                schematicModel: nil,
                parameterName: nil,
                layoutValue: nil,
                schematicValue: nil,
                layoutPorts: [],
                schematicPorts: []
            )
        }
    }

    private func value(after marker: String, in tokens: [String]) -> String? {
        guard let index = tokens.firstIndex(of: marker) else { return nil }
        let valueIndex = index + 1
        guard valueIndex < tokens.count else { return nil }
        let value = tokens[valueIndex].trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
        return value.isEmpty ? nil : value
    }

    private func listValue(after marker: String, in tokens: [String]) -> [String] {
        guard let value = value(after: marker, in: tokens) else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func caseIDValidationFailure(_ rawCaseID: String) -> String? {
        let trimmed = rawCaseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "case ID is empty"
        }
        guard trimmed == rawCaseID else {
            return "case ID contains leading or trailing whitespace"
        }
        if rawCaseID.contains("://") {
            return "case ID contains a URL scheme"
        }
        if rawCaseID.hasPrefix("~") {
            return "case ID starts with a home-directory shortcut"
        }
        if rawCaseID.contains("/") || rawCaseID.contains("\\") {
            return "case ID contains path separators"
        }
        let components = (rawCaseID as NSString).pathComponents
        if components.contains(".") || components.contains("..") {
            return "case ID contains current-directory or parent-directory components"
        }
        if sanitizedIdentifierToken(rawCaseID) != rawCaseID {
            return "case ID contains characters outside the safe evidence namespace"
        }
        return nil
    }

    private func artifactPathValidationFailure(
        _ path: String,
        allowedArtifactRootPath: String?
    ) -> String? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return "path is empty"
        }
        guard trimmedPath == path else {
            return "path contains leading or trailing whitespace"
        }
        if path.contains("://") {
            return "path contains a URL scheme"
        }
        if path.hasPrefix("~") {
            return "path starts with a home-directory shortcut"
        }
        let components = (path as NSString).pathComponents
        if components.contains(".") || components.contains("..") {
            return "path contains current-directory or parent-directory components"
        }
        guard let allowedArtifactRootPath else {
            return nil
        }
        let rootURL = URL(filePath: allowedArtifactRootPath).standardizedFileURL
        let artifactURL = path.hasPrefix("/")
            ? URL(filePath: path).standardizedFileURL
            : rootURL.appendingPathComponent(path).standardizedFileURL
        let rootPath = rootURL.path(percentEncoded: false)
        let artifactPath = artifactURL.path(percentEncoded: false)
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        guard artifactPath == rootPath || artifactPath.hasPrefix(rootPrefix) else {
            return "path is outside the allowed LVS corpus artifact root"
        }
        return nil
    }

    private func caseIDDiagnostic(
        caseKey: String,
        issueID: String,
        caseID: String?,
        reason: String
    ) -> LVSEvidenceDiagnostic {
        LVSEvidenceDiagnostic(
            diagnosticID: "lvs-case:\(caseKey):\(issueID)",
            severity: .error,
            category: "artifact_integrity",
            message: reason,
            caseID: caseID,
            suggestedActions: artifactIntegritySuggestedActions()
        )
    }

    private func artifactPathDiagnostic(
        caseKey: String,
        caseID: String?,
        sourceField: String,
        rawPath: String,
        reason: String
    ) -> LVSEvidenceDiagnostic {
        LVSEvidenceDiagnostic(
            diagnosticID: "lvs-case:\(caseKey):\(sourceField):artifact-integrity",
            severity: .error,
            category: "artifact_integrity",
            message: "The LVS corpus artifact reference '\(rawPath)' is not safe to trust: \(reason)",
            caseID: caseID,
            componentSignature: rawPath,
            suggestedActions: artifactIntegritySuggestedActions()
        )
    }

    private func artifactIntegritySuggestedActions() -> [String] {
        [
            "inspect_lvs_corpus_artifact_paths",
            "regenerate_lvs_corpus_report",
        ]
    }

    private func sanitizedIdentifierToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        var result = ""
        var previousWasSeparator = false
        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    private func suggestedActions(category: String) -> [String] {
        switch category {
        case "artifact_integrity":
            return artifactIntegritySuggestedActions()
        case "primary_execution":
            return ["inspect_lvs_backend_logs", "verify_lvs_netlists_and_policy_inputs"]
        case "oracle_execution":
            return ["inspect_lvs_oracle_logs", "verify_lvs_oracle_tool_configuration"]
        case "oracle_readiness":
            return ["inspect_lvs_oracle_readiness", "inspect_lvs_oracle_logs"]
        case "oracle_agreement":
            return ["compare_native_and_oracle_lvs_diagnostics", "inspect_lvs_policy_mapping"]
        case "expectation_mismatch", "rule_set_mismatch":
            return ["inspect_expected_lvs_rule_ids", "inspect_native_lvs_diagnostic_mapping"]
        case "port_mismatch":
            return ["inspect_layout_and_schematic_ports", "consider_terminal_equivalence_policy"]
        case "model_mismatch":
            return ["inspect_device_model_mapping", "consider_model_equivalence_policy"]
        case "parameter_mismatch":
            return ["inspect_device_parameters", "consider_parameter_tolerance_policy"]
        case "component_count_mismatch":
            return ["inspect_extracted_layout_netlist", "inspect_schematic_device_count"]
        case "layout_extraction":
            return ["inspect_extracted_layout_netlist", "verify_layout_extraction_policy"]
        case "duration_budget":
            return ["inspect_lvs_case_runtime_and_hierarchy"]
        case "coverage_gap":
            return ["add_missing_lvs_corpus_coverage"]
        case "corpus_gate":
            return ["inspect_failing_lvs_corpus_cases"]
        default:
            return ["inspect_lvs_corpus_diagnostics"]
        }
    }

    private func priority(category: String, report: LVSCorpusReport) -> LVSEvidenceDecisionPriority {
        switch category {
        case "artifact_integrity", "primary_execution", "oracle_readiness", "oracle_execution":
            return .high
        case "oracle_agreement",
             "coverage_gap",
             "expectation_mismatch",
             "rule_set_mismatch",
             "port_mismatch",
             "model_mismatch",
             "parameter_mismatch",
             "component_count_mismatch",
             "corpus_gate":
            return .medium
        default:
            return report.qualification.qualified ? .low : .medium
        }
    }

    private func summary(category: String, count: Int) -> String {
        switch category {
        case "artifact_integrity":
            return "\(count) LVS evidence artifact integrity issue(s) must be fixed before trusting this packet."
        case "primary_execution":
            return "\(count) primary LVS execution issue(s) need backend or input inspection."
        case "oracle_execution":
            return "\(count) LVS oracle execution issue(s) need oracle tool inspection."
        case "oracle_readiness":
            return "\(count) LVS oracle readiness issue(s) blocked benchmark comparison."
        case "oracle_agreement":
            return "\(count) native-vs-oracle LVS agreement issue(s) need policy or extraction inspection."
        case "coverage_gap":
            return "\(count) LVS coverage gap(s) prevent qualification under the current policy."
        case "expectation_mismatch", "rule_set_mismatch":
            return "\(count) LVS expected-vs-observed diagnostic mismatch issue(s) need rule-ID inspection."
        case "port_mismatch":
            return "\(count) LVS port mismatch issue(s) need terminal or connectivity inspection."
        case "model_mismatch":
            return "\(count) LVS model mismatch issue(s) need model policy inspection."
        case "parameter_mismatch":
            return "\(count) LVS parameter mismatch issue(s) need parameter policy inspection."
        case "component_count_mismatch":
            return "\(count) LVS component count mismatch issue(s) need extracted netlist inspection."
        case "duration_budget":
            return "\(count) LVS duration budget issue(s) need runtime inspection."
        case "corpus_gate":
            return "\(count) LVS corpus gate issue(s) prevent qualification."
        default:
            return "\(count) LVS diagnostic issue(s) need inspection."
        }
    }
}
