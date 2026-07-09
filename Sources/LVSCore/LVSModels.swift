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

public enum LVSLayoutFormat: String, Sendable, Hashable, Codable {
    case auto
    case gds
    case oasis
    case cif
    case dxf
}

public struct LVSRequest: Sendable, Hashable, Codable {
    public let layoutNetlistURL: URL?
    public let layoutGDSURL: URL?
    public let layoutFormat: LVSLayoutFormat?
    public let schematicNetlistURL: URL
    public let topCell: String
    /// Technology database (`LayoutTechDatabase` JSON) for backends that
    /// extract devices from standard layout formats in-process; backends
    /// delegating extraction to external tools leave it nil.
    public let technologyURL: URL?
    public let waiverURL: URL?
    public let modelEquivalenceURL: URL?
    public let terminalEquivalenceURL: URL?
    public let devicePolicyURL: URL?
    public let workingDirectory: URL?
    public let backendSelection: LVSBackendSelection
    public let options: LVSOptions

    public init(
        layoutNetlistURL: URL? = nil,
        layoutGDSURL: URL? = nil,
        layoutFormat: LVSLayoutFormat? = nil,
        schematicNetlistURL: URL,
        topCell: String,
        technologyURL: URL? = nil,
        waiverURL: URL? = nil,
        modelEquivalenceURL: URL? = nil,
        terminalEquivalenceURL: URL? = nil,
        devicePolicyURL: URL? = nil,
        workingDirectory: URL? = nil,
        backendSelection: LVSBackendSelection = LVSBackendSelection(backendID: "netgen"),
        options: LVSOptions = LVSOptions()
    ) {
        self.layoutNetlistURL = layoutNetlistURL
        self.layoutGDSURL = layoutGDSURL
        self.layoutFormat = layoutFormat
        self.schematicNetlistURL = schematicNetlistURL
        self.topCell = topCell
        self.technologyURL = technologyURL
        self.waiverURL = waiverURL
        self.modelEquivalenceURL = modelEquivalenceURL
        self.terminalEquivalenceURL = terminalEquivalenceURL
        self.devicePolicyURL = devicePolicyURL
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
        success && completed && !diagnostics.contains { $0.severity == .error && !$0.isWaived }
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
    public let category: String?
    public let componentSignature: String?
    public let layoutCount: Int?
    public let schematicCount: Int?
    public let layoutModel: String?
    public let schematicModel: String?
    public let parameterName: String?
    public let layoutValue: String?
    public let schematicValue: String?
    public let layoutPorts: [String]?
    public let schematicPorts: [String]?
    public let suggestedFix: String?
    public let waiverID: String?
    public let waiverReason: String?
    public let rawLine: String
    public let layoutComponentName: String?
    public let schematicComponentName: String?

    public init(
        severity: Severity,
        message: String,
        ruleID: String? = nil,
        category: String? = nil,
        componentSignature: String? = nil,
        layoutCount: Int? = nil,
        schematicCount: Int? = nil,
        layoutModel: String? = nil,
        schematicModel: String? = nil,
        parameterName: String? = nil,
        layoutValue: String? = nil,
        schematicValue: String? = nil,
        layoutPorts: [String]? = nil,
        schematicPorts: [String]? = nil,
        suggestedFix: String? = nil,
        waiverID: String? = nil,
        waiverReason: String? = nil,
        rawLine: String,
        layoutComponentName: String? = nil,
        schematicComponentName: String? = nil
    ) {
        self.severity = severity
        self.message = message
        self.ruleID = ruleID
        self.category = category
        self.componentSignature = componentSignature
        self.layoutCount = layoutCount
        self.schematicCount = schematicCount
        self.layoutModel = layoutModel
        self.schematicModel = schematicModel
        self.parameterName = parameterName
        self.layoutValue = layoutValue
        self.schematicValue = schematicValue
        self.layoutPorts = layoutPorts
        self.schematicPorts = schematicPorts
        self.suggestedFix = suggestedFix
        self.waiverID = waiverID
        self.waiverReason = waiverReason
        self.rawLine = rawLine
        self.layoutComponentName = layoutComponentName
        self.schematicComponentName = schematicComponentName
    }

    public var isWaived: Bool {
        guard let waiverID = waiverID?.trimmingCharacters(in: .whitespacesAndNewlines),
              let waiverReason = waiverReason?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !waiverID.isEmpty && !waiverReason.isEmpty
    }

    public func applyingWaiver(_ waiver: LVSWaiver) -> LVSDiagnostic {
        LVSDiagnostic(
            severity: severity,
            message: message,
            ruleID: ruleID,
            category: category,
            componentSignature: componentSignature,
            layoutCount: layoutCount,
            schematicCount: schematicCount,
            layoutModel: layoutModel,
            schematicModel: schematicModel,
            parameterName: parameterName,
            layoutValue: layoutValue,
            schematicValue: schematicValue,
            layoutPorts: layoutPorts,
            schematicPorts: schematicPorts,
            suggestedFix: suggestedFix,
            waiverID: waiver.id,
            waiverReason: waiver.reason,
            rawLine: rawLine,
            layoutComponentName: layoutComponentName,
            schematicComponentName: schematicComponentName
        )
    }
}

public struct LVSExecutionResult: Sendable, Hashable, Codable {
    public let request: LVSRequest
    public let result: LVSResult
    public let extractedLayoutNetlistURL: URL?
    public let waiverReport: LVSWaiverApplicationReport?
    public let devicePolicyReport: LVSDevicePolicyApplicationReport?
    public let reportURL: URL?
    public let artifactManifestURL: URL?

