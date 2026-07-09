import Foundation
import LVSCore
import LayoutAutoGen
import LayoutCore
import LayoutIO
import LayoutTech

public struct LVSCorpusRunner: Sendable {
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

        for corpusCase in spec.cases {
            try validateBudget(corpusCase.maxDurationSeconds, label: "\(corpusCase.caseID).maxDurationSeconds")
            let maxDurationSeconds = corpusCase.maxDurationSeconds ?? spec.defaultMaxDurationSeconds
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
            let failureReasons = failureReasons(
                expectationMatched: expectationMatched,
                durationBudgetPassed: durationBudgetPassed,
                oracleAgreementPassed: oracleAgreementPassed,
                oracleFailureReasons: oracleResult?.failureReasons ?? [],
                durationSeconds: durationSeconds,
                maxDurationSeconds: maxDurationSeconds
            )
            caseResults.append(LVSCorpusCaseResult(
                caseID: corpusCase.caseID,
                matched: expectationMatched && durationBudgetPassed && oracleAgreementPassed,
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
                oracleComparison: oracleComparison
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
            qualificationPolicy: spec.qualificationPolicy,
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
        let agreementPassed = executionResult.result.passed == primaryPassed
            && oracleRuleIDs == primaryActiveRuleIDs
            && oracleDiagnosticSummary == primaryDiagnosticSummary
        let comparison = LVSCorpusOracleComparison(
            primaryBackendID: primaryBackendID,
            oracleBackendID: executionResult.result.backendID,
            passedMatched: executionResult.result.passed == primaryPassed,
            activeErrorRuleIDsMatched: oracleRuleIDs == primaryActiveRuleIDs,
            diagnosticSummaryMatched: oracleDiagnosticSummary == primaryDiagnosticSummary,
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
            failureReasons: comparison.mismatchReasons,
            executionError: nil,
            reportPath: executionResult.reportURL?.path(percentEncoded: false),
            manifestPath: executionResult.artifactManifestURL?.path(percentEncoded: false),
            extractedLayoutNetlistPath: executionResult.extractedLayoutNetlistURL?.path(percentEncoded: false),
            devicePolicyReport: executionResult.devicePolicyReport,
            provenance: provenance(for: executionResult)
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
        guard let manifestURL = executionResult.artifactManifestURL else {
            return nil
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
                extractedLayoutNetlistPath: executionResult.extractedLayoutNetlistURL?.path(percentEncoded: false)
            )
        }

        return LVSCorpusCaseProvenance(
            backendID: executionResult.result.backendID,
            inputArtifacts: manifest.inputs,
            outputArtifacts: manifest.outputs,
            reportPath: executionResult.reportURL?.path(percentEncoded: false),
            manifestPath: manifestURL.path(percentEncoded: false),
            extractedLayoutNetlistPath: executionResult.extractedLayoutNetlistURL?.path(percentEncoded: false)
        )
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
            devicePolicyURL: try corpusCase.devicePolicyPath.map {
                try resolveCorpusInputPath(
                    $0,
                    label: "\(corpusCase.caseID).devicePolicyPath",
                    relativeTo: specDirectory
                )
            },
            workingDirectory: workingDirectory,
            backendSelection: LVSBackendSelection(backendID: backendID),
            options: LVSOptions()
        )
    }

    private func resolveCorpusInputPath(
        _ path: String,
        label: String,
        relativeTo base: URL
    ) throws -> URL {
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
                }
            )
        }

        let generatedDirectory = caseDirectory.appending(path: "generated-inputs")
        try FileManager.default.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)
        let technology = try generatedTechnology(named: fixture.technology)
        let technologyURL = generatedDirectory.appending(path: "technology.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(technology).write(to: technologyURL, options: [.atomic])

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
            technologyURL: technologyURL
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
}
