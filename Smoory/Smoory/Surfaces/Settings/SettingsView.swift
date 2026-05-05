import EventKit
import SwiftData
import SwiftUI
import UserNotifications

struct SettingsView: View {
    private let surface: Surface = .settings

    @State private var anthropicVM = APIKeyViewModel(
        service: KeychainService.anthropicAPIKeyService,
        providerLabel: "Anthropic",
        placeholder: "sk-ant-…"
    )
    @State private var deepseekVM = APIKeyViewModel(
        service: KeychainService.deepseekAPIKeyService,
        providerLabel: "DeepSeek",
        placeholder: "sk-…"
    )
    @State private var voyageVM = APIKeyViewModel(
        service: KeychainService.voyageAPIKeyService,
        providerLabel: "Voyage",
        placeholder: "pa-…"
    )
    @State private var providerVM = ProviderViewModel()

    @Environment(\.chatViewModel) private var chatViewModel
    @Environment(\.scheduledActionService) private var scheduledActionService
    @Environment(\.remindersSyncService) private var remindersSyncService
    @Environment(\.modelContext) private var modelContext
    @State private var onboardingFeedback: String?
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @AppStorage(RemindersSyncService.enabledDefaultsKey) private var remindersSyncEnabled: Bool = false
    @State private var remindersAuthStatus: EKAuthorizationStatus = .notDetermined
    @State private var isSyncingReminders: Bool = false
    @State private var lastReminderSyncSummary: String?
    @State private var permissionAlertContent: PermissionAlertContent?
    // F-17 audit fix: the three review-schedule VMs used to be `@State var ...?`
    // initialized lazily in `.onAppear`. Toggles flickered as briefly disabled on
    // rapid Settings re-entry while VMs constructed. They now live inside
    // ReviewScheduleSettings, which receives modelContainer + service via init
    // and constructs them eagerly with `_dayReviewVM = State(wrappedValue: ...)`.

    @Bindable private var failureCounter = StructuringFailureCounter.shared
    @Bindable private var briefFailureCounter = MorningBriefFailureCounter.shared
    @Bindable private var patternFailureCounter = PatternAnalyzerFailureCounter.shared
    @Bindable private var compactMemoryFailureCounter = CompactMemoryFailureCounter.shared
    @Bindable private var contradictionDetectionFailureCounter = ContradictionDetectionFailureCounter.shared
    @Bindable private var batchedExtractionFailureCounter = BatchedExtractionFailureCounter.shared
    @Bindable private var batchedExtractionSkippedCounter = BatchedExtractionSkippedCounter.shared
    @Bindable private var factRestructuringFailureCounter = FactRestructuringFailureCounter.shared

    var body: some View {
        Form {
            Section("AI provider") {
                Picker("Provider", selection: $providerVM.selected) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)

                if providerVM.selected == .anthropic {
                    APIKeySectionContent(viewModel: anthropicVM)
                } else {
                    APIKeySectionContent(viewModel: deepseekVM)
                }

                HStack {
                    Button {
                        // @MainActor-explicit so the VM mutation runs on main even if
                        // the SwiftUI lifecycle hook doesn't propagate the actor.
                        Task { @MainActor in await providerVM.testConnection() }
                    } label: {
                        if providerVM.isTestingConnection {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Testing…")
                            }
                        } else {
                            Text("Test connection (current provider)")
                        }
                    }
                    .disabled(providerVM.isTestingConnection)
                    Spacer()
                }
                if let result = providerVM.lastTestResult {
                    Text(result.message)
                        .font(.smoory_caption)
                        .foregroundStyle(result.success ? Color.green : Color.red)
                }
            }

            Section("Voyage API key") {
                APIKeySectionContent(viewModel: voyageVM)
            }

            ReviewScheduleSettings(
                modelContainer: modelContext.container,
                service: scheduledActionService
            )

            Section("Notifications") {
                HStack {
                    Image(systemName: notificationStatus == .authorized ? "bell.fill" : "bell.slash")
                        .foregroundStyle(notificationStatus == .authorized ? .green : .secondary)
                    Text(notificationStatusText)
                        .font(.smoory_body)
                    Spacer()
                }
                if notificationStatus != .authorized {
                    Text("Enable in System Settings → Notifications → Smoory.")
                        .font(.smoory_caption)
                        .foregroundStyle(.tertiary)
                }
            }

            remindersSyncSection

            timeOffSection

