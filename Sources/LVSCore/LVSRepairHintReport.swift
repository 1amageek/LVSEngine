import Foundation

public struct LVSRepairHintReport: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let status: String
    public let reportURL: URL?
    public let backendID: String
    public let topCell: String
    public let activeDiagnosticCount: Int
    public let hintCount: Int
    public let hints: [LVSRepairHint]
    public let unsupportedDiagnosticIndexes: [Int]
    public let unsupportedDiagnostics: [LVSUnsupportedRepairDiagnostic]

    public init(
        schemaVersion: Int = LVSRepairHintReport.currentSchemaVersion,
        status: String,
        reportURL: URL?,
        backendID: String,
        topCell: String,
        activeDiagnosticCount: Int,
        hintCount: Int,
        hints: [LVSRepairHint],
        unsupportedDiagnosticIndexes: [Int],
        unsupportedDiagnostics: [LVSUnsupportedRepairDiagnostic] = []
    ) {
        self.schemaVersion = schemaVersion
        self.status = status
        self.reportURL = reportURL
        self.backendID = backendID
        self.topCell = topCell
        self.activeDiagnosticCount = activeDiagnosticCount
        self.hintCount = hintCount
        self.hints = hints
        self.unsupportedDiagnosticIndexes = unsupportedDiagnosticIndexes
        self.unsupportedDiagnostics = unsupportedDiagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case status
        case reportURL
        case backendID
        case topCell
        case activeDiagnosticCount
        case hintCount
        case hints
        case unsupportedDiagnosticIndexes
        case unsupportedDiagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported LVS repair hint report schema version: \(schemaVersion)."
            )
        }
        self.status = try container.decode(String.self, forKey: .status)
        self.reportURL = try container.decodeIfPresent(URL.self, forKey: .reportURL)
        self.backendID = try container.decode(String.self, forKey: .backendID)
        self.topCell = try container.decode(String.self, forKey: .topCell)
        self.activeDiagnosticCount = try container.decode(Int.self, forKey: .activeDiagnosticCount)
        self.hintCount = try container.decode(Int.self, forKey: .hintCount)
        self.hints = try container.decode([LVSRepairHint].self, forKey: .hints)
        self.unsupportedDiagnosticIndexes = try container.decode(
            [Int].self,
            forKey: .unsupportedDiagnosticIndexes
        )
        self.unsupportedDiagnostics = try container.decode(
            [LVSUnsupportedRepairDiagnostic].self,
            forKey: .unsupportedDiagnostics
        )
    }
}
