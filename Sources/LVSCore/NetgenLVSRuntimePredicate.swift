public struct NetgenLVSRuntimePredicate: Codable, Sendable, Hashable {
    public let variableName: String
    public let pattern: String
    public let captureVariableNames: [String]

    public init(
        variableName: String,
        pattern: String,
        captureVariableNames: [String] = []
    ) {
        self.variableName = variableName
        self.pattern = pattern
        self.captureVariableNames = captureVariableNames
    }

    package var resolvableVariableNames: Set<String> {
        Set([variableName] + captureVariableNames)
    }
}
