import CircuiteFoundation
import Foundation
import LVSCore
import SignoffToolSupport

public struct MagicLVSToolchain: Sendable, Hashable {
    public let toolVersion: String
    public let magicExecutableURL: URL
    public let rcFileURL: URL
    public let pdkRoot: String
    public let driverScriptURL: URL

    public init(
        toolVersion: String,
        magicExecutableURL: URL,
        rcFileURL: URL,
        pdkRoot: String,
        driverScriptURL: URL
    ) {
        self.toolVersion = toolVersion
        self.magicExecutableURL = magicExecutableURL
        self.rcFileURL = rcFileURL
        self.pdkRoot = pdkRoot
        self.driverScriptURL = driverScriptURL
    }
}

public struct MagicLayoutNetlistExtractor: LVSLayoutNetlistExtracting {
    public let toolchain: MagicLVSToolchain

    public init(toolchain: MagicLVSToolchain) {
        self.toolchain = toolchain
    }

    public static var bundledDriverScriptURL: URL? {
        Bundle.module.url(forResource: "extract_lvs", withExtension: "tcl")
    }

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> MagicLayoutNetlistExtractor? {
        guard let driver = bundledDriverScriptURL else { return nil }
        guard let toolVersion = environment["MAGIC_VERSION"],
              !toolVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let magicPath = environment["MAGIC_BIN"]
            ?? NSString(string: "~/.local/magic/bin/magic").expandingTildeInPath
        guard fileManager.isExecutableFile(atPath: magicPath) else { return nil }
        let profile: SignoffPDKProfile
        do {
            profile = try SignoffPDKProfile.bundledDefaultProfile()
        } catch {
            return nil
        }
        guard let pdkRoot = SignoffPDKLocator.root(
            requirementID: "magic",
            profile: profile,
            environment: environment,
            fileManager: fileManager
        ) else {
            return nil
        }
        let rcFile: URL
        do {
            rcFile = try SignoffPDKLocator.requiredFileURL(
                in: pdkRoot,
                profile: profile,
                requirementID: "magic"
            )
        } catch {
            return nil
        }
        guard fileManager.fileExists(atPath: rcFile.path(percentEncoded: false)) else {
            return nil
        }
        return MagicLayoutNetlistExtractor(toolchain: MagicLVSToolchain(
            toolVersion: toolVersion,
            magicExecutableURL: URL(filePath: magicPath),
            rcFileURL: rcFile,
            pdkRoot: pdkRoot,
            driverScriptURL: driver
        ))
    }

    public func extractLayoutNetlist(
        gds: URL,
        topCell: String,
        into directory: URL,
        timeoutSeconds: Double
    ) async throws -> LVSLayoutNetlistExtractionResult {
        try await extractLayoutNetlist(
            gds: gds,
            topCell: topCell,
            into: directory,
            timeoutSeconds: timeoutSeconds,
            cancellationCheck: nil
        )
    }

    public func extractLayoutNetlist(
        gds: URL,
        topCell: String,
        into directory: URL,
        timeoutSeconds: Double,
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> LVSLayoutNetlistExtractionResult {
        let startedAt = Date()
        let digester = SHA256ContentDigester()
        let executableDigest = try digester.digest(
            fileAt: toolchain.magicExecutableURL,
            using: .sha256
        )
        let inputArtifacts = try [
            artifactReference(
                at: gds,
                role: .input,
                kind: .layout,
                format: .gdsii,
                producer: nil
            ),
            artifactReference(
                at: toolchain.rcFileURL,
                role: .input,
                kind: .technology,
                format: .unknown,
                producer: nil
            ),
            artifactReference(
                at: toolchain.driverScriptURL,
                role: .input,
                kind: .ruleDeck,
                format: .unknown,
                producer: nil
            ),
        ]
        let outputStem = try Self.outputFileStem(for: topCell)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appending(path: "\(outputStem)-lvs-\(UUID().uuidString).spice")

        let process = Process()
        process.executableURL = toolchain.magicExecutableURL
        process.arguments = [
            "-dnull",
            "-noconsole",
            "-rcfile",
            toolchain.rcFileURL.path(percentEncoded: false),
            toolchain.driverScriptURL.path(percentEncoded: false),
        ]
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PDK_ROOT": toolchain.pdkRoot,
            "EXT_GDS": gds.path(percentEncoded: false),
            "EXT_CELL": topCell,
            "EXT_OUT": outputURL.path(percentEncoded: false),
            "MAGTYPE": "mag",
        ]) { _, new in new }

