import Foundation

public struct LVSRepairHintBuilder: Sendable {
    public init() {}

    public func build(reportURL: URL) throws -> LVSRepairHintReport {
        do {
            let data = try Data(contentsOf: reportURL)
            let result = try JSONDecoder().decode(LVSExecutionResult.self, from: data)
            return build(result: result, reportURL: reportURL)
        } catch {
            throw LVSError.invalidInput("Unable to load LVS repair hint input: \(error.localizedDescription)")
        }
    }

    public func build(
        result: LVSExecutionResult,
        reportURL: URL? = nil
    ) -> LVSRepairHintReport {
        let activeDiagnostics = result.result.diagnostics.enumerated().filter {
            $0.element.severity == .error && !$0.element.isWaived
        }
        var unsupportedIndexes: [Int] = []
        var unsupportedDiagnostics: [LVSUnsupportedRepairDiagnostic] = []
        var hints: [LVSRepairHint] = []
        for pair in activeDiagnostics {
            let index = pair.offset
            let diagnostic = pair.element
            guard let hint = repairHint(for: diagnostic, sourceDiagnosticIndex: index) else {
                unsupportedIndexes.append(index)
                unsupportedDiagnostics.append(unsupportedDiagnostic(for: diagnostic, sourceDiagnosticIndex: index))
                continue
            }
            hints.append(hint)
        }
        return LVSRepairHintReport(
            status: status(
                activeDiagnosticCount: activeDiagnostics.count,
                hintCount: hints.count,
                unsupportedDiagnosticCount: unsupportedDiagnostics.count
            ),
            reportURL: reportURL ?? result.reportURL,
            backendID: result.result.backendID,
            topCell: result.request.topCell,
            activeDiagnosticCount: activeDiagnostics.count,
            hintCount: hints.count,
            hints: hints,
            unsupportedDiagnosticIndexes: unsupportedIndexes,
            unsupportedDiagnostics: unsupportedDiagnostics
        )
    }

    private func status(
        activeDiagnosticCount: Int,
        hintCount: Int,
        unsupportedDiagnosticCount: Int
    ) -> String {
        guard activeDiagnosticCount > 0 else {
            return "ready"
        }
        if hintCount == 0 {
            return "no-actionable-hints"
        }
        if unsupportedDiagnosticCount > 0 {
            return "partial"
        }
        return "ready"
    }

    private func repairHint(
        for diagnostic: LVSDiagnostic,
        sourceDiagnosticIndex: Int
    ) -> LVSRepairHint? {
        guard let operationID = operationID(for: diagnostic) else {
            return nil
        }
        return LVSRepairHint(
            hintID: hintID(for: diagnostic, index: sourceDiagnosticIndex),
            sourceDiagnosticIndex: sourceDiagnosticIndex,
            operationID: operationID,
            confidence: confidence(for: operationID, diagnostic: diagnostic),
            ruleID: diagnostic.ruleID,
            category: diagnostic.category,
            componentSignature: diagnostic.componentSignature,
            parameterName: diagnostic.parameterName,
            layoutModel: diagnostic.layoutModel,
            schematicModel: diagnostic.schematicModel,
            layoutValue: diagnostic.layoutValue,
            schematicValue: diagnostic.schematicValue,
            layoutPorts: diagnostic.layoutPorts ?? [],
            schematicPorts: diagnostic.schematicPorts ?? [],
            layoutCount: diagnostic.layoutCount,
            schematicCount: diagnostic.schematicCount,
            stringParameters: stringParameters(for: diagnostic),
            verificationGates: verificationGates(for: operationID),
            rationale: rationale(for: operationID, diagnostic: diagnostic),
            numericParameters: numericParameters(for: diagnostic)
        )
    }

