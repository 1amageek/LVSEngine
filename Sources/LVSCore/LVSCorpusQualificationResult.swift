public struct LVSCorpusQualificationResult: Sendable, Hashable, Codable {
    public let qualified: Bool
    public let policy: LVSCorpusQualificationPolicy
    public let failures: [LVSCorpusQualificationFailure]

    public init(
        policy: LVSCorpusQualificationPolicy,
        failures: [LVSCorpusQualificationFailure]
    ) {
        self.policy = policy
        self.failures = failures
        self.qualified = failures.isEmpty
    }
}
