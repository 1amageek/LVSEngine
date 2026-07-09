import Foundation
import LVSCore

public struct NativeLVSNetlist: Sendable, Hashable, Codable {
    public let topCell: String
    public let ports: [String]
    public let globalNets: [String]
    public let runtimeCellModels: [String]
    public let components: [NativeLVSNetlistComponent]

    public init(
        topCell: String,
        ports: [String],
        globalNets: [String] = [],
        runtimeCellModels: [String] = [],
        components: [NativeLVSNetlistComponent]
    ) {
        self.topCell = topCell
        self.ports = ports
        self.globalNets = globalNets
        self.runtimeCellModels = runtimeCellModels
        self.components = components
    }

    private enum CodingKeys: String, CodingKey {
        case topCell
        case ports
        case globalNets
        case runtimeCellModels
        case components
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.topCell = try container.decode(String.self, forKey: .topCell)
        self.ports = try container.decode([String].self, forKey: .ports)
        self.globalNets = try container.decodeIfPresent([String].self, forKey: .globalNets) ?? []
        self.runtimeCellModels = try container.decodeIfPresent([String].self, forKey: .runtimeCellModels) ?? []
        self.components = try container.decode([NativeLVSNetlistComponent].self, forKey: .components)
    }
}

public struct NativeLVSNetlistComponent: Sendable, Hashable, Codable {
    public let name: String
    public let kind: String
    public let pins: [String]
    public let model: String
    public let parameters: [String: String]

    public init(
        name: String,
        kind: String,
        pins: [String],
        model: String,
        parameters: [String: String] = [:]
    ) {
        self.name = name
        self.kind = kind
        self.pins = pins
        self.model = model
        self.parameters = parameters
    }

    public var signature: String {
        [
            kind,
            normalizedModel,
            canonicalPins.joined(separator: ","),
            normalizedParameters
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ","),
        ].joined(separator: "|")
    }

    package var comparisonSignature: String {
        [
            kind,
            normalizedModel,
            canonicalPins.joined(separator: ","),
            normalizedComparisonParameters
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ","),
        ].joined(separator: "|")
    }

    package func comparisonSignature(modelEquivalence: [String: String]) -> String {
        [
            kind,
            normalizedModel(modelEquivalence: modelEquivalence),
            canonicalPins.joined(separator: ","),
            normalizedComparisonParameters
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ","),
        ].joined(separator: "|")
    }

    package func comparisonSignature(
        modelEquivalence: [String: String],
        terminalEquivalence: LVSTerminalEquivalenceResolver
    ) -> String {
        comparisonSignature(
            modelEquivalence: modelEquivalence,
            terminalEquivalence: terminalEquivalence,
            ignoringParameters: []
        )
    }

    package func comparisonSignature(
        modelEquivalence: [String: String],
        terminalEquivalence: LVSTerminalEquivalenceResolver,
        ignoringParameters: Set<String>
    ) -> String {
        [
            kind,
            normalizedModel(modelEquivalence: modelEquivalence),
            canonicalPins(
                modelEquivalence: modelEquivalence,
                terminalEquivalence: terminalEquivalence
            ).joined(separator: ","),
            normalizedComparisonParameters(ignoring: ignoringParameters)
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ","),
        ].joined(separator: "|")
    }

    package var topologySignature: String {
        [
            kind,
            canonicalPins.joined(separator: ","),
        ].joined(separator: "|")
    }

    package func topologySignature(
        modelEquivalence: [String: String],
        terminalEquivalence: LVSTerminalEquivalenceResolver
    ) -> String {
        [
            kind,
            canonicalPins(
                modelEquivalence: modelEquivalence,
                terminalEquivalence: terminalEquivalence
            ).joined(separator: ","),
        ].joined(separator: "|")
    }

    package var normalizedModel: String {
        switch kind {
        case "resistor", "capacitor", "inductor":
            return SPICEValueNormalizer.canonicalize(model)
        default:
            return model.lowercased()
        }
    }

    package func normalizedModel(modelEquivalence: [String: String]) -> String {
        let normalized = normalizedModel
        return modelEquivalence[normalized] ?? normalized
    }

    package var normalizedParameters: [String: String] {
        parameters.reduce(into: [:]) { result, entry in
            result[entry.key] = SPICEValueNormalizer.canonicalize(entry.value)
        }
    }

    package var normalizedComparisonParameters: [String: String] {
        normalizedComparisonParameters(ignoring: [])
    }

    package func normalizedComparisonParameters(ignoring ignoredParameters: Set<String>) -> [String: String] {
        var result = normalizedParameters
        if numericMultiplicity != nil {
            result.removeValue(forKey: "m")
        }
        for parameter in ignoredParameters {
            result.removeValue(forKey: parameter.lowercased())
        }
        return result
    }

    package var effectiveMultiplicity: Double {
        numericMultiplicity ?? 1
    }

    package var originalMultiplicityValue: String? {
        parameters["m"]
    }

    func resolving(name: String, pins: [String], parameters: [String: String]) -> NativeLVSNetlistComponent {
        NativeLVSNetlistComponent(
            name: name,
            kind: kind,
            pins: pins,
            model: model,
            parameters: parameters
        )
    }

    private var canonicalPins: [String] {
        switch kind {
        case "mos" where pins.count == 4:
            let sourceDrain = [pins[0], pins[2]].sorted()
            return [sourceDrain[0], pins[1], sourceDrain[1], pins[3]]
        case "resistor", "capacitor", "inductor":
            guard pins.count == 2 else { return pins }
            return pins.sorted()
        default:
            return pins
        }
    }

    private func canonicalPins(
        modelEquivalence: [String: String],
        terminalEquivalence: LVSTerminalEquivalenceResolver
    ) -> [String] {
        var result = pins
        let groups = terminalEquivalence.equivalentPinGroups(
            kind: kind,
            model: normalizedModel(modelEquivalence: modelEquivalence),
            pinCount: pins.count
        )
        for group in groups {
            let sortedPins = group.map { result[$0] }.sorted()
            for (pinIndex, canonicalPin) in zip(group.sorted(), sortedPins) {
                result[pinIndex] = canonicalPin
            }
        }
        return result
    }

    private var numericMultiplicity: Double? {
        guard let value = parameters["m"],
              let parsed = SPICEValueNormalizer.numericValue(value),
              parsed.isFinite,
              parsed > 0 else {
            return nil
        }
        return parsed
    }
}
