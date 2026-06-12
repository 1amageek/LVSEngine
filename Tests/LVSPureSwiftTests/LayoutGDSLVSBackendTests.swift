import Foundation
import Testing
import LVSCore
import LayoutAutoGen
import LayoutCore
import LayoutIO
import LayoutTech
@testable import LVSPureSwift

/// Pure Swift LVS on STANDARD inputs: an in-code generated MOSFET goes
/// through GDS (where pins and nets die by format contract) and the
/// backend still matches it against the `.subckt` reference, because
/// extraction reads net labels straight off the conductors.
@Suite("Layout GDS LVS backend", .timeLimit(.minutes(2)))
struct LayoutGDSLVSBackendTests {

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "gds-lvs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeTech(in root: URL) throws -> URL {
        let url = root.appending(path: "tech.json")
        try (try JSONEncoder().encode(LayoutTechDatabase.sampleProcess())).write(to: url)
        return url
    }

    /// One generated NMOS, terminals labeled with the reference net
    /// names at the pin positions, exported to GDS.
    private func writeDeviceGDS(in root: URL) throws -> URL {
        let tech = LayoutTechDatabase.sampleProcess()
        var cell = try MOSFETCellGenerator().generateCell(
            deviceKindID: "nmos",
            instanceName: "M1",
            parameters: ["w": 2.0, "l": 0.18, "nf": 1],
            tech: tech
        )
        cell.name = "TOP"
        let netByPin = ["drain": "d", "gate": "g", "source": "s", "bulk": "b"]
        for pin in cell.pins {
            guard let net = netByPin[pin.name] else { continue }
            cell.labels.append(LayoutLabel(text: net, position: pin.position, layer: pin.layer))
        }
        let document = LayoutDocument(name: "TOP", cells: [cell], topCellID: cell.id)
        let url = root.appending(path: "top.gds")
        try GDSFormatConverter(tech: tech).exportDocument(document, to: url, format: .gds)
        return url
    }

    private func writeSchematic(_ text: String, in root: URL) throws -> URL {
        let url = root.appending(path: "reference.spice")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func matchingDevicePasses() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: try writeDeviceGDS(in: root),
            schematicNetlistURL: try writeSchematic(
                """
                .subckt top d g s b
                M1 d g s b nmos W=2u L=0.18u
                .ends
                """,
                in: root
            ),
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            workingDirectory: root
        ))

        #expect(execution.result.passed, "\(execution.result.diagnostics.map(\.message))")
        #expect(FileManager.default.fileExists(atPath: execution.result.logPath))
    }

    @Test func wrongDeviceKindFails() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: try writeDeviceGDS(in: root),
            schematicNetlistURL: try writeSchematic(
                """
                .subckt top d g s b
                M1 d g s b pmos W=2u L=0.18u
                .ends
                """,
                in: root
            ),
            topCell: "TOP",
            technologyURL: try writeTech(in: root)
        ))

        #expect(!execution.result.passed)
        #expect(execution.result.diagnostics.contains { $0.ruleID == "compare.unmatchedReference" })
    }

    @Test func wrongParametersFail() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: try writeDeviceGDS(in: root),
            schematicNetlistURL: try writeSchematic(
                """
                .subckt top d g s b
                M1 d g s b nmos W=4u L=0.18u
                .ends
                """,
                in: root
            ),
            topCell: "TOP",
            technologyURL: try writeTech(in: root)
        ))

        #expect(!execution.result.passed)
        #expect(execution.result.diagnostics.contains { $0.ruleID == "compare.parameterMismatch" })
    }

    @Test func missingTechnologyIsInvalidInput() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: LVSError.self) {
            _ = try await LayoutGDSLVSBackend().run(LVSRequest(
                layoutGDSURL: try writeDeviceGDS(in: root),
                schematicNetlistURL: try writeSchematic(".subckt top\n.ends", in: root),
                topCell: "TOP"
            ))
        }
    }
}
