import LVSGraph

public struct LVSGraphMatchResult: Sendable, Hashable, Codable {
    public let status: LVSGraphMatchStatus
    public let correspondence: LVSCorrespondence
    public let reasonCodes: [String]
    public let exploredSearchStates: Int

    public init(
        status: LVSGraphMatchStatus,
        correspondence: LVSCorrespondence,
        reasonCodes: [String] = [],
        exploredSearchStates: Int
    ) {
        self.status = status
        self.correspondence = correspondence
        self.reasonCodes = reasonCodes.sorted()
        self.exploredSearchStates = exploredSearchStates
    }
}
