import Foundation

public enum NetgenLVSDeviceDeckImportStatus: String, Codable, Sendable, Hashable {
    case complete
    case partial
    case blocked
}

public struct NetgenLVSDeviceDescriptor: Codable, Sendable, Hashable {
    public let deviceName: String
    public let family: String
    public let sourceLineNumber: Int
    public let sourceLine: String

    public init(
        deviceName: String,
        family: String,
        sourceLineNumber: Int,
        sourceLine: String
    ) {
        self.deviceName = deviceName
        self.family = family
        self.sourceLineNumber = sourceLineNumber
        self.sourceLine = sourceLine
    }
}

public struct NetgenLVSPolicyRule: Codable, Sendable, Hashable {
    public let kind: String
    public let arguments: [String]
    public let sourceLineNumber: Int
    public let sourceLine: String

    public init(
        kind: String,
        arguments: [String],
        sourceLineNumber: Int,
        sourceLine: String
    ) {
        self.kind = kind
        self.arguments = arguments
        self.sourceLineNumber = sourceLineNumber
        self.sourceLine = sourceLine
    }
}

public struct NetgenLVSDevicePolicySeed: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let kind: String
    public let generatedAt: String
    public let sourcePath: String
    public let devices: [NetgenLVSDeviceDescriptor]
    public let policyRules: [NetgenLVSPolicyRule]

    public init(
        schemaVersion: Int = 1,
        kind: String = "lvs-device-policy-seed",
        generatedAt: String,
        sourcePath: String,
        devices: [NetgenLVSDeviceDescriptor],
        policyRules: [NetgenLVSPolicyRule]
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.generatedAt = generatedAt
        self.sourcePath = sourcePath
        self.devices = devices
        self.policyRules = policyRules
    }
}

public struct NetgenLVSDeviceDeckImportDiagnostic: Codable, Sendable, Hashable {
    public let code: String
    public let message: String
    public let sourceLineNumber: Int?
    public let sourceLine: String?

    public init(
        code: String,
        message: String,
        sourceLineNumber: Int? = nil,
        sourceLine: String? = nil
    ) {
        self.code = code
        self.message = message
        self.sourceLineNumber = sourceLineNumber
        self.sourceLine = sourceLine
    }
}

public struct NetgenLVSDeviceDeckImportReport: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let kind: String
    public let generatedAt: String
    public let status: NetgenLVSDeviceDeckImportStatus
    public let sourcePath: String
    public let supportedFamilies: [String]
    public let importedDeviceCount: Int
    public let importedPolicyRuleCount: Int
    public let skippedLineCount: Int
    public let deviceFamilyCounts: [String: Int]
    public let policyRuleCounts: [String: Int]
    public let diagnostics: [NetgenLVSDeviceDeckImportDiagnostic]

    public init(
        schemaVersion: Int = 1,
        kind: String = "lvs-foundry-device-deck-import",
        generatedAt: String,
        status: NetgenLVSDeviceDeckImportStatus,
        sourcePath: String,
        supportedFamilies: [String],
        importedDeviceCount: Int,
        importedPolicyRuleCount: Int,
        skippedLineCount: Int,
        deviceFamilyCounts: [String: Int],
        policyRuleCounts: [String: Int],
        diagnostics: [NetgenLVSDeviceDeckImportDiagnostic]
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.generatedAt = generatedAt
        self.status = status
        self.sourcePath = sourcePath
        self.supportedFamilies = supportedFamilies
        self.importedDeviceCount = importedDeviceCount
        self.importedPolicyRuleCount = importedPolicyRuleCount
        self.skippedLineCount = skippedLineCount
        self.deviceFamilyCounts = deviceFamilyCounts
        self.policyRuleCounts = policyRuleCounts
        self.diagnostics = diagnostics
    }
}

public struct NetgenLVSDeviceDeckImport: Sendable, Hashable {
    public let seed: NetgenLVSDevicePolicySeed
    public let report: NetgenLVSDeviceDeckImportReport

