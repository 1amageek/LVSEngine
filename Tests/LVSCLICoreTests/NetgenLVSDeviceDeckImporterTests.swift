import Foundation
import Testing
import LVSCore

@Suite("Netgen LVS device deck importer")
struct NetgenLVSDeviceDeckImporterTests {
    @Test func importsDevicesAndPinPolicyRules() throws {
        let result = NetgenLVSDeviceDeckImporter.importDeviceDeck(
            text: """
            lappend devices sky130_fd_pr__nfet_01v8 sky130_fd_pr__pfet_01v8
            lappend devices sky130_fd_pr__res_generic_m1
            lappend devices sky130_fd_pr__diode_pw2nd_05v5
            lappend devices sky130_fd_pr__cap_mim_m3_1
            lappend devices sky130_fd_pr__npn_05v5
            lappend devices sky130_fd_pr__ind_04_01
            permute "-circuit1 $dev" 1 2
            property "-circuit1 $dev" parallel enable
            equate pins "-circuit1 $dev" "-circuit2 $dev"
            """,
            sourcePath: "/tmp/sky130A_setup.tcl",
            generatedAt: "2026-06-23T00:00:00Z"
        )

        #expect(result.report.status == .complete)
        #expect(result.report.importedDeviceCount == 7)
        #expect(result.report.importedPolicyRuleCount == 3)
        #expect(result.report.deviceFamilyCounts["mos"] == 2)
        #expect(result.report.deviceFamilyCounts["resistor"] == 1)
        #expect(result.report.deviceFamilyCounts["diode"] == 1)
        #expect(result.report.deviceFamilyCounts["capacitor"] == 1)
        #expect(result.report.deviceFamilyCounts["bjt"] == 1)
        #expect(result.report.deviceFamilyCounts["inductor"] == 1)
        #expect(result.report.policyRuleCounts["equate-pins"] == 1)
        #expect(result.seed.devices.contains { $0.deviceName == "sky130_fd_pr__nfet_01v8" })

        let data = try JSONEncoder().encode(result.report)
        let decoded = try JSONDecoder().decode(NetgenLVSDeviceDeckImportReport.self, from: data)
        #expect(decoded == result.report)

        let audit = NetgenLVSDeviceDeckImportAuditor().audit(
            seed: result.seed,
            report: result.report,
            seedPath: "/tmp/lvs-device-policy.json",
            reportPath: "/tmp/lvs-device-import.json",
            checkedAt: "2026-06-23T00:00:00Z"
        )
        #expect(audit.status == .incomplete)
        #expect(audit.summary.unresolvedPolicyRuleCount == 3)
        #expect(audit.requirements.contains {
            $0.requirementID == "maximum-unresolved-policy-rule-count" && $0.status == .incomplete
        })
        #expect(audit.requirements.contains { $0.requirementID == "policy-rule-equate-pins" })
    }

    @Test func expandsDeviceForeachPolicyRules() {
        let result = NetgenLVSDeviceDeckImporter.importDeviceDeck(
            text: """
            set devices {}
            lappend devices sky130_fd_pr__res_generic_m1
            lappend devices sky130_fd_pr__res_generic_m2
            foreach dev $devices {
                if {[lsearch $cells1 $dev] >= 0} {
                    permute "-circuit1 $dev" 1 2
                    property "-circuit1 $dev" parallel enable
                }
            }
            """,
            sourcePath: "/tmp/sky130A_setup.tcl",
            generatedAt: "2026-06-23T00:00:00Z"
        )

        #expect(result.report.status == .complete)
        #expect(result.report.importedDeviceCount == 2)
        #expect(result.report.importedPolicyRuleCount == 4)
        #expect(result.report.policyRuleCounts["permute"] == 2)
        #expect(result.report.policyRuleCounts["property"] == 2)
        #expect(result.seed.policyRules.allSatisfy {
            !$0.arguments.joined(separator: " ").contains("$dev")
        })
        #expect(result.seed.policyRules.contains {
            $0.kind == "permute" && $0.arguments.contains("-circuit1 sky130_fd_pr__res_generic_m1")
        })
        #expect(result.seed.policyRules.contains {
            $0.kind == "permute" && $0.arguments.contains("-circuit1 sky130_fd_pr__res_generic_m2")
        })
    }

    @Test func importsRuntimePredicatesAndIgnoreClassWithoutLosingDeckSemantics() throws {
        let result = NetgenLVSDeviceDeckImporter.importDeviceDeck(
            text: """
            catch {format $env(NETGEN_COLUMNS)}
            set devices {}
            lappend devices sky130_fd_io__condiode
            foreach dev $devices {
                permute "-circuit1 $dev" 1 2
                property "-circuit1 $dev" parallel enable
                equate pins "-circuit1 $dev" "-circuit2 $dev"
                ignore class "-circuit1 $dev"
            }
            foreach cell $cells1 {
                if {[regexp {sky130_fd_sc_[^_]+__fill_[[:digit:]]+} $cell match]} {
                    ignore class "-circuit1 $cell"
                    property "-circuit1 $cell" parallel enable
                }
                if {[regexp "(.+)__(.+)" $cell match library cellname]} {
                    equate classes "-circuit1 $cell" "-circuit2 $cellname"
                    equate pins "-circuit1 $cell" "-circuit2 $cellname"
                }
            }
            """,
            sourcePath: "/tmp/sky130A_setup.tcl",
            generatedAt: "2026-07-12T00:00:00Z"
        )

        #expect(result.report.status == .complete)
        #expect(result.report.skippedLineCount == 0)
        #expect(result.report.policyRuleCounts["ignore-class"] == 2)
        #expect(result.report.policyRuleCounts["equate"] == 1)
        #expect(result.report.policyRuleCounts["equate-pins"] == 2)
        let fillRule = try #require(result.seed.policyRules.first {
            $0.kind == "ignore-class" && $0.arguments.contains("-circuit1 $cell")
        })
        #expect(fillRule.runtimePredicate?.variableName == "cell")
        #expect(fillRule.runtimePredicate?.pattern.contains("__fill_") == true)
        let renameRule = try #require(result.seed.policyRules.first { $0.kind == "equate" })
        #expect(renameRule.runtimePredicate?.captureVariableNames == ["library", "cellname"])

        let audit = NetgenLVSDeviceDeckImportAuditor().audit(
            seed: result.seed,
            report: result.report,
            policy: NetgenLVSDeviceDeckImportAuditPolicy(
                policyID: "runtime-policy-readiness",
                minimumDeviceCount: 1,
                minimumPolicyRuleCount: 1,
                maximumUnresolvedPolicyRuleCount: 0,
                allowPartialImport: false,
                requiredPolicyRuleCounts: [
                    "equate-pins": 1,
                    "ignore-class": 1,
                    "permute": 1,
                    "property": 1,
                ]
            )
        )
        #expect(audit.status == .satisfied)
        #expect(audit.summary.unresolvedPolicyRuleCount == 0)

        let encoded = try JSONEncoder().encode(result.seed)
        let decoded = try JSONDecoder().decode(NetgenLVSDevicePolicySeed.self, from: encoded)
        #expect(decoded == result.seed)
    }

    @Test func unsupportedNetgenSetupCommandMakesImportPartial() {
        let result = NetgenLVSDeviceDeckImporter.importDeviceDeck(
            text: """
            lappend devices sky130_fd_pr__nfet_01v8
            compare hierarchical
            property "-circuit1 sky130_fd_pr__nfet_01v8" parallel enable
            """,
            sourcePath: "/tmp/unsupported-netgen-command.tcl",
            generatedAt: "2026-07-04T00:00:00Z"
        )

        #expect(result.report.status == .partial)
        #expect(result.report.importedDeviceCount == 1)
        #expect(result.report.importedPolicyRuleCount == 1)
        #expect(result.report.skippedLineCount == 1)
        let diagnostic = result.report.diagnostics.first
        #expect(diagnostic?.code == "unsupported_netgen_setup_command")
        #expect(diagnostic?.sourceLineNumber == 2)
        #expect(diagnostic?.sourceLine == "compare hierarchical")
    }

    @Test func blocksWhenNoDevicesAreImported() {
        let result = NetgenLVSDeviceDeckImporter.importDeviceDeck(
            text: """
            puts "setup"
            property "-circuit1 $dev" parallel enable
            """,
            sourcePath: "/tmp/sky130A_setup.tcl",
            generatedAt: "2026-06-23T00:00:00Z"
        )

        #expect(result.report.status == .blocked)
        #expect(result.report.importedDeviceCount == 0)
        #expect(result.report.diagnostics.contains { $0.code == "netgen_device_map_empty" })

        let audit = NetgenLVSDeviceDeckImportAuditor().audit(
            seed: result.seed,
            report: result.report,
            checkedAt: "2026-06-23T00:00:00Z"
        )
        #expect(audit.status == .blocked)
        #expect(audit.requirements.contains {
            $0.requirementID == "import-status" && $0.status == .blocked
        })
    }

    @Test func auditReportsMissingPolicyRuleKinds() {
        let result = NetgenLVSDeviceDeckImporter.importDeviceDeck(
            text: """
            lappend devices sky130_fd_pr__nfet_01v8
            property "-circuit1 sky130_fd_pr__nfet_01v8" parallel enable
            """,
            sourcePath: "/tmp/sky130A_setup.tcl",
            generatedAt: "2026-06-23T00:00:00Z"
        )

        let audit = NetgenLVSDeviceDeckImportAuditor().audit(
            seed: result.seed,
            report: result.report,
            checkedAt: "2026-06-23T00:00:00Z"
        )

        #expect(result.report.status == .complete)
        #expect(audit.status == .incomplete)
        #expect(audit.requirements.contains {
            $0.requirementID == "policy-rule-equate-pins" && $0.status == .incomplete
        })
        #expect(audit.requirements.contains {
            $0.requirementID == "policy-rule-permute" && $0.status == .incomplete
        })
    }

    @Test func auditPolicyRejectsUnsupportedSchemaAndNegativeThresholds() {
        let unsupportedSchema = Data("""
        {
          "schemaVersion": 2,
          "policyID": "device-policy",
          "minimumDeviceCount": 1,
          "minimumPolicyRuleCount": 1,
          "maximumUnresolvedPolicyRuleCount": 0,
          "allowPartialImport": false
        }
        """.utf8)
        let negativeThreshold = Data("""
        {
          "schemaVersion": 1,
          "policyID": "device-policy",
          "minimumDeviceCount": -1,
          "minimumPolicyRuleCount": 1,
          "maximumUnresolvedPolicyRuleCount": 0,
          "allowPartialImport": false
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                NetgenLVSDeviceDeckImportAuditPolicy.self,
                from: unsupportedSchema
            )
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                NetgenLVSDeviceDeckImportAuditPolicy.self,
                from: negativeThreshold
            )
        }
    }

    @Test func auditBlocksInvalidProgrammaticPolicy() {
        let result = NetgenLVSDeviceDeckImporter.importDeviceDeck(
            text: """
            lappend devices sky130_fd_pr__nfet_01v8
            permute "-circuit1 sky130_fd_pr__nfet_01v8" 1 2
            property "-circuit1 sky130_fd_pr__nfet_01v8" parallel enable
            equate pins "-circuit1 sky130_fd_pr__nfet_01v8" "-circuit2 sky130_fd_pr__nfet_01v8"
            """,
            sourcePath: "/tmp/sky130A_setup.tcl",
            generatedAt: "2026-07-12T00:00:00Z"
        )
        let invalidPolicy = NetgenLVSDeviceDeckImportAuditPolicy(
            schemaVersion: 99,
            policyID: " ",
            minimumDeviceCount: -1,
            minimumPolicyRuleCount: -1,
            maximumUnresolvedPolicyRuleCount: 0,
            allowPartialImport: true
        )

        let audit = NetgenLVSDeviceDeckImportAuditor().audit(
            seed: result.seed,
            report: result.report,
            policy: invalidPolicy
        )

        #expect(audit.status == .blocked)
        #expect(audit.requirements.contains {
            $0.requirementID == "audit-policy-validity" && $0.status == .blocked
        })
    }
}
