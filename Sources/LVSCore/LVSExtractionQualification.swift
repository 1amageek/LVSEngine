public struct LVSExtractionQualification: Sendable, Hashable, Codable {
    public let processProfileID: String
    public let deckDigest: String
    public let productionEligible: Bool
    public let blockingReasonCodes: [String]

    public init(
        processProfileID: String,
        deckDigest: String,
        productionEligible: Bool,
        blockingReasonCodes: [String] = []
    ) {
        self.processProfileID = processProfileID
        self.deckDigest = deckDigest
        self.productionEligible = productionEligible
        self.blockingReasonCodes = Array(Set(blockingReasonCodes)).sorted()
    }
}
