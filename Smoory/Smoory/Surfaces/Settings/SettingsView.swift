import SwiftUI

struct SettingsView: View {
    private let surface: Surface = .settings

    @State private var anthropicVM = APIKeyViewModel(
        service: KeychainService.anthropicAPIKeyService,
        providerLabel: "Anthropic",
        placeholder: "sk-ant-…"
    )
    @State private var voyageVM = APIKeyViewModel(
        service: KeychainService.voyageAPIKeyService,
        providerLabel: "Voyage",
        placeholder: "pa-…"
    )

    var body: some View {
        Form {
            Section("Anthropic API key") {
                APIKeySectionContent(viewModel: anthropicVM)
            }
            Section("Voyage API key") {
                APIKeySectionContent(viewModel: voyageVM)
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
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView()
}
