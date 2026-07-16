import Testing
import LVSGraph
import LVSMatching

@Suite("Canonical LVS graph matcher")
struct LVSGraphMatcherTests {
    @Test func internalNetNamesDeviceNamesAndOrderingDoNotAffectEquivalence() throws {
        let layout = graph(
            internalNetName: "layout_internal",
            firstDeviceName: "LM2",
            secondDeviceName: "LM1",
            reverseOrder: true
        )
        let schematic = graph(
            internalNetName: "schematic_internal",
            firstDeviceName: "SM1",
            secondDeviceName: "SM2",
            reverseOrder: false
        )

        let result = try LVSGraphMatcher().match(layout: layout, schematic: schematic)

        #expect(result.status == .matched)
        #expect(result.correspondence.deviceMappings.count == 2)
        #expect(result.correspondence.netMappings.count == 3)
        #expect(result.correspondence.portMappings.map(\.portName) == ["in", "out"])
    }

    @Test func changedConnectivityIsAMismatch() throws {
        let layout = graph(
            internalNetName: "layout_internal",
            firstDeviceName: "L1",
            secondDeviceName: "L2",
            reverseOrder: false
        )
        let schematic = graphWithDisconnectedSecondDevice()

        let result = try LVSGraphMatcher().match(layout: layout, schematic: schematic)

        #expect(result.status == .mismatched)
        #expect(result.reasonCodes.contains("net_count_mismatch") || result.reasonCodes.contains("graph_not_isomorphic"))
    }

    @Test func extraPortIsAMismatch() throws {
        let layout = graph(
            internalNetName: "n1",
            firstDeviceName: "L1",
            secondDeviceName: "L2",
            reverseOrder: false
        )
        let base = graph(
            internalNetName: "n2",
            firstDeviceName: "S1",
            secondDeviceName: "S2",
            reverseOrder: false
        )
        let schematic = LVSGraph(
            topCell: base.topCell,
            devices: base.devices,
            nets: base.nets,
            ports: base.ports + [LVSGraphPort(name: "extra", netID: base.nets[0].id)]
        )

        let result = try LVSGraphMatcher().match(layout: layout, schematic: schematic)

        #expect(result.status == .mismatched)
        #expect(result.reasonCodes == ["port_set_mismatch"])
    }

    @Test func equivalentTerminalsMaySwap() throws {
        let input = LVSObjectID(rawValue: "layout-in")
        let output = LVSObjectID(rawValue: "layout-out")
        let layout = LVSGraph(
            topCell: "top",
            devices: [LVSGraphDevice(
                id: LVSObjectID(rawValue: "layout-r"),
                sourceName: "R1",
                kind: "resistor",
                model: "1000",
                terminals: [
                    LVSGraphTerminal(index: 0, netID: input),
                    LVSGraphTerminal(index: 1, netID: output),
                ],
                equivalentTerminalGroups: [[0, 1]]
            )],
            nets: [
                LVSGraphNet(id: input, sourceName: "in"),
                LVSGraphNet(id: output, sourceName: "out"),
            ],
            ports: [
                LVSGraphPort(name: "in", netID: input),
                LVSGraphPort(name: "out", netID: output),
            ]
        )
        let schematicInput = LVSObjectID(rawValue: "schematic-in")
        let schematicOutput = LVSObjectID(rawValue: "schematic-out")
        let schematic = LVSGraph(
            topCell: "top",
            devices: [LVSGraphDevice(
                id: LVSObjectID(rawValue: "schematic-r"),
                sourceName: "different-name",
                kind: "resistor",
                model: "1000",
                terminals: [
                    LVSGraphTerminal(index: 0, netID: schematicOutput),
                    LVSGraphTerminal(index: 1, netID: schematicInput),
                ],
                equivalentTerminalGroups: [[0, 1]]
            )],
            nets: [
                LVSGraphNet(id: schematicInput, sourceName: "in"),
                LVSGraphNet(id: schematicOutput, sourceName: "out"),
            ],
            ports: [
                LVSGraphPort(name: "in", netID: schematicInput),
                LVSGraphPort(name: "out", netID: schematicOutput),
            ]
        )

        let result = try LVSGraphMatcher().match(layout: layout, schematic: schematic)

        #expect(result.status == .matched)
    }

