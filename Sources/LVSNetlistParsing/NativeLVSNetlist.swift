import Foundation
import LVSCore

public struct NativeLVSNetlist: Sendable, Hashable, Codable {
    public let topCell: String
    public let ports: [String]
    public let globalNets: [String]
    public let runtimeCellModels: [String]
    public let components: [NativeLVSNetlistComponent]

    public init(
        topCell: String,
        ports: [String],
        globalNets: [String] = [],
        runtimeCellModels: [String] = [],
        components: [NativeLVSNetlistComponent]
    ) {
        self.topCell = topCell
        self.ports = ports
        self.globalNets = globalNets
        self.runtimeCellModels = runtimeCellModels
        self.components = components
    }

    private enum CodingKeys: String, CodingKey {
        case topCell
        case ports
        case globalNets
        case runtimeCellModels
        case components
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.topCell = try container.decode(String.self, forKey: .topCell)
        self.ports = try container.decode([String].self, forKey: .ports)
        self.globalNets = try container.decode([String].self, forKey: .globalNets)
        self.runtimeCellModels = try container.decode([String].self, forKey: .runtimeCellModels)
        self.components = try container.decode([NativeLVSNetlistComponent].self, forKey: .components)
    }
}