    public init(
        request: LVSRequest,
        result: LVSResult,
        extractedLayoutNetlistURL: URL? = nil,
        waiverReport: LVSWaiverApplicationReport? = nil,
        devicePolicyReport: LVSDevicePolicyApplicationReport? = nil,
        reportURL: URL? = nil,
        artifactManifestURL: URL? = nil
    ) {
        self.request = request
        self.result = result
        self.extractedLayoutNetlistURL = extractedLayoutNetlistURL
        self.waiverReport = waiverReport
        self.devicePolicyReport = devicePolicyReport
        self.reportURL = reportURL
        self.artifactManifestURL = artifactManifestURL
    }
}

public struct LVSArtifactManifest: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let backendID: String
    public let toolName: String
    public let passed: Bool
    public let completed: Bool
    public let inputs: [LVSArtifactRecord]
    public let outputs: [LVSArtifactRecord]
    public let diagnosticSummary: LVSDiagnosticSummary
    public let waiverReport: LVSWaiverApplicationReport?
    public let devicePolicyReport: LVSDevicePolicyApplicationReport?

    public init(
        schemaVersion: Int = 1,
        generatedAt: String,
        backendID: String,
        toolName: String,
        passed: Bool,
        completed: Bool,
        inputs: [LVSArtifactRecord],
        outputs: [LVSArtifactRecord],
        diagnosticSummary: LVSDiagnosticSummary,
        waiverReport: LVSWaiverApplicationReport? = nil,
        devicePolicyReport: LVSDevicePolicyApplicationReport? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.backendID = backendID
        self.toolName = toolName
        self.passed = passed
        self.completed = completed
        self.inputs = inputs
        self.outputs = outputs
        self.diagnosticSummary = diagnosticSummary
        self.waiverReport = waiverReport
        self.devicePolicyReport = devicePolicyReport
    }
}

public struct LVSArtifactRecord: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case layout
        case layoutNetlist
        case schematicNetlist
        case technology
        case waiver
        case modelEquivalence
        case terminalEquivalence
        case devicePolicy
        case report
        case log
        case manifest
    }

    public let id: String
    public let kind: Kind
    public let path: String
    public let byteCount: Int?
    public let sha256: String?

    public init(
        id: String,
        kind: Kind,
        path: String,
        byteCount: Int?,
        sha256: String?
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct LVSDiagnosticSummary: Sendable, Hashable, Codable {
    public let infoCount: Int
    public let warningCount: Int
    public let errorCount: Int
    public let waivedErrorCount: Int

    public init(
        infoCount: Int,
        warningCount: Int,
        errorCount: Int,
        waivedErrorCount: Int = 0
    ) {
        self.infoCount = infoCount
        self.warningCount = warningCount
        self.errorCount = errorCount
        self.waivedErrorCount = waivedErrorCount
    }
}

public struct LVSWaiverFile: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let waivers: [LVSWaiver]

    public init(schemaVersion: Int = 1, waivers: [LVSWaiver]) {
        self.schemaVersion = schemaVersion
        self.waivers = waivers
    }
}

