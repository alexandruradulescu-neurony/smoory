//
//  ContentView.swift
//  Smoory
//
//  Created by Alexandru on 29/04/2026.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.navigationState) private var navigationState
    /// F-23 audit fix: app-level error bus. ContentView renders an `ErrorBannerOverlay`
    /// at the top so failures from any surface's mutation handler become visible.
    @Environment(\.errorBus) private var errorBus
    /// Local fallback so the previews / tests without env injection still work.
    @State private var localSelection: Surface? = .feed

    private var selectionBinding: Binding<Surface?> {
        if let nav = navigationState {
            return Binding(
                get: { nav.selectedSurface },
                set: { nav.selectedSurface = $0 }
            )
        }
        return $localSelection
    }

    private var resolvedSelection: Surface? {
        navigationState?.selectedSurface ?? localSelection
    }

    var body: some View {
        NavigationSplitView {
            List(Surface.allCases, id: \.self, selection: selectionBinding) { surface in
                Label(surface.title, systemImage: surface.symbol)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            ZStack(alignment: .top) {
                switch resolvedSelection {
                case .feed: FeedView()
                case .todos: TodosView()
                case .lists: ListsView()
                case .chat: ChatView()
                case .memory: MemoryView()
                case .settings: SettingsView()
                case .none: FeedView()
                }
                if let errorBus {
                    ErrorBannerOverlay(bus: errorBus)
                        .allowsHitTesting(true)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
