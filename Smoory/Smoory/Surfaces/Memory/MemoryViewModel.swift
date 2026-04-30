import Foundation
import Observation

@Observable
@MainActor
final class MemoryViewModel {
    enum Tab: Hashable, CaseIterable {
        case facts
        case turns
    }
    var selectedTab: Tab = .facts
}
