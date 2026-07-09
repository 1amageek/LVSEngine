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
    public let waiverPath: String?
    public let modelEquivalencePath: String?
    public let terminalEquivalencePath: String?
    public let devicePolicyPath: String?
    public let backendID: String?
    public let oracleBackendID: String?
    public let expectedPassed: Bool
    public let expectedActiveErrorRuleIDs: [String]
    public let coverageTags: [String]
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
        waiverPath: String? = nil,
        modelEquivalencePath: String? = nil,
        terminalEquivalencePath: String? = nil,
        devicePolicyPath: String? = nil,
        backendID: String? = nil,
        oracleBackendID: String? = nil,
        expectedPassed: Bool,
        expectedActiveErrorRuleIDs: [String] = [],
        coverageTags: [String] = [],
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
        self.waiverPath = waiverPath
        self.modelEquivalencePath = modelEquivalencePath
        self.terminalEquivalencePath = terminalEquivalencePath
        self.devicePolicyPath = devicePolicyPath
        self.backendID = backendID
        self.oracleBackendID = oracleBackendID
        self.expectedPassed = expectedPassed
        self.expectedActiveErrorRuleIDs = expectedActiveErrorRuleIDs
        self.coverageTags = Self.normalizedCoverageTags(coverageTags)
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
        case waiverPath
        case modelEquivalencePath
        case terminalEquivalencePath
        case devicePolicyPath
        case backendID
        case oracleBackendID
        case expectedPassed
        case expectedActiveErrorRuleIDs
        case coverageTags
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
        waiverPath = try container.decodeIfPresent(String.self, forKey: .waiverPath)
        modelEquivalencePath = try container.decodeIfPresent(String.self, forKey: .modelEquivalencePath)
        terminalEquivalencePath = try container.decodeIfPresent(String.self, forKey: .terminalEquivalencePath)
        devicePolicyPath = try container.decodeIfPresent(String.self, forKey: .devicePolicyPath)
        backendID = try container.decodeIfPresent(String.self, forKey: .backendID)
        oracleBackendID = try container.decodeIfPresent(String.self, forKey: .oracleBackendID)
        expectedPassed = try container.decode(Bool.self, forKey: .expectedPassed)
        expectedActiveErrorRuleIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .expectedActiveErrorRuleIDs
        ) ?? []
        coverageTags = Self.normalizedCoverageTags(try container.decodeIfPresent(
            [String].self,
            forKey: .coverageTags
        ) ?? [])
        maxDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .maxDurationSeconds)
    }

    private static func normalizedCoverageTags(_ tags: [String]) -> [String] {
        Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
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
