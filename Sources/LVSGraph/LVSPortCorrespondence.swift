public struct LVSPortCorrespondence: Sendable, Hashable, Codable {
    public let portName: String
    public let layoutNetID: LVSObjectID
    public let schematicNetID: LVSObjectID

    public init(portName: String, layoutNetID: LVSObjectID, schematicNetID: LVSObjectID) {
        self.portName = portName
        self.layoutNetID = layoutNetID
        self.schematicNetID = schematicNetID
    }
}
