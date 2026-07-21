import Foundation
import CryptoKit
import CircuiteFoundation
import LVSCore

public struct LVSArtifactStore: LVSArtifactPersisting {
    public init() {}

    public func save(_ executionResult: LVSExecutionResult, to directory: URL) throws -> LVSArtifactSaveResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let reportURL = directory.appending(path: "lvs-report-\(UUID().uuidString).json")
            let manifestURL = directory.appending(path: "lvs-artifact-manifest-\(UUID().uuidString).json")
            let correspondenceURL = executionResult.correspondence.map { _ in
                directory.appending(path: "lvs-correspondence-\(UUID().uuidString).json")
            }
            if let correspondence = executionResult.correspondence, let correspondenceURL {
                try encoder.encode(correspondence).write(to: correspondenceURL, options: [.atomic])
            }
            let storedResult = LVSExecutionResult(
                request: executionResult.request,
                comparisonRequest: executionResult.comparisonRequest,
                result: executionResult.result,
                extractedLayoutNetlistURL: executionResult.extractedLayoutNetlistURL,
                waiverReport: executionResult.waiverReport,
                devicePolicyReport: executionResult.devicePolicyReport,
                reportURL: reportURL,
                artifactManifestURL: manifestURL,
                correspondence: executionResult.correspondence,
                correspondenceURL: correspondenceURL,
                extractionReportURL: executionResult.extractionReportURL,
                transformLedgerURL: executionResult.transformLedgerURL,
                extractionEvidence: executionResult.extractionEvidence,
                layoutNetlistExtraction: executionResult.layoutNetlistExtraction,
                provenance: executionResult.provenance
            )
            let data = try encoder.encode(storedResult)
            try data.write(to: reportURL, options: [.atomic])

