import LayoutLVSExtraction
import LVSCore
import LVSGraph
import LVSNetlistParsing

public struct LayoutExtractionLVSGraphBuilder: Sendable {
    public init() {}

    public func build(
        from extraction: LayoutExtractionIR,
        maximumObjectCount: Int,
        sharedGlobalNetNames: Set<String> = []
    ) throws -> LVSGraph {
        guard extraction.schemaVersion == LayoutExtractionIR.currentSchemaVersion else {
            throw LVSError.invalidInput("Unsupported layout extraction schema version.")
        }
        guard extraction.isReady else {
            throw LVSError.invalidInput("Layout extraction contains blocking issues.")
        }
        let occurrences = extraction.occurrences.compactMap { occurrence -> LVSGraphOccurrence? in
            let instancePath = relativeInstancePath(
                for: occurrence,
                topCell: extraction.topCell
            )
            guard !instancePath.isEmpty else { return nil }
            let parentPath = instancePath.dropLast()
            let path = instancePath.joined(separator: "/")
            return LVSGraphOccurrence(
                occurrenceID: "layout-occurrence:\(path)",
                parentOccurrenceID: parentPath.isEmpty
                    ? nil
                    : "layout-occurrence:\(parentPath.joined(separator: "/"))",
                instancePath: path,
                depth: instancePath.count,
                sourceKind: "layout-cell-instance"
            )
        }
        guard extraction.devices.count + extraction.nets.count + occurrences.count <= maximumObjectCount else {
            throw LVSError.resourceLimitExceeded(
                "Layout extraction graph contains \(extraction.devices.count + extraction.nets.count + occurrences.count) objects, exceeding \(maximumObjectCount)."
            )
        }

        let netIDs = Dictionary(uniqueKeysWithValues: extraction.nets.map {
            ($0.id, LVSObjectID(rawValue: "layout:\($0.id.rawValue)"))
        })
        let nets = extraction.nets.map { net in
            LVSGraphNet(
                id: netIDs[net.id]!,
                sourceName: net.preferredName ?? net.id.rawValue,
                isGlobal: net.isGlobal
                    || net.preferredName.map { sharedGlobalNetNames.contains($0.lowercased()) } == true
            )
        }
        let devices = try extraction.devices.map { device in
            let terminals = try device.terminals.map { terminal -> LVSGraphTerminal in
                guard let netID = netIDs[terminal.netID] else {
                    throw LVSError.invalidInput(
                        "Layout extraction device \(device.id.rawValue) references an unknown net."
                    )
                }
                return LVSGraphTerminal(
                    index: terminal.index,
                    role: terminal.role,
                    netID: netID
                )
            }
            return LVSGraphDevice(
                id: LVSObjectID(rawValue: "layout:\(device.id.rawValue)"),
                sourceName: device.id.rawValue,
                kind: canonicalKind(for: device.family),
                model: device.model.lowercased(),
                terminals: terminals,
                equivalentTerminalGroups: equivalentTerminalGroups(for: device),
                parameters: graphParameters(
                    for: device,
                    convention: extraction.parameterValueConvention
                )
            )
        }
        let ports = try extraction.ports.map { port -> LVSGraphPort in
            guard let netID = netIDs[port.netID] else {
                throw LVSError.invalidInput(
                    "Layout extraction port \(port.name) references an unknown net."
                )
            }
            return LVSGraphPort(
                name: port.name.lowercased(),
                netID: netID,
                position: port.position
            )
        }
        return LVSGraph(
            topCell: extraction.topCell,
            devices: devices,
            nets: nets,
            ports: ports,
            occurrences: occurrences
        )
    }

    private func graphParameters(
        for device: LayoutExtractionDevice,
        convention: LayoutExtractionParameterValueConvention
    ) -> [LVSGraphParameter] {
        if !device.typedParameters.isEmpty {
            return device.typedParameters.map { parameter in
                let value = graphValue(
                    parameter,
                    convention: convention
                )
                let canonicalValue = SPICEValueNormalizer.canonicalize(value)
                return LVSGraphParameter(
                    name: parameter.name.lowercased(),
                    canonicalValue: canonicalValue,
                    numericValue: SPICEValueNormalizer.numericValue(canonicalValue)
                )
            }
        }
        return device.parameters.map { name, value in
            let canonicalValue = SPICEValueNormalizer.canonicalize(value)
            return LVSGraphParameter(
                name: name.lowercased(),
                canonicalValue: canonicalValue,
                numericValue: SPICEValueNormalizer.numericValue(canonicalValue)
            )
        }
    }

    private func graphValue(
        _ parameter: LayoutExtractionTypedParameter,
        convention: LayoutExtractionParameterValueConvention
    ) -> String {
        guard parameter.unit == "um" else { return parameter.canonicalValue }
        switch convention {
        case .spiceSI:
            return "\(parameter.canonicalValue)u"
        case .micronScalar:
            return parameter.canonicalValue
        }
    }

    private func canonicalKind(for family: String) -> String {
        switch family.lowercased() {
        case "mosfet", "nmos", "pmos":
            return "mos"
        default:
            return family.lowercased()
        }
    }

    private func equivalentTerminalGroups(
        for device: LayoutExtractionDevice
    ) -> [[Int]] {
        guard canonicalKind(for: device.family) == "mos" else { return [] }
        let sourceDrain = device.terminals.filter {
            $0.role == "source" || $0.role == "drain"
        }.map(\.index)
        return sourceDrain.count == 2 ? [sourceDrain] : []
    }

    private func relativeInstancePath(
        for occurrence: LayoutExtractionOccurrence,
        topCell: String
    ) -> [String] {
        var hierarchyPath = occurrence.hierarchyPath
        if hierarchyPath.first == topCell {
            hierarchyPath.removeFirst()
        }
        guard !hierarchyPath.isEmpty else { return [] }

        // Geometry extraction records alternating instance and child-cell names.
        // The canonical graph retains only instance occurrences so depth has the
        // same meaning as a flattened SPICE component path.
        if hierarchyPath.last == occurrence.cellName,
           hierarchyPath.count.isMultiple(of: 2) {
            return hierarchyPath.enumerated().compactMap { index, segment in
                index.isMultiple(of: 2) ? segment : nil
            }
        }
        return hierarchyPath
    }
}
