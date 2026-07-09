public struct LVSCorpusRunOptions: Sendable, Hashable, Codable {
    public let oracleBackendIDOverride: String?

    public init(oracleBackendIDOverride: String? = nil) {
        self.oracleBackendIDOverride = oracleBackendIDOverride
    }
}
