import CircuiteFoundation
import LVSCore

extension DefaultLVSEngine {
    public func execute(_ request: LVSRequest) async throws -> LVSExecutionResult {
        try await run(request)
    }
}
