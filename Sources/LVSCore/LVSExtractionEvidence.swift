public struct LVSExtractionEvidence: Sendable, Hashable, Codable {
    public let processProfileID: String
    public let deckDigest: String
    public let semanticReady: Bool
    public let blockingReasonCodes: [String]

    public init(
        processProfileID: String,
        deckDigest: String,
        semanticReady: Bool,
        blockingReasonCodes: [String] = []
    ) {
        self.processProfileID = processProfileID
        self.deckDigest = deckDigest
        self.semanticReady = semanticReady
        self.blockingReasonCodes = Array(Set(blockingReasonCodes)).sorted()
    }
}
