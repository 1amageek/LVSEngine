public struct LVSObjectCorrespondence: Sendable, Hashable, Codable {
    public let layoutObjectID: LVSObjectID
    public let schematicObjectID: LVSObjectID

    public init(layoutObjectID: LVSObjectID, schematicObjectID: LVSObjectID) {
        self.layoutObjectID = layoutObjectID
        self.schematicObjectID = schematicObjectID
    }
}
