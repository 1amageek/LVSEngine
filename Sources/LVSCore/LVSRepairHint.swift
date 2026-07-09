public struct LVSRepairHint: Codable, Sendable, Hashable {
    public let hintID: String
    public let sourceDiagnosticIndex: Int
    public let operationID: String
    public let confidence: String
    public let ruleID: String?
    public let category: String?
    public let componentSignature: String?
    public let parameterName: String?
    public let layoutModel: String?
    public let schematicModel: String?
    public let layoutValue: String?
    public let schematicValue: String?
    public let layoutPorts: [String]
    public let schematicPorts: [String]
    public let layoutCount: Int?
    public let schematicCount: Int?
    public let numericParameters: [String: Double]?
    public let stringParameters: [String: String]
    public let verificationGates: [String]
    public let rationale: String

    public init(
        hintID: String,
        sourceDiagnosticIndex: Int,
        operationID: String,
        confidence: String,
        ruleID: String?,
        category: String?,
        componentSignature: String?,
        parameterName: String?,
        layoutModel: String?,
        schematicModel: String?,
        layoutValue: String?,
        schematicValue: String?,
        layoutPorts: [String],
        schematicPorts: [String],
        layoutCount: Int?,
        schematicCount: Int?,
        stringParameters: [String: String],
        verificationGates: [String],
        rationale: String,
        numericParameters: [String: Double]? = nil
    ) {
        self.hintID = hintID
        self.sourceDiagnosticIndex = sourceDiagnosticIndex
        self.operationID = operationID
        self.confidence = confidence
        self.ruleID = ruleID
        self.category = category
        self.componentSignature = componentSignature
        self.parameterName = parameterName
        self.layoutModel = layoutModel
        self.schematicModel = schematicModel
        self.layoutValue = layoutValue
        self.schematicValue = schematicValue
        self.layoutPorts = layoutPorts
        self.schematicPorts = schematicPorts
        self.layoutCount = layoutCount
        self.schematicCount = schematicCount
        self.numericParameters = numericParameters
        self.stringParameters = stringParameters
        self.verificationGates = verificationGates
        self.rationale = rationale
    }
}
