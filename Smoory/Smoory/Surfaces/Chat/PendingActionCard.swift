import SwiftData
import SwiftUI

struct PendingActionCard: View {
    let action: PendingAction
    let modelContainer: ModelContainer

    let onConfirm: () -> Void
    let onEdit: () -> Void
    let onDecline: () -> Void
    let onCommitEdit: (String) -> Void
    let onCancelEdit: () -> Void

    var body: some View {
        switch action.state {
        case .pending: compactPendingView
        case .editing: expandedEditingView
        case .executing: executingView
        case .confirmed(let summary):
            collapsedView(text: "✓ \(summary)", color: .secondary, muted: false)
        case .declined(let summary):
            collapsedView(text: "✗ Declined: \(summary)", color: .secondary, muted: true)
        case .failed(let reason):
            collapsedView(text: "⚠ \(reason)", color: .red, muted: false)
        }
    }

    // MARK: - Pending (compact)

    private var compactPendingView: some View {
        let summary = currentSummary
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: summary?.icon ?? "checklist")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary?.title ?? action.toolName).font(.callout).fontWeight(.medium)
                    Text(summary?.primary ?? "").font(.callout)
                    if let secondary = summary?.secondary {
                        Text(secondary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button(action.wasEdited ? "Confirm (edited)" : "Confirm", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                Button("Edit", action: onEdit)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Decline", role: .destructive, action: onDecline)
                    .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Editing (expanded)

    private var expandedEditingView: some View {
        let toolType = ToolRegistry.tool(named: action.toolName)
        let editView = toolType?.makeEditView(
            parametersJSON: action.effectiveParametersJSON,
            modelContainer: modelContainer,
            onCommit: onCommitEdit,
            onCancel: onCancelEdit
        ) ?? AnyView(EmptyView())
        return VStack(alignment: .leading, spacing: 6) {
            Text(currentSummary?.title ?? action.toolName)
                .font(.caption).foregroundStyle(.secondary)
            editView
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Executing

    private var executingView: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(currentSummary?.primary ?? "Working…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Collapsed

    private func collapsedView(text: String, color: Color, muted: Bool) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(muted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private var currentSummary: ProposedActionSummary? {
        guard let toolType = ToolRegistry.tool(named: action.toolName) else { return nil }
        return toolType.renderSummary(parametersJSON: action.effectiveParametersJSON)
    }
}
