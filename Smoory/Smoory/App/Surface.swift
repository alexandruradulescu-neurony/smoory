import SwiftUI

enum Surface: String, CaseIterable, Identifiable {
    case feed
    case lists
    case chat
    case memory
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feed: "Feed"
        case .lists: "Lists"
        case .chat: "Chat"
        case .memory: "Memory"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .feed: "tray"
        case .lists: "list.bullet.rectangle"
        case .chat: "bubble.left.and.bubble.right"
        case .memory: "brain"
        case .settings: "gearshape"
        }
    }
}
