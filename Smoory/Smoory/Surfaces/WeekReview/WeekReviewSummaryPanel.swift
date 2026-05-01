import SwiftUI

struct WeekReviewSummaryPanel: View {
    let summary: WeekReviewSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let stats = summary.stats {
                statsGrid(stats)
            }
            observationsSection
            if !summary.durableInsights.isEmpty {
                insightsSection
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.secondary)
            Text(rangeLabel)
                .font(.smoory_caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
    }

    private var rangeLabel: String {
        let start = summary.weekStartedAt.formatted(.dateTime.month(.abbreviated).day())
        let end = summary.weekEndedAt.formatted(.dateTime.month(.abbreviated).day())
        return "Week of \(start) – \(end)"
    }

    @ViewBuilder
    private func statsGrid(_ stats: WeekStats) -> some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            statCell(label: "Reminders", value: "\(stats.totalReminders)")
            statCell(label: "Completed", value: "\(stats.completedReminders)")
            statCell(label: "Postponed", value: "\(stats.postponedReminders)")
            statCell(label: "Skipped", value: "\(stats.skippedReminders)")
            statCell(label: "Day reviews", value: "\(stats.dayReviewsCompleted)")
            if let avg = stats.avgUserResponseTime {
                statCell(label: "Avg response", value: humanize(seconds: avg))
            }
        }
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.smoory_micro)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(value)
                .font(.smoory_body.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private var observationsSection: some View {
        let observations = summary.observations
        if !observations.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("What stood out")
                    .font(.smoory_micro)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                ForEach(observations) { obs in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon(for: obs.kind))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .frame(width: 16)
                        Text(obs.observation)
                            .font(.smoory_caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("I noticed")
                .font(.smoory_micro)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            ForEach(summary.durableInsights) { insight in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .frame(width: 16)
                    Text(insight.factText)
                        .font(.smoory_caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text("\(Int((insight.confidence * 100).rounded()))%")
                        .font(.smoory_micro.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func icon(for kind: PatternObservation.ObservationKind) -> String {
        switch kind {
        case .completion: return "checkmark.circle"
        case .deferral:   return "clock.arrow.circlepath"
        case .timing:     return "clock"
        case .absence:    return "circle.slash"
        case .rhythm:     return "waveform"
        }
    }

    private func humanize(seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        let leftover = mins % 60
        return leftover == 0 ? "\(hours)h" : "\(hours)h \(leftover)m"
    }
}

struct AnalyzingView: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Analyzing your week…")
                .font(.smoory_caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
