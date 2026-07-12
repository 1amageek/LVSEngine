import Foundation

public struct LVSArtifactSaveResult: Sendable, Hashable {
    public let reportURL: URL
    public let manifestURL: URL
    public let correspondenceURL: URL?

    public init(
        reportURL: URL,
        manifestURL: URL,
        correspondenceURL: URL? = nil
    ) {
        self.reportURL = reportURL
        self.manifestURL = manifestURL
        self.correspondenceURL = correspondenceURL
    }
}
