import Observation

/// App-level navigation state, lifted from ContentView's @State so the notification
/// delegate can imperatively change surfaces (e.g., morning brief tap → focus Feed).
@Observable
@MainActor
final class NavigationState {
    var selectedSurface: Surface? = .feed
}