public struct LVSWaiver: Sendable, Hashable, Codable {
    public let id: String
    public let reason: String
    public let ruleID: String?
    public let category: String?
    public let componentSignature: String?
    public let layoutPorts: [String]?
    public let schematicPorts: [String]?
    public let messageContains: String?

    public init(
        id: String,
        reason: String,
        ruleID: String? = nil,
        category: String? = nil,
        componentSignature: String? = nil,
        layoutPorts: [String]? = nil,
        schematicPorts: [String]? = nil,
        messageContains: String? = nil
    ) {
        self.id = id
        self.reason = reason
        self.ruleID = ruleID
        self.category = category
        self.componentSignature = componentSignature
        self.layoutPorts = layoutPorts
        self.schematicPorts = schematicPorts
        self.messageContains = messageContains
    }
}

public struct LVSWaiverApplicationReport: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let waivedDiagnosticCount: Int
    public let appliedWaivers: [LVSAppliedWaiver]
    public let unusedWaiverIDs: [String]

    public init(
        schemaVersion: Int = 1,
        waivedDiagnosticCount: Int,
        appliedWaivers: [LVSAppliedWaiver],
        unusedWaiverIDs: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.waivedDiagnosticCount = waivedDiagnosticCount
        self.appliedWaivers = appliedWaivers
        self.unusedWaiverIDs = unusedWaiverIDs
    }
}

public struct LVSAppliedWaiver: Sendable, Hashable, Codable {
    public let waiverID: String
    public let ruleID: String?
    public let diagnosticMessage: String

    public init(waiverID: String, ruleID: String?, diagnosticMessage: String) {
        self.waiverID = waiverID
        self.ruleID = ruleID
        self.diagnosticMessage = diagnosticMessage
    }
}

public enum LVSDevicePolicyApplicationStatus: String, Sendable, Hashable, Codable {
    case complete
    case partial
    case blocked
}

public struct LVSDevicePolicyAppliedRule: Sendable, Hashable, Codable {
    public let kind: String
    public let model: String?
    public let pairedModel: String?
    public let family: String?
    public let equivalentPinGroups: [[Int]]
    public let parameterNames: [String]?
    public let parameterTolerances: [String: Double]?
    public let parameterRoles: [String: String]?
    public let propertyMode: String?
    public let sourceLineNumber: Int?
    public let sourceLine: String?

    public init(
        kind: String,
        model: String?,
        pairedModel: String? = nil,
        family: String?,
        equivalentPinGroups: [[Int]] = [],
        parameterNames: [String]? = nil,
        parameterTolerances: [String: Double]? = nil,
        parameterRoles: [String: String]? = nil,
        propertyMode: String? = nil,
        sourceLineNumber: Int?,
        sourceLine: String?
    ) {
        self.kind = kind
        self.model = model
        self.pairedModel = pairedModel
        self.family = family
        self.equivalentPinGroups = equivalentPinGroups
        self.parameterNames = parameterNames
        self.parameterTolerances = parameterTolerances
        self.parameterRoles = parameterRoles
        self.propertyMode = propertyMode
        self.sourceLineNumber = sourceLineNumber
        self.sourceLine = sourceLine
    }
}

public struct LVSDevicePolicyIgnoredRule: Sendable, Hashable, Codable {
    public let kind: String
    public let reasonCode: String
    public let message: String
    public let sourceLineNumber: Int?
    public let sourceLine: String?

    public init(
        kind: String,
        reasonCode: String,
        message: String,
        sourceLineNumber: Int?,
        sourceLine: String?
    ) {
        self.kind = kind
        self.reasonCode = reasonCode
        self.message = message
        self.sourceLineNumber = sourceLineNumber
        self.sourceLine = sourceLine
    }
}

