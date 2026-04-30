import Foundation

enum OnboardingState: String, Sendable {
    case notStarted
    case inProgress
    case completed
}

/// One-shot UserDefaults wrapper for onboarding state.
/// v1: skip is permanent; revisit if real users want a reset (see PHASE_3_NOTES.md).
enum OnboardingStateStore {
    private static let key = "OnboardingState"

    static func current() -> OnboardingState {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return OnboardingState(rawValue: raw) ?? .notStarted
    }

    static func set(_ state: OnboardingState) {
        UserDefaults.standard.set(state.rawValue, forKey: key)
    }
}
