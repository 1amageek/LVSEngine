public struct LVSMatchBudget: Sendable, Hashable, Codable {
    public let maximumSearchStates: Int
    public let maximumDurationSeconds: Double
    public let maximumSearchDepth: Int
    public let maximumWorkingSetBytes: Int

    public init(
        maximumSearchStates: Int = 1_000_000,
        maximumDurationSeconds: Double = 300,
        maximumSearchDepth: Int = 100_000,
        maximumWorkingSetBytes: Int = 512 * 1_024 * 1_024
    ) {
        self.maximumSearchStates = maximumSearchStates
        self.maximumDurationSeconds = maximumDurationSeconds
        self.maximumSearchDepth = maximumSearchDepth
        self.maximumWorkingSetBytes = maximumWorkingSetBytes
    }
}
