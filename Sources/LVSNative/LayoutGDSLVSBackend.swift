import Foundation
import LVSCore
import LayoutCore
import LayoutIO
import LayoutTech
import LayoutVerify

/// Native LVS on standard mask inputs: devices are extracted
/// in-process (channel recognition, connectivity, and label-driven net
/// naming) and compared against a `.subckt` schematic reference. No
/// external extractor is involved; Magic/Netgen remain available as the
/// independent oracle backend.
public struct LayoutGDSLVSBackend: LVSBackend {
    public let backendID = "native-gds"

    public init() {}

    public func run(_ request: LVSRequest) async throws -> LVSExecutionResult {
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

        let schematicText: String
        do {
            schematicText = try String(contentsOf: request.schematicNetlistURL, encoding: .utf8)
        } catch {
            throw LVSError.invalidInput(
                "Could not read schematic reference '\(request.schematicNetlistURL.lastPathComponent)': \(error.localizedDescription)"
            )
        }

        let extraction: DeviceExtractionResult
        do {
            extraction = try DeviceExtractor().extract(
                document: document,
                tech: tech,
                cellID: topCell.id
            )
        } catch {
            throw LVSError.backendFailed(
                "Device extraction failed: \(error.localizedDescription)"
            )
        }

        var diagnostics: [LVSDiagnostic] = extraction.issues.map { issue in
            LVSDiagnostic(
                severity: .error,
                message: issue.message,
                ruleID: "extraction.\(issue.kind)",
                rawLine: "\(issue.kind) @ (\(issue.region.origin.x), \(issue.region.origin.y))"
            )
        }

        if request.devicePolicyURL != nil {
            return try await runPolicyAwareComparison(
                request: request,
                technologyURL: technologyURL,
                schematicText: schematicText,
                document: document,
                topCell: topCell,
                extraction: extraction,
                extractionDiagnostics: diagnostics
            )
        }

        let reference: ComparisonNetlist
        do {
            reference = try SPICESubcktReader().read(schematicText)
        } catch {
            throw LVSError.invalidInput(
                "Could not read schematic reference '\(request.schematicNetlistURL.lastPathComponent)': \(error.localizedDescription)"
            )
        }

        let comparison = NetlistComparator().compare(
            extracted: extraction.netlist,
            reference: reference
        )
        for device in comparison.unmatchedExtractedDevices {
            diagnostics.append(LVSDiagnostic(
                severity: .error,
                message: "Layout device \(device.id) (\(device.kind)) has no schematic counterpart.",
                ruleID: "compare.unmatchedExtracted",
                rawLine: Self.deviceRawLine(device)
            ))
        }
        for device in comparison.unmatchedReferenceDevices {
            diagnostics.append(LVSDiagnostic(
                severity: .error,
                message: "Schematic device \(device.id) (\(device.kind)) is not realized in the layout.",
                ruleID: "compare.unmatchedReference",
                rawLine: Self.deviceRawLine(device)
            ))
        }
        for mismatch in comparison.parameterMismatches {
            diagnostics.append(LVSDiagnostic(
                severity: .error,
                message: "Parameter mismatch \(mismatch.extractedDeviceID) vs \(mismatch.referenceDeviceID): extracted \(mismatch.extracted), reference \(mismatch.reference).",
                ruleID: "compare.parameterMismatch",
                rawLine: "\(mismatch.extractedDeviceID)/\(mismatch.referenceDeviceID)"
            ))
        }
        if diagnostics.isEmpty {
            diagnostics.append(LVSDiagnostic(
                severity: .info,
                message: "Layout matches schematic: \(comparison.referenceDeviceCount) device(s).",
                ruleID: "compare.match",
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

        // `success` means the comparison RAN; the verdict lives in the
        // diagnostics (LVSResult.passed folds both).
        let result = LVSResult(
            backendID: backendID,
            toolName: "LayoutVerify",
            success: true,
            completed: true,
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
        return LVSExecutionResult(request: request, result: result)
    }

    private func runPolicyAwareComparison(
        request: LVSRequest,
        technologyURL: URL,
        schematicText: String,
        document: LayoutDocument,
        topCell: LayoutCell,
        extraction: DeviceExtractionResult,
        extractionDiagnostics: [LVSDiagnostic]
    ) async throws -> LVSExecutionResult {
        let schematicTop = try Self.schematicTopCell(in: schematicText, preferredName: request.topCell)
        let devicePolicySeed = try Self.loadDevicePolicySeed(from: request.devicePolicyURL)
        let extractedNetlistURL = try Self.writeExtractedLayoutNetlist(
            extraction.netlist,
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
            waiverURL: request.waiverURL,
            modelEquivalenceURL: request.modelEquivalenceURL,
            terminalEquivalenceURL: request.terminalEquivalenceURL,
            devicePolicyURL: request.devicePolicyURL,
            workingDirectory: request.workingDirectory,
            backendSelection: LVSBackendSelection(backendID: "native"),
            options: request.options
        )
        let comparison = try await NativeLVSBackend().run(comparisonRequest)
        let diagnostics = extractionDiagnostics + comparison.result.diagnostics
        let logPath = try Self.writeLog(
            diagnostics: diagnostics,
            request: request,
            prefix: "lvs-native-gds-policy"
        ) ?? comparison.result.logPath
        let result = LVSResult(
            backendID: backendID,
            toolName: "LayoutVerify+NativeLVS",
            success: comparison.result.success,
            completed: comparison.result.completed,
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
        return LVSExecutionResult(
            request: request,
            result: result,
            extractedLayoutNetlistURL: extractedNetlistURL,
            devicePolicyReport: comparison.devicePolicyReport
        )
    }

    private static func deviceRawLine(_ device: ComparisonNetlist.Device) -> String {
        let terminals = ComparisonTerminalRole.allCases
            .compactMap { role in
                device.terminals[role].map { "\(role.rawValue)=\($0.rawValue)" }
            }
            .joined(separator: ",")
        return [
            "id=\(device.id)",
            "kind=\(device.kind.rawValue)",
            "terminals=\(terminals)",
            "w=\(device.parameters.width)",
            "l=\(device.parameters.length)",
            "m=\(device.parameters.multiplier)",
        ].joined(separator: " ")
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
        _ netlist: ComparisonNetlist,
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
        let text = writeBlackboxBoundarySPICE(
            netlist: netlist,
            document: document,
            topCell: layoutTopCell,
            schematicText: schematicText,
            topSubcircuitName: topCell,
            topPorts: schematicPorts,
            devicePolicySeed: devicePolicySeed
        ) ?? writeSPICE(netlist, name: topCell, orderedPorts: schematicPorts)
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
        netlist: ComparisonNetlist,
        document: LayoutDocument,
        topCell: LayoutCell,
        schematicText: String,
        topSubcircuitName: String,
        topPorts: [String],
        devicePolicySeed: NetgenLVSDevicePolicySeed?
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
        let filteredNetlist = ComparisonNetlist(
            devices: netlist.devices.filter { device in
                !blackboxRegions.contains { regionContains(device.region, in: $0) }
            },
            ports: netlist.ports
        )
        var lines = writeSPICE(filteredNetlist, name: topSubcircuitName, orderedPorts: topPorts)
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
        _ netlist: ComparisonNetlist,
        name: String,
        orderedPorts: [String]
    ) -> String {
        var tokens: [ComparisonNetID: String] = [:]
        var used: Set<String> = []
        func token(_ net: ComparisonNetID) -> String {
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
            let model: String
            switch device.kind {
            case .nmos: model = "nmos"
            case .pmos: model = "pmos"
            }
            let drain = device.terminals[.drain].map(token) ?? "unconnected_d\(index)"
            let gate = device.terminals[.gate].map(token) ?? "unconnected_g\(index)"
            let source = device.terminals[.source].map(token) ?? "unconnected_s\(index)"
            let bulk = device.terminals[.bulk].map(token) ?? "unconnected_b\(index)"
            lines.append(
                "M\(index) \(drain) \(gate) \(source) \(bulk) \(model) "
                    + "W=\(formatSPICEValue(device.parameters.width))u "
                    + "L=\(formatSPICEValue(device.parameters.length))u "
                    + "M=\(device.parameters.multiplier)"
            )
        }
        lines.append(".ends")
        lines.append("")
        return lines.joined(separator: "\n")
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
