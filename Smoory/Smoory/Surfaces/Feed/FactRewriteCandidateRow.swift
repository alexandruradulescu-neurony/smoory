import SwiftData
import SwiftUI

/// Renders a `.factRewrite` CandidateWrite (4.5) — the day-end restructurer's
/// proposed refine / merge / split / contradict / archive operation. Each
/// operation has a distinct visual treatment so the user can quickly read
/// what's being proposed before deciding.
///
/// All five op types share the same row shell: header (icon + op label +
/// status badge) → before/after content → optional reason → action buttons
/// (when pending). Pending state shows confirm + dismiss; confirmed and
/// rejected states show a status footer.
struct FactRewriteCandidateRow: View {
    @Bindable var candidate: CandidateWrite
    let onConfirm: () -> Void
    let onReject: () -> Void

    private var content: FactRewriteContent? {
        FactRestructurer.decode(candidate.content)
    }

    var body: some View {
        Group {
            if let payload = content {
                VStack(alignment: .leading, spacing: 8) {
                    header(payload: payload)
                    bodyBlock(payload: payload)
                    if let reason = payload.reason, !reason.isEmpty {
                        Text("Reason: \(reason)")
                            .font(.smoory_caption)
                            .foregroundStyle(.tertiary)
                    }
                    switch candidate.status {
                    case .pending:
                        actionRow
                    case .confirmed:
                        statusFooter(text: "Applied")
                    case .rejected:
                        statusFooter(text: "Dismissed")
                    case .autoApplied:
                        EmptyView()
                    }
                }
                .padding(12)
                .background(rowBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                corruptRow
            }
        }
    }

    // MARK: - Header

    private func header(payload: FactRewriteContent) -> some View {
        HStack(spacing: 6) {
            Image(systemName: opIcon(payload.op))
                .foregroundStyle(.purple)
                .font(.caption)
            Text(opLabel(payload.op))
                .font(.smoory_caption)
                .foregroundStyle(.secondary)
            Spacer()
            statusBadge
        }
    }

    private func opIcon(_ op: FactRewriteOp) -> String {
        switch op {
        case .refine: "wand.and.sparkles"
        case .merge: "arrow.triangle.merge"
        case .split: "arrow.triangle.branch"
        case .contradict: "arrow.triangle.2.circlepath"
        case .archive: "archivebox"
        }
    }

    private func opLabel(_ op: FactRewriteOp) -> String {
        switch op {
        case .refine: "Refine fact"
        case .merge: "Merge facts"
        case .split: "Split fact"
        case .contradict: "Replace fact (today's evidence)"
        case .archive: "Archive fact"
        }
    }

    // MARK: - Body block (op-specific)

    @ViewBuilder
    private func bodyBlock(payload: FactRewriteContent) -> some View {
        switch payload.op {
        case .refine, .contradict:
            beforeAfterBlock(
                oldBodies: payload.oldBodies,
                newBodies: payload.newBodies
            )
        case .merge:
            mergeBlock(
                oldBodies: payload.oldBodies,
                newBody: payload.newBodies.first ?? ""
            )
        case .split:
            splitBlock(
                oldBody: payload.oldBodies.first ?? "",
                newBodies: payload.newBodies
            )
        case .archive:
            archiveBlock(oldBody: payload.oldBodies.first ?? "")
        }
    }

    private func beforeAfterBlock(oldBodies: [String], newBodies: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BEFORE")
                    .font(.smoory_micro)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Text(oldBodies.first ?? "")
                    .font(.smoory_body)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("AFTER")
                    .font(.smoory_micro)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Text(newBodies.first ?? "")
                    .font(.smoory_body)
            }
        }
    }

    private func mergeBlock(oldBodies: [String], newBody: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MERGING")
                    .font(.smoory_micro)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                ForEach(Array(oldBodies.enumerated()), id: \.offset) { _, body in
                    Text("• \(body)")
                        .font(.smoory_body)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("INTO")
                    .font(.smoory_micro)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Text(newBody)
                    .font(.smoory_body)
            }
        }
    }

    private func splitBlock(oldBody: String, newBodies: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SPLITTING")
                    .font(.smoory_micro)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Text(oldBody)
                    .font(.smoory_body)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("INTO")
                    .font(.smoory_micro)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                ForEach(Array(newBodies.enumerated()), id: \.offset) { _, body in
                    Text("• \(body)")
                        .font(.smoory_body)
                }
            }
        }
    }

    private func archiveBlock(oldBody: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ARCHIVING")
                .font(.smoory_micro)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(oldBody)
                .font(.smoory_body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Action row + footers

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button("Apply", action: onConfirm)
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)
            Button("Keep as-is", action: onReject)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Spacer()
            Button(role: .cancel, action: onReject) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private func statusFooter(text: String) -> some View {
        HStack {
            Text(text)
                .font(.smoory_caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let reviewedAt = candidate.reviewedAt {
                Text(reviewedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.smoory_micro)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch candidate.status {
        case .pending:
            EmptyView()
        case .confirmed:
            Label("Applied", systemImage: "checkmark.circle.fill")
                .font(.smoory_micro)
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .rejected:
            Label("Dismissed", systemImage: "xmark.circle.fill")
                .font(.smoory_micro)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
        case .autoApplied:
            EmptyView()
        }
    }

    private var rowBackground: Color {
        switch candidate.status {
        case .pending: Color.purple.opacity(0.08)
        case .confirmed: Color.green.opacity(0.06)
        case .rejected: Color.secondary.opacity(0.04)
        case .autoApplied: Color.secondary.opacity(0.06)
        }
    }

    private var corruptRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Couldn't render refinement proposal")
                    .font(.smoory_caption)
                    .foregroundStyle(.secondary)
            }
            Text("Content failed to decode. Reject to dismiss.")
                .font(.smoory_micro)
                .foregroundStyle(.tertiary)
            Button("Reject", role: .destructive, action: onReject)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
