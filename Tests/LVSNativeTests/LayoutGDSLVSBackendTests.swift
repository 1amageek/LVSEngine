import CryptoKit
import Foundation
import Testing
import LVSCore
import LayoutAutoGen
import LayoutCore
import LayoutIO
import LayoutLVSExtraction
import LayoutTech
@testable import LVSNative

/// Native LVS on STANDARD inputs: an in-code generated MOSFET goes
/// through GDS (where pins and nets die by format contract) and the
/// backend still matches it against the `.subckt` reference, because
/// extraction reads net labels straight off the conductors.
@Suite("Layout GDS LVS backend", .timeLimit(.minutes(2)))
struct LayoutGDSLVSBackendTests {
    private enum GeneratedLayoutFixtureError: Error {
        case missingPin(String)
        case missingBoundingBox
    }

    private enum ArrayedNMOSOrientation: Equatable {
        case verticalRows
        case horizontalColumns
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "gds-lvs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeTech(in root: URL) throws -> URL {
        let url = root.appending(path: "tech.json")
        try (try JSONEncoder().encode(LayoutTechDatabase.sampleProcess())).write(to: url)
        return url
    }

    private func writeExtractionDeck(in root: URL) throws -> URL {
        let url = root.appending(path: "extraction.deck")
        try Data("generated-mos-fixture-deck-v1".utf8).write(to: url, options: [.atomic])
        return url
    }

