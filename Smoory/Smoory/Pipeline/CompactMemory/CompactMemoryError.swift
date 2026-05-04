import Foundation

/// Errors surfaced by `CompactMemoryGenerator`. Failure paths increment
/// `CompactMemoryFailureCounter.shared` and leave the previously-active
/// compact memory of that kind in place — `replaceActiveCompactMemory` is
/// only called after a body passes validation.
enum CompactMemoryError: Error, CustomStringConvertible {
    case llmReturnedEmpty
    case llmReturnedJSON
    case wordCountOutOfBounds(actual: Int, expected: ClosedRange<Int>)
    case retryFailed(underlying: Error?)

    var description: String {
        switch self {
        case .llmReturnedEmpty:
            return "compact memory: LLM returned empty body"
        case .llmReturnedJSON:
            return "compact memory: LLM returned JSON instead of plain prose"
        case .wordCountOutOfBounds(let actual, let expected):
            return "compact memory: \(actual) words outside expected range \(expected)"
        case .retryFailed(let err):
            return "compact memory: retry attempt failed (\(err.map(String.init(describing:)) ?? "no underlying error"))"
        }
    }
}
