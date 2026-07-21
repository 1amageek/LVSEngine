import CircuiteFoundation
import Foundation
import LVSCore
import LVSGraph
import LVSMatching
import LVSNetlistParsing
import LayoutCore
import LayoutIO
import LayoutLVSExtraction
import LayoutTech

/// Native LVS on standard mask inputs: devices are extracted
/// in-process (channel recognition, connectivity, and label-driven net
/// naming) and compared against a `.subckt` schematic reference. No
/// external extractor is involved; Magic/Netgen remain available as the
/// independent oracle backend.
private struct ExtractedSPICENetID: Sendable, Hashable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

private enum ExtractedSPICETerminalRole: String, Sendable, Hashable {
    case drain
    case gate
    case source
    case bulk
}

private struct ExtractedSPICEProjection: Sendable {
    struct Parameters: Sendable {
        let width: Double
        let length: Double
        let multiplier: Double
    }

    struct Device: Sendable {
        let id: String
        let model: String
        let terminals: [ExtractedSPICETerminalRole: ExtractedSPICENetID]
        let parameters: Parameters
        let region: LayoutRect
    }

    let devices: [Device]
    let ports: [String: ExtractedSPICENetID]
}

public struct LayoutGDSLVSBackend: LVSCancellableBackend {
    public let backendID = "native-gds"

    public init() {}

    public func run(_ request: LVSRequest) async throws -> LVSExecutionResult {
        try await run(request, cancellationCheck: nil)
    }

