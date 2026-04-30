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
            switch resolvedSelection {
            case .feed: FeedView()
            case .todos: TodosView()
            case .chat: ChatView()
            case .memory: MemoryView()
            case .settings: SettingsView()
            case .none: FeedView()
            }
        }
    }
}

#Preview {
    ContentView()
}