    @Test func exhaustedSearchBudgetBlocksInsteadOfGuessing() throws {
        let layout = ambiguousGraph(prefix: "layout")
        let schematic = ambiguousGraph(prefix: "schematic")

        let result = try LVSGraphMatcher().match(
            layout: layout,
            schematic: schematic,
            budget: LVSMatchBudget(maximumSearchStates: 1, maximumDurationSeconds: 1)
        )

        #expect(result.status == .blocked)
        #expect(result.reasonCodes == ["match_budget_exceeded"])
    }

    @Test func uniqueModelFastPathRespectsSearchBudget() throws {
        let layout = graph(
            internalNetName: "layout-internal",
            firstDeviceName: "L1",
            secondDeviceName: "L2",
            reverseOrder: true
        )
        let schematic = graph(
            internalNetName: "schematic-internal",
            firstDeviceName: "S1",
            secondDeviceName: "S2",
            reverseOrder: false
        )

        let result = try LVSGraphMatcher().match(
            layout: layout,
            schematic: schematic,
            budget: LVSMatchBudget(
                maximumSearchStates: 1,
                maximumDurationSeconds: 1,
                maximumSearchDepth: 2,
                maximumWorkingSetBytes: 1_024 * 1_024
            )
        )

        #expect(result.status == .blocked)
        #expect(result.reasonCodes == ["match_budget_exceeded"])
        #expect(result.exploredSearchStates == 1)
    }

    @Test func thousandSeedMetamorphicEquivalenceMatrix() throws {
        let reference = metamorphicChain(seed: 0, prefix: "reference")
        for seed in 1...1_000 {
            let candidate = metamorphicChain(seed: UInt64(seed), prefix: "candidate-\(seed)")
            let result = try LVSGraphMatcher().match(
                layout: reference,
                schematic: candidate,
                budget: LVSMatchBudget(
                    maximumSearchStates: 10_000,
                    maximumDurationSeconds: 1,
                    maximumSearchDepth: 100,
                    maximumWorkingSetBytes: 16 * 1_024 * 1_024
                )
            )
            #expect(result.status == .matched, "Metamorphic seed \(seed) did not match.")
            #expect(result.correspondence.deviceMappings.count == 6)
            #expect(result.correspondence.netMappings.count == 7)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func tenThousandDeviceEnvelope() throws {
        let (layout, schematic) = scaleGraphPair(deviceCount: 10_000)
        let clock = ContinuousClock()
        let startedAt = clock.now

        let result = try LVSGraphMatcher().match(
            layout: layout,
            schematic: schematic,
            budget: LVSMatchBudget(
                maximumSearchStates: 20_000,
                maximumDurationSeconds: 2,
                maximumSearchDepth: 20_000,
                maximumWorkingSetBytes: 512 * 1_024 * 1_024
            )
        )

        #expect(result.status == .matched)
        #expect(startedAt.duration(to: clock.now) < .seconds(2))
    }

    @Test(.timeLimit(.minutes(1)))
    func hundredThousandDeviceEnvelope() throws {
        let (layout, schematic) = scaleGraphPair(deviceCount: 100_000)
        let clock = ContinuousClock()
        let startedAt = clock.now

        let result = try LVSGraphMatcher().match(
            layout: layout,
            schematic: schematic,
            budget: LVSMatchBudget(
                maximumSearchStates: 200_000,
                maximumDurationSeconds: 30,
                maximumSearchDepth: 200_000,
                maximumWorkingSetBytes: 2 * 1_024 * 1_024 * 1_024
            )
        )

        #expect(result.status == .matched)
        #expect(startedAt.duration(to: clock.now) < .seconds(30))
    }

    @Test(.timeLimit(.minutes(5)))
    func oneMillionDeviceEnvelope() throws {
        let (layout, schematic) = scaleGraphPair(deviceCount: 1_000_000)
        let clock = ContinuousClock()
        let startedAt = clock.now

        let result = try LVSGraphMatcher().match(
            layout: layout,
            schematic: schematic,
            budget: LVSMatchBudget(
                maximumSearchStates: 2_000_000,
                maximumDurationSeconds: 300,
                maximumSearchDepth: 2_000_000,
                maximumWorkingSetBytes: 8 * 1_024 * 1_024 * 1_024
            )
        )

        #expect(result.status == .matched)
        #expect(startedAt.duration(to: clock.now) < .seconds(300))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationLatencyP95IsBelowFiveHundredMilliseconds() async throws {
        let (layout, schematic) = scaleGraphPair(deviceCount: 100_000)
        let clock = ContinuousClock()
        var latencies: [Duration] = []

        for _ in 0..<20 {
            let task = Task {
                try LVSGraphMatcher().match(
                    layout: layout,
                    schematic: schematic,
                    budget: LVSMatchBudget(
                        maximumSearchStates: 200_000,
                        maximumDurationSeconds: 30,
                        maximumSearchDepth: 200_000,
                        maximumWorkingSetBytes: 2 * 1_024 * 1_024 * 1_024
                    )
                )
            }
            try await Task.sleep(for: .milliseconds(5))
            let cancellationStartedAt = clock.now
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("Matcher completed before observing cancellation.")
            } catch is CancellationError {
                latencies.append(cancellationStartedAt.duration(to: clock.now))
            } catch {
                Issue.record("Matcher cancellation returned an unexpected error: \(error)")
            }
        }

        #expect(latencies.count == 20)
        let sortedLatencies = latencies.sorted()
        let percentileIndex = Int((Double(sortedLatencies.count) * 0.95).rounded(.up)) - 1
        #expect(sortedLatencies[percentileIndex] < .milliseconds(500))
    }

