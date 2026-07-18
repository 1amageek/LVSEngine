import CryptoKit
import Foundation
import LVSCore
import LVSNetlistParsing
import LayoutAutoGen
import LayoutCore
import LayoutIO
import LayoutLVSExtraction
import LayoutTech

public struct LVSCorpusRunner: Sendable {
    private struct ExecutionProbe: Sendable {
        let status: LVSCorpusAssertionStatus
        let observedValue: String?
        let sourceArtifactRefs: [String]
        let failureCode: String?
    }

    private let engine: DefaultLVSEngine

    public init(engine: DefaultLVSEngine = DefaultLVSEngine()) {
        self.engine = engine
    }

    public func run(
        specURL: URL,
        outputDirectory: URL,
        options: LVSCorpusRunOptions = LVSCorpusRunOptions()
    ) async throws -> LVSCorpusReport {
        let data: Data
        do {
            data = try Data(contentsOf: specURL)
        } catch {
            throw LVSError.invalidInput("Could not read LVS corpus spec: \(error.localizedDescription)")
        }
        let spec: LVSCorpusSpec
        do {
            spec = try JSONDecoder().decode(LVSCorpusSpec.self, from: data)
        } catch {
            throw LVSError.invalidInput("Could not decode LVS corpus spec: \(error.localizedDescription)")
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var caseResults: [LVSCorpusCaseResult] = []
        let specDirectory = specURL.deletingLastPathComponent()
        try validateBudget(spec.defaultMaxDurationSeconds, label: "defaultMaxDurationSeconds")
        try validateCaseIdentifiers(spec.cases)
        try validateQualificationScopeCaseID(spec.qualificationScopeCaseID, cases: spec.cases)

        for corpusCase in spec.cases {
            try validateBudget(corpusCase.maxDurationSeconds, label: "\(corpusCase.caseID).maxDurationSeconds")
            try validateHardExecutionBudget(corpusCase)
            let maxDurationSeconds = corpusCase.hardExecutionBudget?.maximumDurationSeconds
                ?? corpusCase.maxDurationSeconds
                ?? spec.defaultMaxDurationSeconds
            let caseDirectory = outputDirectory
                .appending(path: "cases")
                .appending(path: safePathComponent(corpusCase.caseID))
            try FileManager.default.createDirectory(at: caseDirectory, withIntermediateDirectories: true)
            let startedAt = Date()
            let preparedInputs: PreparedLVSCorpusInputs
            do {
                preparedInputs = try prepareInputs(
                    for: corpusCase,
                    specDirectory: specDirectory,
                    caseDirectory: caseDirectory
                )
            } catch {
                caseResults.append(failedCaseResult(
                    corpusCase: corpusCase,
                    expectedMaxDurationSeconds: maxDurationSeconds,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    error: error
                ))
                continue
            }
            let request: LVSRequest
            do {
                request = try makeRequest(
                    for: corpusCase,
                    specDirectory: specDirectory,
                    workingDirectory: caseDirectory,
                    preparedInputs: preparedInputs,
                    backendID: corpusCase.backendID ?? defaultBackendID(for: corpusCase)
                )
            } catch {
                caseResults.append(failedCaseResult(
                    corpusCase: corpusCase,
                    expectedMaxDurationSeconds: maxDurationSeconds,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    error: error
                ))
                continue
            }
            let executionResult: LVSExecutionResult
            do {
                executionResult = try await engine.run(request)
            } catch {
                let durationSeconds = Date().timeIntervalSince(startedAt)
                caseResults.append(failedCaseResult(
                    corpusCase: corpusCase,
                    expectedMaxDurationSeconds: maxDurationSeconds,
                    durationSeconds: durationSeconds,
                    error: error
                ))
                continue
            }
            let durationSeconds = Date().timeIntervalSince(startedAt)
            let determinismProbe = await runDeterminismProbeIfNeeded(
                corpusCase: corpusCase,
                request: request,
                primaryResult: executionResult,
                caseDirectory: caseDirectory
            )
            let cancellationProbe = await runCancellationProbeIfNeeded(
                corpusCase: corpusCase,
                request: request,
                caseDirectory: caseDirectory
            )
            let actualRuleIDs = activeErrorRuleIDs(in: executionResult.result.diagnostics)
            let primaryDiagnosticSummary = diagnosticSummary(executionResult.result.diagnostics)
            let primaryProvenance = provenance(for: executionResult)
            let expectedRuleIDs = corpusCase.expectedActiveErrorRuleIDs.sorted()
            let expectationMatched = executionResult.result.passed == corpusCase.expectedPassed
                && actualRuleIDs == expectedRuleIDs
            let durationBudgetPassed = maxDurationSeconds.map { durationSeconds <= $0 } ?? true
            let oracleResult = await runOracleIfNeeded(
                corpusCase: corpusCase,
                oracleBackendID: options.oracleBackendIDOverride ?? corpusCase.oracleBackendID,
                specDirectory: specDirectory,
                caseDirectory: caseDirectory,
                preparedInputs: preparedInputs,
                primaryPassed: executionResult.result.passed,
                primaryBackendID: executionResult.result.backendID,
                primaryImplementationIdentity: primaryProvenance?.implementationIdentity,
                primaryActiveRuleIDs: actualRuleIDs,
                primaryDiagnosticSummary: primaryDiagnosticSummary
            )
            let oracleComparison = oracleResult.map {
                self.oracleComparison(
                    primaryBackendID: executionResult.result.backendID,
                    primaryPassed: executionResult.result.passed,
                    primaryActiveRuleIDs: actualRuleIDs,
                    primaryDiagnostics: executionResult.result.diagnostics,
                    primaryDiagnosticSummary: primaryDiagnosticSummary,
                    primaryProvenance: primaryProvenance,
                    primaryDevicePolicyReport: executionResult.devicePolicyReport,
                    oracleResult: $0
                )
            }
            let oracleAgreementPassed = oracleResult?.agreementPassed ?? true
            let observedAssertions = observedAssertions(
                corpusCase: corpusCase,
                executionResult: executionResult,
                actualRuleIDs: actualRuleIDs,
                durationSeconds: durationSeconds,
                durationBudgetPassed: durationBudgetPassed,
                oracleResult: oracleResult,
                determinismProbe: determinismProbe,
                cancellationProbe: cancellationProbe,
                preparedInputs: preparedInputs
            )
            let assertionGatePassed = observedAssertions.allSatisfy { $0.status == .passed }
            let failureReasons = failureReasons(
                expectationMatched: expectationMatched && assertionGatePassed,
                durationBudgetPassed: durationBudgetPassed,
                oracleAgreementPassed: oracleAgreementPassed,
                oracleFailureReasons: oracleResult?.failureReasons ?? [],
                durationSeconds: durationSeconds,
                maxDurationSeconds: maxDurationSeconds
            )
            caseResults.append(LVSCorpusCaseResult(
                caseID: corpusCase.caseID,
                matched: expectationMatched && durationBudgetPassed && oracleAgreementPassed && assertionGatePassed,
                expectedPassed: corpusCase.expectedPassed,
                actualPassed: executionResult.result.passed,
                expectedActiveErrorRuleIDs: expectedRuleIDs,
                actualActiveErrorRuleIDs: actualRuleIDs,
                coverageTags: corpusCase.coverageTags,
                expectationMatched: expectationMatched,
                durationSeconds: durationSeconds,
                expectedMaxDurationSeconds: maxDurationSeconds,
                durationBudgetPassed: durationBudgetPassed,
                failureReasons: failureReasons,
                diagnosticSummary: primaryDiagnosticSummary,
                reportPath: executionResult.reportURL?.path(percentEncoded: false),
                manifestPath: executionResult.artifactManifestURL?.path(percentEncoded: false),
                extractedLayoutNetlistPath: executionResult.extractedLayoutNetlistURL?.path(percentEncoded: false),
                primaryProvenance: primaryProvenance,
                oracleResult: oracleResult,
                oracleComparison: oracleComparison,
                observedAssertions: observedAssertions
            ))
        }

        let report = LVSCorpusReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            passed: caseResults.allSatisfy(\.matched),
            caseCount: caseResults.count,
            matchedCaseCount: caseResults.filter(\.matched).count,
            budgetExceededCaseCount: caseResults.filter { !$0.durationBudgetPassed }.count,
            totalDurationSeconds: caseResults.reduce(0) { $0 + $1.durationSeconds },
            runOptions: options,
            qualificationScopeCaseID: spec.qualificationScopeCaseID,
            acceptanceCriteria: spec.acceptanceCriteria,
            caseResults: caseResults
        )
        let reportURL = outputDirectory.appending(path: "lvs-corpus-report.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let reportData = try encoder.encode(report)
        try reportData.write(to: reportURL, options: [.atomic])
        return report
    }

    private func validateBudget(_ value: Double?, label: String) throws {
        guard let value else { return }
        guard value.isFinite, value > 0 else {
            throw LVSError.invalidInput("\(label) must be positive finite seconds")
        }
    }

    private func validateQualificationScopeCaseID(
        _ qualificationScopeCaseID: String?,
        cases: [LVSCorpusCase]
    ) throws {
        guard let qualificationScopeCaseID else { return }
        guard !qualificationScopeCaseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LVSError.invalidInput("qualificationScopeCaseID must not be empty.")
        }
        guard cases.contains(where: { $0.caseID == qualificationScopeCaseID }) else {
            throw LVSError.invalidInput(
                "qualificationScopeCaseID does not reference a corpus case: \(qualificationScopeCaseID)"
            )
        }
    }

