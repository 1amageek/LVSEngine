import Foundation
import LVSCore
import LayoutCore
import LayoutIO
import LayoutTech
import LayoutVerify

/// Pure Swift LVS on STANDARD inputs: devices are extracted from a GDS
/// layout in-process (channel recognition + connectivity + label-driven
/// net naming — the same DeviceExtractor the layout editor's live LVS
/// uses) and compared against a `.subckt` schematic reference. No
/// external extractor is involved; Magic/Netgen remain available as the
/// independent oracle backend.
public struct LayoutGDSLVSBackend: LVSBackend {
    public let backendID = "pure-swift-gds"

    public init() {}

    public func run(_ request: LVSRequest) async throws -> LVSExecutionResult {
        guard let layoutGDSURL = request.layoutGDSURL else {
            throw LVSError.invalidInput("The GDS backend needs layoutGDSURL.")
        }
        guard let technologyURL = request.technologyURL else {
            throw LVSError.invalidInput(
                "The GDS backend needs a technology database (technologyURL: LayoutTechDatabase JSON)."
            )
        }
        let tech: LayoutTechDatabase
        do {
            tech = try JSONDecoder().decode(
                LayoutTechDatabase.self,
                from: try Data(contentsOf: technologyURL)
            )
        } catch {
            throw LVSError.invalidInput(
                "Could not load technology database '\(technologyURL.lastPathComponent)': \(error.localizedDescription)"
            )
        }

        let document: LayoutDocument
        do {
            document = try GDSFormatConverter(tech: tech)
                .importDocument(from: layoutGDSURL, format: .gds)
        } catch {
            throw LVSError.invalidInput(
                "Could not read GDS layout '\(layoutGDSURL.lastPathComponent)': \(error.localizedDescription)"
            )
        }
        guard let topCell = document.cells.first(where: { $0.name == request.topCell }) else {
            throw LVSError.invalidInput(
                "Top cell '\(request.topCell)' is not in the layout (cells: \(document.cells.map(\.name).joined(separator: ", ")))."
            )
        }

        let reference: ComparisonNetlist
        do {
            reference = try SPICESubcktReader().read(
                try String(contentsOf: request.schematicNetlistURL, encoding: .utf8)
            )
        } catch {
            throw LVSError.invalidInput(
                "Could not read schematic reference '\(request.schematicNetlistURL.lastPathComponent)': \(error.localizedDescription)"
            )
        }

        let extraction: DeviceExtractionResult
        do {
            extraction = try DeviceExtractor().extract(
                document: document,
                tech: tech,
                cellID: topCell.id
            )
        } catch {
            throw LVSError.backendFailed(
                "Device extraction failed: \(error.localizedDescription)"
            )
        }

        var diagnostics: [LVSDiagnostic] = extraction.issues.map { issue in
            LVSDiagnostic(
                severity: .error,
                message: issue.message,
                ruleID: "extraction.\(issue.kind)",
                rawLine: "\(issue.kind) @ (\(issue.region.origin.x), \(issue.region.origin.y))"
            )
        }

        let comparison = NetlistComparator().compare(
            extracted: extraction.netlist,
            reference: reference
        )
        for device in comparison.unmatchedExtractedDevices {
            diagnostics.append(LVSDiagnostic(
                severity: .error,
                message: "Layout device \(device.id) (\(device.kind)) has no schematic counterpart.",
                ruleID: "compare.unmatchedExtracted",
                rawLine: device.id
            ))
        }
        for device in comparison.unmatchedReferenceDevices {
            diagnostics.append(LVSDiagnostic(
                severity: .error,
                message: "Schematic device \(device.id) (\(device.kind)) is not realized in the layout.",
                ruleID: "compare.unmatchedReference",
                rawLine: device.id
            ))
        }
        for mismatch in comparison.parameterMismatches {
            diagnostics.append(LVSDiagnostic(
                severity: .error,
                message: "Parameter mismatch \(mismatch.extractedDeviceID) vs \(mismatch.referenceDeviceID): extracted \(mismatch.extracted), reference \(mismatch.reference).",
                ruleID: "compare.parameterMismatch",
                rawLine: "\(mismatch.extractedDeviceID)/\(mismatch.referenceDeviceID)"
            ))
        }
        if diagnostics.isEmpty {
            diagnostics.append(LVSDiagnostic(
                severity: .info,
                message: "Layout matches schematic: \(comparison.referenceDeviceCount) device(s).",
                ruleID: "compare.match",
                rawLine: "match"
            ))
        }

        var logPath = ""
        if let workingDirectory = request.workingDirectory {
            let logURL = workingDirectory.appending(path: "lvs-pure-swift-gds.log")
            let log = diagnostics.map { "\($0.severity): \($0.message)" }
                .joined(separator: "\n") + "\n"
            try FileManager.default.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true
            )
            try log.write(to: logURL, atomically: true, encoding: .utf8)
            logPath = logURL.path(percentEncoded: false)
        }

        // `success` means the comparison RAN; the verdict lives in the
        // diagnostics (LVSResult.passed folds both).
        let result = LVSResult(
            backendID: backendID,
            toolName: "LayoutVerify",
            success: true,
            completed: true,
            logPath: logPath,
            diagnostics: diagnostics,
            provenance: LVSToolProvenance(
                executablePath: "in-process",
                pdkRoot: technologyURL.path(percentEncoded: false),
                setupFilePath: "not-applicable",
                driverScriptPath: "not-applicable",
                timeoutSeconds: request.options.timeoutSeconds
            )
        )
        return LVSExecutionResult(request: request, result: result)
    }
}
