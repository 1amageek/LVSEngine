import LVSCore

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

    package func normalizedComparisonParameters(
        ignoring ignoredParameters: Set<String>
    ) -> [String: String] {
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

    func resolving(
        name: String,
        pins: [String],
        parameters: [String: String]
    ) -> NativeLVSNetlistComponent {
        NativeLVSNetlistComponent(
            name: name,
            kind: kind,
            pins: pins,
            model: model,
            parameters: parameters
        )
    }

    package func canonicalPins(
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
