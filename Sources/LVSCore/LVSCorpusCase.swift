import Foundation

public struct LVSCorpusCase: Sendable, Hashable, Codable {
    public let caseID: String
    public let layoutNetlistPath: String?
    public let layoutGDSPath: String?
    public let layoutFormat: LVSLayoutFormat?
    public let generatedLayoutFixture: LVSGeneratedLayoutFixture?
    public let schematicNetlistPath: String
    public let topCell: String
    public let technologyPath: String?
    public let extractionProfilePath: String?
    public let extractionDeckPath: String?
    public let processProfileID: String?
    public let waiverPath: String?
    public let modelEquivalencePath: String?
    public let terminalEquivalencePath: String?
    public let devicePolicyPath: String?
    public let devicePolicyDeckPath: String?
    public let backendID: String?
    public let oracleBackendID: String?
    public let expectedPassed: Bool
    public let expectedVerdict: LVSVerificationVerdict?
    public let faultClass: String?
    public let expectedActiveErrorRuleIDs: [String]
    public let requiredAssertions: [LVSCorpusAssertionRequirement]
    public let oracleComparisonMode: LVSCorpusOracleComparisonMode
    public let hardExecutionBudget: LVSCorpusHardExecutionBudget?
    public let maxDurationSeconds: Double?

