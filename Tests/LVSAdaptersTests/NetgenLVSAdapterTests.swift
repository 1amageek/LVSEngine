import Foundation
import Synchronization
import Testing
import LVSCore
@testable import LVSAdapters

@Suite("Netgen LVS adapter")
struct NetgenLVSAdapterTests {
    @Test func additionalEnvironmentCannotOverrideReservedKeys() async throws {
        let adapter = NetgenLVSAdapter(toolchain: NetgenLVSToolchain(
            toolVersion: "test-netgen-1.0",
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

    @Test func runRejectsInvalidProgrammaticRequestBeforeLaunchingProcess() async throws {
        let directory = try makeTemporaryDirectory()
        let launchedFlag = directory.appending(path: "launched")
        let executableURL = try makeExecutableScript(
            in: directory,
            name: "fake-netgen",
            body: """
            #!/bin/sh
            touch \(shellSingleQuoted(launchedFlag.path(percentEncoded: false)))
            echo "LVS_DONE"
            """
        )
        let adapter = NetgenLVSAdapter(toolchain: NetgenLVSToolchain(
            toolVersion: "test-netgen-1.0",
            netgenExecutableURL: executableURL,
            setupFileURL: URL(filePath: "/tmp/sky130A_setup.tcl"),
            pdkRoot: "/tmp/pdk",
            driverScriptURL: URL(filePath: "/tmp/lvs.tcl")
        ))
        let layoutNetlistURL = directory.appending(path: "layout.spice")
        let schematicNetlistURL = directory.appending(path: "schematic.spice")
        try Data(".subckt inv\n.ends inv\n".utf8).write(to: layoutNetlistURL)
        try Data(".subckt inv\n.ends inv\n".utf8).write(to: schematicNetlistURL)
        let request = LVSRequest(
            layoutNetlistURL: layoutNetlistURL,
            schematicNetlistURL: schematicNetlistURL,
            topCell: "   ",
            workingDirectory: directory,
            options: LVSOptions(timeoutSeconds: .nan)
        )

        await #expect(throws: LVSError.self) {
            _ = try await adapter.run(request)
        }
        #expect(!FileManager.default.fileExists(atPath: launchedFlag.path(percentEncoded: false)))
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
            toolVersion: "test-netgen-1.0",
            netgenExecutableURL: executableURL,
            setupFileURL: URL(filePath: "/tmp/sky130A_setup.tcl"),
            pdkRoot: "/tmp/pdk",
            driverScriptURL: URL(filePath: "/tmp/lvs.tcl")
        ))
        let layoutURL = directory.appending(path: "layout.spice")
        let schematicURL = directory.appending(path: "schematic.spice")
        try ".subckt inv in out\n.ends inv\n".write(
            to: layoutURL,
            atomically: true,
            encoding: .utf8
        )
        try ".subckt inv in out\n.ends inv\n".write(
            to: schematicURL,
            atomically: true,
            encoding: .utf8
        )
        let request = LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
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
        #expect(first.provenance.producer.identifier == "netgen-external")
        #expect(first.provenance.producer.version == "test-netgen-1.0")
        #expect(first.provenance.producer.build?.count == 64)
        #expect(first.provenance.inputs.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationCheckTerminatesNetgenProcessTree() async throws {
        let directory = try makeTemporaryDirectory()
        let processStarted = directory.appending(path: "process-started")
        let childSurvived = directory.appending(path: "child-survived")
        let executableURL = try makeExecutableScript(
            in: directory,
            name: "fake-netgen-cancel",
            body: """
            #!/bin/sh
            trap '' TERM
            touch \(shellSingleQuoted(processStarted.path(percentEncoded: false)))
            (
                trap '' TERM
                sleep 1
                touch \(shellSingleQuoted(childSurvived.path(percentEncoded: false)))
            ) &
            echo "LVS_STARTED"
            sleep 10
            """
        )
        let adapter = NetgenLVSAdapter(toolchain: NetgenLVSToolchain(
            toolVersion: "test-netgen-1.0",
            netgenExecutableURL: executableURL,
            setupFileURL: URL(filePath: "/tmp/sky130A_setup.tcl"),
            pdkRoot: "/tmp/pdk",
            driverScriptURL: URL(filePath: "/tmp/lvs.tcl")
        ))
        let layoutNetlistURL = directory.appending(path: "cancel-layout.spice")
        let schematicNetlistURL = directory.appending(path: "cancel-schematic.spice")
        try Data(".subckt inv\n.ends inv\n".utf8).write(to: layoutNetlistURL)
        try Data(".subckt inv\n.ends inv\n".utf8).write(to: schematicNetlistURL)
        let request = LVSRequest(
            layoutNetlistURL: layoutNetlistURL,
            schematicNetlistURL: schematicNetlistURL,
            topCell: "inv",
            workingDirectory: directory,
            options: LVSOptions(timeoutSeconds: 5)
        )
        let probe = CancellationProbe()

        let task = Task {
            try await adapter.run(
                request,
                cancellationCheck: {
                    probe.isCancelled
                }
            )
        }
        let didStart = try await waitForFile(at: processStarted, timeoutNanoseconds: 2_000_000_000)
        #expect(didStart)
        probe.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected Netgen LVS cancellation")
        } catch let error as LVSError {
            switch error {
            case .cancelled:
                break
            default:
                Issue.record("Unexpected LVS error: \(error)")
            }
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }

        let didChildSurvive = try await waitForFile(at: childSurvived, timeoutNanoseconds: 1_500_000_000)
        if didChildSurvive {
            Issue.record("Netgen child process survived cancellation")
        }
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

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func waitForFile(at url: URL, timeoutNanoseconds: UInt64) async throws -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                return true
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}

private final class CancellationProbe: Sendable {
    private let state = Mutex(false)

    var isCancelled: Bool {
        state.withLock { $0 }
    }

    func cancel() {
        state.withLock { $0 = true }
    }
}
