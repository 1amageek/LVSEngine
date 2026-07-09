import Foundation
import CryptoKit
import Testing
import LVSCore
import LVSRuntime

@Suite("Default LVS engine")
struct DefaultLVSEngineTests {
    @Test func injectedExtractorPreparesLayoutNetlistForBackend() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutGDSURL = directory.appending(path: "inverter.gds")
        let schematicNetlistURL = directory.appending(path: "inverter.spice")
        try Data([0x00, 0x01, 0x02]).write(to: layoutGDSURL)
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: schematicNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        let request = LVSRequest(
            layoutGDSURL: layoutGDSURL,
            schematicNetlistURL: schematicNetlistURL,
            topCell: "inv",
            workingDirectory: directory,
            backendSelection: LVSBackendSelection(backendID: "stub")
        )

        let result = try await DefaultLVSEngine(
            backend: StubLVSBackend(),
            layoutNetlistExtractor: StubLayoutNetlistExtractor()
        ).run(request)

        #expect(result.result.passed)
        #expect(result.extractedLayoutNetlistURL?.lastPathComponent.hasPrefix("inv.extracted") == true)
        #expect(result.request.layoutNetlistURL == directory.appending(path: "inv.extracted.spice"))
        #expect(result.reportURL?.lastPathComponent.hasPrefix("lvs-report-") == true)
        #expect(result.reportURL?.pathExtension == "json")
        #expect(result.artifactManifestURL?.lastPathComponent.hasPrefix("lvs-artifact-manifest-") == true)
        let reportURL = try #require(result.reportURL)
        let data = try Data(contentsOf: reportURL)
        let decoded = try JSONDecoder().decode(LVSExecutionResult.self, from: data)
        #expect(decoded.result.provenance?.executablePath == "/bin/stub-lvs")
        let manifestURL = try #require(result.artifactManifestURL)
        let manifest = try JSONDecoder().decode(LVSArtifactManifest.self, from: Data(contentsOf: manifestURL))
        let inputLayout = try artifact("input-layout", in: manifest.inputs)
        let inputLayoutNetlist = try artifact("input-layout-netlist", in: manifest.inputs)
        let inputSchematic = try artifact("input-schematic-netlist", in: manifest.inputs)
        let report = try artifact("report", in: manifest.outputs)
        let expectedInputLayoutSHA256 = try sha256(layoutGDSURL)
        let expectedInputLayoutNetlistSHA256 = try sha256(directory.appending(path: "inv.extracted.spice"))
        let expectedInputSchematicSHA256 = try sha256(schematicNetlistURL)
        let expectedReportSHA256 = try sha256(reportURL)
        #expect(inputLayout.sha256 == expectedInputLayoutSHA256)
        #expect(inputLayout.byteCount == 3)
        #expect(inputLayoutNetlist.sha256 == expectedInputLayoutNetlistSHA256)
        #expect(inputSchematic.sha256 == expectedInputSchematicSHA256)
        #expect(report.sha256 == expectedReportSHA256)
        #expect(report.byteCount == data.count)
    }

    @Test func artifactManifestRetainsExternalInputsInsideRunDirectory() async throws {
        let inputDirectory = try makeTemporaryDirectory()
        let outputDirectory = try makeTemporaryDirectory()
        defer {
            removeTemporaryDirectory(inputDirectory)
            removeTemporaryDirectory(outputDirectory)
        }
        let layoutNetlistURL = inputDirectory.appending(path: "layout.spice")
        let schematicNetlistURL = inputDirectory.appending(path: "schematic.spice")
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: layoutNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: schematicNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        let request = LVSRequest(
            layoutNetlistURL: layoutNetlistURL,
            schematicNetlistURL: schematicNetlistURL,
            topCell: "inv",
            workingDirectory: outputDirectory,
            backendSelection: LVSBackendSelection(backendID: "stub")
        )

        let result = try await DefaultLVSEngine(
            backend: StubLVSBackend(),
            layoutNetlistExtractor: FailingLayoutNetlistExtractor()
        ).run(request)

        let manifestURL = try #require(result.artifactManifestURL)
        let manifest = try JSONDecoder().decode(
            LVSArtifactManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let layoutNetlist = try artifact("input-layout-netlist", in: manifest.inputs)
        let schematicNetlist = try artifact("input-schematic-netlist", in: manifest.inputs)
        for retainedInput in [layoutNetlist, schematicNetlist] {
            #expect(!retainedInput.path.hasPrefix("/"))
            #expect(retainedInput.path.hasPrefix("retained-artifacts/"))
            let retainedURL = outputDirectory.appending(path: retainedInput.path)
            #expect(FileManager.default.fileExists(atPath: retainedURL.path(percentEncoded: false)))
        }
        #expect(try Data(contentsOf: outputDirectory.appending(path: layoutNetlist.path)) == Data(contentsOf: layoutNetlistURL))
        #expect(try Data(contentsOf: outputDirectory.appending(path: schematicNetlist.path)) == Data(contentsOf: schematicNetlistURL))
        #expect(layoutNetlist.sha256 == (try sha256(layoutNetlistURL)))
        #expect(schematicNetlist.sha256 == (try sha256(schematicNetlistURL)))
    }

    @Test func artifactManifestRetainsSymlinkedInputTargetInsideRunDirectory() async throws {
        let externalDirectory = try makeTemporaryDirectory()
        let outputDirectory = try makeTemporaryDirectory()
        defer {
            removeTemporaryDirectory(externalDirectory)
            removeTemporaryDirectory(outputDirectory)
        }
        let layoutNetlistURL = outputDirectory.appending(path: "layout.spice")
        let externalSchematicURL = externalDirectory.appending(path: "schematic.spice")
        let symlinkSchematicURL = outputDirectory.appending(path: "linked-schematic.spice")
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: layoutNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: externalSchematicURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkSchematicURL,
            withDestinationURL: externalSchematicURL
        )
        let request = LVSRequest(
            layoutNetlistURL: layoutNetlistURL,
            schematicNetlistURL: symlinkSchematicURL,
            topCell: "inv",
            workingDirectory: outputDirectory,
            backendSelection: LVSBackendSelection(backendID: "stub")
        )

        let result = try await DefaultLVSEngine(
            backend: StubLVSBackend(),
            layoutNetlistExtractor: FailingLayoutNetlistExtractor()
        ).run(request)

        let manifestURL = try #require(result.artifactManifestURL)
        let manifest = try JSONDecoder().decode(
            LVSArtifactManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let schematicNetlist = try artifact("input-schematic-netlist", in: manifest.inputs)
        #expect(schematicNetlist.path.hasPrefix("retained-artifacts/input-schematic-netlist/"))
        let retainedURL = outputDirectory.appending(path: schematicNetlist.path)
        #expect(FileManager.default.fileExists(atPath: retainedURL.path(percentEncoded: false)))
        #expect(try Data(contentsOf: retainedURL) == Data(contentsOf: externalSchematicURL))
        #expect(schematicNetlist.sha256 == (try sha256(externalSchematicURL)))
    }

    @Test func artifactStoreRejectsRetainedDirectorySymlinkEscape() async throws {
        let inputDirectory = try makeTemporaryDirectory()
        let outputDirectory = try makeTemporaryDirectory()
        let escapeDirectory = try makeTemporaryDirectory()
        defer {
            removeTemporaryDirectory(inputDirectory)
            removeTemporaryDirectory(outputDirectory)
            removeTemporaryDirectory(escapeDirectory)
        }
        let layoutNetlistURL = outputDirectory.appending(path: "layout.spice")
        let schematicNetlistURL = inputDirectory.appending(path: "schematic.spice")
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: layoutNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: schematicNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        let retainedRoot = outputDirectory.appending(path: "retained-artifacts")
        try FileManager.default.createDirectory(at: retainedRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: retainedRoot.appending(path: "input-schematic-netlist"),
            withDestinationURL: escapeDirectory
        )
        let request = LVSRequest(
            layoutNetlistURL: layoutNetlistURL,
            schematicNetlistURL: schematicNetlistURL,
            topCell: "inv",
            workingDirectory: outputDirectory,
            backendSelection: LVSBackendSelection(backendID: "stub")
        )

        do {
            _ = try await DefaultLVSEngine(
                backend: StubLVSBackend(),
                layoutNetlistExtractor: FailingLayoutNetlistExtractor()
            ).run(request)
            #expect(Bool(false), "Expected retained artifact directory symlink escape to fail")
        } catch let error as LVSError {
            #expect(error.errorDescription?.contains("retained artifact directory escapes") == true)
        }
    }

    @Test func existingLayoutNetlistDoesNotRequireExtractor() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutNetlistURL = directory.appending(path: "layout.spice")
        let schematicNetlistURL = directory.appending(path: "schematic.spice")
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: layoutNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: schematicNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        let request = LVSRequest(
            layoutNetlistURL: layoutNetlistURL,
            schematicNetlistURL: schematicNetlistURL,
            topCell: "inv",
            workingDirectory: directory,
            backendSelection: LVSBackendSelection(backendID: "stub")
        )

        let result = try await DefaultLVSEngine(
            backend: StubLVSBackend(),
            layoutNetlistExtractor: FailingLayoutNetlistExtractor()
        ).run(request)

        #expect(result.result.passed)
        #expect(result.extractedLayoutNetlistURL == nil)
        #expect(result.request.layoutNetlistURL == layoutNetlistURL)
    }

    @Test func artifactStoreRejectsNonFileInputURLBeforePersistenceRead() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutNetlistURL = directory.appending(path: "layout.spice")
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: layoutNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        let schematicNetlistURL = try #require(URL(string: "lvs-artifact://schematic.spice"))
        let request = LVSRequest(
            layoutNetlistURL: layoutNetlistURL,
            schematicNetlistURL: schematicNetlistURL,
            topCell: "inv",
            workingDirectory: directory,
            backendSelection: LVSBackendSelection(backendID: "stub")
        )

        do {
            _ = try await DefaultLVSEngine(backend: StubLVSBackend()).run(request)
            #expect(Bool(false), "Expected non-file artifact URL to fail before persistence read")
        } catch let error as LVSError {
            #expect(error.errorDescription?.contains("non-file artifact URL") == true)
            #expect(error.errorDescription?.contains("lvs-artifact://schematic.spice") == true)
        }
    }

    @Test func nativeBackendIsAvailableByDefault() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutNetlistURL = directory.appending(path: "layout.spice")
        let schematicNetlistURL = directory.appending(path: "schematic.spice")
        let netlist = """
        .subckt inv in out vdd vss
        M1 out in vdd vdd pmos
        M2 out in vss vss nmos
        .ends inv
        """
        try netlist.write(to: layoutNetlistURL, atomically: true, encoding: .utf8)
        try netlist.write(to: schematicNetlistURL, atomically: true, encoding: .utf8)

        let result = try await DefaultLVSEngine(
            backend: nil,
            layoutNetlistExtractor: nil
        ).run(LVSRequest(
            layoutNetlistURL: layoutNetlistURL,
            schematicNetlistURL: schematicNetlistURL,
            topCell: "inv",
            backendSelection: LVSBackendSelection(backendID: "native")
        ))

        #expect(result.result.passed)
    }

    @Test func corpusOracleReadinessDefaultsWhenDecodingLegacyArtifacts() throws {
        let successfulOracleJSON = """
        {
          "backendID": "native",
          "passed": true,
          "activeErrorRuleIDs": [],
          "diagnosticSummary": {
            "infoCount": 0,
            "warningCount": 0,
            "errorCount": 0,
            "waivedErrorCount": 0
          },
          "durationSeconds": 0.01,
          "agreementPassed": true,
          "failureReasons": [],
          "executionError": null,
          "reportPath": "/tmp/report.json",
          "manifestPath": "/tmp/manifest.json",
          "extractedLayoutNetlistPath": null
        }
        """
        let blockedOracleJSON = """
        {
          "backendID": "netgen",
          "passed": false,
          "activeErrorRuleIDs": [],
          "diagnosticSummary": {
            "infoCount": 0,
            "warningCount": 0,
            "errorCount": 0,
            "waivedErrorCount": 0
          },
          "durationSeconds": 0.01,
          "agreementPassed": false,
          "failureReasons": ["oracle_execution_failed:missing tool"],
          "executionError": "missing tool",
          "reportPath": null,
          "manifestPath": null,
          "extractedLayoutNetlistPath": null
        }
        """
        let summaryJSON = """
        {
          "expectationMatchedCaseCount": 1,
          "durationBudgetPassedCaseCount": 1,
          "primaryExecutionFailedCaseCount": 0,
          "oracleCaseCount": 1,
          "oracleAgreementPassedCaseCount": 0,
          "oracleExecutionFailedCaseCount": 1,
          "failureCategoryCounts": {"oracle_execution_failed": 1},
          "coverageTagCounts": {},
          "passRate": 0,
          "oracleAgreementRate": 0
        }
        """

        let successfulOracle = try JSONDecoder().decode(
            LVSCorpusOracleResult.self,
            from: Data(successfulOracleJSON.utf8)
        )
        let blockedOracle = try JSONDecoder().decode(
            LVSCorpusOracleResult.self,
            from: Data(blockedOracleJSON.utf8)
        )
        let summary = try JSONDecoder().decode(
            LVSCorpusSummary.self,
            from: Data(summaryJSON.utf8)
        )

        #expect(successfulOracle.readinessStatus == .ready)
        #expect(successfulOracle.readinessDiagnostics.isEmpty)
        #expect(blockedOracle.readinessStatus == .blocked)
        #expect(blockedOracle.readinessDiagnostics.isEmpty)
        #expect(summary.oracleReadinessBlockedCaseCount == 1)
    }

    @Test func nativeGDSBackendBypassesExtractorAndPreservesTechnology() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutGDSURL = directory.appending(path: "layout.gds")
        let schematicNetlistURL = directory.appending(path: "schematic.spice")
        let technologyURL = directory.appending(path: "tech.json")
        try Data([0x00, 0x01, 0x02]).write(to: layoutGDSURL)
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: schematicNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: technologyURL, atomically: true, encoding: .utf8)

        let result = try await DefaultLVSEngine(
            backend: StubNativeGDSLVSBackend(),
            layoutNetlistExtractor: FailingLayoutNetlistExtractor()
        ).run(LVSRequest(
            layoutGDSURL: layoutGDSURL,
            schematicNetlistURL: schematicNetlistURL,
            topCell: "inv",
            technologyURL: technologyURL,
            workingDirectory: directory,
            backendSelection: LVSBackendSelection(backendID: "native-gds")
        ))

        #expect(result.result.passed)
        #expect(result.request.layoutGDSURL == layoutGDSURL)
        #expect(result.request.layoutNetlistURL == nil)
        #expect(result.request.technologyURL == technologyURL)
        #expect(result.extractedLayoutNetlistURL == nil)
        #expect(result.artifactManifestURL != nil)
    }

    @Test func deprecatedBackendAliasesAreNormalized() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutGDSURL = directory.appending(path: "layout.gds")
        let schematicNetlistURL = directory.appending(path: "schematic.spice")
        let technologyURL = directory.appending(path: "tech.json")
        try Data([0x00, 0x01, 0x02]).write(to: layoutGDSURL)
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: schematicNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(to: technologyURL, atomically: true, encoding: .utf8)

        let result = try await DefaultLVSEngine(
            backend: StubNativeGDSLVSBackend(),
            layoutNetlistExtractor: FailingLayoutNetlistExtractor()
        ).run(LVSRequest(
            layoutGDSURL: layoutGDSURL,
            schematicNetlistURL: schematicNetlistURL,
            topCell: "inv",
            technologyURL: technologyURL,
            backendSelection: LVSBackendSelection(backendID: "pure-swift-gds")
        ))

        #expect(result.result.backendID == "native-gds")
    }

    @Test func waiverFileMarksMatchingDiagnosticsAndIsPersisted() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutNetlistURL = directory.appending(path: "layout.spice")
        let schematicNetlistURL = directory.appending(path: "schematic.spice")
        let waiverURL = directory.appending(path: "lvs-waivers.json")
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: layoutNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: schematicNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try writeWaivers(
            LVSWaiverFile(waivers: [
                LVSWaiver(
                    id: "waive-nmos-signature",
                    reason: "Known fixture mismatch",
                    ruleID: "LVS_COMPONENT_MISMATCH",
                    category: "componentCountMismatch",
                    componentSignature: "mos|nmos|out,in,vss,vss|"
                ),
                LVSWaiver(
                    id: "unused-waiver",
                    reason: "Should be reported as stale",
                    ruleID: "LVS_PORT_MISMATCH"
                ),
            ]),
            to: waiverURL
        )

        let result = try await DefaultLVSEngine(
            backend: WaiverStubLVSBackend(),
            layoutNetlistExtractor: nil
        ).run(LVSRequest(
            layoutNetlistURL: layoutNetlistURL,
            schematicNetlistURL: schematicNetlistURL,
            topCell: "inv",
            waiverURL: waiverURL,
            workingDirectory: directory,
            backendSelection: LVSBackendSelection(backendID: "waiver-stub")
        ))

        #expect(result.result.passed)
        let diagnostic = try #require(result.result.diagnostics.first)
        #expect(diagnostic.waiverID == "waive-nmos-signature")
        #expect(diagnostic.waiverReason == "Known fixture mismatch")
        let waiverReport = try #require(result.waiverReport)
        #expect(waiverReport.waivedDiagnosticCount == 1)
        #expect(waiverReport.unusedWaiverIDs == ["unused-waiver"])
        let manifestURL = try #require(result.artifactManifestURL)
        let manifest = try JSONDecoder().decode(LVSArtifactManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.passed)
        #expect(manifest.diagnosticSummary.errorCount == 0)
        #expect(manifest.diagnosticSummary.waivedErrorCount == 1)
        #expect(manifest.waiverReport == waiverReport)
        #expect(manifest.inputs.contains { $0.id == "input-waivers" && $0.kind == .waiver && $0.sha256 != nil })
    }

    @Test func corpusRunnerFailsWhenOracleBackendDisagrees() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutNetlistURL = directory.appending(path: "layout.spice")
        let schematicNetlistURL = directory.appending(path: "schematic.spice")
        let specURL = directory.appending(path: "lvs-corpus.json")
        let outputDirectory = directory.appending(path: "corpus-output")
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: layoutNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: schematicNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try writeJSON(LVSCorpusSpec(cases: [
            LVSCorpusCase(
                caseID: "oracle-mismatch",
                layoutNetlistPath: layoutNetlistURL.lastPathComponent,
                schematicNetlistPath: schematicNetlistURL.lastPathComponent,
                topCell: "inv",
                backendID: "clean-stub",
                oracleBackendID: "violation-stub",
                expectedPassed: true
            ),
        ]), to: specURL)

        let engine = DefaultLVSEngine(
            backends: [
                CleanStubLVSBackend(),
                ViolationStubLVSBackend(),
            ],
            layoutNetlistExtractor: nil
        )
        let report = try await LVSCorpusRunner(engine: engine).run(
            specURL: specURL,
            outputDirectory: outputDirectory
        )

        #expect(!report.passed)
        #expect(report.caseCount == 1)
        #expect(report.matchedCaseCount == 0)
        #expect(report.summary.primaryExecutionFailedCaseCount == 0)
        #expect(report.summary.oracleExecutionFailedCaseCount == 0)
        #expect(report.summary.failureCategoryCounts["oracle_agreement_mismatch"] == 1)
        #expect(report.summary.disagreementClassCounts["comparisonMismatch"] == 1)
        let result = try #require(report.caseResults.first)
        #expect(result.expectationMatched)
        #expect(result.oracleResult?.backendID == "violation-stub")
        #expect(result.oracleResult?.agreementPassed == false)
        #expect(result.oracleResult?.readinessStatus == .ready)
        #expect(result.oracleResult?.readinessDiagnostics.isEmpty == true)
        #expect(result.failureReasons.contains("oracle_agreement_mismatch"))
        #expect(result.oracleResult?.failureReasons.contains("passed_mismatch") == true)
        #expect(result.oracleResult?.failureReasons.contains("active_error_rule_ids_mismatch") == true)
        #expect(result.oracleResult?.failureReasons.contains("diagnostic_summary_mismatch") == true)
        #expect(result.oracleResult?.failureReasons.contains("oracle_agreement_mismatch") == true)
        #expect(result.oracleComparison?.primaryBackendID == "clean-stub")
        #expect(result.oracleComparison?.oracleBackendID == "violation-stub")
        #expect(result.oracleComparison?.passedMatched == false)
        #expect(result.oracleComparison?.activeErrorRuleIDsMatched == false)
        #expect(result.oracleComparison?.diagnosticSummaryMatched == false)
        #expect(result.oracleComparison?.mismatchReasons.contains("passed_mismatch") == true)
        let classification = try #require(result.oracleComparison?.disagreementClassifications.first)
        #expect(classification.kind == .comparisonMismatch)
        #expect(classification.affectedLayoutComponents == ["XINV_LAYOUT"])
        #expect(classification.affectedSchematicComponents == ["XINV_SCHEMATIC"])
        #expect(classification.affectedNets == ["out", "y"])
        #expect(classification.diagnosticRuleIDs == ["oracle.port"])
        #expect(classification.artifactPaths.contains {
            $0.hasSuffix("layout.spice")
        })
        #expect(result.primaryProvenance?.inputArtifacts.contains { $0.id == "input-layout-netlist" } == true)
        #expect(result.oracleResult?.provenance?.inputArtifacts.contains { $0.id == "input-layout-netlist" } == true)
    }

    @Test func corpusRunnerFailsWhenOracleDiagnosticSummaryDiffers() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutNetlistURL = directory.appending(path: "layout.spice")
        let schematicNetlistURL = directory.appending(path: "schematic.spice")
        let specURL = directory.appending(path: "lvs-corpus.json")
        let outputDirectory = directory.appending(path: "corpus-output")
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: layoutNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: schematicNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try writeJSON(LVSCorpusSpec(cases: [
            LVSCorpusCase(
                caseID: "oracle-diagnostic-summary-mismatch",
                layoutNetlistPath: layoutNetlistURL.lastPathComponent,
                schematicNetlistPath: schematicNetlistURL.lastPathComponent,
                topCell: "inv",
                backendID: "warning-stub",
                oracleBackendID: "clean-stub",
                expectedPassed: true
            ),
        ]), to: specURL)

        let report = try await LVSCorpusRunner(engine: DefaultLVSEngine(
            backends: [
                WarningStubLVSBackend(),
                CleanStubLVSBackend(),
            ],
            layoutNetlistExtractor: nil
        )).run(
            specURL: specURL,
            outputDirectory: outputDirectory
        )

        #expect(!report.passed)
        #expect(report.matchedCaseCount == 0)
        #expect(report.summary.oracleAgreementPassedCaseCount == 0)
        #expect(report.summary.failureCategoryCounts["oracle_agreement_mismatch"] == 1)
        let result = try #require(report.caseResults.first)
        #expect(result.expectationMatched)
        #expect(result.oracleResult?.agreementPassed == false)
        #expect(result.oracleResult?.failureReasons.contains("diagnostic_summary_mismatch") == true)
        #expect(result.oracleComparison?.passedMatched == true)
        #expect(result.oracleComparison?.activeErrorRuleIDsMatched == true)
        #expect(result.oracleComparison?.diagnosticSummaryMatched == false)
        #expect(result.oracleComparison?.agreementPassed == false)
        #expect(result.oracleComparison?.mismatchReasons.contains("diagnostic_summary_mismatch") == true)
    }

    @Test func disagreementClassifierSeparatesRootCausesAndAffectedRefs() {
        let classifier = LVSDisagreementClassifier()
        let extraction = classifier.classify(
            primaryBackendID: "native-gds",
            oracleBackendID: "netgen",
            primaryPassed: false,
            oraclePassed: true,
            primaryDiagnostics: [
                LVSDiagnostic(
                    severity: .error,
                    message: "Layout extraction missed a device label",
                    ruleID: "extraction.missing-label",
                    category: "extraction",
                    layoutPorts: ["n1"],
                    rawLine: "EXTRACTION",
                    layoutComponentName: "M1"
                ),
            ],
            oracleDiagnostics: []
        )
        #expect(extraction.map(\.kind) == [.extraction])
        #expect(extraction.first?.affectedLayoutComponents == ["M1"])
        #expect(extraction.first?.affectedNets == ["n1"])

        let policyReport = LVSDevicePolicyApplicationReport(
            generatedAt: "2026-06-29T00:00:00Z",
            status: .partial,
            policyPath: "/tmp/policy.json",
            seedSourcePath: "/tmp/netgen_setup.tcl",
            knownDeviceCount: 1,
            observedKnownDeviceCount: 1,
            appliedRuleCount: 0,
            ignoredRuleCount: 1,
            deviceFamilyCounts: ["mos": 1],
            observedDeviceFamilyCounts: ["mos": 1],
            appliedRules: [],
            ignoredRules: [
                LVSDevicePolicyIgnoredRule(
                    kind: "property",
                    reasonCode: "unsupported-property-command",
                    message: "Unsupported property command",
                    sourceLineNumber: 12,
                    sourceLine: "property mos unsupported"
                ),
            ]
        )
        let policy = classifier.classify(
            primaryBackendID: "native",
            oracleBackendID: "netgen",
            primaryPassed: false,
            oraclePassed: true,
            primaryDiagnostics: [],
            oracleDiagnostics: [],
            primaryDevicePolicyReport: policyReport
        )
        #expect(policy.map(\.kind) == [.policyInterpretation])
        #expect(policy.first?.policyReasonCodes == ["unsupported-property-command"])
        #expect(policy.first?.policySourceLines == ["property mos unsupported"])

        let parsing = classifier.classify(
            primaryBackendID: "native",
            oracleBackendID: "netgen",
            primaryPassed: false,
            oraclePassed: true,
            primaryDiagnostics: [],
            oracleDiagnostics: [],
            primaryExecutionError: "Could not parse SPICE subckt include"
        )
        #expect(parsing.map(\.kind) == [.netlistParsing])
        #expect(parsing.first?.reasonCodes.contains("could-not-parse-spice-subckt-include") == true)

        let readiness = classifier.classify(
            primaryBackendID: "native",
            oracleBackendID: "missing-netgen",
            primaryPassed: true,
            oraclePassed: false,
            primaryDiagnostics: [],
            oracleDiagnostics: [],
            oracleExecutionError: "Unsupported LVS backend: missing-netgen",
            oracleReadinessStatus: .blocked
        )
        #expect(readiness.map(\.kind) == [.toolReadiness])
        #expect(readiness.first?.reasonCodes.contains("unsupported-lvs-backend-missing-netgen") == true)

        let comparison = classifier.classify(
            primaryBackendID: "native",
            oracleBackendID: "netgen",
            primaryPassed: true,
            oraclePassed: false,
            primaryDiagnostics: [],
            oracleDiagnostics: [
                LVSDiagnostic(
                    severity: .error,
                    message: "Oracle reports parameter mismatch",
                    ruleID: "oracle.param",
                    category: "parameterMismatch",
                    componentSignature: "nfet:4",
                    layoutValue: "1u",
                    schematicValue: "2u",
                    rawLine: "PARAM",
                    layoutComponentName: "M1",
                    schematicComponentName: "M1"
                ),
            ],
            mismatchReasons: ["passed_mismatch", "active_error_rule_ids_mismatch"]
        )
        #expect(comparison.map(\.kind) == [.comparisonMismatch])
        #expect(comparison.first?.affectedComponentSignatures == ["nfet:4"])
        #expect(comparison.first?.diagnosticRuleIDs == ["oracle.param"])

        let mixedRootCauses = classifier.classify(
            primaryBackendID: "native-gds",
            oracleBackendID: "netgen",
            primaryPassed: false,
            oraclePassed: true,
            primaryDiagnostics: [
                LVSDiagnostic(
                    severity: .error,
                    message: "Layout extraction missed a device label",
                    ruleID: "extraction.missing-label",
                    category: "extraction",
                    layoutPorts: ["extracted"],
                    rawLine: "EXTRACTION",
                    layoutComponentName: "M_EXTRACT"
                ),
                LVSDiagnostic(
                    severity: .warning,
                    message: "Device policy ignored a property mapping",
                    ruleID: "policy.ignored-property",
                    category: "device policy",
                    layoutPorts: ["policy"],
                    rawLine: "POLICY",
                    layoutComponentName: "M_POLICY"
                ),
            ],
            oracleDiagnostics: []
        )
        let extractionClass = mixedRootCauses.first { $0.kind == .extraction }
        let policyClass = mixedRootCauses.first { $0.kind == .policyInterpretation }
        #expect(mixedRootCauses.map(\.kind) == [.extraction, .policyInterpretation])
        #expect(extractionClass?.affectedLayoutComponents == ["M_EXTRACT"])
        #expect(extractionClass?.affectedNets == ["extracted"])
        #expect(extractionClass?.diagnosticRuleIDs == ["extraction.missing-label"])
        #expect(policyClass?.affectedLayoutComponents == ["M_POLICY"])
        #expect(policyClass?.affectedNets == ["policy"])
        #expect(policyClass?.diagnosticRuleIDs == ["policy.ignored-property"])
    }

    @Test func corpusRunnerWritesCaseFailureWhenPrimaryBackendIsUnavailable() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutNetlistURL = directory.appending(path: "layout.spice")
        let schematicNetlistURL = directory.appending(path: "schematic.spice")
        let specURL = directory.appending(path: "lvs-corpus.json")
        let outputDirectory = directory.appending(path: "corpus-output")
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: layoutNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: schematicNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try writeJSON(LVSCorpusSpec(cases: [
            LVSCorpusCase(
                caseID: "missing-primary",
                layoutNetlistPath: layoutNetlistURL.lastPathComponent,
                schematicNetlistPath: schematicNetlistURL.lastPathComponent,
                topCell: "inv",
                backendID: "missing-backend",
                expectedPassed: true
            ),
        ]), to: specURL)

        let report = try await LVSCorpusRunner(engine: DefaultLVSEngine(
            backends: [],
            layoutNetlistExtractor: nil
        )).run(
            specURL: specURL,
            outputDirectory: outputDirectory
        )

        #expect(!report.passed)
        #expect(report.caseCount == 1)
        #expect(report.matchedCaseCount == 0)
        #expect(report.summary.primaryExecutionFailedCaseCount == 1)
        #expect(report.summary.failureCategoryCounts["primary_execution_failed"] == 1)
        let result = try #require(report.caseResults.first)
        #expect(result.executionError?.contains("Unsupported LVS backend: missing-backend") == true)
        #expect(result.failureReasons.contains {
            $0.hasPrefix("primary_execution_failed:")
        })
        #expect(result.reportPath == nil)
        #expect(result.manifestPath == nil)
        #expect(FileManager.default.fileExists(
            atPath: outputDirectory.appending(path: "lvs-corpus-report.json").path(percentEncoded: false)
        ))
    }

    @Test func corpusRunnerRejectsInputPathTraversalAsCaseFailure() async throws {
        let directory = try makeTemporaryDirectory()
        let schematicNetlistURL = directory.appending(path: "schematic.spice")
        let specURL = directory.appending(path: "lvs-corpus.json")
        let outputDirectory = directory.appending(path: "corpus-output")
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: schematicNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try writeJSON(LVSCorpusSpec(cases: [
            LVSCorpusCase(
                caseID: "path-traversal",
                layoutNetlistPath: "../outside-layout.spice",
                schematicNetlistPath: schematicNetlistURL.lastPathComponent,
                topCell: "inv",
                backendID: "clean-stub",
                expectedPassed: true
            ),
        ]), to: specURL)

        let report = try await LVSCorpusRunner(engine: DefaultLVSEngine(
            backends: [
                CleanStubLVSBackend(),
            ],
            layoutNetlistExtractor: nil
        )).run(
            specURL: specURL,
            outputDirectory: outputDirectory
        )

        #expect(!report.passed)
        #expect(report.summary.primaryExecutionFailedCaseCount == 1)
        let result = try #require(report.caseResults.first)
        #expect(result.executionError?.contains("path-traversal.layoutNetlistPath") == true)
        #expect(result.executionError?.contains("inside the LVS corpus spec directory") == true)
        #expect(result.failureReasons.contains {
            $0.hasPrefix("primary_execution_failed:")
        })
        #expect(FileManager.default.fileExists(
            atPath: outputDirectory.appending(path: "lvs-corpus-report.json").path(percentEncoded: false)
        ))
    }

    @Test func corpusRunnerRejectsCollidingCaseOutputDirectories() async throws {
        let directory = try makeTemporaryDirectory()
        let specURL = directory.appending(path: "lvs-corpus.json")
        let outputDirectory = directory.appending(path: "corpus-output")
        try writeJSON(LVSCorpusSpec(cases: [
            LVSCorpusCase(
                caseID: "same/path",
                layoutNetlistPath: "layout-a.spice",
                schematicNetlistPath: "schematic-a.spice",
                topCell: "inv",
                backendID: "clean-stub",
                expectedPassed: true
            ),
            LVSCorpusCase(
                caseID: "same_path",
                layoutNetlistPath: "layout-b.spice",
                schematicNetlistPath: "schematic-b.spice",
                topCell: "inv",
                backendID: "clean-stub",
                expectedPassed: true
            ),
        ]), to: specURL)

        do {
            _ = try await LVSCorpusRunner(engine: DefaultLVSEngine(
                backends: [
                    CleanStubLVSBackend(),
                ],
                layoutNetlistExtractor: nil
            )).run(
                specURL: specURL,
                outputDirectory: outputDirectory
            )
            Issue.record("Expected colliding LVS corpus case output directories to be rejected.")
        } catch let error as LVSError {
            guard case .invalidInput(let message) = error else {
                Issue.record("Expected invalidInput, got \(error).")
                return
            }
            #expect(message.contains("same/path"))
            #expect(message.contains("same_path"))
            #expect(message.contains("same output directory"))
        } catch {
            Issue.record("Expected LVS error, got \(error).")
        }
    }

    @Test func corpusRunnerReportsOracleBackendUnavailable() async throws {
        let directory = try makeTemporaryDirectory()
        let layoutNetlistURL = directory.appending(path: "layout.spice")
        let schematicNetlistURL = directory.appending(path: "schematic.spice")
        let specURL = directory.appending(path: "lvs-corpus.json")
        let outputDirectory = directory.appending(path: "corpus-output")
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: layoutNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try ".subckt inv in out vdd vss\n.ends inv\n".write(
            to: schematicNetlistURL,
            atomically: true,
            encoding: .utf8
        )
        try writeJSON(LVSCorpusSpec(cases: [
            LVSCorpusCase(
                caseID: "missing-oracle",
                layoutNetlistPath: layoutNetlistURL.lastPathComponent,
                schematicNetlistPath: schematicNetlistURL.lastPathComponent,
                topCell: "inv",
                backendID: "clean-stub",
                oracleBackendID: "missing-oracle",
                expectedPassed: true
            ),
        ]), to: specURL)

        let report = try await LVSCorpusRunner(engine: DefaultLVSEngine(
            backends: [
                CleanStubLVSBackend(),
            ],
            layoutNetlistExtractor: nil
        )).run(
            specURL: specURL,
            outputDirectory: outputDirectory
        )

        #expect(!report.passed)
        #expect(report.summary.oracleCaseCount == 1)
        #expect(report.summary.oracleAgreementPassedCaseCount == 0)
        #expect(report.summary.oracleExecutionFailedCaseCount == 1)
        #expect(report.summary.oracleReadinessBlockedCaseCount == 1)
        #expect(report.summary.failureCategoryCounts["oracle_agreement_mismatch"] == 1)
        #expect(report.summary.failureCategoryCounts["oracle_execution_failed"] == 1)
        let result = try #require(report.caseResults.first)
        #expect(result.expectationMatched)
        #expect(result.oracleResult?.backendID == "missing-oracle")
        #expect(result.oracleResult?.agreementPassed == false)
        #expect(result.oracleResult?.readinessStatus == .blocked)
        #expect(result.oracleResult?.readinessDiagnostics.contains {
            $0.contains("Unsupported LVS backend: missing-oracle")
        } == true)
        #expect(result.oracleResult?.executionError?.contains("Unsupported LVS backend: missing-oracle") == true)
        #expect(result.failureReasons.contains("oracle_agreement_mismatch"))
        #expect(result.failureReasons.contains {
            $0.hasPrefix("oracle_execution_failed:")
        })
        #expect(result.oracleComparison?.passedMatched == false)
        #expect(result.oracleComparison?.activeErrorRuleIDsMatched == true)
        #expect(result.oracleComparison?.mismatchReasons.contains("passed_mismatch") == true)
        #expect(result.oracleComparison?.mismatchReasons.contains {
            $0.hasPrefix("oracle_execution_failed:")
        } == true)
        let classification = try #require(result.oracleComparison?.disagreementClassifications.first)
        #expect(classification.kind == .toolReadiness)
        #expect(classification.reasonCodes.contains("tool-readiness-blocked"))
        #expect(report.summary.disagreementClassCounts["toolReadiness"] == 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DefaultLVSEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeTemporaryDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove temporary directory: \(error.localizedDescription)")
        }
    }

    private func artifact(_ id: String, in records: [LVSArtifactRecord]) throws -> LVSArtifactRecord {
        try #require(records.first { $0.id == id })
    }

    private func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writeWaivers(_ waivers: LVSWaiverFile, to url: URL) throws {
        try writeJSON(waivers, to: url)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private struct StubLVSBackend: LVSBackend {
        let backendID = "stub"

        func run(_ request: LVSRequest) async throws -> LVSExecutionResult {
            guard request.layoutNetlistURL != nil else {
                throw LVSError.invalidInput("Stub LVS backend requires a layout netlist")
            }
            return LVSExecutionResult(
                request: request,
                result: LVSResult(
                    backendID: backendID,
                    toolName: "stub-lvs",
                    success: true,
                    completed: true,
                    logPath: "/tmp/stub-lvs.log",
                    provenance: LVSToolProvenance(
                        executablePath: "/bin/stub-lvs",
                        pdkRoot: "/tmp/pdk",
                        setupFilePath: "/tmp/sky130A_setup.tcl",
                        driverScriptPath: "/tmp/lvs.tcl",
                        timeoutSeconds: request.options.timeoutSeconds
                    )
                )
            )
        }
    }

    private struct CleanStubLVSBackend: LVSBackend {
        let backendID = "clean-stub"

        func run(_ request: LVSRequest) async throws -> LVSExecutionResult {
            LVSExecutionResult(
                request: request,
                result: LVSResult(
                    backendID: backendID,
                    toolName: "clean-stub-lvs",
                    success: true,
                    completed: true,
                    logPath: ""
                )
            )
        }
    }

    private struct WarningStubLVSBackend: LVSBackend {
        let backendID = "warning-stub"

        func run(_ request: LVSRequest) async throws -> LVSExecutionResult {
            LVSExecutionResult(
                request: request,
                result: LVSResult(
                    backendID: backendID,
                    toolName: "warning-stub-lvs",
                    success: true,
                    completed: true,
                    logPath: "",
                    diagnostics: [
                        LVSDiagnostic(
                            severity: .warning,
                            message: "Primary backend reported a non-fatal normalization warning",
                            ruleID: "primary.warning",
                            category: "normalization",
                            rawLine: "PRIMARY_WARNING"
                        ),
                    ]
                )
            )
        }
    }

    private struct ViolationStubLVSBackend: LVSBackend {
        let backendID = "violation-stub"

        func run(_ request: LVSRequest) async throws -> LVSExecutionResult {
            LVSExecutionResult(
                request: request,
                result: LVSResult(
                    backendID: backendID,
                    toolName: "violation-stub-lvs",
                    success: true,
                    completed: true,
                    logPath: "",
                    diagnostics: [
                        LVSDiagnostic(
                            severity: .error,
                            message: "Oracle reports port mismatch",
                            ruleID: "oracle.port",
                            category: "portMismatch",
                            componentSignature: "inv:ports",
                            layoutPorts: ["out"],
                            schematicPorts: ["y"],
                            rawLine: "ORACLE_PORT",
                            layoutComponentName: "XINV_LAYOUT",
                            schematicComponentName: "XINV_SCHEMATIC"
                        ),
                    ]
                )
            )
        }
    }

    private struct StubNativeGDSLVSBackend: LVSBackend {
        let backendID = "native-gds"

        func run(_ request: LVSRequest) async throws -> LVSExecutionResult {
            guard request.layoutGDSURL != nil else {
                throw LVSError.invalidInput("Stub GDS LVS backend requires a layout")
            }
            guard request.layoutNetlistURL == nil else {
                throw LVSError.invalidInput("Stub GDS LVS backend should not receive extracted netlist")
            }
            guard request.technologyURL != nil else {
                throw LVSError.invalidInput("Stub GDS LVS backend requires technology")
            }
            return LVSExecutionResult(
                request: request,
                result: LVSResult(
                    backendID: backendID,
                    toolName: "stub-gds-lvs",
                    success: true,
                    completed: true,
                    logPath: "",
                    provenance: LVSToolProvenance(
                        executablePath: "in-process",
                        pdkRoot: request.technologyURL?.path(percentEncoded: false) ?? "",
                        setupFilePath: "not-applicable",
                        driverScriptPath: "not-applicable",
                        timeoutSeconds: request.options.timeoutSeconds
                    )
                )
            )
        }
    }

    private struct WaiverStubLVSBackend: LVSBackend {
        let backendID = "waiver-stub"

        func run(_ request: LVSRequest) async throws -> LVSExecutionResult {
            guard request.layoutNetlistURL != nil else {
                throw LVSError.invalidInput("Waiver stub LVS backend requires a layout netlist")
            }
            return LVSExecutionResult(
                request: request,
                result: LVSResult(
                    backendID: backendID,
                    toolName: "waiver-stub-lvs",
                    success: true,
                    completed: true,
                    logPath: "",
                    diagnostics: [
                        LVSDiagnostic(
                            severity: .error,
                            message: "Component signature count differs",
                            ruleID: "LVS_COMPONENT_MISMATCH",
                            category: "componentCountMismatch",
                            componentSignature: "mos|nmos|out,in,vss,vss|",
                            layoutCount: 1,
                            schematicCount: 0,
                            rawLine: "signature=mos|nmos|out,in,vss,vss| layout=1 schematic=0"
                        ),
                    ]
                )
            )
        }
    }

    private struct StubLayoutNetlistExtractor: LVSLayoutNetlistExtracting {
        func extractLayoutNetlist(
            gds: URL,
            topCell: String,
            into directory: URL,
            timeoutSeconds: Double
        ) async throws -> URL {
            let outputURL = directory.appending(path: "\(topCell).extracted.spice")
            try Data().write(to: outputURL)
            return outputURL
        }
    }

    private struct FailingLayoutNetlistExtractor: LVSLayoutNetlistExtracting {
        func extractLayoutNetlist(
            gds: URL,
            topCell: String,
            into directory: URL,
            timeoutSeconds: Double
        ) async throws -> URL {
            throw LVSError.backendFailed("Extractor should not be called")
        }
    }
}
