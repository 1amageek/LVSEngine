import LVSCore

public protocol LVSEngineRunning: Sendable {
    func run(_ request: LVSRequest) async throws -> LVSExecutionResult

    func run(
        _ request: LVSRequest,
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> LVSExecutionResult
}
