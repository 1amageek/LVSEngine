struct LVSCorpusEvidenceAssessment: Sendable {
    let qualificationScope: LVSImplementationIdentity?
    let primaryIdentities: [LVSImplementationIdentity]
    let oracleIdentities: [LVSImplementationIdentity]
    let completePrimaryIdentityCaseCount: Int
    let independentOracleCaseCount: Int
    let independentOracleAgreementPassedCaseCount: Int
    let nonIndependentOracleCaseCount: Int
    let oracleIntegrityFailureCount: Int
    let reportIntegrityFailureCodes: [String]
    let failureCodes: [String]
    let meetsCriteria: Bool

    init(report: LVSCorpusReport) {
        let completePrimaryIdentities: [LVSImplementationIdentity] = report.caseResults.compactMap {
            result -> LVSImplementationIdentity? in
            guard let identity = result.primaryProvenance?.implementationIdentity,
                  identity.isComplete else {
                return nil
            }
            return identity
        }
        let uniquePrimaryIdentities = Self.sortedUnique(completePrimaryIdentities)
        let uniqueOracleIdentities = Self.sortedUnique(report.caseResults.compactMap {
            result -> LVSImplementationIdentity? in
            guard let identity = result.oracleResult?.provenance?.implementationIdentity,
                  identity.isComplete else {
                return nil
            }
            return identity
        })
        let independentResults = report.caseResults.filter(Self.hasIndependentOracle)
        let oracleResults = report.caseResults.compactMap(\.oracleResult)
        let reportIntegrityCodes = report.assessment.findings
            .map(\.code)
            .filter { $0.hasPrefix("report_") }
        let oracleIntegrityFailureCount = oracleResults.reduce(0) {
            $0 + $1.integrityDiagnostics.count
        }

        var assessmentFailureCodes: [String] = []
        let scope = Self.qualificationScope(
            report: report,
            completePrimaryIdentities: completePrimaryIdentities,
            uniquePrimaryIdentities: uniquePrimaryIdentities
        )
        if scope == nil {
            assessmentFailureCodes.append("qualification_scope_missing_or_inconsistent")
        }
        let nonIndependentOracleCaseCount = oracleResults.count - independentResults.count
        if !oracleResults.isEmpty, nonIndependentOracleCaseCount > 0 {
            assessmentFailureCodes.append("oracle_implementation_not_independent")
        }
        if oracleIntegrityFailureCount > 0 {
            assessmentFailureCodes.append("oracle_evidence_integrity_failure")
        }
        if report.caseResults.contains(where: { $0.observedAssertions.isEmpty }) {
            assessmentFailureCodes.append("observed_assertions_missing")
        }
        if report.assessment.criteria.requiredObservedAssertions.isEmpty {
            assessmentFailureCodes.append("observed_assertion_policy_missing")
        }
        if report.summary.failedAssertionCount > 0 {
            assessmentFailureCodes.append("observed_assertion_failed")
        }
        if report.summary.blockedAssertionCount > 0 {
            assessmentFailureCodes.append("observed_assertion_blocked")
        }
        if report.summary.observedAssertionCounts["verdict:match"] == nil {
            assessmentFailureCodes.append("observed_match_assertion_missing")
        }
        if report.summary.observedAssertionCounts["verdict:mismatch"] == nil {
            assessmentFailureCodes.append("observed_mismatch_assertion_missing")
        }

        qualificationScope = scope
        primaryIdentities = uniquePrimaryIdentities
        oracleIdentities = uniqueOracleIdentities
        completePrimaryIdentityCaseCount = completePrimaryIdentities.count
        independentOracleCaseCount = independentResults.count
        independentOracleAgreementPassedCaseCount = independentResults.filter { result in
            guard let oracle = result.oracleResult else { return false }
            return oracle.agreementPassed && oracle.readinessStatus == .ready
        }.count
        self.nonIndependentOracleCaseCount = nonIndependentOracleCaseCount
        self.oracleIntegrityFailureCount = oracleIntegrityFailureCount
        reportIntegrityFailureCodes = Array(Set(reportIntegrityCodes)).sorted()
        failureCodes = Array(Set(reportIntegrityCodes + assessmentFailureCodes)).sorted()
        meetsCriteria = report.assessment.meetsCriteria && assessmentFailureCodes.isEmpty
    }

    var hasCompleteIndependentOracleEvidence: Bool {
        independentOracleCaseCount > 0
            && nonIndependentOracleCaseCount == 0
            && independentOracleAgreementPassedCaseCount == independentOracleCaseCount
            && oracleIntegrityFailureCount == 0
    }

    private static func hasIndependentOracle(_ result: LVSCorpusCaseResult) -> Bool {
        guard let primaryIdentity = result.primaryProvenance?.implementationIdentity,
              let oracleIdentity = result.oracleResult?.provenance?.implementationIdentity,
              primaryIdentity.isComplete,
              oracleIdentity.isComplete else {
            return false
        }
        return oracleIdentity.implementationID != primaryIdentity.implementationID
            && oracleIdentity.binaryDigest != primaryIdentity.binaryDigest
            && oracleIdentity.processProfileID == primaryIdentity.processProfileID
    }

    private static func qualificationScope(
        report: LVSCorpusReport,
        completePrimaryIdentities: [LVSImplementationIdentity],
        uniquePrimaryIdentities: [LVSImplementationIdentity]
    ) -> LVSImplementationIdentity? {
        guard completePrimaryIdentities.count == report.caseResults.count else {
            return nil
        }
        guard let qualificationScopeCaseID = report.qualificationScopeCaseID else {
            return uniquePrimaryIdentities.count == 1 ? uniquePrimaryIdentities.first : nil
        }
        guard let scope = report.caseResults.first(where: {
            $0.caseID == qualificationScopeCaseID
        })?.primaryProvenance?.implementationIdentity,
        scope.isComplete else {
            return nil
        }
        let allIdentitiesSupportScope = completePrimaryIdentities.allSatisfy { identity in
            identity == scope || isProcessNeutralSupport(identity, for: scope)
        }
        return allIdentitiesSupportScope ? scope : nil
    }

    private static func isProcessNeutralSupport(
        _ identity: LVSImplementationIdentity,
        for scope: LVSImplementationIdentity
    ) -> Bool {
        identity.implementationID == scope.implementationID
            && identity.binaryDigest == scope.binaryDigest
            && identity.processProfileID == "process-neutral"
            && identity.deckDigest == "no-deck"
    }

    private static func sortedUnique(
        _ identities: [LVSImplementationIdentity]
    ) -> [LVSImplementationIdentity] {
        Array(Set(identities)).sorted { lhs, rhs in
            Self.sortKey(lhs) < Self.sortKey(rhs)
        }
    }

    private static func sortKey(_ identity: LVSImplementationIdentity) -> String {
        [
            identity.implementationID,
            identity.binaryDigest,
            identity.algorithmVersion,
            identity.processProfileID,
            identity.deckDigest,
        ].joined(separator: "\u{1F}")
    }
}
