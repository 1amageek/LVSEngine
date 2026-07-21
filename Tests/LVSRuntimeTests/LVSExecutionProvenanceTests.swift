import CircuiteFoundation
import Foundation
import LVSCore
import Testing

@Suite("LVS execution provenance")
struct LVSExecutionProvenanceTests {
    @Test func rejectsInputChangedAfterExecutionSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layoutURL = directory.appending(path: "layout.spice")
        let schematicURL = directory.appending(path: "schematic.spice")
        try Data("layout".utf8).write(to: layoutURL)
        try Data("schematic".utf8).write(to: schematicURL)
        let request = LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            backendSelection: LVSBackendSelection(backendID: "native")
        )
        let inputs = try LVSExecutionProvenance.captureInputArtifacts(for: request)
        try Data("changed-schematic".utf8).write(to: schematicURL, options: .atomic)
        let result = LVSResult(
            backendID: "native",
            toolName: "NativeLVS",
            executionStatus: .completed,
            verdict: .match,
            readiness: .ready,
            logPath: ""
        )

        #expect(throws: LVSError.backendFailed(
            "An LVS input artifact changed during execution."
        )) {
            _ = try LVSExecutionProvenance.make(
                request: request,
                result: result,
                inputArtifacts: inputs,
                invocation: ExecutionInvocation.inProcess(entryPoint: "test"),
                startedAt: Date(timeIntervalSince1970: 1),
                completedAt: Date(timeIntervalSince1970: 2)
            )
        }
    }
}
