import Foundation
import Testing
import LVSCore
import LVSPureSwift

@Suite("Pure Swift LVS backend")
struct PureSwiftLVSBackendTests {
    @Test func matchingSPICENetlistsPassWithoutExternalTool() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(matchingInverter, name: "layout.spice", in: directory)
        let schematicURL = try writeNetlist(matchingInverter, name: "schematic.spice", in: directory)

        let result = try await PureSwiftLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "pure-swift")
        ))

        #expect(result.result.passed)
        #expect(result.result.provenance?.executablePath == "in-process")
    }

    @Test func modelMismatchFails() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(matchingInverter, name: "layout.spice", in: directory)
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos
            M2 out in vss vss nmos_mismatch
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await PureSwiftLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "pure-swift")
        ))

        #expect(!result.result.passed)
        #expect(result.result.diagnostics.contains { $0.ruleID == "LVS_COMPONENT_MISMATCH" })
    }

    @Test func portMismatchFails() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(matchingInverter, name: "layout.spice", in: directory)
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vss vdd
            M1 out in vdd vdd pmos
            M2 out in vss vss nmos
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await PureSwiftLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "pure-swift")
        ))

        #expect(!result.result.passed)
        #expect(result.result.diagnostics.contains { $0.ruleID == "LVS_PORT_MISMATCH" })
    }

    private var matchingInverter: String {
        """
        .subckt inv in out vdd vss
        M1 out in vdd vdd pmos
        M2 out in vss vss nmos
        .ends inv
        """
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PureSwiftLVSBackendTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeNetlist(_ netlist: String, name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try netlist.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
