import Foundation
import LVSCore

public struct NetgenLVSReportParser: Sendable {
    public init() {}

    public func parse(
        backendID: String = "netgen",
        toolName: String = "netgen",
        logPath: String,
        rawOutput: String,
        success: Bool,
        provenance: LVSToolProvenance? = nil
    ) -> LVSResult {
        var diagnostics = rawOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { parseDiagnostic(line: String($0)) }
        let completed = containsExactLine("LVS_DONE", in: rawOutput)
        if completed {
            if let resultDiagnostic = parseResultDiagnostic(rawOutput: rawOutput),
               !diagnostics.contains(where: { $0.severity == .error }) {
                diagnostics.append(resultDiagnostic)
            } else if !hasLVSResult(rawOutput: rawOutput),
                      !diagnostics.contains(where: { $0.severity == .error }) {
                diagnostics.append(LVSDiagnostic(
                    severity: .error,
                    message: "LVS completed without an LVS_RESULT line",
                    ruleID: "LVS_RESULT_MISSING",
                    rawLine: "LVS_DONE"
                ))
            }
        }

        return LVSResult(
            backendID: backendID,
            toolName: toolName,
            success: success,
            completed: completed,
            logPath: logPath,
            diagnostics: diagnostics,
            provenance: provenance
        )
    }

    private func parseDiagnostic(line: String) -> LVSDiagnostic? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fields = keyValueFields(in: trimmed)
        let uppercased = trimmed.uppercased()

        if uppercased.hasPrefix("MISMATCH") {
            return LVSDiagnostic(
                severity: .error,
                message: fields["message"] ?? strippedMessage(from: trimmed),
                ruleID: fields["rule"] ?? "LVS_MISMATCH",
                rawLine: trimmed
            )
        }

        if uppercased.hasPrefix("ERROR") {
            return LVSDiagnostic(
                severity: .error,
                message: fields["message"] ?? strippedMessage(from: trimmed),
                ruleID: fields["rule"],
                rawLine: trimmed
            )
        }

        return nil
    }

    private func parseResultDiagnostic(rawOutput: String) -> LVSDiagnostic? {
        for line in rawOutput.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.uppercased().hasPrefix("LVS_RESULT") else { continue }
            let fields = keyValueFields(in: trimmed)
            let status = fields["status"]?.lowercased()
            guard status != "match" else { return nil }
            return LVSDiagnostic(
                severity: .error,
                message: fields["message"] ?? strippedMessage(from: trimmed),
                ruleID: "LVS_RESULT",
                rawLine: trimmed
            )
        }
        return nil
    }

    private func hasLVSResult(rawOutput: String) -> Bool {
        rawOutput
            .split(whereSeparator: \.isNewline)
            .contains { String($0).trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("LVS_RESULT") }
    }

    private func keyValueFields(in line: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = line.startIndex
        while index < line.endIndex {
            while index < line.endIndex, isFieldSeparator(line[index]) {
                index = line.index(after: index)
            }
            let keyStart = index
            while index < line.endIndex, line[index] != "=", !isFieldSeparator(line[index]) {
                index = line.index(after: index)
            }
            guard index < line.endIndex, line[index] == "=" else {
                while index < line.endIndex, !isFieldSeparator(line[index]) {
                    index = line.index(after: index)
                }
                continue
            }
            let key = String(line[keyStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            index = line.index(after: index)

            let value: String
            if index < line.endIndex && (line[index] == "\"" || line[index] == "'") {
                let quote = line[index]
                index = line.index(after: index)
                var characters: [Character] = []
                while index < line.endIndex, line[index] != quote {
                    if line[index] == "\\" {
                        let escapeIndex = line.index(after: index)
                        guard escapeIndex < line.endIndex else { break }
                        characters.append(unescapedCharacter(line[escapeIndex]))
                        index = line.index(after: escapeIndex)
                    } else {
                        characters.append(line[index])
                        index = line.index(after: index)
                    }
                }
                value = String(characters)
                if index < line.endIndex {
                    index = line.index(after: index)
                }
            } else {
                let valueStart = index
                while index < line.endIndex, !isFieldSeparator(line[index]) {
                    index = line.index(after: index)
                }
                value = String(line[valueStart..<index])
            }

            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private func isFieldSeparator(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == ","
    }

    private func containsExactLine(_ marker: String, in rawOutput: String) -> Bool {
        rawOutput
            .split(whereSeparator: \.isNewline)
            .contains { String($0).trimmingCharacters(in: .whitespacesAndNewlines) == marker }
    }

    private func unescapedCharacter(_ character: Character) -> Character {
        switch character {
        case "n":
            return "\n"
        case "r":
            return "\r"
        case "t":
            return "\t"
        default:
            return character
        }
    }

    private func strippedMessage(from line: String) -> String {
        line.replacingOccurrences(of: "MISMATCH", with: "")
            .replacingOccurrences(of: "ERROR", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
