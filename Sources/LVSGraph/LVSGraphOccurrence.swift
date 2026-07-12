public struct LVSGraphOccurrence: Sendable, Hashable, Codable {
    public let occurrenceID: String
    public let parentOccurrenceID: String?
    public let instancePath: String
    public let depth: Int
    public let sourceKind: String

    public init(
        occurrenceID: String,
        parentOccurrenceID: String?,
        instancePath: String,
        depth: Int,
        sourceKind: String
    ) {
        self.occurrenceID = occurrenceID
        self.parentOccurrenceID = parentOccurrenceID
        self.instancePath = instancePath
        self.depth = depth
        self.sourceKind = sourceKind
    }
}
