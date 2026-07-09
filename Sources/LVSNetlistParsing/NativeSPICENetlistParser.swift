import Foundation
import LVSCore

public struct NativeSPICENetlistParser: Sendable {
    public init() {}

    public func inspectRuntimeCellModels(urls: [URL]) throws -> Set<String> {
        try urls.reduce(into: Set<String>()) { result, url in
            result.formUnion(try inspectRuntimeCellModels(url: url))
        }
    }

    public func inspectRuntimeCellModels(url: URL) throws -> Set<String> {
        let text = try loadNetlistText(url: url, includeStack: [])
        return try inspectRuntimeCellModels(text: text)
    }

    public func inspectRuntimeCellModels(text: String) throws -> Set<String> {
        let lines = normalizedLines(from: text)
        let definitions = try parseSubcircuits(from: lines)
        return try runtimeCellModels(from: lines, definitions: definitions)
    }

    public func parse(
        url: URL,
        expectedTopCell: String,
        blackboxModels: Set<String> = []
    ) throws -> NativeLVSNetlist {
        let text = try loadNetlistText(url: url, includeStack: [])
        return try parse(
            text: text,
            expectedTopCell: expectedTopCell,
            blackboxModels: blackboxModels
        )
    }

    public func parse(
        text: String,
        expectedTopCell: String,
        blackboxModels: Set<String> = []
    ) throws -> NativeLVSNetlist {
        let lines = normalizedLines(from: text)
        let globalNets = Set(parseGlobalNets(from: lines))
        let topLevelParameters = try parseTopLevelParameters(from: lines)
        let options = try parseSPICEOptions(from: lines, parameterMap: topLevelParameters)
        let definitions = try parseSubcircuits(from: lines)
        let runtimeCellModels = try runtimeCellModels(from: lines, definitions: definitions)
        let normalizedBlackboxModels = Set(blackboxModels.map(normalizedModelName))
        let normalizedTopCell = normalizedModelName(expectedTopCell)
        guard let topDefinition = definitions[normalizedTopCell] else {
            throw LVSError.invalidInput("Top cell \(expectedTopCell) was not found")
        }
        let topParameterMap = topLevelParameterMap(
            definition: topDefinition,
            topLevelParameters: topLevelParameters
        )
        let portMap = try makePortMap(
            definition: topDefinition,
            connectedPins: topDefinition.ports,
            instancePath: expectedTopCell
        )
        let flattenedComponents = try flatten(
            definition: topDefinition,
            definitions: definitions,
            instancePath: "",
            portMap: portMap,
            parameterMap: topParameterMap,
            globalNets: globalNets,
            blackboxModels: normalizedBlackboxModels,
            stack: [normalizedTopCell]
        )
        let components = applySPICEOptions(
            to: flattenedComponents,
            options: options
        )
        return NativeLVSNetlist(
            topCell: expectedTopCell,
            ports: topDefinition.ports,
            globalNets: globalNets.sorted(),
            runtimeCellModels: runtimeCellModels.sorted(),
            components: components
        )
    }

    private func loadNetlistText(url: URL, includeStack: [URL]) throws -> String {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        if includeStack.contains(canonicalURL) {
            let chain = (includeStack + [canonicalURL])
                .map { $0.path(percentEncoded: false) }
                .joined(separator: " -> ")
            throw LVSError.invalidInput("Recursive .include detected: \(chain)")
        }
        let text: String
        do {
            text = try String(contentsOf: canonicalURL, encoding: .utf8)
        } catch {
            throw LVSError.invalidInput("Native LVS could not read netlist: \(error.localizedDescription)")
        }
        return try resolveExternalReferences(
            in: text,
            baseURL: canonicalURL.deletingLastPathComponent(),
            includeStack: includeStack + [canonicalURL]
        )
    }

