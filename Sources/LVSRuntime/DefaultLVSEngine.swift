import Foundation
import LVSCore
import LVSNative
import LVSAdapters
import LVSExtractionAdapters
import LVSPersistence

public struct DefaultLVSEngine: LVSExecuting {
    private let backends: [String: any LVSBackend]
    private let layoutNetlistExtractor: (any LVSLayoutNetlistExtracting)?
    private let store: any LVSArtifactPersisting

    public init(
        backend: (any LVSBackend)? = NetgenLVSAdapter.locate(),
        layoutNetlistExtractor: (any LVSLayoutNetlistExtracting)? = MagicLayoutNetlistExtractor.locate(),
        store: any LVSArtifactPersisting = LVSArtifactStore()
    ) {
        var backends: [any LVSBackend] = [NativeLVSBackend(), LayoutGDSLVSBackend()]
        if let backend {
            backends.append(backend)
        }
        self.init(backends: backends, layoutNetlistExtractor: layoutNetlistExtractor, store: store)
    }

    public init(
        backends: [any LVSBackend],
        layoutNetlistExtractor: (any LVSLayoutNetlistExtracting)? = MagicLayoutNetlistExtractor.locate(),
        store: any LVSArtifactPersisting = LVSArtifactStore()
    ) {
        var backendsByID: [String: any LVSBackend] = [:]
        for backend in backends {
            backendsByID[backend.backendID] = backend
        }
        self.backends = backendsByID
        self.layoutNetlistExtractor = layoutNetlistExtractor
        self.store = store
    }

    public func run(_ request: LVSRequest) async throws -> LVSExecutionResult {
        try await run(request, cancellationCheck: nil)
    }

