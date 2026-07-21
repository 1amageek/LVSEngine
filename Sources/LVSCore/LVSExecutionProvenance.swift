import CircuiteFoundation
import Foundation

public enum LVSExecutionProvenance {
    public static let nativeImplementationVersion = "1.0.0"
    public static let nativeAlgorithmVersion = "lvs-graph-v2"
    private static let processExecutableDigest: String? = {
        let executableURL = Bundle.main.executableURL
            ?? URL(filePath: CommandLine.arguments[0])
        do {
            return try SHA256ContentDigester().digest(
                fileAt: executableURL,
                using: .sha256
            ).hexadecimalValue
        } catch {
            return nil
        }
    }()

    public static func make(
        request: LVSRequest,
        result: LVSResult,
        implementationID: String? = nil,
        implementationVersion: String? = nil,
        implementationBuild: String? = nil,
        captureInputFiles: Bool = true,
        inputArtifacts: [ArtifactReference]? = nil,
        invocation: ExecutionInvocation,
        startedAt: Date,
        completedAt: Date
    ) throws -> ExecutionProvenance {
        let build: String
        if let implementationBuild {
            build = implementationBuild
        } else {
            build = try currentExecutableDigest()
        }
        let producer = try ProducerIdentity(
            kind: .engine,
            identifier: implementationID ?? self.implementationID(for: result.backendID),
            version: implementationVersion ?? self.implementationVersion(for: result.backendID),
            build: build
        )
        let inputs: [ArtifactReference]
        if let inputArtifacts {
            inputs = inputArtifacts
        } else if captureInputFiles {
            inputs = try captureInputArtifacts(for: request)
        } else {
            inputs = request.executionInputArtifacts
        }
        if captureInputFiles,
           request.executionInputArtifacts.isEmpty,
           !inputs.allSatisfy({ LocalArtifactVerifier().verify($0).isVerified }) {
            throw LVSError.backendFailed(
                "An LVS input artifact changed during execution."
            )
        }
        return try ExecutionProvenance(
            producer: producer,
            inputs: inputs,
            invocation: invocation,
            environment: try environmentFingerprint(
                request: request,
                toolchain: "\(producer.identifier)-\(producer.version)"
            ),
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    public static func implementationID(for backendID: String) -> String {
        switch backendID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "native", "native-gds":
            "lvsengine-native"
        case "netgen":
            "netgen-external"
        default:
            backendID
        }
    }

    public static func implementationVersion(for backendID: String) -> String {
        nativeImplementationVersion
    }

    public static func currentExecutableDigest() throws -> String {
        guard let processExecutableDigest else {
            throw LVSError.backendUnavailable(
                "The executable carrying the native LVS implementation could not be attested."
            )
        }
        return processExecutableDigest
    }

    public static func captureInputArtifacts(for request: LVSRequest) throws -> [ArtifactReference] {
        guard request.executionInputArtifacts.isEmpty else {
            return request.executionInputArtifacts
        }
        let inputURLs = [
            request.layoutNetlistURL,
            request.layoutGDSURL,
            Optional(request.schematicNetlistURL),
            request.technologyURL,
            request.extractionProfileURL,
            request.extractionDeckURL,
            request.waiverURL,
            request.modelEquivalenceURL,
            request.terminalEquivalenceURL,
            request.devicePolicyURL,
        ].compactMap { $0 }
        if let nonFileURL = inputURLs.first(where: { !$0.isFileURL }) {
            throw LVSError.invalidInput(
                "LVS input contains non-file artifact URL: \(nonFileURL.absoluteString)"
            )
        }
        var references: [ArtifactReference] = []
        do {
            if let layoutNetlistURL = request.layoutNetlistURL {
                references.append(try reference(url: layoutNetlistURL, kind: .netlist, format: .spice))
            }
            if let layoutGDSURL = request.layoutGDSURL {
                references.append(try reference(
                    url: layoutGDSURL,
                    kind: .layout,
                    format: try layoutFormat(request.layoutFormat, url: layoutGDSURL)
                ))
            }
            references.append(try reference(
                url: request.schematicNetlistURL,
                kind: .netlist,
                format: .spice
            ))
            for input in optionalInputs(request) {
                references.append(try reference(url: input.url, kind: input.kind, format: input.format))
            }
        } catch let error as LVSError {
            throw error
        } catch {
            throw LVSError.invalidInput(
                "LVS input artifact could not be captured immutably: \(error.localizedDescription)"
            )
        }
        return references
    }

    private static func optionalInputs(
        _ request: LVSRequest
    ) -> [(url: URL, kind: ArtifactKind, format: ArtifactFormat)] {
        [
            request.technologyURL.map { ($0, .technology, .json) },
            request.extractionProfileURL.map { ($0, .technology, .json) },
            request.extractionDeckURL.map { ($0, .ruleDeck, .unknown) },
            request.waiverURL.map { ($0, .constraint, .json) },
            request.modelEquivalenceURL.map { ($0, .constraint, .json) },
            request.terminalEquivalenceURL.map { ($0, .constraint, .json) },
            request.devicePolicyURL.map { ($0, .constraint, .json) },
        ].compactMap { $0 }
    }

    private static func reference(
        url: URL,
        kind: ArtifactKind,
        format: ArtifactFormat
    ) throws -> ArtifactReference {
        try LocalArtifactReferencer().reference(
            ArtifactLocator(
                location: ArtifactLocation(fileURL: url),
                role: .input,
                kind: kind,
                format: format
            )
        )
    }

    private static func layoutFormat(
        _ format: LVSLayoutFormat?,
        url: URL
    ) throws -> ArtifactFormat {
        switch format {
        case .gds: .gdsii
        case .oasis: .oasis
        case .cif: try ArtifactFormat(rawValue: "cif")
        case .dxf: try ArtifactFormat(rawValue: "dxf")
        case .auto, nil:
            switch url.pathExtension.lowercased() {
            case "gds", "gdsii": .gdsii
            case "oas", "oasis": .oasis
            case "cif": try ArtifactFormat(rawValue: "cif")
            case "dxf": try ArtifactFormat(rawValue: "dxf")
            default: .unknown
            }
        }
    }

    private static func environmentFingerprint(
        request: LVSRequest,
        toolchain: String
    ) throws -> ExecutionEnvironmentFingerprint {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let environmentDigest = try SHA256ContentDigester().digest(
            data: encoder.encode(request.options.additionalEnvironment),
            using: .sha256
        )
        return try ExecutionEnvironmentFingerprint(
            platform: platform,
            architecture: architecture,
            toolchain: toolchain,
            environmentDigest: environmentDigest
        )
    }

    private static var platform: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let name = "macOS"
        #elseif os(Linux)
        let name = "Linux"
        #elseif os(Windows)
        let name = "Windows"
        #else
        let name = "unknown-platform"
        #endif
        return "\(name)-\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #elseif arch(arm)
        "arm"
        #elseif arch(i386)
        "i386"
        #else
        "unknown-architecture"
        #endif
    }
}