            Section("Onboarding") {
                HStack {
                    Button("Restart onboarding") {
                        chatViewModel?.startOnboarding()
                        OnboardingStateStore.set(.inProgress)
                        onboardingFeedback = "Onboarding restarted. Open Chat to continue."
                    }
                    .disabled(chatViewModel == nil)
                    Spacer()
                }
                if let onboardingFeedback {
                    Text(onboardingFeedback)
                        .font(.smoory_caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Diagnostics") {
                HStack {
                    Text("Structuring failures since launch")
                    Spacer()
                    Text("\(failureCounter.count)")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
                if failureCounter.count > 0 {
                    Text("Failures occur when the AI provider returns malformed JSON. If this number grows fast, consider switching providers or refining the structuring prompt.")
                        .font(.smoory_caption)
                        .foregroundStyle(.tertiary)
                }

                HStack {
                    Text("Morning brief failures since launch")
                    Spacer()
                    Text("\(briefFailureCounter.count)")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
                if briefFailureCounter.count > 0 {
                    Text("A failed brief retries once with a stricter prompt; persistent failures are usually JSON-format drift from the active provider.")
                        .font(.smoory_caption)
                        .foregroundStyle(.tertiary)
                }

                HStack {
                    Text("Pattern analyzer failures since launch")
                    Spacer()
                    Text("\(patternFailureCounter.count)")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }

                HStack {
                    Text("Compact memory failures since launch")
                    Spacer()
                    Text("\(compactMemoryFailureCounter.count)")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
                if compactMemoryFailureCounter.count > 0 {
                    Text("Failures cover compact memory regeneration: LLM errors, parse failures, and out-of-bounds word counts after retry. The previous active compact memory of that kind stays in place when regeneration fails.")
                        .font(.smoory_caption)
                        .foregroundStyle(.tertiary)
                }

                HStack {
                    Text("Contradiction detection failures since launch")
                    Spacer()
                    Text("\(contradictionDetectionFailureCounter.count)")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
                if contradictionDetectionFailureCounter.count > 0 {
                    Text("Failures cover LLM errors, parse failures, and timeouts during contradiction detection. The fact still lands when detection fails — only the supersession candidate doesn't appear.")
                        .font(.smoory_caption)
                        .foregroundStyle(.tertiary)
                }

                HStack {
                    Text("Batched extraction failures since launch")
                    Spacer()
                    Text("\(batchedExtractionFailureCounter.count)")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
                if batchedExtractionFailureCounter.count > 0 {
                    Text("Failures cover salience LLM errors, extraction LLM errors, and parse failures in the batched fact extractor. The chat continues normally; only Feed candidates don't appear for that window.")
                        .font(.smoory_caption)
                        .foregroundStyle(.tertiary)
                }

                HStack {
                    Text("Batched extraction skipped (no salience)")
                    Spacer()
                    Text("\(batchedExtractionSkippedCounter.count)")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
                if batchedExtractionSkippedCounter.count > 0 {
                    Text("Windows the salience gate decided weren't memory-worthy. High counts may indicate the gate is too strict; very low counts may indicate it's too lenient.")
                        .font(.smoory_caption)
                        .foregroundStyle(.tertiary)
                }

                HStack {
                    Text("Fact restructurer failures since launch")
                    Spacer()
                    Text("\(factRestructuringFailureCounter.count)")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
                if factRestructuringFailureCounter.count > 0 {
                    Text("Failures cover LLM errors and parse failures during day-end fact restructuring. The day review summary still persists when restructuring fails — only the refinement proposals don't appear.")
                        .font(.smoory_caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(surface.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // @MainActor-explicit — refreshNotificationStatus mutates @State.
            Task { @MainActor in await refreshNotificationStatus() }
            refreshRemindersAuthStatus()
        }
    }

    // MARK: - Time off section (4.9)

    @ViewBuilder
    private var timeOffSection: some View {
        TimeOffSettingsSection(modelContainer: modelContext.container)
    }

    // MARK: - Reminders sync section (4.7)

    @ViewBuilder
    private var remindersSyncSection: some View {
        Section("Reminders sync") {
            Toggle("Sync lists with Reminders.app", isOn: $remindersSyncEnabled)
                .onChange(of: remindersSyncEnabled) { _, newValue in
                    handleRemindersToggle(newValue)
                }

            HStack {
                Image(systemName: remindersStatusIcon)
                    .foregroundStyle(remindersStatusColor)
                Text(remindersStatusText)
                    .font(.smoory_body)
                Spacer()
            }

            if let summary = lastReminderSyncSummary {
                Text(summary)
                    .font(.smoory_caption)
                    .foregroundStyle(.secondary)
            }

            if remindersSyncEnabled, remindersAuthStatus == .fullAccess {
                HStack {
                    Button {
                        // @MainActor-explicit — runRemindersSyncNow mutates @State props.
                        Task { @MainActor in await runRemindersSyncNow() }
                    } label: {
                        if isSyncingReminders {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Syncing…")
                            }
                        } else {
                            Text("Sync now")
                        }
                    }
                    .disabled(isSyncingReminders)
                    Spacer()
                }
            }

            if remindersAuthStatus == .denied || remindersAuthStatus == .restricted {
                Text("Reminders access denied. Enable in System Settings → Privacy & Security → Reminders, then reopen Smoory.")
                    .font(.smoory_caption)
                    .foregroundStyle(.tertiary)
            } else if remindersSyncEnabled, remindersAuthStatus == .fullAccess {
                Text("Smoory's checklist-kind lists round-trip with Reminders.app. Notes-kind lists stay local. Last-writer-wins on conflicts.")
                    .font(.smoory_caption)
                    .foregroundStyle(.tertiary)
            } else if !remindersSyncEnabled {
                Text("Off by default. Enabling will request Reminders access and import every existing Reminders list as a Smoory list on first sync.")
                    .font(.smoory_caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .alert(
            permissionAlertContent?.title ?? "",
            isPresented: permissionAlertBinding,
            presenting: permissionAlertContent
        ) { content in
            if content.showOpenSettingsButton {
                Button("Open System Settings") { openRemindersPrivacySettings() }
            }
            Button("OK", role: .cancel) {}
        } message: { content in
            Text(content.message)
        }
    }

    private var permissionAlertBinding: Binding<Bool> {
        Binding(
            get: { permissionAlertContent != nil },
            set: { if !$0 { permissionAlertContent = nil } }
        )
    }

    private var remindersStatusIcon: String {
        switch remindersAuthStatus {
        case .fullAccess: return remindersSyncEnabled ? "arrow.triangle.2.circlepath.circle.fill" : "circle"
        case .denied, .restricted: return "exclamationmark.triangle"
        case .notDetermined: return "questionmark.circle"
        case .writeOnly: return "pencil.circle"
        @unknown default: return "questionmark.circle"
        }
    }

    private var remindersStatusColor: Color {
        switch remindersAuthStatus {
        case .fullAccess: return remindersSyncEnabled ? .green : .secondary
        case .denied, .restricted: return .orange
        case .notDetermined, .writeOnly: return .secondary
        @unknown default: return .secondary
        }
    }

    private var remindersStatusText: String {
        switch remindersAuthStatus {
        case .fullAccess:
            return remindersSyncEnabled ? "Authorized — sync active" : "Authorized — sync paused"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Permission will be requested"
        case .writeOnly: return "Write-only access (insufficient — sync needs full access)"
        @unknown default: return "Unknown"
        }
    }

    private func refreshRemindersAuthStatus() {
        remindersAuthStatus = EKEventStore.authorizationStatus(for: .reminder)
    }

    private func handleRemindersToggle(_ newValue: Bool) {
        guard let svc = remindersSyncService else { return }
        if newValue {
            Task { @MainActor in
                let status = await svc.requestPermission()
                remindersAuthStatus = status
                switch status {
                case .fullAccess:
                    svc.startObserving()
                    await runRemindersSyncNow()
                case .writeOnly:
                    // macOS Sequoia tier — sync needs read too. Surface explicitly so the
                    // user understands why the toggle reverted; offer a System Settings
                    // shortcut so they can grant full access in one click.
                    remindersSyncEnabled = false
                    permissionAlertContent = PermissionAlertContent(
                        title: "Reminders access is partial",
                        message: "macOS granted Smoory write-only access. Sync needs to read your Reminders too. Open System Settings → Privacy & Security → Reminders and toggle Smoory to full access, then re-enable the sync.",
                        showOpenSettingsButton: true
                    )
                case .denied, .restricted:
                    remindersSyncEnabled = false
                    permissionAlertContent = PermissionAlertContent(
                        title: "Reminders access denied",
                        message: "Smoory can't sync without Reminders access. Open System Settings → Privacy & Security → Reminders and toggle Smoory on, then re-enable the sync here.",
                        showOpenSettingsButton: true
                    )
                case .notDetermined:
                    // Request returned without a decision — odd but possible if the prompt
                    // was dismissed with no selection. Revert and surface a soft message.
                    remindersSyncEnabled = false
                    permissionAlertContent = PermissionAlertContent(
                        title: "Permission not granted",
                        message: "The system permission prompt was dismissed without a decision. Try the toggle again.",
                        showOpenSettingsButton: false
                    )
                @unknown default:
                    remindersSyncEnabled = false
                    permissionAlertContent = PermissionAlertContent(
                        title: "Reminders access unavailable",
                        message: "EventKit returned an unrecognized authorization state. Try opening System Settings → Privacy & Security → Reminders to inspect Smoory's access.",
                        showOpenSettingsButton: true
                    )
                }
            }
        } else {
            svc.stopObserving()
            lastReminderSyncSummary = nil
        }
    }

    /// Opens System Settings on the Reminders privacy pane. Falls back to the top-level
    /// Privacy & Security pane if the deep link is unavailable.
    private func openRemindersPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private func runRemindersSyncNow() async {
        guard let svc = remindersSyncService else { return }
        isSyncingReminders = true
        defer { isSyncingReminders = false }
        do {
            let report = try await svc.syncNow()
            lastReminderSyncSummary = "Last sync: \(report.summary)"
            if !report.errors.isEmpty {
                lastReminderSyncSummary! += " (\(report.errors.count) error(s); see Console)"
                for err in report.errors { print("[reminders] \(err)") }
            }
        } catch {
            lastReminderSyncSummary = "Last sync failed: \(error.localizedDescription)"
        }
    }

    private var notificationStatusText: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: "Notifications: enabled"
        case .denied:                                "Notifications: disabled"
        case .notDetermined:                         "Notifications: not determined"
        @unknown default:                            "Notifications: unknown state"
        }
    }

    @MainActor
    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus
    }
}

/// Payload for the Reminders-permission alert. Wrapped in a struct so the alert(_:_:_:)
/// presenting-binding can drive the destructive button label conditionally.
private struct PermissionAlertContent: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let showOpenSettingsButton: Bool
}

/// F-17 audit fix: review-schedule VMs (day / morning brief / week) used to live as
/// `@State var ...?` on SettingsView and were lazily initialized in `.onAppear`. On
/// rapid Settings re-entry the toggles flickered briefly disabled while construction
/// raced the first body draw. This wrapper takes the env-derived dependencies via
/// `init(...)` and constructs the three VMs eagerly via `_xxxVM = State(wrappedValue:)`,
/// so the sections render fully populated on the very first paint.
private struct ReviewScheduleSettings: View {
    @State private var dayReviewVM: DayReviewSettingsViewModel
    @State private var morningBriefVM: MorningBriefSettingsViewModel
    @State private var weekReviewVM: WeekReviewSettingsViewModel

    init(modelContainer: ModelContainer, service: ScheduledActionService?) {
        _dayReviewVM = State(wrappedValue: DayReviewSettingsViewModel(
            modelContainer: modelContainer,
            service: service
        ))
        _morningBriefVM = State(wrappedValue: MorningBriefSettingsViewModel(
            modelContainer: modelContainer,
            service: service
        ))
        _weekReviewVM = State(wrappedValue: WeekReviewSettingsViewModel(
            modelContainer: modelContainer,
            service: service
        ))
    }

    var body: some View {
        Group {
            dayReviewSection
            morningBriefSection
            weekReviewSection
        }
    }

    @ViewBuilder
    private var dayReviewSection: some View {
        @Bindable var vm = dayReviewVM
        Section("Day review") {
            Toggle("Enable evening day review", isOn: $vm.dayReviewEnabled)
            if vm.dayReviewEnabled {
                DatePicker(
                    "Time",
                    selection: $vm.dayReviewTime,
                    displayedComponents: [.hourAndMinute]
                )
                Text("Smoory will check in at this time each evening to reflect on the day.")
                    .font(.smoory_caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var morningBriefSection: some View {
        @Bindable var vm = morningBriefVM
        Section("Morning brief") {
            Toggle("Enable morning brief", isOn: $vm.morningBriefEnabled)
            if vm.morningBriefEnabled {
                DatePicker(
                    "Time",
                    selection: $vm.morningBriefTime,
                    displayedComponents: [.hourAndMinute]
                )
                Text("Smoory will prepare a daily focus brief at this time. Allow ~30s for generation.")
                    .font(.smoory_caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var weekReviewSection: some View {
        @Bindable var vm = weekReviewVM
        Section("Week review") {
            Toggle("Enable weekly review", isOn: $vm.weekReviewEnabled)
            if vm.weekReviewEnabled {
                Picker("Day", selection: $vm.weekReviewDayOfWeek) {
                    ForEach(1...7, id: \.self) { day in
                        Text(WeekReviewSettingsViewModel.weekdayName(day)).tag(day)
                    }
                }
                DatePicker(
                    "Time",
                    selection: $vm.weekReviewTime,
                    displayedComponents: [.hourAndMinute]
                )
                Text("Smoory will check in once a week to reflect on patterns and progress.")
                    .font(.smoory_caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct APIKeySectionContent: View {
    @Bindable var viewModel: APIKeyViewModel

    var body: some View {
        if viewModel.hasKey && !viewModel.isReplacing {
            HStack {
                Label("Configured", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Replace key") { viewModel.beginReplace() }
                Button("Clear", role: .destructive) { viewModel.clear() }
            }
        } else {
            SecureField(viewModel.placeholder, text: $viewModel.draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { viewModel.save() }
            HStack {
                if viewModel.isReplacing {
                    Button("Cancel") { viewModel.cancelReplace() }
                }
                Spacer()
                Button("Save") { viewModel.save() }
                    .disabled(viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }

        if let feedback = viewModel.feedback {
            Text(feedback)
                .font(.smoory_caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView()
}
