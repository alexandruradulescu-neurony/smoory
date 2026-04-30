import Foundation
import Observation

/// In-memory counter, surfaced in Settings → Diagnostics. Mirrors
/// StructuringFailureCounter's pattern. Resets on app relaunch.
@Observable
@MainActor
final class MorningBriefFailureCounter {
    static let shared = MorningBriefFailureCounter()
    private(set) var count: Int = 0

    func increment() { count += 1 }
    func reset() { count = 0 }
}
