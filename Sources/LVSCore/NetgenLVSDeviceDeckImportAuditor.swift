import Foundation

public enum NetgenLVSDeviceDeckImportAuditStatus: String, Codable, Sendable, Hashable {
    case satisfied
    case incomplete
    case blocked
}

public struct NetgenLVSDeviceDeckImportAuditPolicy: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let policyID: String
    public let minimumDeviceCount: Int
    public let minimumPolicyRuleCount: Int
    public let maximumUnresolvedPolicyRuleCount: Int
    public let allowPartialImport: Bool
    public let requiredDeviceFamilyCounts: [String: Int]
    public let requiredPolicyRuleCounts: [String: Int]

    public init(
        schemaVersion: Int = NetgenLVSDeviceDeckImportAuditPolicy.currentSchemaVersion,
        policyID: String,
        minimumDeviceCount: Int,
        minimumPolicyRuleCount: Int,
        maximumUnresolvedPolicyRuleCount: Int,
        allowPartialImport: Bool,
        requiredDeviceFamilyCounts: [String: Int] = [:],
        requiredPolicyRuleCounts: [String: Int] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.policyID = policyID
        self.minimumDeviceCount = minimumDeviceCount
        self.minimumPolicyRuleCount = minimumPolicyRuleCount
        self.maximumUnresolvedPolicyRuleCount = maximumUnresolvedPolicyRuleCount
        self.allowPartialImport = allowPartialImport
        self.requiredDeviceFamilyCounts = requiredDeviceFamilyCounts
        self.requiredPolicyRuleCounts = requiredPolicyRuleCounts
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case policyID
        case minimumDeviceCount
        case minimumPolicyRuleCount
        case maximumUnresolvedPolicyRuleCount
        case allowPartialImport
        case requiredDeviceFamilyCounts
        case requiredPolicyRuleCounts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported Netgen LVS device-deck audit policy schema version: \(schemaVersion)."
            )
        }
        policyID = try container.decode(String.self, forKey: .policyID)
        minimumDeviceCount = try container.decode(Int.self, forKey: .minimumDeviceCount)
        minimumPolicyRuleCount = try container.decode(Int.self, forKey: .minimumPolicyRuleCount)
        maximumUnresolvedPolicyRuleCount = try container.decode(
            Int.self,
            forKey: .maximumUnresolvedPolicyRuleCount
        )
        allowPartialImport = try container.decode(Bool.self, forKey: .allowPartialImport)
        requiredDeviceFamilyCounts = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .requiredDeviceFamilyCounts
        ) ?? [:]
        requiredPolicyRuleCounts = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .requiredPolicyRuleCounts
        ) ?? [:]
        guard validationErrors.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .policyID,
                in: container,
                debugDescription: validationErrors.joined(separator: " ")
            )
        }
    }

    package var validationErrors: [String] {
        var errors: [String] = []
        if schemaVersion != Self.currentSchemaVersion {
            errors.append("The device-deck audit policy schema version is unsupported.")
        }
        if policyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("The device-deck audit policy ID must not be empty.")
        }
        if minimumDeviceCount < 0 {
            errors.append("minimumDeviceCount must be nonnegative.")
        }
        if minimumPolicyRuleCount < 0 {
            errors.append("minimumPolicyRuleCount must be nonnegative.")
        }
        if maximumUnresolvedPolicyRuleCount < 0 {
            errors.append("maximumUnresolvedPolicyRuleCount must be nonnegative.")
        }
        if requiredDeviceFamilyCounts.contains(where: {
            $0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.value < 0
        }) {
            errors.append("Required device-family names must be nonempty and their counts must be nonnegative.")
        }
        if requiredPolicyRuleCounts.contains(where: {
            $0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.value < 0
        }) {
            errors.append("Required policy-rule names must be nonempty and their counts must be nonnegative.")
        }
        return errors
    }

    public static var deviceSeedReadiness: NetgenLVSDeviceDeckImportAuditPolicy {
        NetgenLVSDeviceDeckImportAuditPolicy(
            policyID: "lvs-device-seed-readiness-v1",
            minimumDeviceCount: 1,
            minimumPolicyRuleCount: 1,
            maximumUnresolvedPolicyRuleCount: 0,
            allowPartialImport: false,
            requiredPolicyRuleCounts: [
                "equate-pins": 1,
                "permute": 1,
                "property": 1,
            ]
        )
    }
}

public struct NetgenLVSDeviceDeckImportAuditRequirement: Codable, Sendable, Hashable {
    public let requirementID: String
    public let category: String
    public let status: NetgenLVSDeviceDeckImportAuditStatus
    public let observed: Int
    public let required: Int
    public let message: String

    public init(
        requirementID: String,
        category: String,
        status: NetgenLVSDeviceDeckImportAuditStatus,
        observed: Int,
        required: Int,
        message: String
    ) {
        self.requirementID = requirementID
        self.category = category
        self.status = status
        self.observed = observed
        self.required = required
        self.message = message
    }
}

