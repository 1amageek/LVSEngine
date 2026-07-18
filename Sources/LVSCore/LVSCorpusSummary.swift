public struct LVSCorpusSummary: Sendable, Hashable, Codable {
    public let expectationMatchedCaseCount: Int
    public let durationBudgetPassedCaseCount: Int
    public let primaryExecutionFailedCaseCount: Int
    public let oracleCaseCount: Int
    public let oracleAgreementPassedCaseCount: Int
    public let oracleExecutionFailedCaseCount: Int
    public let oracleReadinessBlockedCaseCount: Int
    public let failureCategoryCounts: [String: Int]
    public let disagreementClassCounts: [String: Int]
    public let observedAssertionCounts: [String: Int]
    public let coverageTagCounts: [String: Int]
    public let failedAssertionCount: Int
    public let blockedAssertionCount: Int
    public let passRate: Double
    public let oracleAgreementRate: Double?

    private enum CodingKeys: String, CodingKey {
        case expectationMatchedCaseCount
        case durationBudgetPassedCaseCount
        case primaryExecutionFailedCaseCount
        case oracleCaseCount
        case oracleAgreementPassedCaseCount
        case oracleExecutionFailedCaseCount
        case oracleReadinessBlockedCaseCount
        case failureCategoryCounts
        case disagreementClassCounts
        case observedAssertionCounts
        case coverageTagCounts
        case failedAssertionCount
        case blockedAssertionCount
        case passRate
        case oracleAgreementRate
    }

    public init(
        expectationMatchedCaseCount: Int,
        durationBudgetPassedCaseCount: Int,
        primaryExecutionFailedCaseCount: Int,
        oracleCaseCount: Int,
        oracleAgreementPassedCaseCount: Int,
        oracleExecutionFailedCaseCount: Int,
        oracleReadinessBlockedCaseCount: Int = 0,
        failureCategoryCounts: [String: Int],
        disagreementClassCounts: [String: Int] = [:],
        observedAssertionCounts: [String: Int] = [:],
        coverageTagCounts: [String: Int] = [:],
        failedAssertionCount: Int = 0,
        blockedAssertionCount: Int = 0,
        passRate: Double,
        oracleAgreementRate: Double?
    ) {
        self.expectationMatchedCaseCount = expectationMatchedCaseCount
        self.durationBudgetPassedCaseCount = durationBudgetPassedCaseCount
        self.primaryExecutionFailedCaseCount = primaryExecutionFailedCaseCount
        self.oracleCaseCount = oracleCaseCount
        self.oracleAgreementPassedCaseCount = oracleAgreementPassedCaseCount
        self.oracleExecutionFailedCaseCount = oracleExecutionFailedCaseCount
        self.oracleReadinessBlockedCaseCount = oracleReadinessBlockedCaseCount
        self.failureCategoryCounts = failureCategoryCounts
        self.disagreementClassCounts = disagreementClassCounts
        self.observedAssertionCounts = observedAssertionCounts
        self.coverageTagCounts = coverageTagCounts
        self.failedAssertionCount = failedAssertionCount
        self.blockedAssertionCount = blockedAssertionCount
        self.passRate = passRate
        self.oracleAgreementRate = oracleAgreementRate
    }

    public init(caseResults: [LVSCorpusCaseResult]) {
        let caseCount = caseResults.count
        let oracleResults = caseResults.compactMap(\.oracleResult)
        self.init(
            expectationMatchedCaseCount: caseResults.filter(\.expectationMatched).count,
            durationBudgetPassedCaseCount: caseResults.filter(\.durationBudgetPassed).count,
            primaryExecutionFailedCaseCount: caseResults.filter { $0.executionError != nil }.count,
            oracleCaseCount: oracleResults.count,
            oracleAgreementPassedCaseCount: oracleResults.filter(\.agreementPassed).count,
            oracleExecutionFailedCaseCount: oracleResults.filter { $0.executionError != nil }.count,
            oracleReadinessBlockedCaseCount: oracleResults.filter { $0.readinessStatus == .blocked }.count,
            failureCategoryCounts: Self.failureCategoryCounts(in: caseResults),
            disagreementClassCounts: Self.disagreementClassCounts(in: caseResults),
            observedAssertionCounts: Self.observedAssertionCounts(in: caseResults),
            coverageTagCounts: Self.coverageTagCounts(in: caseResults),
            failedAssertionCount: caseResults.flatMap(\.observedAssertions).filter { $0.status == .failed }.count,
            blockedAssertionCount: caseResults.flatMap(\.observedAssertions).filter { $0.status == .blocked }.count,
            passRate: caseCount == 0 ? 0 : Double(caseResults.filter(\.matched).count) / Double(caseCount),
            oracleAgreementRate: oracleResults.isEmpty
                ? nil
                : Double(oracleResults.filter(\.agreementPassed).count) / Double(oracleResults.count)
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expectationMatchedCaseCount = try container.decode(Int.self, forKey: .expectationMatchedCaseCount)
        durationBudgetPassedCaseCount = try container.decode(Int.self, forKey: .durationBudgetPassedCaseCount)
        primaryExecutionFailedCaseCount = try container.decode(Int.self, forKey: .primaryExecutionFailedCaseCount)
        oracleCaseCount = try container.decode(Int.self, forKey: .oracleCaseCount)
        oracleAgreementPassedCaseCount = try container.decode(Int.self, forKey: .oracleAgreementPassedCaseCount)
        oracleExecutionFailedCaseCount = try container.decode(Int.self, forKey: .oracleExecutionFailedCaseCount)
        oracleReadinessBlockedCaseCount = try container.decode(Int.self, forKey: .oracleReadinessBlockedCaseCount)
        failureCategoryCounts = try container.decode([String: Int].self, forKey: .failureCategoryCounts)
        disagreementClassCounts = try container.decode([String: Int].self, forKey: .disagreementClassCounts)
        observedAssertionCounts = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .observedAssertionCounts
        ) ?? [:]
        coverageTagCounts = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .coverageTagCounts
        ) ?? [:]
        failedAssertionCount = try container.decodeIfPresent(Int.self, forKey: .failedAssertionCount) ?? 0
        blockedAssertionCount = try container.decodeIfPresent(Int.self, forKey: .blockedAssertionCount) ?? 0
        passRate = try container.decode(Double.self, forKey: .passRate)
        oracleAgreementRate = try container.decodeIfPresent(Double.self, forKey: .oracleAgreementRate)
    }

    private static func failureCategoryCounts(in caseResults: [LVSCorpusCaseResult]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for reason in caseResults.flatMap(\.failureReasons) {
            counts[category(for: reason), default: 0] += 1
        }
        return counts
    }

    private static func disagreementClassCounts(in caseResults: [LVSCorpusCaseResult]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for classification in caseResults
            .compactMap(\.oracleComparison)
            .flatMap(\.disagreementClassifications) {
            counts[classification.kind.rawValue, default: 0] += 1
        }
        return counts
    }

    private static func observedAssertionCounts(
        in caseResults: [LVSCorpusCaseResult]
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for assertion in caseResults.flatMap(\.observedAssertions)
            where assertion.status == .passed {
            counts[assertion.coverageKey, default: 0] += 1
        }
        return counts
    }

    private static func coverageTagCounts(
        in caseResults: [LVSCorpusCaseResult]
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for result in caseResults
            where result.expectationMatched && result.durationBudgetPassed && result.executionError == nil {
            for tag in result.coverageTags {
                counts[tag, default: 0] += 1
            }
        }
        return counts
    }

    private static func category(for reason: String) -> String {
        if let separatorIndex = reason.firstIndex(of: ":") {
            return String(reason[..<separatorIndex])
        }
        return reason
    }
}
