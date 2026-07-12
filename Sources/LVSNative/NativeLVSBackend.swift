import Foundation
import LVSCore
import LVSGraph
import LVSMatching
@_exported import LVSNetlistParsing

public struct NativeLVSBackend: LVSCancellableBackend {
    public let backendID = "native"
    private let parser: NativeSPICENetlistParser

    public init(parser: NativeSPICENetlistParser = NativeSPICENetlistParser()) {
        self.parser = parser
    }

    public func run(_ request: LVSRequest) async throws -> LVSExecutionResult {
        try await run(request, cancellationCheck: nil)
    }

    public func run(
        _ request: LVSRequest,
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> LVSExecutionResult {
        try await checkCancellation(cancellationCheck)
        guard let layoutNetlistURL = request.layoutNetlistURL else {
            throw LVSError.invalidInput("Native LVS requires a layout netlist")
        }

        let devicePolicySeed = try loadDevicePolicySeed(from: request.devicePolicyURL)
        let runtimeCellModels = try parser.inspectRuntimeCellModels(urls: [
            layoutNetlistURL,
            request.schematicNetlistURL,
        ])
        let blackboxModels = blackboxModelNames(
            from: devicePolicySeed,
            runtimeCellModels: runtimeCellModels
        )
        let layout = try parser.parse(
            url: layoutNetlistURL,
            expectedTopCell: request.topCell,
            blackboxModels: blackboxModels
        )
        let schematic = try parser.parse(
            url: request.schematicNetlistURL,
            expectedTopCell: request.topCell,
            blackboxModels: blackboxModels
        )
        let devicePolicy = try loadDevicePolicy(
            seed: devicePolicySeed,
            policyURL: request.devicePolicyURL,
            layout: layout,
            schematic: schematic
        )
        let modelEquivalence = try mergedModelEquivalence(
            explicitPolicy: loadModelEquivalence(from: request.modelEquivalenceURL),
            devicePolicy: devicePolicy.modelEquivalence
        )
        let terminalEquivalence = try loadTerminalEquivalence(
            from: request.terminalEquivalenceURL,
            devicePolicy: devicePolicy.terminalPolicy
        )
        try await checkCancellation(cancellationCheck)
        var correspondence: LVSCorrespondence?
        var graphBlockingReasons: [LVSBlockingReason] = []
        let interfaceDiagnostics = portDiagnostics(layout: layout, schematic: schematic)
        var diagnostics: [LVSDiagnostic]
        let canonicalLayout = NativeLVSNetlist(
            topCell: layout.topCell,
            ports: layout.ports,
            globalNets: layout.globalNets,
            runtimeCellModels: layout.runtimeCellModels,
            components: canonicalizedComponentsForGraph(
                layout.components.filter {
                    !devicePolicy.ignoredLayoutModels.contains($0.normalizedModel)
                },
                modelEquivalence: modelEquivalence,
                terminalEquivalence: terminalEquivalence,
                parameterPolicy: devicePolicy.parameterPolicy
            )
        )
        let canonicalSchematic = NativeLVSNetlist(
            topCell: schematic.topCell,
            ports: schematic.ports,
            globalNets: schematic.globalNets,
            runtimeCellModels: schematic.runtimeCellModels,
            components: canonicalizedComponentsForGraph(
                schematic.components.filter {
                    !devicePolicy.ignoredSchematicModels.contains($0.normalizedModel)
                },
                modelEquivalence: modelEquivalence,
                terminalEquivalence: terminalEquivalence,
                parameterPolicy: devicePolicy.parameterPolicy
            )
        )
        let builder = NativeLVSGraphBuilder()
        var modelKinds: [String: String] = [:]
        for descriptor in devicePolicySeed?.devices ?? [] {
            modelKinds[descriptor.deviceName.lowercased()] = descriptor.family.lowercased()
        }
        let sharedGlobalNetNames = Set(layout.globalNets).union(schematic.globalNets)
        let layoutGraph = try builder.build(
            netlist: canonicalLayout,
            modelEquivalence: modelEquivalence,
            terminalEquivalence: terminalEquivalence,
            parameterPolicy: devicePolicy.parameterPolicy,
            modelKinds: modelKinds,
            maximumObjectCount: request.options.effectiveMaximumGraphObjectCount,
            sharedGlobalNetNames: sharedGlobalNetNames
        )
        let schematicGraph = try builder.build(
            netlist: canonicalSchematic,
            modelEquivalence: modelEquivalence,
            terminalEquivalence: terminalEquivalence,
            parameterPolicy: devicePolicy.parameterPolicy,
            modelKinds: modelKinds,
            maximumObjectCount: request.options.effectiveMaximumGraphObjectCount,
            sharedGlobalNetNames: sharedGlobalNetNames
        )
        let graphResult = try LVSGraphMatcher().match(
            layout: layoutGraph,
            schematic: schematicGraph,
            budget: LVSMatchBudget(
                maximumSearchStates: request.options.effectiveMaximumSearchStates,
                maximumDurationSeconds: request.options.timeoutSeconds,
                maximumSearchDepth: request.options.effectiveMaximumSearchDepth,
                maximumWorkingSetBytes: request.options.effectiveMaximumWorkingSetBytes
            )
        )
        correspondence = graphResult.correspondence
        switch graphResult.status {
        case .matched:
            diagnostics = interfaceDiagnostics
        case .mismatched:
            diagnostics = interfaceDiagnostics + graphMismatchDiagnostics(from: graphResult)
        case .blocked:
            graphBlockingReasons = graphResult.reasonCodes.map { reasonCode in
                LVSBlockingReason(
                    code: reasonCode,
                    message: "Canonical graph matching could not establish a verdict."
                )
            }
            diagnostics = [LVSDiagnostic(
                    severity: .error,
                    message: "Canonical graph matching was blocked by its execution budget.",
                    ruleID: "LVS_GRAPH_MATCH_BLOCKED",
                    category: "matcherReadiness",
                    suggestedFix: "Inspect graph ambiguity and ratify a larger bounded search budget if justified.",
                    rawLine: "reasons=\(graphResult.reasonCodes.joined(separator: ",")) states=\(graphResult.exploredSearchStates)",
                    waiverDisposition: .nonWaivable
                )]
        }
        diagnostics.append(contentsOf: devicePolicy.diagnostics)
        let blockingReasons: [LVSBlockingReason]
        if let report = devicePolicy.report, report.status != .complete {
            blockingReasons = graphBlockingReasons + [LVSBlockingReason(
                code: "device_policy_\(report.status.rawValue)",
                message: "Native LVS did not completely apply the requested device policy.",
                evidenceReferences: [report.policyPath]
            )]
        } else {
            blockingReasons = graphBlockingReasons
        }
        let activeMismatch = diagnostics.contains {
            $0.severity == .error
                && !$0.isWaived
        }
        let verdict: LVSVerificationVerdict = blockingReasons.isEmpty
            ? (activeMismatch ? .mismatch : .match)
            : .blocked
        let logPath: String
        if let workingDirectory = request.workingDirectory {
            try FileManager.default.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true
            )
            let logURL = workingDirectory.appending(path: "lvs-native-\(UUID().uuidString).log")
            let log = (["\(diagnostics.filter { $0.severity == .error }.count) mismatch(es) on \(request.topCell)"]
                + diagnostics.map { "\($0.severity): \($0.message)" })
                .joined(separator: "\n") + "\n"
            try log.write(to: logURL, atomically: true, encoding: .utf8)
            logPath = logURL.path(percentEncoded: false)
        } else {
            logPath = ""
        }
        let result = LVSResult(
            backendID: backendID,
            toolName: "NativeLVS",
            executionStatus: .completed,
            verdict: verdict,
            readiness: blockingReasons.isEmpty ? .ready : .blocked,
            blockingReasons: blockingReasons,
            logPath: logPath,
            diagnostics: diagnostics,
            provenance: LVSToolProvenance(
                executablePath: "in-process",
                pdkRoot: "not-applicable",
                setupFilePath: "not-applicable",
                driverScriptPath: "not-applicable",
                timeoutSeconds: request.options.timeoutSeconds
            )
        )
        return LVSExecutionResult(
            request: request,
            result: result,
            devicePolicyReport: devicePolicy.report,
            correspondence: correspondence
        )
    }