public struct NetgenLVSDeviceDeckImportAuditSummary: Codable, Sendable, Hashable {
    public let requirementCount: Int
    public let satisfiedRequirementCount: Int
    public let incompleteRequirementCount: Int
    public let blockedRequirementCount: Int
    public let importedDeviceCount: Int
    public let importedPolicyRuleCount: Int
    public let unresolvedPolicyRuleCount: Int

    public init(
        requirementCount: Int,
        satisfiedRequirementCount: Int,
        incompleteRequirementCount: Int,
        blockedRequirementCount: Int,
        importedDeviceCount: Int,
        importedPolicyRuleCount: Int,
        unresolvedPolicyRuleCount: Int
    ) {
        self.requirementCount = requirementCount
        self.satisfiedRequirementCount = satisfiedRequirementCount
        self.incompleteRequirementCount = incompleteRequirementCount
        self.blockedRequirementCount = blockedRequirementCount
        self.importedDeviceCount = importedDeviceCount
        self.importedPolicyRuleCount = importedPolicyRuleCount
        self.unresolvedPolicyRuleCount = unresolvedPolicyRuleCount
    }
}

public struct NetgenLVSDeviceDeckImportAudit: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let kind: String
    public let auditID: String
    public let checkedAt: String
    public let status: NetgenLVSDeviceDeckImportAuditStatus
    public let policyID: String
    public let seedPath: String?
    public let reportPath: String?
    public let sourcePath: String
    public let summary: NetgenLVSDeviceDeckImportAuditSummary
    public let requirements: [NetgenLVSDeviceDeckImportAuditRequirement]
    public let importDiagnostics: [NetgenLVSDeviceDeckImportDiagnostic]

    public init(
        schemaVersion: Int = 1,
        kind: String = "lvs-device-import-audit",
        auditID: String,
        checkedAt: String,
        status: NetgenLVSDeviceDeckImportAuditStatus,
        policyID: String,
        seedPath: String?,
        reportPath: String?,
        sourcePath: String,
        summary: NetgenLVSDeviceDeckImportAuditSummary,
        requirements: [NetgenLVSDeviceDeckImportAuditRequirement],
        importDiagnostics: [NetgenLVSDeviceDeckImportDiagnostic]
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.auditID = auditID
        self.checkedAt = checkedAt
        self.status = status
        self.policyID = policyID
        self.seedPath = seedPath
        self.reportPath = reportPath
        self.sourcePath = sourcePath
        self.summary = summary
        self.requirements = requirements
        self.importDiagnostics = importDiagnostics
    }
}

public struct NetgenLVSDeviceDeckImportAuditor: Sendable {
    public init() {}

    public func audit(
        seed: NetgenLVSDevicePolicySeed,
        report: NetgenLVSDeviceDeckImportReport,
        seedPath: String? = nil,
        reportPath: String? = nil,
        policy: NetgenLVSDeviceDeckImportAuditPolicy = .deviceSeedReadiness,
        auditID: String = "lvs-device-import-audit",
        checkedAt: String? = nil
    ) -> NetgenLVSDeviceDeckImportAudit {
        let unresolvedCount = seed.policyRules.filter {
            !$0.unresolvedVariableNames.isEmpty
        }.count
        var requirements = requirements(
            seed: seed,
            report: report,
            unresolvedCount: unresolvedCount,
            policy: policy
        )
        if !policy.validationErrors.isEmpty {
            requirements.insert(NetgenLVSDeviceDeckImportAuditRequirement(
                requirementID: "audit-policy-validity",
                category: "policy-validity",
                status: .blocked,
                observed: 0,
                required: 1,
                message: policy.validationErrors.joined(separator: " ")
            ), at: 0)
        }
        let blockedCount = requirements.filter { $0.status == .blocked }.count
        let incompleteCount = requirements.filter { $0.status == .incomplete }.count
        let satisfiedCount = requirements.filter { $0.status == .satisfied }.count
        let status: NetgenLVSDeviceDeckImportAuditStatus
        if blockedCount > 0 {
            status = .blocked
        } else if incompleteCount > 0 {
            status = .incomplete
        } else {
            status = .satisfied
        }
        return NetgenLVSDeviceDeckImportAudit(
            auditID: auditID,
            checkedAt: checkedAt ?? Self.utcTimestamp(),
            status: status,
            policyID: policy.policyID,
            seedPath: seedPath,
            reportPath: reportPath,
            sourcePath: report.sourcePath.isEmpty ? seed.sourcePath : report.sourcePath,
            summary: NetgenLVSDeviceDeckImportAuditSummary(
                requirementCount: requirements.count,
                satisfiedRequirementCount: satisfiedCount,
                incompleteRequirementCount: incompleteCount,
                blockedRequirementCount: blockedCount,
                importedDeviceCount: report.importedDeviceCount,
                importedPolicyRuleCount: report.importedPolicyRuleCount,
                unresolvedPolicyRuleCount: unresolvedCount
            ),
            requirements: requirements,
            importDiagnostics: report.diagnostics
        )
    }