    private func unsupportedDiagnostic(
        for diagnostic: LVSDiagnostic,
        sourceDiagnosticIndex: Int
    ) -> LVSUnsupportedRepairDiagnostic {
        let suggestedActions = unsupportedSuggestedActions(for: diagnostic)
        return LVSUnsupportedRepairDiagnostic(
            sourceDiagnosticIndex: sourceDiagnosticIndex,
            code: "lvs-repair-unsupported-\(codeSlug(diagnostic.ruleID ?? diagnostic.category ?? diagnostic.message))",
            severity: diagnostic.severity,
            message: diagnostic.message,
            ruleID: diagnostic.ruleID,
            category: diagnostic.category,
            suggestedFix: diagnostic.suggestedFix,
            rawLine: diagnostic.rawLine,
            reason: "No typed repair operation is registered for this LVS diagnostic signature.",
            suggestedActions: suggestedActions
        )
    }

    private func unsupportedSuggestedActions(for diagnostic: LVSDiagnostic) -> [String] {
        var actions: [String] = []
        if let suggestedFix = diagnostic.suggestedFix?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggestedFix.isEmpty {
            actions.append(suggestedFix)
        }
        actions.append("Inspect the source LVS diagnostic before adding a scoped repair operation.")
        return actions
    }

    private func operationID(for diagnostic: LVSDiagnostic) -> String? {
        let normalized = normalizedKind(for: diagnostic)
        if parameterRepairAssignment(for: diagnostic, normalized: normalized) != nil {
            return "simulation.set-netlist-parameters"
        }
        if normalized.contains("model")
            || normalized.contains("terminal")
            || normalized.contains("equivalence") {
            return "lvs.policy-repair"
        }
        if normalized.contains("port") || portSetsDiffer(diagnostic) {
            return "layout.add-label"
        }
        return nil
    }

    private func parameterRepairAssignment(
        for diagnostic: LVSDiagnostic,
        normalized: String
    ) -> (name: String, value: Double)? {
        guard normalized.contains("parameter") || normalized.contains("multiplicity"),
              let parameterName = diagnostic.parameterName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parameterName.isEmpty,
              let schematicValue = diagnostic.schematicValue,
              let value = spiceNumericValue(schematicValue),
              value.isFinite else {
            return nil
        }
        if let componentName = diagnostic.layoutComponentName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !componentName.isEmpty {
            return ("\(componentName).\(parameterName)", value)
        }
        return (parameterName, value)
    }

    private func portSetsDiffer(_ diagnostic: LVSDiagnostic) -> Bool {
        guard let layoutPorts = diagnostic.layoutPorts,
              let schematicPorts = diagnostic.schematicPorts else {
            return false
        }
        return layoutPorts != schematicPorts
    }

    private func stringParameters(for diagnostic: LVSDiagnostic) -> [String: String] {
        var parameters: [String: String] = [:]
        if let ruleID = diagnostic.ruleID {
            parameters["ruleID"] = ruleID
        }
        if let category = diagnostic.category {
            parameters["category"] = category
        }
        if let componentSignature = diagnostic.componentSignature {
            parameters["componentSignature"] = componentSignature
        }
        if let parameterName = diagnostic.parameterName {
            parameters["parameterName"] = parameterName
        }
        if let layoutModel = diagnostic.layoutModel {
            parameters["layoutModel"] = layoutModel
        }
        if let schematicModel = diagnostic.schematicModel {
            parameters["schematicModel"] = schematicModel
        }
        if let layoutValue = diagnostic.layoutValue {
            parameters["layoutValue"] = layoutValue
        }
        if let schematicValue = diagnostic.schematicValue {
            parameters["schematicValue"] = schematicValue
        }
        if let layoutComponentName = diagnostic.layoutComponentName {
            parameters["layoutComponentName"] = layoutComponentName
        }
        if let schematicComponentName = diagnostic.schematicComponentName {
            parameters["schematicComponentName"] = schematicComponentName
        }
        if let assignment = parameterRepairAssignment(for: diagnostic, normalized: normalizedKind(for: diagnostic)) {
            parameters["assignmentName"] = assignment.name
            parameters["lvsEditedNetlistRole"] = "layout"
            parameters["sourceValue"] = diagnostic.layoutValue ?? ""
            parameters["targetValue"] = diagnostic.schematicValue ?? ""
        }
        parameters.merge(policyParameters(for: diagnostic)) { current, _ in current }
        if let firstMissingPort = missingLayoutPorts(for: diagnostic).first {
            parameters["portName"] = firstMissingPort
            parameters["labelText"] = firstMissingPort
            parameters["netName"] = firstMissingPort
        }
        return parameters
    }