    public init(
        caseID: String,
        layoutNetlistPath: String? = nil,
        layoutGDSPath: String? = nil,
        layoutFormat: LVSLayoutFormat? = nil,
        generatedLayoutFixture: LVSGeneratedLayoutFixture? = nil,
        schematicNetlistPath: String,
        topCell: String,
        technologyPath: String? = nil,
        extractionProfilePath: String? = nil,
        extractionDeckPath: String? = nil,
        processProfileID: String? = nil,
        waiverPath: String? = nil,
        modelEquivalencePath: String? = nil,
        terminalEquivalencePath: String? = nil,
        devicePolicyPath: String? = nil,
        devicePolicyDeckPath: String? = nil,
        backendID: String? = nil,
        oracleBackendID: String? = nil,
        expectedPassed: Bool,
        expectedVerdict: LVSVerificationVerdict? = nil,
        faultClass: String? = nil,
        expectedActiveErrorRuleIDs: [String] = [],
        requiredAssertions: [LVSCorpusAssertionRequirement] = [],
        oracleComparisonMode: LVSCorpusOracleComparisonMode = .verdict,
        hardExecutionBudget: LVSCorpusHardExecutionBudget? = nil,
        maxDurationSeconds: Double? = nil
    ) {
        self.caseID = caseID
        self.layoutNetlistPath = layoutNetlistPath
        self.layoutGDSPath = layoutGDSPath
        self.layoutFormat = layoutFormat
        self.generatedLayoutFixture = generatedLayoutFixture
        self.schematicNetlistPath = schematicNetlistPath
        self.topCell = topCell
        self.technologyPath = technologyPath
        self.extractionProfilePath = extractionProfilePath
        self.extractionDeckPath = extractionDeckPath
        self.processProfileID = processProfileID
        self.waiverPath = waiverPath
        self.modelEquivalencePath = modelEquivalencePath
        self.terminalEquivalencePath = terminalEquivalencePath
        self.devicePolicyPath = devicePolicyPath
        self.devicePolicyDeckPath = devicePolicyDeckPath
        self.backendID = backendID
        self.oracleBackendID = oracleBackendID
        self.expectedPassed = expectedPassed
        self.expectedVerdict = expectedVerdict
        self.faultClass = faultClass
        self.expectedActiveErrorRuleIDs = expectedActiveErrorRuleIDs
        self.requiredAssertions = requiredAssertions
        self.oracleComparisonMode = oracleComparisonMode
        self.hardExecutionBudget = hardExecutionBudget
        self.maxDurationSeconds = maxDurationSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case caseID
        case layoutNetlistPath
        case layoutGDSPath
        case layoutFormat
        case generatedLayoutFixture
        case schematicNetlistPath
        case topCell
        case technologyPath
        case extractionProfilePath
        case extractionDeckPath
        case processProfileID
        case waiverPath
        case modelEquivalencePath
        case terminalEquivalencePath
        case devicePolicyPath
        case devicePolicyDeckPath
        case backendID
        case oracleBackendID
        case expectedPassed
        case expectedVerdict
        case faultClass
        case expectedActiveErrorRuleIDs
        case requiredAssertions
        case oracleComparisonMode
        case hardExecutionBudget
        case maxDurationSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        caseID = try container.decode(String.self, forKey: .caseID)
        layoutNetlistPath = try container.decodeIfPresent(String.self, forKey: .layoutNetlistPath)
        layoutGDSPath = try container.decodeIfPresent(String.self, forKey: .layoutGDSPath)
        layoutFormat = try container.decodeIfPresent(LVSLayoutFormat.self, forKey: .layoutFormat)
        generatedLayoutFixture = try container.decodeIfPresent(
            LVSGeneratedLayoutFixture.self,
            forKey: .generatedLayoutFixture
        )
        schematicNetlistPath = try container.decode(String.self, forKey: .schematicNetlistPath)
        topCell = try container.decode(String.self, forKey: .topCell)
        technologyPath = try container.decodeIfPresent(String.self, forKey: .technologyPath)
        extractionProfilePath = try container.decodeIfPresent(String.self, forKey: .extractionProfilePath)
        extractionDeckPath = try container.decodeIfPresent(String.self, forKey: .extractionDeckPath)
        processProfileID = try container.decodeIfPresent(String.self, forKey: .processProfileID)
        waiverPath = try container.decodeIfPresent(String.self, forKey: .waiverPath)
        modelEquivalencePath = try container.decodeIfPresent(String.self, forKey: .modelEquivalencePath)
        terminalEquivalencePath = try container.decodeIfPresent(String.self, forKey: .terminalEquivalencePath)
        devicePolicyPath = try container.decodeIfPresent(String.self, forKey: .devicePolicyPath)
        devicePolicyDeckPath = try container.decodeIfPresent(String.self, forKey: .devicePolicyDeckPath)
        backendID = try container.decodeIfPresent(String.self, forKey: .backendID)
        oracleBackendID = try container.decodeIfPresent(String.self, forKey: .oracleBackendID)
        expectedPassed = try container.decode(Bool.self, forKey: .expectedPassed)
        expectedVerdict = try container.decodeIfPresent(LVSVerificationVerdict.self, forKey: .expectedVerdict)
        faultClass = try container.decodeIfPresent(String.self, forKey: .faultClass)
        expectedActiveErrorRuleIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .expectedActiveErrorRuleIDs
        ) ?? []
        requiredAssertions = try container.decodeIfPresent(
            [LVSCorpusAssertionRequirement].self,
            forKey: .requiredAssertions
        ) ?? []
        oracleComparisonMode = try container.decodeIfPresent(
            LVSCorpusOracleComparisonMode.self,
            forKey: .oracleComparisonMode
        ) ?? .verdict
        hardExecutionBudget = try container.decodeIfPresent(
            LVSCorpusHardExecutionBudget.self,
            forKey: .hardExecutionBudget
        )
        maxDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .maxDurationSeconds)
    }
}

public struct LVSGeneratedLayoutFixture: Sendable, Hashable, Codable {
    public let kind: String
    public let technology: String
    public let format: LVSLayoutFormat

    public init(
        kind: String,
        technology: String = "sampleProcess",
        format: LVSLayoutFormat = .gds
    ) {
        self.kind = kind
        self.technology = technology
        self.format = format
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case technology
        case format
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        technology = try container.decodeIfPresent(String.self, forKey: .technology) ?? "sampleProcess"
        format = try container.decodeIfPresent(LVSLayoutFormat.self, forKey: .format) ?? .gds
    }
}
