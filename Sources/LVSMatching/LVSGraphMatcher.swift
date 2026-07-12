import Foundation
import LVSGraph

public struct LVSGraphMatcher: Sendable {
    public init() {}

    public func match(
        layout: LVSGraph,
        schematic: LVSGraph,
        budget: LVSMatchBudget = LVSMatchBudget()
    ) throws -> LVSGraphMatchResult {
        try validate(layout)
        try validate(schematic)

        guard budget.maximumSearchStates > 0,
              budget.maximumDurationSeconds > 0,
              budget.maximumSearchDepth > 0,
              budget.maximumWorkingSetBytes > 0 else {
            return blocked(reason: "invalid_match_budget")
        }
        guard layout.devices.count <= budget.maximumSearchDepth else {
            return blocked(reason: "match_depth_budget_exceeded")
        }
        guard layout.devices.count == schematic.devices.count else {
            return mismatch(layout: layout, schematic: schematic, reason: "device_count_mismatch")
        }
        guard Set(layout.ports.map(\.name)) == Set(schematic.ports.map(\.name)) else {
            return mismatch(layout: layout, schematic: schematic, reason: "port_set_mismatch")
        }
        guard layout.nets.count == schematic.nets.count else {
            return mismatch(layout: layout, schematic: schematic, reason: "net_count_mismatch")
        }

        var initialNetMap: [LVSObjectID: LVSObjectID] = [:]
        var initialReverseNetMap: [LVSObjectID: LVSObjectID] = [:]
        var portMappings: [LVSPortCorrespondence] = []
        let schematicPortsByName = Dictionary(
            uniqueKeysWithValues: schematic.ports.map { ($0.name, $0) }
        )
        for layoutPort in layout.ports.sorted(by: { $0.name < $1.name }) {
            guard let schematicPort = schematicPortsByName[layoutPort.name] else {
                return mismatch(layout: layout, schematic: schematic, reason: "port_set_mismatch")
            }
            guard extendBijection(
                    layout: layoutPort.netID,
                    schematic: schematicPort.netID,
                    forward: &initialNetMap,
                    reverse: &initialReverseNetMap
                  ) else {
                return mismatch(layout: layout, schematic: schematic, reason: "port_connectivity_mismatch")
            }
            portMappings.append(LVSPortCorrespondence(
                portName: layoutPort.name,
                layoutNetID: layoutPort.netID,
                schematicNetID: schematicPort.netID
            ))
        }
        let layoutGlobals = Dictionary(
            uniqueKeysWithValues: layout.nets.filter(\.isGlobal).map { ($0.sourceName.lowercased(), $0.id) }
        )
        let schematicGlobals = Dictionary(
            uniqueKeysWithValues: schematic.nets.filter(\.isGlobal).map { ($0.sourceName.lowercased(), $0.id) }
        )
        guard Set(layoutGlobals.keys) == Set(schematicGlobals.keys) else {
            return mismatch(layout: layout, schematic: schematic, reason: "global_net_set_mismatch")
        }
        for name in layoutGlobals.keys.sorted() {
            guard let layoutNet = layoutGlobals[name], let schematicNet = schematicGlobals[name],
                  extendBijection(
                    layout: layoutNet,
                    schematic: schematicNet,
                    forward: &initialNetMap,
                    reverse: &initialReverseNetMap
                  ) else {
                return mismatch(layout: layout, schematic: schematic, reason: "global_net_connectivity_mismatch")
            }
        }

        var schematicByShape: [String: [LVSGraphDevice]] = [:]
        schematicByShape.reserveCapacity(schematic.devices.count)
        for (index, device) in schematic.devices.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            schematicByShape[deviceShape(device), default: []].append(device)
        }
        var parameterMismatchDetected = false
        var candidatesByLayoutID: [LVSObjectID: [LVSGraphDevice]] = [:]
        candidatesByLayoutID.reserveCapacity(layout.devices.count)
        for (index, device) in layout.devices.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let semanticCandidates = schematicByShape[deviceShape(device), default: []]
            let candidates = semanticCandidates
                .filter { parametersMatch(device.parameters, $0.parameters) }
                .sorted { $0.id < $1.id }
            if candidates.isEmpty, !semanticCandidates.isEmpty {
                parameterMismatchDetected = true
            }
            candidatesByLayoutID[device.id] = candidates
        }
        guard !candidatesByLayoutID.values.contains(where: \.isEmpty) else {
            return mismatch(
                layout: layout,
                schematic: schematic,
                reason: parameterMismatchDetected
                    ? "device_parameter_mismatch"
                    : "device_semantics_mismatch"
            )
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(budget.maximumDurationSeconds))
        if let uniqueResult = try matchUniqueCandidates(
            layout: layout,
            schematic: schematic,
            layoutDevices: layout.devices,
            candidatesByLayoutID: candidatesByLayoutID,
            initialNetMap: initialNetMap,
            initialReverseNetMap: initialReverseNetMap,
            portMappings: portMappings,
            budget: budget,
            clock: clock,
            deadline: deadline
        ) {
            return uniqueResult
        }
        let orderedLayoutDevices = layout.devices.sorted { lhs, rhs in
            let lhsCount = candidatesByLayoutID[lhs.id, default: []].count
            let rhsCount = candidatesByLayoutID[rhs.id, default: []].count
            if lhsCount != rhsCount { return lhsCount < rhsCount }
            return lhs.id < rhs.id
        }
        var stateCount = 0
        var deviceMap: [LVSObjectID: LVSObjectID] = [:]
        var usedSchematicDevices = Set<LVSObjectID>()
        var netMap = initialNetMap
        var reverseNetMap = initialReverseNetMap
        let matched = try search(
            index: 0,
            layoutDevices: orderedLayoutDevices,
            candidatesByLayoutID: candidatesByLayoutID,
            deviceMap: &deviceMap,
            usedSchematicDevices: &usedSchematicDevices,
            netMap: &netMap,
            reverseNetMap: &reverseNetMap,
            stateCount: &stateCount,
            maximumSearchStates: budget.maximumSearchStates,
            maximumSearchDepth: budget.maximumSearchDepth,
            maximumWorkingSetBytes: budget.maximumWorkingSetBytes,
            clock: clock,
            deadline: deadline
        )
        switch matched {
        case .matched:
            guard try completeIsolatedNetMappings(
                layout: layout,
                schematic: schematic,
                forward: &netMap,
                reverse: &reverseNetMap
            ) else {
                return mismatch(layout: layout, schematic: schematic, reason: "isolated_net_mismatch")
            }
            return LVSGraphMatchResult(
                status: .matched,
                correspondence: LVSCorrespondence(
                    deviceMappings: deviceMap.map {
                        LVSObjectCorrespondence(layoutObjectID: $0.key, schematicObjectID: $0.value)
                    },
                    netMappings: netMap.map {
                        LVSObjectCorrespondence(layoutObjectID: $0.key, schematicObjectID: $0.value)
                    },
                    portMappings: portMappings
                ),
                exploredSearchStates: stateCount
            )
        case .notMatched:
            return mismatch(layout: layout, schematic: schematic, reason: "graph_not_isomorphic", states: stateCount)
        case .budgetExceeded:
            return LVSGraphMatchResult(
                status: .blocked,
                correspondence: LVSCorrespondence(
                    deviceMappings: deviceMap.map {
                        LVSObjectCorrespondence(layoutObjectID: $0.key, schematicObjectID: $0.value)
                    },
                    netMappings: netMap.map {
                        LVSObjectCorrespondence(layoutObjectID: $0.key, schematicObjectID: $0.value)
                    },
                    portMappings: portMappings,
                    ambiguousLayoutObjectIDs: orderedLayoutDevices.dropFirst(deviceMap.count).map(\.id)
                ),
                reasonCodes: ["match_budget_exceeded"],
                exploredSearchStates: stateCount
            )
        case .depthExceeded:
            return blocked(reason: "match_depth_budget_exceeded")
        case .memoryExceeded:
            return blocked(reason: "match_memory_budget_exceeded")
        }
    }

    private enum SearchOutcome: Equatable {
        case matched
        case notMatched
        case budgetExceeded
        case depthExceeded
        case memoryExceeded
    }

    private func matchUniqueCandidates(
        layout: LVSGraph,
        schematic: LVSGraph,
        layoutDevices: [LVSGraphDevice],
        candidatesByLayoutID: [LVSObjectID: [LVSGraphDevice]],
        initialNetMap: [LVSObjectID: LVSObjectID],
        initialReverseNetMap: [LVSObjectID: LVSObjectID],
        portMappings: [LVSPortCorrespondence],
        budget: LVSMatchBudget,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) throws -> LVSGraphMatchResult? {
        var uniqueCandidateIDs = Set<LVSObjectID>()
        uniqueCandidateIDs.reserveCapacity(layoutDevices.count)
        for (index, layoutDevice) in layoutDevices.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            guard let candidates = candidatesByLayoutID[layoutDevice.id],
                  candidates.count == 1,
                  let candidate = candidates.first,
                  uniqueCandidateIDs.insert(candidate.id).inserted else {
                return nil
            }
        }

        var deviceMap: [LVSObjectID: LVSObjectID] = [:]
        deviceMap.reserveCapacity(layoutDevices.count)
        var netMap = initialNetMap
        netMap.reserveCapacity(layout.nets.count)
        var reverseNetMap = initialReverseNetMap
        reverseNetMap.reserveCapacity(schematic.nets.count)
        var stateCount = 0
        for (index, layoutDevice) in layoutDevices.enumerated() {
            if index.isMultiple(of: 1_024) {
                try Task.checkCancellation()
                guard clock.now <= deadline else {
                    return blockedUniqueResult(
                        reason: "match_budget_exceeded",
                        deviceMap: deviceMap,
                        netMap: netMap,
                        portMappings: portMappings,
                        remainingLayoutDevices: layoutDevices.dropFirst(index),
                        states: stateCount
                    )
                }
            }
            guard index < budget.maximumSearchDepth else {
                return blockedUniqueResult(
                    reason: "match_depth_budget_exceeded",
                    deviceMap: deviceMap,
                    netMap: netMap,
                    portMappings: portMappings,
                    remainingLayoutDevices: layoutDevices.dropFirst(index),
                    states: stateCount
                )
            }
            let estimatedWorkingSetBytes = (
                deviceMap.count + netMap.count + reverseNetMap.count + uniqueCandidateIDs.count
            ) * 128
            guard estimatedWorkingSetBytes <= budget.maximumWorkingSetBytes else {
                return blockedUniqueResult(
                    reason: "match_memory_budget_exceeded",
                    deviceMap: deviceMap,
                    netMap: netMap,
                    portMappings: portMappings,
                    remainingLayoutDevices: layoutDevices.dropFirst(index),
                    states: stateCount
                )
            }
            guard stateCount < budget.maximumSearchStates,
                  let schematicDevice = candidatesByLayoutID[layoutDevice.id]?.first else {
                return blockedUniqueResult(
                    reason: "match_budget_exceeded",
                    deviceMap: deviceMap,
                    netMap: netMap,
                    portMappings: portMappings,
                    remainingLayoutDevices: layoutDevices.dropFirst(index),
                    states: stateCount
                )
            }
            var terminalMappingMatched = false
            for terminalMap in terminalIndexMappings(for: layoutDevice) {
                stateCount += 1
                if extendTerminalsIfConsistent(
                    layoutDevice,
                    schematicDevice,
                    terminalMap: terminalMap,
                    netMap: &netMap,
                    reverseNetMap: &reverseNetMap
                ) {
                    terminalMappingMatched = true
                    break
                }
            }
            guard terminalMappingMatched else {
                return mismatch(
                    layout: layout,
                    schematic: schematic,
                    reason: "graph_not_isomorphic",
                    states: stateCount
                )
            }
            deviceMap[layoutDevice.id] = schematicDevice.id
        }
        guard try completeIsolatedNetMappings(
            layout: layout,
            schematic: schematic,
            forward: &netMap,
            reverse: &reverseNetMap
        ) else {
            return mismatch(
                layout: layout,
                schematic: schematic,
                reason: "isolated_net_mismatch",
                states: stateCount
            )
        }
        return LVSGraphMatchResult(
            status: .matched,
            correspondence: LVSCorrespondence(
                deviceMappings: deviceMap.map {
                    LVSObjectCorrespondence(layoutObjectID: $0.key, schematicObjectID: $0.value)
                },
                netMappings: netMap.map {
                    LVSObjectCorrespondence(layoutObjectID: $0.key, schematicObjectID: $0.value)
                },
                portMappings: portMappings
            ),
            exploredSearchStates: stateCount
        )
    }

    private func extendTerminalsIfConsistent(
        _ layout: LVSGraphDevice,
        _ schematic: LVSGraphDevice,
        terminalMap: [Int],
        netMap: inout [LVSObjectID: LVSObjectID],
        reverseNetMap: inout [LVSObjectID: LVSObjectID]
    ) -> Bool {
        guard layout.terminals.count == schematic.terminals.count else { return false }
        var additions: [(layout: LVSObjectID, schematic: LVSObjectID)] = []
        additions.reserveCapacity(layout.terminals.count)
        for layoutIndex in layout.terminals.indices {
            let layoutNetID = layout.terminals[layoutIndex].netID
            let schematicNetID = schematic.terminals[terminalMap[layoutIndex]].netID
            if let existing = netMap[layoutNetID] {
                guard existing == schematicNetID else { return false }
                continue
            }
            if let existing = reverseNetMap[schematicNetID] {
                guard existing == layoutNetID else { return false }
                continue
            }
            if let existing = additions.first(where: { $0.layout == layoutNetID }) {
                guard existing.schematic == schematicNetID else { return false }
                continue
            }
            if let existing = additions.first(where: { $0.schematic == schematicNetID }) {
                guard existing.layout == layoutNetID else { return false }
                continue
            }
            additions.append((layoutNetID, schematicNetID))
        }
        for addition in additions {
            netMap[addition.layout] = addition.schematic
            reverseNetMap[addition.schematic] = addition.layout
        }
        return true
    }

    private func blockedUniqueResult(
        reason: String,
        deviceMap: [LVSObjectID: LVSObjectID],
        netMap: [LVSObjectID: LVSObjectID],
        portMappings: [LVSPortCorrespondence],
        remainingLayoutDevices: ArraySlice<LVSGraphDevice>,
        states: Int
    ) -> LVSGraphMatchResult {
        LVSGraphMatchResult(
            status: .blocked,
            correspondence: LVSCorrespondence(
                deviceMappings: deviceMap.map {
                    LVSObjectCorrespondence(layoutObjectID: $0.key, schematicObjectID: $0.value)
                },
                netMappings: netMap.map {
                    LVSObjectCorrespondence(layoutObjectID: $0.key, schematicObjectID: $0.value)
                },
                portMappings: portMappings,
                ambiguousLayoutObjectIDs: remainingLayoutDevices.map(\.id)
            ),
            reasonCodes: [reason],
            exploredSearchStates: states
        )
    }

    private func search(
        index: Int,
        layoutDevices: [LVSGraphDevice],
        candidatesByLayoutID: [LVSObjectID: [LVSGraphDevice]],
        deviceMap: inout [LVSObjectID: LVSObjectID],
        usedSchematicDevices: inout Set<LVSObjectID>,
        netMap: inout [LVSObjectID: LVSObjectID],
        reverseNetMap: inout [LVSObjectID: LVSObjectID],
        stateCount: inout Int,
        maximumSearchStates: Int,
        maximumSearchDepth: Int,
        maximumWorkingSetBytes: Int,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) throws -> SearchOutcome {
        try Task.checkCancellation()
        guard index <= maximumSearchDepth else {
            return .depthExceeded
        }
        let estimatedWorkingSetBytes = (
            deviceMap.count
                + usedSchematicDevices.count
                + netMap.count
                + reverseNetMap.count
                + candidatesByLayoutID.values.reduce(0) { $0 + $1.count }
        ) * 128
        guard estimatedWorkingSetBytes <= maximumWorkingSetBytes else {
            return .memoryExceeded
        }
        guard stateCount < maximumSearchStates, clock.now <= deadline else {
            return .budgetExceeded
        }
        guard index < layoutDevices.count else {
            return .matched
        }
        let layoutDevice = layoutDevices[index]
        for schematicDevice in candidatesByLayoutID[layoutDevice.id, default: []]
        where !usedSchematicDevices.contains(schematicDevice.id) {
            for terminalMap in terminalIndexMappings(for: layoutDevice) {
                stateCount += 1
                guard stateCount <= maximumSearchStates, clock.now <= deadline else {
                    return .budgetExceeded
                }
                var candidateNetMap = netMap
                var candidateReverseNetMap = reverseNetMap
                guard terminalsMatch(
                    layoutDevice,
                    schematicDevice,
                    terminalMap: terminalMap,
                    netMap: &candidateNetMap,
                    reverseNetMap: &candidateReverseNetMap
                ) else {
                    continue
                }
                deviceMap[layoutDevice.id] = schematicDevice.id
                usedSchematicDevices.insert(schematicDevice.id)
                let outcome = try search(
                    index: index + 1,
                    layoutDevices: layoutDevices,
                    candidatesByLayoutID: candidatesByLayoutID,
                    deviceMap: &deviceMap,
                    usedSchematicDevices: &usedSchematicDevices,
                    netMap: &candidateNetMap,
                    reverseNetMap: &candidateReverseNetMap,
                    stateCount: &stateCount,
                    maximumSearchStates: maximumSearchStates,
                    maximumSearchDepth: maximumSearchDepth,
                    maximumWorkingSetBytes: maximumWorkingSetBytes,
                    clock: clock,
                    deadline: deadline
                )
                if outcome == .matched {
                    netMap = candidateNetMap
                    reverseNetMap = candidateReverseNetMap
                    return .matched
                }
                if outcome == .budgetExceeded {
                    netMap = candidateNetMap
                    reverseNetMap = candidateReverseNetMap
                    return .budgetExceeded
                }
                if outcome == .depthExceeded || outcome == .memoryExceeded {
                    return outcome
                }
                deviceMap.removeValue(forKey: layoutDevice.id)
                usedSchematicDevices.remove(schematicDevice.id)
            }
        }
        return .notMatched
    }

    private func terminalsMatch(
        _ layout: LVSGraphDevice,
        _ schematic: LVSGraphDevice,
        terminalMap: [Int],
        netMap: inout [LVSObjectID: LVSObjectID],
        reverseNetMap: inout [LVSObjectID: LVSObjectID]
    ) -> Bool {
        guard layout.terminals.count == schematic.terminals.count else { return false }
        for layoutIndex in layout.terminals.indices {
            let schematicIndex = terminalMap[layoutIndex]
            guard extendBijection(
                layout: layout.terminals[layoutIndex].netID,
                schematic: schematic.terminals[schematicIndex].netID,
                forward: &netMap,
                reverse: &reverseNetMap
            ) else {
                return false
            }
        }
        return true
    }

    private func terminalIndexMappings(for device: LVSGraphDevice) -> [[Int]] {
        var mappings = [Array(device.terminals.indices)]
        for group in device.equivalentTerminalGroups {
            let permutations = permutations(of: group)
            mappings = mappings.flatMap { mapping in
                permutations.map { permutation in
                    var updated = mapping
                    for (sourceIndex, destinationIndex) in zip(group, permutation) {
                        updated[sourceIndex] = destinationIndex
                    }
                    return updated
                }
            }
        }
        return mappings
    }

    private func permutations(of values: [Int]) -> [[Int]] {
        guard let first = values.first else { return [[]] }
        return permutations(of: Array(values.dropFirst())).flatMap { remainder in
            (0...remainder.count).map { index in
                var result = remainder
                result.insert(first, at: index)
                return result
            }
        }
    }

    private func deviceShape(_ device: LVSGraphDevice) -> String {
        let parameterNames = device.parameters.map(\.name).joined(separator: ",")
        let groups = device.equivalentTerminalGroups
            .map { $0.map(String.init).joined(separator: ",") }
            .joined(separator: ";")
        return "\(device.kind)|\(device.model)|\(device.terminals.count)|\(groups)|\(parameterNames)"
    }

    private func parametersMatch(_ lhs: [LVSGraphParameter], _ rhs: [LVSGraphParameter]) -> Bool {
        guard lhs.map(\.name) == rhs.map(\.name) else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            if left.canonicalValue == right.canonicalValue { return true }
            guard let leftValue = left.numericValue, let rightValue = right.numericValue else { return false }
            let tolerance = max(left.relativeTolerance, right.relativeTolerance)
            let scale = max(abs(leftValue), abs(rightValue))
            if scale == 0 { return leftValue == rightValue }
            return abs(leftValue - rightValue) / scale <= tolerance
        }
    }

    private func completeIsolatedNetMappings(
        layout: LVSGraph,
        schematic: LVSGraph,
        forward: inout [LVSObjectID: LVSObjectID],
        reverse: inout [LVSObjectID: LVSObjectID]
    ) throws -> Bool {
        var remainingLayout: [LVSGraphNet] = []
        var remainingSchematic: [LVSGraphNet] = []
        for (index, net) in layout.nets.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            if forward[net.id] == nil { remainingLayout.append(net) }
        }
        for (index, net) in schematic.nets.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            if reverse[net.id] == nil { remainingSchematic.append(net) }
        }
        let layoutByGlobal = Dictionary(grouping: remainingLayout, by: \.isGlobal)
        let schematicByGlobal = Dictionary(grouping: remainingSchematic, by: \.isGlobal)
        for isGlobal in [false, true] {
            let layoutNets = layoutByGlobal[isGlobal, default: []].sorted { $0.id < $1.id }
            let schematicNets = schematicByGlobal[isGlobal, default: []].sorted { $0.id < $1.id }
            guard layoutNets.count == schematicNets.count else { return false }
            for (layoutNet, schematicNet) in zip(layoutNets, schematicNets) {
                guard extendBijection(
                    layout: layoutNet.id,
                    schematic: schematicNet.id,
                    forward: &forward,
                    reverse: &reverse
                ) else { return false }
            }
        }
        return true
    }

    private func extendBijection(
        layout: LVSObjectID,
        schematic: LVSObjectID,
        forward: inout [LVSObjectID: LVSObjectID],
        reverse: inout [LVSObjectID: LVSObjectID]
    ) -> Bool {
        if let existing = forward[layout] { return existing == schematic }
        if let existing = reverse[schematic] { return existing == layout }
        forward[layout] = schematic
        reverse[schematic] = layout
        return true
    }

    private func validate(_ graph: LVSGraph) throws {
        guard graph.schemaVersion == LVSGraph.currentSchemaVersion else {
            throw LVSGraphMatcherError.invalidGraph("Unsupported graph schema version.")
        }
        var deviceIDs = Set<LVSObjectID>()
        deviceIDs.reserveCapacity(graph.devices.count)
        for (index, device) in graph.devices.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            guard deviceIDs.insert(device.id).inserted else {
                throw LVSGraphMatcherError.invalidGraph("Graph object IDs must be unique by kind.")
            }
        }
        var knownNets = Set<LVSObjectID>()
        knownNets.reserveCapacity(graph.nets.count)
        for (index, net) in graph.nets.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            guard knownNets.insert(net.id).inserted else {
                throw LVSGraphMatcherError.invalidGraph("Graph object IDs must be unique by kind.")
            }
        }
        for (index, device) in graph.devices.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            guard device.terminals.allSatisfy({ knownNets.contains($0.netID) }) else {
                throw LVSGraphMatcherError.invalidGraph("Every terminal and port must reference a known net.")
            }
        }
        guard graph.ports.allSatisfy({ knownNets.contains($0.netID) }) else {
            throw LVSGraphMatcherError.invalidGraph("Every terminal and port must reference a known net.")
        }
        guard Set(graph.ports.map(\.name)).count == graph.ports.count else {
            throw LVSGraphMatcherError.invalidGraph("Port names must be unique.")
        }
    }

    private func mismatch(
        layout: LVSGraph,
        schematic: LVSGraph,
        reason: String,
        states: Int = 0
    ) -> LVSGraphMatchResult {
        LVSGraphMatchResult(
            status: .mismatched,
            correspondence: LVSCorrespondence(
                deviceMappings: [],
                netMappings: [],
                portMappings: [],
                unmatchedLayoutObjectIDs: layout.devices.map(\.id) + layout.nets.map(\.id),
                unmatchedSchematicObjectIDs: schematic.devices.map(\.id) + schematic.nets.map(\.id)
            ),
            reasonCodes: [reason],
            exploredSearchStates: states
        )
    }

    private func blocked(reason: String) -> LVSGraphMatchResult {
        LVSGraphMatchResult(
            status: .blocked,
            correspondence: LVSCorrespondence(deviceMappings: [], netMappings: [], portMappings: []),
            reasonCodes: [reason],
            exploredSearchStates: 0
        )
    }
}
