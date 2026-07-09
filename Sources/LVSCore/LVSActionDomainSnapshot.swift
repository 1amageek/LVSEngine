public struct LVSActionDomainSnapshot: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let domainID: String
    public let ownerPackages: [String]
    public let operations: [LVSActionDomainOperation]

    public init(
        schemaVersion: Int = 1,
        domainID: String,
        ownerPackages: [String],
        operations: [LVSActionDomainOperation]
    ) {
        self.schemaVersion = schemaVersion
        self.domainID = domainID
        self.ownerPackages = ownerPackages
        self.operations = operations
    }
}

