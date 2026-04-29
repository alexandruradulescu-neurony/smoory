import Foundation
import Observation

@Observable
@MainActor
final class SettingsViewModel {
    private(set) var hasKey: Bool
    var draft: String = ""
    var isReplacing: Bool = false
    private(set) var feedback: String?

    init() {
        self.hasKey = (KeychainService.read(service: KeychainService.anthropicAPIKeyService) != nil)
    }

    func beginReplace() {
        isReplacing = true
        draft = ""
        feedback = nil
    }

    func cancelReplace() {
        isReplacing = false
        draft = ""
        feedback = nil
    }

    func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainService.write(trimmed, service: KeychainService.anthropicAPIKeyService)
            hasKey = true
            isReplacing = false
            draft = ""
            feedback = "Saved."
        } catch let KeychainError.underlying(status) {
            feedback = "Couldn't save: keychain error \(status)"
        } catch {
            feedback = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func clear() {
        do {
            try KeychainService.delete(service: KeychainService.anthropicAPIKeyService)
            hasKey = false
            draft = ""
            isReplacing = false
            feedback = "Cleared."
        } catch let KeychainError.underlying(status) {
            feedback = "Couldn't clear: keychain error \(status)"
        } catch {
            feedback = "Couldn't clear: \(error.localizedDescription)"
        }
    }
}
