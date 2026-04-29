//
//  ContentView.swift
//  Smoory
//
//  Created by Alexandru on 29/04/2026.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selection: Surface? = .feed

    var body: some View {
        NavigationSplitView {
            List(Surface.allCases, id: \.self, selection: $selection) { surface in
                Label(surface.title, systemImage: surface.symbol)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            switch selection {
            case .feed: FeedView()
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
