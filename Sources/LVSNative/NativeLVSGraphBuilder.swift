import LVSGraph
import LVSCore
import LVSNetlistParsing

struct NativeLVSGraphBuilder: Sendable {
    func build(
        netlist: NativeLVSNetlist,
        modelEquivalence: [String: String],
        terminalEquivalence: LVSTerminalEquivalenceResolver,
        parameterPolicy: NativeLVSBackend.LVSParameterComparisonPolicy,
        modelKinds: [String: String] = [:],
        maximumObjectCount: Int,
        sharedGlobalNetNames: Set<String>
    ) throws -> LVSGraph {
        let globalNets = Set(netlist.globalNets.map(normalizedNetName)).union(
            sharedGlobalNetNames.map(normalizedNetName)
        )
        let netNames = Set(
            netlist.components.flatMap(\.pins).map(normalizedNetName)
                + netlist.ports.map(normalizedNetName)
                + netlist.globalNets.map(normalizedNetName)
        )
        var netIDs: [String: LVSObjectID] = [:]
        for netName in netNames.sorted() {
            netIDs[netName] = LVSObjectID(rawValue: "net:\(netName)")
        }

        var devices: [LVSGraphDevice] = []
        for (componentIndex, component) in netlist.components.enumerated() {
            let ignoredParameters = parameterPolicy.ignoredParameters(
                for: component,
                modelEquivalence: modelEquivalence
            )
            var normalizedParameters = component.normalizedComparisonParameters(ignoring: ignoredParameters)
            let multiplicity = component.effectiveMultiplicity
            let replicaCount: Int
            if multiplicity.isFinite,
               multiplicity >= 1,
               multiplicity.rounded() == multiplicity,
               multiplicity <= Double(maximumObjectCount) {
                replicaCount = Int(multiplicity)
                normalizedParameters.removeValue(forKey: "m")
            } else {
                replicaCount = 1
                normalizedParameters["m"] = SPICEValueNormalizer.canonicalize(multiplicity)
            }
            let model = component.normalizedModel(modelEquivalence: modelEquivalence)
            let kind = canonicalKind(
                for: component,
                model: model,
                modelKinds: modelKinds
            )
            let equivalentTerminalGroups = Array(Set(terminalEquivalence.equivalentPinGroups(
                kind: kind,
                model: model,
                pinCount: component.pins.count
            ) + defaultEquivalentTerminalGroups(kind: kind, pinCount: component.pins.count)))
            let parameters = normalizedParameters.map { name, value in
                LVSGraphParameter(
                    name: name,
                    canonicalValue: value,
                    numericValue: SPICEValueNormalizer.numericValue(value),
                    relativeTolerance: parameterPolicy.parameterTolerances(
                        for: component,
                        modelEquivalence: modelEquivalence
                    )[name] ?? 0
                )
            }
            for replicaIndex in 0..<replicaCount {
                let terminals = try component.pins.enumerated().map { pinIndex, pinName in
                    let normalizedPinName = normalizedNetName(pinName)
                    guard let netID = netIDs[normalizedPinName] else {
                        throw LVSError.invalidInput("Component pin references an unknown net.")
                    }
                    return LVSGraphTerminal(index: pinIndex, netID: netID)
                }
                devices.append(LVSGraphDevice(
                    id: LVSObjectID(
                        rawValue: "device:\(componentIndex):\(component.name):\(replicaIndex)"
                    ),
                    sourceName: component.name,
                    kind: kind,
                    model: model,
                    terminals: terminals,
                    equivalentTerminalGroups: equivalentTerminalGroups,
                    parameters: parameters
                ))
            }
        }

        let occurrences = hierarchyOccurrences(in: netlist)
        guard devices.count + netNames.count + occurrences.count <= maximumObjectCount else {
            throw LVSError.resourceLimitExceeded(
                "LVS graph contains \(devices.count + netNames.count + occurrences.count) objects, exceeding \(maximumObjectCount)."
            )
        }
        let nets = netNames.sorted().compactMap { netName -> LVSGraphNet? in
            guard let netID = netIDs[netName] else { return nil }
            return LVSGraphNet(
                id: netID,
                sourceName: netName,
                isGlobal: globalNets.contains(netName)
            )
        }
        let ports = netlist.ports.enumerated().compactMap { position, portName -> LVSGraphPort? in
            let normalized = normalizedNetName(portName)
            guard !globalNets.contains(normalized), let netID = netIDs[normalized] else { return nil }
            return LVSGraphPort(name: normalized, netID: netID, position: position)
        }
        return LVSGraph(
            topCell: netlist.topCell,
            devices: devices,
            nets: nets,
            ports: ports,
            occurrences: occurrences
        )
    }

    private func hierarchyOccurrences(in netlist: NativeLVSNetlist) -> [LVSGraphOccurrence] {
        var paths = Set<String>()
        for component in netlist.components {
            let segments = component.name.split(separator: "/").map(String.init)
            guard segments.count > 1 else { continue }
            for count in 1..<segments.count {
                paths.insert(segments.prefix(count).joined(separator: "/"))
            }
        }
        return paths.sorted().map { path in
            let segments = path.split(separator: "/").map(String.init)
            let parentPath = segments.count > 1
                ? segments.dropLast().joined(separator: "/")
                : nil
            return LVSGraphOccurrence(
                occurrenceID: "spice-occurrence:\(path)",
                parentOccurrenceID: parentPath.map { "spice-occurrence:\($0)" },
                instancePath: path,
                depth: segments.count,
                sourceKind: "spice-subcircuit-instance"
            )
        }
    }

    private func canonicalKind(
        for component: NativeLVSNetlistComponent,
        model: String,
        modelKinds: [String: String]
    ) -> String {
        guard component.kind == "subcircuit",
              let declaredKind = modelKinds[model.lowercased()] else {
            return component.kind
        }
        switch declaredKind.lowercased() {
        case "mos", "mosfet", "nmos", "pmos":
            return "mos"
        default:
            return declaredKind.lowercased()
        }
    }

    private func defaultEquivalentTerminalGroups(kind: String, pinCount: Int) -> [[Int]] {
        kind == "mos" && pinCount == 4 ? [[0, 2]] : []
    }

    private func normalizedNetName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
