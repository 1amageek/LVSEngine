import Foundation
import LVSCore
import LVSNative
import LVSAdapters
import LVSExtractionAdapters
import LVSPersistence

public struct DefaultLVSEngine: Sendable {
    private let backends: [String: any LVSBackend]
    private let layoutNetlistExtractor: (any LVSLayoutNetlistExtracting)?
    private let store: LVSArtifactStore

    public init(
        backend: (any LVSBackend)? = NetgenLVSAdapter.locate(),
        layoutNetlistExtractor: (any LVSLayoutNetlistExtracting)? = MagicLayoutNetlistExtractor.locate(),
        store: LVSArtifactStore = LVSArtifactStore()
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
        store: LVSArtifactStore = LVSArtifactStore()
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
        let backendID = request.backendSelection.backendID
        guard let backend = backends[backendID] else {
            throw LVSError.backendUnavailable("Unsupported LVS backend: \(request.backendSelection.backendID)")
        }

        let artifactDirectory = request.workingDirectory ?? FileManager.default.temporaryDirectory
        if backendID == "native-gds" {
            guard request.layoutGDSURL != nil else {
                throw LVSError.invalidInput("native-gds LVS requires layoutGDSURL")
            }
            var directResult: LVSExecutionResult
            if let cancellableBackend = backend as? any LVSCancellableBackend {
                directResult = try await cancellableBackend.run(request, cancellationCheck: cancellationCheck)
            } else {
                directResult = try await backend.run(request)
            }
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
                    artifactManifestURL: artifacts.manifestURL
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
            waiverURL: request.waiverURL,
            modelEquivalenceURL: request.modelEquivalenceURL,
            terminalEquivalenceURL: request.terminalEquivalenceURL,
            devicePolicyURL: request.devicePolicyURL,
            workingDirectory: request.workingDirectory,
            backendSelection: request.backendSelection,
            options: request.options
        )
        var result: LVSExecutionResult
        if let cancellableBackend = backend as? any LVSCancellableBackend {
            result = try await cancellableBackend.run(comparisonRequest, cancellationCheck: cancellationCheck)
        } else {
            result = try await backend.run(comparisonRequest)
        }
        result = try applyWaivers(to: result)
        result = LVSExecutionResult(
            request: result.request,
            result: result.result,
            extractedLayoutNetlistURL: extractedLayoutNetlistURL,
            waiverReport: result.waiverReport,
            devicePolicyReport: result.devicePolicyReport,
            reportURL: result.reportURL,
            artifactManifestURL: result.artifactManifestURL
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
                artifactManifestURL: artifacts.manifestURL
            )
        }
        return result
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
            success: executionResult.result.success,
            completed: executionResult.result.completed,
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
            artifactManifestURL: executionResult.artifactManifestURL
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
