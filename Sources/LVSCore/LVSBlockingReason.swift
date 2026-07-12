public struct LVSBlockingReason: Sendable, Hashable, Codable {
    public let code: String
    public let message: String
    public let evidenceReferences: [String]

    public init(
        code: String,
        message: String,
        evidenceReferences: [String] = []
    ) {
        self.code = code
        self.message = message
        self.evidenceReferences = evidenceReferences
    }
}
