public struct LVSSourceReference: Sendable, Hashable, Codable {
    public let objectID: LVSObjectID
    public let sourceKind: String
    public let sourceObjectID: String
    public let occurrenceID: String?
    public let attributes: [String: String]

    public init(
        objectID: LVSObjectID,
        sourceKind: String,
        sourceObjectID: String,
        occurrenceID: String? = nil,
        attributes: [String: String] = [:]
    ) {
        self.objectID = objectID
        self.sourceKind = sourceKind
        self.sourceObjectID = sourceObjectID
        self.occurrenceID = occurrenceID
        self.attributes = attributes
    }
}
