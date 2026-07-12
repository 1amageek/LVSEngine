public struct LVSCorpusCaseProvenance: Sendable, Hashable, Codable {
    public let backendID: String
    public let inputArtifacts: [LVSArtifactRecord]
    public let outputArtifacts: [LVSArtifactRecord]
    public let reportPath: String?
    public let manifestPath: String?
    public let extractedLayoutNetlistPath: String?
    public let implementationIdentity: LVSImplementationIdentity?

    public init(
        backendID: String,
        inputArtifacts: [LVSArtifactRecord] = [],
        outputArtifacts: [LVSArtifactRecord] = [],
        reportPath: String?,
        manifestPath: String?,
        extractedLayoutNetlistPath: String?,
        implementationIdentity: LVSImplementationIdentity? = nil
    ) {
        self.backendID = backendID
        self.inputArtifacts = inputArtifacts
        self.outputArtifacts = outputArtifacts
        self.reportPath = reportPath
        self.manifestPath = manifestPath
        self.extractedLayoutNetlistPath = extractedLayoutNetlistPath
        self.implementationIdentity = implementationIdentity
    }
}
