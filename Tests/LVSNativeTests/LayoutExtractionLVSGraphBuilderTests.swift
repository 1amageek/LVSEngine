import LayoutLVSExtraction
import LVSCore
import LVSNative
import Testing

struct LayoutExtractionLVSGraphBuilderTests {
    @Test
    func preservesStableObjectsPortsAndMOSExchangeability() throws {
        let source = LayoutExtractionObjectID(rawValue: "net:source")
        let gate = LayoutExtractionObjectID(rawValue: "net:gate")
        let drain = LayoutExtractionObjectID(rawValue: "net:drain")
        let bulk = LayoutExtractionObjectID(rawValue: "net:bulk")
        let occurrence = LayoutExtractionObjectID(rawValue: "occurrence:m1")
        let extraction = LayoutExtractionIR(
            processID: "test",
            processProfileID: "test.profile",
            extractionDeckDigest: "digest",
            deckUseScope: .processProvided,
            topCell: "inverter",
            devices: [
                LayoutExtractionDevice(
                    id: LayoutExtractionObjectID(rawValue: "device:m1"),
                    model: "nmos",
                    family: "mosfet",
                    terminals: [
                        LayoutExtractionTerminal(index: 0, role: "drain", netID: drain),
                        LayoutExtractionTerminal(index: 1, role: "gate", netID: gate),
                        LayoutExtractionTerminal(index: 2, role: "source", netID: source),
                        LayoutExtractionTerminal(index: 3, role: "bulk", netID: bulk),
                    ],
                    parameters: ["w": "1u", "l": "0.15u"],
                    occurrenceIDs: [occurrence],
                    deckRuleID: "rule:nmos"
                ),
            ],
            nets: [source, gate, drain, bulk].map {
                LayoutExtractionNet(id: $0, preferredName: $0.rawValue, occurrenceIDs: [occurrence])
            },
            ports: [
                LayoutExtractionPort(name: "D", position: 0, netID: drain, occurrenceIDs: [occurrence]),
                LayoutExtractionPort(name: "G", position: 1, netID: gate, occurrenceIDs: [occurrence]),
            ],
            occurrences: [
                LayoutExtractionOccurrence(
                    objectID: occurrence,
                    cellName: "inverter",
                    hierarchyPath: ["inverter", "m1"],
                    sourceObjectID: "m1",
                    transformDescription: "identity"
                ),
            ]
        )

        let graph = try LayoutExtractionLVSGraphBuilder().build(
            from: extraction,
            maximumObjectCount: 100
        )

        #expect(graph.devices.count == 1)
        #expect(graph.devices[0].id.rawValue == "layout:device:m1")
        #expect(graph.devices[0].kind == "mos")
        #expect(graph.devices[0].equivalentTerminalGroups == [[0, 2]])
        #expect(graph.ports.map(\.name) == ["d", "g"])
        #expect(graph.devices[0].parameters.first { $0.name == "w" }?.numericValue == 1e-6)
        #expect(graph.occurrences.count == 1)
        #expect(graph.occurrences[0].instancePath == "m1")
        #expect(graph.occurrences[0].depth == 1)
        #expect(graph.occurrences[0].parentOccurrenceID == nil)
    }

