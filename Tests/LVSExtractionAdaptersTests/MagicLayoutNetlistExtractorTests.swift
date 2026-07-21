import Foundation
import Synchronization
import Testing
import LVSCore
import LVSExtractionAdapters

@Suite("Magic layout netlist extractor")
struct MagicLayoutNetlistExtractorTests {
    @Test func repeatedExtractionsDoNotOverwriteExistingNetlists() async throws {
        let directory = try makeTemporaryDirectory()
        let executableURL = try makeExecutableScript(
            in: directory,
            name: "fake-magic",
            body: """
            #!/bin/sh
            echo "* extracted layout netlist" > "$EXT_OUT"
            echo "EXT_DONE"
            """
        )
        let (toolchain, gdsURL) = try makeToolchain(
            executableURL: executableURL,
            directory: directory
        )
        let extractor = MagicLayoutNetlistExtractor(toolchain: toolchain)

        let first = try await extractor.extractLayoutNetlist(
            gds: gdsURL,
            topCell: "inv",
            into: directory,
            timeoutSeconds: 5
        )
        let second = try await extractor.extractLayoutNetlist(
            gds: gdsURL,
            topCell: "inv",
            into: directory,
            timeoutSeconds: 5
        )

        let firstURL = try first.netlistFileURL()
        let secondURL = try second.netlistFileURL()
        #expect(first != second)
        #expect(firstURL.lastPathComponent.hasPrefix("inv-lvs-"))
        #expect(secondURL.lastPathComponent.hasPrefix("inv-lvs-"))
        #expect(FileManager.default.fileExists(atPath: firstURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: secondURL.path(percentEncoded: false)))
        #expect(first.netlist.producer == first.provenance.producer)
    }

    @Test func extractionOutputFileNameDoesNotUseTopCellPathSegments() async throws {
        let directory = try makeTemporaryDirectory()
        let executableURL = try makeExecutableScript(
            in: directory,
            name: "fake-magic-safe-output",
            body: """
            #!/bin/sh
            echo "* extracted layout netlist for $EXT_CELL" > "$EXT_OUT"
            echo "EXT_DONE"
            """
        )
        let (toolchain, gdsURL) = try makeToolchain(
            executableURL: executableURL,
            directory: directory
        )
        let extractor = MagicLayoutNetlistExtractor(toolchain: toolchain)

        let output = try await extractor.extractLayoutNetlist(
            gds: gdsURL,
            topCell: "../escape/cell",
            into: directory,
            timeoutSeconds: 5
        )

        let directoryPath = directory.standardizedFileURL.path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let outputURL = try output.netlistFileURL()
        let outputPath = outputURL.standardizedFileURL.path(percentEncoded: false)
        #expect(outputPath.hasPrefix("/" + directoryPath + "/"))
        #expect(outputURL.lastPathComponent.hasPrefix(".._escape_cell-lvs-"))
        #expect(FileManager.default.fileExists(atPath: outputPath))
        #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appending(path: "escape").path(percentEncoded: false)))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationCheckTerminatesMagicExtractionProcessTree() async throws {
        let directory = try makeTemporaryDirectory()
        let processStarted = directory.appending(path: "process-started")
        let childSurvived = directory.appending(path: "child-survived")
        let executableURL = try makeExecutableScript(
            in: directory,
            name: "fake-magic-extract-cancel",
            body: """
            #!/bin/sh
            trap '' TERM
            touch \(shellSingleQuoted(processStarted.path(percentEncoded: false)))
            (
                trap '' TERM
                sleep 1
                touch \(shellSingleQuoted(childSurvived.path(percentEncoded: false)))
            ) &
            echo "EXT_STARTED"
            sleep 10
            """
        )
        let (toolchain, gdsURL) = try makeToolchain(
            executableURL: executableURL,
            directory: directory
        )
        let extractor = MagicLayoutNetlistExtractor(toolchain: toolchain)
        let probe = CancellationProbe()

        let task = Task {
            try await extractor.extractLayoutNetlist(
                gds: gdsURL,
                topCell: "inv",
                into: directory,
                timeoutSeconds: 5,
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
            Issue.record("Expected Magic LVS extraction cancellation")
        } catch let error as LVSError {
            switch error {
            case .cancelled:
                break
            default:
                Issue.record("Unexpected LVS extraction error: \(error)")
            }
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }

        let didChildSurvive = try await waitForFile(at: childSurvived, timeoutNanoseconds: 1_500_000_000)
        if didChildSurvive {
            Issue.record("Magic LVS extraction child process survived cancellation")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MagicLayoutNetlistExtractorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeToolchain(
        executableURL: URL,
        directory: URL
    ) throws -> (MagicLVSToolchain, URL) {
        let gdsURL = directory.appending(path: "inverter.gds")
        let rcFileURL = directory.appending(path: "sky130A.magicrc")
        let driverScriptURL = directory.appending(path: "extract_lvs.tcl")
        try Data([0]).write(to: gdsURL)
        try Data("tech sky130A\n".utf8).write(to: rcFileURL)
        try Data("# extraction driver\n".utf8).write(to: driverScriptURL)
        return (
            MagicLVSToolchain(
                toolVersion: "test-magic-1.0",
                magicExecutableURL: executableURL,
                rcFileURL: rcFileURL,
                pdkRoot: directory.path(percentEncoded: false),
                driverScriptURL: driverScriptURL
            ),
            gdsURL
        )
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
