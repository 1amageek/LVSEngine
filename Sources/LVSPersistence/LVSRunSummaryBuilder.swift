import Foundation
import LVSCore

public struct LVSRunSummaryBuilder: Sendable {
    public init() {}

    public func build(reportURL: URL) throws -> LVSRunSummaryReport {
        do {
            let data = try Data(contentsOf: reportURL)
            let result = try JSONDecoder().decode(LVSExecutionResult.self, from: data)
            return build(result: result, reportURL: reportURL)
        } catch {
            throw LVSError.invalidInput("Unable to load LVS report summary input: \(error.localizedDescription)")
        }
    }

    public func build(
        result: LVSExecutionResult,
        reportURL: URL? = nil
    ) -> LVSRunSummaryReport {
        LVSRunSummaryReport(
            reportURL: reportURL ?? result.reportURL,
            manifestURL: result.artifactManifestURL,
            summary: LVSRunSummary(
                status: result.result.passed ? "passed" : "failed",
                backendID: result.result.backendID,
                toolName: result.result.toolName,
                topCell: result.request.topCell,
                layoutInputKind: layoutInputKind(result.request),
                passed: result.result.passed,
                completed: result.result.completed,
                diagnosticSummary: diagnosticSummary(result.result.diagnostics),
                activeMismatchCount: result.result.diagnostics.filter { $0.severity == .error && !$0.isWaived }.count,
                waivedMismatchCount: result.result.diagnostics.filter { $0.severity == .error && $0.isWaived }.count,
                mismatchBuckets: mismatchBuckets(result.result.diagnostics),
                extractedLayoutNetlistURL: result.extractedLayoutNetlistURL,
                unusedWaiverIDs: result.waiverReport?.unusedWaiverIDs.sorted() ?? [],
                devicePolicySummary: result.devicePolicyReport.map(LVSDevicePolicyRunSummary.init(report:))
            )
        )
    }

    private func layoutInputKind(_ request: LVSRequest) -> String {
        if request.layoutGDSURL != nil {
            return "layout-gds"
        }
        if request.layoutNetlistURL != nil {
            return "layout-netlist"
        }
        return "unknown"
    }

    private func diagnosticSummary(_ diagnostics: [LVSDiagnostic]) -> LVSDiagnosticSummary {
        diagnostics.reduce(into: LVSDiagnosticSummary(infoCount: 0, warningCount: 0, errorCount: 0)) { summary, diagnostic in
            switch diagnostic.severity {
            case .info:
                summary = LVSDiagnosticSummary(
                    infoCount: summary.infoCount + 1,
                    warningCount: summary.warningCount,
                    errorCount: summary.errorCount,
                    waivedErrorCount: summary.waivedErrorCount
                )
            case .warning:
                summary = LVSDiagnosticSummary(
                    infoCount: summary.infoCount,
                    warningCount: summary.warningCount + 1,
                    errorCount: summary.errorCount,
                    waivedErrorCount: summary.waivedErrorCount
                )
            case .error:
                summary = LVSDiagnosticSummary(
                    infoCount: summary.infoCount,
                    warningCount: summary.warningCount,
                    errorCount: summary.errorCount + (diagnostic.isWaived ? 0 : 1),
                    waivedErrorCount: summary.waivedErrorCount + (diagnostic.isWaived ? 1 : 0)
                )
            }
        }
    }

    private func mismatchBuckets(_ diagnostics: [LVSDiagnostic]) -> [LVSMismatchBucketSummary] {
        let errors = diagnostics.filter { $0.severity == .error }
        var buckets: [LVSMismatchBucketKey: LVSMismatchBucketAccumulator] = [:]
        for diagnostic in errors {
            let key = LVSMismatchBucketKey(
                ruleID: diagnostic.ruleID,
                category: diagnostic.category,
                componentSignature: diagnostic.componentSignature,
                parameterName: diagnostic.parameterName,
                layoutModel: diagnostic.layoutModel,
                schematicModel: diagnostic.schematicModel
            )
            buckets[key, default: LVSMismatchBucketAccumulator(key: key)].add(diagnostic)
        }
        return buckets.values
            .map { $0.summary }
            .sorted { lhs, rhs in
                if lhs.activeCount != rhs.activeCount {
                    return lhs.activeCount > rhs.activeCount
                }
                if lhs.waivedCount != rhs.waivedCount {
                    return lhs.waivedCount > rhs.waivedCount
                }
                return lhs.sortKey < rhs.sortKey
            }
    }
}

public struct LVSRunSummaryReport: Sendable, Codable, Hashable {
    public let schemaVersion: Int
    public let reportURL: URL?
    public let manifestURL: URL?
    public let summary: LVSRunSummary

    public init(
        schemaVersion: Int = 1,
        reportURL: URL?,
        manifestURL: URL?,
        summary: LVSRunSummary
    ) {
        self.schemaVersion = schemaVersion
        self.reportURL = reportURL
        self.manifestURL = manifestURL
        self.summary = summary
    }
}

