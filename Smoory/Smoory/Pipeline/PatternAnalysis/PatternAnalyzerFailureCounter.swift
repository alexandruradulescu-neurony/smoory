import Foundation
import Observation

@Observable
@MainActor
final class PatternAnalyzerFailureCounter {
    static let shared = PatternAnalyzerFailureCounter()
    private(set) var count: Int = 0

    func increment() { count += 1 }
    func reset() { count = 0 }
}
