import Foundation

public struct LVSCorpusCoverageAuditPolicy: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 2

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
        self.minimumCaseCount = minimumCaseCount
        self.maxReportAgeSeconds = maxReportAgeSeconds
        self.requirements = requirements.sorted { $0.requirementID < $1.requirementID }
    }

    public static var netgenFoundryExpansion: LVSCorpusCoverageAuditPolicy {
        LVSCorpusCoverageAuditPolicy(
            policyID: "lvs.production-observed-assertions.v2",
            minimumCaseCount: 7,
            requirements: [
                Requirement(
                    requirementID: "independent-oracle",
                    title: "Independent oracle agreement",
                    requiredObservedAssertions: ["oracleAgreement:true", "oracleIndependence:ready"],
                    suggestedActions: ["run_lvs_corpus_with_netgen_oracle"]
                ),
                Requirement(
                    requirementID: "match-verdict",
                    title: "Positive equivalence verdict",
                    requiredObservedAssertions: ["verdict:match"],
                    suggestedActions: ["add_positive_lvs_case"]
                ),
                Requirement(
                    requirementID: "mismatch-verdict",
                    title: "Negative equivalence verdict",
                    requiredObservedAssertions: ["verdict:mismatch"],
                    suggestedActions: ["add_negative_lvs_case"]
                ),
                Requirement(
                    requirementID: "model-fault-diagnostic",
                    title: "Model fault diagnostic",
                    requiredObservedAssertions: ["diagnosticRule:LVS_MODEL_MISMATCH"],
                    suggestedActions: ["add_model_fault_lvs_case"]
                ),
                Requirement(
                    requirementID: "bounded-execution",
                    title: "Bounded execution",
                    requiredObservedAssertions: ["durationBudget:within-budget", "cancellation:cancelled"],
                    suggestedActions: ["run_lvs_bounded_execution_probes"]
                ),
                Requirement(
                    requirementID: "deterministic-result",
                    title: "Deterministic normalized result",
                    requiredObservedAssertions: ["determinism:stable"],
                    suggestedActions: ["run_lvs_determinism_probe"]
                ),
                Requirement(
                    requirementID: "review-artifacts",
                    title: "Reviewable correspondence artifacts",
                    requiredObservedAssertions: ["reportArtifact", "manifestArtifact", "correspondenceArtifact"],
                    suggestedActions: ["retain_lvs_review_artifacts"]
                ),
                Requirement(
                    requirementID: "layout-extraction",
                    title: "Layout extraction artifact",
                    requiredObservedAssertions: [
                        "extractionArtifact",
                        "extractionProductionEligibility:eligible",
                    ],
                    suggestedActions: ["run_native_gds_lvs_case"]
                ),
                Requirement(
                    requirementID: "sky130-digital-cell-matrix",
                    title: "Sky130 digital MOS cell matrix",
                    requiredObservedAssertions: [
                        "extractionProductionEligibility:eligible",
                        "oracleAgreement:true",
                        "verdict:match",
                    ],
                    minimumCaseCount: 20,
                    suggestedActions: ["run_sky130_digital_cell_matrix"]
                ),
                Requirement(
                    requirementID: "sky130-foundry-device-deck",
                    title: "Sky130 foundry device policy deck",
                    requiredObservedAssertions: [
                        "devicePolicyApplication:complete",
                        "devicePolicyImport:satisfied",
                        "devicePolicyRule:blackbox",
                        "devicePolicyRule:equate",
                        "devicePolicyRule:equate-pins",
                        "devicePolicyRule:ignore-class",
                        "devicePolicyRule:permute",
                        "devicePolicyRule:property",
                    ],
                    minimumCaseCount: 20,
                    suggestedActions: ["run_sky130_foundry_device_deck_matrix"]
                ),
                Requirement(
                    requirementID: "hierarchy-matrix",
                    title: "Nested hierarchy matrix",
                    requiredObservedAssertions: ["hierarchyDepth:1"],
                    minimumCaseCount: 5,
                    suggestedActions: ["run_hierarchical_lvs_matrix"]
                ),
                Requirement(
                    requirementID: "analog-structure-matrix",
                    title: "Analog structure matrix",
                    requiredObservedAssertions: ["structureClass:analog"],
                    minimumCaseCount: 10,
                    suggestedActions: ["run_analog_structure_lvs_matrix"]
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
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported LVS corpus coverage audit policy schema version: \(schemaVersion)."
            )
        }
        policyID = try container.decode(String.self, forKey: .policyID)
        requireQualifiedCorpus = try container.decodeIfPresent(Bool.self, forKey: .requireQualifiedCorpus) ?? true
        requireOracleAgreement = try container.decodeIfPresent(Bool.self, forKey: .requireOracleAgreement) ?? true
        minimumCaseCount = try container.decodeIfPresent(Int.self, forKey: .minimumCaseCount) ?? 1
        maxReportAgeSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .maxReportAgeSeconds
        )
        requirements = try container.decodeIfPresent([Requirement].self, forKey: .requirements) ?? []
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
            errors.append("The coverage policy schema version is unsupported.")
        }
        if policyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("The coverage policy ID must not be empty.")
        }
        if minimumCaseCount < 1 {
            errors.append("The coverage policy minimumCaseCount must be at least one.")
        }
        if let maxReportAgeSeconds,
           !maxReportAgeSeconds.isFinite || maxReportAgeSeconds < 0 {
            errors.append("The coverage policy maxReportAgeSeconds must be finite and nonnegative.")
        }
        if requirements.isEmpty {
            errors.append("The coverage policy must declare at least one observed-assertion requirement.")
        }
        let requirementIDs = requirements.map {
            $0.requirementID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if Set(requirementIDs).count != requirementIDs.count {
            errors.append("Coverage policy requirement IDs must be unique.")
        }
        for requirement in requirements {
            errors.append(contentsOf: requirement.validationErrors)
        }
        return errors
    }

    public struct Requirement: Sendable, Hashable, Codable {
        public let requirementID: String
        public let title: String
        public let requiredObservedAssertions: [String]
        public let minimumCaseCount: Int
        public let suggestedActions: [String]

        public init(
            requirementID: String,
            title: String,
            requiredObservedAssertions: [String],
            minimumCaseCount: Int = 1,
            suggestedActions: [String] = []
        ) {
            self.requirementID = requirementID
            self.title = title
            self.requiredObservedAssertions = Self.normalized(requiredObservedAssertions)
            self.minimumCaseCount = minimumCaseCount
            self.suggestedActions = Self.normalized(suggestedActions)
        }

        private enum CodingKeys: String, CodingKey {
            case requirementID
            case title
            case requiredObservedAssertions
            case minimumCaseCount
            case suggestedActions
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            requirementID = try container.decode(String.self, forKey: .requirementID)
            title = try container.decode(String.self, forKey: .title)
            requiredObservedAssertions = Self.normalized(try container.decodeIfPresent(
                [String].self,
                forKey: .requiredObservedAssertions
            ) ?? [])
            minimumCaseCount = try container.decodeIfPresent(Int.self, forKey: .minimumCaseCount) ?? 1
            suggestedActions = Self.normalized(try container.decodeIfPresent(
                [String].self,
                forKey: .suggestedActions
            ) ?? [])
        }

        private static func normalized(_ values: [String]) -> [String] {
            Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
                .sorted()
        }

        fileprivate var validationErrors: [String] {
            var errors: [String] = []
            let normalizedID = requirementID.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedID.isEmpty {
                errors.append("A coverage policy requirement ID is empty.")
            }
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("Coverage policy requirement '\(normalizedID)' has an empty title.")
            }
            if requiredObservedAssertions.isEmpty {
                errors.append("Coverage policy requirement '\(normalizedID)' has no observed assertions.")
            }
            if minimumCaseCount < 1 {
                errors.append("Coverage policy requirement '\(normalizedID)' must require at least one case.")
            }
            return errors
        }
    }
}
