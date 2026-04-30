import SwiftData
import SwiftUI

struct CandidatesSheet: View {
    let hema: HemaService
    let onDone: () -> Void

    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<CandidateWrite> { $0.statusRaw == 0 },
        sort: \CandidateWrite.createdAt,
        order: .reverse
    )
    private var pending: [CandidateWrite]

    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pending candidates")
                    .font(.headline)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            if pending.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(pending) { candidate in
                        CandidateCard(
                            candidate: candidate,
                            onConfirm: { Task { await confirm(candidate) } },
                            onReject: { Task { await reject(candidate) } }
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                    }
                }
                .listStyle(.inset)
            }

            if let err = actionError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("No pending candidates").font(.headline).foregroundStyle(.secondary)
            Text("As you chat, Smoory will surface candidate goals, todos, facts, and more here.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func confirm(_ candidate: CandidateWrite) async {
        do {
            try await CandidateAcceptor.accept(
                candidate: candidate,
                modelContainer: modelContext.container,
                hema: hema
            )
            actionError = nil
        } catch {
            actionError = "Could not accept candidate: \(error.localizedDescription)"
        }
    }

    private func reject(_ candidate: CandidateWrite) async {
        do {
            try CandidateAcceptor.reject(
                candidate: candidate,
                modelContainer: modelContext.container
            )
            actionError = nil
        } catch {
            actionError = "Could not reject candidate: \(error.localizedDescription)"
        }
    }
}

private struct CandidateCard: View {
    @Bindable var candidate: CandidateWrite
    let onConfirm: () -> Void
    let onReject: () -> Void

    @State private var isEditing: Bool = false
    @State private var draftContent: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: candidate.type.icon)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(candidate.type.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(Int((candidate.confidence * 100).rounded()))%")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }

                    if isEditing {
                        TextField("Content", text: $draftContent, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                    } else {
                        Text(candidate.effectiveContent)
                            .font(.body)
                    }

                    if !candidate.userPhrase.isEmpty {
                        Text("User said: \"\(candidate.userPhrase)\"")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if let exp = candidate.expiresAt {
                        Text("Expires: \(exp.formatted(.dateTime.month(.abbreviated).day().year()))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: 8) {
                if isEditing {
                    Button("Save edit") {
                        candidate.editedContent = draftContent
                        isEditing = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Cancel", role: .cancel) {
                        isEditing = false
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                } else {
                    Button("Confirm", action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Edit") {
                        draftContent = candidate.effectiveContent
                        isEditing = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                    Button("Reject", role: .destructive, action: onReject)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
