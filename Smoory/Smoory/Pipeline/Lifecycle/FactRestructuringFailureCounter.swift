import Foundation
import Observation

/// Per-launch in-memory counter for fact restructurer failures (LLM errors,
/// parse failures, candidate-persistence errors). Resets every app launch.
/// Visible in Settings → Diagnostics. Failures here are non-fatal — the day
/// review's summary turn is already persisted before the restructurer runs.
@Observable
@MainActor
final class FactRestructuringFailureCounter {
    static let shared = FactRestructuringFailureCounter()
    private(set) var count: Int = 0

    private init() {}

    func increment() { count += 1 }
    func reset() { count = 0 }
}
