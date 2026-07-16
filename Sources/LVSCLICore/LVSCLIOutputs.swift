import Foundation
import LVSEngine
import SignoffToolSupport

public struct LVSNetgenDeviceImportCLIOutput: Sendable, Hashable, Codable {
    public let status: NetgenLVSDeviceDeckImportStatus
    public let policyPath: String
    public let reportPath: String?
    public let seedSummary: LVSDevicePolicySeedSummary
    public let importReport: NetgenLVSDeviceDeckImportReport

    public init(
        status: NetgenLVSDeviceDeckImportStatus,
        policyPath: String,
        reportPath: String?,
        seed: NetgenLVSDevicePolicySeed,
        importReport: NetgenLVSDeviceDeckImportReport
    ) {
        self.status = status
        self.policyPath = policyPath
        self.reportPath = reportPath
        self.seedSummary = LVSDevicePolicySeedSummary(seed: seed, report: importReport)
        self.importReport = importReport
    }
}

public struct LVSFoundryDeviceImportCLIOutput: Sendable, Hashable, Codable {
    public let status: NetgenLVSDeviceDeckImportStatus
    public let policyPath: String
    public let reportPath: String?
    public let seedSummary: LVSDevicePolicySeedSummary
    public let importReport: NetgenLVSDeviceDeckImportReport
    public let semanticReport: SignoffDeckSemanticReport

    public init(
        status: NetgenLVSDeviceDeckImportStatus,
        policyPath: String,
        reportPath: String?,
        seed: NetgenLVSDevicePolicySeed,
        importReport: NetgenLVSDeviceDeckImportReport,
        semanticReport: SignoffDeckSemanticReport
    ) {
        self.status = status
        self.policyPath = policyPath
        self.reportPath = reportPath
        self.seedSummary = LVSDevicePolicySeedSummary(seed: seed, report: importReport)
        self.importReport = importReport
        self.semanticReport = semanticReport
    }
}

public struct LVSDevicePolicySeedSummary: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let kind: String
    public let sourcePath: String
    public let deviceCount: Int
    public let policyRuleCount: Int
    public let deviceFamilyCounts: [String: Int]
    public let policyRuleCounts: [String: Int]
    public let unresolvedPolicyRuleCount: Int

    public init(
        schemaVersion: Int,
        kind: String,
        sourcePath: String,
        deviceCount: Int,
        policyRuleCount: Int,
        deviceFamilyCounts: [String: Int],
        policyRuleCounts: [String: Int],
        unresolvedPolicyRuleCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.sourcePath = sourcePath
        self.deviceCount = deviceCount
        self.policyRuleCount = policyRuleCount
        self.deviceFamilyCounts = deviceFamilyCounts
        self.policyRuleCounts = policyRuleCounts
        self.unresolvedPolicyRuleCount = unresolvedPolicyRuleCount
    }

    public init(seed: NetgenLVSDevicePolicySeed, report: NetgenLVSDeviceDeckImportReport) {
        self.init(
            schemaVersion: seed.schemaVersion,
            kind: seed.kind,
            sourcePath: seed.sourcePath,
            deviceCount: seed.devices.count,
            policyRuleCount: seed.policyRules.count,
            deviceFamilyCounts: report.deviceFamilyCounts,
            policyRuleCounts: report.policyRuleCounts,
            unresolvedPolicyRuleCount: seed.policyRules.filter {
                !$0.unresolvedVariableNames.isEmpty
            }.count
        )
    }
}

public struct LVSCorpusAssessmentCLIOutput: Sendable, Hashable, Codable {
    public let status: String
    public let reportPath: String
    public let summary: LVSCorpusSummary
    public let assessment: LVSCorpusAssessment

    public init(
        reportPath: String,
        report: LVSCorpusReport,
        assessment: LVSCorpusAssessment
    ) {
        self.status = assessment.meetsCriteria ? "passed" : "failed"
        self.reportPath = reportPath
        self.summary = report.summary
        self.assessment = assessment
    }
}

public struct LVSCorpusCLIOutput: Sendable, Hashable, Codable {
    public let status: String
    public let reportPath: String
    public let report: LVSCorpusReport

    public init(reportPath: String, report: LVSCorpusReport) {
        self.status = report.assessment.meetsCriteria ? "passed" : "failed"
        self.reportPath = reportPath
        self.report = report
    }
}

public struct LVSCLIOutput: Sendable, Hashable, Codable {
    public let status: String
    public let backendID: String
    public let toolName: String
    public let reportPath: String?
    public let manifestPath: String?
    public let extractedLayoutNetlistPath: String?
    public let diagnosticSummary: LVSDiagnosticSummary
    public let runSummary: LVSRunSummary
    public let diagnostics: [LVSDiagnostic]
    public let waiverReport: LVSWaiverApplicationReport?
    public let devicePolicyReport: LVSDevicePolicyApplicationReport?

    public init(result: LVSExecutionResult) {
        let summaryReport = LVSRunSummaryBuilder().build(result: result)
        self.status = result.result.passed ? "passed" : "failed"
        self.backendID = result.result.backendID
        self.toolName = result.result.toolName
        self.reportPath = result.reportURL?.path(percentEncoded: false)
        self.manifestPath = result.artifactManifestURL?.path(percentEncoded: false)
        self.extractedLayoutNetlistPath = result.extractedLayoutNetlistURL?.path(percentEncoded: false)
        self.diagnostics = result.result.diagnostics
        self.waiverReport = result.waiverReport
        self.devicePolicyReport = result.devicePolicyReport
        self.runSummary = summaryReport.summary
        self.diagnosticSummary = result.result.diagnostics.reduce(
            into: LVSDiagnosticSummary(infoCount: 0, warningCount: 0, errorCount: 0)
        ) { summary, diagnostic in
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
}