public struct LVSDevicePolicyUnobservedRule: Sendable, Hashable, Codable {
    public let kind: String
    public let reasonCode: String
    public let message: String
    public let targetModels: [String]
    public let sourceLineNumber: Int?
    public let sourceLine: String?

    public init(
        kind: String,
        reasonCode: String,
        message: String,
        targetModels: [String],
        sourceLineNumber: Int?,
        sourceLine: String?
    ) {
        self.kind = kind
        self.reasonCode = reasonCode
        self.message = message
        self.targetModels = targetModels
        self.sourceLineNumber = sourceLineNumber
        self.sourceLine = sourceLine
    }
}

public struct LVSDevicePolicyApplicationReport: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let kind: String
    public let generatedAt: String
    public let status: LVSDevicePolicyApplicationStatus
    public let policyPath: String
    public let seedSourcePath: String
    public let knownDeviceCount: Int
    public let observedKnownDeviceCount: Int
    public let policyRuleCount: Int
    public let appliedRuleCount: Int
    public let ignoredRuleCount: Int
    public let unobservedRuleCount: Int
    public let policyRuleCountsByKind: [String: Int]
    public let appliedRuleCountsByKind: [String: Int]
    public let ignoredRuleCountsByReason: [String: Int]
    public let unobservedRuleCountsByKind: [String: Int]
    public let deviceFamilyCounts: [String: Int]
    public let observedDeviceFamilyCounts: [String: Int]
    public let appliedRules: [LVSDevicePolicyAppliedRule]
    public let ignoredRules: [LVSDevicePolicyIgnoredRule]
    public let unobservedRules: [LVSDevicePolicyUnobservedRule]

    public init(
        schemaVersion: Int = 1,
        kind: String = "lvs-device-policy-application-report",
        generatedAt: String,
        status: LVSDevicePolicyApplicationStatus,
        policyPath: String,
        seedSourcePath: String,
        knownDeviceCount: Int,
        observedKnownDeviceCount: Int,
        policyRuleCount: Int? = nil,
        appliedRuleCount: Int,
        ignoredRuleCount: Int,
        unobservedRuleCount: Int? = nil,
        policyRuleCountsByKind: [String: Int]? = nil,
        appliedRuleCountsByKind: [String: Int]? = nil,
        ignoredRuleCountsByReason: [String: Int]? = nil,
        unobservedRuleCountsByKind: [String: Int]? = nil,
        deviceFamilyCounts: [String: Int],
        observedDeviceFamilyCounts: [String: Int],
        appliedRules: [LVSDevicePolicyAppliedRule],
        ignoredRules: [LVSDevicePolicyIgnoredRule],
        unobservedRules: [LVSDevicePolicyUnobservedRule] = []
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.generatedAt = generatedAt
        self.status = status
        self.policyPath = policyPath
        self.seedSourcePath = seedSourcePath
        self.knownDeviceCount = knownDeviceCount
        self.observedKnownDeviceCount = observedKnownDeviceCount
        self.policyRuleCount = policyRuleCount ?? appliedRules.count + ignoredRules.count + unobservedRules.count
        self.appliedRuleCount = appliedRuleCount
        self.ignoredRuleCount = ignoredRuleCount
        self.unobservedRuleCount = unobservedRuleCount ?? unobservedRules.count
        self.policyRuleCountsByKind = policyRuleCountsByKind ?? [:]
        self.appliedRuleCountsByKind = appliedRuleCountsByKind ?? Dictionary(
            grouping: appliedRules,
            by: \.kind
        ).mapValues(\.count)
        self.ignoredRuleCountsByReason = ignoredRuleCountsByReason ?? Dictionary(
            grouping: ignoredRules,
            by: \.reasonCode
        ).mapValues(\.count)
        self.unobservedRuleCountsByKind = unobservedRuleCountsByKind ?? Dictionary(
            grouping: unobservedRules,
            by: \.kind
        ).mapValues(\.count)
        self.deviceFamilyCounts = deviceFamilyCounts
        self.observedDeviceFamilyCounts = observedDeviceFamilyCounts
        self.appliedRules = appliedRules
        self.ignoredRules = ignoredRules
        self.unobservedRules = unobservedRules
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case kind
        case generatedAt
        case status
        case policyPath
        case seedSourcePath
        case knownDeviceCount
        case observedKnownDeviceCount
        case policyRuleCount
        case appliedRuleCount
        case ignoredRuleCount
        case unobservedRuleCount
        case policyRuleCountsByKind
        case appliedRuleCountsByKind
        case ignoredRuleCountsByReason
        case unobservedRuleCountsByKind
        case deviceFamilyCounts
        case observedDeviceFamilyCounts
        case appliedRules
        case ignoredRules
        case unobservedRules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let appliedRules = try container.decodeIfPresent(
            [LVSDevicePolicyAppliedRule].self,
            forKey: .appliedRules
        ) ?? []
        let ignoredRules = try container.decodeIfPresent(
            [LVSDevicePolicyIgnoredRule].self,
            forKey: .ignoredRules
        ) ?? []
        let unobservedRules = try container.decodeIfPresent(
            [LVSDevicePolicyUnobservedRule].self,
            forKey: .unobservedRules
        ) ?? []
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            kind: try container.decodeIfPresent(String.self, forKey: .kind)
                ?? "lvs-device-policy-application-report",
            generatedAt: try container.decode(String.self, forKey: .generatedAt),
            status: try container.decode(LVSDevicePolicyApplicationStatus.self, forKey: .status),
            policyPath: try container.decode(String.self, forKey: .policyPath),
            seedSourcePath: try container.decode(String.self, forKey: .seedSourcePath),
            knownDeviceCount: try container.decodeIfPresent(Int.self, forKey: .knownDeviceCount) ?? 0,
            observedKnownDeviceCount: try container.decodeIfPresent(Int.self, forKey: .observedKnownDeviceCount) ?? 0,
            policyRuleCount: try container.decodeIfPresent(Int.self, forKey: .policyRuleCount),
            appliedRuleCount: try container.decodeIfPresent(Int.self, forKey: .appliedRuleCount) ?? appliedRules.count,
            ignoredRuleCount: try container.decodeIfPresent(Int.self, forKey: .ignoredRuleCount) ?? ignoredRules.count,
            unobservedRuleCount: try container.decodeIfPresent(Int.self, forKey: .unobservedRuleCount),
            policyRuleCountsByKind: try container.decodeIfPresent(
                [String: Int].self,
                forKey: .policyRuleCountsByKind
            ),
            appliedRuleCountsByKind: try container.decodeIfPresent(
                [String: Int].self,
                forKey: .appliedRuleCountsByKind
            ),
            ignoredRuleCountsByReason: try container.decodeIfPresent(
                [String: Int].self,
                forKey: .ignoredRuleCountsByReason
            ),
            unobservedRuleCountsByKind: try container.decodeIfPresent(
                [String: Int].self,
                forKey: .unobservedRuleCountsByKind
            ),
            deviceFamilyCounts: try container.decodeIfPresent([String: Int].self, forKey: .deviceFamilyCounts) ?? [:],
            observedDeviceFamilyCounts: try container.decodeIfPresent(
                [String: Int].self,
                forKey: .observedDeviceFamilyCounts
            ) ?? [:],
            appliedRules: appliedRules,
            ignoredRules: ignoredRules,
            unobservedRules: unobservedRules
        )
    }
}