    private func validateHardExecutionBudget(_ corpusCase: LVSCorpusCase) throws {
        guard let budget = corpusCase.hardExecutionBudget else { return }
        guard budget.determinismRunCount > 0 else {
            throw LVSError.invalidInput(
                "\(corpusCase.caseID).hardExecutionBudget.determinismRunCount must be positive."
            )
        }
        for (label, value) in [
            ("maximumSearchStates", budget.maximumSearchStates),
            ("maximumSearchDepth", budget.maximumSearchDepth),
            ("maximumWorkingSetBytes", budget.maximumWorkingSetBytes),
        ] where value.map({ $0 <= 0 }) == true {
            throw LVSError.invalidInput(
                "\(corpusCase.caseID).hardExecutionBudget.\(label) must be positive."
            )
        }
        try validateBudget(
            budget.maximumDurationSeconds,
            label: "\(corpusCase.caseID).hardExecutionBudget.maximumDurationSeconds"
        )
    }

    private func validateCaseIdentifiers(_ cases: [LVSCorpusCase]) throws {
        var seenCaseIDs: Set<String> = []
        var seenDirectoryNames: [String: String] = [:]
        for corpusCase in cases {
            let trimmedCaseID = corpusCase.caseID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCaseID.isEmpty else {
                throw LVSError.invalidInput("LVS corpus caseID must not be empty.")
            }
            guard seenCaseIDs.insert(corpusCase.caseID).inserted else {
                throw LVSError.invalidInput("Duplicate LVS corpus caseID: \(corpusCase.caseID)")
            }
            let directoryName = safePathComponent(corpusCase.caseID)
            if let existingCaseID = seenDirectoryNames[directoryName] {
                throw LVSError.invalidInput(
                    "LVS corpus caseIDs '\(existingCaseID)' and '\(corpusCase.caseID)' map to the same output directory '\(directoryName)'."
                )
            }
            seenDirectoryNames[directoryName] = corpusCase.caseID
        }
    }

    private func runDeterminismProbeIfNeeded(
        corpusCase: LVSCorpusCase,
        request: LVSRequest,
        primaryResult: LVSExecutionResult,
        caseDirectory: URL
    ) async -> ExecutionProbe? {
        let requiredRuns = corpusCase.hardExecutionBudget?.determinismRunCount ?? 1
        let explicitlyRequired = corpusCase.requiredAssertions.contains { $0.kind == .determinism }
        guard requiredRuns > 1 || explicitlyRequired else { return nil }
        guard requiredRuns > 1 else {
            return ExecutionProbe(
                status: .passed,
                observedValue: "runs=1;stable=true",
                sourceArtifactRefs: primaryResult.artifactManifestURL.map {
                    [$0.path(percentEncoded: false)]
                } ?? [],
                failureCode: nil
            )
        }

        do {
            let primaryDigest = try normalizedResultDigest(from: primaryResult)
            var digests = [primaryDigest]
            var artifactRefs = primaryResult.artifactManifestURL.map {
                [$0.path(percentEncoded: false)]
            } ?? []
            for runIndex in 2...requiredRuns {
                let runDirectory = caseDirectory
                    .appending(path: "determinism")
                    .appending(path: "run-\(runIndex)")
                try FileManager.default.createDirectory(
                    at: runDirectory,
                    withIntermediateDirectories: true
                )
                let repeatedResult = try await engine.run(
                    requestWithWorkingDirectory(request, workingDirectory: runDirectory)
                )
                digests.append(try normalizedResultDigest(from: repeatedResult))
                if let manifestURL = repeatedResult.artifactManifestURL {
                    artifactRefs.append(manifestURL.path(percentEncoded: false))
                }
            }
            let stable = Set(digests).count == 1
            return ExecutionProbe(
                status: stable ? .passed : .failed,
                observedValue: "runs=\(digests.count);stable=\(stable)",
                sourceArtifactRefs: artifactRefs,
                failureCode: stable ? nil : "determinism_digest_mismatch"
            )
        } catch {
            return ExecutionProbe(
                status: .blocked,
                observedValue: nil,
                sourceArtifactRefs: [],
                failureCode: "determinism_probe_failed:\(executionErrorMessage(error))"
            )
        }
    }

    private func runCancellationProbeIfNeeded(
        corpusCase: LVSCorpusCase,
        request: LVSRequest,
        caseDirectory: URL
    ) async -> ExecutionProbe? {
        guard corpusCase.requiredAssertions.contains(where: { $0.kind == .cancellation }) else {
            return nil
        }
        let probeDirectory = caseDirectory.appending(path: "cancellation")
        do {
            try FileManager.default.createDirectory(
                at: probeDirectory,
                withIntermediateDirectories: true
            )
            _ = try await engine.run(
                requestWithWorkingDirectory(request, workingDirectory: probeDirectory),
                cancellationCheck: { true }
            )
            return ExecutionProbe(
                status: .failed,
                observedValue: "completed",
                sourceArtifactRefs: artifactManifestPaths(in: probeDirectory),
                failureCode: "cancellation_request_ignored"
            )
        } catch {
            let cancelled: Bool
            if let lvsError = error as? LVSError,
               case .cancelled = lvsError {
                cancelled = true
            } else {
                cancelled = error is CancellationError
            }
            return ExecutionProbe(
                status: cancelled ? .passed : .failed,
                observedValue: cancelled ? "cancelled" : "failed-with-non-cancellation-error",
                sourceArtifactRefs: artifactManifestPaths(in: probeDirectory),
                failureCode: cancelled ? nil : "cancellation_probe_failed:\(executionErrorMessage(error))"
            )
        }
    }

    private func normalizedResultDigest(from result: LVSExecutionResult) throws -> String {
        guard let manifestURL = result.artifactManifestURL else {
            throw LVSError.artifactWriteFailed("Determinism probe requires an LVS artifact manifest.")
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(LVSArtifactManifest.self, from: data)
        guard let digest = manifest.normalizedResultDigest,
              !digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LVSError.artifactWriteFailed(
                "Determinism probe manifest does not contain normalizedResultDigest."
            )
        }
        return digest
    }