        let processResult: TimedProcessResult
        do {
            processResult = try await TimedProcessRunner(
                timeoutSeconds: timeoutSeconds,
                terminationGraceSeconds: 0.1,
                pipeDrainGraceSeconds: 0.05
            ).run(
                process: process,
                cancellationCheck: cancellationCheck
            )
        } catch let error as TimedProcessError {
            switch error {
            case .cancelled(_, let standardOutput, let standardError):
                let output = [standardOutput, standardError]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                throw LVSError.cancelled(output.isEmpty ? "Magic LVS extraction process was cancelled." : output)
            case .cancellationCheckFailed(_, let message, let standardOutput, let standardError):
                let output = [standardOutput, standardError, message]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                throw LVSError.backendFailed(output)
            default:
                throw error
            }
        }
        let output = [processResult.standardOutput, processResult.standardError].joined(separator: "\n")
        guard processResult.exitCode == 0, output.contains("EXT_DONE"), !output.contains("EXT_ERROR") else {
            throw LVSError.backendFailed("Magic LVS extraction failed: \(output)")
        }
        guard FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) else {
            throw LVSError.backendFailed("Magic LVS extraction did not produce \(outputURL.path(percentEncoded: false))")
        }
        let completedExecutableDigest = try digester.digest(
            fileAt: toolchain.magicExecutableURL,
            using: .sha256
        )
        guard completedExecutableDigest == executableDigest else {
            throw LVSError.backendFailed("Magic executable changed during LVS layout extraction.")
        }
        let producer = try ProducerIdentity(
            kind: .tool,
            identifier: "magic-layout-extractor",
            version: toolchain.toolVersion,
            build: executableDigest.hexadecimalValue
        )
        let netlist = try artifactReference(
            at: outputURL,
            role: .output,
            kind: .netlist,
            format: .spice,
            producer: producer
        )
        let provenance = try ExecutionProvenance(
            producer: producer,
            inputs: inputArtifacts,
            invocation: ExecutionInvocation.externalProcess(
                executable: toolchain.magicExecutableURL.path(percentEncoded: false),
                arguments: process.arguments ?? [],
                workingDirectory: directory.path(percentEncoded: false)
            ),
            environment: try environmentFingerprint(topCell: topCell),
            startedAt: startedAt,
            completedAt: Date()
        )
        return LVSLayoutNetlistExtractionResult(
            netlist: netlist,
            provenance: provenance
        )
    }

    private func artifactReference(
        at url: URL,
        role: ArtifactRole,
        kind: ArtifactKind,
        format: ArtifactFormat,
        producer: ProducerIdentity?
    ) throws -> ArtifactReference {
        try LocalArtifactReferencer().reference(
            ArtifactLocator(
                location: try ArtifactLocation(fileURL: url),
                role: role,
                kind: kind,
                format: format
            ),
            producer: producer
        )
    }

    private func environmentFingerprint(
        topCell: String
    ) throws -> ExecutionEnvironmentFingerprint {
        let values = [
            "EXT_CELL": topCell,
            "MAGTYPE": "mag",
            "PDK_ROOT": toolchain.pdkRoot,
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let environmentDigest = try SHA256ContentDigester().digest(
            data: encoder.encode(values),
            using: .sha256
        )
        return try ExecutionEnvironmentFingerprint(
            platform: Self.platform,
            architecture: Self.architecture,
            toolchain: "magic-layout-extractor-\(toolchain.toolVersion)",
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

    private static func outputFileStem(for topCell: String) throws -> String {
        let trimmed = topCell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LVSError.invalidInput("topCell must be non-empty")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = trimmed.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let stem = String(scalars)
        guard stem != "." && stem != ".." else {
            throw LVSError.invalidInput("topCell does not produce a safe artifact name")
        }
        return stem
    }
}
