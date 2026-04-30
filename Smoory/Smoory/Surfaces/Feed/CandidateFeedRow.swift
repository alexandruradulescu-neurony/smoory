import SwiftData
import SwiftUI

/// Renders a CandidateWrite as a feed row. Pending rows show inline confirm/edit/reject;
/// confirmed/rejected rows show a status badge and review timestamp.
struct CandidateFeedRow: View {
    @Bindable var candidate: CandidateWrite
    let isExpanded: Bool
    let onToggleExpand: () -> Void
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
                        statusBadge
                    }

                    if isEditing {
                        TextField("Content", text: $draftContent, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                    } else {
                        Text(candidate.effectiveContent)
                            .font(isExpanded ? .body : .callout)
                            .lineLimit(isExpanded ? nil : 1)
                    }

                    if isExpanded || candidate.status != .pending {
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
                        if let reviewed = candidate.reviewedAt, candidate.status != .pending {
                            Text("Reviewed: \(reviewed.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }

            if candidate.status == .pending && (isExpanded || isEditing) {
                actionRow
            }
        }
        .padding(10)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var actionRow: some View {
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

    @ViewBuilder
    private var statusBadge: some View {
        switch candidate.status {
        case .confirmed:
            Label("Confirmed", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .rejected:
            Label("Rejected", systemImage: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
        case .autoApplied:
            Label("Auto-applied", systemImage: "bolt.circle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
        case .pending:
            EmptyView()
        }
    }

    private var rowBackground: Color {
        switch candidate.status {
        case .pending: Color.secondary.opacity(0.06)
        case .confirmed: Color.green.opacity(0.06)
        case .rejected: Color.secondary.opacity(0.03)
        case .autoApplied: Color.orange.opacity(0.06)
        }
    }
}
