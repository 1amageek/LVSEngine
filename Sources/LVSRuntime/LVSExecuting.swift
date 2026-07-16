import CircuiteFoundation
import LVSCore

/// Executes layout-versus-schematic verification.
public protocol LVSExecuting: Engine
where Request == LVSRequest, Output == LVSExecutionResult {
    func run(_ request: LVSRequest) async throws -> LVSExecutionResult

    func run(
        _ request: LVSRequest,
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> LVSExecutionResult
}

public extension LVSExecuting {
    func execute(_ request: LVSRequest) async throws -> LVSExecutionResult {
        try await run(request)
    }

    func run(
        _ request: LVSRequest,
        cancellationCheck: LVSExecutionCancellationCheck?
    ) async throws -> LVSExecutionResult {
        try await run(request)
    }
}
