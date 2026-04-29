import SwiftUI

struct SettingsView: View {
    private let surface: Surface = .settings
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        Form {
            Section("Anthropic API key") {
                if viewModel.hasKey && !viewModel.isReplacing {
                    HStack {
                        Label("Configured", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Replace key") {
                            viewModel.beginReplace()
                        }
                        Button("Clear", role: .destructive) {
                            viewModel.clear()
                        }
                    }
                } else {
                    SecureField("sk-ant-…", text: $viewModel.draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { viewModel.save() }
                    HStack {
                        if viewModel.isReplacing {
                            Button("Cancel") { viewModel.cancelReplace() }
                        }
                        Spacer()
                        Button("Save") { viewModel.save() }
                            .disabled(viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .keyboardShortcut(.defaultAction)
                    }
                }

                if let feedback = viewModel.feedback {
                    Text(feedback)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(surface.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

#Preview {
    SettingsView()
}