    private func artifactManifestPaths(in directory: URL) -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter {
                $0.lastPathComponent.hasPrefix("lvs-artifact-manifest-")
                    && $0.pathExtension == "json"
            }.map { $0.path(percentEncoded: false) }.sorted()
        } catch {
            return []
        }
    }

    private func requestWithWorkingDirectory(
        _ request: LVSRequest,
        workingDirectory: URL
    ) -> LVSRequest {
        LVSRequest(
            layoutNetlistURL: request.layoutNetlistURL,
            layoutGDSURL: request.layoutGDSURL,
            layoutFormat: request.layoutFormat,
            schematicNetlistURL: request.schematicNetlistURL,
            topCell: request.topCell,
            technologyURL: request.technologyURL,
            extractionProfileURL: request.extractionProfileURL,
            extractionDeckURL: request.extractionDeckURL,
            processProfileID: request.processProfileID,
            waiverURL: request.waiverURL,
            modelEquivalenceURL: request.modelEquivalenceURL,
            terminalEquivalenceURL: request.terminalEquivalenceURL,
            devicePolicyURL: request.devicePolicyURL,
            workingDirectory: workingDirectory,
            backendSelection: request.backendSelection,
            options: request.options
        )
    }

    private func observedAssertions(
        corpusCase: LVSCorpusCase,
        executionResult: LVSExecutionResult,
        actualRuleIDs: [String],
        durationSeconds: Double,
        durationBudgetPassed: Bool,
        oracleResult: LVSCorpusOracleResult?,
        determinismProbe: ExecutionProbe?,
        cancellationProbe: ExecutionProbe?,
        preparedInputs: PreparedLVSCorpusInputs
    ) -> [LVSCorpusObservedAssertion] {
        let expectedVerdict = corpusCase.expectedVerdict
            ?? (corpusCase.expectedPassed ? .match : .mismatch)
        var requirements = corpusCase.requiredAssertions
        if requirements.isEmpty {
            requirements.append(LVSCorpusAssertionRequirement(
                assertionID: "verdict",
                kind: .verdict,
                expectedValue: expectedVerdict.rawValue
            ))
            requirements.append(LVSCorpusAssertionRequirement(
                assertionID: "duration-budget",
                kind: .durationBudget,
                expectedValue: "within-budget"
            ))
            requirements.append(contentsOf: corpusCase.expectedActiveErrorRuleIDs.map {
                LVSCorpusAssertionRequirement(
                    assertionID: "diagnostic-rule:\($0)",
                    kind: .diagnosticRule,
                    expectedValue: $0
                )
            })
            if corpusCase.hardExecutionBudget?.determinismRunCount ?? 1 > 1 {
                requirements.append(LVSCorpusAssertionRequirement(
                    assertionID: "determinism",
                    kind: .determinism,
                    expectedValue: "stable"
                ))
            }
        }
        let artifactRefs = [
            executionResult.reportURL,
            executionResult.artifactManifestURL,
            executionResult.correspondenceURL,
            executionResult.extractionReportURL,
            executionResult.transformLedgerURL,
        ].compactMap { $0?.path(percentEncoded: false) }
            + preparedInputs.devicePolicyArtifactURLs.map { $0.path(percentEncoded: false) }
        return requirements.map { requirement in
            let evaluation: (LVSCorpusAssertionStatus, String?, String?)
            switch requirement.kind {
            case .verdict:
                let observed = executionResult.result.verdict.rawValue
                evaluation = (
                    observed == requirement.expectedValue ? .passed : .failed,
                    observed,
                    observed == requirement.expectedValue ? nil : "verdict_mismatch"
                )
            case .faultClass:
                let observedClasses = Set(executionResult.result.diagnostics.compactMap {
                    $0.category ?? $0.ruleID
                })
                let matched = requirement.expectedValue.map(observedClasses.contains) == true
                evaluation = (
                    matched ? .passed : .failed,
                    observedClasses.sorted().joined(separator: ","),
                    matched ? nil : "fault_class_not_observed"
                )
            case .readiness:
                let observed = executionResult.result.readiness.rawValue
                evaluation = (
                    observed == requirement.expectedValue ? .passed : .failed,
                    observed,
                    observed == requirement.expectedValue ? nil : "readiness_mismatch"
                )
            case .diagnosticRule:
                let matched = requirement.expectedValue.map(actualRuleIDs.contains) == true
                evaluation = (
                    matched ? .passed : .failed,
                    actualRuleIDs.joined(separator: ","),
                    matched ? nil : "diagnostic_rule_not_observed"
                )
            case .reportArtifact:
                evaluation = artifactEvaluation(executionResult.reportURL, code: "report_artifact_missing")
            case .manifestArtifact:
                evaluation = artifactEvaluation(executionResult.artifactManifestURL, code: "manifest_artifact_missing")
            case .correspondenceArtifact:
                evaluation = artifactEvaluation(executionResult.correspondenceURL, code: "correspondence_artifact_missing")
            case .extractionArtifact:
                evaluation = artifactEvaluation(executionResult.extractionReportURL, code: "extraction_artifact_missing")
            case .extractionProfileReadiness:
                guard let evidence = executionResult.extractionEvidence else {
                    evaluation = (.blocked, nil, "extraction_evidence_missing")
                    break
                }
                evaluation = (
                    evidence.profileReady ? .passed : .failed,
                    evidence.profileReady ? "ready" : "notReady",
                    evidence.profileReady
                        ? nil
                        : "extraction_profile_incomplete:\(evidence.blockingReasonCodes.joined(separator: ","))"
                )
            case .structureClass:
                let observed = observedStructureClass(in: executionResult)
                guard let observed else {
                    evaluation = (.blocked, nil, "structure_class_unavailable")
                    break
                }
                evaluation = (
                    observed == requirement.expectedValue ? .passed : .failed,
                    observed,
                    observed == requirement.expectedValue ? nil : "structure_class_mismatch"
                )
            case .hierarchyDepth:
                guard let requiredText = requirement.expectedValue,
                      let requiredDepth = Int(requiredText),
                      let observedDepth = observedHierarchyDepth(in: executionResult) else {
                    evaluation = (.blocked, nil, "hierarchy_depth_unavailable")
                    break
                }
                evaluation = (
                    observedDepth >= requiredDepth ? .passed : .failed,
                    String(observedDepth),
                    observedDepth >= requiredDepth ? nil : "hierarchy_depth_below_required"
                )
            case .oracleAgreement:
                guard let oracleResult else {
                    evaluation = (.blocked, nil, "oracle_result_missing")
                    break
                }
                evaluation = (
                    oracleResult.agreementPassed ? .passed : .failed,
                    String(oracleResult.agreementPassed),
                    oracleResult.agreementPassed ? nil : "oracle_disagreement"
                )
            case .oracleIndependence:
                guard let oracleResult else {
                    evaluation = (.blocked, nil, "oracle_result_missing")
                    break
                }
                let independent = oracleResult.readinessStatus == .ready
                evaluation = (
                    independent ? .passed : .failed,
                    oracleResult.readinessStatus.rawValue,
                    independent ? nil : "oracle_not_independent"
                )
            case .durationBudget:
                evaluation = (
                    durationBudgetPassed ? .passed : .failed,
                    String(durationSeconds),
                    durationBudgetPassed ? nil : "duration_budget_exceeded"
                )
            case .searchBudget:
                let blocked = executionResult.result.blockingReasons.contains {
                    $0.code.contains("search") || $0.code.contains("match_budget")
                }
                evaluation = (blocked ? .failed : .passed, blocked ? "exceeded" : "within-budget", blocked ? "search_budget_exceeded" : nil)
            case .memoryBudget:
                let blocked = executionResult.result.blockingReasons.contains { $0.code.contains("memory") }
                evaluation = (blocked ? .failed : .passed, blocked ? "exceeded" : "within-budget", blocked ? "memory_budget_exceeded" : nil)
            case .cancellation:
                evaluation = cancellationProbe.map {
                    ($0.status, $0.observedValue, $0.failureCode)
                } ?? (.blocked, nil, "cancellation_probe_not_run")
            case .determinism:
                evaluation = determinismProbe.map {
                    ($0.status, $0.observedValue, $0.failureCode)
                } ?? (.passed, "runs=1;stable=true", nil)
            case .devicePolicyImport:
                guard let audit = preparedInputs.devicePolicyAudit else {
                    evaluation = (.blocked, nil, "device_policy_import_audit_missing")
                    break
                }
                let observed = audit.status.rawValue
                evaluation = (
                    observed == requirement.expectedValue ? .passed : .failed,
                    observed,
                    observed == requirement.expectedValue ? nil : "device_policy_import_incomplete"
                )
            case .devicePolicyApplication:
                guard let report = executionResult.devicePolicyReport else {
                    evaluation = (.blocked, nil, "device_policy_application_report_missing")
                    break
                }
                let observed = report.status.rawValue
                evaluation = (
                    observed == requirement.expectedValue ? .passed : .failed,
                    observed,
                    observed == requirement.expectedValue ? nil : "device_policy_application_incomplete"
                )
            case .devicePolicyRule:
                guard let expectedKind = requirement.expectedValue,
                      let report = executionResult.devicePolicyReport else {
                    evaluation = (.blocked, nil, "device_policy_rule_evidence_missing")
                    break
                }
                let count = report.policyRuleCountsByKind[expectedKind] ?? 0
                evaluation = (
                    count > 0 ? .passed : .failed,
                    "\(expectedKind)=\(count)",
                    count > 0 ? nil : "device_policy_rule_not_observed"
                )
            }
            return LVSCorpusObservedAssertion(
                assertionID: requirement.assertionID,
                kind: requirement.kind,
                status: evaluation.0,
                expectedValue: requirement.expectedValue,
                observedValue: evaluation.1,
                sourceArtifactRefs: assertionArtifactRefs(
                    baseArtifactRefs: artifactRefs,
                    kind: requirement.kind,
                    determinismProbe: determinismProbe,
                    cancellationProbe: cancellationProbe
                ),
                failureCode: evaluation.2
            )
        }
    }

    private func assertionArtifactRefs(
        baseArtifactRefs: [String],
        kind: LVSCorpusAssertionKind,
        determinismProbe: ExecutionProbe?,
        cancellationProbe: ExecutionProbe?
    ) -> [String] {
        let refs: [String]
        switch kind {
        case .determinism:
            refs = determinismProbe?.sourceArtifactRefs ?? []
        case .cancellation:
            refs = cancellationProbe?.sourceArtifactRefs ?? []
        default:
            refs = baseArtifactRefs
        }
        return Array(Set(refs)).sorted()
    }

    private func artifactEvaluation(
        _ url: URL?,
        code: String
    ) -> (LVSCorpusAssertionStatus, String?, String?) {
        guard let url else { return (.blocked, nil, code) }
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        return (exists ? .passed : .failed, url.path(percentEncoded: false), exists ? nil : code)
    }

    private func observedStructureClass(in executionResult: LVSExecutionResult) -> String? {
        guard let netlists = observedNetlists(in: executionResult) else { return nil }
        let analogKinds: Set<String> = [
            "resistor", "capacitor", "inductor", "diode", "bjt",
            "voltage-source", "current-source", "vcvs", "vccs", "cccs", "ccvs",
        ]
        let layoutKinds = Set(netlists.layout.components.map(\.kind))
        let schematicKinds = Set(netlists.schematic.components.map(\.kind))
        return !layoutKinds.isDisjoint(with: analogKinds)
            && !schematicKinds.isDisjoint(with: analogKinds)
            ? "analog"
            : "digital"
    }

    private func observedHierarchyDepth(in executionResult: LVSExecutionResult) -> Int? {
        guard let netlists = observedNetlists(in: executionResult) else { return nil }
        let layoutDepth = netlists.layout.components.map(hierarchyDepth).max() ?? 0
        let schematicDepth = netlists.schematic.components.map(hierarchyDepth).max() ?? 0
        return min(layoutDepth, schematicDepth)
    }

    private func observedNetlists(
        in executionResult: LVSExecutionResult
    ) -> (layout: NativeLVSNetlist, schematic: NativeLVSNetlist)? {
        guard let layoutURL = executionResult.request.layoutNetlistURL else { return nil }
        do {
            return (
                try NativeSPICENetlistParser().parse(
                    url: layoutURL,
                    expectedTopCell: executionResult.request.topCell
                ),
                try NativeSPICENetlistParser().parse(
                    url: executionResult.request.schematicNetlistURL,
                    expectedTopCell: executionResult.request.topCell
                )
            )
        } catch {
            return nil
        }
    }

    private func hierarchyDepth(_ component: NativeLVSNetlistComponent) -> Int {
        max(0, component.name.split(separator: "/").count - 1)
    }

    private func failureReasons(
        expectationMatched: Bool,
        durationBudgetPassed: Bool,
        oracleAgreementPassed: Bool,
        oracleFailureReasons: [String],
        durationSeconds: Double,
        maxDurationSeconds: Double?
    ) -> [String] {
        var reasons: [String] = []
        if !expectationMatched {
            reasons.append("expectation_mismatch")
        }
        if !durationBudgetPassed, let maxDurationSeconds {
            reasons.append("duration_exceeded:\(durationSeconds)>\(maxDurationSeconds)")
        }
        if !oracleAgreementPassed && !oracleFailureReasons.contains("oracle_agreement_mismatch") {
            reasons.append("oracle_agreement_mismatch")
        }
        for reason in oracleFailureReasons where !reasons.contains(reason) {
            reasons.append(reason)
        }
        return reasons
    }

    private func failedCaseResult(
        corpusCase: LVSCorpusCase,
        expectedMaxDurationSeconds: Double?,
        durationSeconds: Double,
        error: any Error
    ) -> LVSCorpusCaseResult {
        let message = executionErrorMessage(error)
        let durationBudgetPassed = expectedMaxDurationSeconds.map { durationSeconds <= $0 } ?? true
        var failureReasons = ["primary_execution_failed:\(message)"]
        if !durationBudgetPassed, let expectedMaxDurationSeconds {
            failureReasons.append("duration_exceeded:\(durationSeconds)>\(expectedMaxDurationSeconds)")
        }
        return LVSCorpusCaseResult(
            caseID: corpusCase.caseID,
            matched: false,
            expectedPassed: corpusCase.expectedPassed,
            actualPassed: false,
            expectedActiveErrorRuleIDs: corpusCase.expectedActiveErrorRuleIDs.sorted(),
            actualActiveErrorRuleIDs: [],
            coverageTags: corpusCase.coverageTags,
            expectationMatched: false,
            durationSeconds: durationSeconds,
            expectedMaxDurationSeconds: expectedMaxDurationSeconds,
            durationBudgetPassed: durationBudgetPassed,
            failureReasons: failureReasons,
            executionError: message,
            diagnosticSummary: zeroDiagnosticSummary(),
            reportPath: nil,
            manifestPath: nil,
            extractedLayoutNetlistPath: nil
        )
    }

    private func runOracleIfNeeded(
        corpusCase: LVSCorpusCase,
        oracleBackendID: String?,
        specDirectory: URL,
        caseDirectory: URL,
        preparedInputs: PreparedLVSCorpusInputs,
        primaryPassed: Bool,
        primaryBackendID: String,
        primaryImplementationIdentity: LVSImplementationIdentity?,
        primaryActiveRuleIDs: [String],
        primaryDiagnosticSummary: LVSDiagnosticSummary
    ) async -> LVSCorpusOracleResult? {
        guard let oracleBackendID else {
            return nil
        }
        let oracleDirectory = caseDirectory
            .appending(path: "oracle-\(safePathComponent(oracleBackendID))")
        let startedAt = Date()
        do {
            try FileManager.default.createDirectory(at: oracleDirectory, withIntermediateDirectories: true)
        } catch {
            return failedOracleResult(
                backendID: oracleBackendID,
                durationSeconds: Date().timeIntervalSince(startedAt),
                error: error
            )
        }
        let request: LVSRequest
        do {
            request = try makeRequest(
                for: corpusCase,
                specDirectory: specDirectory,
                workingDirectory: oracleDirectory,
                preparedInputs: preparedInputs,
                backendID: oracleBackendID
            )
        } catch {
            return failedOracleResult(
                backendID: oracleBackendID,
                durationSeconds: Date().timeIntervalSince(startedAt),
                error: error
            )
        }
        let executionResult: LVSExecutionResult
        do {
            executionResult = try await engine.run(request)
        } catch {
            return failedOracleResult(
                backendID: oracleBackendID,
                durationSeconds: Date().timeIntervalSince(startedAt),
                error: error
            )
        }
        let durationSeconds = Date().timeIntervalSince(startedAt)
        let oracleRuleIDs = activeErrorRuleIDs(in: executionResult.result.diagnostics)
        let oracleDiagnosticSummary = diagnosticSummary(executionResult.result.diagnostics)
        let oracleProvenance = provenance(for: executionResult)
        let distinctBackend = executionResult.result.backendID
            .caseInsensitiveCompare(primaryBackendID) != .orderedSame
        let independentImplementationIdentity = primaryImplementationIdentity.map { primaryIdentity in
            oracleProvenance?.implementationIdentity?.isIndependent(from: primaryIdentity) == true
        } ?? false
        let independentImplementation = distinctBackend && independentImplementationIdentity
        let readinessDiagnostics: [String]
        if !distinctBackend {
            readinessDiagnostics = [
                "The oracle backend is the same backend used by the primary comparison."
            ]
        } else if !independentImplementation {
            readinessDiagnostics = [
                "The oracle implementation identity is missing or is not independent from the primary implementation."
            ]
        } else {
            readinessDiagnostics = []
        }
        let passedMatched = executionResult.result.passed == primaryPassed
        let ruleIDsMatched = oracleRuleIDs == primaryActiveRuleIDs
        let diagnosticSummaryMatched = oracleDiagnosticSummary == primaryDiagnosticSummary
        let enforcedRuleIDsMatched = corpusCase.oracleComparisonMode == .verdict
            ? true
            : ruleIDsMatched
        let enforcedDiagnosticSummaryMatched = corpusCase.oracleComparisonMode == .strictDiagnostics
            ? diagnosticSummaryMatched
            : true
        let agreementPassed = passedMatched
            && enforcedRuleIDsMatched
            && enforcedDiagnosticSummaryMatched
        let comparison = LVSCorpusOracleComparison(
            primaryBackendID: primaryBackendID,
            oracleBackendID: executionResult.result.backendID,
            passedMatched: passedMatched,
            activeErrorRuleIDsMatched: enforcedRuleIDsMatched,
            diagnosticSummaryMatched: enforcedDiagnosticSummaryMatched,
            primaryPassed: primaryPassed,
            oraclePassed: executionResult.result.passed,
            primaryActiveErrorRuleIDs: primaryActiveRuleIDs,
            oracleActiveErrorRuleIDs: oracleRuleIDs,
            primaryDiagnosticSummary: primaryDiagnosticSummary,
            oracleDiagnosticSummary: oracleDiagnosticSummary,
            mismatchReasons: agreementPassed ? [] : oracleMismatchReasons(
                primaryPassed: primaryPassed,
                oraclePassed: executionResult.result.passed,
                primaryActiveRuleIDs: primaryActiveRuleIDs,
                oracleActiveRuleIDs: oracleRuleIDs,
                primaryDiagnosticSummary: primaryDiagnosticSummary,
                oracleDiagnosticSummary: oracleDiagnosticSummary,
                oracleFailureReasons: ["oracle_agreement_mismatch"]
            )
        )
        return LVSCorpusOracleResult(
            backendID: executionResult.result.backendID,
            passed: executionResult.result.passed,
            activeErrorRuleIDs: oracleRuleIDs,
            diagnostics: executionResult.result.diagnostics,
            diagnosticSummary: oracleDiagnosticSummary,
            durationSeconds: durationSeconds,
            agreementPassed: comparison.agreementPassed,
            readinessStatus: independentImplementation ? .ready : .blocked,
            readinessDiagnostics: readinessDiagnostics,
            failureReasons: comparison.mismatchReasons,
            executionError: nil,
            reportPath: executionResult.reportURL?.path(percentEncoded: false),
            manifestPath: executionResult.artifactManifestURL?.path(percentEncoded: false),
            extractedLayoutNetlistPath: executionResult.extractedLayoutNetlistURL?.path(percentEncoded: false),
            devicePolicyReport: executionResult.devicePolicyReport,
            provenance: oracleProvenance
        )
    }

    private func failedOracleResult(
        backendID: String,
        durationSeconds: Double,
        error: any Error
    ) -> LVSCorpusOracleResult {
        let message = executionErrorMessage(error)
        return LVSCorpusOracleResult(
            backendID: backendID,
            passed: false,
            activeErrorRuleIDs: [],
            diagnosticSummary: zeroDiagnosticSummary(),
            durationSeconds: durationSeconds,
            agreementPassed: false,
            readinessStatus: .blocked,
            readinessDiagnostics: [message],
            failureReasons: ["oracle_execution_failed:\(message)"],
            executionError: message,
            reportPath: nil,
            manifestPath: nil,
            extractedLayoutNetlistPath: nil
        )
    }

    private func provenance(for executionResult: LVSExecutionResult) -> LVSCorpusCaseProvenance? {
        let initialIdentity = implementationIdentity(
            for: executionResult,
            manifest: nil
        )
        guard let manifestURL = executionResult.artifactManifestURL else {
            return LVSCorpusCaseProvenance(
                backendID: executionResult.result.backendID,
                reportPath: executionResult.reportURL?.path(percentEncoded: false),
                manifestPath: nil,
                extractedLayoutNetlistPath: executionResult.extractedLayoutNetlistURL?.path(percentEncoded: false),
                implementationIdentity: initialIdentity
            )
        }
        let manifest: LVSArtifactManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(LVSArtifactManifest.self, from: data)
        } catch {
            return LVSCorpusCaseProvenance(
                backendID: executionResult.result.backendID,
                reportPath: executionResult.reportURL?.path(percentEncoded: false),
                manifestPath: manifestURL.path(percentEncoded: false),
                extractedLayoutNetlistPath: executionResult.extractedLayoutNetlistURL?.path(percentEncoded: false),
                implementationIdentity: initialIdentity
            )
        }

        return LVSCorpusCaseProvenance(
            backendID: executionResult.result.backendID,
            inputArtifacts: manifest.inputs,
            outputArtifacts: manifest.outputs,
            reportPath: executionResult.reportURL?.path(percentEncoded: false),
            manifestPath: manifestURL.path(percentEncoded: false),
            extractedLayoutNetlistPath: executionResult.extractedLayoutNetlistURL?.path(percentEncoded: false),
            implementationIdentity: implementationIdentity(for: executionResult, manifest: manifest)
        )
    }

    private func implementationIdentity(
        for executionResult: LVSExecutionResult,
        manifest: LVSArtifactManifest?
    ) -> LVSImplementationIdentity {
        let backendID = executionResult.result.backendID
        let executablePath = executionResult.result.provenance?.executablePath ?? "in-process"
        let executableURL: URL?
        if executablePath == "in-process" {
            executableURL = Bundle.main.executableURL
                ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        } else {
            executableURL = URL(fileURLWithPath: executablePath)
        }
        let technologyDigest = manifest?.inputs.first { $0.kind == .technology }?.sha256
            ?? digestIfReadable(executionResult.request.technologyURL)
        let setupDigest = executionResult.result.provenance.flatMap {
            digestIfReadable(URL(fileURLWithPath: $0.setupFilePath))
        }
        return LVSImplementationIdentity(
            implementationID: implementationFamily(for: backendID),
            binaryDigest: digestIfReadable(executableURL) ?? "",
            algorithmVersion: algorithmVersion(for: backendID),
            processProfileID: executionResult.request.processProfileID
                ?? executionResult.extractionEvidence?.processProfileID
                ?? technologyDigest
                ?? "process-neutral",
            deckDigest: executionResult.extractionEvidence?.deckDigest
                ?? setupDigest
                ?? technologyDigest
                ?? "no-deck"
        )
    }

    private func implementationFamily(for backendID: String) -> String {
        switch backendID {
        case "native", "native-gds":
            return "lvsengine-native"
        case "netgen":
            return "netgen-external"
        default:
            return backendID
        }
    }

    private func algorithmVersion(for backendID: String) -> String {
        switch backendID {
        case "native":
            return "canonical-graph-v2"
        case "native-gds":
            return "layout-extraction-canonical-graph-v2"
        case "netgen":
            return "netgen-subprocess"
        default:
            return "backend-contract-v2:\(backendID)"
        }
    }

    private func digestIfReadable(_ url: URL?) -> String? {
        guard let url, !url.path(percentEncoded: false).isEmpty else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }

    private func oracleComparison(
        primaryBackendID: String,
        primaryPassed: Bool,
        primaryActiveRuleIDs: [String],
        primaryDiagnostics: [LVSDiagnostic],
        primaryDiagnosticSummary: LVSDiagnosticSummary,
        primaryProvenance: LVSCorpusCaseProvenance?,
        primaryDevicePolicyReport: LVSDevicePolicyApplicationReport?,
        oracleResult: LVSCorpusOracleResult
    ) -> LVSCorpusOracleComparison {
        let mismatchReasons = oracleMismatchReasons(
            primaryPassed: primaryPassed,
            oraclePassed: oracleResult.passed,
            primaryActiveRuleIDs: primaryActiveRuleIDs,
            oracleActiveRuleIDs: oracleResult.activeErrorRuleIDs,
            primaryDiagnosticSummary: primaryDiagnosticSummary,
            oracleDiagnosticSummary: oracleResult.diagnosticSummary,
            oracleFailureReasons: oracleResult.failureReasons
        )
        let classifications = LVSDisagreementClassifier().classify(
            primaryBackendID: primaryBackendID,
            oracleBackendID: oracleResult.backendID,
            primaryPassed: primaryPassed,
            oraclePassed: oracleResult.passed,
            primaryDiagnostics: primaryDiagnostics,
            oracleDiagnostics: oracleResult.diagnostics,
            oracleExecutionError: oracleResult.executionError,
            oracleReadinessStatus: oracleResult.readinessStatus,
            primaryProvenance: primaryProvenance,
            oracleProvenance: oracleResult.provenance,
            primaryDevicePolicyReport: primaryDevicePolicyReport,
            oracleDevicePolicyReport: oracleResult.devicePolicyReport,
            mismatchReasons: mismatchReasons
        )
        return LVSCorpusOracleComparison(
            primaryBackendID: primaryBackendID,
            oracleBackendID: oracleResult.backendID,
            passedMatched: primaryPassed == oracleResult.passed,
            activeErrorRuleIDsMatched: primaryActiveRuleIDs == oracleResult.activeErrorRuleIDs,
            diagnosticSummaryMatched: primaryDiagnosticSummary == oracleResult.diagnosticSummary,
            primaryPassed: primaryPassed,
            oraclePassed: oracleResult.passed,
            primaryActiveErrorRuleIDs: primaryActiveRuleIDs,
            oracleActiveErrorRuleIDs: oracleResult.activeErrorRuleIDs,
            primaryDiagnosticSummary: primaryDiagnosticSummary,
            oracleDiagnosticSummary: oracleResult.diagnosticSummary,
            mismatchReasons: mismatchReasons,
            disagreementClassifications: classifications
        )
    }

    private func oracleMismatchReasons(
        primaryPassed: Bool,
        oraclePassed: Bool,
        primaryActiveRuleIDs: [String],
        oracleActiveRuleIDs: [String],
        primaryDiagnosticSummary: LVSDiagnosticSummary,
        oracleDiagnosticSummary: LVSDiagnosticSummary,
        oracleFailureReasons: [String]
    ) -> [String] {
        var reasons: [String] = []
        if primaryPassed != oraclePassed {
            reasons.append("passed_mismatch")
        }
        if primaryActiveRuleIDs != oracleActiveRuleIDs {
            reasons.append("active_error_rule_ids_mismatch")
        }
        if primaryDiagnosticSummary != oracleDiagnosticSummary {
            reasons.append("diagnostic_summary_mismatch")
        }
        for reason in oracleFailureReasons where !reasons.contains(reason) {
            reasons.append(reason)
        }
        return reasons
    }

    private func activeErrorRuleIDs(in diagnostics: [LVSDiagnostic]) -> [String] {
        diagnostics
            .filter { $0.severity == .error && !$0.isWaived }
            .map { $0.ruleID ?? "unclassified" }
            .sorted()
    }

    private func diagnosticSummary(_ diagnostics: [LVSDiagnostic]) -> LVSDiagnosticSummary {
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

    private func zeroDiagnosticSummary() -> LVSDiagnosticSummary {
        LVSDiagnosticSummary(infoCount: 0, warningCount: 0, errorCount: 0)
    }

    private func executionErrorMessage(_ error: any Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func defaultBackendID(for corpusCase: LVSCorpusCase) -> String {
        if corpusCase.generatedLayoutFixture != nil {
            return "native-gds"
        }
        if corpusCase.layoutNetlistPath != nil {
            return "native"
        }
        if corpusCase.technologyPath != nil {
            return "native-gds"
        }
        return "netgen"
    }

    private func makeRequest(
        for corpusCase: LVSCorpusCase,
        specDirectory: URL,
        workingDirectory: URL,
        preparedInputs: PreparedLVSCorpusInputs,
        backendID: String
    ) throws -> LVSRequest {
        LVSRequest(
            layoutNetlistURL: preparedInputs.layoutNetlistURL,
            layoutGDSURL: preparedInputs.layoutGDSURL,
            layoutFormat: preparedInputs.layoutFormat,
            schematicNetlistURL: try resolveCorpusInputPath(
                corpusCase.schematicNetlistPath,
                label: "\(corpusCase.caseID).schematicNetlistPath",
                relativeTo: specDirectory
            ),
            topCell: corpusCase.topCell,
            technologyURL: preparedInputs.technologyURL,
            extractionProfileURL: preparedInputs.extractionProfileURL,
            extractionDeckURL: preparedInputs.extractionDeckURL,
            processProfileID: corpusCase.processProfileID,
            waiverURL: try corpusCase.waiverPath.map {
                try resolveCorpusInputPath(
                    $0,
                    label: "\(corpusCase.caseID).waiverPath",
                    relativeTo: specDirectory
                )
            },
            modelEquivalenceURL: try corpusCase.modelEquivalencePath.map {
                try resolveCorpusInputPath(
                    $0,
                    label: "\(corpusCase.caseID).modelEquivalencePath",
                    relativeTo: specDirectory
                )
            },
            terminalEquivalenceURL: try corpusCase.terminalEquivalencePath.map {
                try resolveCorpusInputPath(
                    $0,
                    label: "\(corpusCase.caseID).terminalEquivalencePath",
                    relativeTo: specDirectory
                )
            },
            devicePolicyURL: backendID == "native" || backendID == "native-gds"
                ? preparedInputs.devicePolicyURL
                : nil,
            workingDirectory: workingDirectory,
            backendSelection: LVSBackendSelection(backendID: backendID),
            options: LVSOptions(
                timeoutSeconds: corpusCase.hardExecutionBudget?.maximumDurationSeconds ?? 300,
                maximumSearchStates: corpusCase.hardExecutionBudget?.maximumSearchStates,
                maximumGraphObjectCount: nil,
                maximumSearchDepth: corpusCase.hardExecutionBudget?.maximumSearchDepth,
                maximumWorkingSetBytes: corpusCase.hardExecutionBudget?.maximumWorkingSetBytes
            )
        )
    }

    private func resolveCorpusInputPath(
        _ path: String,
        label: String,
        relativeTo base: URL
    ) throws -> URL {
        if path.hasPrefix("pdk://") {
            guard let pdkRoot = ProcessInfo.processInfo.environment["PDK_ROOT"],
                  !pdkRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LVSError.invalidInput("\(label) requires PDK_ROOT for its pdk:// reference.")
            }
            let relativePath = String(path.dropFirst("pdk://".count))
            let components = try checkedRelativePathComponents(relativePath, label: label)
            let root = URL(filePath: pdkRoot).standardizedFileURL
            let resolved = components.reduce(root) { partial, component in
                partial.appending(path: component)
            }.standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/") else {
                throw LVSError.invalidInput("\(label) escapes PDK_ROOT.")
            }
            return resolved
        }
        let components = try checkedRelativePathComponents(path, label: label)
        return components.reduce(base) { partial, component in
            partial.appending(path: component)
        }
    }

    private func prepareInputs(
        for corpusCase: LVSCorpusCase,
        specDirectory: URL,
        caseDirectory: URL
    ) throws -> PreparedLVSCorpusInputs {
        let preparedDevicePolicy = try prepareDevicePolicy(
            for: corpusCase,
            specDirectory: specDirectory,
            caseDirectory: caseDirectory
        )
        guard let fixture = corpusCase.generatedLayoutFixture else {
            return PreparedLVSCorpusInputs(
                layoutNetlistURL: try corpusCase.layoutNetlistPath.map {
                    try resolveCorpusInputPath(
                        $0,
                        label: "\(corpusCase.caseID).layoutNetlistPath",
                        relativeTo: specDirectory
                    )
                },
                layoutGDSURL: try corpusCase.layoutGDSPath.map {
                    try resolveCorpusInputPath(
                        $0,
                        label: "\(corpusCase.caseID).layoutGDSPath",
                        relativeTo: specDirectory
                    )
                },
                layoutFormat: corpusCase.layoutFormat,
                technologyURL: try corpusCase.technologyPath.map {
                    try resolveCorpusInputPath(
                        $0,
                        label: "\(corpusCase.caseID).technologyPath",
                        relativeTo: specDirectory
                    )
                },
                extractionProfileURL: try corpusCase.extractionProfilePath.map {
                    try resolveCorpusInputPath(
                        $0,
                        label: "\(corpusCase.caseID).extractionProfilePath",
                        relativeTo: specDirectory
                    )
                },
                extractionDeckURL: try corpusCase.extractionDeckPath.map {
                    try resolveCorpusInputPath(
                        $0,
                        label: "\(corpusCase.caseID).extractionDeckPath",
                        relativeTo: specDirectory
                    )
                },
                devicePolicyURL: preparedDevicePolicy.policyURL,
                devicePolicyAudit: preparedDevicePolicy.audit,
                devicePolicyArtifactURLs: preparedDevicePolicy.artifactURLs
            )
        }

        let generatedDirectory = caseDirectory.appending(path: "generated-inputs")
        try FileManager.default.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)
        let technology = try generatedTechnology(named: fixture.technology)
        let technologyURL = generatedDirectory.appending(path: "technology.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(technology).write(to: technologyURL, options: [.atomic])

        let extractionDeckURL = generatedDirectory.appending(path: "extraction.deck")
        let extractionDeckData = Data("generated-mos-fixture-deck-v1".utf8)
        try extractionDeckData.write(to: extractionDeckURL, options: [.atomic])
        let extractionDeckDigest = SHA256.hash(data: extractionDeckData)
            .map { String(format: "%02x", $0) }
            .joined()
        let fixtureProfile = GeneratedMOSLayoutExtractionProfileFactory().makeProfile()
        let extractionProfile = LayoutExtractionProcessProfile(
            processID: fixtureProfile.processID,
            processProfileID: fixtureProfile.processProfileID,
            extractionDeckDigest: extractionDeckDigest,
            productionEligible: fixtureProfile.productionEligible,
            parameterValueConvention: fixtureProfile.parameterValueConvention,
            conductorLayers: fixtureProfile.conductorLayers,
            connectionRules: fixtureProfile.connectionRules,
            mosRules: fixtureProfile.mosRules
        )
        let extractionProfileURL = generatedDirectory.appending(path: "extraction-profile.json")
        try encoder.encode(extractionProfile).write(to: extractionProfileURL, options: [.atomic])

        let layoutFormat = corpusCase.layoutFormat ?? fixture.format
        let layoutURL = try generatedOutputURL(
            path: corpusCase.layoutGDSPath ?? "generated-layout",
            format: layoutFormat,
            in: generatedDirectory
        )
        let document = try generatedLayoutDocument(for: fixture, technology: technology)
        try MaskDataFormatConverter(tech: technology).exportDocument(
            document,
            to: layoutURL,
            format: layoutFileFormat(for: layoutFormat)
        )

        return PreparedLVSCorpusInputs(
            layoutNetlistURL: nil,
            layoutGDSURL: layoutURL,
            layoutFormat: layoutFormat,
            technologyURL: technologyURL,
            extractionProfileURL: extractionProfileURL,
            extractionDeckURL: extractionDeckURL,
            devicePolicyURL: preparedDevicePolicy.policyURL,
            devicePolicyAudit: preparedDevicePolicy.audit,
            devicePolicyArtifactURLs: preparedDevicePolicy.artifactURLs
        )
    }

    private func prepareDevicePolicy(
        for corpusCase: LVSCorpusCase,
        specDirectory: URL,
        caseDirectory: URL
    ) throws -> PreparedLVSCorpusDevicePolicy {
        if corpusCase.devicePolicyPath != nil, corpusCase.devicePolicyDeckPath != nil {
            throw LVSError.invalidInput(
                "\(corpusCase.caseID) cannot declare both devicePolicyPath and devicePolicyDeckPath."
            )
        }
        if let path = corpusCase.devicePolicyPath {
            let url = try resolveCorpusInputPath(
                path,
                label: "\(corpusCase.caseID).devicePolicyPath",
                relativeTo: specDirectory
            )
            return PreparedLVSCorpusDevicePolicy(
                policyURL: url,
                audit: nil,
                artifactURLs: [url]
            )
        }
        guard let deckPath = corpusCase.devicePolicyDeckPath else {
            return PreparedLVSCorpusDevicePolicy(policyURL: nil, audit: nil, artifactURLs: [])
        }
        let deckURL = try resolveCorpusInputPath(
            deckPath,
            label: "\(corpusCase.caseID).devicePolicyDeckPath",
            relativeTo: specDirectory
        )
        let imported = try NetgenLVSDeviceDeckImporter.importDeviceDeck(from: deckURL)
        let policyDirectory = caseDirectory.appending(path: "generated-device-policy")
        try FileManager.default.createDirectory(at: policyDirectory, withIntermediateDirectories: true)
        let policyURL = policyDirectory.appending(path: "lvs-device-policy.json")
        let reportURL = policyDirectory.appending(path: "lvs-device-import-report.json")
        let auditURL = policyDirectory.appending(path: "lvs-device-import-audit.json")
        let audit = NetgenLVSDeviceDeckImportAuditor().audit(
            seed: imported.seed,
            report: imported.report,
            seedPath: policyURL.path(percentEncoded: false),
            reportPath: reportURL.path(percentEncoded: false)
        )
        guard imported.report.status == .complete, audit.status == .satisfied else {
            throw LVSError.invalidInput(
                "\(corpusCase.caseID) device policy deck did not satisfy the import gate."
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(imported.seed).write(to: policyURL, options: [.atomic])
        try encoder.encode(imported.report).write(to: reportURL, options: [.atomic])
        try encoder.encode(audit).write(to: auditURL, options: [.atomic])
        return PreparedLVSCorpusDevicePolicy(
            policyURL: policyURL,
            audit: audit,
            artifactURLs: [deckURL, policyURL, reportURL, auditURL]
        )
    }

    private func generatedTechnology(named name: String) throws -> LayoutTechDatabase {
        switch name {
        case "sampleProcess":
            return LayoutTechDatabase.sampleProcess()
        default:
            throw LVSError.invalidInput("Unsupported generated LVS technology fixture: \(name)")
        }
    }

    private func generatedLayoutDocument(
        for fixture: LVSGeneratedLayoutFixture,
        technology: LayoutTechDatabase
    ) throws -> LayoutDocument {
        switch fixture.kind {
        case "sampleProcessNMOS":
            return try generatedSingleDeviceDocument(deviceKindID: "nmos", technology: technology)
        case "sampleProcessPMOS":
            return try generatedSingleDeviceDocument(deviceKindID: "pmos", technology: technology)
        case "sampleProcessCMOSInverter":
            return try generatedCMOSInverterDocument(technology: technology)
        case "sampleProcessParallelNMOS":
            return try generatedParallelNMOSDocument(technology: technology)
        case "sampleProcessSeriesNMOS":
            return try generatedSeriesNMOSDocument(technology: technology)
        default:
            throw LVSError.invalidInput("Unsupported generated LVS layout fixture: \(fixture.kind)")
        }
    }

    private func generatedSingleDeviceDocument(
        deviceKindID: String,
        technology: LayoutTechDatabase
    ) throws -> LayoutDocument {
        var cell = try generatedDeviceCell(
            deviceKindID: deviceKindID,
            instanceName: "M1",
            netByPin: ["drain": "d", "gate": "g", "source": "s", "bulk": "b"],
            technology: technology
        )
        cell.name = "TOP"
        return LayoutDocument(name: "TOP", cells: [cell], topCellID: cell.id)
    }

    private func generatedCMOSInverterDocument(technology: LayoutTechDatabase) throws -> LayoutDocument {
        let nmos = try generatedDeviceCell(
            deviceKindID: "nmos",
            instanceName: "M2",
            netByPin: ["drain": "out", "gate": "in", "source": "vss", "bulk": "vss"],
            technology: technology
        )
        let pmos = try generatedDeviceCell(
            deviceKindID: "pmos",
            instanceName: "M1",
            netByPin: ["drain": "out", "gate": "in", "source": "vdd", "bulk": "vdd"],
            technology: technology
        )
        let nmosPlaced = translatedCell(nmos, by: .zero)
        let nmosBox = try boundingBox(of: nmosPlaced)
        let pmosBox = try boundingBox(of: pmos)
        let pmosPlaced = translatedCell(
            pmos,
            by: LayoutPoint(x: 0, y: nmosBox.maxY - pmosBox.minY + 2.0)
        )
        let metal1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let metal1Width = max(technology.ruleSet(for: metal1)?.minWidth ?? 0.2, 0.2)
        let routes = try [
            bridge(
                between: pin("gate", in: nmosPlaced).position,
                and: pin("gate", in: pmosPlaced).position,
                width: metal1Width,
                layer: metal1
            ),
            bridge(
                between: pin("drain", in: nmosPlaced).position,
                and: pin("drain", in: pmosPlaced).position,
                width: metal1Width,
                layer: metal1
            ),
            bridge(
                between: pin("source", in: nmosPlaced).position,
                and: pin("bulk", in: nmosPlaced).position,
                width: metal1Width,
                layer: metal1
            ),
            bridge(
                between: pin("source", in: pmosPlaced).position,
                and: pin("bulk", in: pmosPlaced).position,
                width: metal1Width,
                layer: metal1
            ),
        ].flatMap { $0 }
        let top = LayoutCell(
            name: "TOP",
            shapes: nmosPlaced.shapes + pmosPlaced.shapes + routes,
            vias: nmosPlaced.vias + pmosPlaced.vias,
            labels: nmosPlaced.labels + pmosPlaced.labels
        )
        return LayoutDocument(name: "TOP", cells: [top], topCellID: top.id)
    }

    private func generatedParallelNMOSDocument(technology: LayoutTechDatabase) throws -> LayoutDocument {
        var nmos = try generatedDeviceCell(
            deviceKindID: "nmos",
            instanceName: "MARRAY",
            netByPin: ["drain": "d", "gate": "g", "source": "s", "bulk": "s"],
            technology: technology
        )
        nmos.name = "NMOS_ARRAY_DEVICE"

        let nmosBox = try boundingBox(of: nmos)
        let secondOffset = LayoutPoint(x: 0, y: nmosBox.maxY - nmosBox.minY + 2.0)
        let baseTransform = LayoutTransform()
        let secondTransform = LayoutTransform(translation: secondOffset)
        let metal1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let metal2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let metal1Width = max(technology.ruleSet(for: metal1)?.minWidth ?? 0.2, 0.2)
        let metal2Width = max(technology.ruleSet(for: metal2)?.minWidth ?? 0.28, 0.28)
        let metal2Routes = try [
            bridgeWithVias(
                between: pinPosition("drain", in: nmos, transform: baseTransform),
                and: pinPosition("drain", in: nmos, transform: secondTransform),
                width: metal2Width,
                layer: metal2
            ),
            bridgeWithVias(
                between: pinPosition("gate", in: nmos, transform: baseTransform),
                and: pinPosition("gate", in: nmos, transform: secondTransform),
                width: metal2Width,
                layer: metal2
            ),
            bridgeWithVias(
                between: pinPosition("source", in: nmos, transform: baseTransform),
                and: pinPosition("source", in: nmos, transform: secondTransform),
                width: metal2Width,
                layer: metal2
            ),
        ]
        let sourceBulkRoutes = try [
            bridge(
                between: pinPosition("source", in: nmos, transform: baseTransform),
                and: pinPosition("bulk", in: nmos, transform: baseTransform),
                width: metal1Width,
                layer: metal1
            ),
            bridge(
                between: pinPosition("source", in: nmos, transform: secondTransform),
                and: pinPosition("bulk", in: nmos, transform: secondTransform),
                width: metal1Width,
                layer: metal1
            ),
        ].flatMap { $0 }
        let repetition = LayoutRepetition(
            columns: 1,
            rows: 2,
            columnStep: .zero,
            rowStep: secondOffset
        )
        let top = LayoutCell(
            name: "TOP",
            shapes: metal2Routes.flatMap(\.shapes) + sourceBulkRoutes,
            vias: metal2Routes.flatMap(\.vias),
            labels: try ["drain": "d", "gate": "g", "source": "s"].map { pinName, netName in
                let devicePin = try pin(pinName, in: nmos)
                return LayoutLabel(
                    text: netName,
                    position: baseTransform.apply(to: devicePin.position),
                    layer: devicePin.layer
                )
            },
            instances: [
                LayoutInstance(
                    cellID: nmos.id,
                    name: "XMN_ARRAY",
                    transform: baseTransform,
                    repetition: repetition
                ),
            ]
        )
        return LayoutDocument(name: "TOP", cells: [top, nmos], topCellID: top.id)
    }

    private func generatedSeriesNMOSDocument(technology: LayoutTechDatabase) throws -> LayoutDocument {
        let first = try generatedDeviceCell(
            deviceKindID: "nmos",
            instanceName: "M1",
            netByPin: ["drain": "d", "gate": "g", "source": "mid", "bulk": "b"],
            technology: technology
        )
        let second = try generatedDeviceCell(
            deviceKindID: "nmos",
            instanceName: "M2",
            netByPin: ["drain": "mid", "gate": "g", "source": "s", "bulk": "b"],
            technology: technology
        )
        let firstPlaced = translatedCell(first, by: .zero)
        let firstBox = try boundingBox(of: firstPlaced)
        let secondBox = try boundingBox(of: second)
        let secondPlaced = translatedCell(
            second,
            by: LayoutPoint(x: 0, y: firstBox.maxY - secondBox.minY + 8.0)
        )
        let combinedBox = try boundingBox(of: LayoutCell(
            name: "SERIES_PLACEMENT",
            shapes: firstPlaced.shapes + secondPlaced.shapes
        ))

        let metal1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let metal2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let metal1Width = max(technology.ruleSet(for: metal1)?.minWidth ?? 0.2, 0.2)
        let metal2Width = max(technology.ruleSet(for: metal2)?.minWidth ?? 0.28, 0.28)
        let leftRouteX = combinedBox.minX - 2.0
        let rightRouteX = combinedBox.maxX + 2.0
        let metal2Routes = try [
            bridgeWithVias(
                between: pin("source", in: firstPlaced).position,
                and: pin("drain", in: secondPlaced).position,
                width: metal2Width,
                layer: metal2,
                viaX: leftRouteX
            ),
        ]
        let gateRoutes = try bridge(
            between: pin("gate", in: firstPlaced).position,
            and: pin("gate", in: secondPlaced).position,
            width: metal1Width,
            layer: metal1,
            viaX: rightRouteX
        )
        let bulkRoutes = try bridge(
            between: pin("bulk", in: firstPlaced).position,
            and: pin("bulk", in: secondPlaced).position,
            width: metal1Width,
            layer: metal1,
            viaX: leftRouteX - 1.0
        )

        let top = LayoutCell(
            name: "TOP",
            shapes: firstPlaced.shapes + secondPlaced.shapes + metal2Routes.flatMap(\.shapes) + gateRoutes + bulkRoutes,
            vias: firstPlaced.vias + secondPlaced.vias + metal2Routes.flatMap(\.vias),
            labels: firstPlaced.labels + secondPlaced.labels
        )
        return LayoutDocument(name: "TOP", cells: [top], topCellID: top.id)
    }

    private func generatedDeviceCell(
        deviceKindID: String,
        instanceName: String,
        netByPin: [String: String],
        technology: LayoutTechDatabase
    ) throws -> LayoutCell {
        var cell = try MOSFETCellGenerator().generateCell(
            deviceKindID: deviceKindID,
            instanceName: instanceName,
            parameters: ["w": 2.0, "l": 0.18, "nf": 1],
            tech: technology
        )
        cell.labels = []
        for pin in cell.pins {
            guard let net = netByPin[pin.name] else { continue }
            cell.labels.append(LayoutLabel(text: net, position: pin.position, layer: pin.layer))
        }
        return cell
    }

    private func translatedCell(_ cell: LayoutCell, by delta: LayoutPoint) -> LayoutCell {
        var moved = cell
        moved.shapes = moved.shapes.map { shape in
            var movedShape = shape
            movedShape.geometry = shape.geometry.translated(by: delta)
            return movedShape
        }
        moved.vias = moved.vias.map { via in
            var movedVia = via
            movedVia.position = via.position.translated(by: delta)
            return movedVia
        }
        moved.labels = moved.labels.map { label in
            var movedLabel = label
            movedLabel.position = label.position.translated(by: delta)
            return movedLabel
        }
        moved.pins = moved.pins.map { pin in
            var movedPin = pin
            movedPin.position = pin.position.translated(by: delta)
            return movedPin
        }
        return moved
    }

    private func boundingBox(of cell: LayoutCell) throws -> LayoutRect {
        guard let first = cell.shapes.first.map({ LayoutGeometryAnalysis.boundingBox(for: $0.geometry) }) else {
            throw LVSError.invalidInput("Generated LVS fixture has no geometry to export.")
        }
        return cell.shapes.dropFirst().reduce(first) { partial, shape in
            partial.union(LayoutGeometryAnalysis.boundingBox(for: shape.geometry))
        }
    }

    private func pin(_ name: String, in cell: LayoutCell) throws -> LayoutPin {
        guard let pin = cell.pins.first(where: { $0.name == name }) else {
            throw LVSError.invalidInput("Generated LVS fixture is missing pin '\(name)'.")
        }
        return pin
    }

    private func pinPosition(
        _ name: String,
        in cell: LayoutCell,
        transform: LayoutTransform
    ) throws -> LayoutPoint {
        try transform.apply(to: pin(name, in: cell).position)
    }

    private func bridge(
        between start: LayoutPoint,
        and end: LayoutPoint,
        width: Double,
        layer: LayoutLayerID
    ) -> [LayoutShape] {
        let corner = LayoutPoint(x: start.x, y: end.y)
        return [
            segment(from: start, to: corner, width: width, layer: layer),
            segment(from: corner, to: end, width: width, layer: layer),
        ].filter { shape in
            guard case .rect(let rect) = shape.geometry else { return true }
            return rect.size.width > 0 && rect.size.height > 0
        }
    }

    private func bridge(
        between start: LayoutPoint,
        and end: LayoutPoint,
        width: Double,
        layer: LayoutLayerID,
        viaX: Double
    ) -> [LayoutShape] {
        let firstCorner = LayoutPoint(x: viaX, y: start.y)
        let secondCorner = LayoutPoint(x: viaX, y: end.y)
        return [
            segment(from: start, to: firstCorner, width: width, layer: layer),
            segment(from: firstCorner, to: secondCorner, width: width, layer: layer),
            segment(from: secondCorner, to: end, width: width, layer: layer),
        ].filter { shape in
            guard case .rect(let rect) = shape.geometry else { return true }
            return rect.size.width > 0 && rect.size.height > 0
        }
    }

    private func bridgeWithVias(
        between start: LayoutPoint,
        and end: LayoutPoint,
        width: Double,
        layer: LayoutLayerID
    ) -> (shapes: [LayoutShape], vias: [LayoutVia]) {
        (
            shapes: [segment(from: start, to: end, width: width, layer: layer)],
            vias: [
                LayoutVia(viaDefinitionID: "VIA1", position: start),
                LayoutVia(viaDefinitionID: "VIA1", position: end),
            ]
        )
    }

    private func bridgeWithVias(
        between start: LayoutPoint,
        and end: LayoutPoint,
        width: Double,
        layer: LayoutLayerID,
        viaX: Double
    ) -> (shapes: [LayoutShape], vias: [LayoutVia]) {
        (
            shapes: bridge(between: start, and: end, width: width, layer: layer, viaX: viaX),
            vias: [
                LayoutVia(viaDefinitionID: "VIA1", position: start),
                LayoutVia(viaDefinitionID: "VIA1", position: end),
            ]
        )
    }

    private func segment(
        from start: LayoutPoint,
        to end: LayoutPoint,
        width: Double,
        layer: LayoutLayerID
    ) -> LayoutShape {
        let segment = LayoutRect(
            origin: LayoutPoint(
                x: min(start.x, end.x) - width / 2,
                y: min(start.y, end.y) - width / 2
            ),
            size: LayoutSize(
                width: abs(start.x - end.x) + width,
                height: abs(start.y - end.y) + width
            )
        )
        return LayoutShape(layer: layer, geometry: .rect(segment))
    }

    private func generatedOutputURL(
        path: String,
        format: LVSLayoutFormat,
        in directory: URL
    ) throws -> URL {
        let components = try checkedRelativePathComponents(path, label: "generatedLayoutFixture.layoutGDSPath")
        let requestedURL = components.reduce(directory) { partial, component in
            partial.appending(path: component)
        }
        try FileManager.default.createDirectory(
            at: requestedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if requestedURL.pathExtension.isEmpty {
            return requestedURL.appendingPathExtension(fileExtension(for: format))
        }
        return requestedURL
    }

    private func checkedRelativePathComponents(_ path: String, label: String) throws -> [String] {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let isSafeRelativePath = !trimmedPath.isEmpty
            && !trimmedPath.hasPrefix("/")
            && !trimmedPath.hasPrefix("~")
            && !trimmedPath.contains("://")
            && !components.isEmpty
            && !components.contains("")
            && !components.contains(".")
            && !components.contains("..")
        guard isSafeRelativePath else {
            throw LVSError.invalidInput("\(label) must be a non-empty relative path inside the LVS corpus spec directory.")
        }
        return components
    }

    private func layoutFileFormat(for format: LVSLayoutFormat) -> LayoutFileFormat {
        switch format {
        case .auto, .gds:
            return .gds
        case .oasis:
            return .oasis
        case .cif:
            return .cif
        case .dxf:
            return .dxf
        }
    }

    private func fileExtension(for format: LVSLayoutFormat) -> String {
        switch format {
        case .auto, .gds:
            return "gds"
        case .oasis:
            return "oas"
        case .cif:
            return "cif"
        case .dxf:
            return "dxf"
        }
    }

    private func safePathComponent(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = value.map { allowed.contains($0) ? $0 : "_" }
        let result = String(mapped)
        return result.isEmpty ? "case" : result
    }
}

private struct PreparedLVSCorpusInputs: Sendable {
    let layoutNetlistURL: URL?
    let layoutGDSURL: URL?
    let layoutFormat: LVSLayoutFormat?
    let technologyURL: URL?
    let extractionProfileURL: URL?
    let extractionDeckURL: URL?
    let devicePolicyURL: URL?
    let devicePolicyAudit: NetgenLVSDeviceDeckImportAudit?
    let devicePolicyArtifactURLs: [URL]
}

private struct PreparedLVSCorpusDevicePolicy: Sendable {
    let policyURL: URL?
    let audit: NetgenLVSDeviceDeckImportAudit?
    let artifactURLs: [URL]
}