    @Test
    func canonicalizesAlternatingGeometryHierarchyAsInstanceOccurrences() throws {
        let extraction = LayoutExtractionIR(
            processID: "test",
            processProfileID: "test.profile",
            extractionDeckDigest: "digest",
            deckUseScope: .processProvided,
            topCell: "top",
            devices: [],
            nets: [],
            ports: [],
            occurrences: [
                LayoutExtractionOccurrence(
                    objectID: LayoutExtractionObjectID(rawValue: "occurrence:/top"),
                    cellName: "top",
                    hierarchyPath: ["top"],
                    transformDescription: "identity"
                ),
                LayoutExtractionOccurrence(
                    objectID: LayoutExtractionObjectID(rawValue: "occurrence:/top/X0#0[0]/child"),
                    cellName: "child",
                    hierarchyPath: ["top", "X0#0[0]", "child"],
                    transformDescription: "identity"
                ),
                LayoutExtractionOccurrence(
                    objectID: LayoutExtractionObjectID(rawValue: "occurrence:/top/X0#0[0]/child/X1#0[0]/leaf"),
                    cellName: "leaf",
                    hierarchyPath: ["top", "X0#0[0]", "child", "X1#0[0]", "leaf"],
                    transformDescription: "identity"
                ),
            ]
        )

        let graph = try LayoutExtractionLVSGraphBuilder().build(
            from: extraction,
            maximumObjectCount: 100
        )

        #expect(graph.occurrences.map(\.instancePath) == [
            "X0#0[0]",
            "X0#0[0]/X1#0[0]",
        ])
        #expect(graph.occurrences.map(\.depth) == [1, 2])
        #expect(graph.occurrences[1].parentOccurrenceID == "layout-occurrence:X0#0[0]")
    }

    @Test
    func appliesExplicitMicronScalarConventionWithoutInspectingModelName() throws {
        let net = LayoutExtractionObjectID(rawValue: "net:shared")
        let extraction = LayoutExtractionIR(
            processID: "test",
            processProfileID: "test.micron-scalar",
            extractionDeckDigest: "digest",
            deckUseScope: .processProvided,
            parameterValueConvention: .micronScalar,
            topCell: "top",
            devices: [
                LayoutExtractionDevice(
                    id: LayoutExtractionObjectID(rawValue: "device:m1"),
                    model: "model-without-name-convention",
                    family: "mosfet",
                    terminals: [
                        LayoutExtractionTerminal(index: 0, role: "drain", netID: net),
                    ],
                    typedParameters: [
                        LayoutExtractionTypedParameter(
                            name: "w",
                            kind: .number,
                            canonicalValue: "0.65",
                            numericValue: 0.65,
                            unit: "um"
                        ),
                    ],
                    occurrenceIDs: [],
                    deckRuleID: "rule:m1"
                ),
            ],
            nets: [LayoutExtractionNet(id: net, preferredName: "shared", occurrenceIDs: [])],
            ports: [],
            occurrences: []
        )

        let graph = try LayoutExtractionLVSGraphBuilder().build(
            from: extraction,
            maximumObjectCount: 100
        )

        #expect(graph.devices[0].parameters.first?.numericValue == 0.65)
    }

    @Test
    func rejectsExtractionWithBlockingIssue() {
        let extraction = LayoutExtractionIR(
            processID: "test",
            processProfileID: "test.profile",
            extractionDeckDigest: "digest",
            deckUseScope: .processProvided,
            topCell: "top",
            devices: [],
            nets: [],
            ports: [],
            occurrences: [],
            issues: [
                LayoutExtractionIssue(
                    code: "missing-child",
                    severity: .blocking,
                    message: "A child cell is unavailable."
                ),
            ]
        )

        #expect(throws: (any Error).self) {
            try LayoutExtractionLVSGraphBuilder().build(
                from: extraction,
                maximumObjectCount: 100
            )
        }
    }

    @Test
    func rejectsDuplicateNetIdentifiers() {
        let duplicatedID = LayoutExtractionObjectID(rawValue: "net:duplicate")
        let extraction = LayoutExtractionIR(
            processID: "test",
            processProfileID: "test.profile",
            extractionDeckDigest: "digest",
            deckUseScope: .processProvided,
            topCell: "top",
            devices: [],
            nets: [
                LayoutExtractionNet(id: duplicatedID, preferredName: "first", occurrenceIDs: []),
                LayoutExtractionNet(id: duplicatedID, preferredName: "second", occurrenceIDs: []),
            ],
            ports: [],
            occurrences: []
        )

        #expect(throws: LVSError.self) {
            try LayoutExtractionLVSGraphBuilder().build(
                from: extraction,
                maximumObjectCount: 100
            )
        }
    }
}
