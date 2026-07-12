import Foundation
import LVSCore
import LVSNetlistParsing

extension NativeLVSBackend {
    func canonicalizedComponentsForGraph(
        _ components: [NativeLVSNetlistComponent],
        modelEquivalence: [String: String],
        terminalEquivalence: LVSTerminalEquivalenceResolver,
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> [NativeLVSNetlistComponent] {
        let seriesReduction = seriesReducedComponents(
            components: components,
            modelEquivalence: modelEquivalence,
            parameterPolicy: parameterPolicy
        )
        return parallelReducedComponents(
            components: seriesReduction.components,
            modelEquivalence: modelEquivalence,
            terminalEquivalence: terminalEquivalence,
            parameterPolicy: parameterPolicy
        )
    }

    func nonGlobalPorts(_ ports: [String], globalNets: Set<String>) -> [String] {
        ports.filter { !globalNets.contains($0.lowercased()) }
    }

    private struct LVSSeriesReductionResult: Sendable, Hashable {
        let components: [NativeLVSNetlistComponent]
        let changed: Bool
    }

    private struct LVSSeriesGroupKey: Sendable, Hashable {
        let kind: String
        let model: String
        let fixedPins: [String]
        let additiveParameters: [String]
    }

    private func seriesReducedComponents(
        components: [NativeLVSNetlistComponent],
        modelEquivalence: [String: String],
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> LVSSeriesReductionResult {
        var candidatesByKey: [LVSSeriesGroupKey: [Int]] = [:]
        for (index, component) in components.enumerated() {
            guard let key = seriesGroupKey(
                for: component,
                modelEquivalence: modelEquivalence,
                parameterPolicy: parameterPolicy
            ) else {
                continue
            }
            candidatesByKey[key, default: []].append(index)
        }

        let pinUseCounts = allPinUseCounts(components)
        var consumedIndexes = Set<Int>()
        var aggregates: [NativeLVSNetlistComponent] = []

        for indexes in candidatesByKey.values {
            let connectedIndexGroups = seriesConnectedIndexGroups(indexes: indexes, components: components)
            for connectedIndexes in connectedIndexGroups where connectedIndexes.count >= 2 {
                guard !connectedIndexes.contains(where: consumedIndexes.contains),
                      let aggregate = seriesAggregate(
                        indexes: connectedIndexes,
                        components: components,
                        modelEquivalence: modelEquivalence,
                        parameterPolicy: parameterPolicy,
                        pinUseCounts: pinUseCounts
                      ) else {
                    continue
                }
                consumedIndexes.formUnion(connectedIndexes)
                aggregates.append(aggregate)
            }
        }

        guard !consumedIndexes.isEmpty else {
            return LVSSeriesReductionResult(components: components, changed: false)
        }
        let remaining = components.enumerated()
            .filter { !consumedIndexes.contains($0.offset) }
            .map(\.element)
        return LVSSeriesReductionResult(
            components: remaining + aggregates.sorted { $0.name < $1.name },
            changed: true
        )
    }

    private func seriesGroupKey(
        for component: NativeLVSNetlistComponent,
        modelEquivalence: [String: String],
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> LVSSeriesGroupKey? {
        let seriesPolicy = parameterPolicy.seriesPolicy(
            for: component,
            modelEquivalence: modelEquivalence
        )
        guard seriesPolicy.enabled,
              !seriesPolicy.additiveParameters.isEmpty,
              seriesEndpointPins(for: component) != nil,
              let fixedPins = seriesFixedPins(for: component) else {
            return nil
        }
        return LVSSeriesGroupKey(
            kind: component.kind,
            model: component.normalizedModel(modelEquivalence: modelEquivalence),
            fixedPins: fixedPins.map(normalizedNetName),
            additiveParameters: seriesPolicy.additiveParameters.sorted()
        )
    }

    private func seriesConnectedIndexGroups(
        indexes: [Int],
        components: [NativeLVSNetlistComponent]
    ) -> [[Int]] {
        let indexSet = Set(indexes)
        var indexesByEndpoint: [String: Set<Int>] = [:]
        for index in indexes {
            guard let endpoints = seriesEndpointPins(for: components[index]) else {
                continue
            }
            for endpoint in endpoints.map(normalizedNetName) {
                indexesByEndpoint[endpoint, default: []].insert(index)
            }
        }

        var visited = Set<Int>()
        var groups: [[Int]] = []
        for index in indexes where !visited.contains(index) {
            var stack = [index]
            var group: [Int] = []
            visited.insert(index)
            while let current = stack.popLast() {
                group.append(current)
                guard let endpoints = seriesEndpointPins(for: components[current]) else {
                    continue
                }
                let neighbors = endpoints
                    .map(normalizedNetName)
                    .flatMap { indexesByEndpoint[$0, default: []] }
                for neighbor in neighbors where indexSet.contains(neighbor) && !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    stack.append(neighbor)
                }
            }
            groups.append(group.sorted())
        }
        return groups
    }

    private func seriesAggregate(
        indexes: [Int],
        components: [NativeLVSNetlistComponent],
        modelEquivalence: [String: String],
        parameterPolicy: LVSParameterComparisonPolicy,
        pinUseCounts: [String: Int]
    ) -> NativeLVSNetlistComponent? {
        guard let firstIndex = indexes.first else {
            return nil
        }
        let first = components[firstIndex]
        let seriesPolicy = parameterPolicy.seriesPolicy(
            for: first,
            modelEquivalence: modelEquivalence
        )
        guard seriesPolicy.enabled,
              !seriesPolicy.additiveParameters.isEmpty,
              let firstFixedPins = seriesFixedPins(for: first),
              let externalEndpoints = seriesExternalEndpoints(
                indexes: indexes,
                components: components,
                pinUseCounts: pinUseCounts
              ) else {
            return nil
        }

        let ignoredParameters = parameterPolicy.ignoredParameters(
            for: first,
            modelEquivalence: modelEquivalence
        )
        let parameterTolerances = mergedParameterTolerances(
            components: indexes.map { components[$0] },
            modelEquivalence: modelEquivalence,
            parameterPolicy: parameterPolicy
        )
        var aggregateParameters = first.normalizedParameters
        for parameter in ignoredParameters {
            aggregateParameters.removeValue(forKey: parameter.lowercased())
        }
        var additiveValues = Dictionary(uniqueKeysWithValues: seriesPolicy.additiveParameters.map { ($0, 0.0) })
        let referenceMultiplicity = first.effectiveMultiplicity
        let referenceFixedPins = firstFixedPins.map(normalizedNetName)
        let referenceModel = first.normalizedModel(modelEquivalence: modelEquivalence)

        for index in indexes {
            let component = components[index]
            guard component.kind == first.kind,
                  component.normalizedModel(modelEquivalence: modelEquivalence) == referenceModel,
                  multiplicityMatches(component.effectiveMultiplicity, referenceMultiplicity),
                  seriesFixedPins(for: component)?.map(normalizedNetName) == referenceFixedPins else {
                return nil
            }
            let componentPolicy = parameterPolicy.seriesPolicy(
                for: component,
                modelEquivalence: modelEquivalence
            )
            guard componentPolicy.enabled,
                  componentPolicy.additiveParameters == seriesPolicy.additiveParameters else {
                return nil
            }
            let componentIgnoredParameters = parameterPolicy.ignoredParameters(
                for: component,
                modelEquivalence: modelEquivalence
            )
            var componentParameters = component.normalizedComparisonParameters(ignoring: componentIgnoredParameters)
            componentParameters.removeValue(forKey: "m")

            for parameterName in Set(aggregateParameters.keys).union(componentParameters.keys) {
                if seriesPolicy.additiveParameters.contains(parameterName) || parameterName == "m" {
                    continue
                }
                guard parameterValuesMatch(
                    layoutValue: aggregateParameters[parameterName],
                    schematicValue: componentParameters[parameterName],
                    tolerance: parameterTolerances[parameterName]
                ) else {
                    return nil
                }
            }

            for parameterName in seriesPolicy.additiveParameters {
                guard let value = componentParameters[parameterName],
                      let numericValue = SPICEValueNormalizer.numericValue(value) else {
                    return nil
                }
                additiveValues[parameterName, default: 0] += numericValue
            }
        }

        for parameterName in seriesPolicy.additiveParameters {
            aggregateParameters[parameterName] = SPICEValueNormalizer.canonicalize(additiveValues[parameterName, default: 0])
        }
        if multiplicityMatches(referenceMultiplicity, 1) {
            aggregateParameters.removeValue(forKey: "m")
        } else {
            aggregateParameters["m"] = SPICEValueNormalizer.canonicalize(referenceMultiplicity)
        }

        return NativeLVSNetlistComponent(
            name: indexes.map { components[$0].name }.sorted().joined(separator: "+"),
            kind: first.kind,
            pins: seriesAggregatePins(
                kind: first.kind,
                externalEndpoints: externalEndpoints,
                fixedPins: firstFixedPins
            ),
            model: first.model,
            parameters: aggregateParameters
        )
    }

    private func seriesExternalEndpoints(
        indexes: [Int],
        components: [NativeLVSNetlistComponent],
        pinUseCounts: [String: Int]
    ) -> [String]? {
        var localEndpointCounts: [String: Int] = [:]
        var representativeEndpointNames: [String: String] = [:]
        for index in indexes {
            guard let endpoints = seriesEndpointPins(for: components[index]) else {
                return nil
            }
            for endpoint in endpoints {
                let normalized = normalizedNetName(endpoint)
                localEndpointCounts[normalized, default: 0] += 1
                representativeEndpointNames[normalized] = endpoint
            }
        }

        let externalEndpoints = localEndpointCounts
            .filter { $0.value == 1 }
            .map(\.key)
            .sorted()
        guard externalEndpoints.count == 2 else {
            return nil
        }
        for (net, localCount) in localEndpointCounts {
            if externalEndpoints.contains(net) {
                continue
            }
            guard localCount == 2,
                  pinUseCounts[net, default: 0] == 2 else {
                return nil
            }
        }
        return externalEndpoints.compactMap { representativeEndpointNames[$0] }
    }

    private func seriesEndpointPins(for component: NativeLVSNetlistComponent) -> [String]? {
        switch component.kind {
        case "mos" where component.pins.count == 4:
            return [component.pins[0], component.pins[2]]
        case "resistor", "inductor":
            guard component.pins.count == 2 else { return nil }
            return component.pins
        default:
            return nil
        }
    }

    private func seriesFixedPins(for component: NativeLVSNetlistComponent) -> [String]? {
        switch component.kind {
        case "mos" where component.pins.count == 4:
            return [component.pins[1], component.pins[3]]
        case "resistor", "inductor":
            guard component.pins.count == 2 else { return nil }
            return []
        default:
            return nil
        }
    }

    private func seriesAggregatePins(
        kind: String,
        externalEndpoints: [String],
        fixedPins: [String]
    ) -> [String] {
        switch kind {
        case "mos" where fixedPins.count == 2:
            return [externalEndpoints[0], fixedPins[0], externalEndpoints[1], fixedPins[1]]
        default:
            return externalEndpoints
        }
    }

    private func allPinUseCounts(_ components: [NativeLVSNetlistComponent]) -> [String: Int] {
        components.reduce(into: [:]) { counts, component in
            for pin in component.pins.map(normalizedNetName) {
                counts[pin, default: 0] += 1
            }
        }
    }

    private func normalizedNetName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct LVSParallelAggregate: Sendable, Hashable {
        let model: String
        let parameters: [String: String]
    }

    private func parallelReducedComponents(
        components: [NativeLVSNetlistComponent],
        modelEquivalence: [String: String],
        terminalEquivalence: LVSTerminalEquivalenceResolver,
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> [NativeLVSNetlistComponent] {
        let groups = Dictionary(grouping: components) {
            localConnectivityKey(
                for: $0,
                modelEquivalence: modelEquivalence,
                terminalEquivalence: terminalEquivalence
            )
        }
        return groups.keys.sorted().flatMap { signature in
            let group = groups[signature, default: []].sorted { $0.name < $1.name }
            guard let first = group.first,
                  let aggregate = parallelAggregate(
                    components: group,
                    modelEquivalence: modelEquivalence,
                    parameterPolicy: parameterPolicy
                  ) else {
                return group
            }
            return [NativeLVSNetlistComponent(
                name: group.map(\.name).joined(separator: "+"),
                kind: first.kind,
                pins: first.pins,
                model: first.model,
                parameters: aggregate.parameters
            )]
        }
    }

    private func localConnectivityKey(
        for component: NativeLVSNetlistComponent,
        modelEquivalence: [String: String],
        terminalEquivalence: LVSTerminalEquivalenceResolver
    ) -> String {
        [
            component.kind,
            component.canonicalPins(
                modelEquivalence: modelEquivalence,
                terminalEquivalence: terminalEquivalence
            ).joined(separator: ","),
        ].joined(separator: "|")
    }

    private func parallelAggregate(
        components: [NativeLVSNetlistComponent],
        modelEquivalence: [String: String],
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> LVSParallelAggregate? {
        guard let first = components.first else {
            return nil
        }
        let model = first.normalizedModel(modelEquivalence: modelEquivalence)
        let parallelPolicy = parameterPolicy.parallelPolicy(
            for: first,
            modelEquivalence: modelEquivalence
        )
        guard parallelPolicy.enabled,
              !parallelPolicy.additiveParameters.isEmpty else {
            return nil
        }
        let ignoredParameters = parameterPolicy.ignoredParameters(for: first, modelEquivalence: modelEquivalence)
        let parameterTolerances = mergedParameterTolerances(
            components: components,
            modelEquivalence: modelEquivalence,
            parameterPolicy: parameterPolicy
        )
        var aggregateParameters = first.normalizedComparisonParameters(ignoring: ignoredParameters)
        var additiveValues = Dictionary(uniqueKeysWithValues: parallelPolicy.additiveParameters.map { ($0, 0.0) })

        for component in components {
            guard component.normalizedModel(modelEquivalence: modelEquivalence) == model else {
                return nil
            }
            let componentParallelPolicy = parameterPolicy.parallelPolicy(
                for: component,
                modelEquivalence: modelEquivalence
            )
            guard componentParallelPolicy.enabled,
                  componentParallelPolicy.additiveParameters == parallelPolicy.additiveParameters else {
                return nil
            }
            let componentIgnoredParameters = parameterPolicy.ignoredParameters(
                for: component,
                modelEquivalence: modelEquivalence
            )
            let componentParameters = component.normalizedComparisonParameters(ignoring: componentIgnoredParameters)

            for parameterName in Set(aggregateParameters.keys).union(componentParameters.keys) {
                if parallelPolicy.additiveParameters.contains(parameterName) {
                    continue
                }
                guard parameterValuesMatch(
                    layoutValue: aggregateParameters[parameterName],
                    schematicValue: componentParameters[parameterName],
                    tolerance: parameterTolerances[parameterName]
                ) else {
                    return nil
                }
            }

            for parameterName in parallelPolicy.additiveParameters {
                guard let value = componentParameters[parameterName],
                      let numericValue = SPICEValueNormalizer.numericValue(value) else {
                    return nil
                }
                additiveValues[parameterName, default: 0] += numericValue * component.effectiveMultiplicity
            }
        }

        for parameterName in parallelPolicy.additiveParameters {
            aggregateParameters[parameterName] = SPICEValueNormalizer.canonicalize(additiveValues[parameterName, default: 0])
        }
        return LVSParallelAggregate(model: model, parameters: aggregateParameters)
    }

    private func mergedParameterTolerances(
        components: [NativeLVSNetlistComponent],
        modelEquivalence: [String: String],
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> [String: Double] {
        var result: [String: Double] = [:]
        for component in components {
            for (parameterName, tolerance) in parameterPolicy.parameterTolerances(
                for: component,
                modelEquivalence: modelEquivalence
            ) {
                result[parameterName] = max(result[parameterName] ?? 0, tolerance)
            }
        }
        return result
    }

    private func parameterValuesMatch(
        layoutValue: String?,
        schematicValue: String?,
        tolerance: Double?
    ) -> Bool {
        if layoutValue == schematicValue {
            return true
        }
        guard let layoutValue,
              let schematicValue,
              let tolerance,
              let layoutNumericValue = SPICEValueNormalizer.numericValue(layoutValue),
              let schematicNumericValue = SPICEValueNormalizer.numericValue(schematicValue) else {
            return false
        }
        let scale = max(abs(layoutNumericValue), abs(schematicNumericValue))
        guard scale > 0 else {
            return layoutNumericValue == schematicNumericValue
        }
        return abs(layoutNumericValue - schematicNumericValue) / scale <= tolerance
    }

    private func multiplicityMatches(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= max(1e-12, max(abs(lhs), abs(rhs)) * 1e-12)
    }

}
