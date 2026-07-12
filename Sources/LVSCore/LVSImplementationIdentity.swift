import Foundation

public struct LVSImplementationIdentity: Sendable, Hashable, Codable {
    public let implementationID: String
    public let binaryDigest: String
    public let algorithmVersion: String
    public let processProfileID: String
    public let deckDigest: String

    public init(
        implementationID: String,
        binaryDigest: String,
        algorithmVersion: String,
        processProfileID: String,
        deckDigest: String
    ) {
        self.implementationID = implementationID
        self.binaryDigest = binaryDigest
        self.algorithmVersion = algorithmVersion
        self.processProfileID = processProfileID
        self.deckDigest = deckDigest
    }

    public var isComplete: Bool {
        [
            implementationID,
            binaryDigest,
            algorithmVersion,
            processProfileID,
            deckDigest,
        ].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public func isIndependent(from other: LVSImplementationIdentity) -> Bool {
        isComplete
            && other.isComplete
            && implementationID != other.implementationID
            && (binaryDigest != other.binaryDigest || algorithmVersion != other.algorithmVersion)
    }
}