    public init(
        seed: NetgenLVSDevicePolicySeed,
        report: NetgenLVSDeviceDeckImportReport
    ) {
        self.seed = seed
        self.report = report
    }
}

public enum NetgenLVSDeviceDeckImporter {
    public static func importDeviceDeck(
        from setupURL: URL,
        generatedAt: String? = nil
    ) throws -> NetgenLVSDeviceDeckImport {
        let text = try String(contentsOf: setupURL, encoding: .utf8)
        return importDeviceDeck(
            text: text,
            sourcePath: setupURL.path(percentEncoded: false),
            generatedAt: generatedAt
        )
    }

    public static func importDeviceDeck(
        text: String,
        sourcePath: String,
        generatedAt: String? = nil
    ) -> NetgenLVSDeviceDeckImport {
        var devices: [NetgenLVSDeviceDescriptor] = []
        var policyRules: [NetgenLVSPolicyRule] = []
        var diagnostics: [NetgenLVSDeviceDeckImportDiagnostic] = []
        var skippedLineCount = 0
        var currentDeviceNames: [String] = []
        var activeForeach: ForeachContext?

        for line in makeLogicalLines(from: text) {
            let tokens = splitTCL(line.text)
            guard let command = tokens.first else {
                activeForeach = updateForeach(activeForeach, after: line)
                continue
            }
            if command == "set", tokens.count >= 2, tokens[1] == "devices" {
                currentDeviceNames = tokens.dropFirst(2)
                    .flatMap { splitListToken(cleanToken($0)) }
                activeForeach = updateForeach(activeForeach, after: line)
                continue
            }
            if command == "lappend", tokens.count >= 3, tokens[1] == "devices" {
                let deviceNames = tokens.dropFirst(2).map(cleanToken).filter { !$0.isEmpty }
                if deviceNames.isEmpty {
                    skippedLineCount += 1
                    diagnostics.append(NetgenLVSDeviceDeckImportDiagnostic(
                        code: "netgen_device_list_empty",
                        message: "The Netgen devices append command did not contain device names.",
                        sourceLineNumber: line.lineNumber,
                        sourceLine: line.text
                    ))
                    continue
                }
                currentDeviceNames.append(contentsOf: deviceNames)
                for deviceName in deviceNames {
                    devices.append(NetgenLVSDeviceDescriptor(
                        deviceName: deviceName,
                        family: deviceFamily(deviceName),
                        sourceLineNumber: line.lineNumber,
                        sourceLine: line.text
                    ))
                }
                continue
            }
            if command == "foreach", tokens.count >= 3, tokens[2] == "$devices" {
                activeForeach = ForeachContext(
                    variableName: cleanToken(tokens[1]),
                    values: currentDeviceNames,
                    braceDepth: max(1, braceDelta(in: line.text))
                )
                continue
            }
            if command == "permute" || command == "property" || command == "equate" {
                let rule = NetgenLVSPolicyRule(
                    kind: command == "equate" && tokens.dropFirst().first == "pins" ? "equate-pins" : command,
                    arguments: tokens.dropFirst().map(cleanToken),
                    sourceLineNumber: line.lineNumber,
                    sourceLine: line.text
                )
                policyRules.append(contentsOf: expandPolicyRule(rule, foreach: activeForeach))
                activeForeach = updateForeach(activeForeach, after: line)
                continue
            }
            if line.text.contains("model blackbox") {
                policyRules.append(NetgenLVSPolicyRule(
                    kind: "blackbox",
                    arguments: tokens.map(cleanToken),
                    sourceLineNumber: line.lineNumber,
                    sourceLine: line.text
                ))
                activeForeach = updateForeach(activeForeach, after: line)
                continue
            }
            if !isIgnoredTCLControlCommand(command) {
                skippedLineCount += 1
                diagnostics.append(NetgenLVSDeviceDeckImportDiagnostic(
                    code: "unsupported_netgen_setup_command",
                    message: "The Netgen LVS setup command '\(command)' is not imported into the device policy seed.",
                    sourceLineNumber: line.lineNumber,
                    sourceLine: line.text
                ))
            }
            activeForeach = updateForeach(activeForeach, after: line)
        }

        if devices.isEmpty {
            diagnostics.append(NetgenLVSDeviceDeckImportDiagnostic(
                code: "netgen_device_map_empty",
                message: "No lappend devices command was imported from the Netgen LVS setup deck."
            ))
        }

        let generatedAtValue = generatedAt ?? utcTimestamp()
        let status: NetgenLVSDeviceDeckImportStatus
        if devices.isEmpty {
            status = .blocked
        } else if diagnostics.isEmpty {
            status = .complete
        } else {
            status = .partial
        }
        let seed = NetgenLVSDevicePolicySeed(
            generatedAt: generatedAtValue,
            sourcePath: sourcePath,
            devices: devices.sorted {
                if $0.family == $1.family {
                    return $0.deviceName < $1.deviceName
                }
                return $0.family < $1.family
            },
            policyRules: policyRules
        )
        let report = NetgenLVSDeviceDeckImportReport(
            generatedAt: generatedAtValue,
            status: status,
            sourcePath: sourcePath,
            supportedFamilies: supportedFamilies,
            importedDeviceCount: devices.count,
            importedPolicyRuleCount: policyRules.count,
            skippedLineCount: skippedLineCount,
            deviceFamilyCounts: count(devices.map(\.family)),
            policyRuleCounts: count(policyRules.map(\.kind)),
            diagnostics: diagnostics
        )
        return NetgenLVSDeviceDeckImport(seed: seed, report: report)
    }

