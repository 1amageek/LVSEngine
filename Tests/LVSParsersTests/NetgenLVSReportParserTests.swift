import Testing
import LVSCore
import LVSParsers

@Suite("Netgen LVS report parser")
struct NetgenLVSReportParserTests {
    @Test func matchingCompletedReportPasses() {
        let report = NetgenLVSReportParser().parse(
            logPath: "/tmp/lvs.log",
            rawOutput: """
            LVS_RESULT status=match message="Netlists match uniquely"
            LVS_DONE
            """,
            success: true
        )

        #expect(report.passed)
        #expect(report.executionStatus == .completed)
        #expect(report.diagnostics.isEmpty)
    }

    @Test func escapedResultMessageFieldsAreDecoded() {
        let report = NetgenLVSReportParser().parse(
            logPath: "/tmp/lvs.log",
            rawOutput: #"""
            LVS_RESULT status=match message="Netlists \"match\", uniquely\nwith warning text"
            LVS_DONE
            """#,
            success: true
        )

        #expect(report.passed)
        #expect(report.diagnostics.isEmpty)
    }

    @Test func mismatchReportFails() {
        let report = NetgenLVSReportParser().parse(
            logPath: "/tmp/lvs.log",
            rawOutput: """
            MISMATCH rule=LVS_MISMATCH message="Top level cell failed pin matching"
            LVS_DONE
            """,
            success: true
        )

        #expect(!report.passed)
        #expect(report.executionStatus == .completed)
        #expect(report.diagnostics.count == 1)
        #expect(report.diagnostics[0].ruleID == "LVS_MISMATCH")
    }

    @Test func nonMatchingResultStatusFailsWithoutMismatchLine() {
        let report = NetgenLVSReportParser().parse(
            logPath: "/tmp/lvs.log",
            rawOutput: """
            LVS_RESULT status=mismatch message="Netlists do not match"
            LVS_DONE
            """,
            success: true
        )

        #expect(!report.passed)
        #expect(report.executionStatus == .completed)
        #expect(report.diagnostics.count == 1)
        #expect(report.diagnostics[0].ruleID == "LVS_RESULT")
    }

    @Test func completedReportWithoutResultCannotPass() {
        let report = NetgenLVSReportParser().parse(
            logPath: "/tmp/lvs.log",
            rawOutput: "LVS_DONE",
            success: true
        )

        #expect(!report.passed)
        #expect(report.executionStatus == .completed)
        #expect(report.diagnostics.count == 1)
        #expect(report.diagnostics[0].ruleID == "LVS_RESULT_MISSING")
    }

    @Test func missingCompletionMarkerCannotPass() {
        let report = NetgenLVSReportParser().parse(
            logPath: "/tmp/lvs.log",
            rawOutput: #"LVS_RESULT status=match message="Netlists match uniquely""#,
            success: true
        )

        #expect(!report.passed)
        #expect(report.executionStatus != .completed)
    }

    @Test func completionMarkerMustBeExactLine() {
        let report = NetgenLVSReportParser().parse(
            logPath: "/tmp/lvs.log",
            rawOutput: #"LVS_RESULT status=match message="LVS_DONE""#,
            success: true
        )

        #expect(!report.passed)
        #expect(report.executionStatus != .completed)
    }
}
