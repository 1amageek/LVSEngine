public struct LVSCorpusAssessmentFinding: Sendable, Hashable, Codable {
    public let code: String
    public let message: String
    public let observedDouble: Double?
    public let requiredDouble: Double?
    public let observedCount: Int?
    public let requiredCount: Int?
    public let observedText: String?
    public let requiredText: String?

    public init(
        code: String,
        message: String,
        observedDouble: Double? = nil,
        requiredDouble: Double? = nil,
        observedCount: Int? = nil,
        requiredCount: Int? = nil,
        observedText: String? = nil,
        requiredText: String? = nil
    ) {
        self.code = code
        self.message = message
        self.observedDouble = observedDouble
        self.requiredDouble = requiredDouble
        self.observedCount = observedCount
        self.requiredCount = requiredCount
        self.observedText = observedText
        self.requiredText = requiredText
    }
}