    private static let supportedFamilies = ["mos", "resistor", "diode", "capacitor", "bjt", "inductor", "other"]

    private struct LogicalLine: Sendable, Hashable {
        let lineNumber: Int
        let text: String
    }

    private struct ForeachContext: Sendable, Hashable {
        let variableName: String
        let values: [String]
        let braceDepth: Int
    }

    private static func makeLogicalLines(from text: String) -> [LogicalLine] {
        var logicalLines: [LogicalLine] = []
        var buffer = ""
        var startLine = 1
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            var line = normalizedLine(String(rawLine))
            if line.isEmpty {
                continue
            }
            let continues = line.hasSuffix("\\")
            if continues {
                line.removeLast()
                line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if buffer.isEmpty {
                startLine = lineNumber
                buffer = line
            } else {
                buffer += " " + line
            }
            if !continues {
                logicalLines.append(LogicalLine(lineNumber: startLine, text: buffer))
                buffer = ""
            }
        }
        if !buffer.isEmpty {
            logicalLines.append(LogicalLine(lineNumber: startLine, text: buffer))
        }
        return logicalLines
    }

    private static func normalizedLine(_ rawLine: String) -> String {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commentIndex = trimmed.firstIndex(of: "#") else {
            return trimmed
        }
        return String(trimmed[..<commentIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitTCL(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var braceDepth = 0
        for character in line {
            if character == "\"" {
                inQuote.toggle()
                continue
            }
            if !inQuote {
                if character == "{" {
                    braceDepth += 1
                    continue
                }
                if character == "}" {
                    braceDepth = max(0, braceDepth - 1)
                    continue
                }
            }
            if character.isWhitespace && !inQuote && braceDepth == 0 {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func cleanToken(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: "\"{} \t\n"))
    }

    private static func splitListToken(_ token: String) -> [String] {
        token.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func isIgnoredTCLControlCommand(_ command: String) -> Bool {
        [
            "if",
            "elseif",
            "else",
            "switch",
            "set",
            "foreach",
            "puts",
            "return",
        ].contains(command)
    }

    private static func expandPolicyRule(
        _ rule: NetgenLVSPolicyRule,
        foreach context: ForeachContext?
    ) -> [NetgenLVSPolicyRule] {
        guard
            let context,
            !context.values.isEmpty,
            containsVariable(context.variableName, in: rule.arguments)
        else {
            return [rule]
        }
        return context.values.map { value in
            NetgenLVSPolicyRule(
                kind: rule.kind,
                arguments: rule.arguments.map {
                    replaceVariable(context.variableName, with: value, in: $0)
                },
                sourceLineNumber: rule.sourceLineNumber,
                sourceLine: replaceVariable(context.variableName, with: value, in: rule.sourceLine)
            )
        }
    }

    private static func containsVariable(_ variableName: String, in arguments: [String]) -> Bool {
        arguments.contains { $0.contains("$\(variableName)") || $0.contains("${\(variableName)}") }
    }

    private static func replaceVariable(_ variableName: String, with value: String, in text: String) -> String {
        text
            .replacingOccurrences(of: "${\(variableName)}", with: value)
            .replacingOccurrences(of: "$\(variableName)", with: value)
    }

    private static func updateForeach(_ context: ForeachContext?, after line: LogicalLine) -> ForeachContext? {
        guard let context else { return nil }
        let nextDepth = context.braceDepth + braceDelta(in: line.text)
        guard nextDepth > 0 else { return nil }
        return ForeachContext(
            variableName: context.variableName,
            values: context.values,
            braceDepth: nextDepth
        )
    }

    private static func braceDelta(in text: String) -> Int {
        text.reduce(0) { depth, character in
            if character == "{" {
                return depth + 1
            }
            if character == "}" {
                return depth - 1
            }
            return depth
        }
    }

    private static func deviceFamily(_ device: String) -> String {
        if device.contains("nfet") || device.contains("pfet") {
            return "mos"
        }
        if device.contains("res_") || device.hasPrefix("mrd") {
            return "resistor"
        }
        if device.contains("diode") {
            return "diode"
        }
        if device.contains("cap_") || device.contains("__cap") {
            return "capacitor"
        }
        if device.contains("npn") || device.contains("pnp") {
            return "bjt"
        }
        if device.contains("ind_") {
            return "inductor"
        }
        return "other"
    }

    private static func count(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { counts, value in
            counts[value, default: 0] += 1
        }
    }

    private static func utcTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
}

@available(*, deprecated, renamed: "NetgenLVSDeviceDeckImportStatus")
public typealias Sky130NetgenLVSDeviceDeckImportStatus = NetgenLVSDeviceDeckImportStatus

@available(*, deprecated, renamed: "NetgenLVSDeviceDescriptor")
public typealias Sky130NetgenLVSDeviceDescriptor = NetgenLVSDeviceDescriptor

@available(*, deprecated, renamed: "NetgenLVSPolicyRule")
public typealias Sky130NetgenLVSPolicyRule = NetgenLVSPolicyRule

@available(*, deprecated, renamed: "NetgenLVSDevicePolicySeed")
public typealias Sky130NetgenLVSDevicePolicySeed = NetgenLVSDevicePolicySeed

@available(*, deprecated, renamed: "NetgenLVSDeviceDeckImportDiagnostic")
public typealias Sky130NetgenLVSDeviceDeckImportDiagnostic = NetgenLVSDeviceDeckImportDiagnostic

@available(*, deprecated, renamed: "NetgenLVSDeviceDeckImportReport")
public typealias Sky130NetgenLVSDeviceDeckImportReport = NetgenLVSDeviceDeckImportReport

@available(*, deprecated, renamed: "NetgenLVSDeviceDeckImport")
public typealias Sky130NetgenLVSDeviceDeckImport = NetgenLVSDeviceDeckImport

@available(*, deprecated, renamed: "NetgenLVSDeviceDeckImporter")
public typealias Sky130NetgenLVSDeviceDeckImporter = NetgenLVSDeviceDeckImporter