    public func run(
        _ request: LVSRequest,
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> LVSExecutionResult {
        do {
            return try await runAttempt(request, cancellationCheck: cancellationCheck)
        } catch {
            if let directory = request.workingDirectory {
                try persistFailedAttempt(error, request: request, directory: directory)
            }
            throw error
        }
    }

    private func runAttempt(
        _ request: LVSRequest,
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> LVSExecutionResult {
        let backendID = request.backendSelection.backendID
        guard let backend = backends[backendID] else {
            throw LVSError.backendUnavailable("Unsupported LVS backend: \(request.backendSelection.backendID)")
        }

        let artifactDirectory = request.workingDirectory ?? FileManager.default.temporaryDirectory
        if backendID == "native-gds" {
            guard request.layoutGDSURL != nil else {
                throw LVSError.invalidInput("native-gds LVS requires layoutGDSURL")
            }
            var directResult = try await runBackend(
                backend,
                request: request,
                cancellationCheck: cancellationCheck
            )
            directResult = try applyWaivers(to: directResult)
            if let directory = request.workingDirectory {
                let artifacts = try store.save(directResult, to: directory)
                directResult = LVSExecutionResult(
                    request: directResult.request,
                    result: directResult.result,
                    extractedLayoutNetlistURL: directResult.extractedLayoutNetlistURL,
                    waiverReport: directResult.waiverReport,
                    devicePolicyReport: directResult.devicePolicyReport,
                    reportURL: artifacts.reportURL,
                    artifactManifestURL: artifacts.manifestURL,
                    correspondence: directResult.correspondence,
                    correspondenceURL: artifacts.correspondenceURL,
                    extractionReportURL: directResult.extractionReportURL,
                    transformLedgerURL: directResult.transformLedgerURL,
                    extractionEvidence: directResult.extractionEvidence
                )
            }
            return directResult
        }

        let (layoutNetlistURL, extractedLayoutNetlistURL) = try await resolveLayoutNetlist(
            request: request,
            artifactDirectory: artifactDirectory,
            cancellationCheck: cancellationCheck
        )
        let comparisonRequest = LVSRequest(
            layoutNetlistURL: layoutNetlistURL,
            layoutGDSURL: request.layoutGDSURL,
            layoutFormat: request.layoutFormat,
            schematicNetlistURL: request.schematicNetlistURL,
            topCell: request.topCell,
            technologyURL: request.technologyURL,
            extractionDeckURL: request.extractionDeckURL,
            processProfileID: request.processProfileID,
            waiverURL: request.waiverURL,
            modelEquivalenceURL: request.modelEquivalenceURL,
            terminalEquivalenceURL: request.terminalEquivalenceURL,
            devicePolicyURL: request.devicePolicyURL,
            workingDirectory: request.workingDirectory,
            backendSelection: request.backendSelection,
            options: request.options
        )
        var result = try await runBackend(
            backend,
            request: comparisonRequest,
            cancellationCheck: cancellationCheck
        )
        result = try applyWaivers(to: result)
        result = LVSExecutionResult(
            request: result.request,
            result: result.result,
            extractedLayoutNetlistURL: extractedLayoutNetlistURL,
            waiverReport: result.waiverReport,
            devicePolicyReport: result.devicePolicyReport,
            reportURL: result.reportURL,
            artifactManifestURL: result.artifactManifestURL,
            correspondence: result.correspondence,
            correspondenceURL: result.correspondenceURL,
            extractionReportURL: result.extractionReportURL,
            transformLedgerURL: result.transformLedgerURL,
            extractionEvidence: result.extractionEvidence
        )
        if let directory = request.workingDirectory {
            let artifacts = try store.save(result, to: directory)
            result = LVSExecutionResult(
                request: result.request,
                result: result.result,
                extractedLayoutNetlistURL: result.extractedLayoutNetlistURL,
                waiverReport: result.waiverReport,
                devicePolicyReport: result.devicePolicyReport,
                reportURL: artifacts.reportURL,
                artifactManifestURL: artifacts.manifestURL,
                correspondence: result.correspondence,
                correspondenceURL: artifacts.correspondenceURL,
                extractionReportURL: result.extractionReportURL,
                transformLedgerURL: result.transformLedgerURL,
                extractionEvidence: result.extractionEvidence
            )
        }
        return result
    }

    private func persistFailedAttempt(
        _ error: any Error,
        request: LVSRequest,
        directory: URL
    ) throws {
        let failure = failureContract(for: error)
        let diagnostic = LVSDiagnostic(
            severity: .error,
            message: error.localizedDescription,
            ruleID: failure.reason.code,
            category: "executionReadiness",
            suggestedFix: "Inspect the retained request, partial artifacts, and blocking reason before resuming.",
            rawLine: error.localizedDescription,
            waiverDisposition: .nonWaivable
        )
        let result = LVSResult(
            backendID: request.backendSelection.backendID,
            toolName: "LVSRuntime",
            executionStatus: failure.status,
            verdict: .blocked,
            readiness: .blocked,
            blockingReasons: [failure.reason],
            logPath: "",
            diagnostics: [diagnostic]
        )
        _ = try store.save(
            LVSExecutionResult(request: request, result: result),
            to: directory
        )
    }

    private func failureContract(
        for error: any Error
    ) -> (status: LVSExecutionStatus, reason: LVSBlockingReason) {
        let code: String
        let status: LVSExecutionStatus
        if let lvsError = error as? LVSError {
            switch lvsError {
            case .cancelled:
                code = "execution_cancelled"
                status = .cancelled
            case .timedOut:
                code = "execution_timed_out"
                status = .timedOut
            case .resourceLimitExceeded:
                code = "execution_resource_limit_exceeded"
                status = .failed
            case .invalidInput:
                code = "execution_invalid_input"
                status = .failed
            case .backendUnavailable:
                code = "execution_backend_unavailable"
                status = .failed
            case .backendFailed:
                code = "execution_backend_failed"
                status = .failed
            case .artifactWriteFailed:
                code = "execution_artifact_write_failed"
                status = .failed
            case .waiverApplicationFailed, .unscopedWaiver, .invalidWaiver:
                code = "execution_waiver_failed"
                status = .failed
            }
        } else if error is CancellationError {
            code = "execution_cancelled"
            status = .cancelled
        } else {
            code = "execution_failed"
            status = .failed
        }
        return (
            status,
            LVSBlockingReason(
                code: code,
                message: error.localizedDescription
            )
        )
    }

    private func runBackend(
        _ backend: any LVSBackend,
        request: LVSRequest,
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> LVSExecutionResult {
        guard request.options.timeoutSeconds > 0 else {
            throw LVSError.invalidInput("LVS timeoutSeconds must be greater than zero.")
        }
        return try await withThrowingTaskGroup(of: LVSExecutionResult.self) { group in
            group.addTask {
                if let cancellableBackend = backend as? any LVSCancellableBackend {
                    return try await cancellableBackend.run(
                        request,
                        cancellationCheck: cancellationCheck
                    )
                }
                return try await backend.run(request)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(request.options.timeoutSeconds))
                throw LVSError.timedOut(
                    "Backend \(backend.backendID) exceeded \(request.options.timeoutSeconds) seconds."
                )
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw LVSError.backendFailed("LVS backend produced no result.")
            }
            return result
        }
    }

    private func resolveLayoutNetlist(
        request: LVSRequest,
        artifactDirectory: URL,
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> (layoutNetlistURL: URL, extractedLayoutNetlistURL: URL?) {
        if let existing = request.layoutNetlistURL {
            return (existing, nil)
        }
        if let layoutGDSURL = request.layoutGDSURL {
            guard let layoutNetlistExtractor else {
                throw LVSError.backendUnavailable("LVS layout netlist extractor was not located")
            }
            let layoutNetlistURL = try await layoutNetlistExtractor.extractLayoutNetlist(
                gds: layoutGDSURL,
                topCell: request.topCell,
                into: artifactDirectory,
                timeoutSeconds: request.options.timeoutSeconds,
                cancellationCheck: cancellationCheck
            )
            return (layoutNetlistURL, layoutNetlistURL)
        }
        throw LVSError.invalidInput("LVS requires layoutNetlistURL or layoutGDSURL")
    }

    private func applyWaivers(to executionResult: LVSExecutionResult) throws -> LVSExecutionResult {
        guard let waiverURL = executionResult.request.waiverURL else {
            return executionResult
        }
        let waiverFile = try loadWaiverFile(from: waiverURL)
        let reviewer = LVSWaiverReviewer()
        let review = try reviewer.review(
            diagnostics: executionResult.result.diagnostics,
            waiverFile: waiverFile,
            waiverPolicyPath: waiverURL.path(percentEncoded: false)
        )
        let diagnostics = try reviewer.reviewedDiagnostics(
            diagnostics: executionResult.result.diagnostics,
            waiverFile: waiverFile
        )
        let result = LVSResult(
            backendID: executionResult.result.backendID,
            toolName: executionResult.result.toolName,
            executionStatus: executionResult.result.executionStatus,
            verdict: executionResult.result.verdict,
            readiness: executionResult.result.readiness,
            blockingReasons: executionResult.result.blockingReasons,
            logPath: executionResult.result.logPath,
            diagnostics: diagnostics,
            provenance: executionResult.result.provenance
        )
        return LVSExecutionResult(
            request: executionResult.request,
            result: result,
            extractedLayoutNetlistURL: executionResult.extractedLayoutNetlistURL,
            waiverReport: review.applicationReport,
            devicePolicyReport: executionResult.devicePolicyReport,
            reportURL: executionResult.reportURL,
            artifactManifestURL: executionResult.artifactManifestURL,
            correspondence: executionResult.correspondence,
            correspondenceURL: executionResult.correspondenceURL,
            extractionReportURL: executionResult.extractionReportURL,
            transformLedgerURL: executionResult.transformLedgerURL,
            extractionEvidence: executionResult.extractionEvidence
        )
    }

    private func loadWaiverFile(from url: URL) throws -> LVSWaiverFile {
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(LVSWaiverFile.self, from: data)
            let ids = file.waivers.map(\.id)
            guard Set(ids).count == ids.count else {
                throw LVSError.waiverApplicationFailed("Waiver IDs must be unique.")
            }
            return file
        } catch let error as LVSError {
            throw error
        } catch {
            throw LVSError.waiverApplicationFailed(error.localizedDescription)
        }
    }
}