public struct LVSDevicePolicyRunSummary: Sendable, Hashable, Codable {
    public let status: LVSDevicePolicyApplicationStatus
    public let knownDeviceCount: Int
    public let observedKnownDeviceCount: Int
    public let policyRuleCount: Int
    public let appliedRuleCount: Int
    public let ignoredRuleCount: Int
    public let unobservedRuleCount: Int
    public let policyRuleCountsByKind: [String: Int]
    public let appliedRuleCountsByKind: [String: Int]
    public let ignoredRuleCountsByReason: [String: Int]
    public let unobservedRuleCountsByKind: [String: Int]

    public init(report: LVSDevicePolicyApplicationReport) {
        self.status = report.status
        self.knownDeviceCount = report.knownDeviceCount
        self.observedKnownDeviceCount = report.observedKnownDeviceCount
        self.policyRuleCount = report.policyRuleCount
        self.appliedRuleCount = report.appliedRuleCount
        self.ignoredRuleCount = report.ignoredRuleCount
        self.unobservedRuleCount = report.unobservedRuleCount
        self.policyRuleCountsByKind = report.policyRuleCountsByKind
        self.appliedRuleCountsByKind = report.appliedRuleCountsByKind
        self.ignoredRuleCountsByReason = report.ignoredRuleCountsByReason
        self.unobservedRuleCountsByKind = report.unobservedRuleCountsByKind
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case knownDeviceCount
        case observedKnownDeviceCount
        case policyRuleCount
        case appliedRuleCount
        case ignoredRuleCount
        case unobservedRuleCount
        case policyRuleCountsByKind
        case appliedRuleCountsByKind
        case ignoredRuleCountsByReason
        case unobservedRuleCountsByKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(LVSDevicePolicyApplicationStatus.self, forKey: .status)
        knownDeviceCount = try container.decodeIfPresent(Int.self, forKey: .knownDeviceCount) ?? 0
        observedKnownDeviceCount = try container.decodeIfPresent(Int.self, forKey: .observedKnownDeviceCount) ?? 0
        appliedRuleCount = try container.decodeIfPresent(Int.self, forKey: .appliedRuleCount) ?? 0
        ignoredRuleCount = try container.decodeIfPresent(Int.self, forKey: .ignoredRuleCount) ?? 0
        unobservedRuleCount = try container.decodeIfPresent(Int.self, forKey: .unobservedRuleCount) ?? 0
        policyRuleCount = try container.decodeIfPresent(Int.self, forKey: .policyRuleCount)
            ?? appliedRuleCount + ignoredRuleCount + unobservedRuleCount
        policyRuleCountsByKind = try container.decodeIfPresent([String: Int].self, forKey: .policyRuleCountsByKind)
            ?? [:]
        appliedRuleCountsByKind = try container.decodeIfPresent([String: Int].self, forKey: .appliedRuleCountsByKind)
            ?? [:]
        ignoredRuleCountsByReason = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .ignoredRuleCountsByReason
        ) ?? [:]
        unobservedRuleCountsByKind = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .unobservedRuleCountsByKind
        ) ?? [:]
    }
}

