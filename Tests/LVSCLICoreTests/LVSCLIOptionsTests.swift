import Testing
import LVSCLICore

@Suite("LVS CLI options")
struct LVSCLIOptionsTests {
    @Test func invalidTimeoutThrows() throws {
        let error = try captureError {
            _ = try LVSCLIOptions(arguments: [
                "--layout-netlist", "/tmp/layout.spice",
                "--schematic-netlist", "/tmp/schematic.spice",
                "--top-cell", "inv",
                "--out", "/tmp/lvs",
                "--timeout", "abc",
            ])
        }

        #expect(error == .invalidValue(
            argument: "--timeout",
            value: "abc",
            expected: "positive finite seconds"
        ))
    }

    @Test func zeroTimeoutThrows() throws {
        let error = try captureError {
            _ = try LVSCLIOptions(arguments: [
                "--layout-netlist", "/tmp/layout.spice",
                "--schematic-netlist", "/tmp/schematic.spice",
                "--top-cell", "inv",
                "--out", "/tmp/lvs",
                "--timeout", "0",
            ])
        }

        #expect(error == .invalidValue(
            argument: "--timeout",
            value: "0",
            expected: "positive finite seconds"
        ))
    }

    @Test func layoutNetlistAndGDSCannotBeSpecifiedTogether() throws {
        let error = try captureError {
            _ = try LVSCLIOptions(arguments: [
                "--layout-netlist", "/tmp/layout.spice",
                "--layout-gds", "/tmp/layout.gds",
                "--schematic-netlist", "/tmp/schematic.spice",
                "--top-cell", "inv",
                "--out", "/tmp/lvs",
            ])
        }

        #expect(error == .conflictingArguments("--layout-netlist", "--layout-gds"))
    }

    private func captureError(_ operation: () throws -> Void) throws -> LVSCLIError? {
        do {
            try operation()
            return nil
        } catch let error as LVSCLIError {
            return error
        } catch {
            throw error
        }
    }
}