    private func resolveExternalReferences(
        in text: String,
        baseURL: URL,
        includeStack: [URL]
    ) throws -> String {
        var resolvedLines: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let directiveLine = stripInlineComment(from: line)
            if let includePath = try includePath(from: directiveLine) {
                let includeURL = URL(filePath: includePath, relativeTo: baseURL)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                let includedText = try loadNetlistText(url: includeURL, includeStack: includeStack)
                resolvedLines.append(includedText)
                continue
            }
            if let libraryReference = try libraryReference(from: directiveLine) {
                let libraryURL = URL(filePath: libraryReference.path, relativeTo: baseURL)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                let libraryText = try loadLibrarySection(
                    url: libraryURL,
                    sectionName: libraryReference.sectionName,
                    includeStack: includeStack
                )
                resolvedLines.append(libraryText)
                continue
            }
            resolvedLines.append(line)
        }
        return resolvedLines.joined(separator: "\n")
    }

    private func includePath(from line: String) throws -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("*"),
              !trimmed.hasPrefix("//") else {
            return nil
        }
        let tokens = directiveTokens(from: trimmed)
        guard tokens.first?.lowercased() == ".include" else {
            return nil
        }
        guard tokens.count >= 2 else {
            throw LVSError.invalidInput("Invalid .include line: \(line)")
        }
        return tokens[1]
    }

    private func libraryReference(from line: String) throws -> (path: String, sectionName: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("*"),
              !trimmed.hasPrefix("//") else {
            return nil
        }
        let tokens = directiveTokens(from: trimmed)
        guard tokens.first?.lowercased() == ".lib" else {
            return nil
        }
        guard tokens.count >= 3 else {
            throw LVSError.invalidInput("Invalid .lib line: \(line)")
        }
        return (path: tokens[1], sectionName: tokens[2].lowercased())
    }

    private func loadLibrarySection(
        url: URL,
        sectionName: String,
        includeStack: [URL]
    ) throws -> String {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        if includeStack.contains(canonicalURL) {
            let chain = (includeStack + [canonicalURL])
                .map { $0.path(percentEncoded: false) }
                .joined(separator: " -> ")
            throw LVSError.invalidInput("Recursive .lib detected: \(chain)")
        }
        let text: String
        do {
            text = try String(contentsOf: canonicalURL, encoding: .utf8)
        } catch {
            throw LVSError.invalidInput("Native LVS could not read library: \(error.localizedDescription)")
        }
        let section = try extractLibrarySection(
            named: sectionName,
            from: text,
            sourceURL: canonicalURL
        )
        return try resolveExternalReferences(
            in: section,
            baseURL: canonicalURL.deletingLastPathComponent(),
            includeStack: includeStack + [canonicalURL]
        )
    }

    private func extractLibrarySection(
        named sectionName: String,
        from text: String,
        sourceURL: URL
    ) throws -> String {
        let normalizedSectionName = sectionName.lowercased()
        var activeSectionName: String?
        var activeLines: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let tokens = directiveTokens(from: stripInlineComment(from: line))
            if tokens.first?.lowercased() == ".lib", tokens.count == 2 {
                if let activeSectionName {
                    throw LVSError.invalidInput(
                        "Nested .lib section \(tokens[1]) is not supported inside \(activeSectionName)"
                    )
                }
                activeSectionName = tokens[1].lowercased()
                activeLines = []
                continue
            }
            if tokens.first?.lowercased() == ".endl" {
                guard let currentSectionName = activeSectionName else {
                    continue
                }
                let closingSectionName = tokens.dropFirst().first?.lowercased()
                guard closingSectionName == nil || closingSectionName == currentSectionName else {
                    throw LVSError.invalidInput(
                        "Mismatched .endl \(closingSectionName ?? "") for .lib section \(currentSectionName)"
                    )
                }
                if currentSectionName == normalizedSectionName {
                    return activeLines.joined(separator: "\n")
                }
                activeSectionName = nil
                activeLines = []
                continue
            }
            if activeSectionName != nil {
                activeLines.append(line)
            }
        }
        if activeSectionName == normalizedSectionName {
            throw LVSError.invalidInput(
                "Unterminated .lib section \(sectionName) in \(sourceURL.path(percentEncoded: false))"
            )
        }
        throw LVSError.invalidInput(
            ".lib section \(sectionName) was not found in \(sourceURL.path(percentEncoded: false))"
        )
    }

    private func directiveTokens(from line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for character in line {
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func parseGlobalNets(from lines: [String]) -> [String] {
        lines.flatMap { line in
            let tokens = spiceTokens(from: line)
            guard tokens.first?.lowercased() == ".global" else {
                return [String]()
            }
            return tokens.dropFirst().map { $0.lowercased() }
        }
    }

    private func parseTopLevelParameters(from lines: [String]) throws -> [String: String] {
        var inSubcircuit = false
        var parameters: [String: String] = [:]
        for line in lines {
            let tokens = spiceTokens(from: line)
            guard let first = tokens.first else { continue }
            let lowercased = first.lowercased()
            if lowercased == ".subckt" {
                inSubcircuit = true
                continue
            }
            if lowercased == ".ends" {
                inSubcircuit = false
                continue
            }
            guard !inSubcircuit, lowercased == ".param" else {
                continue
            }
            for (name, value) in try parseParameters(Array(tokens.dropFirst()), rawLine: line) {
                parameters[name] = resolveParameterValue(value, parameterMap: parameters)
            }
        }
        return parameters
    }

    private func parseSPICEOptions(
        from lines: [String],
        parameterMap: [String: String]
    ) throws -> SPICENetlistOptions {
        var inSubcircuit = false
        var options = SPICENetlistOptions()
        for line in lines {
            let tokens = spiceTokens(from: line)
            guard let first = tokens.first else { continue }
            let lowercased = first.lowercased()
            if lowercased == ".subckt" {
                inSubcircuit = true
                continue
            }
            if lowercased == ".ends" {
                inSubcircuit = false
                continue
            }
            guard !inSubcircuit,
                  lowercased == ".option" || lowercased == ".options" else {
                continue
            }
            let optionParameters = try parseParameters(Array(tokens.dropFirst()), rawLine: line)
            if let scaleValue = optionParameters["scale"] {
                let resolvedScale = resolveParameterValue(scaleValue, parameterMap: parameterMap)
                guard let scale = SPICEValueNormalizer.numericValue(resolvedScale),
                      scale.isFinite,
                      scale > 0 else {
                    throw LVSError.invalidInput("Invalid SPICE .option scale value: \(scaleValue)")
                }
                options.scale = scale
            }
        }
        return options
    }

    private func parseSubcircuits(from lines: [String]) throws -> [String: SubcircuitDefinition] {
        var definitions: [String: SubcircuitDefinition] = [:]
        var currentName: String?
        var currentPorts: [String] = []
        var currentParameters: [String: String] = [:]
        var currentComponents: [NativeLVSNetlistComponent] = []

        for line in lines {
            let tokens = spiceTokens(from: line)
            guard let first = tokens.first else { continue }
            let lowercased = first.lowercased()

            if lowercased == ".subckt" {
                if let currentName {
                    throw LVSError.invalidInput("Nested .subckt is not supported inside \(currentName)")
                }
                guard tokens.count >= 2 else {
                    throw LVSError.invalidInput("Invalid .subckt line: \(line)")
                }
                currentName = tokens[1]
                let signature = splitSubcircuitSignature(Array(tokens.dropFirst(2)))
                currentPorts = signature.ports
                currentParameters = try parseParameters(signature.parameterTokens, rawLine: line)
                currentComponents = []
                continue
            }
            if lowercased == ".ends" {
                guard let name = currentName else {
                    throw LVSError.invalidInput("Unexpected .ends line: \(line)")
                }
                try validateSubcircuitEnd(tokens: tokens, currentName: name, rawLine: line)
                let normalizedName = normalizedModelName(name)
                if definitions[normalizedName] != nil {
                    throw LVSError.invalidInput("Duplicate .subckt definition for \(name)")
                }
                definitions[normalizedName] = SubcircuitDefinition(
                    name: name,
                    ports: currentPorts,
                    parameters: currentParameters,
                    components: currentComponents
                )
                currentName = nil
                currentPorts = []
                currentParameters = [:]
                currentComponents = []
                continue
            }
            guard currentName != nil else {
                guard first.hasPrefix(".") else {
                    throw LVSError.invalidInput(
                        "Top-level component lines are not supported by native LVS parser: \(line)"
                    )
                }
                guard isSupportedIgnoredDirective(lowercased) else {
                    throw LVSError.invalidInput("Unsupported top-level SPICE directive: \(line)")
                }
                continue
            }
            if first.hasPrefix(".") {
                if lowercased == ".param" {
                    for (name, value) in try parseParameters(Array(tokens.dropFirst()), rawLine: line) {
                        currentParameters[name] = value
                    }
                    continue
                }
                guard isSupportedIgnoredDirective(lowercased) else {
                    throw LVSError.invalidInput("Unsupported SPICE directive in .subckt \(currentName ?? ""): \(line)")
                }
                continue
            }
            currentComponents.append(try parseComponent(tokens: tokens, rawLine: line))
        }

        if let currentName {
            throw LVSError.invalidInput("Unterminated .subckt definition for \(currentName)")
        }
        return definitions
    }

    private func isSupportedIgnoredDirective(_ directive: String) -> Bool {
        switch directive {
        case ".end", ".global", ".param", ".option", ".options", ".model":
            return true
        default:
            return false
        }
    }

    private func validateSubcircuitEnd(
        tokens: [String],
        currentName: String,
        rawLine: String
    ) throws {
        guard let closingName = tokens.dropFirst().first else {
            return
        }
        guard normalizedModelName(closingName) == normalizedModelName(currentName) else {
            throw LVSError.invalidInput(
                "Mismatched .ends \(closingName) for .subckt \(currentName): \(rawLine)"
            )
        }
    }

    private func runtimeCellModels(
        from lines: [String],
        definitions: [String: SubcircuitDefinition]
    ) throws -> Set<String> {
        var models = Set<String>()
        let definedModels = Set(definitions.keys.map(normalizedModelName))
        var inSubcircuit = false
        for line in lines {
            let tokens = spiceTokens(from: line)
            guard let first = tokens.first else { continue }
            let lowercased = first.lowercased()
            if lowercased == ".subckt" {
                inSubcircuit = true
                continue
            }
            if lowercased == ".ends" {
                inSubcircuit = false
                continue
            }
            guard inSubcircuit,
                  first.uppercased().hasPrefix("X") else {
                continue
            }
            let instance = try parseSubcircuitInstance(tokens: tokens, rawLine: line)
            let normalizedModel = normalizedModelName(instance.model)
            if definedModels.contains(normalizedModel) {
                models.insert(normalizedModel)
            }
        }
        return models
    }

    private func topLevelParameterMap(
        definition: SubcircuitDefinition,
        topLevelParameters: [String: String]
    ) -> [String: String] {
        var result = topLevelParameters
        for (name, value) in definition.parameters {
            result[name] = resolveParameterValue(value, parameterMap: result)
        }
        return result
    }

    private func flatten(
        definition: SubcircuitDefinition,
        definitions: [String: SubcircuitDefinition],
        instancePath: String,
        portMap: [String: String],
        parameterMap: [String: String],
        globalNets: Set<String>,
        blackboxModels: Set<String>,
        stack: [String]
    ) throws -> [NativeLVSNetlistComponent] {
        var components: [NativeLVSNetlistComponent] = []
        for component in definition.components {
            let resolvedPins = component.pins.map {
                resolveNet($0, portMap: portMap, instancePath: instancePath, globalNets: globalNets)
            }
            let resolvedName = hierarchicalName(for: component.name, instancePath: instancePath)
            let normalizedComponentModel = normalizedModelName(component.model)
            if component.kind == "subcircuit",
               let childDefinition = definitions[normalizedComponentModel],
               !blackboxModels.contains(normalizedComponentModel) {
                if stack.contains(normalizedComponentModel) {
                    throw LVSError.invalidInput("Recursive .subckt expansion detected: \(stack.joined(separator: " -> ")) -> \(component.model)")
                }
                let childPortMap = try makePortMap(
                    definition: childDefinition,
                    connectedPins: resolvedPins,
                    instancePath: resolvedName
                )
                let childParameterMap = bindParameters(
                    definition: childDefinition,
                    instanceParameters: component.parameters,
                    parentParameterMap: parameterMap
                )
                components.append(contentsOf: try flatten(
                    definition: childDefinition,
                    definitions: definitions,
                    instancePath: resolvedName,
                    portMap: childPortMap,
                    parameterMap: childParameterMap,
                    globalNets: globalNets,
                    blackboxModels: blackboxModels,
                    stack: stack + [normalizedComponentModel]
                ))
            } else {
                components.append(component.resolving(
                    name: resolvedName,
                    pins: resolvedPins,
                    parameters: resolveParameters(component.parameters, parameterMap: parameterMap)
                ))
            }
        }
        return components
    }

    private func makePortMap(
        definition: SubcircuitDefinition,
        connectedPins: [String],
        instancePath: String
    ) throws -> [String: String] {
        guard definition.ports.count == connectedPins.count else {
            throw LVSError.invalidInput(
                "Subcircuit instance \(instancePath) of \(definition.name) has \(connectedPins.count) pins, expected \(definition.ports.count)"
            )
        }
        var portMap: [String: String] = [:]
        for (port, net) in zip(definition.ports, connectedPins) {
            if portMap[port] != nil {
                throw LVSError.invalidInput("Duplicate port \(port) in .subckt \(definition.name)")
            }
            portMap[port] = net
        }
        return portMap
    }

    private func bindParameters(
        definition: SubcircuitDefinition,
        instanceParameters: [String: String],
        parentParameterMap: [String: String]
    ) -> [String: String] {
        var result = resolveParameters(definition.parameters, parameterMap: parentParameterMap)
        for (name, value) in instanceParameters {
            result[name] = resolveParameterValue(value, parameterMap: parentParameterMap)
        }
        return result
    }

    private func resolveParameters(
        _ parameters: [String: String],
        parameterMap: [String: String]
    ) -> [String: String] {
        parameters.reduce(into: [:]) { result, entry in
            result[entry.key] = resolveParameterValue(entry.value, parameterMap: parameterMap)
        }
    }

    private func resolveParameterValue(_ value: String, parameterMap: [String: String]) -> String {
        let normalized = value.lowercased()
        if let direct = parameterMap[normalized] {
            return direct
        }
        let wrappedExpression = isWrappedExpression(normalized)
        let expression = unwrappedExpression(normalized)
        if expression != normalized, let mapped = parameterMap[expression] {
            return mapped
        }
        guard shouldEvaluateParameterExpression(expression, isWrapped: wrappedExpression),
              let evaluated = SPICEExpressionEvaluator.evaluate(expression, parameters: parameterMap) else {
            return normalized
        }
        return SPICEValueNormalizer.canonicalize(evaluated)
    }

    private func isWrappedExpression(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") && trimmed.hasSuffix("}")
    }

    private func shouldEvaluateParameterExpression(_ expression: String, isWrapped: Bool) -> Bool {
        if isWrapped {
            return true
        }
        return containsArithmeticOperator(expression)
    }

    private func containsArithmeticOperator(_ expression: String) -> Bool {
        var previousNonWhitespace: Character?
        for character in expression {
            if character.isWhitespace {
                continue
            }
            if character == "*" || character == "/" || character == "(" || character == ")" {
                return true
            }
            if character == "+" || character == "-" {
                if previousNonWhitespace == nil {
                    previousNonWhitespace = character
                    continue
                }
                if previousNonWhitespace == "e" {
                    previousNonWhitespace = character
                    continue
                }
                if let previous = previousNonWhitespace,
                   previous == "+"
                    || previous == "-"
                    || previous == "*"
                    || previous == "/"
                    || previous == "("
                    || previous == "{" {
                    previousNonWhitespace = character
                    continue
                }
                return true
            }
            previousNonWhitespace = character
        }
        return false
    }

    private func unwrappedExpression(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveNet(
        _ net: String,
        portMap: [String: String],
        instancePath: String,
        globalNets: Set<String>
    ) -> String {
        if let resolved = portMap[net] {
            if globalNets.contains(resolved.lowercased()) {
                return resolved.lowercased()
            }
            return resolved
        }
        if globalNets.contains(net.lowercased()) {
            return net.lowercased()
        }
        guard !instancePath.isEmpty else {
            return net
        }
        return "\(instancePath)/\(net)"
    }

    private func normalizedModelName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func applySPICEOptions(
        to components: [NativeLVSNetlistComponent],
        options: SPICENetlistOptions
    ) -> [NativeLVSNetlistComponent] {
        guard options.scale != 1 else {
            return components
        }
        return components.map { component in
            let scaledParameters = component.parameters.reduce(into: [String: String]()) { result, entry in
                guard let scaleExponent = scaleExponent(
                    forParameter: entry.key,
                    componentKind: component.kind
                ),
                      let value = SPICEValueNormalizer.numericValue(entry.value) else {
                    result[entry.key] = entry.value
                    return
                }
                result[entry.key] = SPICEValueNormalizer.canonicalize(
                    value * pow(options.scale, scaleExponent)
                )
            }
            return component.resolving(
                name: component.name,
                pins: component.pins,
                parameters: scaledParameters
            )
        }
    }

    private func scaleExponent(
        forParameter parameterName: String,
        componentKind: String
    ) -> Double? {
        let normalizedName = parameterName.lowercased()
        switch componentKind {
        case "mos", "resistor", "capacitor":
            if ["w", "l", "pd", "ps", "sa", "sb", "sd"].contains(normalizedName) {
                return 1
            }
            if ["ad", "as"].contains(normalizedName) {
                return 2
            }
            return nil
        default:
            return nil
        }
    }

    private func hierarchicalName(for name: String, instancePath: String) -> String {
        guard !instancePath.isEmpty else {
            return name
        }
        return "\(instancePath)/\(name)"
    }

    private func splitSubcircuitSignature(_ tokens: [String]) -> (ports: [String], parameterTokens: [String]) {
        guard let parameterStart = tokens.firstIndex(where: isParameterToken) else {
            return (tokens, [])
        }
        return (Array(tokens[..<parameterStart]), Array(tokens[parameterStart...]))
    }

    private func normalizedLines(from text: String) -> [String] {
        var result: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = stripInlineComment(from: String(rawLine))
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("*"),
                  !trimmed.hasPrefix("//") else {
                continue
            }
            if trimmed.hasPrefix("+"), let last = result.indices.last {
                result[last] += " " + trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                result.append(String(trimmed))
            }
        }
        return result
    }

    private func stripInlineComment(from line: String) -> String {
        var inSingleQuote = false
        var inDoubleQuote = false
        var previousWasBoundary = true
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
                previousWasBoundary = false
                index = line.index(after: index)
                continue
            }
            if character == "'", !inDoubleQuote {
                inSingleQuote.toggle()
                previousWasBoundary = false
                index = line.index(after: index)
                continue
            }

            if !inSingleQuote, !inDoubleQuote {
                if character == "$", previousWasBoundary {
                    return String(line[..<index])
                }
                if character == "/", previousWasBoundary {
                    let nextIndex = line.index(after: index)
                    if nextIndex < line.endIndex, line[nextIndex] == "/" {
                        return String(line[..<index])
                    }
                }
            }

            previousWasBoundary = character.isWhitespace
            index = line.index(after: index)
        }

        return line
    }

    private func spiceTokens(from line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var braceDepth = 0
        var parenthesisDepth = 0
        for character in line {
            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
                continue
            }
            if character == "{" {
                braceDepth += 1
                current.append(character)
                continue
            }
            if character == "}" {
                braceDepth = max(0, braceDepth - 1)
                current.append(character)
                continue
            }
            if character == "(" {
                parenthesisDepth += 1
                current.append(character)
                continue
            }
            if character == ")" {
                parenthesisDepth = max(0, parenthesisDepth - 1)
                current.append(character)
                continue
            }
            if character.isWhitespace, braceDepth == 0, parenthesisDepth == 0 {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func parseComponent(tokens: [String], rawLine: String) throws -> NativeLVSNetlistComponent {
        guard let name = tokens.first,
              let prefix = name.first else {
            throw LVSError.invalidInput("Invalid component line: \(rawLine)")
        }
        switch prefix.uppercased() {
        case "M":
            guard tokens.count >= 6 else {
                throw LVSError.invalidInput("Invalid MOS component line: \(rawLine)")
            }
            return NativeLVSNetlistComponent(
                name: name,
                kind: "mos",
                pins: Array(tokens[1...4]),
                model: tokens[5],
                parameters: try parseParameters(Array(tokens.dropFirst(6)), rawLine: rawLine)
            )
        case "R":
            return try parseTwoTerminalPassiveComponent(
                tokens: tokens,
                rawLine: rawLine,
                kind: "resistor"
            )
        case "C":
            return try parseTwoTerminalPassiveComponent(
                tokens: tokens,
                rawLine: rawLine,
                kind: "capacitor"
            )
        case "L":
            return try parseTwoTerminalPassiveComponent(
                tokens: tokens,
                rawLine: rawLine,
                kind: "inductor"
            )
        case "D":
            guard tokens.count >= 4 else {
                throw LVSError.invalidInput("Invalid diode component line: \(rawLine)")
            }
            return NativeLVSNetlistComponent(
                name: name,
                kind: "diode",
                pins: Array(tokens[1...2]),
                model: tokens[3],
                parameters: try parseParameters(Array(tokens.dropFirst(4)), rawLine: rawLine)
            )
        case "Q":
            guard tokens.count >= 5 else {
                throw LVSError.invalidInput("Invalid BJT component line: \(rawLine)")
            }
            let modelIndex: Int
            if tokens.count >= 6, !isParameterToken(tokens[5]) {
                modelIndex = 5
            } else {
                modelIndex = 4
            }
            return NativeLVSNetlistComponent(
                name: name,
                kind: "bjt",
                pins: Array(tokens[1..<modelIndex]),
                model: tokens[modelIndex],
                parameters: try parseParameters(Array(tokens.dropFirst(modelIndex + 1)), rawLine: rawLine)
            )
        case "V":
            return try parseIndependentSourceComponent(
                tokens: tokens,
                rawLine: rawLine,
                kind: "voltage-source"
            )
        case "I":
            return try parseIndependentSourceComponent(
                tokens: tokens,
                rawLine: rawLine,
                kind: "current-source"
            )
        case "E":
            return try parseVoltageControlledSourceComponent(
                tokens: tokens,
                rawLine: rawLine,
                kind: "vcvs"
            )
        case "G":
            return try parseVoltageControlledSourceComponent(
                tokens: tokens,
                rawLine: rawLine,
                kind: "vccs"
            )
        case "F":
            return try parseCurrentControlledSourceComponent(
                tokens: tokens,
                rawLine: rawLine,
                kind: "cccs"
            )
        case "H":
            return try parseCurrentControlledSourceComponent(
                tokens: tokens,
                rawLine: rawLine,
                kind: "ccvs"
            )
        case "X":
            guard tokens.count >= 3 else {
                throw LVSError.invalidInput("Invalid subcircuit instance line: \(rawLine)")
            }
            let instance = try parseSubcircuitInstance(tokens: tokens, rawLine: rawLine)
            return NativeLVSNetlistComponent(
                name: name,
                kind: "subcircuit",
                pins: instance.pins,
                model: instance.model,
                parameters: instance.parameters
            )
        default:
            throw LVSError.invalidInput("Unsupported component prefix \(prefix) in line: \(rawLine)")
        }
    }

    private func parseTwoTerminalPassiveComponent(
        tokens: [String],
        rawLine: String,
        kind: String
    ) throws -> NativeLVSNetlistComponent {
        guard let name = tokens.first, tokens.count >= 4 else {
            throw LVSError.invalidInput("Invalid \(kind) component line: \(rawLine)")
        }
        var model = tokens[3]
        var parameterStart = 4
        var parameters: [String: String] = [:]
        if tokens.count > 4, !isParameterToken(tokens[4]) {
            model = tokens[4]
            parameters["value"] = tokens[3]
            parameterStart = 5
        }
        parameters.merge(try parseParameters(Array(tokens.dropFirst(parameterStart)), rawLine: rawLine)) { _, new in new }
        return NativeLVSNetlistComponent(
            name: name,
            kind: kind,
            pins: Array(tokens[1...2]),
            model: model,
            parameters: parameters
        )
    }

    private func parseIndependentSourceComponent(
        tokens: [String],
        rawLine: String,
        kind: String
    ) throws -> NativeLVSNetlistComponent {
        guard let name = tokens.first, tokens.count >= 4 else {
            throw LVSError.invalidInput("Invalid independent source line: \(rawLine)")
        }
        let source = try parseIndependentSourceSpec(Array(tokens.dropFirst(3)), rawLine: rawLine)
        return NativeLVSNetlistComponent(
            name: name,
            kind: kind,
            pins: Array(tokens[1...2]),
            model: source.model,
            parameters: source.parameters
        )
    }

    private func parseIndependentSourceSpec(
        _ tokens: [String],
        rawLine: String
    ) throws -> (model: String, parameters: [String: String]) {
        guard let first = tokens.first else {
            return (model: "dc", parameters: [:])
        }
        let normalizedFirst = first.lowercased()
        if isParameterToken(first) {
            return try normalizeIndependentSourceParameters(parseParameters(tokens, rawLine: rawLine))
        }
        if normalizedFirst == "dc" || normalizedFirst == "ac" {
            var parameters = try parseParameters(Array(tokens.dropFirst(2)), rawLine: rawLine)
            if tokens.count >= 2 {
                parameters["value"] = tokens[1].lowercased()
            }
            return (model: normalizedFirst, parameters: parameters)
        }
        if isFunctionalSourceToken(normalizedFirst) {
            return (
                model: functionalSourceModel(normalizedFirst),
                parameters: ["spec": tokens.joined(separator: " ").lowercased()]
            )
        }
        var parameters = try parseParameters(Array(tokens.dropFirst()), rawLine: rawLine)
        parameters["value"] = normalizedFirst
        return (model: "dc", parameters: parameters)
    }

    private func normalizeIndependentSourceParameters(
        _ parameters: [String: String]
    ) -> (model: String, parameters: [String: String]) {
        var normalized = parameters
        if let value = normalized.removeValue(forKey: "dc") {
            normalized["value"] = value
            return (model: "dc", parameters: normalized)
        }
        if let value = normalized.removeValue(forKey: "ac") {
            normalized["value"] = value
            return (model: "ac", parameters: normalized)
        }
        return (model: "source", parameters: normalized)
    }

    private func parseVoltageControlledSourceComponent(
        tokens: [String],
        rawLine: String,
        kind: String
    ) throws -> NativeLVSNetlistComponent {
        guard let name = tokens.first, tokens.count >= 6 else {
            throw LVSError.invalidInput("Invalid voltage-controlled source line: \(rawLine)")
        }
        return NativeLVSNetlistComponent(
            name: name,
            kind: kind,
            pins: Array(tokens[1...4]),
            model: kind,
            parameters: try parseControlledSourceGain(Array(tokens.dropFirst(5)), rawLine: rawLine)
        )
    }

    private func parseCurrentControlledSourceComponent(
        tokens: [String],
        rawLine: String,
        kind: String
    ) throws -> NativeLVSNetlistComponent {
        guard let name = tokens.first, tokens.count >= 5 else {
            throw LVSError.invalidInput("Invalid current-controlled source line: \(rawLine)")
        }
        return NativeLVSNetlistComponent(
            name: name,
            kind: kind,
            pins: Array(tokens[1...2]),
            model: tokens[3],
            parameters: try parseControlledSourceGain(Array(tokens.dropFirst(4)), rawLine: rawLine)
        )
    }

    private func parseControlledSourceGain(_ tokens: [String], rawLine: String) throws -> [String: String] {
        guard let first = tokens.first else {
            return [:]
        }
        if isParameterToken(first) {
            return try normalizeControlledSourceParameters(parseParameters(tokens, rawLine: rawLine))
        }
        var parameters = try parseParameters(Array(tokens.dropFirst()), rawLine: rawLine)
        parameters["gain"] = first.lowercased()
        return parameters
    }

    private func normalizeControlledSourceParameters(_ parameters: [String: String]) -> [String: String] {
        var normalized = parameters
        if normalized["gain"] == nil, let value = normalized.removeValue(forKey: "value") {
            normalized["gain"] = value
        }
        return normalized
    }

    private func isFunctionalSourceToken(_ token: String) -> Bool {
        ["pulse", "pwl", "sin", "exp", "sffm", "am"].contains { token.hasPrefix($0) }
    }

    private func functionalSourceModel(_ token: String) -> String {
        guard let start = token.firstIndex(of: "(") else {
            return token
        }
        return String(token[..<start])
    }

    private func parseSubcircuitInstance(
        tokens: [String],
        rawLine: String
    ) throws -> (pins: [String], model: String, parameters: [String: String]) {
        var parameterStart = tokens.endIndex
        while parameterStart > tokens.index(after: tokens.startIndex) {
            let previous = tokens.index(before: parameterStart)
            guard isParameterToken(tokens[previous]) else {
                break
            }
            parameterStart = previous
        }
        let modelIndex = tokens.index(before: parameterStart)
        guard modelIndex > tokens.startIndex else {
            throw LVSError.invalidInput("Invalid subcircuit instance line: \(rawLine)")
        }
        let pins = Array(tokens[tokens.index(after: tokens.startIndex)..<modelIndex])
        guard !pins.isEmpty else {
            throw LVSError.invalidInput("Subcircuit instance has no connected pins: \(rawLine)")
        }
        return (
            pins: pins,
            model: tokens[modelIndex],
            parameters: try parseParameters(Array(tokens[parameterStart..<tokens.endIndex]), rawLine: rawLine)
        )
    }

    private func parseParameters(_ tokens: [String], rawLine: String) throws -> [String: String] {
        try tokens.reduce(into: [:]) { parameters, token in
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw LVSError.invalidInput("Unsupported SPICE parameter token '\(token)' in line: \(rawLine)")
            }
            parameters[parts[0].lowercased()] = parts[1].lowercased()
        }
    }

    private func isParameterToken(_ token: String) -> Bool {
        token.contains("=")
    }

    private struct SubcircuitDefinition: Sendable, Hashable {
        let name: String
        let ports: [String]
        let parameters: [String: String]
        let components: [NativeLVSNetlistComponent]
    }

    private struct SPICENetlistOptions: Sendable, Hashable {
        var scale: Double = 1
    }
}
