import Foundation
import SwiftData

@Model
final class ScheduledAction {
    var id: UUID = UUID()
    var kindRaw: Int = ScheduledActionKind.userReminder.rawValue

    /// Current effective fire time (mutated by postpone / reschedule).
    var scheduledFor: Date = Date()
    /// Original fire time at creation. Immutable after init — anchors recurring
    /// regeneration so deferring one occurrence doesn't drift the recurrence.
    var originalScheduledFor: Date = Date()

    var statusRaw: Int = ScheduledActionStatus.pending.rawValue
    var createdAt: Date = Date()
    var createdBySourceRaw: Int = ActionSource.system.rawValue
    var completedAt: Date?

    /// Free-text reminder body (for .userReminder, .goalNudge); empty for system actions
    /// that resolve their content at fire time (.morningBrief, .dayReview, .weekReview).
    var content: String = ""
    /// Optional foreign key to a related entity (a Goal for goalNudge, a Todo for a
    /// reminder about a specific item, etc.). Resolved by the action consumer.
    var relatedEntityID: UUID?

    /// JSON-encoded RecurringRule. Nil = one-off occurrence.
    var recurringRuleJSON: String?

    // History fields — written for pattern observation in 3.6.
    var deferralCount: Int = 0
    var deferralHistoryJSON: String = "[]"
    /// Seconds from `scheduledFor` (the effective fire time at completion) to
    /// `completedAt`. Negative if completed before fire (rare; not enforced).
    var userResponseTimeSeconds: Double?

    init() {}
}

extension ScheduledAction {
    var kind: ScheduledActionKind {
        get { ScheduledActionKind(rawValue: kindRaw) ?? .userReminder }
        set { kindRaw = newValue.rawValue }
    }

    var status: ScheduledActionStatus {
        get { ScheduledActionStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var createdBySource: ActionSource {
        get { ActionSource(rawValue: createdBySourceRaw) ?? .system }
        set { createdBySourceRaw = newValue.rawValue }
    }

    var recurringRule: RecurringRule? {
        get { RecurringRule.decode(recurringRuleJSON) }
        set { recurringRuleJSON = RecurringRule.encode(newValue) }
    }

    var deferralHistory: [DeferralEntry] {
        get { DeferralEntry.decode(deferralHistoryJSON) }
        set { deferralHistoryJSON = DeferralEntry.encode(newValue) }
    }
}

enum ScheduledActionKind: Int, Codable, Sendable, CaseIterable {
    case morningBrief = 0
    case dayReview = 1
    case weekReview = 2
    case goalNudge = 3
    case userReminder = 4
    /// 4.10 — end-of-day shutdown ritual. Operational counterpart to dayReview:
    /// fires later in the evening, focuses on tomorrow prep + clearing loose
    /// ends rather than reflective recall.
    case endOfDay = 5

    var stringValue: String {
        switch self {
        case .morningBrief: "morningBrief"
        case .dayReview: "dayReview"
        case .weekReview: "weekReview"
        case .goalNudge: "goalNudge"
        case .userReminder: "userReminder"
        case .endOfDay: "endOfDay"
        }
    }
}

enum ScheduledActionStatus: Int, Codable, Sendable, CaseIterable {
    case pending = 0
    case firing = 1
    case completed = 2
    case deferred = 3
    case cancelled = 4
    case skipped = 5
}

enum ActionSource: Int, Codable, Sendable {
    case system = 0
    case userChat = 1
}