    private func checkCancellation(_ cancellationCheck: LVSExecutionCancellationCheck?) async throws {
        do {
            try Task.checkCancellation()
        } catch {
            throw LVSError.cancelled("Native LVS task was cancelled.")
        }
        if try await cancellationCheck?() == true {
            throw LVSError.cancelled("Native LVS cancellation was requested.")
        }
    }

    private func graphMismatchDiagnostics(from result: LVSGraphMatchResult) -> [LVSDiagnostic] {
        let reasons = result.reasonCodes.isEmpty ? ["graph_not_isomorphic"] : result.reasonCodes
        let layoutObjectIDs = result.correspondence.unmatchedLayoutObjectIDs.map(\.rawValue).joined(separator: ",")
        let schematicObjectIDs = result.correspondence.unmatchedSchematicObjectIDs.map(\.rawValue).joined(separator: ",")
        return reasons.map { reason in
            let metadata = graphMismatchMetadata(for: reason)
            return LVSDiagnostic(
                severity: .error,
                message: metadata.message,
                ruleID: metadata.ruleID,
                category: metadata.category,
                componentSignature: result.correspondence.unmatchedLayoutObjectIDs.first?.rawValue,
                suggestedFix: "Inspect the retained canonical correspondence and source-object references.",
                rawLine: [
                    "reason=\(reason)",
                    "layoutObjectIDs=\(layoutObjectIDs)",
                    "schematicObjectIDs=\(schematicObjectIDs)",
                ].joined(separator: " "),
                waiverDisposition: metadata.waiverDisposition
            )
        }
    }

