import Foundation
import LVSEngine

public enum LVSCLIError: Error, LocalizedError, Equatable {
    case missingValue(String)
    case missingRequired(String)
    case invalidValue(argument: String, value: String, expected: String)
    case conflictingArguments(String, String)
    case unknownArgument(String)

    public var errorDescription: String? {
        switch self {
        case .missingValue(let argument):
            return "Missing value after \(argument)"
        case .missingRequired(let argument):
            return "Missing required argument: \(argument)"
        case .invalidValue(let argument, let value, let expected):
            return "Invalid value for \(argument): \(value). Expected \(expected)"
        case .conflictingArguments(let first, let second):
            return "Conflicting arguments: \(first) and \(second)"
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        }
    }
}

public struct LVSCLIOptions: Sendable, Hashable {
    public let layoutNetlistURL: URL?
    public let layoutGDSURL: URL?
    public let schematicNetlistURL: URL
    public let topCell: String
    public let technologyURL: URL?
    public let backendID: String?
    public let outputDirectory: URL
    public let timeoutSeconds: Double

    public init(arguments: [String]) throws {
        var layoutNetlistURL: URL?
        var layoutGDSURL: URL?
        var schematicNetlistURL: URL?
        var topCell: String?
        var technologyURL: URL?
        var backendID: String?
        var outputDirectory: URL?
        var timeoutSeconds = 300.0
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--layout-netlist":
                layoutNetlistURL = URL(filePath: try Self.value(after: argument, in: arguments, index: &index))
            case "--layout-gds":
                layoutGDSURL = URL(filePath: try Self.value(after: argument, in: arguments, index: &index))
            case "--schematic-netlist":
                schematicNetlistURL = URL(filePath: try Self.value(after: argument, in: arguments, index: &index))
            case "--top-cell":
                topCell = try Self.value(after: argument, in: arguments, index: &index)
            case "--out":
                outputDirectory = URL(filePath: try Self.value(after: argument, in: arguments, index: &index))
            case "--tech":
                technologyURL = URL(filePath: try Self.value(after: argument, in: arguments, index: &index))
            case "--backend":
                backendID = try Self.value(after: argument, in: arguments, index: &index)
            case "--timeout":
                timeoutSeconds = try Self.positiveFiniteDouble(after: argument, in: arguments, index: &index)
            default:
                throw LVSCLIError.unknownArgument(argument)
            }
            index += 1
        }

        guard !(layoutNetlistURL != nil && layoutGDSURL != nil) else {
            throw LVSCLIError.conflictingArguments("--layout-netlist", "--layout-gds")
        }
        guard layoutNetlistURL != nil || layoutGDSURL != nil else {
            throw LVSCLIError.missingRequired("--layout-netlist or --layout-gds")
        }
        guard let schematicNetlistURL else { throw LVSCLIError.missingRequired("--schematic-netlist") }
        guard let topCell else { throw LVSCLIError.missingRequired("--top-cell") }
        guard let outputDirectory else { throw LVSCLIError.missingRequired("--out") }

        self.layoutNetlistURL = layoutNetlistURL
        self.layoutGDSURL = layoutGDSURL
        self.schematicNetlistURL = schematicNetlistURL
        self.topCell = topCell
        self.technologyURL = technologyURL
        self.backendID = backendID
        self.outputDirectory = outputDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    public func makeRequest() -> LVSRequest {
        // A technology database implies the standard-input pure Swift
        // backend unless the caller chose one explicitly.
        let resolvedBackendID = backendID ?? (technologyURL != nil ? "pure-swift-gds" : "netgen")
        return LVSRequest(
            layoutNetlistURL: layoutNetlistURL,
            layoutGDSURL: layoutGDSURL,
            schematicNetlistURL: schematicNetlistURL,
            topCell: topCell,
            technologyURL: technologyURL,
            workingDirectory: outputDirectory,
            backendSelection: LVSBackendSelection(backendID: resolvedBackendID),
            options: LVSOptions(timeoutSeconds: timeoutSeconds)
        )
    }

    private static func value(after argument: String, in arguments: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw LVSCLIError.missingValue(argument)
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func positiveFiniteDouble(after argument: String, in arguments: [String], index: inout Int) throws -> Double {
        let rawValue = try value(after: argument, in: arguments, index: &index)
        guard let value = Double(rawValue), value.isFinite, value > 0 else {
            throw LVSCLIError.invalidValue(argument: argument, value: rawValue, expected: "positive finite seconds")
        }
        return value
    }
}

public enum LVSCLI {
    public static func run(arguments: [String]) async -> Int32 {
        do {
            let options = try LVSCLIOptions(arguments: arguments)
            let result = try await DefaultLVSEngine().run(options.makeRequest())
            print("status=\(result.result.passed ? "passed" : "failed")")
            if let reportURL = result.reportURL {
                print("report=\(reportURL.path(percentEncoded: false))")
            }
            if let extracted = result.extractedLayoutNetlistURL {
                print("extracted_layout_netlist=\(extracted.path(percentEncoded: false))")
            }
            return result.result.passed ? 0 : 2
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
