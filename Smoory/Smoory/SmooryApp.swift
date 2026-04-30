//
//  SmooryApp.swift
//  Smoory
//
//  Created by Alexandru on 29/04/2026.
//

import SQLiteVec
import SwiftData
import SwiftUI
import UserNotifications

@main
struct SmooryApp: App {
    @State private var hemaState: HemaState = .loading
    /// Stable for the app's lifetime so navigating sidebar away and back doesn't reset the chat session.
    @State private var chatSessionID = UUID()
    /// App-level ChatViewModel — outlives sidebar navigation so visible chat history persists.
    @State private var chatViewModel: ChatViewModel?

    @State private var scheduledActionService: ScheduledActionService?
    @State private var pollingTimer: Timer?
    @State private var notificationDelegate = NotificationDelegate()
    @State private var pendingDayReview = PendingDayReviewState()

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
            ScheduledAction.self,
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
                .environment(\.scheduledActionService, scheduledActionService)
                .sheet(isPresented: Binding(
                    get: { pendingDayReview.actionToPresent != nil },
                    set: { newValue in
                        if !newValue { pendingDayReview.actionToPresent = nil }
                    }
                )) {
                    if let action = pendingDayReview.actionToPresent,
                       case .ready(let hema) = hemaState,
                       let svc = scheduledActionService {
                        DayReviewSheet(
                            viewModel: DayReviewViewModel(
                                action: action,
                                modelContainer: sharedModelContainer,
                                hema: hema,
                                scheduledActionService: svc
                            ),
                            dismiss: { pendingDayReview.actionToPresent = nil }
                        )
                    }
                }
                .task {
                    initializeScheduledActionsIfNeeded()
                    await initializeHemaIfNeeded()
                    await requestNotificationPermissionIfNeeded()
                    startPollingIfNeeded()
                }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1100, height: 700)
        .commands {
            DebugCommands(
                hemaState: hemaState,
                modelContainer: sharedModelContainer,
                scheduledActionService: scheduledActionService
            )
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
                chatSessionID: chatSessionID,
                scheduledActionService: scheduledActionService
            )
            print("[smoory] hema ready at \(hema.databaseURL.path(percentEncoded: false))")
        } catch {
            hemaState = .failed(error.localizedDescription)
            print("[smoory] hema init failed: \(error)")
        }
    }

    @MainActor
    private func initializeScheduledActionsIfNeeded() {
        guard scheduledActionService == nil else { return }
        NotificationCategoryRegistrar.register()
        let writer = AppGroupContainerWriter()
        let service = ScheduledActionService(
            modelContainer: sharedModelContainer,
            appGroupWriter: writer
        )
        scheduledActionService = service
        notificationDelegate.attach(service: service, pendingDayReview: pendingDayReview)
        if writer == nil {
            print("[scheduled] App Group container unavailable — widget snapshot writes are disabled")
        } else {
            print("[scheduled] service initialized; snapshot path \(writer!.snapshotURL.path(percentEncoded: false))")
        }
    }

    @MainActor
    private func requestNotificationPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            print("[notif] permission already \(settings.authorizationStatus.rawValue)")
            return
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            print("[notif] permission \(granted ? "granted" : "denied")")
        } catch {
            print("[notif] permission request failed: \(error)")
        }
    }

    @MainActor
    private func startPollingIfNeeded() {
        guard pollingTimer == nil, let service = scheduledActionService else { return }
        // Catch any backlog accumulated while the app was closed.
        Task { @MainActor in await service.processOverdue() }
        // 5-minute foreground polling per Phase 3 decision.
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in await service.processOverdue() }
        }
    }
}
