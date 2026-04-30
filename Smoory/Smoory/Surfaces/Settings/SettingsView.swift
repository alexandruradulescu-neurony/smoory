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
    @Environment(\.modelContext) private var modelContext
    @State private var onboardingFeedback: String?
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var dayReviewVM: DayReviewSettingsViewModel?
    @State private var morningBriefVM: MorningBriefSettingsViewModel?

    @Bindable private var failureCounter = StructuringFailureCounter.shared
    @Bindable private var briefFailureCounter = MorningBriefFailureCounter.shared

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
                        Task { await providerVM.testConnection() }
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

            if let dayReviewVM {
                dayReviewSection(viewModel: dayReviewVM)
            }

            if let morningBriefVM {
                morningBriefSection(viewModel: morningBriefVM)
            }

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
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(surface.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            Task { await refreshNotificationStatus() }
            if dayReviewVM == nil {
                dayReviewVM = DayReviewSettingsViewModel(
                    modelContainer: modelContext.container,
                    service: scheduledActionService
                )
            }
            if morningBriefVM == nil {
                morningBriefVM = MorningBriefSettingsViewModel(
                    modelContainer: modelContext.container,
                    service: scheduledActionService
                )
            }
        }
    }

    @ViewBuilder
    private func morningBriefSection(viewModel: MorningBriefSettingsViewModel) -> some View {
        @Bindable var vm = viewModel
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
    private func dayReviewSection(viewModel: DayReviewSettingsViewModel) -> some View {
        @Bindable var vm = viewModel
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
