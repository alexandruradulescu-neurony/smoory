import SwiftUI

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
    @State private var onboardingFeedback: String?

    @Bindable private var failureCounter = StructuringFailureCounter.shared

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
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(surface.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
