import SwiftData
import SwiftUI

/// Settings → "Time off" section. Lists current and upcoming `OffPeriod` rows with a
/// delete affordance. Past periods are hidden by default; toggle reveals them. New
/// periods are created via the structuring candidate flow today (no inline create);
/// see DECISIONS.md §4.9 "Out of scope".
struct TimeOffSettingsSection: View {
    let modelContainer: ModelContainer

    @Environment(\.modelContext) private var modelContext

    @Query(sort: \OffPeriod.startDate, order: .forward)
    private var allPeriods: [OffPeriod]

    @State private var showingPast = false

    private var visiblePeriods: [OffPeriod] {
        let now = Date()
        return showingPast ? allPeriods : allPeriods.filter { !$0.isPast(now: now) }
    }

    var body: some View {
        Section("Time off") {
            if visiblePeriods.isEmpty {
                HStack {
                    Image(systemName: "calendar.badge.checkmark")
                        .foregroundStyle(.secondary)
                    Text(showingPast ? "No off periods on record." : "No upcoming off periods.")
                        .font(.smoory_body)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ForEach(visiblePeriods, id: \.id) { period in
                    OffPeriodRow(period: period, modelContext: modelContext)
                }
            }

            Toggle("Show past", isOn: $showingPast)
                .toggleStyle(.switch)
                .controlSize(.small)

            Text("New off periods are added when you tell Smoory in chat that you'll be off — confirm the candidate in the Feed and it lands here.")
                .font(.smoory_caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct OffPeriodRow: View {
    @Bindable var period: OffPeriod
    let modelContext: ModelContext

    @State private var pendingDelete = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: period.kind.symbolName)
                .foregroundStyle(period.isActive() ? Color.orange : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(period.displayLabel)
                    .font(.smoory_body)
                if period.isActive() {
                    Text("Active now").font(.caption2).foregroundStyle(.orange)
                } else if period.isUpcoming {
                    Text("Upcoming").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Past").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button(role: .destructive) {
                pendingDelete = true
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete off period")
        }
        .padding(.vertical, 2)
        .alert("Delete off period?", isPresented: $pendingDelete) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(period.displayLabel)\" will be removed. Conflict cards in your Feed are not auto-cleared.")
        }
    }

    private func delete() {
        modelContext.delete(period)
        try? modelContext.save()
    }
}
