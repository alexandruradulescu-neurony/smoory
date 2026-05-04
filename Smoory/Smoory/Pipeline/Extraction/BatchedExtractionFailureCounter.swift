import Foundation
import Observation

/// Per-launch in-memory counter for batched fact extraction failures —
/// salience LLM errors, extraction LLM errors, parse failures, candidate-
/// persistence errors. Resets every app launch (singleton with no
/// persistence). Visible in Settings → Diagnostics.
@Observable
@MainActor
final class BatchedExtractionFailureCounter {
    static let shared = BatchedExtractionFailureCounter()
    private(set) var count: Int = 0

    private init() {}

    func increment() { count += 1 }
    func reset() { count = 0 }
}

/// Per-launch in-memory counter for batches the salience gate decided were
/// not memory-worthy. Useful for tuning the salience prompt: if this number
/// is very high, the gate may be too strict; if it's near zero, the gate
/// isn't filtering anything and the heavy-tier extractor is paying
/// unnecessary calls.
@Observable
@MainActor
final class BatchedExtractionSkippedCounter {
    static let shared = BatchedExtractionSkippedCounter()
    private(set) var count: Int = 0

    private init() {}

    func increment() { count += 1 }
    func reset() { count = 0 }
}
