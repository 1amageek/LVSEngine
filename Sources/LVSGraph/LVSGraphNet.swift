public struct LVSGraphNet: Sendable, Hashable, Codable {
    public let id: LVSObjectID
    public let sourceName: String
    public let isGlobal: Bool

    public init(id: LVSObjectID, sourceName: String, isGlobal: Bool = false) {
        self.id = id
        self.sourceName = sourceName
        self.isGlobal = isGlobal
    }
}
