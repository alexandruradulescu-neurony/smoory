import Foundation
import Observation

@Observable
@MainActor
final class APIKeyViewModel {
    let service: String              // KeychainService service identifier
    let providerLabel: String        // "Anthropic" / "Voyage" — used in feedback strings
    let placeholder: String          // SecureField placeholder, e.g. "sk-ant-…"

    private(set) var hasKey: Bool
    var draft: String = ""
    var isReplacing: Bool = false
    private(set) var feedback: String?

    init(service: String, providerLabel: String, placeholder: String) {
        self.service = service
        self.providerLabel = providerLabel
        self.placeholder = placeholder
        self.hasKey = (KeychainService.read(service: service) != nil)
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
            try KeychainService.write(trimmed, service: service)
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
            try KeychainService.delete(service: service)
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
