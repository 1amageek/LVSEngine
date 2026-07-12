import Foundation
import Testing
import LVSCore
import LVSNative

@Suite("Native LVS backend")
struct NativeLVSBackendTests {
    @Test func matchingSPICENetlistsPassWithoutExternalTool() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(matchingInverter, name: "layout.spice", in: directory)
        let schematicURL = try writeNetlist(matchingInverter, name: "schematic.spice", in: directory)

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed)
        #expect(result.result.provenance?.executablePath == "in-process")
    }

    @Test func includeAndTopLevelParametersMatch() async throws {
        let directory = try makeTemporaryDirectory()
        let includeDirectory = directory.appending(path: "models")
        try FileManager.default.createDirectory(at: includeDirectory, withIntermediateDirectories: true)
        _ = try writeNetlist(
            """
            .subckt inv in out vdd vss w=drawn_w l=drawn_l
            M1 out in vdd vdd pmos W={w} L={l}
            M2 out in vss vss nmos W={w} L={l}
            .ends inv
            """,
            name: "inverter.spice",
            in: includeDirectory
        )
        let layoutURL = try writeNetlist(
            """
            .param drawn_w=1u drawn_l=0.15u
            .include "models/inverter.spice"
            .subckt top in out vdd vss
            XU1 in out vdd vss inv w={drawn_w} l={drawn_l}
            .ends top
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .param drawn_w=1000n drawn_l=150n
            .include "models/inverter.spice"
            .subckt top in out vdd vss
            XU1 in out vdd vss inv
            .ends top
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
    }

    @Test func parserFlattensSubcircuitsCaseInsensitively() throws {
        let directory = try makeTemporaryDirectory()
        let netlistURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos W=1u L=0.15u
            M2 out in vss vss nmos W=1u L=0.15u
            .ends inv
            .subckt TOP in out vdd vss
            XU1 in out vdd vss INV
            .ends TOP
            """,
            name: "mixed-case.spice",
            in: directory
        )

        let netlist = try NativeSPICENetlistParser().parse(
            url: netlistURL,
            expectedTopCell: "top"
        )

        #expect(netlist.components.count == 2)
        #expect(netlist.components.allSatisfy { $0.kind != "subcircuit" })
        #expect(Set(netlist.components.map(\.model)) == ["pmos", "nmos"])
    }

    @Test func parameterExpressionsMatchEquivalentNumericValues() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .param total_w=2u nf=4 unit_w={total_w/nf}
            .subckt inv in out vdd vss w={unit_w*nf} l={(0.1u + 0.2u)/2}
            M1 out in vdd vdd pmos W={w} L={l}
            M2 out in vss vss nmos W=0.5u*2 L={l}
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos W=2000n L=150n
            M2 out in vss vss nmos W=1u L=0.15u
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
    }

    @Test func resistorModelTokenParticipatesInComparison() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt resistor_cell a b
            R1 a b 2k rmodel_hipo
            .ends resistor_cell
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt resistor_cell a b
            R1 a b 2k rmodel_lopo
            .ends resistor_cell
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "resistor_cell",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!result.result.passed)
        #expect(result.result.diagnostics.contains {
            $0.ruleID == "LVS_MODEL_MISMATCH" || $0.ruleID == "LVS_PARAMETER_MISMATCH"
        })
    }

    @Test func spiceMilSuffixIsNotParsedAsMilli() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt resistor_cell a b
            R1 a b 100mil
            .ends resistor_cell
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt resistor_cell a b
            R1 a b 0.1
            .ends resistor_cell
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "resistor_cell",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!result.result.passed)
    }

    @Test func topLevelComponentLineFailsExplicitly() throws {
        let directory = try makeTemporaryDirectory()
        let netlistURL = try writeNetlist(
            """
            R1 a b 1k
            .subckt top a b
            .ends top
            """,
            name: "top-level-component.spice",
            in: directory
        )

        #expect(throws: LVSError.self) {
            _ = try NativeSPICENetlistParser().parse(url: netlistURL, expectedTopCell: "top")
        }
    }

    @Test func unsupportedDotCardFailsExplicitly() throws {
        let directory = try makeTemporaryDirectory()
        let netlistURL = try writeNetlist(
            """
            .subckt top a b
            .connect a b
            .ends top
            """,
            name: "unsupported-dot-card.spice",
            in: directory
        )

        #expect(throws: LVSError.self) {
            _ = try NativeSPICENetlistParser().parse(url: netlistURL, expectedTopCell: "top")
        }
    }

    @Test func unsupportedBareParameterTokenFailsExplicitly() throws {
        let directory = try makeTemporaryDirectory()
        let netlistURL = try writeNetlist(
            """
            .subckt top in out vss
            M1 out in vss vss nmos W=1u L=0.15u unexpected_token
            .ends top
            """,
            name: "unsupported-bare-parameter-token.spice",
            in: directory
        )

        #expect(throws: LVSError.self) {
            _ = try NativeSPICENetlistParser().parse(url: netlistURL, expectedTopCell: "top")
        }
    }

    @Test func topLevelEndDirectiveIsAccepted() throws {
        let directory = try makeTemporaryDirectory()
        let netlistURL = try writeNetlist(
            """
            .subckt top a b
            R1 a b 1k
            .ends top
            .end
            """,
            name: "top-level-end.spice",
            in: directory
        )

        let netlist = try NativeSPICENetlistParser().parse(url: netlistURL, expectedTopCell: "top")

        #expect(netlist.components.count == 1)
    }

    @Test func optionScaleMatchesDimensionlessExtractedGeometry() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .option scale=1u
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos W=2 L=0.15
            M2 out in vss vss nmos W=1 L=0.15
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos W=2u L=150n
            M2 out in vss vss nmos W=1000n L=0.15u
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
    }

    @Test func invalidOptionScaleFailsExplicitly() throws {
        let directory = try makeTemporaryDirectory()
        let netlistURL = try writeNetlist(
            """
            .option scale=0
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos W=2 L=0.15
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )

        do {
            _ = try NativeSPICENetlistParser().parse(url: netlistURL, expectedTopCell: "inv")
            Issue.record("Expected invalid .option scale to fail.")
        } catch let error as LVSError {
            guard case .invalidInput(let message) = error else {
                Issue.record("Expected invalid input error, got \(error).")
                return
            }
            #expect(message.contains("Invalid SPICE .option scale value"))
        }
    }

    @Test func continuationAndInlineCommentsDoNotAffectComparison() async throws {
        let directory = try makeTemporaryDirectory()
        let includeDirectory = directory.appending(path: "models")
        try FileManager.default.createDirectory(at: includeDirectory, withIntermediateDirectories: true)
        _ = try writeNetlist(
            """
            .subckt inv in out vdd vss w=drawn_w l=drawn_l
            M1 out in vdd vdd pmos W={w} $ ignored=layout_only
            + L={l} // ignored=layout_continuation
            M2 out in vss vss nmos W={w}
            + L={l} $ ignored=schematic_continuation
            .ends inv
            """,
            name: "inverter.spice",
            in: includeDirectory
        )
        let layoutURL = try writeNetlist(
            """
            .param drawn_w=1u drawn_l=0.15u $ ignored=layout_top
            .include "models/inverter.spice" $ include=ignored
            .subckt top in out vdd vss
            XU1 in out vdd vss inv w={drawn_w} l={drawn_l} $ layout_only=bad
            .ends top
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .param drawn_w=1000n drawn_l=150n // ignored=schematic_top
            .include "models/inverter.spice" // include=ignored
            .subckt top in out vdd vss
            XU1 in out vdd vss inv $ schematic_only=bad
            .ends top
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
    }

    @Test func recursiveIncludeFails() async throws {
        let directory = try makeTemporaryDirectory()
        _ = try writeNetlist(
            """
            .include "b.spice"
            .subckt top in out
            .ends top
            """,
            name: "a.spice",
            in: directory
        )
        let bURL = try writeNetlist(
            """
            .include "a.spice"
            """,
            name: "b.spice",
            in: directory
        )

        do {
            _ = try NativeSPICENetlistParser().parse(url: bURL, expectedTopCell: "top")
            Issue.record("Expected recursive include to fail.")
        } catch let error as LVSError {
            guard case .invalidInput(let message) = error else {
                Issue.record("Expected invalid input error, got \(error).")
                return
            }
            #expect(message.contains("Recursive .include detected"))
        }
    }

    @Test func librarySectionIncludeMatches() async throws {
        let directory = try makeTemporaryDirectory()
        let modelDirectory = directory.appending(path: "models")
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        _ = try writeNetlist(
            """
            .lib tt
            .subckt inv in out vdd vss w=1u l=0.15u
            M1 out in vdd vdd pmos W={w} L={l}
            M2 out in vss vss nmos W={w} L={l}
            .ends inv
            .endl tt
            .lib ss
            .subckt inv in out vdd vss w=2u l=0.20u
            M1 out in vdd vdd pmos_slow W={w} L={l}
            M2 out in vss vss nmos_slow W={w} L={l}
            .ends inv
            .endl ss
            """,
            name: "standard-cells.lib",
            in: modelDirectory
        )
        let layoutURL = try writeNetlist(
            """
            .lib "models/standard-cells.lib" tt
            .subckt top in out vdd vss
            XU1 in out vdd vss inv w=1000n l=150n
            .ends top
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .lib 'models/standard-cells.lib' tt
            .subckt top in out vdd vss
            XU1 in out vdd vss inv
            .ends top
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
    }

    @Test func missingLibrarySectionFailsExplicitly() throws {
        let directory = try makeTemporaryDirectory()
        let modelDirectory = directory.appending(path: "models")
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        _ = try writeNetlist(
            """
            .lib tt
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos
            M2 out in vss vss nmos
            .ends inv
            .endl tt
            """,
            name: "standard-cells.lib",
            in: modelDirectory
        )
        let netlistURL = try writeNetlist(
            """
            .lib "models/standard-cells.lib" ff
            .subckt top in out vdd vss
            XU1 in out vdd vss inv
            .ends top
            """,
            name: "layout.spice",
            in: directory
        )

        do {
            _ = try NativeSPICENetlistParser().parse(url: netlistURL, expectedTopCell: "top")
            Issue.record("Expected missing .lib section to fail.")
        } catch let error as LVSError {
            guard case .invalidInput(let message) = error else {
                Issue.record("Expected invalid input error, got \(error).")
                return
            }
            #expect(message.contains(".lib section ff was not found"))
        }
    }

    @Test func malformedLibraryDirectiveFailsBeforeTopCellLookup() throws {
        let directory = try makeTemporaryDirectory()
        let netlistURL = try writeNetlist(
            """
            .lib "models/standard-cells.lib"
            .subckt top in out vdd vss
            .ends top
            """,
            name: "layout.spice",
            in: directory
        )

        do {
            _ = try NativeSPICENetlistParser().parse(url: netlistURL, expectedTopCell: "top")
            Issue.record("Expected malformed .lib directive to fail.")
        } catch let error as LVSError {
            guard case .invalidInput(let message) = error else {
                Issue.record("Expected invalid input error, got \(error).")
                return
            }
            #expect(message.contains("Invalid .lib line"))
        }
    }

    @Test func mismatchedSubcircuitEndFailsExplicitly() throws {
        do {
            _ = try NativeSPICENetlistParser().parse(
                text: """
                .subckt inv in out vdd vss
                M1 out in vdd vdd pmos
                .ends other
                """,
                expectedTopCell: "inv"
            )
            Issue.record("Expected mismatched .ends directive to fail.")
        } catch let error as LVSError {
            guard case .invalidInput(let message) = error else {
                Issue.record("Expected invalid input error, got \(error).")
                return
            }
            #expect(message.contains("Mismatched .ends other for .subckt inv"))
        }
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

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!result.result.passed)
        let diagnostic = try #require(result.result.diagnostics.first { $0.ruleID == "LVS_MODEL_MISMATCH" })
        #expect(diagnostic.category == "modelMismatch")
        #expect(diagnostic.componentSignature?.hasPrefix("device:") == true)
        #expect(diagnostic.rawLine.contains("reason=device_semantics_mismatch"))
        #expect(diagnostic.suggestedFix != nil)
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

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!result.result.passed)
        let diagnostic = try #require(result.result.diagnostics.first { $0.ruleID == "LVS_PORT_MISMATCH" })
        #expect(diagnostic.category == "portMismatch")
        #expect(diagnostic.layoutPorts == ["in", "out", "vdd", "vss"])
        #expect(diagnostic.schematicPorts == ["in", "out", "vss", "vdd"])
        #expect(diagnostic.suggestedFix != nil)
    }

    @Test func symmetricDeviceTerminalsMatch() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 vdd in out vdd pmos W=1u L=0.15u
            R1 a b 100
            C1 x y 1f
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos L=0.15u W=1u
            R1 b a 100
            C1 y x 1f
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
    }

    @Test func diodeTerminalSwapRequiresTerminalEquivalencePolicy() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt clamp in vss
            D1 in vss diode area=1
            .ends clamp
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt clamp in vss
            D1 vss in diode area=1
            .ends clamp
            """,
            name: "schematic.spice",
            in: directory
        )

        let defaultResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "clamp",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!defaultResult.result.passed)
        #expect(defaultResult.result.diagnostics.contains {
            $0.ruleID == "LVS_GRAPH_MISMATCH"
                && $0.rawLine.contains("layoutObjectIDs=device:")
        })

        let policyURL = try writeTerminalEquivalencePolicy(
            """
            {
              "schemaVersion" : 1,
              "rules" : [
                {
                  "equivalentPinGroups" : [[0, 1]],
                  "kind" : "diode",
                  "pinCount" : 2
                }
              ]
            }
            """,
            name: "terminal-equivalence.json",
            in: directory
        )

        let policyResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "clamp",
            terminalEquivalenceURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(policyResult.result.passed)
    }

    @Test func parameterMismatchFails() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos W=1u L=0.15u
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos W=2u L=0.15u
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!result.result.passed)
        let diagnostic = try #require(result.result.diagnostics.first { $0.ruleID == "LVS_PARAMETER_MISMATCH" })
        #expect(diagnostic.category == "parameterMismatch")
        #expect(diagnostic.componentSignature?.hasPrefix("device:") == true)
        #expect(diagnostic.rawLine.contains("reason=device_parameter_mismatch"))
        #expect(diagnostic.rawLine.contains("schematicObjectIDs=device:"))
    }

    @Test func numericEquivalentParametersMatch() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos W=1u L=0.15u
            R1 a b 1k
            C1 x y 1p
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos W=1000n L=150n
            R1 b a 1000
            C1 y x 1e-12
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
    }

    @Test func numericParameterMismatchStillReportsOriginalValues() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos W=1u L=0.15u
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos W=2u L=150n
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!result.result.passed)
        let diagnostic = try #require(result.result.diagnostics.first { $0.ruleID == "LVS_PARAMETER_MISMATCH" })
        #expect(diagnostic.rawLine.contains("reason=device_parameter_mismatch"))
        #expect(diagnostic.componentSignature?.hasPrefix("device:") == true)
    }

    @Test func matchingSubcircuitInstancesPass() async throws {
        let directory = try makeTemporaryDirectory()
        let hierarchicalNetlist = """
        .subckt top a y vdd vss
        X1 a mid vdd vss inv
        X2 mid y vdd vss inv
        .ends top
        .subckt inv in out vdd vss
        M1 out in vdd vdd pmos W=1u L=0.15u
        M2 out in vss vss nmos W=1u L=0.15u
        .ends inv
        """
        let layoutURL = try writeNetlist(hierarchicalNetlist, name: "layout.spice", in: directory)
        let schematicURL = try writeNetlist(hierarchicalNetlist, name: "schematic.spice", in: directory)

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
    }

    @Test func subcircuitParameterOverridesPassWhenResolvedToPrimitiveDevices() async throws {
        let directory = try makeTemporaryDirectory()
        let netlist = """
        .subckt top a y vdd vss
        X1 a y vdd vss inv w=2u
        .ends top
        .subckt inv in out vdd vss w=1u l=0.15u
        M1 out in vdd vdd pmos W={w} L={l}
        M2 out in vss vss nmos W={w} L={l}
        .ends inv
        """
        let layoutURL = try writeNetlist(netlist, name: "layout.spice", in: directory)
        let schematicURL = try writeNetlist(netlist, name: "schematic.spice", in: directory)

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
    }

    @Test func subcircuitParameterOverrideMismatchFailsAtPrimitiveParameter() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt top a y vdd vss
            X1 a y vdd vss inv w=1u
            .ends top
            .subckt inv in out vdd vss w=1u l=0.15u
            M1 out in vdd vdd pmos W={w} L={l}
            M2 out in vss vss nmos W={w} L={l}
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt top a y vdd vss
            X1 a y vdd vss inv w=2u
            .ends top
            .subckt inv in out vdd vss w=1u l=0.15u
            M1 out in vdd vdd pmos W={w} L={l}
            M2 out in vss vss nmos W={w} L={l}
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!result.result.passed)
        let diagnostic = try #require(result.result.diagnostics.first { $0.ruleID == "LVS_PARAMETER_MISMATCH" })
        #expect(diagnostic.category == "parameterMismatch")
        #expect(diagnostic.rawLine.contains("reason=device_parameter_mismatch"))
    }

    @Test func hierarchicalSubcircuitDefinitionModelMismatchFails() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt top a y vdd vss
            X1 a y vdd vss inv
            .ends top
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos W=1u L=0.15u
            M2 out in vss vss nmos W=1u L=0.15u
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt top a y vdd vss
            X1 a y vdd vss inv
            .ends top
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos W=1u L=0.15u
            M2 out in vss vss nmos_mismatch W=1u L=0.15u
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!result.result.passed)
        let diagnostic = try #require(result.result.diagnostics.first { $0.ruleID == "LVS_MODEL_MISMATCH" })
        #expect(diagnostic.category == "modelMismatch")
        #expect(diagnostic.componentSignature?.hasPrefix("device:") == true)
        #expect(diagnostic.rawLine.contains("reason=device_semantics_mismatch"))
    }

    @Test func subcircuitInstancePinMismatchFails() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt top a y vdd vss
            X1 a mid vdd vss inv
            X2 mid y vdd vss inv
            .ends top
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos W=1u L=0.15u
            M2 out in vss vss nmos W=1u L=0.15u
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt top a y vdd vss
            X1 a mid vdd vss inv
            X2 y mid vdd vss inv
            .ends top
            .subckt inv in out vdd vss
            M1 out in vdd vdd pmos W=1u L=0.15u
            M2 out in vss vss nmos W=1u L=0.15u
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!result.result.passed)
        #expect(result.result.diagnostics.contains {
            $0.ruleID == "LVS_GRAPH_MISMATCH"
                && $0.rawLine.contains("layoutObjectIDs=device:")
        })
    }

    @Test func globalSupplyNetsMatchWhenTopPortsDiffer() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt top in out vdd vss
            X1 in out vdd vss inv_with_ports
            .ends top
            .subckt inv_with_ports in out vdd vss
            M1 out in vdd vdd pmos W=1u L=0.15u
            M2 out in vss vss nmos W=1u L=0.15u
            .ends inv_with_ports
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .global VDD VSS
            .subckt top in out
            X1 in out inv_global
            .ends top
            .subckt inv_global in out
            M1 out in VDD VDD pmos W=1u L=0.15u
            M2 out in VSS VSS nmos W=1u L=0.15u
            .ends inv_global
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
        #expect(!result.result.diagnostics.contains { $0.ruleID == "LVS_PORT_MISMATCH" })
    }

    @Test func diodeAndBJTDevicesMatch() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt bias in out vdd vss sub
            D1 out vss diode_model AREA=1p
            Q1 out in vss sub npn_model AREA=2
            .ends bias
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt bias in out vdd vss sub
            D1 out vss diode_model AREA=1e-12
            Q1 out in vss sub npn_model AREA=2
            .ends bias
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "bias",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
    }

    @Test func diodeModelMismatchFails() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt clamp in vss
            D1 in vss diode_model AREA=1p
            .ends clamp
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt clamp in vss
            D1 in vss diode_mismatch AREA=1p
            .ends clamp
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "clamp",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!result.result.passed)
        let diagnostic = try #require(result.result.diagnostics.first { $0.ruleID == "LVS_MODEL_MISMATCH" })
        #expect(diagnostic.category == "modelMismatch")
        #expect(diagnostic.componentSignature?.hasPrefix("device:") == true)
        #expect(diagnostic.rawLine.contains("reason=device_semantics_mismatch"))
    }

    @Test func inductorAndSourceDevicesMatchWithNumericEquivalentValues() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt mixed in out ctrl ctrlb vdd vss sense
            L1 out in 1n TOL=5
            VBIAS vdd vss 1.2
            IREF out vss DC 10u
            E1 out vss ctrl ctrlb 10
            G1 in vss ctrl ctrlb 1m
            F1 out vss VBIAS 2
            H1 sense vss VBIAS 500
            .ends mixed
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt mixed in out ctrl ctrlb vdd vss sense
            L1 in out 1e-9 TOL=5.0
            VBIAS vdd vss DC 1200m
            IREF out vss 1e-5
            E1 out vss ctrl ctrlb 1e1
            G1 in vss ctrl ctrlb 1e-3
            F1 out vss vbias 2.0
            H1 sense vss vbias 0.5k
            .ends mixed
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "mixed",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
    }

    @Test func sourcePolarityMismatchFails() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt bias vdd vss
            VBIAS vdd vss 1.2
            .ends bias
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt bias vdd vss
            VBIAS vss vdd DC 1.2
            .ends bias
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "bias",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!result.result.passed)
        #expect(result.result.diagnostics.contains {
            $0.ruleID == "LVS_GRAPH_MISMATCH"
                && $0.category == "graphMismatch"
                && $0.rawLine.contains("layoutObjectIDs=device:")
        })
    }

    @Test func controlledSourceGainMismatchFails() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt amp in out ctrl ctrlb vss
            E1 out vss ctrl ctrlb 10
            .ends amp
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt amp in out ctrl ctrlb vss
            E1 out vss ctrl ctrlb 11
            .ends amp
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "amp",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!result.result.passed)
        let diagnostic = try #require(result.result.diagnostics.first { $0.ruleID == "LVS_PARAMETER_MISMATCH" })
        #expect(diagnostic.category == "parameterMismatch")
        #expect(diagnostic.componentSignature?.hasPrefix("device:") == true)
        #expect(diagnostic.rawLine.contains("reason=device_parameter_mismatch"))
    }

    @Test func parallelDevicesMatchNumericMultiplicity() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vss vss nmos W=1u L=0.15u M=2
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vss vss nmos W=1u L=0.15u
            M2 out in vss vss nmos W=1u L=0.15u
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
    }

    @Test func devicePolicyPropertyParallelAddsWidthAcrossParallelMOSDevices() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=2 L=0.15
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=1 L=0.15
            M2 out in vss vss sky130_fd_pr__nfet_01v8 W=1 L=0.15
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let defaultResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))
        #expect(!defaultResult.result.passed)

        let importedPolicy = NetgenLVSDeviceDeckImporter.importDeviceDeck(
            text: """
            set devices {}
            lappend devices sky130_fd_pr__nfet_01v8
            foreach dev $devices {
                property "-circuit1 $dev" parallel enable
                property "-circuit1 $dev" parallel {l critical}
                property "-circuit1 $dev" parallel {w add}
            }
            """,
            sourcePath: "sky130A_setup.tcl",
            generatedAt: "2026-06-23T00:00:00Z"
        )
        let policyURL = try writeDevicePolicySeed(
            importedPolicy.seed,
            name: "device-policy.json",
            in: directory
        )

        let policyResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(policyResult.result.passed, "\(policyResult.result.diagnostics.map(\.message))")
        let report = try #require(policyResult.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 3)
        #expect(report.ignoredRuleCount == 0)
        #expect(report.appliedRuleCountsByKind["property-parallel"] == 3)
        #expect(report.ignoredRuleCountsByReason.isEmpty)
        #expect(report.appliedRules.contains {
            $0.kind == "property-parallel" && $0.propertyMode == "enable"
        })
        #expect(report.appliedRules.contains {
            $0.kind == "property-parallel" && $0.parameterRoles == ["l": "critical"]
        })
        #expect(report.appliedRules.contains {
            $0.kind == "property-parallel" && $0.parameterRoles == ["w": "add"]
        })

        let criticalMismatchLayoutURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=2 L=0.16
            .ends inv
            """,
            name: "layout-critical-mismatch.spice",
            in: directory
        )
        let criticalMismatchResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: criticalMismatchLayoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!criticalMismatchResult.result.passed)
    }

    @Test func devicePolicyEquatePinsMatchesSameFamilyModelPair() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt clamp in vss
            D1 in vss sky130_fd_pr__diode_pw2nd_05v5 area=1
            .ends clamp
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt clamp in vss
            D1 in vss sky130_fd_pr__diode_pw2nd_05v5_alias area=1
            .ends clamp
            """,
            name: "schematic.spice",
            in: directory
        )

        let defaultResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "clamp",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))
        #expect(!defaultResult.result.passed)
        #expect(defaultResult.result.diagnostics.contains { $0.ruleID == "LVS_MODEL_MISMATCH" })

        let importedPolicy = NetgenLVSDeviceDeckImporter.importDeviceDeck(
            text: """
            lappend devices sky130_fd_pr__diode_pw2nd_05v5
            lappend devices sky130_fd_pr__diode_pw2nd_05v5_alias
            equate pins "-circuit1 sky130_fd_pr__diode_pw2nd_05v5" "-circuit2 sky130_fd_pr__diode_pw2nd_05v5_alias"
            """,
            sourcePath: "sky130A_setup.tcl",
            generatedAt: "2026-06-23T00:00:00Z"
        )
        let policyURL = try writeDevicePolicySeed(
            importedPolicy.seed,
            name: "device-policy-equate-pins.json",
            in: directory
        )

        let policyResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "clamp",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(policyResult.result.passed, "\(policyResult.result.diagnostics.map(\.message))")
        let report = try #require(policyResult.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 1)
        #expect(report.ignoredRuleCount == 0)
        #expect(report.appliedRules.contains {
            $0.kind == "equate-pins"
                && $0.model == "sky130_fd_pr__diode_pw2nd_05v5"
                && $0.pairedModel == "sky130_fd_pr__diode_pw2nd_05v5_alias"
                && $0.propertyMode == "pin-order"
        })
    }

    @Test func devicePolicyBlackboxPreservesSubcircuitBoundary() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt top in out
            XU1 in out hard_macro gain=1
            .ends top

            .subckt hard_macro in out
            R1 in out rpoly r=1k
            .ends hard_macro
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt top in out
            XU1 in out hard_macro gain=9
            .ends top

            .subckt hard_macro in out
            R1 in out rpoly r=2k
            .ends hard_macro
            """,
            name: "schematic.spice",
            in: directory
        )

        let defaultResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))
        #expect(!defaultResult.result.passed)
        #expect(defaultResult.result.diagnostics.contains { $0.ruleID == "LVS_PARAMETER_MISMATCH" })

        let seed = NetgenLVSDevicePolicySeed(
            generatedAt: "2026-06-24T00:00:00Z",
            sourcePath: "sky130A_setup.tcl",
            devices: [],
            policyRules: [
                NetgenLVSPolicyRule(
                    kind: "blackbox",
                    arguments: ["model", "blackbox", "hard_macro"],
                    sourceLineNumber: 12,
                    sourceLine: "model blackbox hard_macro"
                )
            ]
        )
        let policyURL = try writeDevicePolicySeed(
            seed,
            name: "device-policy-blackbox.json",
            in: directory
        )

        let policyResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(policyResult.result.passed, "\(policyResult.result.diagnostics.map(\.message))")
        let report = try #require(policyResult.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 1)
        #expect(report.ignoredRuleCount == 0)
        #expect(report.appliedRules.contains {
            $0.kind == "blackbox"
                && $0.model == "hard_macro"
                && $0.propertyMode == "blackbox"
        })

        let pinMismatchSchematicURL = try writeNetlist(
            """
            .subckt top in out
            XU1 out in hard_macro gain=9
            .ends top

            .subckt hard_macro in out
            R1 in out rpoly r=2k
            .ends hard_macro
            """,
            name: "schematic-blackbox-pin-mismatch.spice",
            in: directory
        )
        let pinMismatchResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: pinMismatchSchematicURL,
            topCell: "top",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))
        #expect(!pinMismatchResult.result.passed)
    }

    @Test func devicePolicyPropertyBlackboxIgnoresModelScopedParameters() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=1 L=0.15
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=9 L=9
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let defaultResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))
        #expect(!defaultResult.result.passed)

        let importedPolicy = NetgenLVSDeviceDeckImporter.importDeviceDeck(
            text: """
            lappend devices sky130_fd_pr__nfet_01v8
            property "-circuit1 sky130_fd_pr__nfet_01v8" blackbox
            """,
            sourcePath: "sky130A_setup.tcl",
            generatedAt: "2026-06-24T00:00:00Z"
        )
        let policyURL = try writeDevicePolicySeed(
            importedPolicy.seed,
            name: "device-policy-property-blackbox.json",
            in: directory
        )

        let policyResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(policyResult.result.passed, "\(policyResult.result.diagnostics.map(\.message))")
        let report = try #require(policyResult.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 1)
        #expect(report.ignoredRuleCount == 0)
        let appliedRule = try #require(report.appliedRules.first)
        #expect(appliedRule.kind == "property-blackbox")
        #expect(appliedRule.model == "sky130_fd_pr__nfet_01v8")
        #expect(appliedRule.propertyMode == "blackbox")
    }

    @Test func devicePolicyRuntimeCellBlackboxResolvesComparedSubcircuitModels() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt top in out
            XU1 in out hard_macro gain=1
            .ends top

            .subckt hard_macro in out
            R1 in out rpoly r=1k
            .ends hard_macro
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt top in out
            XU1 in out hard_macro gain=9
            .ends top

            .subckt hard_macro in out
            R1 in out rpoly r=2k
            .ends hard_macro
            """,
            name: "schematic.spice",
            in: directory
        )

        let defaultResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))
        #expect(!defaultResult.result.passed)

        let seed = NetgenLVSDevicePolicySeed(
            generatedAt: "2026-06-24T00:00:00Z",
            sourcePath: "sky130A_setup.tcl",
            devices: [],
            policyRules: [
                NetgenLVSPolicyRule(
                    kind: "property",
                    arguments: ["-circuit1 $cell", "blackbox"],
                    sourceLineNumber: 12,
                    sourceLine: "property \"-circuit1 $cell\" blackbox"
                )
            ]
        )
        let policyURL = try writeDevicePolicySeed(
            seed,
            name: "device-policy-runtime-cell-blackbox.json",
            in: directory
        )

        let policyResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(policyResult.result.passed, "\(policyResult.result.diagnostics.map(\.message))")
        let report = try #require(policyResult.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 1)
        #expect(report.ignoredRuleCount == 0)
        let appliedRule = try #require(report.appliedRules.first)
        #expect(appliedRule.kind == "property-blackbox")
        #expect(appliedRule.model == "hard_macro")
        #expect(appliedRule.family == "cell")
        #expect(appliedRule.propertyMode == "blackbox")
    }

    @Test func devicePolicyRuntimeCellBlackboxDoesNotResolveUndefinedExternalModels() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt top in out
            XU1 in out external_macro gain=1
            .ends top
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt top in out
            XU1 in out external_macro gain=9
            .ends top
            """,
            name: "schematic.spice",
            in: directory
        )
        let seed = NetgenLVSDevicePolicySeed(
            generatedAt: "2026-06-24T00:00:00Z",
            sourcePath: "sky130A_setup.tcl",
            devices: [],
            policyRules: [
                NetgenLVSPolicyRule(
                    kind: "property",
                    arguments: ["-circuit1 $cell", "blackbox"],
                    sourceLineNumber: 12,
                    sourceLine: "property \"-circuit1 $cell\" blackbox"
                )
            ]
        )
        let policyURL = try writeDevicePolicySeed(
            seed,
            name: "device-policy-runtime-cell-external-model.json",
            in: directory
        )

        let policyResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!policyResult.result.passed)
        let report = try #require(policyResult.devicePolicyReport)
        #expect(report.status == .partial)
        #expect(report.appliedRuleCount == 0)
        #expect(report.ignoredRuleCount == 1)
        #expect(report.appliedRuleCountsByKind.isEmpty)
        #expect(report.ignoredRuleCountsByReason["unresolved-device-selector"] == 1)
        let ignoredRule = try #require(report.ignoredRules.first)
        #expect(ignoredRule.reasonCode == "unresolved-device-selector")
    }

    @Test func devicePolicyRuntimePredicateScopesPolicyToMatchingCells() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt top in out
            X1 in mid sky130_fd_sc_hd__fill_1 gain=1
            X2 mid out logic_cell gain=1
            .ends top
            .subckt sky130_fd_sc_hd__fill_1 in out
            R1 in out rpoly r=1k
            .ends sky130_fd_sc_hd__fill_1
            .subckt logic_cell in out
            R1 in out rpoly r=1k
            .ends logic_cell
            """,
            name: "layout-runtime-selector.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt top in out
            X1 in mid sky130_fd_sc_hd__fill_1 gain=9
            X2 mid out logic_cell gain=1
            .ends top
            .subckt sky130_fd_sc_hd__fill_1 in out
            R1 in out rpoly r=2k
            .ends sky130_fd_sc_hd__fill_1
            .subckt logic_cell in out
            R1 in out rpoly r=1k
            .ends logic_cell
            """,
            name: "schematic-runtime-selector.spice",
            in: directory
        )
        let seed = NetgenLVSDevicePolicySeed(
            generatedAt: "2026-07-12T00:00:00Z",
            sourcePath: "sky130A_setup.tcl",
            devices: [],
            policyRules: [
                NetgenLVSPolicyRule(
                    kind: "property",
                    arguments: ["-circuit1 $cell", "blackbox"],
                    runtimePredicate: NetgenLVSRuntimePredicate(
                        variableName: "cell",
                        pattern: "sky130_fd_sc_[^_]+__fill_[[:digit:]]+"
                    ),
                    sourceLineNumber: 12,
                    sourceLine: "property \"-circuit1 $cell\" blackbox"
                )
            ]
        )
        let policyURL = try writeDevicePolicySeed(
            seed,
            name: "runtime-selector-policy.json",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
        let report = try #require(result.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRules.map(\.model) == ["sky130_fd_sc_hd__fill_1"])
        #expect(!report.appliedRules.contains { $0.model == "logic_cell" })
    }

    @Test func devicePolicyIgnoreClassRemovesOnlyTheSelectedCircuitModel() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt top in out
            XIGNORE in out ignored_cell
            R1 in out rpoly r=1k
            .ends top
            .subckt ignored_cell in out
            R1 in out rpoly r=10k
            .ends ignored_cell
            """,
            name: "layout-ignore-class.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt top in out
            R1 in out rpoly r=1k
            .ends top
            """,
            name: "schematic-ignore-class.spice",
            in: directory
        )
        let seed = NetgenLVSDevicePolicySeed(
            generatedAt: "2026-07-12T00:00:00Z",
            sourcePath: "sky130A_setup.tcl",
            devices: [],
            policyRules: [
                NetgenLVSPolicyRule(
                    kind: "ignore-class",
                    arguments: ["class", "-circuit1 ignored_cell"],
                    sourceLineNumber: 24,
                    sourceLine: "ignore class \"-circuit1 ignored_cell\""
                )
            ]
        )
        let policyURL = try writeDevicePolicySeed(
            seed,
            name: "ignore-class-policy.json",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
        let report = try #require(result.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRules.contains {
            $0.kind == "ignore-class"
                && $0.model == "ignored_cell"
                && $0.propertyMode == "circuit1"
        })
    }

    @Test func devicePolicyRuntimeEquateClassesResolvesCapturedCellName() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt top in out
            X1 in out library__macro
            .ends top
            .subckt library__macro in out
            R1 in out rpoly r=1k
            .ends library__macro
            """,
            name: "layout-equate-runtime.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt top in out
            X1 in out macro
            .ends top
            .subckt macro in out
            R1 in out rpoly r=1k
            .ends macro
            """,
            name: "schematic-equate-runtime.spice",
            in: directory
        )
        let predicate = NetgenLVSRuntimePredicate(
            variableName: "cell",
            pattern: "(.+)__(.+)",
            captureVariableNames: ["library", "cellname"]
        )
        let seed = NetgenLVSDevicePolicySeed(
            generatedAt: "2026-07-12T00:00:00Z",
            sourcePath: "sky130A_setup.tcl",
            devices: [],
            policyRules: [
                NetgenLVSPolicyRule(
                    kind: "equate",
                    arguments: ["classes", "-circuit1 $cell", "-circuit2 $cellname"],
                    runtimePredicate: predicate,
                    sourceLineNumber: 31,
                    sourceLine: "equate classes \"-circuit1 $cell\" \"-circuit2 $cellname\""
                ),
                NetgenLVSPolicyRule(
                    kind: "equate-pins",
                    arguments: ["pins", "-circuit1 $cell", "-circuit2 $cellname"],
                    runtimePredicate: predicate,
                    sourceLineNumber: 32,
                    sourceLine: "equate pins \"-circuit1 $cell\" \"-circuit2 $cellname\""
                ),
            ]
        )
        let policyURL = try writeDevicePolicySeed(
            seed,
            name: "runtime-equate-policy.json",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
        let report = try #require(result.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCountsByKind["equate-classes"] == 1)
        #expect(report.appliedRuleCountsByKind["equate-pins"] == 1)
        #expect(report.ignoredRuleCount == 0)
    }

    @Test func devicePolicyConsumesNetgenDefaultsAndNamedResistorPins() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt top a b
            R1 a b sky130_fd_pr__res_generic_m1 r=1k
            .ends top
            """,
            name: "layout-default-policy.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt top a b
            R1 b a sky130_fd_pr__res_generic_m1 r=1k
            .ends top
            """,
            name: "schematic-default-policy.spice",
            in: directory
        )
        let seed = NetgenLVSDevicePolicySeed(
            generatedAt: "2026-07-12T00:00:00Z",
            sourcePath: "sky130A_setup.tcl",
            devices: [
                NetgenLVSDeviceDescriptor(
                    deviceName: "sky130_fd_pr__res_generic_m1",
                    family: "resistor",
                    sourceLineNumber: 1,
                    sourceLine: "lappend devices sky130_fd_pr__res_generic_m1"
                )
            ],
            policyRules: [
                NetgenLVSPolicyRule(
                    kind: "permute",
                    arguments: ["default"],
                    sourceLineNumber: 2,
                    sourceLine: "permute default"
                ),
                NetgenLVSPolicyRule(
                    kind: "property",
                    arguments: ["default"],
                    sourceLineNumber: 3,
                    sourceLine: "property default"
                ),
                NetgenLVSPolicyRule(
                    kind: "property",
                    arguments: ["parallel", "none"],
                    sourceLineNumber: 4,
                    sourceLine: "property parallel none"
                ),
                NetgenLVSPolicyRule(
                    kind: "permute",
                    arguments: ["-circuit1 sky130_fd_pr__res_generic_m1", "end_a", "end_b"],
                    sourceLineNumber: 5,
                    sourceLine: "permute \"-circuit1 sky130_fd_pr__res_generic_m1\" end_a end_b"
                ),
            ]
        )
        let policyURL = try writeDevicePolicySeed(
            seed,
            name: "default-policy.json",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "top",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
        let report = try #require(result.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCountsByKind["permute-default"] == 1)
        #expect(report.appliedRuleCountsByKind["property-default"] == 2)
        #expect(report.appliedRuleCountsByKind["permute"] == 1)
        #expect(report.ignoredRuleCount == 0)
    }

    @Test func devicePolicyPropertySeriesAddsLengthAcrossSeriesMOSDevices() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=1 L=0.30
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in mid vss sky130_fd_pr__nfet_01v8 W=1 L=0.15
            M2 mid in vss vss sky130_fd_pr__nfet_01v8 W=1 L=0.15
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let defaultResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))
        #expect(!defaultResult.result.passed)

        let importedPolicy = NetgenLVSDeviceDeckImporter.importDeviceDeck(
            text: """
            set devices {}
            lappend devices sky130_fd_pr__nfet_01v8
            foreach dev $devices {
                property "-circuit1 $dev" series enable
                property "-circuit1 $dev" series {w critical}
                property "-circuit1 $dev" series {l add}
            }
            """,
            sourcePath: "sky130A_setup.tcl",
            generatedAt: "2026-06-23T00:00:00Z"
        )
        let policyURL = try writeDevicePolicySeed(
            importedPolicy.seed,
            name: "device-policy-series.json",
            in: directory
        )

        let policyResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(policyResult.result.passed, "\(policyResult.result.diagnostics.map(\.message))")
        let report = try #require(policyResult.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 3)
        #expect(report.ignoredRuleCount == 0)
        #expect(report.appliedRules.contains {
            $0.kind == "property-series" && $0.propertyMode == "enable"
        })
        #expect(report.appliedRules.contains {
            $0.kind == "property-series" && $0.parameterRoles == ["w": "critical"]
        })
        #expect(report.appliedRules.contains {
            $0.kind == "property-series" && $0.parameterRoles == ["l": "add"]
        })

        let criticalMismatchSchematicURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in mid vss sky130_fd_pr__nfet_01v8 W=1 L=0.15
            M2 mid in vss vss sky130_fd_pr__nfet_01v8 W=2 L=0.15
            .ends inv
            """,
            name: "schematic-series-critical-mismatch.spice",
            in: directory
        )
        let criticalMismatchResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: criticalMismatchSchematicURL,
            topCell: "inv",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!criticalMismatchResult.result.passed)
    }

    @Test func devicePolicyPropertySeriesAddsResistanceAcrossPassiveDevices() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt ladder a b
            R1 a b rpoly r=2000
            .ends ladder
            """,
            name: "layout-passive-series.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt ladder a b
            R1 a mid rpoly r=1000
            R2 mid b rpoly r=1000
            .ends ladder
            """,
            name: "schematic-passive-series.spice",
            in: directory
        )

        let defaultResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "ladder",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))
        #expect(!defaultResult.result.passed)

        let policyURL = try writeDevicePolicySeed(
            NetgenLVSDevicePolicySeed(
                generatedAt: "2026-06-29T00:00:00Z",
                sourcePath: "generic-device-policy.tcl",
                devices: [
                    NetgenLVSDeviceDescriptor(
                        deviceName: "rpoly",
                        family: "resistor",
                        sourceLineNumber: 1,
                        sourceLine: "lappend devices rpoly"
                    )
                ],
                policyRules: [
                    NetgenLVSPolicyRule(
                        kind: "property",
                        arguments: ["-circuit1 rpoly", "series", "enable"],
                        sourceLineNumber: 2,
                        sourceLine: "property \"-circuit1 rpoly\" series enable"
                    ),
                    NetgenLVSPolicyRule(
                        kind: "property",
                        arguments: ["-circuit1 rpoly", "series", "{r add}"],
                        sourceLineNumber: 3,
                        sourceLine: "property \"-circuit1 rpoly\" series {r add}"
                    ),
                ]
            ),
            name: "device-policy-passive-series.json",
            in: directory
        )

        let policyResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "ladder",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(policyResult.result.passed, "\(policyResult.result.diagnostics.map(\.message))")
        let report = try #require(policyResult.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 2)
        #expect(report.ignoredRuleCount == 0)
        #expect(report.appliedRules.contains {
            $0.kind == "property-series" && $0.propertyMode == "enable" && $0.model == "rpoly"
        })
        #expect(report.appliedRules.contains {
            $0.kind == "property-series" && $0.parameterRoles == ["r": "add"] && $0.model == "rpoly"
        })
    }

    @Test func multiplicityMismatchFails() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vss vss nmos W=1u L=0.15u M=3
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vss vss nmos W=1u L=0.15u
            M2 out in vss vss nmos W=1u L=0.15u
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!result.result.passed)
        let diagnostic = try #require(result.result.diagnostics.first {
            $0.ruleID == "LVS_COMPONENT_COUNT_MISMATCH"
        })
        #expect(diagnostic.category == "componentCount")
        #expect(diagnostic.rawLine.contains("reason=device_count_mismatch"))
    }

    @Test func modelEquivalencePolicyMatchesAliasModels() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=1u L=0.15u
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vss vss nmos W=1u L=0.15u
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )
        let policyURL = try writeModelEquivalencePolicy(
            """
            {
              "schemaVersion" : 1,
              "groups" : [
                {
                  "canonicalModel" : "nmos",
                  "aliases" : ["sky130_fd_pr__nfet_01v8"]
                }
              ]
            }
            """,
            name: "model-equivalence.json",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            modelEquivalenceURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed, "\(result.result.diagnostics.map(\.message))")
    }

    @Test func modelEquivalencePolicyMissingAliasStillFails() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=1u L=0.15u
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vdd vss
            M1 out in vss vss nmos W=1u L=0.15u
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let result = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!result.result.passed)
        let diagnostic = try #require(result.result.diagnostics.first { $0.ruleID == "LVS_MODEL_MISMATCH" })
        #expect(diagnostic.category == "modelMismatch")
        #expect(diagnostic.rawLine.contains("reason=device_semantics_mismatch"))
    }

    @Test func devicePolicySeedPermuteRuleMatchesSwappedDiodeTerminals() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt diode_cell out vss
            D1 out vss sky130_fd_pr__diode_pw2nd_05v5 AREA=1
            .ends diode_cell
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt diode_cell out vss
            D1 vss out sky130_fd_pr__diode_pw2nd_05v5 AREA=1
            .ends diode_cell
            """,
            name: "schematic.spice",
            in: directory
        )

        let defaultResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "diode_cell",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))
        #expect(!defaultResult.result.passed)

        let importedPolicy = NetgenLVSDeviceDeckImporter.importDeviceDeck(
            text: """
            set devices {}
            lappend devices sky130_fd_pr__diode_pw2nd_05v5
            foreach dev $devices {
                permute "-circuit1 $dev" 1 2
                property "-circuit1 $dev" parallel enable
            }
            """,
            sourcePath: "sky130A_setup.tcl",
            generatedAt: "2026-06-23T00:00:00Z"
        )
        #expect(importedPolicy.seed.policyRules.allSatisfy {
            !$0.arguments.joined(separator: " ").contains("$dev")
        })
        let policyURL = try writeDevicePolicySeed(
            importedPolicy.seed,
            name: "device-policy.json",
            in: directory
        )

        let policyResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "diode_cell",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(policyResult.result.passed, "\(policyResult.result.diagnostics.map(\.message))")
        let report = try #require(policyResult.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.knownDeviceCount == 1)
        #expect(report.observedKnownDeviceCount == 1)
        #expect(report.appliedRuleCount == 2)
        #expect(report.ignoredRuleCount == 0)
        #expect(report.appliedRules.contains {
            $0.kind == "permute" && $0.equivalentPinGroups == [[0, 1]]
        })
        #expect(report.appliedRules.contains {
            $0.kind == "property-parallel" && $0.propertyMode == "enable"
        })
        #expect(policyResult.result.diagnostics.contains { $0.ruleID == "LVS_DEVICE_POLICY_APPLIED" })
        #expect(!policyResult.result.diagnostics.contains { $0.ruleID == "LVS_DEVICE_POLICY_IGNORED" })
    }

    @Test func devicePolicyPropertyDeleteIgnoresFoundryGeometryParameters() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=1u L=0.15u AS=1 AD=2
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=1u L=0.15u AS=9 AD=8
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let defaultResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))
        #expect(!defaultResult.result.passed)
        #expect(defaultResult.result.diagnostics.contains {
            $0.ruleID == "LVS_PARAMETER_MISMATCH"
                && $0.rawLine.contains("reason=device_parameter_mismatch")
        })

        let importedPolicy = NetgenLVSDeviceDeckImporter.importDeviceDeck(
            text: """
            set devices {}
            lappend devices sky130_fd_pr__nfet_01v8
            lappend devices sky130_fd_pr__pfet_01v8
            foreach dev $devices {
                property "-circuit1 $dev" delete as ad
            }
            """,
            sourcePath: "sky130A_setup.tcl",
            generatedAt: "2026-06-23T00:00:00Z"
        )
        let policyURL = try writeDevicePolicySeed(
            importedPolicy.seed,
            name: "device-policy.json",
            in: directory
        )

        let policyResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(policyResult.result.passed, "\(policyResult.result.diagnostics.map(\.message))")
        let report = try #require(policyResult.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.knownDeviceCount == 2)
        #expect(report.observedKnownDeviceCount == 1)
        #expect(report.policyRuleCount == 2)
        #expect(report.appliedRuleCount == 1)
        #expect(report.ignoredRuleCount == 0)
        #expect(report.unobservedRuleCount == 1)
        #expect(report.policyRuleCountsByKind["property"] == 2)
        #expect(report.unobservedRuleCountsByKind["property"] == 1)
        let unobservedRule = try #require(report.unobservedRules.first)
        #expect(unobservedRule.targetModels == ["sky130_fd_pr__pfet_01v8"])
        #expect(policyResult.result.diagnostics.contains {
            $0.ruleID == "LVS_DEVICE_POLICY_UNOBSERVED_SELECTOR_TARGET_NOT_OBSERVED"
                && $0.rawLine.contains("unobservedReason=selector-target-not-observed")
        })
        let appliedRule = try #require(report.appliedRules.first)
        #expect(appliedRule.kind == "property-delete")
        #expect(appliedRule.parameterNames == ["ad", "as"])
    }

    @Test func devicePolicyApplicationReportRetainsUnobservedSelectorMatchedRules() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=1u L=0.15u AS=1 AD=2
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=1u L=0.15u AS=9 AD=8
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )
        let seed = NetgenLVSDevicePolicySeed(
            generatedAt: "2026-06-26T00:00:00Z",
            sourcePath: "sky130A_setup.tcl",
            devices: [
                NetgenLVSDeviceDescriptor(
                    deviceName: "sky130_fd_pr__nfet_01v8",
                    family: "mos",
                    sourceLineNumber: 10,
                    sourceLine: "lappend devices sky130_fd_pr__nfet_01v8"
                ),
                NetgenLVSDeviceDescriptor(
                    deviceName: "sky130_fd_pr__pfet_01v8",
                    family: "mos",
                    sourceLineNumber: 11,
                    sourceLine: "lappend devices sky130_fd_pr__pfet_01v8"
                ),
                NetgenLVSDeviceDescriptor(
                    deviceName: "sky130_fd_pr__diode_pw2nd_05v5",
                    family: "diode",
                    sourceLineNumber: 12,
                    sourceLine: "lappend devices sky130_fd_pr__diode_pw2nd_05v5"
                ),
                NetgenLVSDeviceDescriptor(
                    deviceName: "sky130_fd_pr__diode_pw2nd_05v5_alias",
                    family: "diode",
                    sourceLineNumber: 13,
                    sourceLine: "lappend devices sky130_fd_pr__diode_pw2nd_05v5_alias"
                ),
            ],
            policyRules: [
                NetgenLVSPolicyRule(
                    kind: "property",
                    arguments: ["-circuit1 sky130_fd_pr__nfet_01v8", "delete", "as", "ad"],
                    sourceLineNumber: 20,
                    sourceLine: "property \"-circuit1 sky130_fd_pr__nfet_01v8\" delete as ad"
                ),
                NetgenLVSPolicyRule(
                    kind: "property",
                    arguments: ["-circuit1 sky130_fd_pr__pfet_01v8", "delete", "as", "ad"],
                    sourceLineNumber: 21,
                    sourceLine: "property \"-circuit1 sky130_fd_pr__pfet_01v8\" delete as ad"
                ),
                NetgenLVSPolicyRule(
                    kind: "permute",
                    arguments: ["-circuit1 sky130_fd_pr__diode_pw2nd_05v5", "1", "2"],
                    sourceLineNumber: 22,
                    sourceLine: "permute \"-circuit1 sky130_fd_pr__diode_pw2nd_05v5\" 1 2"
                ),
                NetgenLVSPolicyRule(
                    kind: "equate-pins",
                    arguments: [
                        "pins",
                        "-circuit1 sky130_fd_pr__diode_pw2nd_05v5",
                        "-circuit2 sky130_fd_pr__diode_pw2nd_05v5_alias",
                    ],
                    sourceLineNumber: 23,
                    sourceLine: "equate pins \"-circuit1 sky130_fd_pr__diode_pw2nd_05v5\" \"-circuit2 sky130_fd_pr__diode_pw2nd_05v5_alias\""
                ),
                NetgenLVSPolicyRule(
                    kind: "blackbox",
                    arguments: ["model", "blackbox", "hard_macro"],
                    sourceLineNumber: 24,
                    sourceLine: "model blackbox hard_macro"
                ),
                NetgenLVSPolicyRule(
                    kind: "property",
                    arguments: ["-circuit1 missing_model", "delete", "as"],
                    sourceLineNumber: 25,
                    sourceLine: "property \"-circuit1 missing_model\" delete as"
                ),
            ]
        )
        let policyURL = try writeDevicePolicySeed(
            seed,
            name: "device-policy-application-breadth.json",
            in: directory
        )

        let policyResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(!policyResult.result.passed)
        #expect(policyResult.result.executionStatus == .completed)
        #expect(policyResult.result.verdict == .blocked)
        #expect(policyResult.result.readiness == .blocked)
        #expect(policyResult.result.blockingReasons.map(\.code) == ["device_policy_partial"])
        let report = try #require(policyResult.devicePolicyReport)
        #expect(report.status == .partial)
        #expect(report.knownDeviceCount == 4)
        #expect(report.observedKnownDeviceCount == 1)
        #expect(report.policyRuleCount == 6)
        #expect(report.appliedRuleCount == 1)
        #expect(report.ignoredRuleCount == 1)
        #expect(report.unobservedRuleCount == 4)
        #expect(report.policyRuleCountsByKind["property"] == 3)
        #expect(report.policyRuleCountsByKind["permute"] == 1)
        #expect(report.policyRuleCountsByKind["equate-pins"] == 1)
        #expect(report.policyRuleCountsByKind["blackbox"] == 1)
        #expect(report.appliedRuleCountsByKind["property-delete"] == 1)
        #expect(report.ignoredRuleCountsByReason["unresolved-device-selector"] == 1)
        #expect(report.unobservedRuleCountsByKind["property"] == 1)
        #expect(report.unobservedRuleCountsByKind["permute"] == 1)
        #expect(report.unobservedRuleCountsByKind["equate-pins"] == 1)
        #expect(report.unobservedRuleCountsByKind["blackbox"] == 1)
        #expect(report.unobservedRules.contains {
            $0.kind == "blackbox" && $0.targetModels == ["hard_macro"]
        })
        #expect(policyResult.result.diagnostics.contains { $0.ruleID == "LVS_DEVICE_POLICY_APPLIED" })
        #expect(policyResult.result.diagnostics.contains { $0.ruleID == "LVS_DEVICE_POLICY_IGNORED" })
        #expect(policyResult.result.diagnostics.contains {
            $0.ruleID == "LVS_DEVICE_POLICY_PARTIAL"
                && $0.effectiveWaiverDisposition == .nonWaivable
        })
        #expect(policyResult.result.diagnostics.contains { $0.ruleID == "LVS_DEVICE_POLICY_UNOBSERVED" })
        #expect(policyResult.result.diagnostics.contains {
            $0.ruleID == "LVS_DEVICE_POLICY_IGNORED_UNRESOLVED_DEVICE_SELECTOR"
                && $0.rawLine.contains("ignoredReason=unresolved-device-selector")
        })
        #expect(policyResult.result.diagnostics.contains {
            $0.ruleID == "LVS_DEVICE_POLICY_UNOBSERVED_SELECTOR_TARGET_NOT_OBSERVED"
                && $0.rawLine.contains("unobservedReason=selector-target-not-observed")
        })
    }

    @Test func devicePolicyPropertyToleranceAcceptsBoundedNumericParameterDelta() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=1.005 L=0.150
            M2 out in vss vss sky130_fd_pr__nfet_01v8 W=2.000 L=0.150
            .ends inv
            """,
            name: "layout.spice",
            in: directory
        )
        let schematicURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=1.000 L=0.150
            M2 out in vss vss sky130_fd_pr__nfet_01v8 W=2.000 L=0.150
            .ends inv
            """,
            name: "schematic.spice",
            in: directory
        )

        let defaultResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))
        #expect(!defaultResult.result.passed)

        let importedPolicy = NetgenLVSDeviceDeckImporter.importDeviceDeck(
            text: """
            set devices {}
            lappend devices sky130_fd_pr__nfet_01v8
            foreach dev $devices {
                property "-circuit1 $dev" tolerance {w 0.01} {l 0.01}
            }
            """,
            sourcePath: "sky130A_setup.tcl",
            generatedAt: "2026-06-23T00:00:00Z"
        )
        let policyURL = try writeDevicePolicySeed(
            importedPolicy.seed,
            name: "device-policy.json",
            in: directory
        )

        let policyResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "inv",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(policyResult.result.passed, "\(policyResult.result.diagnostics.map(\.message))")
        let report = try #require(policyResult.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 1)
        #expect(report.ignoredRuleCount == 0)
        let appliedRule = try #require(report.appliedRules.first)
        #expect(appliedRule.kind == "property-tolerance")
        #expect(appliedRule.parameterNames == ["l", "w"])
        #expect(appliedRule.parameterTolerances == ["l": 0.01, "w": 0.01])

        let outOfToleranceLayoutURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=1.020 L=0.150
            .ends inv
            """,
            name: "layout-out-of-tolerance.spice",
            in: directory
        )
        let outOfToleranceSchematicURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=1.000 L=0.150
            .ends inv
            """,
            name: "schematic-out-of-tolerance.spice",
            in: directory
        )
        let outOfToleranceResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: outOfToleranceLayoutURL,
            schematicNetlistURL: outOfToleranceSchematicURL,
            topCell: "inv",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))
        #expect(!outOfToleranceResult.result.passed)
        #expect(outOfToleranceResult.result.diagnostics.contains {
            $0.ruleID == "LVS_PARAMETER_MISMATCH"
                && $0.rawLine.contains("reason=device_parameter_mismatch")
        })

        let suffixOutOfToleranceLayoutURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=0.43u L=0.150u
            .ends inv
            """,
            name: "layout-suffix-out-of-tolerance.spice",
            in: directory
        )
        let suffixOutOfToleranceSchematicURL = try writeNetlist(
            """
            .subckt inv in out vss
            M1 out in vss vss sky130_fd_pr__nfet_01v8 W=0.42u L=0.150u
            .ends inv
            """,
            name: "schematic-suffix-out-of-tolerance.spice",
            in: directory
        )
        let suffixOutOfToleranceResult = try await NativeLVSBackend().run(LVSRequest(
            layoutNetlistURL: suffixOutOfToleranceLayoutURL,
            schematicNetlistURL: suffixOutOfToleranceSchematicURL,
            topCell: "inv",
            devicePolicyURL: policyURL,
            backendSelection: LVSBackendSelection(backendID: "native")
        ))
        #expect(!suffixOutOfToleranceResult.result.passed)
        #expect(suffixOutOfToleranceResult.result.diagnostics.contains {
            $0.ruleID == "LVS_PARAMETER_MISMATCH"
                && $0.rawLine.contains("reason=device_parameter_mismatch")
        })
    }

    @Test func conflictingModelEquivalencePolicyFailsExplicitly() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(matchingInverter, name: "layout.spice", in: directory)
        let schematicURL = try writeNetlist(matchingInverter, name: "schematic.spice", in: directory)
        let policyURL = try writeModelEquivalencePolicy(
            """
            {
              "schemaVersion" : 1,
              "groups" : [
                {
                  "canonicalModel" : "nmos",
                  "aliases" : ["nfet"]
                },
                {
                  "canonicalModel" : "pmos",
                  "aliases" : ["nfet"]
                }
              ]
            }
            """,
            name: "conflicting-model-equivalence.json",
            in: directory
        )

        do {
            _ = try await NativeLVSBackend().run(LVSRequest(
                layoutNetlistURL: layoutURL,
                schematicNetlistURL: schematicURL,
                topCell: "inv",
                modelEquivalenceURL: policyURL,
                backendSelection: LVSBackendSelection(backendID: "native")
            ))
            Issue.record("Expected conflicting model equivalence policy to fail.")
        } catch let error as LVSError {
            #expect(error == .invalidInput("Model equivalence alias nfet maps to both nmos and pmos."))
        }
    }

    @Test func invalidTerminalEquivalencePolicyFailsExplicitly() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutURL = try writeNetlist(matchingInverter, name: "layout.spice", in: directory)
        let schematicURL = try writeNetlist(matchingInverter, name: "schematic.spice", in: directory)
        let policyURL = try writeTerminalEquivalencePolicy(
            """
            {
              "schemaVersion" : 1,
              "rules" : [
                {
                  "equivalentPinGroups" : [[0, 2]],
                  "kind" : "diode",
                  "pinCount" : 2
                }
              ]
            }
            """,
            name: "invalid-terminal-equivalence.json",
            in: directory
        )

        do {
            _ = try await NativeLVSBackend().run(LVSRequest(
                layoutNetlistURL: layoutURL,
                schematicNetlistURL: schematicURL,
                topCell: "inv",
                terminalEquivalenceURL: policyURL,
                backendSelection: LVSBackendSelection(backendID: "native")
            ))
            Issue.record("Expected invalid terminal equivalence policy to fail.")
        } catch let error as LVSError {
            #expect(error == .invalidInput(
                "Terminal equivalence group for diode references a pin index outside pinCount 2."
            ))
        }
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
            .appending(path: "NativeLVSBackendTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeNetlist(_ netlist: String, name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try netlist.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeModelEquivalencePolicy(_ policy: String, name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try policy.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeTerminalEquivalencePolicy(_ policy: String, name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try policy.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeDevicePolicySeed(_ policy: String, name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try policy.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeDevicePolicySeed(
        _ seed: NetgenLVSDevicePolicySeed,
        name: String,
        in directory: URL
    ) throws -> URL {
        let url = directory.appending(path: name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(seed)
        try data.write(to: url, options: [.atomic])
        return url
    }
}
