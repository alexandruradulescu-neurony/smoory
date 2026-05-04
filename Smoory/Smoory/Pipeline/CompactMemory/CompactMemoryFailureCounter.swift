import Foundation
import Observation

/// Per-launch in-memory counter for compact-memory regeneration failures
/// (LLM errors, parse failures, word-count rejections after retry). Resets
/// every app launch (singleton with no persistence). Visible in
/// Settings → Diagnostics alongside StructuringFailureCounter and
/// MorningBriefFailureCounter.
@Observable
@MainActor
final class CompactMemoryFailureCounter {
    static let shared = CompactMemoryFailureCounter()
    private(set) var count: Int = 0

    private init() {}

    func increment() { count += 1 }
    func reset() { count = 0 }
}
