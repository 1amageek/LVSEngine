import Foundation
import LVSCore
import LVSPureSwift
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
        var backends: [any LVSBackend] = [PureSwiftLVSBackend()]
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
        guard let backend = backends[request.backendSelection.backendID] else {
            throw LVSError.backendUnavailable("Unsupported LVS backend: \(request.backendSelection.backendID)")
        }

        let artifactDirectory = request.workingDirectory ?? FileManager.default.temporaryDirectory
        let layoutNetlistURL: URL
        let extractedLayoutNetlistURL: URL?
        if let existing = request.layoutNetlistURL {
            layoutNetlistURL = existing
            extractedLayoutNetlistURL = nil
        } else if let layoutGDSURL = request.layoutGDSURL {
            guard let layoutNetlistExtractor else {
                throw LVSError.backendUnavailable("LVS layout netlist extractor was not located")
            }
            layoutNetlistURL = try await layoutNetlistExtractor.extractLayoutNetlist(
                gds: layoutGDSURL,
                topCell: request.topCell,
                into: artifactDirectory,
                timeoutSeconds: request.options.timeoutSeconds
            )
            extractedLayoutNetlistURL = layoutNetlistURL
        } else {
            throw LVSError.invalidInput("LVS requires layoutNetlistURL or layoutGDSURL")
        }

        let comparisonRequest = LVSRequest(
            layoutNetlistURL: layoutNetlistURL,
            layoutGDSURL: request.layoutGDSURL,
            schematicNetlistURL: request.schematicNetlistURL,
            topCell: request.topCell,
            workingDirectory: request.workingDirectory,
            backendSelection: request.backendSelection,
            options: request.options
        )
        var result = try await backend.run(comparisonRequest)
        result = LVSExecutionResult(
            request: result.request,
            result: result.result,
            extractedLayoutNetlistURL: extractedLayoutNetlistURL,
            reportURL: result.reportURL
        )
        if let directory = request.workingDirectory {
            let reportURL = try store.save(result, to: directory)
            result = LVSExecutionResult(
                request: result.request,
                result: result.result,
                extractedLayoutNetlistURL: result.extractedLayoutNetlistURL,
                reportURL: reportURL
            )
        }
        return result
    }
}