    public func run(
        _ request: LVSRequest,
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> LVSExecutionResult {
        let startedAt = Date()
        let inputArtifacts = try LVSExecutionProvenance.captureInputArtifacts(for: request)
        try await checkCancellation(cancellationCheck)
        guard let layoutGDSURL = request.layoutGDSURL else {
            throw LVSError.invalidInput("The GDS backend needs layoutGDSURL.")
        }
        guard let technologyURL = request.technologyURL else {
            throw LVSError.invalidInput(
                "The GDS backend needs a technology database (technologyURL: LayoutTechDatabase JSON)."
            )
        }
        let tech: LayoutTechDatabase
        do {
            tech = try JSONDecoder().decode(
                LayoutTechDatabase.self,
                from: try Data(contentsOf: technologyURL)
            )
        } catch {
            throw LVSError.invalidInput(
                "Could not load technology database '\(technologyURL.lastPathComponent)': \(error.localizedDescription)"
            )
        }

        let document: LayoutDocument
        do {
            document = try Self.loadDocument(
                from: layoutGDSURL,
                format: request.layoutFormat,
                tech: tech
            )
        } catch {
            throw LVSError.invalidInput(
                "Could not read layout '\(layoutGDSURL.lastPathComponent)': \(error.localizedDescription)"
            )
        }
        let topCell = try Self.resolveTopCell(
            in: document,
            requestedTopCell: request.topCell,
            format: request.layoutFormat,
            layoutURL: layoutGDSURL
        )
        try await checkCancellation(cancellationCheck)

        let schematicText: String
        do {
            schematicText = try String(contentsOf: request.schematicNetlistURL, encoding: .utf8)
        } catch {
            throw LVSError.invalidInput(
                "Could not read schematic reference '\(request.schematicNetlistURL.lastPathComponent)': \(error.localizedDescription)"
            )
        }

        let extractionProfile = try Self.extractionProfile(for: request)
        let extractionIR: LayoutExtractionIR
        do {
            extractionIR = try LayoutGeometryExtractor().extract(
                document: document,
                technology: tech,
                topCellID: topCell.id,
                profile: extractionProfile,
                maximumObjectCount: request.options.effectiveMaximumGraphObjectCount
            )
        } catch {
            throw LVSError.backendFailed(
                "Device extraction failed: \(error.localizedDescription)"
            )
        }
        try await checkCancellation(cancellationCheck)
        let extractionArtifacts = try Self.persistExtractionArtifacts(
            extractionIR,
            request: request
        )

        var diagnostics: [LVSDiagnostic] = extractionIR.issues.map { issue in
            LVSDiagnostic(
                severity: .error,
                message: issue.message,
                ruleID: "extraction.\(issue.code)",
                rawLine: issue.affectedObjectIDs.map(\.rawValue).joined(separator: ","),
                waiverDisposition: .nonWaivable
            )
        }

        if request.devicePolicyURL != nil {
            return try await runPolicyAwareComparison(
                request: request,
                technologyURL: technologyURL,
                schematicText: schematicText,
                document: document,
                topCell: topCell,
                extractionIR: extractionIR,
                extractionReportURL: extractionArtifacts.reportURL,
                transformLedgerURL: extractionArtifacts.transformLedgerURL,
                extractionDiagnostics: diagnostics,
                inputArtifacts: inputArtifacts,
                cancellationCheck: cancellationCheck
            )
        }

        let graphMatch: LVSGraphMatchResult?
        if extractionIR.isReady {
            let schematicNetlist = try NativeSPICENetlistParser().parse(
                url: request.schematicNetlistURL,
                expectedTopCell: request.topCell
            )
            let layoutGraph = try LayoutExtractionLVSGraphBuilder().build(
                from: extractionIR,
                maximumObjectCount: request.options.effectiveMaximumGraphObjectCount,
                sharedGlobalNetNames: Set(schematicNetlist.globalNets)
            )
            let terminalEquivalence = try LVSTerminalEquivalenceResolver.defaultSPICEPrimitive()
            var modelKinds: [String: String] = [:]
            for device in extractionIR.devices {
                modelKinds[device.model.lowercased()] = device.family.lowercased()
            }
            let schematicGraph = try NativeLVSGraphBuilder().build(
                netlist: schematicNetlist,
                modelEquivalence: [:],
                terminalEquivalence: terminalEquivalence,
                parameterPolicy: .empty,
                modelKinds: modelKinds,
                maximumObjectCount: request.options.effectiveMaximumGraphObjectCount,
                sharedGlobalNetNames: Set(schematicNetlist.globalNets)
            )
            graphMatch = try LVSGraphMatcher().match(
                layout: layoutGraph,
                schematic: schematicGraph,
                budget: LVSMatchBudget(
                    maximumSearchStates: request.options.effectiveMaximumSearchStates,
                    maximumDurationSeconds: request.options.timeoutSeconds
                )
            )
        } else {
            graphMatch = nil
        }
        try await checkCancellation(cancellationCheck)

        if graphMatch?.status == .mismatched {
            if graphMatch?.reasonCodes.contains("port_set_mismatch") == true {
                diagnostics.append(LVSDiagnostic(
                    severity: .error,
                    message: "Top-level layout and schematic port sets differ.",
                    ruleID: "LVS_PORT_MISMATCH",
                    category: "portMismatch",
                    layoutPorts: extractionIR.ports.map(\.name).sorted(),
                    schematicPorts: try NativeSPICENetlistParser().parse(
                        url: request.schematicNetlistURL,
                        expectedTopCell: request.topCell
                    ).ports.sorted(),
                    suggestedFix: "Align the extracted layout top-port set with the schematic interface.",
                    rawLine: "reasons=port_set_mismatch",
                    waiverDisposition: .nonWaivable
                ))
            } else if graphMatch?.reasonCodes.contains("device_parameter_mismatch") == true {
                diagnostics.append(LVSDiagnostic(
                    severity: .error,
                    message: "Extracted and schematic device parameters differ.",
                    ruleID: "LVS_PARAMETER_MISMATCH",
                    category: "parameterMismatch",
                    suggestedFix: "Inspect mapped devices and source-linked extracted parameters.",
                    rawLine: "reasons=device_parameter_mismatch"
                ))
            } else if graphMatch?.reasonCodes.contains("device_semantics_mismatch") == true {
                diagnostics.append(LVSDiagnostic(
                    severity: .error,
                    message: "Extracted and schematic device kinds or models differ.",
                    ruleID: "LVS_DEVICE_SEMANTICS_MISMATCH",
                    category: "deviceSemanticsMismatch",
                    suggestedFix: "Inspect device recognition rules, model equivalence, and correspondence.",
                    rawLine: "reasons=device_semantics_mismatch"
                ))
            } else {
                diagnostics.append(LVSDiagnostic(
                    severity: .error,
                    message: "Canonical layout and schematic graphs are not isomorphic.",
                    ruleID: "LVS_GRAPH_MISMATCH",
                    category: "graphMismatch",
                    suggestedFix: "Inspect the retained correspondence and graph mismatch reasons.",
                    rawLine: "reasons=\(graphMatch?.reasonCodes.joined(separator: ",") ?? "unknown")"
                ))
            }
        } else if graphMatch?.status == .blocked {
            diagnostics.append(LVSDiagnostic(
                severity: .error,
                message: "Canonical graph matching exceeded its bounded execution budget.",
                ruleID: "LVS_GRAPH_MATCH_BLOCKED",
                category: "matcherReadiness",
                suggestedFix: "Inspect graph ambiguity before changing the bounded search budget.",
                rawLine: "reasons=\(graphMatch?.reasonCodes.joined(separator: ",") ?? "unknown")",
                waiverDisposition: .nonWaivable
            ))
        }
        if diagnostics.isEmpty, graphMatch?.status == .matched {
            diagnostics.append(LVSDiagnostic(
                severity: .info,
                message: "Layout matches schematic: \(extractionIR.devices.count) device(s).",
                ruleID: "graph.match",
                rawLine: "match"
            ))
        }

        var logPath = ""
        if let workingDirectory = request.workingDirectory {
            let logURL = workingDirectory.appending(path: "lvs-native-gds-\(UUID().uuidString).log")
            let log = diagnostics.map { "\($0.severity): \($0.message)" }
                .joined(separator: "\n") + "\n"
            try FileManager.default.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true
            )
            try log.write(to: logURL, atomically: true, encoding: .utf8)
            logPath = logURL.path(percentEncoded: false)
        }

        var blockingReasons = extractionIR.isReady ? [] : [LVSBlockingReason(
            code: "layout_extraction_incomplete",
            message: "Layout extraction emitted one or more unresolved issues."
        )]
        if graphMatch?.status == .blocked {
            blockingReasons.append(contentsOf: graphMatch?.reasonCodes.map {
                LVSBlockingReason(
                    code: $0,
                    message: "Canonical graph matching could not establish a verdict."
                )
            } ?? [])
        }
        let verdict: LVSVerificationVerdict
        if !blockingReasons.isEmpty {
            verdict = .blocked
        } else if graphMatch?.status == .matched {
            verdict = .match
        } else {
            verdict = .mismatch
        }
        let result = LVSResult(
            backendID: backendID,
            toolName: "LayoutLVSExtraction",
            executionStatus: .completed,
            verdict: verdict,
            readiness: blockingReasons.isEmpty ? .ready : .blocked,
            blockingReasons: blockingReasons,
            logPath: logPath,
            diagnostics: diagnostics,
            provenance: LVSToolProvenance(
                executablePath: "in-process",
                pdkRoot: technologyURL.path(percentEncoded: false),
                setupFilePath: "not-applicable",
                driverScriptPath: "not-applicable",
                timeoutSeconds: request.options.timeoutSeconds
            )
        )
        return LVSExecutionResult(
            request: request,
            result: result,
            correspondence: enrichedCorrespondence(
                graphMatch?.correspondence,
                extraction: extractionIR
            ),
            extractionReportURL: extractionArtifacts.reportURL,
            transformLedgerURL: extractionArtifacts.transformLedgerURL,
            extractionEvidence: Self.extractionEvidence(for: extractionIR),
            provenance: try LVSExecutionProvenance.make(
                request: request,
                result: result,
                inputArtifacts: inputArtifacts,
                invocation: ExecutionInvocation.inProcess(
                    entryPoint: "LayoutGDSLVSBackend.run"
                ),
                startedAt: startedAt,
                completedAt: Date()
            )
        )
    }

