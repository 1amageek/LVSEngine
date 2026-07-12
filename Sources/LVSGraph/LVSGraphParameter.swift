public struct LVSGraphParameter: Sendable, Hashable, Codable {
    public let name: String
    public let canonicalValue: String
    public let numericValue: Double?
    public let relativeTolerance: Double

    public init(
        name: String,
        canonicalValue: String,
        numericValue: Double? = nil,
        relativeTolerance: Double = 0
    ) {
        self.name = name
        self.canonicalValue = canonicalValue
        self.numericValue = numericValue
        self.relativeTolerance = relativeTolerance
    }
}