    private func requirements(
        seed: NetgenLVSDevicePolicySeed,
        report: NetgenLVSDeviceDeckImportReport,
        unresolvedCount: Int,
        policy: NetgenLVSDeviceDeckImportAuditPolicy
    ) -> [NetgenLVSDeviceDeckImportAuditRequirement] {
        var requirements: [NetgenLVSDeviceDeckImportAuditRequirement] = []
        requirements.append(importStatusRequirement(report: report, policy: policy))
        requirements.append(thresholdRequirement(
            requirementID: "minimum-device-count",
            category: "device-count",
            observed: report.importedDeviceCount,
            required: policy.minimumDeviceCount,
            message: "Imported device count must meet the seed readiness policy."
        ))
        requirements.append(thresholdRequirement(
            requirementID: "minimum-policy-rule-count",
            category: "policy-rule-count",
            observed: report.importedPolicyRuleCount,
            required: policy.minimumPolicyRuleCount,
            message: "Imported policy rule count must meet the seed readiness policy."
        ))
        requirements.append(maximumRequirement(
            requirementID: "maximum-unresolved-policy-rule-count",
            category: "policy-rule-resolution",
            observed: unresolvedCount,
            required: policy.maximumUnresolvedPolicyRuleCount,
            message: "Imported policy rules must not retain unresolved Netgen variables."
        ))
        for family in policy.requiredDeviceFamilyCounts.keys.sorted() {
            let required = policy.requiredDeviceFamilyCounts[family] ?? 0
            requirements.append(thresholdRequirement(
                requirementID: "device-family-\(family)",
                category: "device-family",
                observed: report.deviceFamilyCounts[family] ?? 0,
                required: required,
                message: "Required device family '\(family)' must be represented in the imported seed."
            ))
        }
        for kind in policy.requiredPolicyRuleCounts.keys.sorted() {
            let required = policy.requiredPolicyRuleCounts[kind] ?? 0
            requirements.append(thresholdRequirement(
                requirementID: "policy-rule-\(kind)",
                category: "policy-rule-kind",
                observed: report.policyRuleCounts[kind] ?? 0,
                required: required,
                message: "Required policy rule kind '\(kind)' must be represented in the imported seed."
            ))
        }
        requirements.append(seedConsistencyRequirement(seed: seed, report: report))
        return requirements
    }

    private func importStatusRequirement(
        report: NetgenLVSDeviceDeckImportReport,
        policy: NetgenLVSDeviceDeckImportAuditPolicy
    ) -> NetgenLVSDeviceDeckImportAuditRequirement {
        let status: NetgenLVSDeviceDeckImportAuditStatus
        let observed: Int
        switch report.status {
        case .complete:
            status = .satisfied
            observed = 2
        case .partial:
            status = policy.allowPartialImport ? .satisfied : .incomplete
            observed = 1
        case .blocked:
            status = .blocked
            observed = 0
        }
        return NetgenLVSDeviceDeckImportAuditRequirement(
            requirementID: "import-status",
            category: "import-status",
            status: status,
            observed: observed,
            required: policy.allowPartialImport ? 1 : 2,
            message: "Import status must be usable under the audit policy."
        )
    }

    private func seedConsistencyRequirement(
        seed: NetgenLVSDevicePolicySeed,
        report: NetgenLVSDeviceDeckImportReport
    ) -> NetgenLVSDeviceDeckImportAuditRequirement {
        let consistent = seed.devices.count == report.importedDeviceCount
            && seed.policyRules.count == report.importedPolicyRuleCount
        return NetgenLVSDeviceDeckImportAuditRequirement(
            requirementID: "seed-report-consistency",
            category: "artifact-consistency",
            status: consistent ? .satisfied : .blocked,
            observed: consistent ? 1 : 0,
            required: 1,
            message: "Policy seed element counts must match the import report."
        )
    }

    private func thresholdRequirement(
        requirementID: String,
        category: String,
        observed: Int,
        required: Int,
        message: String
    ) -> NetgenLVSDeviceDeckImportAuditRequirement {
        NetgenLVSDeviceDeckImportAuditRequirement(
            requirementID: requirementID,
            category: category,
            status: observed >= required ? .satisfied : .incomplete,
            observed: observed,
            required: required,
            message: message
        )
    }

    private func maximumRequirement(
        requirementID: String,
        category: String,
        observed: Int,
        required: Int,
        message: String
    ) -> NetgenLVSDeviceDeckImportAuditRequirement {
        NetgenLVSDeviceDeckImportAuditRequirement(
            requirementID: requirementID,
            category: category,
            status: observed <= required ? .satisfied : .incomplete,
            observed: observed,
            required: required,
            message: message
        )
    }

    private static func utcTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
}
