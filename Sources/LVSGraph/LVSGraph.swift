public struct LVSGraph: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let topCell: String
    public let devices: [LVSGraphDevice]
    public let nets: [LVSGraphNet]
    public let ports: [LVSGraphPort]
    public let occurrences: [LVSGraphOccurrence]

    public init(
        schemaVersion: Int = LVSGraph.currentSchemaVersion,
        topCell: String,
        devices: [LVSGraphDevice],
        nets: [LVSGraphNet],
        ports: [LVSGraphPort],
        occurrences: [LVSGraphOccurrence] = []
    ) {
        self.schemaVersion = schemaVersion
        self.topCell = topCell
        self.devices = devices.sorted { $0.id < $1.id }
        self.nets = nets.sorted { $0.id < $1.id }
        self.ports = ports.sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.name < $1.name
        }
        self.occurrences = occurrences.sorted { $0.occurrenceID < $1.occurrenceID }
    }
}
