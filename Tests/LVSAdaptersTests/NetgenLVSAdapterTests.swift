import Foundation
import Testing
import LVSCore
@testable import LVSAdapters

@Suite("Netgen LVS adapter")
struct NetgenLVSAdapterTests {
    @Test func additionalEnvironmentCannotOverrideReservedKeys() async throws {
        let adapter = NetgenLVSAdapter(toolchain: NetgenLVSToolchain(
            netgenExecutableURL: URL(filePath: "/bin/true"),
            setupFileURL: URL(filePath: "/tmp/sky130A_setup.tcl"),
            pdkRoot: "/tmp/pdk",
            driverScriptURL: URL(filePath: "/tmp/lvs.tcl")
        ))
        let request = LVSRequest(
            layoutNetlistURL: URL(filePath: "/tmp/layout.spice"),
            schematicNetlistURL: URL(filePath: "/tmp/schematic.spice"),
            topCell: "inv",
            options: LVSOptions(additionalEnvironment: ["LVS_TOP": "other"])
        )

        var didThrowExpectedError = false
        do {
            _ = try await adapter.run(request)
        } catch let error as LVSError {
            didThrowExpectedError = error == .invalidInput("additionalEnvironment contains reserved keys: LVS_TOP")
        } catch {
            throw error
        }

        #expect(didThrowExpectedError)
    }

    @Test func locatorPrefersHeadlessNetgenExecOverGUIWrapper() throws {
        let directory = try makeTemporaryDirectory()
        let netgenExec = try makeExecutableScript(
            in: directory,
            name: "netgenexec",
            body: "#!/bin/sh\nexit 0\n"
        )
        let wrapper = try makeExecutableScript(
            in: directory,
            name: "netgen",
            body: "#!/bin/sh\nexit 0\n"
        )

        let resolved = NetgenLVSAdapter.resolveNetgenExecutablePath(
            environment: [:],
            fileManager: .default,
            defaultCandidates: [
                netgenExec.path(percentEncoded: false),
                wrapper.path(percentEncoded: false),
            ]
        )

        #expect(resolved == netgenExec.path(percentEncoded: false))
    }

    @Test func explicitNetgenBinOverridesDefaultCandidates() throws {
        let directory = try makeTemporaryDirectory()
        let explicit = directory.appending(path: "explicit-netgen")
        let fallback = try makeExecutableScript(
            in: directory,
            name: "netgenexec",
            body: "#!/bin/sh\nexit 0\n"
        )

        let resolved = NetgenLVSAdapter.resolveNetgenExecutablePath(
            environment: ["NETGEN_BIN": explicit.path(percentEncoded: false)],
            fileManager: .default,
            defaultCandidates: [fallback.path(percentEncoded: false)]
        )

        #expect(resolved == explicit.path(percentEncoded: false))
    }

    @Test func repeatedRunsUseDistinctLogArtifacts() async throws {
        let directory = try makeTemporaryDirectory()
        let executableURL = try makeExecutableScript(
            in: directory,
            name: "fake-netgen",
            body: """
            #!/bin/sh
            echo "LVS_RESULT status=match message=\\"Circuits match uniquely.\\""
            echo "LVS_DONE"
            """
        )
        let adapter = NetgenLVSAdapter(toolchain: NetgenLVSToolchain(
            netgenExecutableURL: executableURL,
            setupFileURL: URL(filePath: "/tmp/sky130A_setup.tcl"),
            pdkRoot: "/tmp/pdk",
            driverScriptURL: URL(filePath: "/tmp/lvs.tcl")
        ))
        let request = LVSRequest(
            layoutNetlistURL: URL(filePath: "/tmp/layout.spice"),
            schematicNetlistURL: URL(filePath: "/tmp/schematic.spice"),
            topCell: "inv",
            workingDirectory: directory
        )

        let first = try await adapter.run(request)
        let second = try await adapter.run(request)

        #expect(first.result.passed)
        #expect(second.result.passed)
        #expect(first.result.logPath != second.result.logPath)
        #expect(FileManager.default.fileExists(atPath: first.result.logPath))
        #expect(FileManager.default.fileExists(atPath: second.result.logPath))
        #expect(first.result.provenance?.executablePath == executableURL.path(percentEncoded: false))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NetgenLVSAdapterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeExecutableScript(in directory: URL, name: String, body: String) throws -> URL {
        let scriptURL = directory.appending(path: name)
        try body.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path(percentEncoded: false)
        )
        return scriptURL
    }
}
