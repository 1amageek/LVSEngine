import Foundation
import CryptoKit
import LVSCore

public struct LVSArtifactSaveResult: Sendable, Hashable {
    public let reportURL: URL
    public let manifestURL: URL

    public init(reportURL: URL, manifestURL: URL) {
        self.reportURL = reportURL
        self.manifestURL = manifestURL
    }
}

public struct LVSArtifactStore: Sendable {
    public init() {}

    public func save(_ executionResult: LVSExecutionResult, to directory: URL) throws -> LVSArtifactSaveResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let reportURL = directory.appending(path: "lvs-report-\(UUID().uuidString).json")
            let manifestURL = directory.appending(path: "lvs-artifact-manifest-\(UUID().uuidString).json")
            let storedResult = LVSExecutionResult(
                request: executionResult.request,
                result: executionResult.result,
                extractedLayoutNetlistURL: executionResult.extractedLayoutNetlistURL,
                waiverReport: executionResult.waiverReport,
                devicePolicyReport: executionResult.devicePolicyReport,
                reportURL: reportURL,
                artifactManifestURL: manifestURL
            )
            let data = try encoder.encode(storedResult)
            try data.write(to: reportURL, options: [.atomic])

            let manifest = try makeManifest(
                for: storedResult,
                reportURL: reportURL,
                manifestURL: manifestURL,
                baseDirectory: directory
            )
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(to: manifestURL, options: [.atomic])
            return LVSArtifactSaveResult(reportURL: reportURL, manifestURL: manifestURL)
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
        baseDirectory: URL
    ) throws -> LVSArtifactManifest {
        var inputs: [LVSArtifactRecord] = []
        if let layoutGDSURL = executionResult.request.layoutGDSURL {
            inputs.append(try record(id: "input-layout", kind: .layout, url: layoutGDSURL, baseDirectory: baseDirectory))
        }
        if let layoutNetlistURL = executionResult.request.layoutNetlistURL {
            inputs.append(try record(
                id: "input-layout-netlist",
                kind: .layoutNetlist,
                url: layoutNetlistURL,
                baseDirectory: baseDirectory
            ))
        }
        if let extractedLayoutNetlistURL = executionResult.extractedLayoutNetlistURL,
           executionResult.request.layoutNetlistURL != extractedLayoutNetlistURL {
            inputs.append(try record(
                id: "extracted-layout-netlist",
                kind: .layoutNetlist,
                url: extractedLayoutNetlistURL,
                baseDirectory: baseDirectory
            ))
        }
        inputs.append(try record(
            id: "input-schematic-netlist",
            kind: .schematicNetlist,
            url: executionResult.request.schematicNetlistURL,
            baseDirectory: baseDirectory
        ))
        if let technologyURL = executionResult.request.technologyURL {
            inputs.append(try record(id: "input-technology", kind: .technology, url: technologyURL, baseDirectory: baseDirectory))
        }
        if let waiverURL = executionResult.request.waiverURL {
            inputs.append(try record(id: "input-waivers", kind: .waiver, url: waiverURL, baseDirectory: baseDirectory))
        }
        if let modelEquivalenceURL = executionResult.request.modelEquivalenceURL {
            inputs.append(try record(
                id: "input-model-equivalence",
                kind: .modelEquivalence,
                url: modelEquivalenceURL,
                baseDirectory: baseDirectory
            ))
        }
        if let terminalEquivalenceURL = executionResult.request.terminalEquivalenceURL {
            inputs.append(try record(
                id: "input-terminal-equivalence",
                kind: .terminalEquivalence,
                url: terminalEquivalenceURL,
                baseDirectory: baseDirectory
            ))
        }
        if let devicePolicyURL = executionResult.request.devicePolicyURL {
            inputs.append(try record(
                id: "input-device-policy",
                kind: .devicePolicy,
                url: devicePolicyURL,
                baseDirectory: baseDirectory
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
            passed: executionResult.result.passed,
            completed: executionResult.result.completed,
            inputs: inputs,
            outputs: outputs,
            diagnosticSummary: diagnosticSummary(executionResult.result.diagnostics),
            waiverReport: executionResult.waiverReport,
            devicePolicyReport: executionResult.devicePolicyReport
        )
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
        baseDirectory: URL
    ) throws -> LVSArtifactRecord {
        guard url.isFileURL else {
            throw LVSError.artifactWriteFailed("non-file artifact URL is not supported for \(id): \(url.absoluteString)")
        }
        let data = try Data(contentsOf: url)
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
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
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
        url
            .resolvingSymlinksInPath()
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
