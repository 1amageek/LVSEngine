import CircuiteFoundation
import LVSCore

public protocol LVSEngineRunning: Engine
where Request == LVSRequest, Output == LVSExecutionResult {
    func run(_ request: LVSRequest) async throws -> LVSExecutionResult

    func run(
        _ request: LVSRequest,
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> LVSExecutionResult
}
