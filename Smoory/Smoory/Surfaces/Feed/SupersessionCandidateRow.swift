import SwiftData
import SwiftUI

/// Renders a `.supersession` CandidateWrite as a side-by-side comparison of
/// the existing (older) fact and the new fact, with confirm / "Both true" /
/// dismiss actions. Three states:
///
/// - `.pending`   — orange-tinted warning background; action buttons visible.
/// - `.confirmed` — green-tinted; "Old fact superseded" footer.
/// - `.rejected`  — secondary-tinted; "Marked as both true" footer.
///
/// Falls back to a corruption-safe row if the JSON content fails to decode.
/// The candidate stays in Feed in that case so the user can dismiss it; we
/// don't silently delete a row whose content didn't round-trip.
struct SupersessionCandidateRow: View {
    @Bindable var candidate: CandidateWrite
    let onConfirm: () -> Void
    let onReject: () -> Void

    private var content: SupersessionContent? {
        SupersessionCandidateBuilder.decode(candidate.content)
    }

    var body: some View {
        Group {
            if let payload = content {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    factBlock(label: "EXISTING (older)", body: payload.oldFactBody, savedAt: payload.oldFactCreatedAt)
                    factBlock(label: "NEW", body: payload.newFactBody, savedAt: payload.newFactCreatedAt)

                    switch candidate.status {
                    case .pending:
                        Text("Replace old with new?")
                            .font(.smoory_caption)
                            .foregroundStyle(.secondary)
                        actionRow
                    case .confirmed:
                        statusFooter(text: "Old fact superseded")
                    case .rejected:
                        statusFooter(text: "Marked as both true")
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

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text("Possible contradiction")
                .font(.smoory_caption)
                .foregroundStyle(.secondary)
            Spacer()
            statusBadge
        }
    }

    // MARK: - Fact block

    private func factBlock(label: String, body: String, savedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.smoory_micro)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(body)
                .font(.smoory_body)
                .foregroundStyle(candidate.status == .rejected ? .secondary : .primary)
            Text("Saved \(relativeLabel(for: savedAt))")
                .font(.smoory_caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button("Confirm replacement", action: onConfirm)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            Button("Both true", action: onReject)
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

    // MARK: - Status footer

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
            Label("Confirmed", systemImage: "checkmark.circle.fill")
                .font(.smoory_micro)
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .rejected:
            Label("Rejected", systemImage: "xmark.circle.fill")
                .font(.smoory_micro)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
        case .autoApplied:
            EmptyView()
        }
    }

    // MARK: - Backgrounds + helpers

    private var rowBackground: Color {
        switch candidate.status {
        case .pending: Color.orange.opacity(0.10)
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
                Text("Couldn't render supersession candidate")
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

    private func relativeLabel(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
