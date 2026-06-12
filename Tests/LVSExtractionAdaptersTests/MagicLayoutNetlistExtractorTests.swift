import Foundation
import Testing
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
}
