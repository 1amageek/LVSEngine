public struct LVSGraphTerminal: Sendable, Hashable, Codable {
    public let index: Int
    public let role: String?
    public let netID: LVSObjectID

    public init(index: Int, role: String? = nil, netID: LVSObjectID) {
        self.index = index
        self.role = role
        self.netID = netID
    }
}
