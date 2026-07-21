import CircuiteFoundation
import Foundation

public struct LVSLayoutNetlistExtractionResult: Sendable, Hashable, Codable {
    public let netlist: ArtifactReference
    public let provenance: ExecutionProvenance

    public init(
        netlist: ArtifactReference,
        provenance: ExecutionProvenance
    ) {
        self.netlist = netlist
        self.provenance = provenance
    }

    public func netlistFileURL() throws -> URL {
        try netlist.locator.location.resolvedFileURL()
    }
}
