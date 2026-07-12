public struct LVSGraphDevice: Sendable, Hashable, Codable {
    public let id: LVSObjectID
    public let sourceName: String
    public let kind: String
    public let model: String
    public let terminals: [LVSGraphTerminal]
    public let equivalentTerminalGroups: [[Int]]
    public let parameters: [LVSGraphParameter]

    public init(
        id: LVSObjectID,
        sourceName: String,
        kind: String,
        model: String,
        terminals: [LVSGraphTerminal],
        equivalentTerminalGroups: [[Int]] = [],
        parameters: [LVSGraphParameter] = []
    ) {
        self.id = id
        self.sourceName = sourceName
        self.kind = kind
        self.model = model
        self.terminals = terminals.sorted { $0.index < $1.index }
        self.equivalentTerminalGroups = equivalentTerminalGroups
            .map { $0.sorted() }
            .sorted { $0.lexicographicallyPrecedes($1) }
        self.parameters = parameters.sorted { $0.name < $1.name }
    }
}
