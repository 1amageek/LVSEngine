import Foundation
import LVSNetlistParsing
import Testing

@Suite("Native LVS netlist contract")
struct NativeLVSNetlistContractTests {
    @Test func decoderRejectsMissingCanonicalCollections() {
        let data = Data("""
        {
          "topCell": "inv",
          "ports": ["in", "out"],
          "components": []
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(NativeLVSNetlist.self, from: data)
        }
    }
}
