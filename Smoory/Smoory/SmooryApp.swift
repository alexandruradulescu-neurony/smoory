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
    /// App-level CalendarService dedicated to the 5-min snapshot tick + app-launch
    /// snapshot writes. Other consumers (chat, day review, etc.) keep their own
    /// fallback instances — sharing isn't required for correctness, only for the
    /// snapshot write path's stability.
    @State private var snapshotCalendarService = CalendarService()
    @State private var notificationDelegate = NotificationDelegate()
    @State private var pendingDayReview = PendingDayReviewState()
    @State private var pendingWeekReview = PendingWeekReviewState()
    @State private var firedReminderQueue = FiredReminderQueue()
    @State private var navigationState = NavigationState()
    @State private var morningBriefDispatcher: MorningBriefDispatcher?
    /// App-level CompactMemoryGenerator constructed once hema is ready. Threaded into
    /// MorningBriefGenerator (for the .today brief side-write) and into
    /// WeekReviewViewModel (for .recent + counter-gated .overall regeneration on review
    /// completion). Debug commands also call its three generate* methods directly.
    @State private var compactMemoryGenerator: CompactMemoryGenerator?
    @Environment(\.scenePhase) private var scenePhase

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
            WeekReviewSummary.self,
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
            ZStack(alignment: .top) {
                ContentView()
                    .environment(\.dynamicTypeSize, .xxLarge)
                    .environment(\.hemaState, hemaState)
                    .environment(\.chatSessionID, chatSessionID)
                    .environment(\.chatViewModel, chatViewModel)
                    .environment(\.scheduledActionService, scheduledActionService)
                    .environment(\.navigationState, navigationState)
                    .sheet(isPresented: Binding(
                        get: { pendingDayReview.actionToPresent != nil || pendingWeekReview.actionToPresent != nil },
                        set: { newValue in
                            if !newValue {
                                pendingDayReview.actionToPresent = nil
                                pendingWeekReview.actionToPresent = nil
                            }
                        }
                    )) {
                        reviewSheetContent
                    }
                    .task {
                        initializeScheduledActionsIfNeeded()
                        await initializeHemaIfNeeded()
                        await requestNotificationPermissionIfNeeded()
                        startPollingIfNeeded()
                        await refreshStaleReminders()
                        await writeInitialSnapshots()
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        if newPhase == .active {
                            Task { @MainActor in await refreshStaleReminders() }
                        }
                    }

                reminderBannerStack
            }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1100, height: 700)
        .commands {
            DebugCommands(
                hemaState: hemaState,
                modelContainer: sharedModelContainer,
                scheduledActionService: scheduledActionService,
                morningBriefDispatcher: morningBriefDispatcher,
                compactMemoryGenerator: compactMemoryGenerator
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
            // Compact memory generator (4.2) — single instance shared by the
            // morning brief route (.today side-write) and the week review hook
            // (.recent + counter-gated .overall).
            let compactGen = CompactMemoryGenerator(
                modelContainer: sharedModelContainer,
                hema: hema,
                calendarService: snapshotCalendarService
            )
            compactMemoryGenerator = compactGen

            // Morning brief dispatcher needs hema for retrieve_memory tool calls; build
            // it now and (re)attach the notification delegate so morning_brief taps route
            // through the dispatcher.
            if let svc = scheduledActionService {
                let dispatcher = MorningBriefDispatcher(
                    generator: MorningBriefGenerator(
                        modelContainer: sharedModelContainer,
                        hema: hema,
                        calendarService: CalendarService(),
                        appGroupWriter: AppGroupContainerWriter(),
                        scheduledActionService: svc,
                        compactMemoryGenerator: compactGen
                    ),
                    scheduledActionService: svc,
                    modelContainer: sharedModelContainer
                )
                morningBriefDispatcher = dispatcher
                notificationDelegate.attach(
                    service: svc,
                    pendingDayReview: pendingDayReview,
                    pendingWeekReview: pendingWeekReview,
                    firedReminderQueue: firedReminderQueue,
                    navigationState: navigationState,
                    morningBriefDispatcher: dispatcher
                )
            }
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
        // Note: NotificationDelegate is attached later, after hema readies and the
        // morning-brief dispatcher exists. Until then, notification taps are dropped —
        // acceptable because the polling timer also hasn't started yet.
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

    /// Branches between day and week review sheets based on which pending state has a
    /// value. Day takes precedence if both somehow set (shouldn't happen — different
    /// fire schedules — but the binding sequence handles it cleanly).
    @ViewBuilder
    private var reviewSheetContent: some View {
        if let dayAction = pendingDayReview.actionToPresent,
           case .ready(let hema) = hemaState,
           let svc = scheduledActionService {
            DayReviewSheet(
                viewModel: DayReviewViewModel(
                    action: dayAction,
                    modelContainer: sharedModelContainer,
                    hema: hema,
                    scheduledActionService: svc
                ),
                dismiss: { pendingDayReview.actionToPresent = nil }
            )
        } else if let weekAction = pendingWeekReview.actionToPresent,
                  case .ready(let hema) = hemaState,
                  let svc = scheduledActionService {
            WeekReviewSheet(
                viewModel: WeekReviewViewModel(
                    action: weekAction,
                    modelContainer: sharedModelContainer,
                    hema: hema,
                    scheduledActionService: svc,
                    compactMemoryGenerator: compactMemoryGenerator
                ),
                dismiss: { pendingWeekReview.actionToPresent = nil }
            )
        }
    }

    @ViewBuilder
    private var reminderBannerStack: some View {
        VStack(spacing: 8) {
            ForEach(firedReminderQueue.visibleReminders) { reminder in
                ReminderBannerView(
                    reminder: reminder,
                    onMarkDone: { Task { @MainActor in await markReminderDone(reminder) } },
                    onPostpone1h: { Task { @MainActor in await postponeReminder(reminder, by: 3600) } },
                    onSnooze10m: { Task { @MainActor in await postponeReminder(reminder, by: 600) } }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 12)
        .animation(.easeOut(duration: 0.25), value: firedReminderQueue.visibleReminders.map(\.id))
        .allowsHitTesting(!firedReminderQueue.visibleReminders.isEmpty)
    }

    @MainActor
    private func markReminderDone(_ reminder: FiredReminderQueue.FiredReminder) async {
        guard let svc = scheduledActionService else { return }
        let elapsed = Date().timeIntervalSince(reminder.firedAt)
        _ = try? await svc.markCompleted(actionID: reminder.id, userResponseTime: elapsed)
        firedReminderQueue.dismiss(id: reminder.id)
    }

    @MainActor
    private func postponeReminder(_ reminder: FiredReminderQueue.FiredReminder, by interval: TimeInterval) async {
        guard let svc = scheduledActionService else { return }
        _ = try? await svc.postpone(actionID: reminder.id, by: interval, reason: "user-banner-postpone")
        firedReminderQueue.dismiss(id: reminder.id)
    }

    @MainActor
    private func refreshStaleReminders() async {
        guard let svc = scheduledActionService else { return }
        await firedReminderQueue.enqueueAllStaleUserReminders(service: svc)
    }

    @MainActor
    private func startPollingIfNeeded() {
        guard pollingTimer == nil, let service = scheduledActionService else { return }
        // Catch any backlog accumulated while the app was closed.
        Task { @MainActor in
            await service.processOverdue()
            await dispatchFiringMorningBriefs()
        }
        // 5-minute foreground polling per Phase 3 decision. Also drives the live
        // calendar snapshot refresh (4.1) — same tick, sequential calls inside
        // the same Task so we don't add a parallel Timer.
        let calendarService = snapshotCalendarService
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                await service.processOverdue()
                await dispatchFiringMorningBriefs()
                await calendarService.refreshAndWriteSnapshot()
            }
        }
    }

    /// One-shot at app launch: write both the calendar snapshot and the todos
    /// snapshot so the very first widget render after a cold start has data.
    /// Each writer also calls WidgetCenter.reloadAllTimelines so the widget
    /// picks the new state up on its next provider tick.
    @MainActor
    private func writeInitialSnapshots() async {
        await snapshotCalendarService.refreshAndWriteSnapshot()
        TodosSnapshotWriter.writeFromStore(sharedModelContainer)
    }

    @MainActor
    private func dispatchFiringMorningBriefs() async {
        guard let dispatcher = morningBriefDispatcher else { return }
        await dispatcher.dispatchAllFiring()
    }
}
