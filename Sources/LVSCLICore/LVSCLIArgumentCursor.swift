import Foundation

struct LVSCLIArgumentCursor: Sendable {
  static func value(
    after argument: String,
    in arguments: [String],
    index: inout Int
  ) throws -> String {
    let valueIndex = index + 1
    guard valueIndex < arguments.count else {
      throw LVSCLIError.missingValue(argument)
    }
    let value = arguments[valueIndex]
    guard !value.hasPrefix("--") else {
      throw LVSCLIError.missingValue(argument)
    }
    index = valueIndex
    return value
  }

  static func nonEmptyValue(
    after argument: String,
    in arguments: [String],
    index: inout Int,
    expected: String
  ) throws -> String {
    let value = try value(after: argument, in: arguments, index: &index)
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LVSCLIError.invalidValue(argument: argument, value: value, expected: expected)
    }
    return value
  }

  static func positiveFiniteDouble(
    after argument: String,
    in arguments: [String],
    index: inout Int
  ) throws -> Double {
    let rawValue = try value(after: argument, in: arguments, index: &index)
    guard let value = Double(rawValue), value.isFinite, value > 0 else {
      throw LVSCLIError.invalidValue(
        argument: argument, value: rawValue, expected: "positive finite seconds")
    }
    return value
  }
}
