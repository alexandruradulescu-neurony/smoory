import SwiftUI

struct CreateScheduledActionEditView: View {
    let parametersJSON: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var content: String = ""
    @State private var scheduledFor: Date = Date().addingTimeInterval(3600)
    @State private var didLoad: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Reminder", text: $content)
                .textFieldStyle(.roundedBorder)
                .font(.smoory_body)

            DatePicker(
                "When",
                selection: $scheduledFor,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .font(.smoory_body)

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(content.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            decodeAndPrefill()
        }
    }

    private func decodeAndPrefill() {
        guard let input = try? CreateScheduledActionTool.decodeInput(parametersJSON) else {
            return
        }
        content = input.content
        if let parsed = CreateScheduledActionTool.parseISO8601(input.scheduled_for), parsed > Date() {
            scheduledFor = parsed
        }
        // Natural-language fallthrough: leave the picker at the default (now+1h).
        // The user adjusts; the resolved time on Save is whatever the picker holds.
    }

    private func commit() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload: [String: Any] = [
            "content": content.trimmingCharacters(in: .whitespacesAndNewlines),
            "scheduled_for": formatter.string(from: scheduledFor)
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{}"
        onCommit(json)
    }
}
