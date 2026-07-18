import Foundation
import LayoutTech
import LVSCLICore
import LVSCore
import Testing

extension LVSCLIOptionsTests {
    @Test
    func productionTechnologyFixtureDecodes() throws {
        let technologyURL = externalOracleFixtureURL("sky130-layout-tech.json")
        _ = try JSONDecoder().decode(
            LayoutTechDatabase.self,
            from: Data(contentsOf: technologyURL)
        )
    }

    @Test
    func productionCorpusDeclaresIndependentObservedAssertionCoverage() throws {
        let specURL = externalOracleFixtureURL("lvs-production-corpus.json")
        let spec = try JSONDecoder().decode(
            LVSCorpusSpec.self,
            from: Data(contentsOf: specURL)
        )

        #expect(spec.defaultMaxDurationSeconds == 30)
        #expect(spec.cases.count == 40)
        #expect(Set(spec.cases.compactMap(\.backendID)) == ["native", "native-gds"])
        #expect(Set(spec.cases.compactMap(\.oracleBackendID)) == ["netgen"])
        #expect(spec.acceptanceCriteria.minimumOracleCaseCount == 40)
        #expect(spec.acceptanceCriteria.requiredObservedAssertions.contains("oracleAgreement:true"))
        #expect(spec.acceptanceCriteria.requiredObservedAssertions.contains("oracleIndependence:ready"))
        #expect(spec.acceptanceCriteria.requiredObservedAssertions.contains("determinism:stable"))
        #expect(spec.acceptanceCriteria.requiredObservedAssertions.contains("cancellation:cancelled"))
        #expect(spec.acceptanceCriteria.requiredObservedAssertions.contains("extractionProfileReadiness:ready"))
        #expect(spec.acceptanceCriteria.requiredObservedAssertions.contains("hierarchyDepth:1"))
        #expect(spec.acceptanceCriteria.requiredObservedAssertions.contains("structureClass:analog"))
        #expect(spec.acceptanceCriteria.requiredObservedAssertions.contains("devicePolicyImport:satisfied"))
        #expect(spec.acceptanceCriteria.requiredObservedAssertions.contains("devicePolicyApplication:complete"))
        #expect(spec.acceptanceCriteria.requiredObservedAssertions.contains("devicePolicyRule:ignore-class"))

        let physicalDigitalCases = spec.cases.filter {
            $0.backendID == "native-gds"
                && $0.extractionProfilePath
                    == "sky130A-layout-extraction-profile.json"
                && $0.extractionDeckPath == "pdk://libs.tech/magic/sky130A.tech"
                && $0.requiredAssertions.contains { $0.kind == .extractionArtifact }
                && $0.requiredAssertions.contains {
                    $0.kind == .extractionProfileReadiness && $0.expectedValue == "ready"
                }
                && $0.devicePolicyDeckPath == "pdk://libs.tech/netgen/sky130A_setup.tcl"
                && Set($0.requiredAssertions.compactMap { assertion in
                    assertion.kind == .devicePolicyRule ? assertion.expectedValue : nil
                }) == ["blackbox", "equate", "equate-pins", "ignore-class", "permute", "property"]
                && $0.requiredAssertions.contains {
                    $0.kind == .devicePolicyImport && $0.expectedValue == "satisfied"
                }
                && $0.requiredAssertions.contains {
                    $0.kind == .devicePolicyApplication && $0.expectedValue == "complete"
                }
        }
        let hierarchicalCases = spec.cases.filter {
            $0.requiredAssertions.contains {
                $0.kind == .hierarchyDepth && $0.expectedValue == "1"
            }
        }
        let analogCases = spec.cases.filter {
            $0.requiredAssertions.contains {
                $0.kind == .structureClass && $0.expectedValue == "analog"
            }
        }

        #expect(physicalDigitalCases.count == 20)
        let extractionProfileURL = externalOracleFixtureURL("sky130A-layout-extraction-profile.json")
        let extractionProfile = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: extractionProfileURL)) as? [String: Any]
        )
        #expect(extractionProfile["schemaVersion"] as? Int == 1)
        #expect(extractionProfile["processProfileID"] as? String == "sky130.open-pdk.digital-mos.signoff")
        #expect(extractionProfile["productionEligible"] as? Bool == true)
        #expect(
            extractionProfile["extractionDeckDigest"] as? String
                == "31287ea98453d1a4a0fe9e18f8e2a9a0aa411bea3e5eae9db3dd5e450bcd57c0"
        )
        #expect(hierarchicalCases.count == 5)
        #expect(analogCases.count == 10)
        #expect(spec.cases.allSatisfy { corpusCase in
            corpusCase.oracleBackendID == "netgen"
                && corpusCase.requiredAssertions.contains {
                    $0.kind == .oracleAgreement && $0.expectedValue == "true"
                }
                && corpusCase.requiredAssertions.contains {
                    $0.kind == .oracleIndependence && $0.expectedValue == "ready"
                }
        })
    }

    @Test
    func externalOracleCorpusUsesNativePrimaryAndNetgenReference() throws {
        let specURL = externalOracleFixtureURL("lvs-netgen-corpus.json")
        let spec = try JSONDecoder().decode(
            LVSCorpusSpec.self,
            from: Data(contentsOf: specURL)
        )

        #expect(spec.cases.count == 6)
        #expect(Set(spec.cases.compactMap(\.backendID)) == ["native"])
        #expect(Set(spec.cases.compactMap(\.oracleBackendID)) == ["netgen"])
        #expect(spec.acceptanceCriteria.minimumOracleCaseCount == 6)
        #expect(spec.acceptanceCriteria.minimumOracleAgreementRate == 1)
        #expect(spec.acceptanceCriteria.requiredObservedAssertions.contains("oracleAgreement:true"))
        #expect(spec.acceptanceCriteria.requiredObservedAssertions.contains("oracleIndependence:ready"))
        #expect(spec.cases.allSatisfy { corpusCase in
            corpusCase.backendID != corpusCase.oracleBackendID
                && corpusCase.oracleComparisonMode == .verdict
                && corpusCase.coverageTags.contains("external.netgen")
                && corpusCase.requiredAssertions.contains {
                    $0.kind == .oracleAgreement && $0.expectedValue == "true"
                }
                && corpusCase.requiredAssertions.contains {
                    $0.kind == .oracleIndependence && $0.expectedValue == "ready"
                }
        })
        #expect(spec.cases.filter { !$0.expectedPassed }.allSatisfy { corpusCase in
            corpusCase.expectedActiveErrorRuleIDs == ["LVS_MODEL_MISMATCH"]
                && corpusCase.requiredAssertions.contains {
                    $0.kind == .diagnosticRule && $0.expectedValue == "LVS_MODEL_MISMATCH"
                }
        })
    }

    @Test
    func corpusCoverageAuditRequiresPassedAssertionsFromTheSameCase() {
        let complete = observedCase(
            caseID: "complete",
            statuses: [.passed, .passed]
        )
        let splitFailure = observedCase(
            caseID: "split-failure",
            statuses: [.passed, .failed]
        )
        let policy = LVSCorpusCoverageAuditPolicy(
            policyID: "test.observed-assertions.v2",
            requireQualifiedCorpus: false,
            requireOracleAgreement: false,
            minimumCaseCount: 1,
            requirements: [
                .init(
                    requirementID: "same-case",
                    title: "Same-case observed evidence",
                    requiredObservedAssertions: ["durationBudget:within-budget", "verdict:match"]
                ),
            ]
        )

        let satisfied = LVSCorpusCoverageAuditor().audit(
            report: report(caseResults: [complete]),
            policy: policy
        )
        let incomplete = LVSCorpusCoverageAuditor().audit(
            report: report(caseResults: [splitFailure]),
            policy: policy
        )

        #expect(satisfied.status == .satisfied)
        #expect(satisfied.observedAssertions.contains("verdict:match"))
        #expect(incomplete.status == .incomplete)
        #expect(incomplete.missingRequirements.first?.missingAssertions == ["verdict:match"])
    }

    @Test
    func corpusCoveragePolicyRejectsUnsupportedSchemaAndInvalidThresholds() {
        let unsupportedSchema = Data("""
        {
          "schemaVersion": 1,
          "policyID": "test-policy",
          "requirements": [
            {
              "requirementID": "match",
              "title": "Match",
              "requiredObservedAssertions": ["verdict:match"],
              "minimumCaseCount": 1
            }
          ]
        }
        """.utf8)
        let invalidThreshold = Data("""
        {
          "schemaVersion": 2,
          "policyID": "test-policy",
          "minimumCaseCount": 0,
          "requirements": [
            {
              "requirementID": "match",
              "title": "Match",
              "requiredObservedAssertions": ["verdict:match"],
              "minimumCaseCount": 1
            }
          ]
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LVSCorpusCoverageAuditPolicy.self, from: unsupportedSchema)
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LVSCorpusCoverageAuditPolicy.self, from: invalidThreshold)
        }
    }

    @Test
    func corpusCoverageAuditBlocksInvalidProgrammaticPolicy() {
        let policy = LVSCorpusCoverageAuditPolicy(
            schemaVersion: 99,
            policyID: " ",
            requireQualifiedCorpus: false,
            requireOracleAgreement: false,
            minimumCaseCount: 0,
            requirements: []
        )

        let audit = LVSCorpusCoverageAuditor().audit(
            report: report(caseResults: [observedCase(caseID: "complete", statuses: [.passed, .passed])]),
            policy: policy
        )

        #expect(audit.status == .incomplete)
        #expect(audit.missingRequirements.contains {
            $0.requirementID == "coverage-policy-validity"
        })
    }

    @Test
    func corpusCoverageAuditFailsClosedForMissingAndStaleTimestamps() {
        let requirement = LVSCorpusCoverageAuditPolicy.Requirement(
            requirementID: "match",
            title: "Match",
            requiredObservedAssertions: ["verdict:match"]
        )
        let unboundedAgePolicy = LVSCorpusCoverageAuditPolicy(
            policyID: "test-huge-age",
            requireQualifiedCorpus: false,
            requireOracleAgreement: false,
            maxReportAgeSeconds: .greatestFiniteMagnitude,
            requirements: [requirement]
        )
        let missingTimestampAudit = LVSCorpusCoverageAuditor().audit(
            report: report(caseResults: [observedCase(caseID: "complete", statuses: [.passed, .passed])]),
            policy: unboundedAgePolicy,
            checkedAt: Date(timeIntervalSince1970: 100)
        )
        let stalePolicy = LVSCorpusCoverageAuditPolicy(
            policyID: "test-stale-age",
            requireQualifiedCorpus: false,
            requireOracleAgreement: false,
            maxReportAgeSeconds: 5,
            requirements: [requirement]
        )
        let staleAudit = LVSCorpusCoverageAuditor().audit(
            report: report(
                caseResults: [observedCase(caseID: "complete", statuses: [.passed, .passed])],
                generatedAt: "1970-01-01T00:01:40Z"
            ),
            policy: stalePolicy,
            checkedAt: Date(timeIntervalSince1970: 106)
        )

        #expect(missingTimestampAudit.status == .incomplete)
        #expect(missingTimestampAudit.missingRequirements.contains {
            $0.requirementID == "retained-report-freshness" && $0.requiredCaseCount == Int.max
        })
        #expect(staleAudit.status == .incomplete)
        #expect(staleAudit.summary.reportAgeSeconds == 6)
    }

    private func observedCase(
        caseID: String,
        statuses: [LVSCorpusAssertionStatus]
    ) -> LVSCorpusCaseResult {
        let assertions = [
            LVSCorpusObservedAssertion(
                assertionID: "duration",
                kind: .durationBudget,
                status: statuses[0],
                expectedValue: "within-budget",
                observedValue: "0.01",
                sourceArtifactRefs: ["manifest.json"]
            ),
            LVSCorpusObservedAssertion(
                assertionID: "verdict",
                kind: .verdict,
                status: statuses[1],
                expectedValue: "match",
                observedValue: "match",
                sourceArtifactRefs: ["manifest.json"]
            ),
        ]
        return LVSCorpusCaseResult(
            caseID: caseID,
            matched: true,
            expectedPassed: true,
            actualPassed: true,
            expectedActiveErrorRuleIDs: [],
            actualActiveErrorRuleIDs: [],
            expectationMatched: true,
            durationSeconds: 0.01,
            expectedMaxDurationSeconds: 1,
            durationBudgetPassed: true,
            failureReasons: [],
            diagnosticSummary: LVSDiagnosticSummary(
                infoCount: 0,
                warningCount: 0,
                errorCount: 0
            ),
            reportPath: "report.json",
            manifestPath: "manifest.json",
            extractedLayoutNetlistPath: nil,
            observedAssertions: assertions
        )
    }

    private func report(
        caseResults: [LVSCorpusCaseResult],
        generatedAt: String? = nil
    ) -> LVSCorpusReport {
        LVSCorpusReport(
            generatedAt: generatedAt,
            passed: true,
            caseCount: caseResults.count,
            matchedCaseCount: caseResults.count,
            totalDurationSeconds: caseResults.reduce(0) { $0 + $1.durationSeconds },
            acceptanceCriteria: LVSCorpusAcceptanceCriteria(
                requireCorpusPassed: false,
                requiredObservedAssertions: []
            ),
            caseResults: caseResults
        )
    }
}
