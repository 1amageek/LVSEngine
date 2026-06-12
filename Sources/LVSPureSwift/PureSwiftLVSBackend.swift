import Foundation
import LVSCore

public struct PureSwiftLVSBackend: LVSBackend {
    public let backendID = "pure-swift"
    private let parser: PureSwiftSPICENetlistParser

    public init(parser: PureSwiftSPICENetlistParser = PureSwiftSPICENetlistParser()) {
        self.parser = parser
    }

    public func run(_ request: LVSRequest) async throws -> LVSExecutionResult {
        guard let layoutNetlistURL = request.layoutNetlistURL else {
            throw LVSError.invalidInput("Pure Swift LVS requires a layout netlist")
        }

        let layout = try parser.parse(url: layoutNetlistURL, expectedTopCell: request.topCell)
        let schematic = try parser.parse(url: request.schematicNetlistURL, expectedTopCell: request.topCell)
        let diagnostics = compare(layout: layout, schematic: schematic)
        let result = LVSResult(
            backendID: backendID,
            toolName: "PureSwiftLVS",
            success: true,
            completed: true,
            logPath: request.workingDirectory?
                .appending(path: "lvs-pure-swift-\(UUID().uuidString).log")
                .path(percentEncoded: false)
                ?? "",
            diagnostics: diagnostics,
            provenance: LVSToolProvenance(
                executablePath: "in-process",
                pdkRoot: "not-applicable",
                setupFilePath: "not-applicable",
                driverScriptPath: "not-applicable",
                timeoutSeconds: request.options.timeoutSeconds
            )
        )
        return LVSExecutionResult(request: request, result: result)
    }

    private func compare(layout: PureSwiftNetlist, schematic: PureSwiftNetlist) -> [LVSDiagnostic] {
        var diagnostics: [LVSDiagnostic] = []
        if layout.ports != schematic.ports {
            diagnostics.append(LVSDiagnostic(
                severity: .error,
                message: "Top cell ports differ between layout and schematic",
                ruleID: "LVS_PORT_MISMATCH",
                rawLine: "layout=\(layout.ports.joined(separator: ",")) schematic=\(schematic.ports.joined(separator: ","))"
            ))
        }

        let layoutCounts = componentCounts(layout.components)
        let schematicCounts = componentCounts(schematic.components)
        for signature in Set(layoutCounts.keys).union(schematicCounts.keys).sorted() {
            let layoutCount = layoutCounts[signature, default: 0]
            let schematicCount = schematicCounts[signature, default: 0]
            guard layoutCount != schematicCount else { continue }
            diagnostics.append(LVSDiagnostic(
                severity: .error,
                message: "Component signature count differs for \(signature)",
                ruleID: "LVS_COMPONENT_MISMATCH",
                rawLine: "signature=\(signature) layout=\(layoutCount) schematic=\(schematicCount)"
            ))
        }
        return diagnostics
    }

    private func componentCounts(_ components: [PureSwiftNetlistComponent]) -> [String: Int] {
        components.reduce(into: [:]) { counts, component in
            counts[component.signature, default: 0] += 1
        }
    }
}

public struct PureSwiftSPICENetlistParser: Sendable {
    public init() {}

    public func parse(url: URL, expectedTopCell: String) throws -> PureSwiftNetlist {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw LVSError.invalidInput("Pure Swift LVS could not read netlist: \(error.localizedDescription)")
        }
        return try parse(text: text, expectedTopCell: expectedTopCell)
    }

    public func parse(text: String, expectedTopCell: String) throws -> PureSwiftNetlist {
        let lines = normalizedLines(from: text)
        var topPorts: [String]?
        var components: [PureSwiftNetlistComponent] = []
        var insideExpectedSubcircuit = false

        for line in lines {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = tokens.first else { continue }
            let lowercased = first.lowercased()

            if lowercased == ".subckt" {
                guard tokens.count >= 2 else {
                    throw LVSError.invalidInput("Invalid .subckt line: \(line)")
                }
                insideExpectedSubcircuit = tokens[1] == expectedTopCell
                if insideExpectedSubcircuit {
                    topPorts = Array(tokens.dropFirst(2))
                }
                continue
            }
            if lowercased == ".ends" {
                insideExpectedSubcircuit = false
                continue
            }
            guard insideExpectedSubcircuit, !first.hasPrefix(".") else {
                continue
            }
            components.append(try parseComponent(tokens: tokens, rawLine: line))
        }

        guard let topPorts else {
            throw LVSError.invalidInput("Top cell \(expectedTopCell) was not found")
        }
        return PureSwiftNetlist(topCell: expectedTopCell, ports: topPorts, components: components)
    }

    private func normalizedLines(from text: String) -> [String] {
        var result: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func parseComponent(tokens: [String], rawLine: String) throws -> PureSwiftNetlistComponent {
        guard let name = tokens.first,
              let prefix = name.first else {
            throw LVSError.invalidInput("Invalid component line: \(rawLine)")
        }
        switch prefix.uppercased() {
        case "M":
            guard tokens.count >= 6 else {
                throw LVSError.invalidInput("Invalid MOS component line: \(rawLine)")
            }
            return PureSwiftNetlistComponent(
                name: name,
                kind: "mos",
                pins: Array(tokens[1...4]),
                model: tokens[5]
            )
        case "R":
            guard tokens.count >= 4 else {
                throw LVSError.invalidInput("Invalid resistor component line: \(rawLine)")
            }
            return PureSwiftNetlistComponent(
                name: name,
                kind: "resistor",
                pins: Array(tokens[1...2]),
                model: tokens[3]
            )
        case "C":
            guard tokens.count >= 4 else {
                throw LVSError.invalidInput("Invalid capacitor component line: \(rawLine)")
            }
            return PureSwiftNetlistComponent(
                name: name,
                kind: "capacitor",
                pins: Array(tokens[1...2]),
                model: tokens[3]
            )
        case "X":
            guard tokens.count >= 3 else {
                throw LVSError.invalidInput("Invalid subcircuit instance line: \(rawLine)")
            }
            return PureSwiftNetlistComponent(
                name: name,
                kind: "subcircuit",
                pins: Array(tokens[1..<tokens.index(before: tokens.endIndex)]),
                model: tokens[tokens.index(before: tokens.endIndex)]
            )
        default:
            throw LVSError.invalidInput("Unsupported component prefix \(prefix) in line: \(rawLine)")
        }
    }
}

public struct PureSwiftNetlist: Sendable, Hashable, Codable {
    public let topCell: String
    public let ports: [String]
    public let components: [PureSwiftNetlistComponent]

    public init(topCell: String, ports: [String], components: [PureSwiftNetlistComponent]) {
        self.topCell = topCell
        self.ports = ports
        self.components = components
    }
}

public struct PureSwiftNetlistComponent: Sendable, Hashable, Codable {
    public let name: String
    public let kind: String
    public let pins: [String]
    public let model: String

    public init(name: String, kind: String, pins: [String], model: String) {
        self.name = name
        self.kind = kind
        self.pins = pins
        self.model = model
    }

    public var signature: String {
        "\(kind)|\(model)|\(pins.joined(separator: ","))"
    }
}