    private func graphMismatchMetadata(
        for reason: String
    ) -> (message: String, ruleID: String, category: String, waiverDisposition: LVSDiagnosticWaiverDisposition) {
        switch reason {
        case "port_set_mismatch", "port_connectivity_mismatch":
            return (
                "Top-cell port equivalence failed in the canonical LVS graph.",
                "LVS_PORT_MISMATCH",
                "portMismatch",
                .nonWaivable
            )
        case "device_count_mismatch":
            return (
                "Canonical LVS graphs contain different device counts.",
                "LVS_COMPONENT_COUNT_MISMATCH",
                "componentCount",
                .waivable
            )
        case "device_parameter_mismatch":
            return (
                "Canonical LVS graph device parameters differ.",
                "LVS_PARAMETER_MISMATCH",
                "parameterMismatch",
                .waivable
            )
        case "device_semantics_mismatch":
            return (
                "Canonical LVS graph device kinds or models differ.",
                "LVS_MODEL_MISMATCH",
                "modelMismatch",
                .waivable
            )
        case "net_count_mismatch", "global_net_set_mismatch", "global_net_connectivity_mismatch":
            return (
                "Canonical LVS graph net or global-net equivalence failed.",
                "LVS_NET_MISMATCH",
                "netMismatch",
                .nonWaivable
            )
        default:
            return (
                "Canonical LVS graphs are not isomorphic.",
                "LVS_GRAPH_MISMATCH",
                "graphMismatch",
                .waivable
            )
        }
    }

    private func portDiagnostics(
        layout: NativeLVSNetlist,
        schematic: NativeLVSNetlist
    ) -> [LVSDiagnostic] {
        var diagnostics: [LVSDiagnostic] = []
        let sharedGlobalNets = Set(layout.globalNets).union(schematic.globalNets)
        let layoutPorts = nonGlobalPorts(layout.ports, globalNets: sharedGlobalNets)
        let schematicPorts = nonGlobalPorts(schematic.ports, globalNets: sharedGlobalNets)
        if layoutPorts != schematicPorts {
            diagnostics.append(LVSDiagnostic(
                severity: .error,
                message: "Top cell non-global ports differ between layout and schematic",
                ruleID: "LVS_PORT_MISMATCH",
                category: "portMismatch",
                layoutPorts: layoutPorts,
                schematicPorts: schematicPorts,
                suggestedFix: "Align the extracted layout top ports with the schematic top ports.",
                rawLine: [
                    "layout=\(layout.ports.joined(separator: ","))",
                    "schematic=\(schematic.ports.joined(separator: ","))",
                    "globals=\(sharedGlobalNets.sorted().joined(separator: ","))",
                ].joined(separator: " "),
                waiverDisposition: .nonWaivable
            ))
        }
        return diagnostics
    }

    private func loadModelEquivalence(from url: URL?) throws -> [String: String] {
        guard let url else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(LVSModelEquivalencePolicy.self, from: data).canonicalModelMap()
        } catch let error as LVSError {
            throw error
        } catch {
            throw LVSError.invalidInput("Could not load model equivalence policy: \(error.localizedDescription)")
        }
    }

    private func mergedModelEquivalence(
        explicitPolicy: [String: String],
        devicePolicy: [String: String]
    ) throws -> [String: String] {
        var result = explicitPolicy
        for (alias, canonical) in devicePolicy {
            let normalizedAlias = normalizedPolicyName(alias)
            let normalizedCanonical = normalizedPolicyName(canonical)
            guard !normalizedAlias.isEmpty, !normalizedCanonical.isEmpty else {
                continue
            }
            if let existing = result[normalizedAlias], existing != normalizedCanonical {
                throw LVSError.invalidInput(
                    "Device policy model equivalence for \(normalizedAlias) conflicts with explicit model equivalence policy."
                )
            }
            result[normalizedAlias] = normalizedCanonical
        }
        return result
    }

    private func loadTerminalEquivalence(
        from url: URL?,
        devicePolicy: LVSTerminalEquivalencePolicy?
    ) throws -> LVSTerminalEquivalenceResolver {
        do {
            var policies: [LVSTerminalEquivalencePolicy] = [.defaultSPICEPrimitive]
            if let url {
                let data = try Data(contentsOf: url)
                policies.append(try JSONDecoder().decode(LVSTerminalEquivalencePolicy.self, from: data))
            }
            if let devicePolicy {
                policies.append(devicePolicy)
            }
            return try LVSTerminalEquivalenceResolver(policies: policies)
        } catch let error as LVSError {
            throw error
        } catch {
            throw LVSError.invalidInput("Could not load terminal equivalence policy: \(error.localizedDescription)")
        }
    }
}
