import CircuiteFoundation
import Foundation
import LVSCore
import LVSParsers
import SignoffToolSupport

public struct NetgenLVSToolchain: Sendable, Hashable {
    public let toolVersion: String
    public let netgenExecutableURL: URL
    public let setupFileURL: URL
    public let pdkRoot: String
    public let driverScriptURL: URL

    public init(
        toolVersion: String,
        netgenExecutableURL: URL,
        setupFileURL: URL,
        pdkRoot: String,
        driverScriptURL: URL
    ) {
        self.toolVersion = toolVersion
        self.netgenExecutableURL = netgenExecutableURL
        self.setupFileURL = setupFileURL
        self.pdkRoot = pdkRoot
        self.driverScriptURL = driverScriptURL
    }
}

public struct NetgenLVSAdapter: LVSCancellableBackend {
    public let toolchain: NetgenLVSToolchain
    private let parser: NetgenLVSReportParser

    public let backendID = "netgen"
    private static let reservedEnvironmentKeys: Set<String> = [
        "PDK_ROOT",
        "LVS_LAYOUT",
        "LVS_SCHEM",
        "LVS_TOP",
        "LVS_SETUP",
        "LVS_OUT",
    ]

    public init(
        toolchain: NetgenLVSToolchain,
        parser: NetgenLVSReportParser = NetgenLVSReportParser()
    ) {
        self.toolchain = toolchain
        self.parser = parser
    }

    public func currentExecutableDigest() throws -> String {
        try SHA256ContentDigester().digest(
            fileAt: toolchain.netgenExecutableURL,
            using: .sha256
        ).hexadecimalValue
    }

    public static var bundledDriverScriptURL: URL? {
        Bundle.module.url(forResource: "lvs", withExtension: "tcl")
    }

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> NetgenLVSAdapter? {
        guard let driver = bundledDriverScriptURL else { return nil }
        guard let toolVersion = environment["NETGEN_VERSION"],
              !toolVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let netgenPath = resolveNetgenExecutablePath(
            environment: environment,
            fileManager: fileManager
        ) else {
            return nil
        }
        guard fileManager.isExecutableFile(atPath: netgenPath) else { return nil }
        let profile: SignoffPDKProfile
        do {
            profile = try SignoffPDKProfile.bundledDefaultProfile()
        } catch {
            return nil
        }
        guard let pdkRoot = SignoffPDKLocator.root(
            requirementID: "netgen",
            profile: profile,
            environment: environment,
            fileManager: fileManager
        ) else {
            return nil
        }
        let setupFile: URL
        do {
            setupFile = try SignoffPDKLocator.requiredFileURL(
                in: pdkRoot,
                profile: profile,
                requirementID: "netgen"
            )
        } catch {
            return nil
        }
        guard fileManager.fileExists(atPath: setupFile.path(percentEncoded: false)) else {
            return nil
        }
        return NetgenLVSAdapter(toolchain: NetgenLVSToolchain(
            toolVersion: toolVersion,
            netgenExecutableURL: URL(filePath: netgenPath),
            setupFileURL: setupFile,
            pdkRoot: pdkRoot,
            driverScriptURL: driver
        ))
    }

