import Foundation
import SwiftUI

/// Environment value carrying the app-level HemaService state. ChatView reads this to gate on
/// memory readiness. Default `.loading` is harmless — SmooryApp always sets the real value.
private struct HemaStateKey: EnvironmentKey {
    static let defaultValue: HemaState = .loading
}

/// Environment value for the chat session UUID — stable across the app's lifetime so
/// navigating Sidebar away and back doesn't reset the session.
private struct ChatSessionIDKey: EnvironmentKey {
    static let defaultValue: UUID = UUID()
}

private struct ChatViewModelKey: EnvironmentKey {
    static let defaultValue: ChatViewModel? = nil
}

extension EnvironmentValues {
    var hemaState: HemaState {
        get { self[HemaStateKey.self] }
        set { self[HemaStateKey.self] = newValue }
    }
    var chatSessionID: UUID {
        get { self[ChatSessionIDKey.self] }
        set { self[ChatSessionIDKey.self] = newValue }
    }
    /// App-level ChatViewModel — persists across sidebar navigation so chat history survives.
    var chatViewModel: ChatViewModel? {
        get { self[ChatViewModelKey.self] }
        set { self[ChatViewModelKey.self] = newValue }
    }
}