    private func writeExtractionProfile(in root: URL) throws -> URL {
        let deckURL = try writeExtractionDeck(in: root)
        let deckData = try Data(contentsOf: deckURL)
        let digest = SHA256.hash(data: deckData)
            .map { String(format: "%02x", $0) }
            .joined()
        let fixture = GeneratedMOSLayoutExtractionProfileFactory().makeProfile()
        let profile = LayoutExtractionProcessProfile(
            processID: fixture.processID,
            processProfileID: fixture.processProfileID,
            extractionDeckDigest: digest,
            productionEligible: fixture.productionEligible,
            parameterValueConvention: fixture.parameterValueConvention,
            conductorLayers: fixture.conductorLayers,
            connectionRules: fixture.connectionRules,
            mosRules: fixture.mosRules
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = root.appending(path: "extraction-profile.json")
        try encoder.encode(profile).write(to: url, options: [.atomic])
        return url
    }

    /// One generated MOS device, terminals labeled with the reference net
    /// names at the pin positions, exported to GDS.
    private func writeDeviceLayout(
        deviceKindID: String = "nmos",
        format: LayoutFileFormat = .gds,
        fileExtension: String = "gds",
        in root: URL
    ) throws -> URL {
        let tech = LayoutTechDatabase.sampleProcess()
        var cell = try MOSFETCellGenerator().generateCell(
            deviceKindID: deviceKindID,
            instanceName: "M1",
            parameters: ["w": 2.0, "l": 0.18, "nf": 1],
            tech: tech
        )
        cell.name = "TOP"
        cell.labels = []
        let netByPin = ["drain": "d", "gate": "g", "source": "s", "bulk": "b"]
        for pin in cell.pins {
            guard let net = netByPin[pin.name] else { continue }
            cell.labels.append(LayoutLabel(text: net, position: pin.position, layer: pin.layer))
        }
        let document = LayoutDocument(name: "TOP", cells: [cell], topCellID: cell.id)
        let url = root.appending(path: "top.\(fileExtension)")
        try MaskDataFormatConverter(tech: tech).exportDocument(document, to: url, format: format)
        return url
    }

    private func writeInverterLayout(
        format: LayoutFileFormat = .gds,
        fileExtension: String = "gds",
        in root: URL
    ) throws -> URL {
        let tech = LayoutTechDatabase.sampleProcess()
        let nmos = try makeDeviceCell(
            deviceKindID: "nmos",
            instanceName: "M2",
            netByPin: ["drain": "out", "gate": "in", "source": "vss", "bulk": "vss"],
            tech: tech
        )
        let pmos = try makeDeviceCell(
            deviceKindID: "pmos",
            instanceName: "M1",
            netByPin: ["drain": "out", "gate": "in", "source": "vdd", "bulk": "vdd"],
            tech: tech
        )
        let nmosPlaced = translatedCell(nmos, by: .zero)
        let nmosBox = try boundingBox(of: nmosPlaced)
        let pmosBox = try boundingBox(of: pmos)
        let pmosPlaced = translatedCell(
            pmos,
            by: LayoutPoint(x: 0, y: nmosBox.maxY - pmosBox.minY + 2.0)
        )

        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let m1Width = max(tech.ruleSet(for: m1)?.minWidth ?? 0.2, 0.2)
        let routes = try [
            m1Bridge(
                between: pin("gate", in: nmosPlaced).position,
                and: pin("gate", in: pmosPlaced).position,
                width: m1Width,
                layer: m1
            ),
            m1Bridge(
                between: pin("drain", in: nmosPlaced).position,
                and: pin("drain", in: pmosPlaced).position,
                width: m1Width,
                layer: m1
            ),
            m1Bridge(
                between: pin("source", in: nmosPlaced).position,
                and: pin("bulk", in: nmosPlaced).position,
                width: m1Width,
                layer: m1
            ),
            m1Bridge(
                between: pin("source", in: pmosPlaced).position,
                and: pin("bulk", in: pmosPlaced).position,
                width: m1Width,
                layer: m1
            ),
        ].flatMap { $0 }

        let top = LayoutCell(
            name: "TOP",
            shapes: nmosPlaced.shapes + pmosPlaced.shapes + routes,
            vias: nmosPlaced.vias + pmosPlaced.vias,
            labels: nmosPlaced.labels + pmosPlaced.labels
        )
        let document = LayoutDocument(name: "TOP", cells: [top], topCellID: top.id)
        let url = root.appending(path: "inverter.\(fileExtension)")
        try MaskDataFormatConverter(tech: tech).exportDocument(document, to: url, format: format)
        return url
    }

    private func writeHierarchicalInverterLayout(
        format: LayoutFileFormat = .gds,
        fileExtension: String = "gds",
        in root: URL
    ) throws -> URL {
        let tech = LayoutTechDatabase.sampleProcess()
        var nmos = try makeDeviceCell(
            deviceKindID: "nmos",
            instanceName: "M2",
            netByPin: ["drain": "out", "gate": "in", "source": "vss", "bulk": "vss"],
            tech: tech
        )
        nmos.name = "NMOS_DEVICE"
        var pmos = try makeDeviceCell(
            deviceKindID: "pmos",
            instanceName: "M1",
            netByPin: ["drain": "out", "gate": "in", "source": "vdd", "bulk": "vdd"],
            tech: tech
        )
        pmos.name = "PMOS_DEVICE"
        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        nmos.shapes.append(LayoutShape(
            layer: m1,
            geometry: .rect(LayoutRect(
                origin: LayoutPoint(x: 50, y: 0),
                size: LayoutSize(width: 1, height: 1)
            ))
        ))
        nmos.labels.append(LayoutLabel(
            text: "INTERNAL_ONLY",
            position: LayoutPoint(x: 50.5, y: 0.5),
            layer: m1
        ))

        let nmosTransform = LayoutTransform()
        let nmosPlaced = translatedCell(nmos, by: nmosTransform.translation)
        let nmosBox = try boundingBox(of: nmosPlaced)
        let pmosBox = try boundingBox(of: pmos)
        let pmosTransform = LayoutTransform(
            translation: LayoutPoint(x: 0, y: nmosBox.maxY - pmosBox.minY + 2.0)
        )
        let pmosPlaced = translatedCell(pmos, by: pmosTransform.translation)

        let m1Width = max(tech.ruleSet(for: m1)?.minWidth ?? 0.2, 0.2)
        let routes = try [
            m1Bridge(
                between: pin("gate", in: nmosPlaced).position,
                and: pin("gate", in: pmosPlaced).position,
                width: m1Width,
                layer: m1
            ),
            m1Bridge(
                between: pin("drain", in: nmosPlaced).position,
                and: pin("drain", in: pmosPlaced).position,
                width: m1Width,
                layer: m1
            ),
            m1Bridge(
                between: pin("source", in: nmosPlaced).position,
                and: pin("bulk", in: nmosPlaced).position,
                width: m1Width,
                layer: m1
            ),
            m1Bridge(
                between: pin("source", in: pmosPlaced).position,
                and: pin("bulk", in: pmosPlaced).position,
                width: m1Width,
                layer: m1
            ),
        ].flatMap { $0 }

        let top = LayoutCell(
            name: "TOP",
            shapes: routes,
            labels: try [
                LayoutLabel(
                    text: "in",
                    position: pin("gate", in: nmosPlaced).position,
                    layer: pin("gate", in: nmosPlaced).layer
                ),
                LayoutLabel(
                    text: "out",
                    position: pin("drain", in: nmosPlaced).position,
                    layer: pin("drain", in: nmosPlaced).layer
                ),
                LayoutLabel(
                    text: "vss",
                    position: pin("source", in: nmosPlaced).position,
                    layer: pin("source", in: nmosPlaced).layer
                ),
                LayoutLabel(
                    text: "vdd",
                    position: pin("source", in: pmosPlaced).position,
                    layer: pin("source", in: pmosPlaced).layer
                ),
            ],
            instances: [
                LayoutInstance(cellID: nmos.id, name: "XM2", transform: nmosTransform),
                LayoutInstance(cellID: pmos.id, name: "XM1", transform: pmosTransform),
            ]
        )
        let document = LayoutDocument(name: "TOP", cells: [top, nmos, pmos], topCellID: top.id)
        let url = root.appending(path: "hierarchical-inverter.\(fileExtension)")
        try MaskDataFormatConverter(tech: tech).exportDocument(document, to: url, format: format)
        return url
    }

    private func writeBlackboxMacroLayout(
        format: LayoutFileFormat = .gds,
        fileExtension: String = "gds",
        in root: URL
    ) throws -> URL {
        let tech = LayoutTechDatabase.sampleProcess()
        var macro = try makeDeviceCell(
            deviceKindID: "nmos",
            instanceName: "M1",
            netByPin: ["drain": "d", "gate": "g", "source": "s", "bulk": "b"],
            tech: tech
        )
        macro.name = "hard_macro"
        let top = LayoutCell(
            name: "TOP",
            labels: try [
                ("drain", "d"),
                ("gate", "g"),
                ("source", "s"),
                ("bulk", "b"),
            ].map { pinName, netName in
                let macroPin = try pin(pinName, in: macro)
                return LayoutLabel(text: netName, position: macroPin.position, layer: macroPin.layer)
            },
            instances: [
                LayoutInstance(cellID: macro.id, name: "XU1")
            ]
        )
        let document = LayoutDocument(name: "TOP", cells: [top, macro], topCellID: top.id)
        let url = root.appending(path: "blackbox-macro.\(fileExtension)")
        try MaskDataFormatConverter(tech: tech).exportDocument(document, to: url, format: format)
        return url
    }

    private func writeMixedBlackboxMacroAndDeviceLayout(
        format: LayoutFileFormat = .gds,
        fileExtension: String = "gds",
        in root: URL
    ) throws -> URL {
        let tech = LayoutTechDatabase.sampleProcess()
        var macro = try makeDeviceCell(
            deviceKindID: "nmos",
            instanceName: "M1",
            netByPin: ["drain": "d", "gate": "g", "source": "s", "bulk": "b"],
            tech: tech
        )
        macro.name = "hard_macro"
        let directDevice = try makeDeviceCell(
            deviceKindID: "nmos",
            instanceName: "M2",
            netByPin: ["drain": "dn", "gate": "gn", "source": "sn", "bulk": "bn"],
            tech: tech
        )
        let macroBox = try boundingBox(of: macro)
        let directBox = try boundingBox(of: directDevice)
        let directPlaced = translatedCell(
            directDevice,
            by: LayoutPoint(x: macroBox.maxX - directBox.minX + 10.0, y: 0)
        )

        let top = LayoutCell(
            name: "TOP",
            shapes: directPlaced.shapes,
            vias: directPlaced.vias,
            labels: directPlaced.labels + (try [
                ("drain", "d"),
                ("gate", "g"),
                ("source", "s"),
                ("bulk", "b"),
            ].map { pinName, netName in
                let macroPin = try pin(pinName, in: macro)
                return LayoutLabel(text: netName, position: macroPin.position, layer: macroPin.layer)
            }),
            instances: [
                LayoutInstance(cellID: macro.id, name: "XU1")
            ]
        )
        let document = LayoutDocument(name: "TOP", cells: [top, macro], topCellID: top.id)
        let url = root.appending(path: "mixed-blackbox-macro.\(fileExtension)")
        try MaskDataFormatConverter(tech: tech).exportDocument(document, to: url, format: format)
        return url
    }

    private func writeArrayedParallelNMOSLayout(
        orientation: ArrayedNMOSOrientation = .verticalRows,
        format: LayoutFileFormat = .gds,
        fileExtension: String = "gds",
        in root: URL
    ) throws -> URL {
        let tech = LayoutTechDatabase.sampleProcess()
        var nmos = try makeDeviceCell(
            deviceKindID: "nmos",
            instanceName: "MARRAY",
            netByPin: ["drain": "d", "gate": "g", "source": "s", "bulk": "s"],
            tech: tech
        )
        nmos.name = "NMOS_ARRAY_DEVICE"

        let nmosBox = try boundingBox(of: nmos)
        let repetition: LayoutRepetition
        let baseTransform: LayoutTransform
        let secondTransform: LayoutTransform
        let fileStem: String
        switch orientation {
        case .verticalRows:
            let secondOffset = LayoutPoint(x: 0, y: nmosBox.maxY - nmosBox.minY + 2.0)
            baseTransform = LayoutTransform()
            secondTransform = LayoutTransform(translation: secondOffset)
            repetition = LayoutRepetition(
                columns: 1,
                rows: 2,
                columnStep: .zero,
                rowStep: secondOffset
            )
            fileStem = "arrayed-parallel-nmos-vertical"
        case .horizontalColumns:
            let rotation = LayoutTransform(rotationDegrees: 90)
            let rotatedBox = try transformedBoundingBox(of: nmos, by: rotation)
            let normalizedTransform = LayoutTransform(
                translation: LayoutPoint(x: -rotatedBox.minX, y: -rotatedBox.minY),
                rotationDegrees: 90
            )
            let normalizedBox = try transformedBoundingBox(of: nmos, by: normalizedTransform)
            let secondOffset = LayoutPoint(x: normalizedBox.maxX - normalizedBox.minX + 2.0, y: 0)
            baseTransform = normalizedTransform
            secondTransform = LayoutTransform(
                translation: normalizedTransform.translation.translated(by: secondOffset),
                rotationDegrees: 90
            )
            repetition = LayoutRepetition(
                columns: 2,
                rows: 1,
                columnStep: secondOffset,
                rowStep: .zero
            )
            fileStem = "arrayed-parallel-nmos-horizontal"
        }

        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let m1Width = max(tech.ruleSet(for: m1)?.minWidth ?? 0.2, 0.2)
        let m2Width = max(tech.ruleSet(for: m2)?.minWidth ?? 0.28, 0.28)
        let m2Routes = try [
            m2BridgeWithVias(
                between: pinPosition("drain", in: nmos, transform: baseTransform),
                and: pinPosition("drain", in: nmos, transform: secondTransform),
                width: m2Width,
                layer: m2
            ),
            m2BridgeWithVias(
                between: pinPosition("gate", in: nmos, transform: baseTransform),
                and: pinPosition("gate", in: nmos, transform: secondTransform),
                width: m2Width,
                layer: m2
            ),
            m2BridgeWithVias(
                between: pinPosition("source", in: nmos, transform: baseTransform),
                and: pinPosition("source", in: nmos, transform: secondTransform),
                width: m2Width,
                layer: m2
            ),
        ]
        let sourceBulkRoutes = try [
            m1Bridge(
                between: pinPosition("source", in: nmos, transform: baseTransform),
                and: pinPosition("bulk", in: nmos, transform: baseTransform),
                width: m1Width,
                layer: m1
            ),
            m1Bridge(
                between: pinPosition("source", in: nmos, transform: secondTransform),
                and: pinPosition("bulk", in: nmos, transform: secondTransform),
                width: m1Width,
                layer: m1
            ),
        ].flatMap { $0 }

        let top = LayoutCell(
            name: "TOP",
            shapes: m2Routes.flatMap(\.shapes) + sourceBulkRoutes,
            vias: m2Routes.flatMap(\.vias),
            labels: try [("drain", "d"), ("gate", "g"), ("source", "s")].map { pinName, netName in
                let devicePin = try pin(pinName, in: nmos)
                return LayoutLabel(
                    text: netName,
                    position: baseTransform.apply(to: devicePin.position),
                    layer: devicePin.layer
                )
            },
            instances: [
                LayoutInstance(
                    cellID: nmos.id,
                    name: "XMN_ARRAY",
                    transform: baseTransform,
                    repetition: repetition
                ),
            ]
        )
        let document = LayoutDocument(name: "TOP", cells: [top, nmos], topCellID: top.id)
        let url = root.appending(path: "\(fileStem).\(fileExtension)")
        try MaskDataFormatConverter(tech: tech).exportDocument(document, to: url, format: format)
        return url
    }

    private func writeSeriesNMOSLayout(
        format: LayoutFileFormat = .gds,
        fileExtension: String = "gds",
        in root: URL
    ) throws -> URL {
        let tech = LayoutTechDatabase.sampleProcess()
        let first = try makeDeviceCell(
            deviceKindID: "nmos",
            instanceName: "M1",
            netByPin: ["drain": "d", "gate": "g", "source": "mid", "bulk": "b"],
            tech: tech
        )
        let second = try makeDeviceCell(
            deviceKindID: "nmos",
            instanceName: "M2",
            netByPin: ["drain": "mid", "gate": "g", "source": "s", "bulk": "b"],
            tech: tech
        )
        let firstPlaced = translatedCell(first, by: .zero)
        let firstBox = try boundingBox(of: firstPlaced)
        let secondBox = try boundingBox(of: second)
        let secondPlaced = translatedCell(
            second,
            by: LayoutPoint(x: 0, y: firstBox.maxY - secondBox.minY + 8.0)
        )
        let combinedBox = try boundingBox(of: LayoutCell(
            name: "SERIES_PLACEMENT",
            shapes: firstPlaced.shapes + secondPlaced.shapes
        ))

        let m1 = LayoutLayerID(name: "M1", purpose: "drawing")
        let m2 = LayoutLayerID(name: "M2", purpose: "drawing")
        let m1Width = max(tech.ruleSet(for: m1)?.minWidth ?? 0.2, 0.2)
        let m2Width = max(tech.ruleSet(for: m2)?.minWidth ?? 0.28, 0.28)
        let leftRouteX = combinedBox.minX - 2.0
        let rightRouteX = combinedBox.maxX + 2.0
        let m2Routes = try [
            m2BridgeWithVias(
                between: pin("source", in: firstPlaced).position,
                and: pin("drain", in: secondPlaced).position,
                width: m2Width,
                layer: m2,
                viaX: leftRouteX
            ),
        ]
        let gateRoutes = try m1Bridge(
            between: pin("gate", in: firstPlaced).position,
            and: pin("gate", in: secondPlaced).position,
            width: m1Width,
            layer: m1,
            viaX: rightRouteX
        )
        let bulkRoutes = try m1Bridge(
            between: pin("bulk", in: firstPlaced).position,
            and: pin("bulk", in: secondPlaced).position,
            width: m1Width,
            layer: m1,
            viaX: leftRouteX - 1.0
        )

        let top = LayoutCell(
            name: "TOP",
            shapes: firstPlaced.shapes + secondPlaced.shapes + m2Routes.flatMap(\.shapes) + gateRoutes + bulkRoutes,
            vias: firstPlaced.vias + secondPlaced.vias + m2Routes.flatMap(\.vias),
            labels: firstPlaced.labels + secondPlaced.labels
        )
        let document = LayoutDocument(name: "TOP", cells: [top], topCellID: top.id)
        let url = root.appending(path: "series-nmos.\(fileExtension)")
        try MaskDataFormatConverter(tech: tech).exportDocument(document, to: url, format: format)
        return url
    }

    private func makeDeviceCell(
        deviceKindID: String,
        instanceName: String,
        netByPin: [String: String],
        tech: LayoutTechDatabase
    ) throws -> LayoutCell {
        var cell = try MOSFETCellGenerator().generateCell(
            deviceKindID: deviceKindID,
            instanceName: instanceName,
            parameters: ["w": 2.0, "l": 0.18, "nf": 1],
            tech: tech
        )
        cell.labels = []
        for pin in cell.pins {
            guard let net = netByPin[pin.name] else { continue }
            cell.labels.append(LayoutLabel(text: net, position: pin.position, layer: pin.layer))
        }
        return cell
    }

    private func translatedCell(_ cell: LayoutCell, by delta: LayoutPoint) -> LayoutCell {
        var moved = cell
        moved.shapes = moved.shapes.map { shape in
            var movedShape = shape
            movedShape.geometry = shape.geometry.translated(by: delta)
            return movedShape
        }
        moved.vias = moved.vias.map { via in
            var movedVia = via
            movedVia.position = via.position.translated(by: delta)
            return movedVia
        }
        moved.labels = moved.labels.map { label in
            var movedLabel = label
            movedLabel.position = label.position.translated(by: delta)
            return movedLabel
        }
        moved.pins = moved.pins.map { pin in
            var movedPin = pin
            movedPin.position = pin.position.translated(by: delta)
            return movedPin
        }
        return moved
    }

    private func boundingBox(of cell: LayoutCell) throws -> LayoutRect {
        guard let first = cell.shapes.first.map({ LayoutGeometryAnalysis.boundingBox(for: $0.geometry) }) else {
            throw GeneratedLayoutFixtureError.missingBoundingBox
        }
        return cell.shapes.dropFirst().reduce(first) { partial, shape in
            partial.union(LayoutGeometryAnalysis.boundingBox(for: shape.geometry))
        }
    }

    private func pin(_ name: String, in cell: LayoutCell) throws -> LayoutPin {
        guard let pin = cell.pins.first(where: { $0.name == name }) else {
            throw GeneratedLayoutFixtureError.missingPin(name)
        }
        return pin
    }

    private func pinPosition(
        _ name: String,
        in cell: LayoutCell,
        transform: LayoutTransform
    ) throws -> LayoutPoint {
        try transform.apply(to: pin(name, in: cell).position)
    }

    private func transformedBoundingBox(
        of cell: LayoutCell,
        by transform: LayoutTransform
    ) throws -> LayoutRect {
        let box = try boundingBox(of: cell)
        let points = [
            LayoutPoint(x: box.minX, y: box.minY),
            LayoutPoint(x: box.minX, y: box.maxY),
            LayoutPoint(x: box.maxX, y: box.minY),
            LayoutPoint(x: box.maxX, y: box.maxY),
        ].map { transform.apply(to: $0) }
        guard let first = points.first else {
            throw GeneratedLayoutFixtureError.missingBoundingBox
        }
        let minX = points.dropFirst().reduce(first.x) { min($0, $1.x) }
        let minY = points.dropFirst().reduce(first.y) { min($0, $1.y) }
        let maxX = points.dropFirst().reduce(first.x) { max($0, $1.x) }
        let maxY = points.dropFirst().reduce(first.y) { max($0, $1.y) }
        return LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private func m1Bridge(
        between start: LayoutPoint,
        and end: LayoutPoint,
        width: Double,
        layer: LayoutLayerID
    ) -> [LayoutShape] {
        let corner = LayoutPoint(x: start.x, y: end.y)
        return [
            m1Segment(from: start, to: corner, width: width, layer: layer),
            m1Segment(from: corner, to: end, width: width, layer: layer),
        ].filter { shape in
            guard case .rect(let rect) = shape.geometry else { return true }
            return rect.size.width > 0 && rect.size.height > 0
        }
    }

    private func m1Bridge(
        between start: LayoutPoint,
        and end: LayoutPoint,
        width: Double,
        layer: LayoutLayerID,
        viaX: Double
    ) -> [LayoutShape] {
        let firstCorner = LayoutPoint(x: viaX, y: start.y)
        let secondCorner = LayoutPoint(x: viaX, y: end.y)
        return [
            m1Segment(from: start, to: firstCorner, width: width, layer: layer),
            m1Segment(from: firstCorner, to: secondCorner, width: width, layer: layer),
            m1Segment(from: secondCorner, to: end, width: width, layer: layer),
        ].filter { shape in
            guard case .rect(let rect) = shape.geometry else { return true }
            return rect.size.width > 0 && rect.size.height > 0
        }
    }

    private func m1Segment(
        from start: LayoutPoint,
        to end: LayoutPoint,
        width: Double,
        layer: LayoutLayerID
    ) -> LayoutShape {
        let minX = min(start.x, end.x) - width / 2
        let minY = min(start.y, end.y) - width / 2
        let segment = LayoutRect(
            origin: LayoutPoint(x: minX, y: minY),
            size: LayoutSize(
                width: abs(start.x - end.x) + width,
                height: abs(start.y - end.y) + width
            )
        )
        return LayoutShape(layer: layer, geometry: .rect(segment))
    }

    private func m2BridgeWithVias(
        between start: LayoutPoint,
        and end: LayoutPoint,
        width: Double,
        layer: LayoutLayerID
    ) -> (shapes: [LayoutShape], vias: [LayoutVia]) {
        (
            shapes: [m1Segment(from: start, to: end, width: width, layer: layer)],
            vias: [
                LayoutVia(viaDefinitionID: "VIA1", position: start),
                LayoutVia(viaDefinitionID: "VIA1", position: end),
            ]
        )
    }

    private func m2BridgeWithVias(
        between start: LayoutPoint,
        and end: LayoutPoint,
        width: Double,
        layer: LayoutLayerID,
        viaX: Double
    ) -> (shapes: [LayoutShape], vias: [LayoutVia]) {
        (
            shapes: m1Bridge(between: start, and: end, width: width, layer: layer, viaX: viaX),
            vias: [
                LayoutVia(viaDefinitionID: "VIA1", position: start),
                LayoutVia(viaDefinitionID: "VIA1", position: end),
            ]
        )
    }

    private func writeSchematic(_ text: String, in root: URL) throws -> URL {
        let url = root.appending(path: "reference.spice")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeDevicePolicySeed(
        _ seed: NetgenLVSDevicePolicySeed,
        in root: URL
    ) throws -> URL {
        let url = root.appending(path: "device-policy.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(seed).write(to: url)
        return url
    }

    @Test func matchingDevicePasses() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: try writeDeviceLayout(in: root),
            schematicNetlistURL: try writeSchematic(
                """
                .subckt top d g s b
                M1 d g s b nmos W=2u L=0.18u
                .ends
                """,
                in: root
            ),
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            workingDirectory: root
        ))

        #expect(execution.result.passed, "\(execution.result.diagnostics.map(\.message))")
        #expect(FileManager.default.fileExists(atPath: execution.result.logPath))
    }

    @Test func extraTopPortIsANonWaivableMismatch() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: try writeDeviceLayout(in: root),
            schematicNetlistURL: try writeSchematic(
                """
                .subckt top d g s b extra
                M1 d g s b nmos W=2u L=0.18u
                .ends
                """,
                in: root
            ),
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            workingDirectory: root
        ))

        #expect(!execution.result.passed)
        #expect(execution.result.verdict == .mismatch)
        #expect(execution.result.readiness == .ready)
        #expect(execution.result.diagnostics.contains {
            $0.ruleID == "LVS_PORT_MISMATCH"
                && $0.effectiveWaiverDisposition == .nonWaivable
        })
    }

    @Test func matchingPMOSDevicePasses() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: try writeDeviceLayout(deviceKindID: "pmos", in: root),
            schematicNetlistURL: try writeSchematic(
                """
                .subckt top d g s b
                M1 d g s b pmos W=2u L=0.18u
                .ends
                """,
                in: root
            ),
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            workingDirectory: root
        ))

        #expect(execution.result.passed, "\(execution.result.diagnostics.map(\.message))")
    }

    @Test func matchingDevicePassesFromAutoDetectedOASIS() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: try writeDeviceLayout(format: .oasis, fileExtension: "oas", in: root),
            schematicNetlistURL: try writeSchematic(
                """
                .subckt top d g s b
                M1 d g s b nmos W=2u L=0.18u
                .ends
                """,
                in: root
            ),
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            workingDirectory: root
        ))

        #expect(execution.result.passed, "\(execution.result.diagnostics.map(\.message))")
    }

    @Test func matchingGeneratedInverterPasses() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: try writeInverterLayout(in: root),
            schematicNetlistURL: try writeSchematic(
                """
                .subckt top in out vdd vss
                M1 out in vdd vdd pmos W=2u L=0.18u
                M2 out in vss vss nmos W=2u L=0.18u
                .ends
                """,
                in: root
            ),
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            workingDirectory: root
        ))

        #expect(execution.result.passed, "\(execution.result.diagnostics.map(\.message))")
    }

    @Test func matchingHierarchicalGeneratedInverterPasses() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: try writeHierarchicalInverterLayout(in: root),
            schematicNetlistURL: try writeSchematic(
                """
                .subckt top in out vdd vss
                M1 out in vdd vdd pmos W=2u L=0.18u
                M2 out in vss vss nmos W=2u L=0.18u
                .ends
                """,
                in: root
            ),
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            workingDirectory: root
        ))

        #expect(execution.result.passed, "\(execution.result.diagnostics.map(\.message))")
        let extractionReportURL = try #require(execution.extractionReportURL)
        let extraction = try JSONDecoder().decode(
            LayoutExtractionIR.self,
            from: Data(contentsOf: extractionReportURL)
        )
        #expect(extraction.ports.map(\.name).sorted() == ["in", "out", "vdd", "vss"])
        #expect(!extraction.ports.contains { $0.name == "INTERNAL_ONLY" })
    }

    @Test func matchingArrayedParallelNMOSPasses() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: try writeArrayedParallelNMOSLayout(in: root),
            schematicNetlistURL: try writeSchematic(
                """
                .subckt top d g s
                M1 d g s s nmos W=2u L=0.18u M=2
                .ends
                """,
                in: root
            ),
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            workingDirectory: root
        ))

        #expect(execution.result.passed, "\(execution.result.diagnostics.map(\.message))")
    }

    @Test func matchingArrayedParallelNMOSPassesFromAutoDetectedOASIS() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: try writeArrayedParallelNMOSLayout(format: .oasis, fileExtension: "oas", in: root),
            schematicNetlistURL: try writeSchematic(
                """
                .subckt top d g s
                M1 d g s s nmos W=2u L=0.18u M=2
                .ends
                """,
                in: root
            ),
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            workingDirectory: root
        ))

        #expect(execution.result.passed, "\(execution.result.diagnostics.map(\.message))")
    }

    @Test func matchingHorizontalArrayedParallelNMOSPasses() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: try writeArrayedParallelNMOSLayout(orientation: .horizontalColumns, in: root),
            schematicNetlistURL: try writeSchematic(
                """
                .subckt top d g s
                M1 d g s s nmos W=2u L=0.18u M=2
                .ends
                """,
                in: root
            ),
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            workingDirectory: root
        ))

        #expect(execution.result.passed, "\(execution.result.diagnostics.map(\.message))")
    }

    @Test func matchingHorizontalArrayedParallelNMOSPassesFromAutoDetectedOASIS() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: try writeArrayedParallelNMOSLayout(
                orientation: .horizontalColumns,
                format: .oasis,
                fileExtension: "oas",
                in: root
            ),
            schematicNetlistURL: try writeSchematic(
                """
                .subckt top d g s
                M1 d g s s nmos W=2u L=0.18u M=2
                .ends
                """,
                in: root
            ),
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            workingDirectory: root
        ))

        #expect(execution.result.passed, "\(execution.result.diagnostics.map(\.message))")
    }

    @Test func devicePolicyParallelAppliesAfterNativeGDSExtraction() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let layoutURL = try writeArrayedParallelNMOSLayout(in: root)
        let schematicURL = try writeSchematic(
            """
            .subckt top d g s
            M1 d g s s nmos W=4u L=0.18u
            .ends
            """,
            in: root
        )

        let seedWithoutBlackbox = NetgenLVSDevicePolicySeed(
            generatedAt: "2026-06-24T00:00:00Z",
            sourcePath: "sky130A_setup.tcl",
            devices: [],
            policyRules: []
        )
        let seedWithoutBlackboxURL = try writeDevicePolicySeed(seedWithoutBlackbox, in: root)
        let failingExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: seedWithoutBlackboxURL,
            workingDirectory: root
        ))
        #expect(!failingExecution.result.passed)
        #expect(failingExecution.result.diagnostics.contains { $0.severity == .error })

        let policyURL = try writeDevicePolicySeed(
            NetgenLVSDevicePolicySeed(
                generatedAt: "2026-06-24T00:00:00Z",
                sourcePath: "sky130A_setup.tcl",
                devices: [
                    NetgenLVSDeviceDescriptor(
                        deviceName: "nmos",
                        family: "mos",
                        sourceLineNumber: 1,
                        sourceLine: "lappend devices nmos"
                    )
                ],
                policyRules: [
                    NetgenLVSPolicyRule(
                        kind: "property",
                        arguments: ["-circuit1 nmos", "parallel", "enable"],
                        sourceLineNumber: 2,
                        sourceLine: "property \"-circuit1 nmos\" parallel enable"
                    ),
                    NetgenLVSPolicyRule(
                        kind: "property",
                        arguments: ["-circuit1 nmos", "parallel", "{l critical}"],
                        sourceLineNumber: 3,
                        sourceLine: "property \"-circuit1 nmos\" parallel {l critical}"
                    ),
                    NetgenLVSPolicyRule(
                        kind: "property",
                        arguments: ["-circuit1 nmos", "parallel", "{w add}"],
                        sourceLineNumber: 4,
                        sourceLine: "property \"-circuit1 nmos\" parallel {w add}"
                    ),
                ]
            ),
            in: root
        )

        let policyExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: policyURL,
            workingDirectory: root
        ))

        #expect(policyExecution.result.passed, "\(policyExecution.result.diagnostics.map(\.message))")
        #expect(policyExecution.result.backendID == "native-gds")
        let extractedNetlistURL = try #require(policyExecution.extractedLayoutNetlistURL)
        #expect(FileManager.default.fileExists(atPath: extractedNetlistURL.path(percentEncoded: false)))
        let report = try #require(policyExecution.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 3)
        #expect(report.ignoredRuleCount == 0)
        #expect(report.appliedRules.contains {
            $0.kind == "property-parallel" && $0.propertyMode == "enable"
        })
        #expect(report.appliedRules.contains {
            $0.kind == "property-parallel" && $0.parameterRoles == ["l": "critical"]
        })
        #expect(report.appliedRules.contains {
            $0.kind == "property-parallel" && $0.parameterRoles == ["w": "add"]
        })
    }

    @Test func policyAwareExtractionPreservesPDKDimensionlessMicronConvention() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let layoutURL = try writeDeviceLayout(in: root)
        let schematicURL = try writeSchematic(
            """
            .subckt top d g s b
            M1 d g s b nmos W=2000000u L=180000u
            .ends
            """,
            in: root
        )
        let policyURL = try writeDevicePolicySeed(
            NetgenLVSDevicePolicySeed(
                generatedAt: "2026-07-12T00:00:00Z",
                sourcePath: "foundry-setup.tcl",
                devices: [
                    NetgenLVSDeviceDescriptor(
                        deviceName: "nmos",
                        family: "mos",
                        sourceLineNumber: 1,
                        sourceLine: "lappend devices nmos"
                    )
                ],
                policyRules: [
                    NetgenLVSPolicyRule(
                        kind: "property",
                        arguments: ["-circuit1 nmos", "delete", "mult"],
                        sourceLineNumber: 2,
                        sourceLine: "property \"-circuit1 nmos\" delete mult"
                    )
                ]
            ),
            in: root
        )

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: policyURL,
            workingDirectory: root
        ))

        #expect(execution.result.passed, "\(execution.result.diagnostics.map(\.message))")
        let extractedURL = try #require(execution.extractedLayoutNetlistURL)
        let extracted = try String(contentsOf: extractedURL, encoding: .utf8)
        #expect(extracted.contains("W=2 L=0.18"))
        #expect(!extracted.contains("W=2u"))
        #expect(execution.devicePolicyReport?.status == .complete)
    }

    @Test func devicePolicySeriesAppliesAfterNativeGDSExtraction() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let layoutURL = try writeSeriesNMOSLayout(in: root)
        let schematicURL = try writeSchematic(
            """
            .subckt top d g s b
            M1 d g s b nmos W=2u L=0.36u
            .ends
            """,
            in: root
        )

        let seedWithoutBlackbox = NetgenLVSDevicePolicySeed(
            generatedAt: "2026-06-24T00:00:00Z",
            sourcePath: "sky130A_setup.tcl",
            devices: [],
            policyRules: []
        )
        let seedWithoutBlackboxURL = try writeDevicePolicySeed(seedWithoutBlackbox, in: root)
        let failingExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: seedWithoutBlackboxURL,
            workingDirectory: root
        ))
        #expect(!failingExecution.result.passed)
        #expect(failingExecution.result.diagnostics.contains { $0.severity == .error })

        let policyURL = try writeDevicePolicySeed(
            NetgenLVSDevicePolicySeed(
                generatedAt: "2026-06-24T00:00:00Z",
                sourcePath: "sky130A_setup.tcl",
                devices: [
                    NetgenLVSDeviceDescriptor(
                        deviceName: "nmos",
                        family: "mos",
                        sourceLineNumber: 1,
                        sourceLine: "lappend devices nmos"
                    )
                ],
                policyRules: [
                    NetgenLVSPolicyRule(
                        kind: "property",
                        arguments: ["-circuit1 nmos", "series", "enable"],
                        sourceLineNumber: 2,
                        sourceLine: "property \"-circuit1 nmos\" series enable"
                    ),
                    NetgenLVSPolicyRule(
                        kind: "property",
                        arguments: ["-circuit1 nmos", "series", "{w critical}"],
                        sourceLineNumber: 3,
                        sourceLine: "property \"-circuit1 nmos\" series {w critical}"
                    ),
                    NetgenLVSPolicyRule(
                        kind: "property",
                        arguments: ["-circuit1 nmos", "series", "{l add}"],
                        sourceLineNumber: 4,
                        sourceLine: "property \"-circuit1 nmos\" series {l add}"
                    ),
                ]
            ),
            in: root
        )

        let policyExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: policyURL,
            workingDirectory: root
        ))

        #expect(policyExecution.result.passed, "\(policyExecution.result.diagnostics.map(\.message))")
        #expect(policyExecution.result.backendID == "native-gds")
        let extractedNetlistURL = try #require(policyExecution.extractedLayoutNetlistURL)
        #expect(FileManager.default.fileExists(atPath: extractedNetlistURL.path(percentEncoded: false)))
        let report = try #require(policyExecution.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 3)
        #expect(report.ignoredRuleCount == 0)
        #expect(report.appliedRules.contains {
            $0.kind == "property-series" && $0.propertyMode == "enable"
        })
        #expect(report.appliedRules.contains {
            $0.kind == "property-series" && $0.parameterRoles == ["w": "critical"]
        })
        #expect(report.appliedRules.contains {
            $0.kind == "property-series" && $0.parameterRoles == ["l": "add"]
        })
    }

    @Test func devicePolicyEquatePinsAppliesAfterNativeGDSExtraction() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let layoutURL = try writeDeviceLayout(in: root)
        let schematicURL = try writeSchematic(
            """
            .subckt top d g s b
            M1 d g s b nmos_alias W=2u L=0.18u
            .ends
            """,
            in: root
        )

        let seedWithoutEquate = NetgenLVSDevicePolicySeed(
            generatedAt: "2026-06-24T00:00:00Z",
            sourcePath: "sky130A_setup.tcl",
            devices: [
                NetgenLVSDeviceDescriptor(
                    deviceName: "nmos",
                    family: "mos",
                    sourceLineNumber: 1,
                    sourceLine: "lappend devices nmos"
                ),
                NetgenLVSDeviceDescriptor(
                    deviceName: "nmos_alias",
                    family: "mos",
                    sourceLineNumber: 2,
                    sourceLine: "lappend devices nmos_alias"
                ),
            ],
            policyRules: []
        )
        let seedWithoutEquateURL = try writeDevicePolicySeed(seedWithoutEquate, in: root)
        let failingExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: seedWithoutEquateURL,
            workingDirectory: root
        ))
        #expect(!failingExecution.result.passed)
        #expect(failingExecution.result.diagnostics.contains { $0.ruleID == "LVS_MODEL_MISMATCH" })

        let policyURL = try writeDevicePolicySeed(
            NetgenLVSDevicePolicySeed(
                generatedAt: "2026-06-24T00:00:00Z",
                sourcePath: "sky130A_setup.tcl",
                devices: seedWithoutEquate.devices,
                policyRules: [
                    NetgenLVSPolicyRule(
                        kind: "equate-pins",
                        arguments: ["pins", "-circuit1 nmos", "-circuit2 nmos_alias"],
                        sourceLineNumber: 3,
                        sourceLine: "equate pins \"-circuit1 nmos\" \"-circuit2 nmos_alias\""
                    )
                ]
            ),
            in: root
        )

        let policyExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: policyURL,
            workingDirectory: root
        ))

        #expect(policyExecution.result.passed, "\(policyExecution.result.diagnostics.map(\.message))")
        #expect(policyExecution.result.backendID == "native-gds")
        let extractedNetlistURL = try #require(policyExecution.extractedLayoutNetlistURL)
        #expect(FileManager.default.fileExists(atPath: extractedNetlistURL.path(percentEncoded: false)))
        let report = try #require(policyExecution.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 1)
        #expect(report.ignoredRuleCount == 0)
        #expect(report.appliedRules.contains {
            $0.kind == "equate-pins"
                && $0.model == "nmos"
                && $0.pairedModel == "nmos_alias"
                && $0.propertyMode == "pin-order"
        })
    }

    @Test func devicePolicyPropertyBlackboxAppliesAfterNativeGDSExtraction() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let layoutURL = try writeDeviceLayout(in: root)
        let schematicURL = try writeSchematic(
            """
            .subckt top d g s b
            M1 d g s b nmos W=9u L=9u
            .ends
            """,
            in: root
        )

        let seedWithoutBlackbox = NetgenLVSDevicePolicySeed(
            generatedAt: "2026-06-24T00:00:00Z",
            sourcePath: "sky130A_setup.tcl",
            devices: [
                NetgenLVSDeviceDescriptor(
                    deviceName: "nmos",
                    family: "mos",
                    sourceLineNumber: 1,
                    sourceLine: "lappend devices nmos"
                )
            ],
            policyRules: []
        )
        let seedWithoutBlackboxURL = try writeDevicePolicySeed(seedWithoutBlackbox, in: root)
        let failingExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: seedWithoutBlackboxURL,
            workingDirectory: root
        ))
        #expect(!failingExecution.result.passed)
        #expect(failingExecution.result.diagnostics.contains { $0.ruleID == "LVS_PARAMETER_MISMATCH" })

        let policyURL = try writeDevicePolicySeed(
            NetgenLVSDevicePolicySeed(
                generatedAt: "2026-06-24T00:00:00Z",
                sourcePath: "sky130A_setup.tcl",
                devices: seedWithoutBlackbox.devices,
                policyRules: [
                    NetgenLVSPolicyRule(
                        kind: "property",
                        arguments: ["-circuit1 nmos", "blackbox"],
                        sourceLineNumber: 2,
                        sourceLine: "property \"-circuit1 nmos\" blackbox"
                    )
                ]
            ),
            in: root
        )

        let policyExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: policyURL,
            workingDirectory: root
        ))

        #expect(policyExecution.result.passed, "\(policyExecution.result.diagnostics.map(\.message))")
        #expect(policyExecution.result.backendID == "native-gds")
        let extractedNetlistURL = try #require(policyExecution.extractedLayoutNetlistURL)
        #expect(FileManager.default.fileExists(atPath: extractedNetlistURL.path(percentEncoded: false)))
        let report = try #require(policyExecution.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 1)
        #expect(report.ignoredRuleCount == 0)
        let appliedRule = try #require(report.appliedRules.first)
        #expect(appliedRule.kind == "property-blackbox")
        #expect(appliedRule.model == "nmos")
        #expect(appliedRule.propertyMode == "blackbox")
    }

    @Test func devicePolicyModelBlackboxPreservesNativeGDSInstanceBoundary() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let layoutURL = try writeBlackboxMacroLayout(in: root)
        let schematicURL = try writeSchematic(
            """
            .subckt top d g s b
            XU1 d g s b hard_macro gain=9
            .ends

            .subckt hard_macro d g s b
            M1 d g s b nmos W=9u L=9u
            .ends
            """,
            in: root
        )

        let seedWithoutBlackbox = NetgenLVSDevicePolicySeed(
            generatedAt: "2026-06-24T00:00:00Z",
            sourcePath: "sky130A_setup.tcl",
            devices: [],
            policyRules: []
        )
        let seedWithoutBlackboxURL = try writeDevicePolicySeed(seedWithoutBlackbox, in: root)
        let failingExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: seedWithoutBlackboxURL,
            workingDirectory: root
        ))
        #expect(!failingExecution.result.passed)
        #expect(failingExecution.result.diagnostics.contains { $0.severity == .error })

        let policyURL = try writeDevicePolicySeed(
            NetgenLVSDevicePolicySeed(
                generatedAt: "2026-06-24T00:00:00Z",
                sourcePath: "sky130A_setup.tcl",
                devices: [],
                policyRules: [
                    NetgenLVSPolicyRule(
                        kind: "blackbox",
                        arguments: ["model", "blackbox", "hard_macro"],
                        sourceLineNumber: 2,
                        sourceLine: "model blackbox hard_macro"
                    )
                ]
            ),
            in: root
        )

        let policyExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: policyURL,
            workingDirectory: root
        ))

        #expect(policyExecution.result.passed, "\(policyExecution.result.diagnostics.map(\.message))")
        #expect(policyExecution.result.backendID == "native-gds")
        let extractedNetlistURL = try #require(policyExecution.extractedLayoutNetlistURL)
        let extractedNetlist = try String(contentsOf: extractedNetlistURL, encoding: .utf8)
        #expect(extractedNetlist.contains(" d g s b hard_macro"))
        #expect(extractedNetlist.contains(".subckt hard_macro d g s b"))
        let report = try #require(policyExecution.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 1)
        #expect(report.ignoredRuleCount == 0)
        let appliedRule = try #require(report.appliedRules.first)
        #expect(appliedRule.kind == "blackbox")
        #expect(appliedRule.model == "hard_macro")
        #expect(appliedRule.propertyMode == "blackbox")
    }

    @Test func devicePolicyRuntimeCellBlackboxPreservesNativeGDSInstanceBoundary() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let layoutURL = try writeBlackboxMacroLayout(in: root)
        let schematicURL = try writeSchematic(
            """
            .subckt top d g s b
            XU1 d g s b hard_macro gain=9
            .ends

            .subckt hard_macro d g s b
            M1 d g s b nmos W=9u L=9u
            .ends
            """,
            in: root
        )
        let policyURL = try writeDevicePolicySeed(
            NetgenLVSDevicePolicySeed(
                generatedAt: "2026-06-24T00:00:00Z",
                sourcePath: "sky130A_setup.tcl",
                devices: [],
                policyRules: [
                    NetgenLVSPolicyRule(
                        kind: "property",
                        arguments: ["-circuit1 $cell", "blackbox"],
                        sourceLineNumber: 12,
                        sourceLine: "property \"-circuit1 $cell\" blackbox"
                    )
                ]
            ),
            in: root
        )

        let policyExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: policyURL,
            workingDirectory: root
        ))

        #expect(policyExecution.result.passed, "\(policyExecution.result.diagnostics.map(\.message))")
        #expect(policyExecution.result.backendID == "native-gds")
        let extractedNetlistURL = try #require(policyExecution.extractedLayoutNetlistURL)
        let extractedNetlist = try String(contentsOf: extractedNetlistURL, encoding: .utf8)
        #expect(extractedNetlist.contains(" d g s b hard_macro"))
        #expect(extractedNetlist.contains(".subckt hard_macro d g s b"))
        let report = try #require(policyExecution.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 1)
        #expect(report.ignoredRuleCount == 0)
        let appliedRule = try #require(report.appliedRules.first)
        #expect(appliedRule.kind == "property-blackbox")
        #expect(appliedRule.model == "hard_macro")
        #expect(appliedRule.family == "cell")
        #expect(appliedRule.propertyMode == "blackbox")
    }

    @Test func devicePolicyRuntimeCellBlackboxCoexistsWithExtractedNativeGDSDevices() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let layoutURL = try writeMixedBlackboxMacroAndDeviceLayout(in: root)
        let schematicURL = try writeSchematic(
            """
            .subckt top d g s b dn gn sn bn
            XU1 d g s b hard_macro gain=9
            M2 dn gn sn bn nmos W=2u L=0.18u
            .ends

            .subckt hard_macro d g s b
            M1 d g s b nmos W=9u L=9u
            .ends
            """,
            in: root
        )
        let policyURL = try writeDevicePolicySeed(
            NetgenLVSDevicePolicySeed(
                generatedAt: "2026-06-24T00:00:00Z",
                sourcePath: "sky130A_setup.tcl",
                devices: [],
                policyRules: [
                    NetgenLVSPolicyRule(
                        kind: "property",
                        arguments: ["-circuit1 $cell", "blackbox"],
                        sourceLineNumber: 12,
                        sourceLine: "property \"-circuit1 $cell\" blackbox"
                    )
                ]
            ),
            in: root
        )

        let policyExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: policyURL,
            workingDirectory: root
        ))

        #expect(policyExecution.result.passed, "\(policyExecution.result.diagnostics.map(\.message))")
        #expect(policyExecution.result.backendID == "native-gds")
        let extractedNetlistURL = try #require(policyExecution.extractedLayoutNetlistURL)
        let extractedNetlist = try String(contentsOf: extractedNetlistURL, encoding: .utf8)
        #expect(extractedNetlist.contains(" d g s b hard_macro"))
        #expect(extractedNetlist.contains(".subckt hard_macro d g s b"))
        #expect(extractedNetlist.contains(" nmos W=2u L=0.18u"))
        #expect(extractedNetlist.components(separatedBy: " nmos W=").count - 1 == 1)
        let report = try #require(policyExecution.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 1)
        #expect(report.ignoredRuleCount == 0)
        let appliedRule = try #require(report.appliedRules.first)
        #expect(appliedRule.kind == "property-blackbox")
        #expect(appliedRule.model == "hard_macro")
        #expect(appliedRule.family == "cell")
        #expect(appliedRule.propertyMode == "blackbox")
    }

    @Test func wrongDeviceKindFails() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: try writeDeviceLayout(in: root),
            schematicNetlistURL: try writeSchematic(
                """
                .subckt top d g s b
                M1 d g s b pmos W=2u L=0.18u
                .ends
                """,
                in: root
            ),
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root)
        ))

        #expect(!execution.result.passed)
        #expect(execution.result.diagnostics.contains { $0.ruleID == "LVS_DEVICE_SEMANTICS_MISMATCH" })
    }

    @Test func wrongParametersFail() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let execution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: try writeDeviceLayout(in: root),
            schematicNetlistURL: try writeSchematic(
                """
                .subckt top d g s b
                M1 d g s b nmos W=4u L=0.18u
                .ends
                """,
                in: root
            ),
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root)
        ))

        #expect(!execution.result.passed)
        #expect(execution.result.diagnostics.contains { $0.ruleID == "LVS_PARAMETER_MISMATCH" })
    }

    @Test func devicePolicyToleranceAppliesAfterNativeGDSExtraction() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let layoutURL = try writeDeviceLayout(in: root)
        let schematicURL = try writeSchematic(
            """
            .subckt top pin_d pin_g pin_s pin_b
            M1 pin_d pin_g pin_s pin_b nmos W=2.01u L=0.18u
            .ends
            """,
            in: root
        )
        let defaultExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            workingDirectory: root
        ))
        #expect(!defaultExecution.result.passed)
        #expect(defaultExecution.result.diagnostics.contains { $0.severity == .error })

        let policyURL = try writeDevicePolicySeed(
            NetgenLVSDevicePolicySeed(
                generatedAt: "2026-06-24T00:00:00Z",
                sourcePath: "sky130A_setup.tcl",
                devices: [
                    NetgenLVSDeviceDescriptor(
                        deviceName: "nmos",
                        family: "mos",
                        sourceLineNumber: 1,
                        sourceLine: "lappend devices nmos"
                    )
                ],
                policyRules: [
                    NetgenLVSPolicyRule(
                        kind: "property",
                        arguments: ["-circuit1 nmos", "tolerance", "{w 0.01}"],
                        sourceLineNumber: 2,
                        sourceLine: "property \"-circuit1 nmos\" tolerance {w 0.01}"
                    )
                ]
            ),
            in: root
        )

        let policyExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: policyURL,
            workingDirectory: root
        ))

        #expect(policyExecution.result.passed, "\(policyExecution.result.diagnostics.map(\.message))")
        #expect(policyExecution.result.backendID == "native-gds")
        let extractedNetlistURL = try #require(policyExecution.extractedLayoutNetlistURL)
        #expect(FileManager.default.fileExists(atPath: extractedNetlistURL.path(percentEncoded: false)))
        let report = try #require(policyExecution.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 1)
        #expect(report.ignoredRuleCount == 0)
        let appliedRule = try #require(report.appliedRules.first)
        #expect(appliedRule.kind == "property-tolerance")
        #expect(appliedRule.model == "nmos")
        let widthTolerance = try #require(appliedRule.parameterTolerances?["w"])
        #expect(abs(widthTolerance - 0.01) < 1e-18)
    }

    @Test func devicePolicyDeleteAppliesAfterNativeGDSExtraction() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let layoutURL = try writeDeviceLayout(in: root)
        let schematicURL = try writeSchematic(
            """
            .subckt top pin_d pin_g pin_s pin_b
            M1 pin_d pin_g pin_s pin_b nmos W=2u L=0.18u AD=1 AS=1
            .ends
            """,
            in: root
        )
        let seedWithoutDelete = NetgenLVSDevicePolicySeed(
            generatedAt: "2026-06-24T00:00:00Z",
            sourcePath: "sky130A_setup.tcl",
            devices: [
                NetgenLVSDeviceDescriptor(
                    deviceName: "nmos",
                    family: "mos",
                    sourceLineNumber: 1,
                    sourceLine: "lappend devices nmos"
                )
            ],
            policyRules: []
        )
        let seedWithoutDeleteURL = try writeDevicePolicySeed(seedWithoutDelete, in: root)

        let failingExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: seedWithoutDeleteURL,
            workingDirectory: root
        ))
        #expect(!failingExecution.result.passed)
        #expect(failingExecution.result.diagnostics.contains { $0.severity == .error })

        let seedWithDelete = NetgenLVSDevicePolicySeed(
            generatedAt: "2026-06-24T00:00:00Z",
            sourcePath: "sky130A_setup.tcl",
            devices: seedWithoutDelete.devices,
            policyRules: [
                NetgenLVSPolicyRule(
                    kind: "property",
                    arguments: ["-circuit1 nmos", "delete", "ad", "as"],
                    sourceLineNumber: 2,
                    sourceLine: "property \"-circuit1 nmos\" delete ad as"
                )
            ]
        )
        let seedWithDeleteURL = try writeDevicePolicySeed(seedWithDelete, in: root)

        let policyExecution = try await LayoutGDSLVSBackend().run(LVSRequest(
            layoutGDSURL: layoutURL,
            schematicNetlistURL: schematicURL,
            topCell: "TOP",
            technologyURL: try writeTech(in: root),
            extractionProfileURL: try writeExtractionProfile(in: root),
            extractionDeckURL: try writeExtractionDeck(in: root),
            devicePolicyURL: seedWithDeleteURL,
            workingDirectory: root
        ))

        #expect(policyExecution.result.passed, "\(policyExecution.result.diagnostics.map(\.message))")
        let extractedNetlistURL = try #require(policyExecution.extractedLayoutNetlistURL)
        #expect(FileManager.default.fileExists(atPath: extractedNetlistURL.path(percentEncoded: false)))
        let report = try #require(policyExecution.devicePolicyReport)
        #expect(report.status == .complete)
        #expect(report.appliedRuleCount == 1)
        #expect(report.ignoredRuleCount == 0)
        let appliedRule = try #require(report.appliedRules.first)
        #expect(appliedRule.kind == "property-delete")
        #expect(appliedRule.model == "nmos")
        #expect(appliedRule.parameterNames == ["ad", "as"])
    }

    @Test func policyAwareComparisonRejectsMissingSchematicTopCell() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        let layoutURL = try writeDeviceLayout(in: root)
        let schematicURL = try writeSchematic(
            """
            .subckt unrelated d g s b
            M1 d g s b nmos W=2u L=0.18u
            .ends
            """,
            in: root
        )
        let policyURL = try writeDevicePolicySeed(
            NetgenLVSDevicePolicySeed(
                generatedAt: "2026-06-24T00:00:00Z",
                sourcePath: "sky130A_setup.tcl",
                devices: [],
                policyRules: []
            ),
            in: root
        )

        do {
            _ = try await LayoutGDSLVSBackend().run(LVSRequest(
                layoutGDSURL: layoutURL,
                schematicNetlistURL: schematicURL,
                topCell: "TOP",
                technologyURL: try writeTech(in: root),
                extractionProfileURL: try writeExtractionProfile(in: root),
                extractionDeckURL: try writeExtractionDeck(in: root),
                devicePolicyURL: policyURL,
                workingDirectory: root
            ))
            Issue.record("Expected policy-aware LVS to reject a missing schematic top cell.")
        } catch let error as LVSError {
            guard case .invalidInput(let message) = error else {
                Issue.record("Expected invalid input error, got \(error).")
                return
            }
            #expect(message.contains("TOP"))
            #expect(message.contains("unrelated"))
        } catch {
            Issue.record("Expected LVS error, got \(error).")
        }
    }

    @Test func missingTechnologyIsInvalidInput() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        await #expect(throws: LVSError.self) {
            _ = try await LayoutGDSLVSBackend().run(LVSRequest(
                layoutGDSURL: try writeDeviceLayout(in: root),
                schematicNetlistURL: try writeSchematic(".subckt top\n.ends", in: root),
                topCell: "TOP"
            ))
        }
    }

    @Test func missingExtractionProfileFailsClosed() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }

        await #expect(throws: LayoutExtractionProcessProfileError.missingProfileArtifact(
            path: "LVSRequest.extractionProfileURL"
        )) {
            _ = try await LayoutGDSLVSBackend().run(LVSRequest(
                layoutGDSURL: try writeDeviceLayout(in: root),
                schematicNetlistURL: try writeSchematic(".subckt top\n.ends", in: root),
                topCell: "TOP",
                technologyURL: try writeTech(in: root)
            ))
        }
    }

    @Test func extractionDeckDigestMismatchFailsClosed() async throws {
        let root = try makeRoot()
        defer { removeTemporaryDirectory(root) }
        let profileURL = try writeExtractionProfile(in: root)
        let deckURL = try writeExtractionDeck(in: root)
        try Data("modified-process-deck".utf8).write(to: deckURL, options: [.atomic])

        await #expect(throws: LayoutExtractionProcessProfileError.self) {
            _ = try await LayoutGDSLVSBackend().run(LVSRequest(
                layoutGDSURL: try writeDeviceLayout(in: root),
                schematicNetlistURL: try writeSchematic(".subckt top\n.ends", in: root),
                topCell: "TOP",
                technologyURL: try writeTech(in: root),
                extractionProfileURL: profileURL,
                extractionDeckURL: deckURL
            ))
        }
    }

    private func removeTemporaryDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove temporary directory: \(error.localizedDescription)")
        }
    }
}
