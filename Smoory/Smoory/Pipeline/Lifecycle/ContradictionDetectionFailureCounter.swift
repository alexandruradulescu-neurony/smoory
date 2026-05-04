import Foundation
import Observation

/// Per-launch in-memory counter for contradiction-detection failures (LLM
/// errors, parse failures, timeouts). Resets every app launch (singleton
/// with no persistence). Visible in Settings → Diagnostics alongside the
/// existing failure counters. Failures here are non-fatal — the new fact
/// has already landed; only contradiction-detection's downstream output
/// (a possible supersession candidate) is missed.
@Observable
@MainActor
final class ContradictionDetectionFailureCounter {
    static let shared = ContradictionDetectionFailureCounter()
    private(set) var count: Int = 0

    private init() {}

    func increment() { count += 1 }
    func reset() { count = 0 }
}
