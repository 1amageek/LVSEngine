public struct LVSExtractionEvidence: Sendable, Hashable, Codable {
    public let processProfileID: String
    public let deckDigest: String
    public let profileReady: Bool
    public let blockingReasonCodes: [String]

    public init(
        processProfileID: String,
        deckDigest: String,
        profileReady: Bool,
        blockingReasonCodes: [String] = []
    ) {
        self.processProfileID = processProfileID
        self.deckDigest = deckDigest
        self.profileReady = profileReady
        self.blockingReasonCodes = Array(Set(blockingReasonCodes)).sorted()
    }
}