public protocol LVSBackend: Sendable {
    var backendID: String { get }

    func run(_ request: LVSRequest) async throws -> LVSExecutionResult
}

public typealias LVSExecutionCancellationCheck = @Sendable () async throws -> Bool

public protocol LVSCancellableBackend: LVSBackend {
    func run(
        _ request: LVSRequest,
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> LVSExecutionResult
}

public protocol LVSLayoutNetlistExtracting: Sendable {
    func extractLayoutNetlist(
        gds: URL,
        topCell: String,
        into directory: URL,
        timeoutSeconds: Double
    ) async throws -> URL

    func extractLayoutNetlist(
        gds: URL,
        topCell: String,
        into directory: URL,
        timeoutSeconds: Double,
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> URL
}

public extension LVSLayoutNetlistExtracting {
    func extractLayoutNetlist(
        gds: URL,
        topCell: String,
        into directory: URL,
        timeoutSeconds: Double,
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> URL {
        try await extractLayoutNetlist(
            gds: gds,
            topCell: topCell,
            into: directory,
            timeoutSeconds: timeoutSeconds
        )
    }
}

public enum LVSError: Error, LocalizedError, Equatable {
    case invalidInput(String)
    case backendUnavailable(String)
    case backendFailed(String)
    case artifactWriteFailed(String)
    case waiverApplicationFailed(String)
    case unscopedWaiver(id: String)
    case invalidWaiver(id: String, reason: String)
    case cancelled(String)

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
        case .waiverApplicationFailed(let message):
            return "LVS waiver application failed: \(message)"
        case .unscopedWaiver(let id):
            return "LVS waiver is missing a scoped selector: \(id)"
        case .invalidWaiver(let id, let reason):
            return "LVS waiver is invalid (\(reason)): \(id)"
        case .cancelled(let message):
            return "LVS cancelled: \(message)"
        }
    }
}
