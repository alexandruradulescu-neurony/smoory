import SwiftUI

/// Renders a `.firing` review-kind ScheduledAction (.dayReview / .endOfDay /
/// .weekReview) as a tappable Feed row in the "Reviews" section. Tap calls
/// the `onTap` closure which routes to the corresponding pending-state's
/// `actionToPresent` so the existing review sheet plumbing in SmooryApp
/// presents the modal — same path NotificationDelegate uses for tapped
/// notifications. No "skip / dismiss" affordance here: stale rows are
/// auto-skipped at 18h by `skipStaleReviewMisses` on launch, so the user
/// doesn't need a manual escape hatch to keep the recurring chain alive.
struct FiringReviewRow: View {
    let action: ScheduledAction
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.orange)
                    .imageScale(.medium)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.smoory_body)
                        .foregroundStyle(.primary)
                    Text(scheduledLabel)
                        .font(.smoory_caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            .padding(12)
            .background(Color.orange.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        switch action.kind {
        case .dayReview: "Day review"
        case .endOfDay: "End of day"
        case .weekReview: "Week review"
        default: "Review"
        }
    }

    private var icon: String {
        switch action.kind {
        case .dayReview: "moon.stars"
        case .endOfDay: "checklist"
        case .weekReview: "calendar.badge.clock"
        default: "bell"
        }
    }

    private var scheduledLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Scheduled \(formatter.localizedString(for: action.scheduledFor, relativeTo: Date()))"
    }
}
