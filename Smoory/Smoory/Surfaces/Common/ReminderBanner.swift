import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class FiredReminderQueue {
    struct FiredReminder: Identifiable, Sendable, Hashable {
        let id: UUID
        let content: String
        let firedAt: Date
        let willDismissAt: Date
    }

    private(set) var visibleReminders: [FiredReminder] = []
    private var alreadyShown: Set<UUID> = []
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    private static let autoDismissAfter: TimeInterval = 30
    private static let maxVisible = 3

    func enqueue(action: ScheduledAction) {
        guard !visibleReminders.contains(where: { $0.id == action.id }) else { return }
        let now = Date()
        let reminder = FiredReminder(
            id: action.id,
            content: action.content,
            firedAt: now,
            willDismissAt: now.addingTimeInterval(Self.autoDismissAfter)
        )
        if visibleReminders.count >= Self.maxVisible {
            let oldest = visibleReminders.removeFirst()
            dismissTasks.removeValue(forKey: oldest.id)?.cancel()
        }
        visibleReminders.append(reminder)
        alreadyShown.insert(action.id)

        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoDismissAfter))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: action.id)
        }
        dismissTasks[action.id] = task
    }

    func dismiss(id: UUID) {
        visibleReminders.removeAll { $0.id == id }
        dismissTasks.removeValue(forKey: id)?.cancel()
    }

    /// Pulls all .firing user reminders not already shown this session and enqueues
    /// them. Called on app foreground so a reminder that fired while the app was
    /// closed still surfaces visually when the user returns.
    func enqueueAllStaleUserReminders(service: ScheduledActionService) async {
        let history = (try? service.actionsHistory(daysBack: 7)) ?? []
        let stale = history.filter { $0.kind == .userReminder && $0.status == .firing }
        for action in stale where !alreadyShown.contains(action.id) {
            enqueue(action: action)
        }
    }
}

struct ReminderBannerView: View {
    let reminder: FiredReminderQueue.FiredReminder
    let onMarkDone: () -> Void
    let onPostpone1h: () -> Void
    let onSnooze10m: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Reminder")
                    .font(.smoory_micro)
                    .foregroundStyle(.secondary)
                Text(reminder.content)
                    .font(.smoory_body)
                    .lineLimit(2)
            }

            Spacer()

            HStack(spacing: 4) {
                Button("Mark done", action: onMarkDone)
                    .buttonStyle(.borderedProminent)
                Button("+1h", action: onPostpone1h)
                    .buttonStyle(.bordered)
                Button("+10m", action: onSnooze10m)
                    .buttonStyle(.bordered)
            }
            .font(.smoory_caption)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4, y: 2)
    }
}
