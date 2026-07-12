public struct LVSGraphPort: Sendable, Hashable, Codable {
    public let name: String
    public let netID: LVSObjectID
    public let position: Int

    public init(name: String, netID: LVSObjectID, position: Int = 0) {
        self.name = name
        self.netID = netID
        self.position = position
    }
}
