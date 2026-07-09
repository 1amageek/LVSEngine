import Foundation
import LVSCore
import LVSNetlistParsing

extension NativeLVSBackend {
    func nonGlobalPorts(_ ports: [String], globalNets: Set<String>) -> [String] {
        ports.filter { !globalNets.contains($0.lowercased()) }
    }

    func compareComponents(
        layout: [NativeLVSNetlistComponent],
        schematic: [NativeLVSNetlistComponent],
        modelEquivalence: [String: String],
        terminalEquivalence: LVSTerminalEquivalenceResolver,
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> [LVSDiagnostic] {
        let diagnostics = compareComponentsByTopology(
            layout: layout,
            schematic: schematic,
            modelEquivalence: modelEquivalence,
            terminalEquivalence: terminalEquivalence,
            parameterPolicy: parameterPolicy
        )
        guard !diagnostics.isEmpty,
              canMatchSeriesReducedComponents(
                layout: layout,
                schematic: schematic,
                modelEquivalence: modelEquivalence,
                terminalEquivalence: terminalEquivalence,
                parameterPolicy: parameterPolicy
              ) else {
            return diagnostics
        }
        return []
    }

    private func compareComponentsByTopology(
        layout: [NativeLVSNetlistComponent],
        schematic: [NativeLVSNetlistComponent],
        modelEquivalence: [String: String],
        terminalEquivalence: LVSTerminalEquivalenceResolver,
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> [LVSDiagnostic] {
        var diagnostics: [LVSDiagnostic] = []
        let layoutByTopology = Dictionary(grouping: layout) {
            $0.topologySignature(
                modelEquivalence: modelEquivalence,
                terminalEquivalence: terminalEquivalence
            )
        }
        let schematicByTopology = Dictionary(grouping: schematic) {
            $0.topologySignature(
                modelEquivalence: modelEquivalence,
                terminalEquivalence: terminalEquivalence
            )
        }
        for topologySignature in Set(layoutByTopology.keys).union(schematicByTopology.keys).sorted() {
            let layoutComponents = layoutByTopology[topologySignature, default: []]
            let schematicComponents = schematicByTopology[topologySignature, default: []]
            if layoutComponents.count == 1, schematicComponents.count == 1 {
                if canMatchParallelComponents(
                    layout: layoutComponents,
                    schematic: schematicComponents,
                    modelEquivalence: modelEquivalence,
                    parameterPolicy: parameterPolicy
                ) {
                    continue
                }
                diagnostics.append(contentsOf: compareMatchedComponents(
                    layout: layoutComponents[0],
                    schematic: schematicComponents[0],
                    topologySignature: topologySignature,
                    modelEquivalence: modelEquivalence,
                    parameterPolicy: parameterPolicy
                ))
            } else if layoutComponents.count == schematicComponents.count,
                      canPairAllComponents(
                        layout: layoutComponents,
                        schematic: schematicComponents,
                        modelEquivalence: modelEquivalence,
                        parameterPolicy: parameterPolicy
                      ) {
                continue
            } else if canMatchParallelComponents(
                layout: layoutComponents,
                schematic: schematicComponents,
                modelEquivalence: modelEquivalence,
                parameterPolicy: parameterPolicy
            ) {
                continue
            } else {
                diagnostics.append(contentsOf: componentCountDiagnostics(
                    layout: layoutComponents,
                    schematic: schematicComponents,
                    modelEquivalence: modelEquivalence,
                    terminalEquivalence: terminalEquivalence,
                    parameterPolicy: parameterPolicy
                ))
            }
        }
        return diagnostics
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

    private func canMatchSeriesReducedComponents(
        layout: [NativeLVSNetlistComponent],
        schematic: [NativeLVSNetlistComponent],
        modelEquivalence: [String: String],
        terminalEquivalence: LVSTerminalEquivalenceResolver,
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> Bool {
        let layoutReduction = seriesReducedComponents(
            components: layout,
            modelEquivalence: modelEquivalence,
            parameterPolicy: parameterPolicy
        )
        let schematicReduction = seriesReducedComponents(
            components: schematic,
            modelEquivalence: modelEquivalence,
            parameterPolicy: parameterPolicy
        )
        guard layoutReduction.changed || schematicReduction.changed else {
            return false
        }
        return compareComponentsByTopology(
            layout: layoutReduction.components,
            schematic: schematicReduction.components,
            modelEquivalence: modelEquivalence,
            terminalEquivalence: terminalEquivalence,
            parameterPolicy: parameterPolicy
        ).isEmpty
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

    private func compareMatchedComponents(
        layout: NativeLVSNetlistComponent,
        schematic: NativeLVSNetlistComponent,
        topologySignature: String,
        modelEquivalence: [String: String],
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> [LVSDiagnostic] {
        let layoutModel = layout.normalizedModel(modelEquivalence: modelEquivalence)
        let schematicModel = schematic.normalizedModel(modelEquivalence: modelEquivalence)
        if layoutModel != schematicModel {
            return [LVSDiagnostic(
                severity: .error,
                message: "Component model differs for \(topologySignature)",
                ruleID: "LVS_MODEL_MISMATCH",
                category: "modelMismatch",
                componentSignature: topologySignature,
                layoutModel: layout.model,
                schematicModel: schematic.model,
                suggestedFix: "Align the schematic and layout device models for this topology.",
                rawLine: "topology=\(topologySignature) layoutModel=\(layout.model) schematicModel=\(schematic.model)",
                layoutComponentName: layout.name,
                schematicComponentName: schematic.name
            )]
        }

        let ignoredParameters = parameterPolicy
            .ignoredParameters(for: layout, modelEquivalence: modelEquivalence)
            .union(parameterPolicy.ignoredParameters(for: schematic, modelEquivalence: modelEquivalence))
        let parameterTolerances = mergedParameterTolerances(
            layout: layout,
            schematic: schematic,
            modelEquivalence: modelEquivalence,
            parameterPolicy: parameterPolicy
        )
        let layoutParameters = layout.normalizedComparisonParameters(ignoring: ignoredParameters)
        let schematicParameters = schematic.normalizedComparisonParameters(ignoring: ignoredParameters)
        let parameterNames = Set(layoutParameters.keys).union(schematicParameters.keys).sorted()
        var diagnostics: [LVSDiagnostic] = parameterNames.compactMap { parameterName in
            let layoutValue = layoutParameters[parameterName]
            let schematicValue = schematicParameters[parameterName]
            guard !parameterValuesMatch(
                layoutValue: layoutValue,
                schematicValue: schematicValue,
                tolerance: parameterTolerances[parameterName]
            ) else {
                return nil
            }
            return LVSDiagnostic(
                severity: .error,
                message: "Component parameter \(parameterName) differs for \(topologySignature)",
                ruleID: "LVS_PARAMETER_MISMATCH",
                category: "parameterMismatch",
                componentSignature: "\(topologySignature)|\(layoutModel)",
                layoutModel: layout.model,
                schematicModel: schematic.model,
                parameterName: parameterName,
                layoutValue: layout.parameters[parameterName],
                schematicValue: schematic.parameters[parameterName],
                suggestedFix: "Align the \(parameterName) parameter for the matching device topology.",
                rawLine: "topology=\(topologySignature) parameter=\(parameterName) layout=\(layoutValue ?? "nil") schematic=\(schematicValue ?? "nil")",
                layoutComponentName: layout.name,
                schematicComponentName: schematic.name
            )
        }
        if !multiplicityMatches(layout.effectiveMultiplicity, schematic.effectiveMultiplicity) {
            diagnostics.append(multiplicityDiagnostic(
                signature: "\(topologySignature)|\(layoutModel)",
                layoutMultiplicity: layout.effectiveMultiplicity,
                schematicMultiplicity: schematic.effectiveMultiplicity,
                layoutValue: layout.originalMultiplicityValue,
                schematicValue: schematic.originalMultiplicityValue,
                layoutComponentName: layout.name,
                schematicComponentName: schematic.name
            ))
        }
        return diagnostics
    }

    private func canPairAllComponents(
        layout: [NativeLVSNetlistComponent],
        schematic: [NativeLVSNetlistComponent],
        modelEquivalence: [String: String],
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> Bool {
        guard layout.count == schematic.count else { return false }
        var matchedSchematicIndexes = Set<Int>()
        return canPairComponents(
            layoutIndex: 0,
            layout: layout,
            schematic: schematic,
            matchedSchematicIndexes: &matchedSchematicIndexes,
            modelEquivalence: modelEquivalence,
            parameterPolicy: parameterPolicy
        )
    }

    private func canPairComponents(
        layoutIndex: Int,
        layout: [NativeLVSNetlistComponent],
        schematic: [NativeLVSNetlistComponent],
        matchedSchematicIndexes: inout Set<Int>,
        modelEquivalence: [String: String],
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> Bool {
        guard layoutIndex < layout.count else { return true }
        for schematicIndex in schematic.indices where !matchedSchematicIndexes.contains(schematicIndex) {
            guard componentsMatch(
                layout: layout[layoutIndex],
                schematic: schematic[schematicIndex],
                modelEquivalence: modelEquivalence,
                parameterPolicy: parameterPolicy
            ) else {
                continue
            }
            matchedSchematicIndexes.insert(schematicIndex)
            if canPairComponents(
                layoutIndex: layoutIndex + 1,
                layout: layout,
                schematic: schematic,
                matchedSchematicIndexes: &matchedSchematicIndexes,
                modelEquivalence: modelEquivalence,
                parameterPolicy: parameterPolicy
            ) {
                return true
            }
            matchedSchematicIndexes.remove(schematicIndex)
        }
        return false
    }

    private func componentsMatch(
        layout: NativeLVSNetlistComponent,
        schematic: NativeLVSNetlistComponent,
        modelEquivalence: [String: String],
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> Bool {
        guard layout.normalizedModel(modelEquivalence: modelEquivalence)
            == schematic.normalizedModel(modelEquivalence: modelEquivalence),
              multiplicityMatches(layout.effectiveMultiplicity, schematic.effectiveMultiplicity) else {
            return false
        }
        let ignoredParameters = parameterPolicy
            .ignoredParameters(for: layout, modelEquivalence: modelEquivalence)
            .union(parameterPolicy.ignoredParameters(for: schematic, modelEquivalence: modelEquivalence))
        let parameterTolerances = mergedParameterTolerances(
            layout: layout,
            schematic: schematic,
            modelEquivalence: modelEquivalence,
            parameterPolicy: parameterPolicy
        )
        let layoutParameters = layout.normalizedComparisonParameters(ignoring: ignoredParameters)
        let schematicParameters = schematic.normalizedComparisonParameters(ignoring: ignoredParameters)
        for parameterName in Set(layoutParameters.keys).union(schematicParameters.keys) {
            guard parameterValuesMatch(
                layoutValue: layoutParameters[parameterName],
                schematicValue: schematicParameters[parameterName],
                tolerance: parameterTolerances[parameterName]
            ) else {
                return false
            }
        }
        return true
    }

    private struct LVSParallelAggregate: Sendable, Hashable {
        let model: String
        let parameters: [String: String]
    }

    private func canMatchParallelComponents(
        layout: [NativeLVSNetlistComponent],
        schematic: [NativeLVSNetlistComponent],
        modelEquivalence: [String: String],
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> Bool {
        guard let layoutAggregate = parallelAggregate(
            components: layout,
            modelEquivalence: modelEquivalence,
            parameterPolicy: parameterPolicy
        ),
              let schematicAggregate = parallelAggregate(
                components: schematic,
                modelEquivalence: modelEquivalence,
                parameterPolicy: parameterPolicy
              ),
              layoutAggregate.model == schematicAggregate.model else {
            return false
        }
        let parameterTolerances = mergedParameterTolerances(
            components: layout + schematic,
            modelEquivalence: modelEquivalence,
            parameterPolicy: parameterPolicy
        )
        for parameterName in Set(layoutAggregate.parameters.keys).union(schematicAggregate.parameters.keys) {
            guard parameterValuesMatch(
                layoutValue: layoutAggregate.parameters[parameterName],
                schematicValue: schematicAggregate.parameters[parameterName],
                tolerance: parameterTolerances[parameterName]
            ) else {
                return false
            }
        }
        return true
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
        layout: NativeLVSNetlistComponent,
        schematic: NativeLVSNetlistComponent,
        modelEquivalence: [String: String],
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> [String: Double] {
        var result = parameterPolicy.parameterTolerances(
            for: layout,
            modelEquivalence: modelEquivalence
        )
        for (parameterName, tolerance) in parameterPolicy.parameterTolerances(
            for: schematic,
            modelEquivalence: modelEquivalence
        ) {
            result[parameterName] = max(result[parameterName] ?? 0, tolerance)
        }
        return result
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

    private func componentCountDiagnostics(
        layout: [NativeLVSNetlistComponent],
        schematic: [NativeLVSNetlistComponent],
        modelEquivalence: [String: String],
        terminalEquivalence: LVSTerminalEquivalenceResolver,
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> [LVSDiagnostic] {
        let layoutCounts = effectiveComponentCounts(
            layout,
            modelEquivalence: modelEquivalence,
            terminalEquivalence: terminalEquivalence,
            parameterPolicy: parameterPolicy
        )
        let schematicCounts = effectiveComponentCounts(
            schematic,
            modelEquivalence: modelEquivalence,
            terminalEquivalence: terminalEquivalence,
            parameterPolicy: parameterPolicy
        )
        return Set(layoutCounts.keys).union(schematicCounts.keys).sorted().compactMap { signature in
            let layoutMultiplicity = layoutCounts[signature, default: 0]
            let schematicMultiplicity = schematicCounts[signature, default: 0]
            guard !multiplicityMatches(layoutMultiplicity, schematicMultiplicity) else {
                return nil
            }
            if layoutMultiplicity > 0, schematicMultiplicity > 0 {
                return multiplicityDiagnostic(
                    signature: signature,
                    layoutMultiplicity: layoutMultiplicity,
                    schematicMultiplicity: schematicMultiplicity,
                    layoutValue: nil,
                    schematicValue: nil
                )
            }
            return LVSDiagnostic(
                severity: .error,
                message: "Component signature count differs for \(signature)",
                ruleID: "LVS_COMPONENT_MISMATCH",
                category: "componentCountMismatch",
                componentSignature: signature,
                layoutCount: integerCountIfWhole(layoutMultiplicity),
                schematicCount: integerCountIfWhole(schematicMultiplicity),
                suggestedFix: "Compare the devices and parameters represented by this signature in the layout and schematic netlists.",
                rawLine: "signature=\(signature) layout=\(formatMultiplicity(layoutMultiplicity)) schematic=\(formatMultiplicity(schematicMultiplicity))"
            )
        }
    }

    private func effectiveComponentCounts(
        _ components: [NativeLVSNetlistComponent],
        modelEquivalence: [String: String],
        terminalEquivalence: LVSTerminalEquivalenceResolver,
        parameterPolicy: LVSParameterComparisonPolicy
    ) -> [String: Double] {
        components.reduce(into: [:]) { counts, component in
            counts[component.comparisonSignature(
                modelEquivalence: modelEquivalence,
                terminalEquivalence: terminalEquivalence,
                ignoringParameters: parameterPolicy.ignoredParameters(
                    for: component,
                    modelEquivalence: modelEquivalence
                )
            ), default: 0] += component.effectiveMultiplicity
        }
    }

    private func multiplicityDiagnostic(
        signature: String,
        layoutMultiplicity: Double,
        schematicMultiplicity: Double,
        layoutValue: String?,
        schematicValue: String?,
        layoutComponentName: String? = nil,
        schematicComponentName: String? = nil
    ) -> LVSDiagnostic {
        LVSDiagnostic(
            severity: .error,
            message: "Component effective multiplicity differs for \(signature)",
            ruleID: "LVS_MULTIPLICITY_MISMATCH",
            category: "multiplicityMismatch",
            componentSignature: signature,
            layoutCount: integerCountIfWhole(layoutMultiplicity),
            schematicCount: integerCountIfWhole(schematicMultiplicity),
            parameterName: "m",
            layoutValue: layoutValue ?? formatMultiplicity(layoutMultiplicity),
            schematicValue: schematicValue ?? formatMultiplicity(schematicMultiplicity),
            suggestedFix: "Align the device multiplicity or the number of parallel devices for this topology.",
            rawLine: "signature=\(signature) layoutMultiplicity=\(formatMultiplicity(layoutMultiplicity)) schematicMultiplicity=\(formatMultiplicity(schematicMultiplicity))",
            layoutComponentName: layoutComponentName,
            schematicComponentName: schematicComponentName
        )
    }

    private func multiplicityMatches(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= max(1e-12, max(abs(lhs), abs(rhs)) * 1e-12)
    }

    private func integerCountIfWhole(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded()
        guard abs(value - rounded) <= 1e-12 else { return nil }
        return Int(rounded)
    }

    private func formatMultiplicity(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        let rounded = value.rounded()
        if abs(value - rounded) <= 1e-12 {
            return String(Int(rounded))
        }
        return String(format: "%.12e", value)
    }
}