public struct LVSRunSummary: Sendable, Codable, Hashable {
    public let status: String
    public let backendID: String
    public let toolName: String
    public let topCell: String
    public let layoutInputKind: String
    public let passed: Bool
    public let completed: Bool
    public let diagnosticSummary: LVSDiagnosticSummary
    public let activeMismatchCount: Int
    public let waivedMismatchCount: Int
    public let mismatchBuckets: [LVSMismatchBucketSummary]
    public let extractedLayoutNetlistURL: URL?
    public let unusedWaiverIDs: [String]
    public let devicePolicySummary: LVSDevicePolicyRunSummary?

    public init(
        status: String,
        backendID: String,
        toolName: String,
        topCell: String,
        layoutInputKind: String,
        passed: Bool,
        completed: Bool,
        diagnosticSummary: LVSDiagnosticSummary,
        activeMismatchCount: Int,
        waivedMismatchCount: Int,
        mismatchBuckets: [LVSMismatchBucketSummary],
        extractedLayoutNetlistURL: URL?,
        unusedWaiverIDs: [String],
        devicePolicySummary: LVSDevicePolicyRunSummary? = nil
    ) {
        self.status = status
        self.backendID = backendID
        self.toolName = toolName
        self.topCell = topCell
        self.layoutInputKind = layoutInputKind
        self.passed = passed
        self.completed = completed
        self.diagnosticSummary = diagnosticSummary
        self.activeMismatchCount = activeMismatchCount
        self.waivedMismatchCount = waivedMismatchCount
        self.mismatchBuckets = mismatchBuckets
        self.extractedLayoutNetlistURL = extractedLayoutNetlistURL
        self.unusedWaiverIDs = unusedWaiverIDs
        self.devicePolicySummary = devicePolicySummary
    }
}

public struct LVSMismatchBucketSummary: Sendable, Codable, Hashable {
    public let ruleID: String?
    public let category: String?
    public let componentSignature: String?
    public let parameterName: String?
    public let layoutModel: String?
    public let schematicModel: String?
    public let activeCount: Int
    public let waivedCount: Int
    public let layoutCount: Int?
    public let schematicCount: Int?
    public let layoutPorts: [String]
    public let schematicPorts: [String]
    public let suggestedFixes: [String]

    public init(
        ruleID: String?,
        category: String?,
        componentSignature: String?,
        parameterName: String?,
        layoutModel: String?,
        schematicModel: String?,
        activeCount: Int,
        waivedCount: Int,
        layoutCount: Int?,
        schematicCount: Int?,
        layoutPorts: [String],
        schematicPorts: [String],
        suggestedFixes: [String]
    ) {
        self.ruleID = ruleID
        self.category = category
        self.componentSignature = componentSignature
        self.parameterName = parameterName
        self.layoutModel = layoutModel
        self.schematicModel = schematicModel
        self.activeCount = activeCount
        self.waivedCount = waivedCount
        self.layoutCount = layoutCount
        self.schematicCount = schematicCount
        self.layoutPorts = layoutPorts
        self.schematicPorts = schematicPorts
        self.suggestedFixes = suggestedFixes
    }

    fileprivate var sortKey: String {
        [
            ruleID,
            category,
            componentSignature,
            parameterName,
            layoutModel,
            schematicModel,
        ].map { $0 ?? "" }.joined(separator: "|")
    }
}

private struct LVSMismatchBucketKey: Hashable {
    let ruleID: String?
    let category: String?
    let componentSignature: String?
    let parameterName: String?
    let layoutModel: String?
    let schematicModel: String?
}

private struct LVSMismatchBucketAccumulator {
    let key: LVSMismatchBucketKey
    var activeCount = 0
    var waivedCount = 0
    var layoutCount: Int?
    var schematicCount: Int?
    var layoutPorts: Set<String> = []
    var schematicPorts: Set<String> = []
    var suggestedFixes: Set<String> = []

    mutating func add(_ diagnostic: LVSDiagnostic) {
        if diagnostic.isWaived {
            waivedCount += 1
        } else {
            activeCount += 1
        }
        if layoutCount == nil {
            layoutCount = diagnostic.layoutCount
        }
        if schematicCount == nil {
            schematicCount = diagnostic.schematicCount
        }
        layoutPorts.formUnion(diagnostic.layoutPorts ?? [])
        schematicPorts.formUnion(diagnostic.schematicPorts ?? [])
        if let suggestedFix = diagnostic.suggestedFix {
            suggestedFixes.insert(suggestedFix)
        }
    }

    var summary: LVSMismatchBucketSummary {
        LVSMismatchBucketSummary(
            ruleID: key.ruleID,
            category: key.category,
            componentSignature: key.componentSignature,
            parameterName: key.parameterName,
            layoutModel: key.layoutModel,
            schematicModel: key.schematicModel,
            activeCount: activeCount,
            waivedCount: waivedCount,
            layoutCount: layoutCount,
            schematicCount: schematicCount,
            layoutPorts: layoutPorts.sorted(),
            schematicPorts: schematicPorts.sorted(),
            suggestedFixes: suggestedFixes.sorted()
        )
    }
}