            let manifest = try makeManifest(
                for: storedResult,
                reportURL: reportURL,
                manifestURL: manifestURL,
                correspondenceURL: correspondenceURL,
                baseDirectory: directory
            )
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(to: manifestURL, options: [.atomic])
            return LVSArtifactSaveResult(
                reportURL: reportURL,
                manifestURL: manifestURL,
                correspondenceURL: correspondenceURL
            )
        } catch let error as LVSError {
            throw error
        } catch {
            throw LVSError.artifactWriteFailed(error.localizedDescription)
        }
    }

    private func makeManifest(
        for executionResult: LVSExecutionResult,
        reportURL: URL,
        manifestURL: URL,
        correspondenceURL: URL?,
        baseDirectory: URL
    ) throws -> LVSArtifactManifest {
        let comparisonRequest = executionResult.comparisonRequest
        let provenanceInputs = executionResult.provenance.inputs
        let derivedNetlist = executionResult.layoutNetlistExtraction?.netlist
        var inputs: [LVSArtifactRecord] = []
        if let layoutGDSURL = comparisonRequest.layoutGDSURL {
            inputs.append(try record(
                id: "input-layout",
                kind: .layout,
                url: layoutGDSURL,
                baseDirectory: baseDirectory,
                sourceReferences: provenanceInputs,
                expectedArtifactKind: .layout
            ))
        }
        if let layoutNetlistURL = comparisonRequest.layoutNetlistURL {
            if let derivedNetlist, sourceLocation(derivedNetlist.locator.location, matches: layoutNetlistURL) {
                inputs.append(try record(
                    id: "input-layout-netlist",
                    kind: .layoutNetlist,
                    url: layoutNetlistURL,
                    baseDirectory: baseDirectory,
                    derivedReference: derivedNetlist
                ))
            } else {
                inputs.append(try record(
                    id: "input-layout-netlist",
                    kind: .layoutNetlist,
                    url: layoutNetlistURL,
                    baseDirectory: baseDirectory,
                    sourceReferences: provenanceInputs,
                    expectedArtifactKind: .netlist
                ))
            }
        }
        if let extractedLayoutNetlistURL = executionResult.extractedLayoutNetlistURL,
           comparisonRequest.layoutNetlistURL != extractedLayoutNetlistURL {
            guard let derivedNetlist else {
                throw LVSError.artifactWriteFailed(
                    "LVS extracted layout netlist is missing its producer-bound derived artifact reference."
                )
            }
            inputs.append(try record(
                id: "derived-layout-netlist",
                kind: .layoutNetlist,
                url: extractedLayoutNetlistURL,
                baseDirectory: baseDirectory,
                derivedReference: derivedNetlist
            ))
        }
        inputs.append(try record(
            id: "input-schematic-netlist",
            kind: .schematicNetlist,
            url: comparisonRequest.schematicNetlistURL,
            baseDirectory: baseDirectory,
            sourceReferences: provenanceInputs,
            expectedArtifactKind: .netlist
        ))
        if let technologyURL = comparisonRequest.technologyURL {
            inputs.append(try record(
                id: "input-technology",
                kind: .technology,
                url: technologyURL,
                baseDirectory: baseDirectory,
                sourceReferences: provenanceInputs,
                expectedArtifactKind: .technology
            ))
        }
        if let extractionProfileURL = comparisonRequest.extractionProfileURL {
            inputs.append(try record(
                id: "input-extraction-profile",
                kind: .extractionProfile,
                url: extractionProfileURL,
                baseDirectory: baseDirectory,
                sourceReferences: provenanceInputs,
                expectedArtifactKind: .technology
            ))
        }
        if let extractionDeckURL = comparisonRequest.extractionDeckURL {
            inputs.append(try record(
                id: "input-extraction-deck",
                kind: .extractionDeck,
                url: extractionDeckURL,
                baseDirectory: baseDirectory,
                sourceReferences: provenanceInputs,
                expectedArtifactKind: .ruleDeck
            ))
        }
        if let waiverURL = comparisonRequest.waiverURL {
            inputs.append(try record(
                id: "input-waivers",
                kind: .waiver,
                url: waiverURL,
                baseDirectory: baseDirectory,
                sourceReferences: provenanceInputs,
                expectedArtifactKind: .constraint
            ))
        }
        if let modelEquivalenceURL = comparisonRequest.modelEquivalenceURL {
            inputs.append(try record(
                id: "input-model-equivalence",
                kind: .modelEquivalence,
                url: modelEquivalenceURL,
                baseDirectory: baseDirectory,
                sourceReferences: provenanceInputs,
                expectedArtifactKind: .constraint
            ))
        }
        if let terminalEquivalenceURL = comparisonRequest.terminalEquivalenceURL {
            inputs.append(try record(
                id: "input-terminal-equivalence",
                kind: .terminalEquivalence,
                url: terminalEquivalenceURL,
                baseDirectory: baseDirectory,
                sourceReferences: provenanceInputs,
                expectedArtifactKind: .constraint
            ))
        }
        if let devicePolicyURL = comparisonRequest.devicePolicyURL {
            inputs.append(try record(
                id: "input-device-policy",
                kind: .devicePolicy,
                url: devicePolicyURL,
                baseDirectory: baseDirectory,
                sourceReferences: provenanceInputs,
                expectedArtifactKind: .constraint
            ))
        }

        var outputs = [
            try record(id: "report", kind: .report, url: reportURL, baseDirectory: baseDirectory),
        ]
        let logURL = URL(filePath: executionResult.result.logPath)
        if !executionResult.result.logPath.isEmpty,
           FileManager.default.fileExists(atPath: logURL.path(percentEncoded: false)) {
            outputs.append(try record(id: "log", kind: .log, url: logURL, baseDirectory: baseDirectory))
        }
        if let correspondenceURL {
            outputs.append(try record(
                id: "lvs-correspondence",
                kind: .correspondence,
                url: correspondenceURL,
                baseDirectory: baseDirectory
            ))
        }
        if let extractionReportURL = executionResult.extractionReportURL {
            outputs.append(try record(
                id: "lvs-extraction-report",
                kind: .extractionReport,
                url: extractionReportURL,
                baseDirectory: baseDirectory
            ))
        }
        if let transformLedgerURL = executionResult.transformLedgerURL {
            outputs.append(try record(
                id: "lvs-transform-ledger",
                kind: .transformLedger,
                url: transformLedgerURL,
                baseDirectory: baseDirectory
            ))
        }
        outputs.append(LVSArtifactRecord(
            id: "manifest",
            kind: .manifest,
            path: relativePath(for: manifestURL, baseDirectory: baseDirectory),
            byteCount: nil,
            sha256: nil
        ))

        return LVSArtifactManifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            backendID: executionResult.result.backendID,
            toolName: executionResult.result.toolName,
            producer: executionResult.provenance.producer,
            executionStatus: executionResult.result.executionStatus,
            verdict: executionResult.result.verdict,
            readiness: executionResult.result.readiness,
            blockingReasons: executionResult.result.blockingReasons,
            implementationIdentity: try implementationIdentity(
                for: executionResult,
                inputs: inputs
            ),
            options: executionResult.request.options,
            normalizedResultDigest: try normalizedResultDigest(executionResult),
            inputs: inputs,
            outputs: outputs,
            diagnosticSummary: diagnosticSummary(executionResult.result.diagnostics),
            waiverReport: executionResult.waiverReport,
            devicePolicyReport: executionResult.devicePolicyReport,
            extractionEvidence: executionResult.extractionEvidence
        )
    }

    private func implementationIdentity(
        for executionResult: LVSExecutionResult,
        inputs: [LVSArtifactRecord]
    ) throws -> LVSImplementationIdentity? {
        guard let processProfileID = executionResult.request.processProfileID,
              let deckDigest = inputs.first(where: { $0.kind == .extractionDeck })?.sha256
                ?? inputs.first(where: { $0.kind == .technology })?.sha256,
              let binaryDigest = executionResult.provenance.producer.build else {
            return nil
        }
        if let executableURL = resolvedExecutableURL(executionResult.result.provenance) {
            let executableData = try Data(contentsOf: executableURL)
            let observedDigest = SHA256.hash(data: executableData)
                .map { String(format: "%02x", $0) }
                .joined()
            guard observedDigest == binaryDigest else {
                throw LVSError.artifactWriteFailed(
                    "LVS executable digest differs from execution provenance producer build."
                )
            }
        }
        return LVSImplementationIdentity(
            implementationID: executionResult.provenance.producer.identifier,
            binaryDigest: binaryDigest,
            algorithmVersion: executionResult.result.backendID == "native"
                || executionResult.result.backendID == "native-gds"
                ? LVSExecutionProvenance.nativeAlgorithmVersion
                : executionResult.provenance.producer.version,
            processProfileID: processProfileID,
            deckDigest: deckDigest
        )
    }

    private func resolvedExecutableURL(_ provenance: LVSToolProvenance?) -> URL? {
        guard let path = provenance?.executablePath, path != "in-process" else {
            return Bundle.main.executableURL
        }
        let url = URL(filePath: path)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    private func normalizedResultDigest(_ executionResult: LVSExecutionResult) throws -> String {
        try LVSNormalizedResultDigester().digest(executionResult)
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

    private func record(
        id: String,
        kind: LVSArtifactRecord.Kind,
        url: URL,
        baseDirectory: URL,
        sourceReferences: [ArtifactReference] = [],
        expectedArtifactKind: ArtifactKind? = nil,
        derivedReference: ArtifactReference? = nil
    ) throws -> LVSArtifactRecord {
        guard url.isFileURL else {
            throw LVSError.artifactWriteFailed("non-file artifact URL is not supported for \(id): \(url.absoluteString)")
        }
        let data = try Data(contentsOf: url)
        let sourceReference: ArtifactReference?
        if let expectedArtifactKind {
            sourceReference = try uniqueSourceReference(
                for: url,
                data: data,
                expectedKind: expectedArtifactKind,
                among: sourceReferences,
                recordID: id
            )
        } else {
            sourceReference = nil
        }
        if let derivedReference {
            try validateDerivedReference(
                derivedReference,
                url: url,
                data: data,
                recordID: id
            )
        }
        let retainedURL = try retainedArtifactURL(
            for: url,
            id: id,
            data: data,
            baseDirectory: baseDirectory
        )
        return LVSArtifactRecord(
            id: id,
            kind: kind,
            path: relativePath(for: retainedURL, baseDirectory: baseDirectory),
            byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            sourceReference: sourceReference,
            derivedReference: derivedReference
        )
    }

    private func uniqueSourceReference(
        for url: URL,
        data: Data,
        expectedKind: ArtifactKind,
        among references: [ArtifactReference],
        recordID: String
    ) throws -> ArtifactReference {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let matches = references.filter { reference in
            reference.locator.kind == expectedKind
                && reference.digest.algorithm == .sha256
                && reference.digest.hexadecimalValue == digest
                && reference.byteCount == UInt64(data.count)
                && sourceLocation(reference.locator.location, matches: url)
        }
        guard matches.count == 1, let match = matches.first else {
            throw LVSError.artifactWriteFailed(
                "LVS manifest input \(recordID) requires exactly one matching execution provenance artifact; found \(matches.count)."
            )
        }
        return match
    }

    private func validateDerivedReference(
        _ reference: ArtifactReference,
        url: URL,
        data: Data,
        recordID: String
    ) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard reference.locator.role == .output,
              reference.locator.kind == .netlist,
              reference.digest.algorithm == .sha256,
              reference.digest.hexadecimalValue == digest,
              reference.byteCount == UInt64(data.count),
              reference.producer != nil,
              sourceLocation(reference.locator.location, matches: url) else {
            throw LVSError.artifactWriteFailed(
                "LVS derived input \(recordID) does not match its producer-bound layout-netlist artifact reference."
            )
        }
    }

    private func sourceLocation(_ location: ArtifactLocation, matches url: URL) -> Bool {
        let sourcePath = url.standardizedFileURL.path(percentEncoded: false)
        switch location.storage {
        case .absoluteFileURL:
            guard let referenceURL = URL(string: location.value), referenceURL.isFileURL else {
                return false
            }
            return referenceURL.standardizedFileURL.path(percentEncoded: false) == sourcePath
        case .workspaceRelative:
            let relativePath = location.value.split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
                .joined(separator: "/")
            return sourcePath == "/" + relativePath || sourcePath.hasSuffix("/" + relativePath)
        }
    }

    private func retainedArtifactURL(
        for url: URL,
        id: String,
        data: Data,
        baseDirectory: URL
    ) throws -> URL {
        if isContained(url, in: baseDirectory) {
            return url
        }
        let fileName = safeFileName(url.lastPathComponent, fallback: "artifact")
        let retainedDirectory = baseDirectory
            .appending(path: "retained-artifacts")
            .appending(path: safeFileName(id, fallback: "artifact"))
        let retainedURL = retainedDirectory.appending(path: fileName)
        try FileManager.default.createDirectory(
            at: retainedDirectory,
            withIntermediateDirectories: true
        )
        try ensureRetainedDirectoryIsInsideBase(retainedDirectory, baseDirectory: baseDirectory)
        try data.write(to: retainedURL, options: [.atomic])
        return retainedURL
    }

    private func isContained(_ url: URL, in baseDirectory: URL) -> Bool {
        containmentRelativePath(for: url, baseDirectory: baseDirectory) != nil
    }

    private func safeFileName(_ value: String, fallback: String) -> String {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate != ".", candidate != ".." else {
            return fallback
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = candidate.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let name = String(sanitized)
        return name.isEmpty ? fallback : name
    }

    private func relativePath(for url: URL, baseDirectory: URL) -> String {
        if let relativePath = containmentRelativePath(for: url, baseDirectory: baseDirectory) {
            return relativePath
        }
        return url.standardizedFileURL.path(percentEncoded: false)
    }

    private func ensureRetainedDirectoryIsInsideBase(_ directoryURL: URL, baseDirectory: URL) throws {
        let resolvedBasePath = directoryPath(normalizedPath(baseDirectory))
        let resolvedDirectoryPath = directoryPath(normalizedPath(directoryURL))
        guard resolvedDirectoryPath == resolvedBasePath || resolvedDirectoryPath.hasPrefix(resolvedBasePath + "/") else {
            throw LVSError.artifactWriteFailed(
                "retained artifact directory escapes the run directory: \(directoryURL.path(percentEncoded: false))"
            )
        }
    }

    private func containmentRelativePath(for url: URL, baseDirectory: URL) -> String? {
        let basePath = directoryPath(baseDirectory.standardizedFileURL.path(percentEncoded: false))
        let artifactPath = url.standardizedFileURL.path(percentEncoded: false)
        guard artifactPath.hasPrefix(basePath + "/") else {
            return nil
        }

        if FileManager.default.fileExists(atPath: artifactPath) {
            let resolvedBasePath = directoryPath(normalizedPath(baseDirectory))
            let resolvedArtifactPath = normalizedPath(url)
            guard resolvedArtifactPath.hasPrefix(resolvedBasePath + "/") else {
                return nil
            }
        }

        return String(artifactPath.dropFirst(basePath.count + 1))
    }

    private func normalizedPath(_ url: URL) -> String {
        let standardizedURL = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: standardizedURL.path(percentEncoded: false)) {
            return standardizedURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path(percentEncoded: false)
        }
        let parentURL = standardizedURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return parentURL
            .appending(path: standardizedURL.lastPathComponent)
            .standardizedFileURL
            .path(percentEncoded: false)
    }

    private func directoryPath(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}