    private func runPolicyAwareComparison(
        request: LVSRequest,
        technologyURL: URL,
        schematicText: String,
        document: LayoutDocument,
        topCell: LayoutCell,
        extractionIR: LayoutExtractionIR,
        extractionReportURL: URL?,
        transformLedgerURL: URL?,
        extractionDiagnostics: [LVSDiagnostic],
        inputArtifacts: [ArtifactReference],
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> LVSExecutionResult {
        let schematicTop = try Self.schematicTopCell(in: schematicText, preferredName: request.topCell)
        let devicePolicySeed = try Self.loadDevicePolicySeed(from: request.devicePolicyURL)
        let extractedNetlistURL = try Self.writeExtractedLayoutNetlist(
            try Self.comparisonNetlist(
                from: extractionIR,
                schematicPorts: schematicTop.ports
            ),
            topCell: schematicTop.name,
            schematicPorts: schematicTop.ports,
            document: document,
            layoutTopCell: topCell,
            schematicText: schematicText,
            devicePolicySeed: devicePolicySeed,
            request: request
        )
        let comparisonRequest = LVSRequest(
            layoutNetlistURL: extractedNetlistURL,
            layoutGDSURL: request.layoutGDSURL,
            layoutFormat: request.layoutFormat,
            schematicNetlistURL: request.schematicNetlistURL,
            topCell: schematicTop.name,
            technologyURL: request.technologyURL,
            extractionProfileURL: request.extractionProfileURL,
            extractionDeckURL: request.extractionDeckURL,
            processProfileID: request.processProfileID,
            waiverURL: request.waiverURL,
            modelEquivalenceURL: request.modelEquivalenceURL,
            terminalEquivalenceURL: request.terminalEquivalenceURL,
            devicePolicyURL: request.devicePolicyURL,
            workingDirectory: request.workingDirectory,
            backendSelection: LVSBackendSelection(backendID: "native"),
            options: request.options,
            executionInputArtifacts: request.executionInputArtifacts
        )
        let comparison = try await NativeLVSBackend().run(
            comparisonRequest,
            cancellationCheck: cancellationCheck
        )
        let diagnostics = extractionDiagnostics + comparison.result.diagnostics
        let logPath = try Self.writeLog(
            diagnostics: diagnostics,
            request: request,
            prefix: "lvs-native-gds-policy"
        ) ?? comparison.result.logPath
        let extractionBlockingReasons = extractionDiagnostics.isEmpty ? [] : [LVSBlockingReason(
            code: "layout_extraction_incomplete",
            message: "Layout extraction emitted one or more unresolved issues."
        )]
        let combinedBlockingReasons = extractionBlockingReasons + comparison.result.blockingReasons
        let result = LVSResult(
            backendID: backendID,
            toolName: "LayoutLVSExtraction+NativeLVS",
            executionStatus: comparison.result.executionStatus,
            verdict: extractionBlockingReasons.isEmpty ? comparison.result.verdict : .blocked,
            readiness: combinedBlockingReasons.isEmpty ? comparison.result.readiness : .blocked,
            blockingReasons: combinedBlockingReasons,
            logPath: logPath,
            diagnostics: diagnostics,
            provenance: LVSToolProvenance(
                executablePath: "in-process",
                pdkRoot: technologyURL.path(percentEncoded: false),
                setupFilePath: "not-applicable",
                driverScriptPath: "native-gds extracted SPICE -> NativeLVS",
                timeoutSeconds: request.options.timeoutSeconds
            )
        )
        let provenance = try LVSExecutionProvenance.make(
            request: request,
            result: result,
            inputArtifacts: inputArtifacts,
            invocation: ExecutionInvocation.inProcess(
                entryPoint: "LayoutGDSLVSBackend.runPolicyAwareComparison"
            ),
            startedAt: comparison.provenance.startedAt,
            completedAt: Date()
        )
        let extractedNetlist = try LocalArtifactReferencer().reference(
            ArtifactLocator(
                location: ArtifactLocation(fileURL: extractedNetlistURL),
                role: .output,
                kind: .netlist,
                format: .spice
            ),
            producer: provenance.producer
        )
        return LVSExecutionResult(
            request: request,
            result: result,
            extractedLayoutNetlistURL: extractedNetlistURL,
            devicePolicyReport: comparison.devicePolicyReport,
            correspondence: enrichedCorrespondence(
                comparison.correspondence,
                extraction: extractionIR
            ),
            extractionReportURL: extractionReportURL,
            transformLedgerURL: transformLedgerURL,
            extractionEvidence: LVSExtractionEvidence(
                processProfileID: extractionIR.processProfileID,
                deckDigest: extractionIR.extractionDeckDigest,
                semanticReady: extractionIR.isReady,
                blockingReasonCodes: extractionIR.isReady
                    ? []
                    : ["extraction_semantics_incomplete"]
            ),
            layoutNetlistExtraction: LVSLayoutNetlistExtractionResult(
                netlist: extractedNetlist,
                provenance: provenance
            ),
            provenance: provenance
        )
    }

    private static func extractionEvidence(
        for extraction: LayoutExtractionIR
    ) -> LVSExtractionEvidence {
        LVSExtractionEvidence(
            processProfileID: extraction.processProfileID,
            deckDigest: extraction.extractionDeckDigest,
            semanticReady: extraction.isReady,
            blockingReasonCodes: extraction.isReady
                ? []
                : ["extraction_semantics_incomplete"]
        )
    }

    private static func comparisonNetlist(
        from extraction: LayoutExtractionIR,
        schematicPorts: [String]
    ) throws -> ExtractedSPICEProjection {
        guard extraction.isReady else {
            throw LVSError.invalidInput("Layout extraction contains blocking issues.")
        }
        let nets = Dictionary(uniqueKeysWithValues: extraction.nets.map {
            ($0.id, ExtractedSPICENetID($0.preferredName ?? $0.id.rawValue))
        })
        let devices = try extraction.devices.map { device -> ExtractedSPICEProjection.Device in
            guard device.family.lowercased() == "mosfet" else {
                throw LVSError.invalidInput(
                    "Policy-aware SPICE projection does not support extracted family '\(device.family)'."
                )
            }
            var terminals: [ExtractedSPICETerminalRole: ExtractedSPICENetID] = [:]
            for terminal in device.terminals {
                guard let roleName = terminal.role,
                      let role = ExtractedSPICETerminalRole(rawValue: roleName.lowercased()),
                      let net = nets[terminal.netID] else {
                    throw LVSError.invalidInput(
                        "Extracted device \(device.id.rawValue) has an unresolved terminal."
                    )
                }
                terminals[role] = net
            }
            guard let width = extractedMicronParameter("w", from: device),
                  let length = extractedMicronParameter("l", from: device) else {
                throw LVSError.invalidInput(
                    "Extracted device \(device.id.rawValue) is missing W/L geometry."
                )
            }
            let regions = device.geometryReferences.map(\.bounds)
            guard let firstRegion = regions.first else {
                throw LVSError.invalidInput(
                    "Extracted device \(device.id.rawValue) has no source geometry."
                )
            }
            return ExtractedSPICEProjection.Device(
                id: device.id.rawValue,
                model: device.model,
                terminals: terminals,
                parameters: ExtractedSPICEProjection.Parameters(
                    width: width,
                    length: length,
                    multiplier: extractedScalarParameter("m", from: device) ?? 1
                ),
                region: regions.dropFirst().reduce(firstRegion) { $0.union($1) }
            )
        }
        let ports = try Dictionary(uniqueKeysWithValues: schematicPorts.map { schematicPortName in
            let candidates = extraction.ports.filter {
                canonicalPortName($0.name) == canonicalPortName(schematicPortName)
            }
            guard candidates.count == 1, let port = candidates.first else {
                throw LVSError.invalidInput(
                    "Schematic port \(schematicPortName) does not resolve to exactly one extracted net label."
                )
            }
            guard let net = nets[port.netID] else {
                throw LVSError.invalidInput(
                    "Extracted port \(port.name) references an unknown net."
                )
            }
            return (schematicPortName, net)
        })
        return ExtractedSPICEProjection(devices: devices, ports: ports)
    }

    private static func canonicalPortName(_ name: String) -> String {
        let normalized = name.lowercased()
        return normalized.hasPrefix("pin_") ? String(normalized.dropFirst(4)) : normalized
    }

    private static func extractedMicronParameter(
        _ name: String,
        from device: LayoutExtractionDevice
    ) -> Double? {
        if let parameter = device.typedParameters.first(where: { $0.name.lowercased() == name }) {
            return Double(parameter.canonicalValue)
        }
        guard let rawValue = device.parameters.first(where: { $0.key.lowercased() == name })?.value,
              let value = SPICEValueNormalizer.numericValue(rawValue) else {
            return nil
        }
        return rawValue.lowercased().hasSuffix("u") ? value * 1_000_000 : value
    }

    private static func extractedScalarParameter(
        _ name: String,
        from device: LayoutExtractionDevice
    ) -> Double? {
        if let parameter = device.typedParameters.first(where: { $0.name.lowercased() == name }) {
            return Double(parameter.canonicalValue)
        }
        guard let rawValue = device.parameters.first(where: { $0.key.lowercased() == name })?.value else {
            return nil
        }
        return SPICEValueNormalizer.numericValue(rawValue)
    }

    private static func persistExtractionArtifacts(
        _ extraction: LayoutExtractionIR,
        request: LVSRequest
    ) throws -> (reportURL: URL?, transformLedgerURL: URL?) {
        guard let directory = request.workingDirectory else {
            return (nil, nil)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reportURL = directory.appending(path: "lvs-extraction-report.json")
        let transformLedgerURL = directory.appending(path: "lvs-transform-ledger.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(extraction).write(to: reportURL, options: [.atomic])
        try encoder.encode(extraction.transformLedger).write(
            to: transformLedgerURL,
            options: [.atomic]
        )
        return (reportURL, transformLedgerURL)
    }

    private func enrichedCorrespondence(
        _ correspondence: LVSCorrespondence?,
        extraction: LayoutExtractionIR
    ) -> LVSCorrespondence? {
        guard let correspondence else { return nil }
        let deviceReferences = extraction.devices.flatMap { device in
            sourceReferences(
                objectID: LVSObjectID(rawValue: "layout:\(device.id.rawValue)"),
                sourceKind: "layout-device-geometry",
                geometryReferences: device.geometryReferences
            )
        }
        let netReferences = extraction.nets.flatMap { net in
            sourceReferences(
                objectID: LVSObjectID(rawValue: "layout:\(net.id.rawValue)"),
                sourceKind: "layout-net-geometry",
                geometryReferences: net.geometryReferences
            )
        }
        return LVSCorrespondence(
            deviceMappings: correspondence.deviceMappings,
            netMappings: correspondence.netMappings,
            portMappings: correspondence.portMappings,
            unmatchedLayoutObjectIDs: correspondence.unmatchedLayoutObjectIDs,
            unmatchedSchematicObjectIDs: correspondence.unmatchedSchematicObjectIDs,
            ambiguousLayoutObjectIDs: correspondence.ambiguousLayoutObjectIDs,
            layoutSourceReferences: deviceReferences + netReferences
        )
    }

    private func sourceReferences(
        objectID: LVSObjectID,
        sourceKind: String,
        geometryReferences: [LayoutExtractionGeometryReference]
    ) -> [LVSSourceReference] {
        geometryReferences.map { reference in
            LVSSourceReference(
                objectID: objectID,
                sourceKind: sourceKind,
                sourceObjectID: reference.sourceObjectID,
                occurrenceID: reference.occurrenceID.rawValue,
                attributes: [
                    "layer": reference.layer.name,
                    "purpose": reference.layer.purpose,
                    "minX": "\(reference.bounds.minX)",
                    "minY": "\(reference.bounds.minY)",
                    "maxX": "\(reference.bounds.maxX)",
                    "maxY": "\(reference.bounds.maxY)",
                ]
            )
        }
    }

    private func checkCancellation(_ cancellationCheck: LVSExecutionCancellationCheck?) async throws {
        do {
            try Task.checkCancellation()
        } catch {
            throw LVSError.cancelled("Native GDS LVS task was cancelled.")
        }
        if try await cancellationCheck?() == true {
            throw LVSError.cancelled("Native GDS LVS cancellation was requested.")
        }
    }

    private static func loadDocument(
        from url: URL,
        format: LVSLayoutFormat?,
        tech: LayoutTechDatabase
    ) throws -> LayoutDocument {
        let converter = MaskDataFormatConverter(tech: tech)
        switch format ?? .auto {
        case .auto:
            let data = try Data(contentsOf: url)
            return try converter.importFromData(data)
        case .gds:
            return try converter.importDocument(from: url, format: .gds)
        case .oasis:
            return try converter.importDocument(from: url, format: .oasis)
        case .cif:
            return try converter.importDocument(from: url, format: .cif)
        case .dxf:
            return try converter.importDocument(from: url, format: .dxf)
        }
    }

    private static func extractionProfile(
        for request: LVSRequest
    ) throws -> LayoutExtractionProcessProfile {
        guard let profileURL = request.extractionProfileURL else {
            throw LayoutExtractionProcessProfileError.missingProfileArtifact(
                path: "LVSRequest.extractionProfileURL"
            )
        }
        guard let extractionDeckURL = request.extractionDeckURL else {
            throw LayoutExtractionProcessProfileError.missingExtractionDeck(
                path: "LVSRequest.extractionDeckURL"
            )
        }
        return try LayoutExtractionProcessProfileLoader().load(
            profileURL: profileURL,
            extractionDeckURL: extractionDeckURL,
            expectedProcessProfileID: request.processProfileID
        )
    }

    private static func schematicTopCell(
        in text: String,
        preferredName: String
    ) throws -> (name: String, ports: [String]) {
        let requestedName = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else {
            throw LVSError.invalidInput("Top cell name is required for policy-aware native GDS LVS.")
        }
        let normalizedRequestedName = normalizePolicyToken(requestedName)
        var availableSubcircuitNames: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine
                .split(separator: "$", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2,
                  tokens[0].lowercased() == ".subckt" else {
                continue
            }
            let signature = tokens.dropFirst(2).prefix { token in
                !token.contains("=")
            }
            let subcircuit = (name: tokens[1], ports: Array(signature))
            availableSubcircuitNames.append(subcircuit.name)
            if normalizePolicyToken(subcircuit.name) == normalizedRequestedName {
                return subcircuit
            }
        }
        guard !availableSubcircuitNames.isEmpty else {
            throw LVSError.invalidInput("Schematic reference does not contain a .subckt definition.")
        }
        throw LVSError.invalidInput(
            "Schematic reference does not contain requested top cell '\(requestedName)' "
                + "(available: \(availableSubcircuitNames.joined(separator: ", ")))."
        )
    }

    private static func writeExtractedLayoutNetlist(
        _ netlist: ExtractedSPICEProjection,
        topCell: String,
        schematicPorts: [String],
        document: LayoutDocument,
        layoutTopCell: LayoutCell,
        schematicText: String,
        devicePolicySeed: NetgenLVSDevicePolicySeed?,
        request: LVSRequest
    ) throws -> URL {
        let directory = request.workingDirectory ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "lvs-native-gds-extracted-\(UUID().uuidString).spice")
        let geometryEncoding = try geometryEncoding(
            for: netlist,
            schematicText: schematicText,
            topCell: topCell
        )
        let text = writeBlackboxBoundarySPICE(
            netlist: netlist,
            document: document,
            topCell: layoutTopCell,
            schematicText: schematicText,
            topSubcircuitName: topCell,
            topPorts: schematicPorts,
            devicePolicySeed: devicePolicySeed,
            geometryEncoding: geometryEncoding
        ) ?? writeSPICE(
            netlist,
            name: topCell,
            orderedPorts: schematicPorts,
            geometryEncoding: geometryEncoding
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private struct BlackboxBoundaryInstance {
        var name: String
        var model: String
        var pins: [String]
        var region: LayoutRect
    }

    private static func writeBlackboxBoundarySPICE(
        netlist: ExtractedSPICEProjection,
        document: LayoutDocument,
        topCell: LayoutCell,
        schematicText: String,
        topSubcircuitName: String,
        topPorts: [String],
        devicePolicySeed: NetgenLVSDevicePolicySeed?,
        geometryEncoding: SPICEGeometryEncoding
    ) -> String? {
        guard let devicePolicySeed else { return nil }
        let schematicSubcircuits = schematicSubcircuitPorts(in: schematicText)
        let runtimeCellModels = schematicRuntimeCellModels(
            in: schematicText,
            knownSubcircuits: Set(schematicSubcircuits.keys)
        )
        let blackboxModels = blackboxModelNames(
            from: devicePolicySeed,
            runtimeCellModels: runtimeCellModels
        )
        guard !blackboxModels.isEmpty, !topCell.instances.isEmpty else { return nil }
        var instances: [BlackboxBoundaryInstance] = []
        for (index, instance) in topCell.instances.enumerated() {
            guard let child = document.cell(withID: instance.cellID) else { return nil }
            let normalizedModel = normalizePolicyToken(child.name)
            guard blackboxModels.contains(normalizedModel) else {
                continue
            }
            guard let modelPorts = schematicSubcircuits[normalizedModel],
                  let pins = blackboxPins(for: child, modelPorts: modelPorts),
                  let region = transformedCellBoundingBox(child, transform: instance.transform) else { return nil }
            let instanceName = sanitizeSPICEToken(instance.name.isEmpty ? "X\(index)" : instance.name)
            instances.append(BlackboxBoundaryInstance(
                name: instanceName.uppercased().hasPrefix("X") ? instanceName : "X\(instanceName)",
                model: child.name,
                pins: pins,
                region: region
            ))
        }
        guard !instances.isEmpty else { return nil }

        let blackboxRegions = instances.map(\.region)
        let filteredNetlist = ExtractedSPICEProjection(
            devices: netlist.devices.filter { device in
                !blackboxRegions.contains { regionContains(device.region, in: $0) }
            },
            ports: netlist.ports
        )
        var lines = writeSPICE(
            filteredNetlist,
            name: topSubcircuitName,
            orderedPorts: topPorts,
            geometryEncoding: geometryEncoding
        )
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        guard let topEndsIndex = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == ".ends"
        }) else {
            return nil
        }
        var topInstanceLines: [String] = []
        for instance in instances {
            topInstanceLines.append("\(instance.name) \(instance.pins.joined(separator: " ")) \(sanitizeSPICEToken(instance.model))")
        }
        lines.insert(contentsOf: topInstanceLines, at: topEndsIndex)
        var emittedModels: Set<String> = []
        for instance in instances {
            let modelName = sanitizeSPICEToken(instance.model)
            guard emittedModels.insert(modelName).inserted else {
                continue
            }
            let modelPorts = schematicSubcircuits[normalizePolicyToken(instance.model)] ?? instance.pins
            lines.append(".subckt \(modelName) \(modelPorts.map(sanitizeSPICEToken).joined(separator: " "))")
            lines.append(".ends")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func transformedCellBoundingBox(_ cell: LayoutCell, transform: LayoutTransform) -> LayoutRect? {
        var bounds: LayoutRect?

        func include(_ rect: LayoutRect) {
            bounds = bounds.map { $0.union(rect) } ?? rect
        }

        for shape in cell.shapes {
            include(LayoutGeometryAnalysis.boundingBox(for: shape.geometry))
        }
        for via in cell.vias {
            include(LayoutRect(origin: via.position, size: LayoutSize(width: 0, height: 0)))
        }
        for pin in cell.pins {
            include(LayoutRect(origin: pin.position, size: LayoutSize(width: 0, height: 0)))
        }
        for label in cell.labels {
            include(LayoutRect(origin: label.position, size: LayoutSize(width: 0, height: 0)))
        }
        guard let bounds else { return nil }
        return transformBoundingBox(bounds, by: transform)
    }

    private static func transformBoundingBox(_ rect: LayoutRect, by transform: LayoutTransform) -> LayoutRect {
        let points = [
            LayoutPoint(x: rect.minX, y: rect.minY),
            LayoutPoint(x: rect.maxX, y: rect.minY),
            LayoutPoint(x: rect.maxX, y: rect.maxY),
            LayoutPoint(x: rect.minX, y: rect.maxY),
        ].map { transform.apply(to: $0) }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private static func regionContains(_ inner: LayoutRect, in outer: LayoutRect) -> Bool {
        let expanded = outer.expanded(by: 1e-6, 1e-6)
        return expanded.contains(LayoutPoint(x: inner.minX, y: inner.minY))
            && expanded.contains(LayoutPoint(x: inner.maxX, y: inner.minY))
            && expanded.contains(LayoutPoint(x: inner.maxX, y: inner.maxY))
            && expanded.contains(LayoutPoint(x: inner.minX, y: inner.maxY))
    }

    private static func blackboxPins(for cell: LayoutCell, modelPorts: [String]) -> [String]? {
        let labelTokens = Set(cell.labels.map { sanitizeSPICEToken($0.text) })
        let pins = modelPorts.map(sanitizeSPICEToken)
        guard pins.allSatisfy(labelTokens.contains) else { return nil }
        return pins
    }

    private static func schematicSubcircuitPorts(in text: String) -> [String: [String]] {
        var subcircuits: [String: [String]] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine
                .split(separator: "$", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2, tokens[0].lowercased() == ".subckt" else {
                continue
            }
            var ports: [String] = []
            var index = tokens.index(tokens.startIndex, offsetBy: 2)
            while index < tokens.endIndex, !tokens[index].contains("=") {
                ports.append(tokens[index])
                index = tokens.index(after: index)
            }
            subcircuits[normalizePolicyToken(tokens[1])] = ports
        }
        return subcircuits
    }

    private static func schematicRuntimeCellModels(
        in text: String,
        knownSubcircuits: Set<String>
    ) -> Set<String> {
        var models: Set<String> = []
        var inSubcircuit = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine
                .split(separator: "$", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let firstToken = tokens.first else {
                continue
            }
            let lowercasedFirstToken = firstToken.lowercased()
            if lowercasedFirstToken == ".subckt" {
                inSubcircuit = true
                continue
            }
            if lowercasedFirstToken == ".ends" {
                inSubcircuit = false
                continue
            }
            guard inSubcircuit,
                  firstToken.uppercased().hasPrefix("X"),
                  let modelToken = subcircuitInstanceModelToken(in: tokens) else {
                continue
            }
            let normalizedModel = normalizePolicyToken(modelToken)
            if knownSubcircuits.contains(normalizedModel) {
                models.insert(normalizedModel)
            }
        }
        return models
    }

    private static func subcircuitInstanceModelToken(in tokens: [String]) -> String? {
        guard tokens.count >= 2 else {
            return nil
        }
        let positionalTokens: ArraySlice<String>
        if let firstParameterIndex = tokens.firstIndex(where: { $0.contains("=") }) {
            positionalTokens = tokens[..<firstParameterIndex]
        } else {
            positionalTokens = tokens[...]
        }
        guard positionalTokens.count >= 2 else {
            return nil
        }
        return positionalTokens.last
    }

    private static func blackboxModelNames(
        from seed: NetgenLVSDevicePolicySeed,
        runtimeCellModels: Set<String>
    ) -> Set<String> {
        var models: Set<String> = []
        for rule in seed.policyRules {
            let tokens = flattenedPolicyTokens(in: rule.arguments)
            let lowercased = Set(tokens.map { $0.lowercased() })
            guard rule.kind == "blackbox" || (rule.kind == "property" && lowercased.contains("blackbox")) else {
                continue
            }
            if usesRuntimeCellSelector(in: tokens) {
                models.formUnion(runtimeCellModels)
            }
            for token in tokens where isPolicyModelToken(token) {
                models.insert(normalizePolicyToken(token))
            }
        }
        return models
    }

    private static func usesRuntimeCellSelector(in tokens: [String]) -> Bool {
        tokens.contains { token in
            token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'{}")).lowercased() == "$cell"
        }
    }

    private static func flattenedPolicyTokens(in arguments: [String]) -> [String] {
        arguments.flatMap { argument in
            argument
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" || $0 == "}" || $0 == "\"" || $0 == "'" })
                .map(String.init)
        }
    }

    private static func isPolicyModelToken(_ token: String) -> Bool {
        let value = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'{}")).lowercased()
        return !value.isEmpty
            && !value.hasPrefix("-")
            && !value.contains("$")
            && value != "model"
            && value != "blackbox"
            && value != "default"
            && value != "pins"
            && value != "enable"
            && value != "add"
            && value != "critical"
            && value != "delete"
            && value != "tolerance"
            && value != "parallel"
            && value != "series"
    }

    private static func normalizePolicyToken(_ value: String) -> String {
        sanitizeSPICEToken(value).lowercased()
    }

    private static func loadDevicePolicySeed(from url: URL?) throws -> NetgenLVSDevicePolicySeed? {
        guard let url else { return nil }
        do {
            return try JSONDecoder().decode(NetgenLVSDevicePolicySeed.self, from: try Data(contentsOf: url))
        } catch {
            throw LVSError.invalidInput(
                "Could not read device policy seed '\(url.lastPathComponent)': \(error.localizedDescription)"
            )
        }
    }

    private static func writeSPICE(
        _ netlist: ExtractedSPICEProjection,
        name: String,
        orderedPorts: [String],
        geometryEncoding: SPICEGeometryEncoding = .micronSuffix
    ) -> String {
        var tokens: [ExtractedSPICENetID: String] = [:]
        var used: Set<String> = []
        func token(_ net: ExtractedSPICENetID) -> String {
            if let existing = tokens[net] { return existing }
            var sanitized = String(net.rawValue.map { character in
                character.isLetter || character.isNumber || character == "_" ? character : "_"
            })
            if sanitized.isEmpty || (sanitized.first?.isNumber ?? false) {
                sanitized = "n" + sanitized
            }
            var candidate = sanitized
            var counter = 1
            while used.contains(candidate) {
                candidate = "\(sanitized)_\(counter)"
                counter += 1
            }
            used.insert(candidate)
            tokens[net] = candidate
            return candidate
        }

        var portTokens: [String] = []
        var seenPortTokens: Set<String> = []
        for portName in orderedPorts {
            let portToken = sanitizeSPICEToken(portName)
            if let net = netlist.ports[portName] {
                tokens[net] = portToken
                used.insert(portToken)
            }
            if seenPortTokens.insert(portToken).inserted {
                portTokens.append(portToken)
            }
        }
        var lines = [".subckt \(name) \(portTokens.joined(separator: " "))"]
        for (index, device) in netlist.devices
            .sorted(by: { $0.id < $1.id })
            .enumerated() {
            let model = sanitizeSPICEToken(device.model)
            let drain = device.terminals[.drain].map(token) ?? "unconnected_d\(index)"
            let gate = device.terminals[.gate].map(token) ?? "unconnected_g\(index)"
            let source = device.terminals[.source].map(token) ?? "unconnected_s\(index)"
            let bulk = device.terminals[.bulk].map(token) ?? "unconnected_b\(index)"
            lines.append(
                "M\(index) \(drain) \(gate) \(source) \(bulk) \(model) "
                    + "W=\(formatSPICEValue(device.parameters.width))\(geometryEncoding.suffix) "
                    + "L=\(formatSPICEValue(device.parameters.length))\(geometryEncoding.suffix) "
                    + "M=\(device.parameters.multiplier)"
            )
        }
        lines.append(".ends")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private enum SPICEGeometryEncoding: Sendable {
        case dimensionlessMicrons
        case micronSuffix

        var suffix: String {
            switch self {
            case .dimensionlessMicrons: ""
            case .micronSuffix: "u"
            }
        }
    }

    private static func geometryEncoding(
        for netlist: ExtractedSPICEProjection,
        schematicText: String,
        topCell: String
    ) throws -> SPICEGeometryEncoding {
        let schematic = try NativeSPICENetlistParser().parse(
            text: schematicText,
            expectedTopCell: topCell
        )
        var dimensionlessScore = 0.0
        var micronSuffixScore = 0.0
        var observationCount = 0
        for device in netlist.devices {
            let model = normalizePolicyToken(device.model)
            let candidates = schematic.components.filter {
                normalizePolicyToken($0.model) == model
            }
            for (parameterName, extractedValue) in [
                ("w", device.parameters.width),
                ("l", device.parameters.length),
            ] {
                let schematicValues = candidates.compactMap { component -> Double? in
                    guard let value = component.parameters[parameterName] else { return nil }
                    return SPICEValueNormalizer.numericValue(value)
                }
                guard !schematicValues.isEmpty else { continue }
                dimensionlessScore += schematicValues.map {
                    logarithmicDistance(extractedValue, $0)
                }.min() ?? 0
                micronSuffixScore += schematicValues.map {
                    logarithmicDistance(extractedValue * 1e-6, $0)
                }.min() ?? 0
                observationCount += 1
            }
        }
        guard observationCount > 0 else { return .micronSuffix }
        return dimensionlessScore < micronSuffixScore
            ? .dimensionlessMicrons
            : .micronSuffix
    }

    private static func logarithmicDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let minimumMagnitude = Double.leastNormalMagnitude
        let left = max(abs(lhs), minimumMagnitude)
        let right = max(abs(rhs), minimumMagnitude)
        return abs(log10(left / right))
    }

    private static func formatSPICEValue(_ value: Double) -> String {
        String(format: "%.6g", value)
    }

    private static func sanitizeSPICEToken(_ value: String) -> String {
        var sanitized = String(value.map { character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        })
        if sanitized.isEmpty || (sanitized.first?.isNumber ?? false) {
            sanitized = "n" + sanitized
        }
        return sanitized
    }

    private static func writeLog(
        diagnostics: [LVSDiagnostic],
        request: LVSRequest,
        prefix: String
    ) throws -> String? {
        guard let workingDirectory = request.workingDirectory else {
            return nil
        }
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        let logURL = workingDirectory.appending(path: "\(prefix)-\(UUID().uuidString).log")
        let log = diagnostics.map { "\($0.severity): \($0.message)" }
            .joined(separator: "\n") + "\n"
        try log.write(to: logURL, atomically: true, encoding: .utf8)
        return logURL.path(percentEncoded: false)
    }

    private static func resolveTopCell(
        in document: LayoutDocument,
        requestedTopCell: String,
        format: LVSLayoutFormat?,
        layoutURL: URL
    ) throws -> LayoutCell {
        if let topCell = document.cells.first(where: { $0.name == requestedTopCell }) {
            return topCell
        }
        if allowsSingleCellNameFallback(format: format, layoutURL: layoutURL) {
            if let topCellID = document.topCellID,
               let topCell = document.cell(withID: topCellID) {
                return topCell
            }
            if document.cells.count == 1,
               let topCell = document.cells.first {
                return topCell
            }
        }
        throw LVSError.invalidInput(
            "Top cell '\(requestedTopCell)' is not in the layout (cells: \(document.cells.map(\.name).joined(separator: ", ")))."
        )
    }

    private static func allowsSingleCellNameFallback(format: LVSLayoutFormat?, layoutURL: URL) -> Bool {
        switch format ?? inferredFormat(from: layoutURL) {
        case .cif, .dxf:
            return true
        case .auto, .gds, .oasis, .none:
            return false
        }
    }

    private static func inferredFormat(from url: URL) -> LVSLayoutFormat? {
        switch url.pathExtension.lowercased() {
        case "cif":
            return .cif
        case "dxf":
            return .dxf
        default:
            return nil
        }
    }
}
