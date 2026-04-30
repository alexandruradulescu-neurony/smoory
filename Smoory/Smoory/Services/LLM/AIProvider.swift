import Foundation

enum AIProvider: String, Codable, CaseIterable, Sendable {
    case anthropic
    case deepseek

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .deepseek: "DeepSeek"
        }
    }

    /// Model identifier sent on the wire for a given tier. Mirrors each client's internal
    /// mapping so callers (e.g. structuring layer) can record provenance.
    func modelID(for tier: ModelTier) -> String {
        switch self {
        case .anthropic:
            switch tier {
            case .fast: return "claude-haiku-4-5"
            case .balanced: return "claude-sonnet-4-6"
            case .heavy: return "claude-opus-4-7"
            }
        case .deepseek:
            switch tier {
            case .fast, .balanced: return "deepseek-chat"
            case .heavy: return "deepseek-reasoner"
            }
        }
    }
}

/// UserDefaults-backed store for the active AI provider. Default is .deepseek for fresh
/// installs and unset existing installs alike (per milestone 2.5b decision).
enum AIProviderStore {
    private static let key = "com.assistant.smoory.aiProvider"

    static func current() -> AIProvider {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return AIProvider(rawValue: raw) ?? .deepseek
    }

    @MainActor
    static func set(_ provider: AIProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: key)
    }
}
