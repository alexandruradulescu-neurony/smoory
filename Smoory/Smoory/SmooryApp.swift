//
//  SmooryApp.swift
//  Smoory
//
//  Created by Alexandru on 29/04/2026.
//

import SQLiteVec
import SwiftData
import SwiftUI

@main
struct SmooryApp: App {
    @State private var hemaState: HemaState = .loading
    /// Stable for the app's lifetime so navigating sidebar away and back doesn't reset the chat session.
    @State private var chatSessionID = UUID()
    /// App-level ChatViewModel — outlives sidebar navigation so visible chat history persists.
    @State private var chatViewModel: ChatViewModel?

    init() {
        // Load the sqlite-vec extension into SQLite globally. Must happen before any Database init.
        do {
            try SQLiteVec.initialize()
        } catch {
            print("[smoory] SQLiteVec.initialize failed: \(error)")
        }
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Role.self,
            Goal.self,
            Project.self,
            Thread.self,
            Todo.self,
            Habit.self,
            Person.self,
            Profile.self,
            Infrastructure.self,
            CaptureItem.self,
            FeedItem.self,
            Schedule.self,
            RuleAdjustment.self,
            CandidateWrite.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.dynamicTypeSize, .xxLarge)
                .environment(\.hemaState, hemaState)
                .environment(\.chatSessionID, chatSessionID)
                .environment(\.chatViewModel, chatViewModel)
                .task { await initializeHemaIfNeeded() }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1100, height: 700)
        .commands {
            DebugCommands(hemaState: hemaState, modelContainer: sharedModelContainer)
        }
    }

    @MainActor
    private func initializeHemaIfNeeded() async {
        guard case .loading = hemaState else { return }
        do {
            let hema = try await HemaService(embedder: VoyageEmbedder())
            hemaState = .ready(hema)
            // Construct ChatViewModel once hema is ready; it lives at App level so chat
            // history persists across sidebar navigation.
            chatViewModel = ChatViewModel(
                modelContainer: sharedModelContainer,
                hema: hema,
                chatSessionID: chatSessionID
            )
            print("[smoory] hema ready at \(hema.databaseURL.path(percentEncoded: false))")
        } catch {
            hemaState = .failed(error.localizedDescription)
            print("[smoory] hema init failed: \(error)")
        }
    }
}
