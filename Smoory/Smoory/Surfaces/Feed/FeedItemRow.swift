import SwiftUI

/// Renders a FeedItem as a feed row. 2.5 stub — Phase 3 producers (briefs, reviews,
/// email annotations, alerts) will populate FeedItems and exercise this row.
struct FeedItemRow: View {
    let item: FeedItem
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: kindIcon)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.headline)
                        .font(.smoory_body)
                        .lineLimit(isExpanded ? nil : 1)
                    if isExpanded && !item.body.isEmpty {
                        Text(item.body)
                            .font(.smoory_body)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(kindLabel)
                            .font(.smoory_micro)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        if item.pinned {
                            Image(systemName: "pin.fill")
                                .imageScale(.small)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { onToggleExpand() }
    }

    private var kindIcon: String {
        switch item.kind {
        case .alert: "exclamationmark.triangle"
        case .emailAnnotation: "envelope"
        case .todoProposal: "checklist"
        case .calendarNudge: "calendar"
        case .morningBrief: "sun.horizon"
        case .dayReview: "moon"
        case .weekReview: "calendar.day.timeline.left"
        case .memoryCandidate: "lightbulb"
        case .goalCandidate: "target"
        case .personCandidate: "person.crop.circle"
        case .threadProposal: "text.alignleft"
        case .patternObservation: "waveform.path.ecg"
        case .checkInDue: "clock.badge.checkmark"
        case .offPeriodConflict: "calendar.badge.exclamationmark"
        }
    }

    private var kindLabel: String {
        switch item.kind {
        case .alert: "Alert"
        case .emailAnnotation: "Email"
        case .todoProposal: "Todo proposal"
        case .calendarNudge: "Calendar"
        case .morningBrief: "Morning brief"
        case .dayReview: "Day review"
        case .weekReview: "Week review"
        case .memoryCandidate: "Memory candidate"
        case .goalCandidate: "Goal candidate"
        case .personCandidate: "Person candidate"
        case .threadProposal: "Thread proposal"
        case .patternObservation: "Pattern"
        case .checkInDue: "Check-in"
        case .offPeriodConflict: "Time-off conflict"
        }
    }
}
