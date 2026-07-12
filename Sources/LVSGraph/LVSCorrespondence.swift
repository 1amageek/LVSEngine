public struct LVSCorrespondence: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let deviceMappings: [LVSObjectCorrespondence]
    public let netMappings: [LVSObjectCorrespondence]
    public let portMappings: [LVSPortCorrespondence]
    public let unmatchedLayoutObjectIDs: [LVSObjectID]
    public let unmatchedSchematicObjectIDs: [LVSObjectID]
    public let ambiguousLayoutObjectIDs: [LVSObjectID]
    public let layoutSourceReferences: [LVSSourceReference]

    public init(
        schemaVersion: Int = LVSCorrespondence.currentSchemaVersion,
        deviceMappings: [LVSObjectCorrespondence],
        netMappings: [LVSObjectCorrespondence],
        portMappings: [LVSPortCorrespondence],
        unmatchedLayoutObjectIDs: [LVSObjectID] = [],
        unmatchedSchematicObjectIDs: [LVSObjectID] = [],
        ambiguousLayoutObjectIDs: [LVSObjectID] = [],
        layoutSourceReferences: [LVSSourceReference] = []
    ) {
        self.schemaVersion = schemaVersion
        self.deviceMappings = deviceMappings.sorted { $0.layoutObjectID < $1.layoutObjectID }
        self.netMappings = netMappings.sorted { $0.layoutObjectID < $1.layoutObjectID }
        self.portMappings = portMappings.sorted { $0.portName < $1.portName }
        self.unmatchedLayoutObjectIDs = unmatchedLayoutObjectIDs.sorted()
        self.unmatchedSchematicObjectIDs = unmatchedSchematicObjectIDs.sorted()
        self.ambiguousLayoutObjectIDs = ambiguousLayoutObjectIDs.sorted()
        self.layoutSourceReferences = layoutSourceReferences.sorted {
            if $0.objectID != $1.objectID { return $0.objectID < $1.objectID }
            return $0.sourceObjectID < $1.sourceObjectID
        }
    }
}
