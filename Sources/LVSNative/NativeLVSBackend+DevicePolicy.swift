import Foundation
import LVSCore
import LVSNetlistParsing

extension NativeLVSBackend {
    struct LoadedDevicePolicy: Sendable, Hashable {
        let terminalPolicy: LVSTerminalEquivalencePolicy?
        let modelEquivalence: [String: String]
        let parameterPolicy: LVSParameterComparisonPolicy
        let ignoredLayoutModels: Set<String>
        let ignoredSchematicModels: Set<String>
        let report: LVSDevicePolicyApplicationReport?
        let diagnostics: [LVSDiagnostic]
    }

    private struct EquatePinDevicePair: Sendable, Hashable {
        let circuit1: NetgenLVSDeviceDescriptor
        let circuit2: NetgenLVSDeviceDescriptor
    }

    private struct CircuitModelPair: Sendable, Hashable {
        let circuit1Model: String
        let circuit2Model: String
    }

    private struct CircuitModelTarget: Sendable, Hashable {
        let circuit: Int
        let model: String
    }

    private struct RuntimePolicyResolution: Sendable, Hashable {
        let rules: [NetgenLVSPolicyRule]
        let failureReason: String?
    }

    func loadDevicePolicySeed(from url: URL?) throws -> NetgenLVSDevicePolicySeed? {
        guard let url else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(NetgenLVSDevicePolicySeed.self, from: data)
        } catch let error as LVSError {
            throw error
        } catch {
            throw LVSError.invalidInput("Could not load LVS device policy seed: \(error.localizedDescription)")
        }
    }

    func loadDevicePolicy(
        seed: NetgenLVSDevicePolicySeed?,
        policyURL: URL?,
        layout: NativeLVSNetlist,
        schematic: NativeLVSNetlist
    ) throws -> LoadedDevicePolicy {
        guard let seed, let policyURL else {
            return LoadedDevicePolicy(
                terminalPolicy: nil,
                modelEquivalence: [:],
                parameterPolicy: .empty,
                ignoredLayoutModels: [],
                ignoredSchematicModels: [],
                report: nil,
                diagnostics: []
            )
        }
        return makeDevicePolicy(
            seed: seed,
            policyURL: policyURL,
            layout: layout,
            schematic: schematic
        )
    }

    private func makeDevicePolicy(
        seed: NetgenLVSDevicePolicySeed,
        policyURL: URL,
        layout: NativeLVSNetlist,
        schematic: NativeLVSNetlist
    ) -> LoadedDevicePolicy {
        let devicesByName = seed.devices.reduce(into: [String: NetgenLVSDeviceDescriptor]()) { result, device in
            result[normalizedPolicyName(device.deviceName)] = device
        }
        let observedModels = Set((layout.components + schematic.components).map {
            normalizedPolicyName($0.normalizedModel)
        })
        let layoutObservedModels = Set(layout.components.map {
            normalizedPolicyName($0.normalizedModel)
        }).union(layout.runtimeCellModels.map(normalizedPolicyName))
        let schematicObservedModels = Set(schematic.components.map {
            normalizedPolicyName($0.normalizedModel)
        }).union(schematic.runtimeCellModels.map(normalizedPolicyName))
        let layoutRuntimeCellModels = Set(layout.runtimeCellModels.map(normalizedPolicyName))
        let schematicRuntimeCellModels = Set(schematic.runtimeCellModels.map(normalizedPolicyName))
        let runtimeCellModels = Set((layout.runtimeCellModels + schematic.runtimeCellModels).map(normalizedPolicyName))
        let observedPolicyModels = observedModels.union(runtimeCellModels)
        let observedDevices = seed.devices.filter { observedModels.contains(normalizedPolicyName($0.deviceName)) }
        var terminalRules: [LVSTerminalEquivalenceRule] = []
        var modelEquivalenceByModel: [String: String] = [:]
        var ignoredParametersByModel: [String: Set<String>] = [:]
        var parameterTolerancesByModel: [String: [String: Double]] = [:]
        var parallelPolicyByModel: [String: LVSParallelComparisonPolicy] = [:]
        var seriesPolicyByModel: [String: LVSSeriesComparisonPolicy] = [:]
        var blackboxedModels: Set<String> = []
        var ignoredLayoutModels: Set<String> = []
        var ignoredSchematicModels: Set<String> = []
        var appliedRules: [LVSDevicePolicyAppliedRule] = []
        var ignoredRules: [LVSDevicePolicyIgnoredRule] = []
        var unobservedRules: [LVSDevicePolicyUnobservedRule] = []

        for sourceRule in seed.policyRules {
            let resolution = resolveRuntimePolicyRule(
                sourceRule,
                layoutRuntimeCellModels: layoutRuntimeCellModels,
                schematicRuntimeCellModels: schematicRuntimeCellModels
            )
            if let failureReason = resolution.failureReason {
                ignoredRules.append(ignoredPolicyRule(
                    sourceRule,
                    reasonCode: "invalid-runtime-selector",
                    message: failureReason
                ))
                continue
            }
            guard !resolution.rules.isEmpty else {
                unobservedRules.append(unobservedPolicyRule(
                    sourceRule,
                    reasonCode: "runtime-selector-target-not-observed",
                    message: "The Netgen runtime selector matched no compared subcircuit model.",
                    targetModels: []
                ))
                continue
            }
            for rule in resolution.rules {
            if rule.kind == "permute", isPermuteDefault(rule.arguments) {
                appliedRules.append(LVSDevicePolicyAppliedRule(
                    kind: "permute-default",
                    model: nil,
                    family: nil,
                    propertyMode: "native-default",
                    sourceLineNumber: rule.sourceLineNumber,
                    sourceLine: rule.sourceLine
                ))
                continue
            }
            if rule.kind == "property", let globalMode = globalPropertyMode(rule.arguments) {
                appliedRules.append(LVSDevicePolicyAppliedRule(
                    kind: "property-default",
                    model: nil,
                    family: nil,
                    propertyMode: globalMode,
                    sourceLineNumber: rule.sourceLineNumber,
                    sourceLine: rule.sourceLine
                ))
                continue
            }
            if rule.kind == "ignore-class" {
                let targets = circuitModelTargets(in: rule.arguments)
                guard !targets.isEmpty else {
                    ignoredRules.append(ignoredPolicyRule(
                        rule,
                        reasonCode: "unsupported-ignore-class-arguments",
                        message: "Netgen ignore class policy did not contain a circuit-scoped model selector."
                    ))
                    continue
                }
                var observedTargetCount = 0
                var unobservedTargets: [String] = []
                for target in targets {
                    let normalizedModel = normalizedPolicyName(target.model)
                    switch target.circuit {
                    case 1 where layoutObservedModels.contains(normalizedModel):
                        ignoredLayoutModels.insert(normalizedModel)
                        observedTargetCount += 1
                    case 2 where schematicObservedModels.contains(normalizedModel):
                        ignoredSchematicModels.insert(normalizedModel)
                        observedTargetCount += 1
                    default:
                        unobservedTargets.append(normalizedModel)
                        continue
                    }
                    appliedRules.append(LVSDevicePolicyAppliedRule(
                        kind: "ignore-class",
                        model: normalizedModel,
                        family: "cell",
                        propertyMode: "circuit\(target.circuit)",
                        sourceLineNumber: rule.sourceLineNumber,
                        sourceLine: rule.sourceLine
                    ))
                }
                if !unobservedTargets.isEmpty {
                    unobservedRules.append(unobservedPolicyRule(
                        rule,
                        reasonCode: "selector-target-not-observed",
                        message: "Netgen ignore class policy resolved to model(s) not observed on the selected circuit side.",
                        targetModels: unobservedTargets
                    ))
                }
                if observedTargetCount == 0 { continue }
                continue
            }

            if rule.kind == "equate" {
                guard let pair = circuitModelPair(in: rule.arguments, command: "classes") else {
                    ignoredRules.append(ignoredPolicyRule(
                        rule,
                        reasonCode: "unsupported-equate-classes-arguments",
                        message: "Netgen equate classes policy did not contain concrete circuit1 and circuit2 model selectors."
                    ))
                    continue
                }
                guard layoutObservedModels.contains(pair.circuit1Model),
                      schematicObservedModels.contains(pair.circuit2Model) else {
                    unobservedRules.append(unobservedPolicyRule(
                        rule,
                        reasonCode: "selector-target-not-observed",
                        message: "Netgen equate classes policy resolved to a pair not observed on both circuit sides.",
                        targetModels: [pair.circuit1Model, pair.circuit2Model]
                    ))
                    continue
                }
                guard mergeModelEquivalenceAlias(
                    alias: pair.circuit1Model,
                    canonical: pair.circuit1Model,
                    into: &modelEquivalenceByModel
                ), mergeModelEquivalenceAlias(
                    alias: pair.circuit2Model,
                    canonical: pair.circuit1Model,
                    into: &modelEquivalenceByModel
                ) else {
                    ignoredRules.append(ignoredPolicyRule(
                        rule,
                        reasonCode: "conflicting-equate-classes-model-equivalence",
                        message: "Netgen equate classes policy conflicts with another model-equivalence rule."
                    ))
                    continue
                }
                appliedRules.append(LVSDevicePolicyAppliedRule(
                    kind: "equate-classes",
                    model: pair.circuit1Model,
                    pairedModel: pair.circuit2Model,
                    family: "cell",
                    propertyMode: "class-name",
                    sourceLineNumber: rule.sourceLineNumber,
                    sourceLine: rule.sourceLine
                ))
                continue
            }

            if rule.kind == "property" {
                let targetDevices = concreteTargetDevices(
                    in: rule.arguments,
                    devicesByName: devicesByName,
                    runtimeCellModels: runtimeCellModels
                )
                guard !targetDevices.isEmpty else {
                    ignoredRules.append(ignoredPolicyRule(
                        rule,
                        reasonCode: "unresolved-device-selector",
                        message: "Netgen property policy did not resolve to a concrete imported device model or runtime cell model."
                    ))
                    continue
                }
                let observedTargetDevices = targetDevices.filter {
                    observedPolicyModels.contains(normalizedPolicyName($0.deviceName))
                }
                let unobservedTargetDevices = targetDevices.filter {
                    !observedPolicyModels.contains(normalizedPolicyName($0.deviceName))
                }
                if !unobservedTargetDevices.isEmpty {
                    unobservedRules.append(unobservedPolicyRule(
                        rule,
                        reasonCode: "selector-target-not-observed",
                        message: "Netgen property policy resolved to concrete model(s), but no matching model was observed in the compared netlists.",
                        targetModels: unobservedTargetDevices.map(\.deviceName)
                    ))
                }
                guard !observedTargetDevices.isEmpty else {
                    continue
                }
                let command = propertyCommand(in: rule.arguments)
                switch command {
                case "delete":
                    let parameterNames = propertyDeleteParameterNames(in: rule.arguments)
                    guard !parameterNames.isEmpty else {
                        ignoredRules.append(ignoredPolicyRule(
                            rule,
                            reasonCode: "unsupported-property-delete-arguments",
                            message: "Netgen property delete policy did not contain comparable parameter names."
                        ))
                        continue
                    }
                    for device in observedTargetDevices {
                        let normalizedModel = normalizedPolicyName(device.deviceName)
                        ignoredParametersByModel[normalizedModel, default: []].formUnion(parameterNames)
                        appliedRules.append(LVSDevicePolicyAppliedRule(
                            kind: "property-delete",
                            model: device.deviceName,
                            family: device.family,
                            parameterNames: parameterNames.sorted(),
                            sourceLineNumber: rule.sourceLineNumber,
                            sourceLine: rule.sourceLine
                        ))
                    }
                case "tolerance":
                    let tolerances = propertyToleranceValues(in: rule.arguments)
                    guard !tolerances.isEmpty else {
                        ignoredRules.append(ignoredPolicyRule(
                            rule,
                            reasonCode: "unsupported-property-tolerance-arguments",
                            message: "Netgen property tolerance policy did not contain comparable numeric parameter tolerances."
                        ))
                        continue
                    }
                    for device in observedTargetDevices {
                        let normalizedModel = normalizedPolicyName(device.deviceName)
                        var modelTolerances = parameterTolerancesByModel[normalizedModel, default: [:]]
                        for (parameterName, tolerance) in tolerances {
                            modelTolerances[parameterName] = max(modelTolerances[parameterName] ?? 0, tolerance)
                        }
                        parameterTolerancesByModel[normalizedModel] = modelTolerances
                        appliedRules.append(LVSDevicePolicyAppliedRule(
                            kind: "property-tolerance",
                            model: device.deviceName,
                            family: device.family,
                            parameterNames: tolerances.keys.sorted(),
                            parameterTolerances: Dictionary(uniqueKeysWithValues: tolerances.sorted { $0.key < $1.key }),
                            sourceLineNumber: rule.sourceLineNumber,
                            sourceLine: rule.sourceLine
                        ))
                    }
                case "parallel":
                    let parallelUpdate = propertyParallelUpdate(in: rule.arguments)
                    guard parallelUpdate.isMeaningful else {
                        ignoredRules.append(ignoredPolicyRule(
                            rule,
                            reasonCode: "unsupported-property-parallel-arguments",
                            message: "Netgen property parallel policy did not contain a supported enable, add, or critical directive."
                        ))
                        continue
                    }
                    for device in observedTargetDevices {
                        let normalizedModel = normalizedPolicyName(device.deviceName)
                        parallelPolicyByModel[normalizedModel, default: .empty].merge(parallelUpdate)
                        appliedRules.append(LVSDevicePolicyAppliedRule(
                            kind: "property-parallel",
                            model: device.deviceName,
                            family: device.family,
                            parameterNames: parallelUpdate.parameterNames.sorted(),
                            parameterRoles: parallelUpdate.parameterRoles,
                            propertyMode: parallelUpdate.enabled ? "enable" : nil,
                            sourceLineNumber: rule.sourceLineNumber,
                            sourceLine: rule.sourceLine
                        ))
                    }
                case "series":
                    let seriesUpdate = propertySeriesUpdate(in: rule.arguments)
                    guard seriesUpdate.isMeaningful else {
                        ignoredRules.append(ignoredPolicyRule(
                            rule,
                            reasonCode: "unsupported-property-series-arguments",
                            message: "Netgen property series policy did not contain a supported enable, add, or critical directive."
                        ))
                        continue
                    }
                    for device in observedTargetDevices {
                        guard nativeSeriesDeviceFamilySupported(device.family) else {
                            ignoredRules.append(ignoredPolicyRule(
                                rule,
                                reasonCode: "unsupported-property-series-family",
                                message: "Device family \(device.family) is not supported by native LVS property series aggregation."
                            ))
                            continue
                        }
                        let normalizedModel = normalizedPolicyName(device.deviceName)
                        seriesPolicyByModel[normalizedModel, default: .empty].merge(seriesUpdate)
                        appliedRules.append(LVSDevicePolicyAppliedRule(
                            kind: "property-series",
                            model: device.deviceName,
                            family: device.family,
                            parameterNames: seriesUpdate.parameterNames.sorted(),
                            parameterRoles: seriesUpdate.parameterRoles,
                            propertyMode: seriesUpdate.enabled ? "enable" : nil,
                            sourceLineNumber: rule.sourceLineNumber,
                            sourceLine: rule.sourceLine
                        ))
                    }
                case "blackbox":
                    for device in observedTargetDevices {
                        let normalizedModel = normalizedPolicyName(device.deviceName)
                        blackboxedModels.insert(normalizedModel)
                        appliedRules.append(LVSDevicePolicyAppliedRule(
                            kind: "property-blackbox",
                            model: device.deviceName,
                            family: device.family,
                            propertyMode: "blackbox",
                            sourceLineNumber: rule.sourceLineNumber,
                            sourceLine: rule.sourceLine
                        ))
                    }
                default:
                    ignoredRules.append(ignoredPolicyRule(
                        rule,
                        reasonCode: "unsupported-property-command",
                        message: "Netgen property policy is retained in the application report but only delete, tolerance, parallel, series, and blackbox policies are consumed by native LVS yet."
                    ))
                }
                continue
            }

            if rule.kind == "blackbox" {
                var targetModels = blackboxModelNames(in: rule.arguments)
                if usesRuntimeCellSelector(in: rule.arguments) {
                    targetModels.formUnion(runtimeCellModels)
                }
                guard !targetModels.isEmpty else {
                    ignoredRules.append(ignoredPolicyRule(
                        rule,
                        reasonCode: "unsupported-blackbox-arguments",
                        message: "Netgen blackbox policy did not contain concrete model names."
                    ))
                    continue
                }
                let observedTargetModels = targetModels.filter(observedModels.contains)
                let unobservedTargetModels = targetModels.subtracting(observedTargetModels)
                if !unobservedTargetModels.isEmpty {
                    unobservedRules.append(unobservedPolicyRule(
                        rule,
                        reasonCode: "selector-target-not-observed",
                        message: "Netgen blackbox policy resolved to concrete model(s), but no matching model was observed in the compared netlists.",
                        targetModels: Array(unobservedTargetModels)
                    ))
                }
                guard !observedTargetModels.isEmpty else {
                    continue
                }
                for model in observedTargetModels.sorted() {
                    blackboxedModels.insert(model)
                    appliedRules.append(LVSDevicePolicyAppliedRule(
                        kind: "blackbox",
                        model: model,
                        family: devicesByName[model]?.family,
                        propertyMode: "blackbox",
                        sourceLineNumber: rule.sourceLineNumber,
                        sourceLine: rule.sourceLine
                    ))
                }
                continue
            }

            if rule.kind == "equate-pins" {
                if let runtimePair = circuitModelPair(in: rule.arguments, command: "pins"),
                   devicesByName[runtimePair.circuit1Model] == nil,
                   devicesByName[runtimePair.circuit2Model] == nil {
                    guard layoutObservedModels.contains(runtimePair.circuit1Model),
                          schematicObservedModels.contains(runtimePair.circuit2Model) else {
                        unobservedRules.append(unobservedPolicyRule(
                            rule,
                            reasonCode: "selector-target-not-observed",
                            message: "Netgen equate pins policy resolved to a runtime cell pair not observed on both circuit sides.",
                            targetModels: [runtimePair.circuit1Model, runtimePair.circuit2Model]
                        ))
                        continue
                    }
                    guard mergeModelEquivalenceAlias(
                        alias: runtimePair.circuit1Model,
                        canonical: runtimePair.circuit1Model,
                        into: &modelEquivalenceByModel
                    ), mergeModelEquivalenceAlias(
                        alias: runtimePair.circuit2Model,
                        canonical: runtimePair.circuit1Model,
                        into: &modelEquivalenceByModel
                    ) else {
                        ignoredRules.append(ignoredPolicyRule(
                            rule,
                            reasonCode: "conflicting-equate-pins-model-equivalence",
                            message: "Netgen runtime equate pins policy conflicts with another model-equivalence rule."
                        ))
                        continue
                    }
                    appliedRules.append(LVSDevicePolicyAppliedRule(
                        kind: "equate-pins",
                        model: runtimePair.circuit1Model,
                        pairedModel: runtimePair.circuit2Model,
                        family: "cell",
                        propertyMode: "pin-order",
                        sourceLineNumber: rule.sourceLineNumber,
                        sourceLine: rule.sourceLine
                    ))
                    continue
                }
                guard let pair = equatePinDevicePair(in: rule.arguments, devicesByName: devicesByName) else {
                    ignoredRules.append(ignoredPolicyRule(
                        rule,
                        reasonCode: "unsupported-equate-pins-arguments",
                        message: "Netgen equate pins policy did not contain concrete circuit1 and circuit2 imported device selectors."
                    ))
                    continue
                }
                let observedPairModels = [
                    normalizedPolicyName(pair.circuit1.deviceName),
                    normalizedPolicyName(pair.circuit2.deviceName),
                ]
                let unobservedPairModels = observedPairModels.filter { !observedModels.contains($0) }
                guard unobservedPairModels.isEmpty else {
                    unobservedRules.append(unobservedPolicyRule(
                        rule,
                        reasonCode: "selector-target-not-observed",
                        message: "Netgen equate pins policy resolved to a model pair, but at least one model was not observed in the compared netlists.",
                        targetModels: unobservedPairModels
                    ))
                    continue
                }
                guard let circuit1Kind = nativeComponentKind(for: pair.circuit1.family),
                      let circuit2Kind = nativeComponentKind(for: pair.circuit2.family),
                      circuit1Kind == circuit2Kind else {
                    ignoredRules.append(ignoredPolicyRule(
                        rule,
                        reasonCode: "unsupported-equate-pins-family-pair",
                        message: "Netgen equate pins policy is only consumed for same-family native LVS device models."
                    ))
                    continue
                }
                let canonicalModel = normalizedPolicyName(pair.circuit1.deviceName)
                let pairedModel = normalizedPolicyName(pair.circuit2.deviceName)
                guard mergeModelEquivalenceAlias(
                    alias: canonicalModel,
                    canonical: canonicalModel,
                    into: &modelEquivalenceByModel
                ), mergeModelEquivalenceAlias(
                    alias: pairedModel,
                    canonical: canonicalModel,
                    into: &modelEquivalenceByModel
                ) else {
                    ignoredRules.append(ignoredPolicyRule(
                        rule,
                        reasonCode: "conflicting-equate-pins-model-equivalence",
                        message: "Netgen equate pins policy conflicts with another imported model-equivalence rule."
                    ))
                    continue
                }
                appliedRules.append(LVSDevicePolicyAppliedRule(
                    kind: rule.kind,
                    model: pair.circuit1.deviceName,
                    pairedModel: pair.circuit2.deviceName,
                    family: pair.circuit1.family,
                    propertyMode: "pin-order",
                    sourceLineNumber: rule.sourceLineNumber,
                    sourceLine: rule.sourceLine
                ))
                continue
            }

            guard rule.kind == "permute" else {
                ignoredRules.append(ignoredPolicyRule(
                    rule,
                    reasonCode: "unsupported-policy-kind",
                    message: "Netgen policy kind \(rule.kind) is retained in the application report but is not consumed by native LVS yet."
                ))
                continue
            }

            let targetDevices = concreteTargetDevices(in: rule.arguments, devicesByName: devicesByName)
            guard !targetDevices.isEmpty else {
                ignoredRules.append(ignoredPolicyRule(
                    rule,
                    reasonCode: "unresolved-device-selector",
                    message: "Netgen permute policy did not resolve to a concrete imported device model."
                ))
                continue
            }
            let observedTargetDevices = targetDevices.filter {
                observedModels.contains(normalizedPolicyName($0.deviceName))
            }
            let unobservedTargetDevices = targetDevices.filter {
                !observedModels.contains(normalizedPolicyName($0.deviceName))
            }
            if !unobservedTargetDevices.isEmpty {
                unobservedRules.append(unobservedPolicyRule(
                    rule,
                    reasonCode: "selector-target-not-observed",
                    message: "Netgen permute policy resolved to concrete model(s), but no matching model was observed in the compared netlists.",
                    targetModels: unobservedTargetDevices.map(\.deviceName)
                ))
            }
            guard !observedTargetDevices.isEmpty else {
                continue
            }

            for device in observedTargetDevices {
                let pinGroup = policyPinGroup(in: rule.arguments, family: device.family)
                guard pinGroup.count >= 2 else {
                    ignoredRules.append(ignoredPolicyRule(
                        rule,
                        reasonCode: "unsupported-permute-arguments",
                        message: "Netgen permute policy did not contain a supported numeric or family pin group."
                    ))
                    continue
                }
                guard let nativeKind = nativeComponentKind(for: device.family) else {
                    ignoredRules.append(ignoredPolicyRule(
                        rule,
                        reasonCode: "unsupported-device-family",
                        message: "Device family \(device.family) is not supported by native LVS terminal policy consumption."
                    ))
                    continue
                }
                terminalRules.append(LVSTerminalEquivalenceRule(
                    kind: nativeKind,
                    model: device.deviceName,
                    equivalentPinGroups: [pinGroup]
                ))
                appliedRules.append(LVSDevicePolicyAppliedRule(
                    kind: rule.kind,
                    model: device.deviceName,
                    family: device.family,
                    equivalentPinGroups: [pinGroup],
                    sourceLineNumber: rule.sourceLineNumber,
                    sourceLine: rule.sourceLine
                ))
            }
            }
        }

        let status: LVSDevicePolicyApplicationStatus
        if seed.devices.isEmpty, seed.policyRules.isEmpty {
            status = .blocked
        } else if ignoredRules.isEmpty {
            status = .complete
        } else {
            status = .partial
        }
        let report = LVSDevicePolicyApplicationReport(
            generatedAt: utcTimestamp(),
            status: status,
            policyPath: policyURL.path(percentEncoded: false),
            seedSourcePath: seed.sourcePath,
            knownDeviceCount: seed.devices.count,
            observedKnownDeviceCount: observedDevices.count,
            policyRuleCount: seed.policyRules.count,
            appliedRuleCount: appliedRules.count,
            ignoredRuleCount: ignoredRules.count,
            unobservedRuleCount: unobservedRules.count,
            policyRuleCountsByKind: count(seed.policyRules.map(\.kind)),
            appliedRuleCountsByKind: count(appliedRules.map(\.kind)),
            ignoredRuleCountsByReason: count(ignoredRules.map(\.reasonCode)),
            unobservedRuleCountsByKind: count(unobservedRules.map(\.kind)),
            deviceFamilyCounts: count(seed.devices.map(\.family)),
            observedDeviceFamilyCounts: count(observedDevices.map(\.family)),
            appliedRules: appliedRules,
            ignoredRules: ignoredRules,
            unobservedRules: unobservedRules
        )
        let diagnostics = devicePolicyDiagnostics(report: report)
        let terminalPolicy = terminalRules.isEmpty ? nil : LVSTerminalEquivalencePolicy(rules: terminalRules)
        return LoadedDevicePolicy(
            terminalPolicy: terminalPolicy,
            modelEquivalence: modelEquivalenceByModel,
            parameterPolicy: LVSParameterComparisonPolicy(
                ignoredParametersByModel: ignoredParametersByModel,
                parameterTolerancesByModel: parameterTolerancesByModel,
                parallelPolicyByModel: parallelPolicyByModel,
                seriesPolicyByModel: seriesPolicyByModel,
                blackboxedModels: blackboxedModels
            ),
            ignoredLayoutModels: ignoredLayoutModels,
            ignoredSchematicModels: ignoredSchematicModels,
            report: report,
            diagnostics: diagnostics
        )
    }

    struct LVSParameterComparisonPolicy: Sendable, Hashable {
        let ignoredParametersByModel: [String: Set<String>]
        let parameterTolerancesByModel: [String: [String: Double]]
        let parallelPolicyByModel: [String: LVSParallelComparisonPolicy]
        let seriesPolicyByModel: [String: LVSSeriesComparisonPolicy]
        let blackboxedModels: Set<String>

        static let empty = LVSParameterComparisonPolicy(
            ignoredParametersByModel: [:],
            parameterTolerancesByModel: [:],
            parallelPolicyByModel: [:],
            seriesPolicyByModel: [:],
            blackboxedModels: []
        )

        func ignoredParameters(
            for component: NativeLVSNetlistComponent,
            modelEquivalence: [String: String]
        ) -> Set<String> {
            let directModel = component.normalizedModel
            let equivalentModel = component.normalizedModel(modelEquivalence: modelEquivalence)
            if blackboxedModels.contains(directModel) || blackboxedModels.contains(equivalentModel) {
                return Set(component.parameters.keys.map { $0.lowercased() })
            }
            return ignoredParametersByModel[directModel, default: []]
                .union(ignoredParametersByModel[equivalentModel, default: []])
        }

        func parameterTolerances(
            for component: NativeLVSNetlistComponent,
            modelEquivalence: [String: String]
        ) -> [String: Double] {
            let directModel = component.normalizedModel
            let equivalentModel = component.normalizedModel(modelEquivalence: modelEquivalence)
            var result = parameterTolerancesByModel[directModel, default: [:]]
            for (parameterName, tolerance) in parameterTolerancesByModel[equivalentModel, default: [:]] {
                result[parameterName] = max(result[parameterName] ?? 0, tolerance)
            }
            return result
        }

        func parallelPolicy(
            for component: NativeLVSNetlistComponent,
            modelEquivalence: [String: String]
        ) -> LVSParallelComparisonPolicy {
            let directModel = component.normalizedModel
            let equivalentModel = component.normalizedModel(modelEquivalence: modelEquivalence)
            var result = parallelPolicyByModel[directModel, default: .empty]
            result.merge(parallelPolicyByModel[equivalentModel, default: .empty])
            return result
        }

        func seriesPolicy(
            for component: NativeLVSNetlistComponent,
            modelEquivalence: [String: String]
        ) -> LVSSeriesComparisonPolicy {
            let directModel = component.normalizedModel
            let equivalentModel = component.normalizedModel(modelEquivalence: modelEquivalence)
            var result = seriesPolicyByModel[directModel, default: .empty]
            result.merge(seriesPolicyByModel[equivalentModel, default: .empty])
            return result
        }
    }

    struct LVSParallelComparisonPolicy: Sendable, Hashable {
        var enabled: Bool
        var additiveParameters: Set<String>
        var criticalParameters: Set<String>

        static let empty = LVSParallelComparisonPolicy(
            enabled: false,
            additiveParameters: [],
            criticalParameters: []
        )

        var isMeaningful: Bool {
            enabled || !additiveParameters.isEmpty || !criticalParameters.isEmpty
        }

        var parameterNames: Set<String> {
            additiveParameters.union(criticalParameters)
        }

        var parameterRoles: [String: String]? {
            var roles: [String: String] = [:]
            for parameter in additiveParameters {
                roles[parameter] = "add"
            }
            for parameter in criticalParameters {
                roles[parameter] = "critical"
            }
            return roles.isEmpty ? nil : roles
        }

        mutating func merge(_ other: LVSParallelComparisonPolicy) {
            enabled = enabled || other.enabled
            additiveParameters.formUnion(other.additiveParameters)
            criticalParameters.formUnion(other.criticalParameters)
        }
    }

    struct LVSSeriesComparisonPolicy: Sendable, Hashable {
        var enabled: Bool
        var additiveParameters: Set<String>
        var criticalParameters: Set<String>

        static let empty = LVSSeriesComparisonPolicy(
            enabled: false,
            additiveParameters: [],
            criticalParameters: []
        )

        var isMeaningful: Bool {
            enabled || !additiveParameters.isEmpty || !criticalParameters.isEmpty
        }

        var parameterNames: Set<String> {
            additiveParameters.union(criticalParameters)
        }

        var parameterRoles: [String: String]? {
            var roles: [String: String] = [:]
            for parameter in additiveParameters {
                roles[parameter] = "add"
            }
            for parameter in criticalParameters {
                roles[parameter] = "critical"
            }
            return roles.isEmpty ? nil : roles
        }

        mutating func merge(_ other: LVSSeriesComparisonPolicy) {
            enabled = enabled || other.enabled
            additiveParameters.formUnion(other.additiveParameters)
            criticalParameters.formUnion(other.criticalParameters)
        }
    }

    private func resolveRuntimePolicyRule(
        _ rule: NetgenLVSPolicyRule,
        layoutRuntimeCellModels: Set<String>,
        schematicRuntimeCellModels: Set<String>
    ) -> RuntimePolicyResolution {
        guard let predicate = rule.runtimePredicate else {
            return RuntimePolicyResolution(rules: [rule], failureReason: nil)
        }
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: predicate.pattern)
        } catch {
            return RuntimePolicyResolution(
                rules: [],
                failureReason: "Netgen runtime selector regex is invalid: \(error.localizedDescription)"
            )
        }
        let argumentsText = rule.arguments.joined(separator: " ").lowercased()
        let variableToken = "$\(predicate.variableName.lowercased())"
        let usesCircuit1 = argumentsText.contains("-circuit1 \(variableToken)")
        let usesCircuit2 = argumentsText.contains("-circuit2 \(variableToken)")
        let candidates: Set<String>
        if usesCircuit1, !usesCircuit2 {
            candidates = layoutRuntimeCellModels
        } else if usesCircuit2, !usesCircuit1 {
            candidates = schematicRuntimeCellModels
        } else {
            candidates = layoutRuntimeCellModels.union(schematicRuntimeCellModels)
        }
        var resolvedRules: [NetgenLVSPolicyRule] = []
        for candidate in candidates.sorted() {
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = expression.firstMatch(in: candidate, range: range) else {
                continue
            }
            var bindings = [predicate.variableName: candidate]
            for (offset, variableName) in predicate.captureVariableNames.enumerated() {
                let captureIndex = offset + 1
                guard captureIndex < match.numberOfRanges,
                      let captureRange = Range(match.range(at: captureIndex), in: candidate) else {
                    continue
                }
                bindings[variableName] = String(candidate[captureRange])
            }
            resolvedRules.append(NetgenLVSPolicyRule(
                kind: rule.kind,
                arguments: rule.arguments.map { substituteRuntimeBindings(bindings, in: $0) },
                sourceLineNumber: rule.sourceLineNumber,
                sourceLine: substituteRuntimeBindings(bindings, in: rule.sourceLine)
            ))
        }
        return RuntimePolicyResolution(rules: resolvedRules, failureReason: nil)
    }

    private func substituteRuntimeBindings(
        _ bindings: [String: String],
        in value: String
    ) -> String {
        bindings.keys.sorted { $0.count > $1.count }.reduce(value) { result, variableName in
            guard let replacement = bindings[variableName] else { return result }
            return result
                .replacingOccurrences(of: "${\(variableName)}", with: replacement)
                .replacingOccurrences(of: "$\(variableName)", with: replacement)
        }
    }

    private func circuitModelTargets(in arguments: [String]) -> [CircuitModelTarget] {
        let tokens = flattenedPolicyTokens(in: arguments).map(cleanPolicyToken)
        var targets: [CircuitModelTarget] = []
        var index = tokens.startIndex
        while index < tokens.endIndex {
            let token = tokens[index].lowercased()
            let valueIndex = tokens.index(after: index)
            if token == "-circuit1", valueIndex < tokens.endIndex {
                targets.append(CircuitModelTarget(circuit: 1, model: normalizedPolicyName(tokens[valueIndex])))
                index = tokens.index(after: valueIndex)
                continue
            }
            if token == "-circuit2", valueIndex < tokens.endIndex {
                targets.append(CircuitModelTarget(circuit: 2, model: normalizedPolicyName(tokens[valueIndex])))
                index = tokens.index(after: valueIndex)
                continue
            }
            index = valueIndex
        }
        return targets.filter { !$0.model.isEmpty && !$0.model.contains("$") }
    }

    private func circuitModelPair(
        in arguments: [String],
        command: String
    ) -> CircuitModelPair? {
        let tokens = flattenedPolicyTokens(in: arguments).map(cleanPolicyToken)
        guard tokens.contains(where: { $0.lowercased() == command }) else { return nil }
        let targets = circuitModelTargets(in: arguments)
        guard let circuit1 = targets.first(where: { $0.circuit == 1 }),
              let circuit2 = targets.first(where: { $0.circuit == 2 }) else {
            return nil
        }
        return CircuitModelPair(
            circuit1Model: normalizedPolicyName(circuit1.model),
            circuit2Model: normalizedPolicyName(circuit2.model)
        )
    }

    private func cleanPolicyToken(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'{}"))
    }

    private func policyPinGroup(in arguments: [String], family: String) -> [Int] {
        let tokens: [String] = selectorTokens(in: arguments)
        let numericPins: [Int] = tokens.compactMap { token -> Int? in
            guard let value = Int(token), value > 0 else {
                return nil
            }
            return value - 1
        }
        if numericPins.count >= 2 { return numericPins }
        let namedPins = Set(tokens.map { $0.lowercased() })
        if family == "resistor", namedPins.isSuperset(of: ["end_a", "end_b"]) {
            return [0, 1]
        }
        return []
    }

    private func isPermuteDefault(_ arguments: [String]) -> Bool {
        flattenedPolicyTokens(in: arguments).map(cleanPolicyToken).map { $0.lowercased() } == ["default"]
    }

    private func globalPropertyMode(_ arguments: [String]) -> String? {
        let tokens = flattenedPolicyTokens(in: arguments).map(cleanPolicyToken).map { $0.lowercased() }
        if tokens == ["default"] { return "native-default" }
        if tokens == ["parallel", "none"] { return "parallel-disabled" }
        return nil
    }

    private func concreteTargetDevices(
        in arguments: [String],
        devicesByName: [String: NetgenLVSDeviceDescriptor],
        runtimeCellModels: Set<String> = []
    ) -> [NetgenLVSDeviceDescriptor] {
        var seen = Set<String>()
        var devices: [NetgenLVSDeviceDescriptor] = []
        if usesRuntimeCellSelector(in: arguments) {
            for model in runtimeCellModels.sorted() where !seen.contains(model) {
                seen.insert(model)
                devices.append(NetgenLVSDeviceDescriptor(
                    deviceName: model,
                    family: "cell",
                    sourceLineNumber: 0,
                    sourceLine: "runtime $cell"
                ))
            }
        }
        for token in selectorTokens(in: arguments) {
            let normalized = normalizedPolicyName(token)
            guard !seen.contains(normalized) else {
                continue
            }
            if runtimeCellModels.contains(normalized) {
                seen.insert(normalized)
                devices.append(NetgenLVSDeviceDescriptor(
                    deviceName: normalized,
                    family: "cell",
                    sourceLineNumber: 0,
                    sourceLine: "resolved runtime selector"
                ))
                continue
            }
            guard let device = devicesByName[normalized] else { continue }
            seen.insert(normalized)
            devices.append(device)
        }
        return devices
    }

    private func usesRuntimeCellSelector(in arguments: [String]) -> Bool {
        flattenedPolicyTokens(in: arguments).contains { token in
            token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'{}")).lowercased() == "$cell"
        }
    }

    private func equatePinDevicePair(
        in arguments: [String],
        devicesByName: [String: NetgenLVSDeviceDescriptor]
    ) -> EquatePinDevicePair? {
        let tokens = flattenedPolicyTokens(in: arguments).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'{}"))
        }
        guard tokens.contains(where: { $0.lowercased() == "pins" }) else {
            return nil
        }
        var circuit1Model: String?
        var circuit2Model: String?
        var index = tokens.startIndex
        while index < tokens.endIndex {
            let token = tokens[index].lowercased()
            let valueIndex = tokens.index(after: index)
            if token == "-circuit1", valueIndex < tokens.endIndex {
                circuit1Model = tokens[valueIndex]
                index = tokens.index(after: valueIndex)
                continue
            }
            if token == "-circuit2", valueIndex < tokens.endIndex {
                circuit2Model = tokens[valueIndex]
                index = tokens.index(after: valueIndex)
                continue
            }
            index = valueIndex
        }
        guard let circuit1Model,
              let circuit2Model,
              let circuit1 = devicesByName[normalizedPolicyName(circuit1Model)],
              let circuit2 = devicesByName[normalizedPolicyName(circuit2Model)] else {
            return nil
        }
        return EquatePinDevicePair(circuit1: circuit1, circuit2: circuit2)
    }

    func blackboxModelNames(
        from seed: NetgenLVSDevicePolicySeed?,
        runtimeCellModels: Set<String>
    ) -> Set<String> {
        guard let seed else { return [] }
        let devicesByName = seed.devices.reduce(into: [String: NetgenLVSDeviceDescriptor]()) { result, device in
            result[normalizedPolicyName(device.deviceName)] = device
        }
        var result: Set<String> = []
        for sourceRule in seed.policyRules {
            let resolution = resolveRuntimePolicyRule(
                sourceRule,
                layoutRuntimeCellModels: runtimeCellModels,
                schematicRuntimeCellModels: runtimeCellModels
            )
            for rule in resolution.rules {
            if rule.kind == "property",
               propertyCommand(in: rule.arguments) == "blackbox" {
                result.formUnion(concreteTargetDevices(
                    in: rule.arguments,
                    devicesByName: devicesByName,
                    runtimeCellModels: runtimeCellModels
                ).map {
                    normalizedPolicyName($0.deviceName)
                })
                continue
            }
            if rule.kind == "blackbox" {
                if usesRuntimeCellSelector(in: rule.arguments) {
                    result.formUnion(runtimeCellModels)
                }
                result.formUnion(blackboxModelNames(in: rule.arguments))
            }
            if rule.kind == "ignore-class" {
                result.formUnion(circuitModelTargets(in: rule.arguments).map {
                    normalizedPolicyName($0.model)
                })
            }
            }
        }
        return result
    }

    func blackboxModelNames(in arguments: [String]) -> Set<String> {
        let tokens = flattenedPolicyTokens(in: arguments).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'{}")).lowercased()
        }
        let candidateTokens: ArraySlice<String>
        if let blackboxIndex = tokens.firstIndex(of: "blackbox") {
            candidateTokens = tokens[tokens.index(after: blackboxIndex)...]
        } else {
            candidateTokens = tokens[...]
        }
        return Set(candidateTokens.filter(isPolicyModelToken).map(normalizedPolicyName))
    }

    private func isPolicyModelToken(_ token: String) -> Bool {
        !token.isEmpty
            && !token.hasPrefix("-")
            && !token.contains("$")
            && token != "model"
            && token != "blackbox"
            && token != "default"
            && token != "pins"
            && token != "enable"
            && token != "add"
            && token != "critical"
    }

    private func mergeModelEquivalenceAlias(
        alias: String,
        canonical: String,
        into modelEquivalence: inout [String: String]
    ) -> Bool {
        let normalizedAlias = normalizedPolicyName(alias)
        let normalizedCanonical = normalizedPolicyName(canonical)
        guard !normalizedAlias.isEmpty, !normalizedCanonical.isEmpty else {
            return false
        }
        if let existing = modelEquivalence[normalizedAlias] {
            return existing == normalizedCanonical
        }
        modelEquivalence[normalizedAlias] = normalizedCanonical
        return true
    }

    private func selectorTokens(in arguments: [String]) -> [String] {
        flattenedPolicyTokens(in: arguments)
        .map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'{}"))
        }
        .filter { token in
            !token.isEmpty
                && token != "-circuit1"
                && token != "-circuit2"
                && token != "default"
                && !token.contains("$")
        }
    }

    private func flattenedPolicyTokens(in arguments: [String]) -> [String] {
        arguments.flatMap { argument in
            argument
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        }
    }

    private func propertyCommand(in arguments: [String]) -> String? {
        let tokens = flattenedPolicyTokens(in: arguments).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'{}")).lowercased()
        }
        return tokens.first { token in
            token == "delete"
                || token == "tolerance"
                || token == "parallel"
                || token == "series"
                || token == "blackbox"
        }
    }

    private func propertyDeleteParameterNames(in arguments: [String]) -> Set<String> {
        let tokens = flattenedPolicyTokens(in: arguments).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'{}")).lowercased()
        }
        guard let deleteIndex = tokens.firstIndex(of: "delete") else {
            return []
        }
        return Set(tokens[tokens.index(after: deleteIndex)...].filter { token in
            !token.isEmpty
                && !token.hasPrefix("-circuit")
                && !token.hasPrefix("$")
                && token != "delete"
        })
    }

    private func propertyToleranceValues(in arguments: [String]) -> [String: Double] {
        let tokens = flattenedPolicyTokens(in: arguments).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'{}")).lowercased()
        }
        guard let toleranceIndex = tokens.firstIndex(of: "tolerance") else {
            return [:]
        }
        var result: [String: Double] = [:]
        var index = tokens.index(after: toleranceIndex)
        while index < tokens.endIndex {
            let parameterName = tokens[index]
            let valueIndex = tokens.index(after: index)
            guard valueIndex < tokens.endIndex else {
                break
            }
            let toleranceValue = tokens[valueIndex]
            if isComparablePropertyName(parameterName),
               let tolerance = SPICEValueNormalizer.numericValue(toleranceValue),
               tolerance.isFinite,
               tolerance >= 0 {
                result[parameterName] = tolerance
            }
            index = tokens.index(after: valueIndex)
        }
        return result
    }

    private func propertyParallelUpdate(in arguments: [String]) -> LVSParallelComparisonPolicy {
        let tokens = flattenedPolicyTokens(in: arguments).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'{}")).lowercased()
        }
        guard let parallelIndex = tokens.firstIndex(of: "parallel") else {
            return .empty
        }
        var result = LVSParallelComparisonPolicy.empty
        var index = tokens.index(after: parallelIndex)
        while index < tokens.endIndex {
            let token = tokens[index]
            if token == "enable" {
                result.enabled = true
                index = tokens.index(after: index)
                continue
            }
            let roleIndex = tokens.index(after: index)
            guard roleIndex < tokens.endIndex else {
                break
            }
            let role = tokens[roleIndex]
            if isComparablePropertyName(token), role == "add" {
                result.enabled = true
                result.additiveParameters.insert(token)
            } else if isComparablePropertyName(token), role == "critical" {
                result.enabled = true
                result.criticalParameters.insert(token)
            }
            index = tokens.index(after: roleIndex)
        }
        return result
    }

    private func propertySeriesUpdate(in arguments: [String]) -> LVSSeriesComparisonPolicy {
        let tokens = flattenedPolicyTokens(in: arguments).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'{}")).lowercased()
        }
        guard let seriesIndex = tokens.firstIndex(of: "series") else {
            return .empty
        }
        var result = LVSSeriesComparisonPolicy.empty
        var index = tokens.index(after: seriesIndex)
        while index < tokens.endIndex {
            let token = tokens[index]
            if token == "enable" {
                result.enabled = true
                index = tokens.index(after: index)
                continue
            }
            let roleIndex = tokens.index(after: index)
            guard roleIndex < tokens.endIndex else {
                break
            }
            let role = tokens[roleIndex]
            if isComparablePropertyName(token), role == "add" {
                result.enabled = true
                result.additiveParameters.insert(token)
            } else if isComparablePropertyName(token), role == "critical" {
                result.enabled = true
                result.criticalParameters.insert(token)
            }
            index = tokens.index(after: roleIndex)
        }
        return result
    }

    private func isComparablePropertyName(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("-circuit")
            && !value.hasPrefix("$")
            && value != "tolerance"
            && value != "delete"
            && value != "parallel"
            && value != "series"
            && value != "blackbox"
    }

    private func ignoredPolicyRule(
        _ rule: NetgenLVSPolicyRule,
        reasonCode: String,
        message: String
    ) -> LVSDevicePolicyIgnoredRule {
        LVSDevicePolicyIgnoredRule(
            kind: rule.kind,
            reasonCode: reasonCode,
            message: message,
            sourceLineNumber: rule.sourceLineNumber,
            sourceLine: rule.sourceLine
        )
    }

    private func unobservedPolicyRule(
        _ rule: NetgenLVSPolicyRule,
        reasonCode: String,
        message: String,
        targetModels: [String]
    ) -> LVSDevicePolicyUnobservedRule {
        LVSDevicePolicyUnobservedRule(
            kind: rule.kind,
            reasonCode: reasonCode,
            message: message,
            targetModels: targetModels.map(normalizedPolicyName).sorted(),
            sourceLineNumber: rule.sourceLineNumber,
            sourceLine: rule.sourceLine
        )
    }

    private func devicePolicyDiagnostics(report: LVSDevicePolicyApplicationReport) -> [LVSDiagnostic] {
        var diagnostics: [LVSDiagnostic] = []
        if report.status != .complete {
            diagnostics.append(LVSDiagnostic(
                severity: .error,
                message: "LVS device policy application is \(report.status.rawValue); equivalence is not established.",
                ruleID: "LVS_DEVICE_POLICY_\(report.status.rawValue.uppercased())",
                category: "devicePolicyReadiness",
                suggestedFix: "Resolve every ignored or unsupported policy rule before relying on native LVS.",
                rawLine: "policy=\(report.policyPath) status=\(report.status.rawValue)",
                waiverDisposition: .nonWaivable
            ))
        }
        if report.appliedRuleCount > 0 {
            diagnostics.append(LVSDiagnostic(
                severity: .info,
                message: "Applied \(report.appliedRuleCount) LVS device policy rule(s).",
                ruleID: "LVS_DEVICE_POLICY_APPLIED",
                category: "devicePolicy",
                suggestedFix: nil,
                rawLine: "policy=\(report.policyPath) applied=\(report.appliedRuleCount)"
            ))
        }
        if report.ignoredRuleCount > 0 {
            diagnostics.append(LVSDiagnostic(
                severity: .warning,
                message: "Ignored \(report.ignoredRuleCount) LVS device policy rule(s) that native LVS does not consume yet.",
                ruleID: "LVS_DEVICE_POLICY_IGNORED",
                category: "devicePolicy",
                suggestedFix: "Inspect lvs-device-policy-application-report before relying on foundry policy parity.",
                rawLine: "policy=\(report.policyPath) ignored=\(report.ignoredRuleCount)"
            ))
            for (reasonCode, count) in report.ignoredRuleCountsByReason.sorted(by: { $0.key < $1.key }) {
                diagnostics.append(LVSDiagnostic(
                    severity: .warning,
                    message: "Ignored \(count) LVS device policy rule(s) for reason \(reasonCode).",
                    ruleID: devicePolicyDiagnosticRuleID(
                        prefix: "LVS_DEVICE_POLICY_IGNORED",
                        reasonCode: reasonCode
                    ),
                    category: "devicePolicy",
                    suggestedFix: "Review ignoredRules where reasonCode=\(reasonCode) in lvs-device-policy-application-report.",
                    rawLine: "policy=\(report.policyPath) ignoredReason=\(reasonCode) count=\(count)"
                ))
            }
        }
        if report.unobservedRuleCount > 0 {
            diagnostics.append(LVSDiagnostic(
                severity: .info,
                message: "Retained \(report.unobservedRuleCount) LVS device policy rule(s) whose selectors matched no observed model in this run.",
                ruleID: "LVS_DEVICE_POLICY_UNOBSERVED",
                category: "devicePolicy",
                suggestedFix: "Use unobservedRules in lvs-device-policy-application-report as policy coverage material, not as an LVS mismatch.",
                rawLine: "policy=\(report.policyPath) unobserved=\(report.unobservedRuleCount)"
            ))
            let unobservedRuleCountsByReason = count(report.unobservedRules.map(\.reasonCode))
            for (reasonCode, count) in unobservedRuleCountsByReason.sorted(by: { $0.key < $1.key }) {
                diagnostics.append(LVSDiagnostic(
                    severity: .info,
                    message: "Retained \(count) unobserved LVS device policy rule(s) for reason \(reasonCode).",
                    ruleID: devicePolicyDiagnosticRuleID(
                        prefix: "LVS_DEVICE_POLICY_UNOBSERVED",
                        reasonCode: reasonCode
                    ),
                    category: "devicePolicy",
                    suggestedFix: "Review unobservedRules where reasonCode=\(reasonCode) and targetModels are retained in lvs-device-policy-application-report.",
                    rawLine: "policy=\(report.policyPath) unobservedReason=\(reasonCode) count=\(count)"
                ))
            }
        }
        if report.knownDeviceCount > 0, report.observedKnownDeviceCount == 0 {
            diagnostics.append(LVSDiagnostic(
                severity: .warning,
                message: "No imported foundry device models were observed in the compared netlists.",
                ruleID: "LVS_DEVICE_POLICY_NO_OBSERVED_DEVICES",
                category: "devicePolicy",
                suggestedFix: "Verify that extracted layout and schematic model names match the device policy seed.",
                rawLine: "policy=\(report.policyPath) knownDevices=\(report.knownDeviceCount)"
            ))
        }
        return diagnostics
    }

    private func devicePolicyDiagnosticRuleID(prefix: String, reasonCode: String) -> String {
        let suffix = reasonCode
            .uppercased()
            .map { character in
                character.isLetter || character.isNumber ? character : "_"
            }
            .reduce(into: "") { result, character in
                if character == "_", result.last == "_" {
                    return
                }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return suffix.isEmpty ? prefix : "\(prefix)_\(suffix)"
    }

    private func nativeComponentKind(for family: String) -> String? {
        switch family {
        case "mos", "resistor", "diode", "capacitor", "bjt", "inductor":
            return family
        default:
            return nil
        }
    }

    private func nativeSeriesDeviceFamilySupported(_ family: String) -> Bool {
        switch family {
        case "mos", "resistor", "inductor":
            return true
        default:
            return false
        }
    }

    private func count(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { counts, value in
            counts[value, default: 0] += 1
        }
    }

    func normalizedPolicyName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func utcTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
