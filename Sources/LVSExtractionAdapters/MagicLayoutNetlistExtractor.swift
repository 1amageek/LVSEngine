import Foundation
import LVSCore
import SignoffToolSupport

public struct MagicLVSToolchain: Sendable, Hashable {
    public let magicExecutableURL: URL
    public let rcFileURL: URL
    public let pdkRoot: String
    public let driverScriptURL: URL

    public init(
        magicExecutableURL: URL,
        rcFileURL: URL,
        pdkRoot: String,
        driverScriptURL: URL
    ) {
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
        let magicPath = environment["MAGIC_BIN"]
            ?? NSString(string: "~/.local/magic/bin/magic").expandingTildeInPath
        guard fileManager.isExecutableFile(atPath: magicPath) else { return nil }
        guard let pdkRoot = Sky130PDKLocator.root(
            requirement: .magic,
            environment: environment,
            fileManager: fileManager
        ) else {
            return nil
        }
        let rcFile = Sky130PDKLocator.requiredFileURL(in: pdkRoot, requirement: .magic)
        guard fileManager.fileExists(atPath: rcFile.path(percentEncoded: false)) else {
            return nil
        }
        return MagicLayoutNetlistExtractor(toolchain: MagicLVSToolchain(
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
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appending(path: "\(topCell)-lvs-\(UUID().uuidString).spice")

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

        let processResult = try await TimedProcessRunner(timeoutSeconds: timeoutSeconds).run(process: process)
        let output = [processResult.standardOutput, processResult.standardError].joined(separator: "\n")
        guard processResult.exitCode == 0, output.contains("EXT_DONE"), !output.contains("EXT_ERROR") else {
            throw LVSError.backendFailed("Magic LVS extraction failed: \(output)")
        }
        guard FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) else {
            throw LVSError.backendFailed("Magic LVS extraction did not produce \(outputURL.path(percentEncoded: false))")
        }
        return outputURL
    }
}
