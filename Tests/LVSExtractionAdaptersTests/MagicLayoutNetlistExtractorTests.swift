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
        let extractor = MagicLayoutNetlistExtractor(toolchain: MagicLVSToolchain(
            magicExecutableURL: executableURL,
            rcFileURL: URL(filePath: "/tmp/sky130A.magicrc"),
            pdkRoot: "/tmp/pdk",
            driverScriptURL: URL(filePath: "/tmp/extract_lvs.tcl")
        ))

        let first = try await extractor.extractLayoutNetlist(
            gds: URL(filePath: "/tmp/inverter.gds"),
            topCell: "inv",
            into: directory,
            timeoutSeconds: 5
        )
        let second = try await extractor.extractLayoutNetlist(
            gds: URL(filePath: "/tmp/inverter.gds"),
            topCell: "inv",
            into: directory,
            timeoutSeconds: 5
        )

        #expect(first != second)
        #expect(first.lastPathComponent.hasPrefix("inv-lvs-"))
        #expect(second.lastPathComponent.hasPrefix("inv-lvs-"))
        #expect(FileManager.default.fileExists(atPath: first.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: second.path(percentEncoded: false)))
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
        let extractor = MagicLayoutNetlistExtractor(toolchain: MagicLVSToolchain(
            magicExecutableURL: executableURL,
            rcFileURL: URL(filePath: "/tmp/sky130A.magicrc"),
            pdkRoot: "/tmp/pdk",
            driverScriptURL: URL(filePath: "/tmp/extract_lvs.tcl")
        ))

        let output = try await extractor.extractLayoutNetlist(
            gds: URL(filePath: "/tmp/inverter.gds"),
            topCell: "../escape/cell",
            into: directory,
            timeoutSeconds: 5
        )

        let directoryPath = directory.standardizedFileURL.path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let outputPath = output.standardizedFileURL.path(percentEncoded: false)
        #expect(outputPath.hasPrefix("/" + directoryPath + "/"))
        #expect(output.lastPathComponent.hasPrefix(".._escape_cell-lvs-"))
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
        let extractor = MagicLayoutNetlistExtractor(toolchain: MagicLVSToolchain(
            magicExecutableURL: executableURL,
            rcFileURL: URL(filePath: "/tmp/sky130A.magicrc"),
            pdkRoot: "/tmp/pdk",
            driverScriptURL: URL(filePath: "/tmp/extract_lvs.tcl")
        ))
        let probe = CancellationProbe()

        let task = Task {
            try await extractor.extractLayoutNetlist(
                gds: URL(filePath: "/tmp/inverter.gds"),
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
