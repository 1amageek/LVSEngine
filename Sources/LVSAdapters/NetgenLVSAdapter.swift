import Foundation
import LVSCore
import LVSParsers
import SignoffToolSupport

public struct NetgenLVSToolchain: Sendable, Hashable {
    public let netgenExecutableURL: URL
    public let setupFileURL: URL
    public let pdkRoot: String
    public let driverScriptURL: URL

    public init(
        netgenExecutableURL: URL,
        setupFileURL: URL,
        pdkRoot: String,
        driverScriptURL: URL
    ) {
        self.netgenExecutableURL = netgenExecutableURL
        self.setupFileURL = setupFileURL
        self.pdkRoot = pdkRoot
        self.driverScriptURL = driverScriptURL
    }
}

public struct NetgenLVSAdapter: LVSBackend {
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

    public static var bundledDriverScriptURL: URL? {
        Bundle.module.url(forResource: "lvs", withExtension: "tcl")
    }

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> NetgenLVSAdapter? {
        guard let driver = bundledDriverScriptURL else { return nil }
        guard let netgenPath = resolveNetgenExecutablePath(
            environment: environment,
            fileManager: fileManager
        ) else {
            return nil
        }
        guard fileManager.isExecutableFile(atPath: netgenPath) else { return nil }
        guard let pdkRoot = Sky130PDKLocator.root(
            requirement: .netgen,
            environment: environment,
            fileManager: fileManager
        ) else {
            return nil
        }
        let setupFile = Sky130PDKLocator.requiredFileURL(in: pdkRoot, requirement: .netgen)
        guard fileManager.fileExists(atPath: setupFile.path(percentEncoded: false)) else {
            return nil
        }
        return NetgenLVSAdapter(toolchain: NetgenLVSToolchain(
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
        try Self.validateAdditionalEnvironment(request.options.additionalEnvironment)
        guard let layoutNetlistURL = request.layoutNetlistURL else {
            throw LVSError.invalidInput("Netgen LVS requires a layout netlist")
        }
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

        let processResult = try await TimedProcessRunner(timeoutSeconds: request.options.timeoutSeconds).run(process: process)
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
        return LVSExecutionResult(request: request, result: parsed)
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
}
