import LVSCore
import LVSNetlistParsing
@testable import LVSNative
import Testing

struct NativeLVSGraphBuilderTests {
    @Test
    func derivesCanonicalOccurrenceTreeFromFlattenedComponentNames() throws {
        let netlist = NativeLVSNetlist(
            topCell: "top",
            ports: ["in", "out"],
            components: [
                NativeLVSNetlistComponent(
                    name: "X0/X1/M0",
                    kind: "mos",
                    pins: ["out", "in", "vss", "vss"],
                    model: "nmos"
                ),
                NativeLVSNetlistComponent(
                    name: "X0/X2/R0",
                    kind: "resistor",
                    pins: ["out", "vss"],
                    model: "1k"
                ),
            ]
        )

        let graph = try NativeLVSGraphBuilder().build(
            netlist: netlist,
            modelEquivalence: [:],
            terminalEquivalence: LVSTerminalEquivalenceResolver.defaultSPICEPrimitive(),
            parameterPolicy: .empty,
            maximumObjectCount: 100,
            sharedGlobalNetNames: []
        )

        #expect(graph.occurrences.map(\.instancePath) == ["X0", "X0/X1", "X0/X2"])
        #expect(graph.occurrences.map(\.depth) == [1, 2, 2])
        #expect(graph.occurrences[0].parentOccurrenceID == nil)
        #expect(graph.occurrences[1].parentOccurrenceID == "spice-occurrence:X0")
        #expect(graph.occurrences[2].parentOccurrenceID == "spice-occurrence:X0")
    }
}
