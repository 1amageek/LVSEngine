public struct LVSObjectID: RawRepresentable, Sendable, Hashable, Codable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: LVSObjectID, rhs: LVSObjectID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
