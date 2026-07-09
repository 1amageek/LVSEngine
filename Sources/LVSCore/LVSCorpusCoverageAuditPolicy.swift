import Foundation

public struct LVSCorpusCoverageAuditPolicy: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let policyID: String
    public let requireQualifiedCorpus: Bool
    public let requireOracleAgreement: Bool
    public let minimumCaseCount: Int
    public let maxReportAgeSeconds: Double?
    public let requirements: [Requirement]

    public init(
        schemaVersion: Int = LVSCorpusCoverageAuditPolicy.currentSchemaVersion,
        policyID: String,
        requireQualifiedCorpus: Bool = true,
        requireOracleAgreement: Bool = true,
        minimumCaseCount: Int = 1,
        maxReportAgeSeconds: Double? = nil,
        requirements: [Requirement]
    ) {
        self.schemaVersion = schemaVersion
        self.policyID = policyID
        self.requireQualifiedCorpus = requireQualifiedCorpus
        self.requireOracleAgreement = requireOracleAgreement
        self.minimumCaseCount = max(0, minimumCaseCount)
        if let maxReportAgeSeconds, maxReportAgeSeconds.isFinite, maxReportAgeSeconds >= 0 {
            self.maxReportAgeSeconds = maxReportAgeSeconds
        } else {
            self.maxReportAgeSeconds = nil
        }
        self.requirements = requirements.sorted { $0.requirementID < $1.requirementID }
    }

    public static var netgenFoundryExpansion: LVSCorpusCoverageAuditPolicy {
        LVSCorpusCoverageAuditPolicy(
            policyID: "lvs.netgen-foundry-expansion.v1",
            minimumCaseCount: 8,
            requirements: [
                Requirement(
                    requirementID: "netgen-oracle-baseline",
                    title: "Netgen oracle lane baseline",
                    requiredCoverageTags: ["external.netgen", "layout.spice", "lvs.match"],
                    suggestedActions: ["retain_netgen_external_oracle_lane"]
                ),
                Requirement(
                    requirementID: "netlist-mismatch-verdicts",
                    title: "Netlist mismatch verdicts",
                    requiredCoverageTags: ["diagnostic.rule-id", "failure.expected", "lvs.model-mismatch"],
                    suggestedActions: ["add_netgen_mismatch_cases"]
                ),
                Requirement(
                    requirementID: "hierarchy-coverage",
                    title: "Hierarchy coverage",
                    requiredCoverageTags: ["lvs.hierarchy"],
                    suggestedActions: ["add_hierarchical_netgen_case"]
                ),
                Requirement(
                    requirementID: "device-breadth-coverage",
                    title: "Device breadth coverage",
                    requiredCoverageTags: ["lvs.device-breadth", "lvs.bjt", "lvs.diode", "lvs.sources"],
                    suggestedActions: ["add_device_family_netgen_cases"]
                ),
                Requirement(
                    requirementID: "source-device-breadth-coverage",
                    title: "Source device breadth coverage",
                    requiredCoverageTags: [
                        "external.netgen",
                        "lvs.controlled-sources",
                        "lvs.independent-sources",
                        "lvs.inductor",
                        "lvs.sources",
                    ],
                    suggestedActions: ["add_source_device_family_netgen_cases"]
                ),
                Requirement(
                    requirementID: "terminal-permutation-coverage",
                    title: "Terminal permutation coverage",
                    requiredCoverageTags: [
                        "external.netgen",
                        "lvs.mos-source-drain-permutation",
                        "lvs.passive-terminal-permutation",
                        "lvs.symmetric-terminals",
                    ],
                    suggestedActions: ["add_symmetric_terminal_netgen_case"]
                ),
                Requirement(
                    requirementID: "netgen-policy-gap-coverage",
                    title: "Netgen policy gap coverage",
                    requiredCoverageTags: [
                        "lvs.netgen.policy-gap.global-nets",
                        "lvs.netgen.policy-gap.multiplicity",
                    ],
                    suggestedActions: ["retain_oracle_policy_gap_verdicts"]
                ),
                Requirement(
                    requirementID: "parallel-device-policy-gap-coverage",
                    title: "Parallel device policy gap coverage",
                    requiredCoverageTags: [
                        "external.netgen",
                        "lvs.netgen.policy-gap.multiplicity",
                        "lvs.parallel-devices",
                    ],
                    suggestedActions: ["retain_parallel_device_policy_gap_verdicts"]
                ),
                Requirement(
                    requirementID: "standard-layout-extraction-coverage",
                    title: "Standard layout extraction coverage",
                    requiredCoverageTags: [
                        "layout.gds",
                        "lvs.extract.connectivity",
                        "lvs.extract.devices",
                        "lvs.input.gds",
                    ],
                    suggestedActions: ["add_extracted_layout_netgen_oracle_cases"]
                ),
                Requirement(
                    requirementID: "pin-policy-coverage",
                    title: "Pin and terminal policy coverage",
                    requiredCoverageTags: [
                        "lvs.netgen.policy-gap.terminal-equivalence",
                        "lvs.terminal-equivalence-policy",
                    ],
                    suggestedActions: ["add_terminal_equivalence_netgen_oracle_case"]
                ),
                Requirement(
                    requirementID: "diode-terminal-policy-gap-coverage",
                    title: "Diode terminal policy gap coverage",
                    requiredCoverageTags: [
                        "external.netgen",
                        "lvs.diode-terminal-equivalence",
                        "lvs.netgen.policy-gap.terminal-equivalence",
                        "lvs.terminal-equivalence-policy",
                    ],
                    suggestedActions: ["retain_diode_terminal_policy_gap_verdicts"]
                ),
                Requirement(
                    requirementID: "parameter-policy-coverage",
                    title: "Parameter policy coverage",
                    requiredCoverageTags: [
                        "lvs.netgen.policy-gap.parameter-mismatch",
                        "lvs.parameter-mismatch",
                    ],
                    suggestedActions: ["add_parameter_policy_netgen_oracle_case"]
                ),
            ]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case policyID
        case requireQualifiedCorpus
        case requireOracleAgreement
        case minimumCaseCount
        case maxReportAgeSeconds
        case requirements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? LVSCorpusCoverageAuditPolicy.currentSchemaVersion
        policyID = try container.decode(String.self, forKey: .policyID)
        requireQualifiedCorpus = try container.decodeIfPresent(Bool.self, forKey: .requireQualifiedCorpus) ?? true
        requireOracleAgreement = try container.decodeIfPresent(Bool.self, forKey: .requireOracleAgreement) ?? true
        minimumCaseCount = max(0, try container.decodeIfPresent(Int.self, forKey: .minimumCaseCount) ?? 1)
        if let decodedMaxReportAgeSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .maxReportAgeSeconds
        ), decodedMaxReportAgeSeconds.isFinite, decodedMaxReportAgeSeconds >= 0 {
            maxReportAgeSeconds = decodedMaxReportAgeSeconds
        } else {
            maxReportAgeSeconds = nil
        }
        requirements = try container.decodeIfPresent([Requirement].self, forKey: .requirements) ?? []
    }

    public struct Requirement: Sendable, Hashable, Codable {
        public let requirementID: String
        public let title: String
        public let requiredCoverageTags: [String]
        public let minimumCaseCount: Int
        public let suggestedActions: [String]

        public init(
            requirementID: String,
            title: String,
            requiredCoverageTags: [String],
            minimumCaseCount: Int = 1,
            suggestedActions: [String] = []
        ) {
            self.requirementID = requirementID
            self.title = title
            self.requiredCoverageTags = Self.normalized(requiredCoverageTags)
            self.minimumCaseCount = max(1, minimumCaseCount)
            self.suggestedActions = Self.normalized(suggestedActions)
        }

        private enum CodingKeys: String, CodingKey {
            case requirementID
            case title
            case requiredCoverageTags
            case minimumCaseCount
            case suggestedActions
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            requirementID = try container.decode(String.self, forKey: .requirementID)
            title = try container.decode(String.self, forKey: .title)
            requiredCoverageTags = Self.normalized(try container.decodeIfPresent(
                [String].self,
                forKey: .requiredCoverageTags
            ) ?? [])
            minimumCaseCount = max(1, try container.decodeIfPresent(Int.self, forKey: .minimumCaseCount) ?? 1)
            suggestedActions = Self.normalized(try container.decodeIfPresent(
                [String].self,
                forKey: .suggestedActions
            ) ?? [])
        }

        private static func normalized(_ values: [String]) -> [String] {
            Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
                .sorted()
        }
    }
}
