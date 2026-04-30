import Foundation
import Observation

/// Per-launch in-memory counter for structuring-layer JSON parse failures.
/// Resets every app launch (singleton with no persistence). Visible in Settings → Diagnostics.
@Observable
@MainActor
final class StructuringFailureCounter {
    static let shared = StructuringFailureCounter()
    private(set) var count: Int = 0

    private init() {}

    func increment() { count += 1 }
    func reset() { count = 0 }
}
