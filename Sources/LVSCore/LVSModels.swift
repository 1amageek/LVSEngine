import Foundation

public struct LVSBackendSelection: Sendable, Hashable, Codable {
    public let backendID: String

    public init(backendID: String) {
        self.backendID = backendID
    }
}

public struct LVSOptions: Sendable, Hashable, Codable {
    public let timeoutSeconds: Double
    public let additionalEnvironment: [String: String]

    public init(
        timeoutSeconds: Double = 300,
        additionalEnvironment: [String: String] = [:]
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.additionalEnvironment = additionalEnvironment
    }
}

public struct LVSRequest: Sendable, Hashable, Codable {
    public let layoutNetlistURL: URL?
    public let layoutGDSURL: URL?
    public let schematicNetlistURL: URL
    public let topCell: String
    /// Technology database (`LayoutTechDatabase` JSON) for backends that
    /// extract devices from standard layout formats in-process; backends
    /// delegating extraction to external tools leave it nil.
    public let technologyURL: URL?
    public let workingDirectory: URL?
    public let backendSelection: LVSBackendSelection
    public let options: LVSOptions

    public init(
        layoutNetlistURL: URL? = nil,
        layoutGDSURL: URL? = nil,
        schematicNetlistURL: URL,
        topCell: String,
        technologyURL: URL? = nil,
        workingDirectory: URL? = nil,
        backendSelection: LVSBackendSelection = LVSBackendSelection(backendID: "netgen"),
        options: LVSOptions = LVSOptions()
    ) {
        self.layoutNetlistURL = layoutNetlistURL
        self.layoutGDSURL = layoutGDSURL
        self.schematicNetlistURL = schematicNetlistURL
        self.topCell = topCell
        self.technologyURL = technologyURL
        self.workingDirectory = workingDirectory
        self.backendSelection = backendSelection
        self.options = options
    }
}

public struct LVSResult: Sendable, Hashable, Codable {
    public let backendID: String
    public let toolName: String
    public let success: Bool
    public let completed: Bool
    public let logPath: String
    public let diagnostics: [LVSDiagnostic]
    public let provenance: LVSToolProvenance?

    public init(
        backendID: String,
        toolName: String,
        success: Bool,
        completed: Bool,
        logPath: String,
        diagnostics: [LVSDiagnostic] = [],
        provenance: LVSToolProvenance? = nil
    ) {
        self.backendID = backendID
        self.toolName = toolName
        self.success = success
        self.completed = completed
        self.logPath = logPath
        self.diagnostics = diagnostics
        self.provenance = provenance
    }

    public var passed: Bool {
        success && completed && !diagnostics.contains { $0.severity == .error }
    }
}

public struct LVSToolProvenance: Sendable, Hashable, Codable {
    public let executablePath: String
    public let pdkRoot: String
    public let setupFilePath: String
    public let driverScriptPath: String
    public let timeoutSeconds: Double

    public init(
        executablePath: String,
        pdkRoot: String,
        setupFilePath: String,
        driverScriptPath: String,
        timeoutSeconds: Double
    ) {
        self.executablePath = executablePath
        self.pdkRoot = pdkRoot
        self.setupFilePath = setupFilePath
        self.driverScriptPath = driverScriptPath
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct LVSDiagnostic: Sendable, Hashable, Codable {
    public enum Severity: String, Sendable, Hashable, Codable {
        case info
        case warning
        case error
    }

    public let severity: Severity
    public let message: String
    public let ruleID: String?
    public let rawLine: String

    public init(
        severity: Severity,
        message: String,
        ruleID: String? = nil,
        rawLine: String
    ) {
        self.severity = severity
        self.message = message
        self.ruleID = ruleID
        self.rawLine = rawLine
    }
}

public struct LVSExecutionResult: Sendable, Hashable, Codable {
    public let request: LVSRequest
    public let result: LVSResult
    public let extractedLayoutNetlistURL: URL?
    public let reportURL: URL?

    public init(
        request: LVSRequest,
        result: LVSResult,
        extractedLayoutNetlistURL: URL? = nil,
        reportURL: URL? = nil
    ) {
        self.request = request
        self.result = result
        self.extractedLayoutNetlistURL = extractedLayoutNetlistURL
        self.reportURL = reportURL
    }
}

public protocol LVSBackend: Sendable {
    var backendID: String { get }

    func run(_ request: LVSRequest) async throws -> LVSExecutionResult
}

public protocol LVSLayoutNetlistExtracting: Sendable {
    func extractLayoutNetlist(
        gds: URL,
        topCell: String,
        into directory: URL,
        timeoutSeconds: Double
    ) async throws -> URL
}

public enum LVSError: Error, LocalizedError, Equatable {
    case invalidInput(String)
    case backendUnavailable(String)
    case backendFailed(String)
    case artifactWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return "Invalid LVS input: \(message)"
        case .backendUnavailable(let message):
            return "LVS backend unavailable: \(message)"
        case .backendFailed(let message):
            return "LVS backend failed: \(message)"
        case .artifactWriteFailed(let message):
            return "LVS artifact write failed: \(message)"
        }
    }
}
