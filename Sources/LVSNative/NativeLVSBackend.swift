import Foundation
import LVSCore
@_exported import LVSNetlistParsing

public struct NativeLVSBackend: LVSBackend {
    public let backendID = "native"
    private let parser: NativeSPICENetlistParser

    public init(parser: NativeSPICENetlistParser = NativeSPICENetlistParser()) {
        self.parser = parser
    }

    public func run(_ request: LVSRequest) async throws -> LVSExecutionResult {
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
        var diagnostics = compare(
            layout: layout,
            schematic: schematic,
            modelEquivalence: modelEquivalence,
            terminalEquivalence: terminalEquivalence,
            parameterPolicy: devicePolicy.parameterPolicy
        )
        diagnostics.append(contentsOf: devicePolicy.diagnostics)
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
            success: true,
            completed: true,
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
            devicePolicyReport: devicePolicy.report
        )
    }

    private func compare(
        layout: NativeLVSNetlist,
        schematic: NativeLVSNetlist,
        modelEquivalence: [String: String],
        terminalEquivalence: LVSTerminalEquivalenceResolver,
        parameterPolicy: LVSParameterComparisonPolicy
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
                ].joined(separator: " ")
            ))
        }

        diagnostics.append(contentsOf: compareComponents(
            layout: layout.components,
            schematic: schematic.components,
            modelEquivalence: modelEquivalence,
            terminalEquivalence: terminalEquivalence,
            parameterPolicy: parameterPolicy
        ))
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