    static func resolveNetgenExecutablePath(
        environment: [String: String],
        fileManager: FileManager,
        defaultCandidates: [String] = [
            NSString(string: "~/.local/netgen/lib/netgen/tcl/netgenexec").expandingTildeInPath,
            NSString(string: "~/.local/netgen/bin/netgen").expandingTildeInPath,
        ]
    ) -> String? {
        if let explicit = environment["NETGEN_BIN"] {
            return explicit
        }
        return defaultCandidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    public func run(_ request: LVSRequest) async throws -> LVSExecutionResult {
        try await run(request, cancellationCheck: nil)
    }

    public func run(
        _ request: LVSRequest,
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> LVSExecutionResult {
        try Self.validateAdditionalEnvironment(request.options.additionalEnvironment)
        try Self.validateRequest(request)
        guard let layoutNetlistURL = request.layoutNetlistURL else {
            throw LVSError.invalidInput("Netgen LVS requires a layout netlist")
        }
        let startedAt = Date()
        let inputArtifacts = try LVSExecutionProvenance.captureInputArtifacts(for: request)
        let executableDigest = try SHA256ContentDigester().digest(
            fileAt: toolchain.netgenExecutableURL,
            using: .sha256
        )
        let artifactDirectory = request.workingDirectory ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let artifactID = UUID().uuidString
        let logURL = artifactDirectory.appending(path: "lvs-netgen-\(artifactID).log")
        let reportURL = artifactDirectory.appending(path: "lvs-compare-\(artifactID).out")

        let process = Process()
        process.executableURL = toolchain.netgenExecutableURL
        process.arguments = [
            "-batch",
            "source",
            toolchain.driverScriptURL.path(percentEncoded: false),
        ]
        process.currentDirectoryURL = artifactDirectory
        let requestEnvironment = [
            "PDK_ROOT": toolchain.pdkRoot,
            "LVS_LAYOUT": layoutNetlistURL.path(percentEncoded: false),
            "LVS_SCHEM": request.schematicNetlistURL.path(percentEncoded: false),
            "LVS_TOP": request.topCell,
            "LVS_SETUP": toolchain.setupFileURL.path(percentEncoded: false),
            "LVS_OUT": reportURL.path(percentEncoded: false),
        ]
        process.environment = ProcessInfo.processInfo.environment
            .merging(request.options.additionalEnvironment) { _, new in new }
            .merging(requestEnvironment) { _, new in new }

        let processResult: TimedProcessResult
        do {
            processResult = try await TimedProcessRunner(
                timeoutSeconds: request.options.timeoutSeconds,
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
                throw LVSError.cancelled(output.isEmpty ? "Netgen LVS process was cancelled." : output)
            case .cancellationCheckFailed(_, let message, let standardOutput, let standardError):
                let output = [standardOutput, standardError, message]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                throw LVSError.backendFailed(output)
            default:
                throw error
            }
        }
        let rawOutput = [processResult.standardOutput, processResult.standardError].joined(separator: "\n")
        let log = renderLog(request: request, layoutNetlistURL: layoutNetlistURL, exitCode: processResult.exitCode, rawOutput: rawOutput)
        do {
            try log.write(to: logURL, atomically: true, encoding: .utf8)
        } catch {
            throw LVSError.artifactWriteFailed(error.localizedDescription)
        }

        let parsed = parser.parse(
            logPath: logURL.path(percentEncoded: false),
            rawOutput: rawOutput,
            success: processResult.exitCode == 0,
            provenance: LVSToolProvenance(
                executablePath: toolchain.netgenExecutableURL.path(percentEncoded: false),
                pdkRoot: toolchain.pdkRoot,
                setupFilePath: toolchain.setupFileURL.path(percentEncoded: false),
                driverScriptPath: toolchain.driverScriptURL.path(percentEncoded: false),
                timeoutSeconds: request.options.timeoutSeconds
            )
        )
        let completedDigest = try SHA256ContentDigester().digest(
            fileAt: toolchain.netgenExecutableURL,
            using: .sha256
        )
        guard completedDigest == executableDigest else {
            throw LVSError.backendFailed("Netgen executable changed during LVS execution.")
        }
        return LVSExecutionResult(
            request: request,
            result: parsed,
            provenance: try LVSExecutionProvenance.make(
                request: request,
                result: parsed,
                implementationID: "netgen-external",
                implementationVersion: toolchain.toolVersion,
                implementationBuild: executableDigest.hexadecimalValue,
                inputArtifacts: inputArtifacts,
                invocation: ExecutionInvocation.externalProcess(
                    executable: toolchain.netgenExecutableURL.path(percentEncoded: false),
                    arguments: process.arguments ?? [],
                    workingDirectory: artifactDirectory.path(percentEncoded: false)
                ),
                startedAt: startedAt,
                completedAt: Date()
            )
        )
    }

    private func renderLog(request: LVSRequest, layoutNetlistURL: URL, exitCode: Int32, rawOutput: String) -> String {
        """
        tool=netgen
        kind=lvs
        layout_netlist=\(layoutNetlistURL.path(percentEncoded: false))
        schematic_netlist=\(request.schematicNetlistURL.path(percentEncoded: false))
        top_cell=\(request.topCell)
        exit_code=\(exitCode)

        [output]
        \(rawOutput)
        """
    }

    private static func validateAdditionalEnvironment(_ environment: [String: String]) throws {
        let reservedKeys = environment.keys
            .filter { reservedEnvironmentKeys.contains($0) }
            .sorted()
        guard reservedKeys.isEmpty else {
            throw LVSError.invalidInput("additionalEnvironment contains reserved keys: \(reservedKeys.joined(separator: ", "))")
        }
    }

    private static func validateRequest(_ request: LVSRequest) throws {
        guard request.options.timeoutSeconds.isFinite, request.options.timeoutSeconds > 0 else {
            throw LVSError.invalidInput("timeoutSeconds must be positive finite seconds")
        }
        guard !request.topCell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LVSError.invalidInput("topCell must be non-empty")
        }
    }
}
