public enum LVSExecutionStatus: String, Sendable, Hashable, Codable {
    case completed
    case timedOut
    case cancelled
    case failed
}
