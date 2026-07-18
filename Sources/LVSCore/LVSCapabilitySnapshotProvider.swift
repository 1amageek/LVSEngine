public struct LVSCapabilitySnapshotProvider: Sendable {
    public init() {}

    public func snapshot() -> LVSCapabilitySnapshot {
        LVSCapabilitySnapshot(
            engineID: "lvsengine",
            ownerPackage: "LVSEngine",
            trustEvidenceContract: trustEvidenceContract(),
            backends: [
                nativeBackend(),
                nativeGDSBackend(),
                netgenBackend(),
            ],
            artifacts: artifactContracts(),
            corpus: corpusContract(),
            actionDomain: LVSActionDomainExporter().snapshot(),
            agentContracts: [
                "CLI emits structured JSON for single-run, waiver-review, corpus, corpus observations, coverage-audit, evidence-packet, foundry-deck semantic inventory, Netgen device seed import with compact seedSummary, Netgen device import audit, action-domain, and capability queries.",
                "API exposes typed request/result, mismatch diagnostics, waiver-review report, summary, manifest, corpus, coverage-audit, corpus observation export, evidence-packet, action-domain, repair-hint, and capability models.",
                "Retained corpus reports can be converted into Agent decision material through LVSCorpusEvidencePacketBuilder and lvsengine --evidence-packet-from-corpus-report, including readiness, extracted layout netlist references, metrics, diagnostics, observed assertions, and decision hints.",
                "Retained corpus reports can be audited through LVSCorpusCoverageAuditor and lvsengine --audit-corpus-coverage to expose missing Netgen oracle coverage dimensions without prescribing a fixed repair flow.",
                "Foundry deck semantic inspection is exposed through lvsengine --foundry-deck-semantics and the signoff-foundry-deck-semantics artifact contract.",
                "Netgen LVS device and pin-policy declarations can be imported into an auditable seed through NetgenLVSDeviceDeckImporter and lvsengine --import-netgen-devices --netgen-setup <path>, with concrete $dev foreach expansion, lvs-device-policy-seed, lvs-foundry-device-import-report artifacts, compact seedSummary stdout, and lvs-device-import-audit verification through lvsengine --audit-netgen-device-import; installed foundry PDK import is exposed through lvsengine --import-foundry-netgen-devices through signoff profile discovery and semantic readiness.",
                "Native LVS can consume lvs-device-policy-seed through LVSRequest.devicePolicyURL or lvsengine --device-policy, applying concrete Netgen permute, equate-pins, property-delete, property-tolerance, property-parallel, property-series, conservative blackbox, and runtime $cell selector rules resolved against defined compared subcircuit models while emitting lvs-device-policy-application-report evidence.",
                "Native-gds routes extracted layout SPICE through the same policy-aware comparison path for equate-pins, property-blackbox, explicit model-blackbox boundary, runtime $cell blackbox boundary, mixed blackbox-plus-extracted-device top cells, property-delete, property-tolerance, property-parallel, and property-series evidence from standard mask inputs.",
                "Native-gds requires a versioned process-owned layout extraction profile plus its source deck and validates schema, semantic completeness, profile identity, and deck digest before geometry extraction.",
                "Diagnostics distinguish port, model, parameter, component-count, and extraction failures; actionable port, policy, parameter, and multiplicity diagnostics can be exported as typed repair hints.",
                "Corpus reports are immutable evidence and can be reassessed without rerunning the engine.",
            ]
        )
    }

    private func trustEvidenceContract() -> LVSCapabilitySnapshot.TrustEvidenceContract {
        LVSCapabilitySnapshot.TrustEvidenceContract(
            evidenceArtifactID: "lvs-corpus-observation-export",
            evaluator: "ToolQualification evidence policy",
            backendSelectionPolicy: "Select only a backend whose fresh evidence matches the requested process profile and extraction-deck digest.",
            requiredIdentityFields: [
                "implementationID",
                "binaryDigest",
                "algorithmVersion",
                "processProfileID",
                "extractionDeckDigest",
                "oracleImplementationID",
                "oracleBinaryDigest",
            ],
            freshnessPolicy: "Production eligibility expires when ToolQualification rejects evidence age, identity, scope, or integrity."
        )
    }

    private func nativeBackend() -> LVSCapabilitySnapshot.Backend {
        LVSCapabilitySnapshot.Backend(
            backendID: "native",
            executionMode: "in-process",
            requiresExternalTool: false,
            inputFormats: ["layout-spice", "schematic-spice"],
            requiredInputs: ["layout-netlist", "schematic-netlist", "top-cell", "optional-device-policy-seed"],
            producedArtifacts: ["lvs-report", "lvs-artifact-manifest", "lvs-summary", "lvs-device-policy-application-report"],
            diagnosticCategories: diagnosticCategories(),
            limitations: [
                "Native netlist comparison depends on supported SPICE primitive and expression coverage.",
                "Production eligibility is derived from retained evidence and is never asserted by this capability snapshot.",
            ]
        )
    }

    private func nativeGDSBackend() -> LVSCapabilitySnapshot.Backend {
        LVSCapabilitySnapshot.Backend(
            backendID: "native-gds",
            executionMode: "in-process",
            requiresExternalTool: false,
            inputFormats: ["gds", "oasis", "cif", "dxf", "layout-tech-json", "layout-extraction-profile-json", "extraction-deck", "schematic-spice"],
            requiredInputs: ["standard-layout-file", "technology-json", "layout-extraction-profile", "extraction-deck", "schematic-netlist", "top-cell", "optional-device-policy-seed"],
            producedArtifacts: [
                "lvs-report",
                "lvs-artifact-manifest",
                "extracted-layout-netlist",
                "lvs-summary",
                "lvs-device-policy-application-report",
            ],
            diagnosticCategories: ["extraction", "componentCountMismatch", "modelMismatch", "parameterMismatch", "devicePolicy"],
            limitations: [
                "The retained physical extraction scope is sky130.open-pdk.digital-mos.signoff and its exact extraction-deck digest.",
                "Analog structures and hierarchy cases in the retained corpus validate SPICE graph semantics, not analog or hierarchical physical extraction.",
                "CIF, DXF, and OASIS parsing support does not imply foundry extraction coverage without matching retained observations.",
                "The sample-process extractor is fixture-only and is not a foundry deck implementation.",
            ]
        )
    }

    private func netgenBackend() -> LVSCapabilitySnapshot.Backend {
        LVSCapabilitySnapshot.Backend(
            backendID: "netgen",
            executionMode: "headless-batch-process",
            requiresExternalTool: true,
            inputFormats: ["layout-netlist", "schematic-netlist", "gds-through-extraction-adapter"],
            requiredInputs: ["layout-netlist-or-extracted-layout", "schematic-netlist", "top-cell", "netgen-pdk-environment"],
            producedArtifacts: ["lvs-report", "lvs-artifact-manifest", "tool-log", "optional-extracted-layout-netlist"],
            diagnosticCategories: ["external-tool-report"],
            limitations: [
                "Requires Netgen and optional Magic extraction setup outside the Swift process.",
                "Used for oracle and PDK deck agreement, not as the preferred standalone path.",
            ]
        )
    }

    private func diagnosticCategories() -> [String] {
        [
            "portMismatch",
            "modelMismatch",
            "parameterMismatch",
            "componentCountMismatch",
            "extraction",
            "devicePolicy",
        ]
    }

    private func artifactContracts() -> [LVSCapabilitySnapshot.ArtifactContract] {
        [
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "lvs-report",
                format: "json",
                producer: "LVSPersistence.LVSArtifactStore",
                consumer: ["Agent", "Human review", "Xcircuite", "DesignFlowKernel"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "lvs-artifact-manifest",
                format: "json",
                producer: "LVSPersistence.LVSArtifactStore",
                consumer: ["artifact-integrity-gate", "Xcircuite", "CI"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "lvs-corpus-report",
                format: "json",
                producer: "LVSRuntime.LVSCorpusRunner",
                consumer: ["ToolQualification trust evaluation", "Human review", "CI"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "lvs-corpus-observation-export",
                format: "json",
                producer: "LVSCore.LVSCorpusObservationExport",
                consumer: ["ToolQualification", "Xcircuite trust gate", "CI", "Human review"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "lvs-summary",
                format: "json",
                producer: "LVSPersistence.LVSRunSummaryBuilder",
                consumer: ["Agent planning", "Human review", "Xcircuite planning/problem generator"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "lvs-repair-hints",
                format: "json",
                producer: "LVSCore.LVSRepairHintBuilder",
                consumer: ["Agent planning", "Human review", "Xcircuite planning/problem generator"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "lvs-waiver-report",
                format: "json",
                producer: "LVSCore.LVSWaiverReviewer",
                consumer: ["Agent planning", "Human approval gate", "Xcircuite review bundle"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "lvs-evidence-packet",
                format: "json",
                producer: "LVSCore.LVSCorpusEvidencePacketBuilder",
                consumer: ["Agent planning", "Human review", "CI", "DesignFlowKernel"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "lvs-corpus-coverage-audit",
                format: "json",
                producer: "LVSCore.LVSCorpusCoverageAuditor",
                consumer: ["Agent gap analysis", "Human review", "CI", "DesignFlowKernel"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "extracted-layout-netlist",
                format: "spice",
                producer: "LVSNative.LayoutGDSLVSBackend or LVSExtractionAdapters.MagicLayoutNetlistExtractor",
                consumer: ["Agent debug", "Human review", "LVS oracle comparison"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "optional-extracted-layout-netlist",
                format: "spice",
                producer: "LVSExtractionAdapters.MagicLayoutNetlistExtractor or Netgen adapter flow",
                consumer: ["Agent debug", "Human review", "LVS oracle comparison"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "tool-log",
                format: "text",
                producer: "LVSAdapters.NetgenLVSAdapter",
                consumer: ["Human debug", "CI", "ToolQualification"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "signoff-foundry-deck-semantics",
                format: "json",
                producer: "SignoffToolSupport.SignoffDeckSemanticInventory",
                consumer: ["Agent tool selection", "Xcircuite trust gate", "CI", "Human review"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "lvs-device-policy-seed",
                format: "json",
                producer: "LVSCore.NetgenLVSDeviceDeckImporter",
                consumer: ["Agent planning", "native LVS extraction policy work", "Human review"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "lvs-foundry-device-import-report",
                format: "json",
                producer: "LVSCore.NetgenLVSDeviceDeckImporter",
                consumer: ["Agent gap analysis", "Xcircuite trust gate", "CI", "Human review"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "lvs-device-import-audit",
                format: "json",
                producer: "LVSCore.NetgenLVSDeviceDeckImportAuditor",
                consumer: ["Agent readiness gate", "Xcircuite trust gate", "CI", "Human review"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "lvs-device-policy-application-report",
                format: "json",
                producer: "LVSNative.NativeLVSBackend",
                consumer: ["Agent gap analysis", "Xcircuite trust gate", "CI", "Human review"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "model-equivalence-policy",
                format: "json",
                producer: "Xcircuite.CandidatePlanExecutor",
                consumer: ["Agent planning", "Native LVS", "Human approval gate"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "terminal-equivalence-policy",
                format: "json",
                producer: "Xcircuite.CandidatePlanExecutor",
                consumer: ["Agent planning", "Native LVS", "Human approval gate"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "policy-artifact",
                format: "json",
                producer: "Xcircuite.CandidatePlanExecutor",
                consumer: ["Agent planning", "Native LVS", "Human review"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "design-diff",
                format: "json",
                producer: "Xcircuite.CandidatePlanExecutor",
                consumer: ["Agent planning", "Human review", "Xcircuite review bundle"]
            ),
            LVSCapabilitySnapshot.ArtifactContract(
                artifactID: "planning-problem",
                format: "json",
                producer: "Xcircuite.DiagnosticPlanningProblemBuilder",
                consumer: ["Agent planner", "Human review", "Xcircuite planning/problem generator"]
            ),
        ]
    }

    private func corpusContract() -> LVSCapabilitySnapshot.CorpusContract {
        LVSCapabilitySnapshot.CorpusContract(
            runner: "LVSCorpusRunner",
            cliFlag: "--corpus",
            committedSpecPath: "Tests/LVSCLICoreTests/Fixtures/ExternalOracle/lvs-production-corpus.json",
            reportArtifact: "lvs-corpus-report",
            evidenceExportFlag: "--observations-from-corpus-report",
            acceptanceCriteria: "strict unless overridden by corpus spec or --acceptance-criteria",
            requiredObservedAssertions: [
                "cancellation:cancelled",
                "correspondenceArtifact",
                "determinism:stable",
                "diagnosticRule:LVS_MODEL_MISMATCH",
                "durationBudget:within-budget",
                "extractionArtifact",
                "extractionSemanticReadiness:ready",
                "manifestArtifact",
                "oracleAgreement:true",
                "oracleIndependence:ready",
                "reportArtifact",
                "verdict:match",
                "verdict:mismatch",
            ]
        )
    }
}