    private func graph(
        internalNetName: String,
        firstDeviceName: String,
        secondDeviceName: String,
        reverseOrder: Bool
    ) -> LVSGraph {
        let input = LVSObjectID(rawValue: "net-in")
        let internalNet = LVSObjectID(rawValue: "net-\(internalNetName)")
        let output = LVSObjectID(rawValue: "net-out")
        let first = LVSGraphDevice(
            id: LVSObjectID(rawValue: "device-\(firstDeviceName)"),
            sourceName: firstDeviceName,
            kind: "resistor",
            model: "1000",
            terminals: [
                LVSGraphTerminal(index: 0, netID: input),
                LVSGraphTerminal(index: 1, netID: internalNet),
            ],
            equivalentTerminalGroups: [[0, 1]]
        )
        let second = LVSGraphDevice(
            id: LVSObjectID(rawValue: "device-\(secondDeviceName)"),
            sourceName: secondDeviceName,
            kind: "resistor",
            model: "2000",
            terminals: [
                LVSGraphTerminal(index: 0, netID: internalNet),
                LVSGraphTerminal(index: 1, netID: output),
            ],
            equivalentTerminalGroups: [[0, 1]]
        )
        return LVSGraph(
            topCell: "top",
            devices: reverseOrder ? [second, first] : [first, second],
            nets: [
                LVSGraphNet(id: input, sourceName: "in"),
                LVSGraphNet(id: internalNet, sourceName: internalNetName),
                LVSGraphNet(id: output, sourceName: "out"),
            ],
            ports: [
                LVSGraphPort(name: "in", netID: input),
                LVSGraphPort(name: "out", netID: output),
            ]
        )
    }

    private func graphWithDisconnectedSecondDevice() -> LVSGraph {
        let base = graph(
            internalNetName: "schematic_internal",
            firstDeviceName: "S1",
            secondDeviceName: "S2",
            reverseOrder: false
        )
        let disconnected = LVSObjectID(rawValue: "net-disconnected")
        let second = base.devices[1]
        let changedSecond = LVSGraphDevice(
            id: second.id,
            sourceName: second.sourceName,
            kind: second.kind,
            model: second.model,
            terminals: [
                LVSGraphTerminal(index: 0, netID: disconnected),
                second.terminals[1],
            ],
            equivalentTerminalGroups: second.equivalentTerminalGroups,
            parameters: second.parameters
        )
        return LVSGraph(
            topCell: base.topCell,
            devices: [base.devices[0], changedSecond],
            nets: base.nets + [LVSGraphNet(id: disconnected, sourceName: "disconnected")],
            ports: base.ports
        )
    }

