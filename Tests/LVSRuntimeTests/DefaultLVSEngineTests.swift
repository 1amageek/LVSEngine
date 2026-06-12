import Foundation
import Testing
import LVSCore
import LVSRuntime

@Suite("Default LVS engine")
struct DefaultLVSEngineTests {
    @Test func injectedExtractorPreparesLayoutNetlistForBackend() async throws {
        let directory = try makeTemporaryDirectory()
        let request = LVSRequest(
            layoutGDSURL: URL(filePath: "/tmp/inverter.gds"),
            schematicNetlistURL: URL(filePath: "/tmp/inverter.spice"),
            topCell: "inv",
            workingDirectory: directory,
            backendSelection: LVSBackendSelection(backendID: "stub")
        )

        let result = try await DefaultLVSEngine(
            backend: StubLVSBackend(),
            layoutNetlistExtractor: StubLayoutNetlistExtractor()
        ).run(request)

        #expect(result.result.passed)
        #expect(result.extractedLayoutNetlistURL?.lastPathComponent.hasPrefix("inv.extracted") == true)
        #expect(result.request.layoutNetlistURL == directory.appending(path: "inv.extracted.spice"))
        #expect(result.reportURL?.lastPathComponent.hasPrefix("lvs-report-") == true)
        #expect(result.reportURL?.pathExtension == "json")
        let reportURL = try #require(result.reportURL)
        let data = try Data(contentsOf: reportURL)
        let decoded = try JSONDecoder().decode(LVSExecutionResult.self, from: data)
        #expect(decoded.result.provenance?.executablePath == "/bin/stub-lvs")
    }

    @Test func existingLayoutNetlistDoesNotRequireExtractor() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutNetlistURL = directory.appending(path: "layout.spice")
        let request = LVSRequest(
            layoutNetlistURL: layoutNetlistURL,
            schematicNetlistURL: URL(filePath: "/tmp/inverter.spice"),
            topCell: "inv",
            workingDirectory: directory,
            backendSelection: LVSBackendSelection(backendID: "stub")
        )

        let result = try await DefaultLVSEngine(
            backend: StubLVSBackend(),
            layoutNetlistExtractor: FailingLayoutNetlistExtractor()
        ).run(request)

        #expect(result.result.passed)
        #expect(result.extractedLayoutNetlistURL == nil)
        #expect(result.request.layoutNetlistURL == layoutNetlistURL)
    }

    @Test func pureSwiftBackendIsAvailableByDefault() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutNetlistURL = directory.appending(path: "layout.spice")
        let schematicNetlistURL = directory.appending(path: "schematic.spice")
        let netlist = """
        .subckt inv in out vdd vss
        M1 out in vdd vdd pmos
        M2 out in vss vss nmos
        .ends inv
        """
        try netlist.write(to: layoutNetlistURL, atomically: true, encoding: .utf8)
        try netlist.write(to: schematicNetlistURL, atomically: true, encoding: .utf8)

        let result = try await DefaultLVSEngine(
            backend: nil,
            layoutNetlistExtractor: nil
        ).run(LVSRequest(
            layoutNetlistURL: layoutNetlistURL,
            schematicNetlistURL: schematicNetlistURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "pure-swift")
        ))

        #expect(result.result.passed)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DefaultLVSEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private struct StubLVSBackend: LVSBackend {
        let backendID = "stub"

        func run(_ request: LVSRequest) async throws -> LVSExecutionResult {
            guard request.layoutNetlistURL != nil else {
                throw LVSError.invalidInput("Stub LVS backend requires a layout netlist")
            }
            return LVSExecutionResult(
                request: request,
                result: LVSResult(
                    backendID: backendID,
                    toolName: "stub-lvs",
                    success: true,
                    completed: true,
                    logPath: "/tmp/stub-lvs.log",
                    provenance: LVSToolProvenance(
                        executablePath: "/bin/stub-lvs",
                        pdkRoot: "/tmp/pdk",
                        setupFilePath: "/tmp/sky130A_setup.tcl",
                        driverScriptPath: "/tmp/lvs.tcl",
                        timeoutSeconds: request.options.timeoutSeconds
                    )
                )
            )
        }
    }

    private struct StubLayoutNetlistExtractor: LVSLayoutNetlistExtracting {
        func extractLayoutNetlist(
            gds: URL,
            topCell: String,
            into directory: URL,
            timeoutSeconds: Double
        ) async throws -> URL {
            let outputURL = directory.appending(path: "\(topCell).extracted.spice")
            try Data().write(to: outputURL)
            return outputURL
        }
    }

    private struct FailingLayoutNetlistExtractor: LVSLayoutNetlistExtracting {
        func extractLayoutNetlist(
            gds: URL,
            topCell: String,
            into directory: URL,
            timeoutSeconds: Double
        ) async throws -> URL {
            throw LVSError.backendFailed("Extractor should not be called")
        }
    }
}
