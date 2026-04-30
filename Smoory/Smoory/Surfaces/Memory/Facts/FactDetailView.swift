import SwiftUI

struct FactDetailView: View {
    let fact: SemanticFact
    let viewModel: FactsListViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var editedBody: String
    @State private var editedTags: [String]
    @State private var editedConfidence: Double
    @State private var editedUserConfirmed: Bool
    @State private var editedIsPrivate: Bool
    @State private var hasExpiresAt: Bool
    @State private var editedExpiresAt: Date

    init(fact: SemanticFact, viewModel: FactsListViewModel) {
        self.fact = fact
        self.viewModel = viewModel
        _editedBody = State(initialValue: fact.body)
        _editedTags = State(initialValue: fact.tags)
        _editedConfidence = State(initialValue: fact.confidence)
        _editedUserConfirmed = State(initialValue: fact.userConfirmed)
        _editedIsPrivate = State(initialValue: fact.isPrivate)
        _hasExpiresAt = State(initialValue: fact.expiresAt != nil)
        _editedExpiresAt = State(initialValue: fact.expiresAt ?? Date().addingTimeInterval(86400 * 30))
    }

    var body: some View {
        Form {
            Section("Body") {
                TextEditor(text: $editedBody)
                    .frame(minHeight: 70)
            }

            Section("Tags") {
                TagEditor(tags: $editedTags)
            }

            Section("Properties") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Confidence: \(Int((editedConfidence * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $editedConfidence, in: 0...1, step: 0.05)
                }
                Toggle("User confirmed", isOn: $editedUserConfirmed)
                Toggle("Private (excluded from API context)", isOn: $editedIsPrivate)
                Toggle("Has expiration", isOn: $hasExpiresAt)
                if hasExpiresAt {
                    DatePicker("Expires", selection: $editedExpiresAt, displayedComponents: [.date])
                }
            }

            Section("Provenance") {
                ProvenanceView(provenanceJSON: fact.provenanceJSON, createdAt: fact.createdAt)
            }

            if hasChanges {
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        Text("Save changes")
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }

            Section {
                ConfirmDeleteButton(title: "Delete this fact") {
                    Task { await delete() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Fact")
        .navigationSubtitle(fact.createdAt.formatted(.dateTime.month(.abbreviated).day().year()))
    }

    private var hasChanges: Bool {
        editedBody != fact.body
            || editedTags != fact.tags
            || editedConfidence != fact.confidence
            || editedUserConfirmed != fact.userConfirmed
            || editedIsPrivate != fact.isPrivate
            || hasExpiresAt != (fact.expiresAt != nil)
            || (hasExpiresAt && fact.expiresAt.map { !Calendar.current.isDate($0, inSameDayAs: editedExpiresAt) } ?? false)
    }

    private func save() async {
        let updated = SemanticFact(
            id: fact.id,
            body: editedBody,
            tags: editedTags,
            entitiesReferenced: fact.entitiesReferenced,
            confidence: editedConfidence,
            userConfirmed: editedUserConfirmed,
            createdAt: fact.createdAt,
            expiresAt: hasExpiresAt ? editedExpiresAt : nil,
            supersededBy: fact.supersededBy,
            provenanceJSON: fact.provenanceJSON,
            vector: fact.vector,
            isPrivate: editedIsPrivate
        )
        await viewModel.updateFact(updated)
        dismiss()
    }

    private func delete() async {
        await viewModel.deleteFact(id: fact.id)
        dismiss()
    }
}

/// Two-tap confirm with a 3-second arming window. Visual countdown via TimelineView.
struct ConfirmDeleteButton: View {
    let title: String
    let onConfirm: () -> Void

    @State private var armedAt: Date? = nil
    @State private var resetTask: Task<Void, Never>? = nil

    private static let armDuration: TimeInterval = 3.0

    var body: some View {
        Button(role: .destructive) {
            if armedAt != nil {
                onConfirm()
                armedAt = nil
                resetTask?.cancel()
            } else {
                armedAt = Date()
                resetTask?.cancel()
                resetTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Self.armDuration * 1_000_000_000))
                    armedAt = nil
                }
            }
        } label: {
            if let started = armedAt {
                TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                    let elapsed = ctx.date.timeIntervalSince(started)
                    let remaining = max(0, Self.armDuration - elapsed)
                    let progress = remaining / Self.armDuration
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 60)
                        Text("Tap again to confirm")
                            .foregroundStyle(.red)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                Label(title, systemImage: "trash")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderless)
    }
}