    private func ambiguousGraph(prefix: String) -> LVSGraph {
        let net = LVSObjectID(rawValue: "\(prefix)-net")
        let devices = (0..<3).map { index in
            LVSGraphDevice(
                id: LVSObjectID(rawValue: "\(prefix)-device-\(index)"),
                sourceName: "device-\(index)",
                kind: "capacitor",
                model: "1e-12",
                terminals: [
                    LVSGraphTerminal(index: 0, netID: net),
                    LVSGraphTerminal(index: 1, netID: net),
                ],
                equivalentTerminalGroups: [[0, 1]]
            )
        }
        return LVSGraph(
            topCell: "top",
            devices: devices,
            nets: [LVSGraphNet(id: net, sourceName: "net")],
            ports: []
        )
    }

    private func metamorphicChain(seed: UInt64, prefix: String) -> LVSGraph {
        let nets = (0...6).map { index in
            LVSGraphNet(
                id: LVSObjectID(rawValue: "\(prefix)-net-id-\(index)"),
                sourceName: index == 0 ? "in" : (index == 6 ? "out" : "\(prefix)-renamed-\(seed)-\(index)")
            )
        }
        let devices = (0..<6).map { index in
            LVSGraphDevice(
                id: LVSObjectID(rawValue: "\(prefix)-device-id-\(seed)-\(index)"),
                sourceName: "\(prefix)-instance-\(seed)-\(index)",
                kind: "resistor",
                model: "\(1_000 + index)",
                terminals: [
                    LVSGraphTerminal(index: 0, netID: nets[index].id),
                    LVSGraphTerminal(index: 1, netID: nets[index + 1].id),
                ],
                equivalentTerminalGroups: [[0, 1]]
            )
        }
        return LVSGraph(
            topCell: "top",
            devices: seededPermutation(devices, seed: seed),
            nets: seededPermutation(nets, seed: seed ^ 0x9e3779b97f4a7c15),
            ports: [
                LVSGraphPort(name: "in", netID: nets[0].id),
                LVSGraphPort(name: "out", netID: nets[6].id),
            ]
        )
    }

    private func seededPermutation<Element>(_ values: [Element], seed: UInt64) -> [Element] {
        var state = seed == 0 ? 0xd1b54a32d192ed03 : seed
        var result = values
        guard result.count > 1 else { return result }
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let destination = Int(state % UInt64(index + 1))
            result.swapAt(index, destination)
        }
        return result
    }

    private func scaleGraphPair(deviceCount: Int) -> (layout: LVSGraph, schematic: LVSGraph) {
        // Scale tests exercise matcher cardinality, while the smaller metamorphic
        // tests cover renaming and ordering. Sharing immutable fixture storage
        // avoids measuring duplicate graph construction and memory pressure.
        var nets: [LVSGraphNet] = []
        nets.reserveCapacity(deviceCount + 1)
        for index in stride(from: deviceCount, through: 0, by: -1) {
            let sourceName = index == 0 ? "in" : (index == deviceCount ? "out" : "internal")
            nets.append(LVSGraphNet(
                id: LVSObjectID(rawValue: "n\(index)"),
                sourceName: sourceName
            ))
        }
        var devices: [LVSGraphDevice] = []
        devices.reserveCapacity(deviceCount)
        let equivalentTerminalGroups = [[0, 1]]
        for index in stride(from: deviceCount - 1, through: 0, by: -1) {
            let netOffset = deviceCount - index
            devices.append(LVSGraphDevice(
                id: LVSObjectID(rawValue: "d\(index)"),
                sourceName: "instance",
                kind: "resistor",
                model: "m\(index)",
                terminals: [
                    LVSGraphTerminal(index: 0, netID: nets[netOffset].id),
                    LVSGraphTerminal(index: 1, netID: nets[netOffset - 1].id),
                ],
                equivalentTerminalGroups: equivalentTerminalGroups
            ))
        }
        let graph = LVSGraph(
            topCell: "top",
            devices: devices,
            nets: nets,
            ports: [
                LVSGraphPort(name: "in", netID: nets[deviceCount].id),
                LVSGraphPort(name: "out", netID: nets[0].id),
            ]
        )
        return (graph, graph)
    }
}