    private func numericParameters(for diagnostic: LVSDiagnostic) -> [String: Double]? {
        guard let assignment = parameterRepairAssignment(for: diagnostic, normalized: normalizedKind(for: diagnostic)) else {
            return nil
        }
        return ["assignmentValue": assignment.value]
    }

    private func policyParameters(for diagnostic: LVSDiagnostic) -> [String: String] {
        let normalized = normalizedKind(for: diagnostic)
        if normalized.contains("model") {
            return ["policyKind": "model-equivalence"]
        }
        if normalized.contains("terminal") || normalized.contains("equivalence") {
            var parameters: [String: String] = ["policyKind": "terminal-equivalence"]
            if let kind = terminalKind(for: diagnostic) {
                parameters["terminalKind"] = kind
            }
            if let pinCount = terminalPinCount(for: diagnostic) {
                parameters["terminalPinCount"] = String(pinCount)
            }
            if let groups = inferredEquivalentPinGroups(for: diagnostic) {
                parameters["equivalentPinGroups"] = encodedPinGroups(groups)
            }
            return parameters
        }
        return [:]
    }

    private func terminalKind(for diagnostic: LVSDiagnostic) -> String? {
        if let componentSignature = diagnostic.componentSignature,
           let first = componentSignature.split(separator: "|").first {
            let kind = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
            if !kind.isEmpty {
                return kind
            }
        }
        return (diagnostic.layoutModel ?? diagnostic.schematicModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func terminalPinCount(for diagnostic: LVSDiagnostic) -> Int? {
        if let count = diagnostic.layoutPorts?.count, count > 0 {
            return count
        }
        if let count = diagnostic.schematicPorts?.count, count > 0 {
            return count
        }
        return nil
    }

    private func inferredEquivalentPinGroups(for diagnostic: LVSDiagnostic) -> [[Int]]? {
        guard let layoutPorts = diagnostic.layoutPorts,
              let schematicPorts = diagnostic.schematicPorts,
              layoutPorts.count == schematicPorts.count,
              Set(layoutPorts) == Set(schematicPorts),
              layoutPorts != schematicPorts else {
            return nil
        }
        let swappedIndexes = layoutPorts.indices.filter { layoutPorts[$0] != schematicPorts[$0] }
        guard swappedIndexes.count >= 2 else {
            return nil
        }
        return [Array(swappedIndexes)]
    }

    private func encodedPinGroups(_ groups: [[Int]]) -> String {
        let groupText = groups.map { group in
            "[\(group.map(String.init).joined(separator: ","))]"
        }
        .joined(separator: ",")
        return "[\(groupText)]"
    }

    private func missingLayoutPorts(for diagnostic: LVSDiagnostic) -> [String] {
        let layoutPorts = Set(diagnostic.layoutPorts ?? [])
        return (diagnostic.schematicPorts ?? []).filter { !layoutPorts.contains($0) }
    }

    private func hintID(for diagnostic: LVSDiagnostic, index: Int) -> String {
        let rule = diagnostic.ruleID ?? diagnostic.category ?? "diagnostic"
        return "lvs-repair-\(index)-\(sanitize(rule))"
    }

    private func sanitize(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(Character(scalar)) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "diagnostic" : collapsed
    }

    private func codeSlug(_ value: String) -> String {
        var result = ""
        var previousDash = false
        for scalar in value.lowercased().unicodeScalars {
            let scalarValue = scalar.value
            if (48...57).contains(scalarValue) || (97...122).contains(scalarValue) {
                result.unicodeScalars.append(scalar)
                previousDash = false
            } else if !previousDash {
                result.append("-")
                previousDash = true
            }
            if result.count >= 64 {
                break
            }
        }
        let slug = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "diagnostic" : slug
    }

    private func normalizedKind(for diagnostic: LVSDiagnostic) -> String {
        [
            diagnostic.ruleID,
            diagnostic.category,
            diagnostic.componentSignature,
            diagnostic.parameterName,
            diagnostic.layoutModel,
            diagnostic.schematicModel,
            diagnostic.message,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }

    private func confidence(for operationID: String, diagnostic: LVSDiagnostic) -> String {
        switch operationID {
        case "layout.add-label":
            missingLayoutPorts(for: diagnostic).isEmpty ? "medium" : "high"
        case "simulation.set-netlist-parameters":
            diagnostic.layoutComponentName == nil ? "medium" : "high"
        case "lvs.policy-repair":
            "medium"
        default:
            "low"
        }
    }

    private func verificationGates(for operationID: String) -> [String] {
        switch operationID {
        case "layout.add-label":
            return ["native-lvs", "native-drc", "artifact-integrity"]
        case "simulation.set-netlist-parameters":
            return ["artifact-integrity", "native-lvs"]
        case "lvs.policy-repair":
            return ["approval-gate", "native-lvs", "artifact-integrity"]
        default:
            return ["native-lvs", "artifact-integrity"]
        }
    }

    private func rationale(for operationID: String, diagnostic: LVSDiagnostic) -> String {
        let rule = diagnostic.ruleID ?? diagnostic.category ?? "LVS diagnostic"
        if operationID == "simulation.set-netlist-parameters",
           let assignment = parameterRepairAssignment(for: diagnostic, normalized: normalizedKind(for: diagnostic)) {
            return "\(rule) maps to \(operationID) because the diagnostic exposes parameter \(assignment.name) and schematic target value \(diagnostic.schematicValue ?? "n/a")."
        }
        return "\(rule) maps to \(operationID) because the diagnostic exposes layoutPorts=\(diagnostic.layoutPorts ?? []) and schematicPorts=\(diagnostic.schematicPorts ?? [])."
    }

    private func spiceNumericValue(_ value: String) -> Double? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "µ", with: "u")
        let numberEnd = numericPrefixEnd(in: normalized)
        guard numberEnd > normalized.startIndex else {
            return nil
        }
        let numberText = String(normalized[..<numberEnd])
        guard let number = Double(numberText) else {
            return nil
        }
        let suffix = String(normalized[numberEnd...])
        guard let multiplier = multiplier(for: suffix) else {
            return nil
        }
        return number * multiplier
    }

    private func numericPrefixEnd(in value: String) -> String.Index {
        var index = value.startIndex
        var sawDigit = false
        var sawDecimalPoint = false
        var sawExponent = false

        if index < value.endIndex, value[index] == "+" || value[index] == "-" {
            index = value.index(after: index)
        }

        while index < value.endIndex {
            let character = value[index]
            if character.isNumber {
                sawDigit = true
                index = value.index(after: index)
                continue
            }
            if character == ".", !sawDecimalPoint, !sawExponent {
                sawDecimalPoint = true
                index = value.index(after: index)
                continue
            }
            if character == "e", sawDigit, !sawExponent {
                let exponentStart = index
                var next = value.index(after: index)
                if next < value.endIndex, value[next] == "+" || value[next] == "-" {
                    next = value.index(after: next)
                }
                guard next < value.endIndex, value[next].isNumber else {
                    return exponentStart
                }
                sawExponent = true
                index = next
                continue
            }
            break
        }
        return sawDigit ? index : value.startIndex
    }

    private func multiplier(for suffix: String) -> Double? {
        guard !suffix.isEmpty else {
            return 1
        }
        if suffix.hasPrefix("meg") {
            return 1e6
        }
        guard let first = suffix.first else {
            return 1
        }
        switch first {
        case "t":
            return 1e12
        case "g":
            return 1e9
        case "k":
            return 1e3
        case "m":
            return 1e-3
        case "u":
            return 1e-6
        case "n":
            return 1e-9
        case "p":
            return 1e-12
        case "f":
            return 1e-15
        default:
            return nil
        }
    }
}
