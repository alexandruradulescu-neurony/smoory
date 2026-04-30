import AppKit
import SwiftData
import SwiftUI

/// Debug commands for milestone 3.1 — exercise the ScheduledAction lifecycle without
/// any consumer wired (consumers land in 3.2+).
struct ScheduledActionDebugCommands: View {
    let service: ScheduledActionService?
    let modelContainer: ModelContainer

    var body: some View {
        Group {
            Button("Schedule test reminder (60s)") {
                runOnService { svc in
                    let action = try await svc.schedule(
                        kind: .userReminder,
                        at: Date().addingTimeInterval(60),
                        content: "Test reminder fired",
                        source: .system
                    )
                    print("[debug] scheduled test reminder \(action.id)")
                }
            }

            Button("Schedule daily recurring at +90s") {
                runOnService { svc in
                    let fire = Date().addingTimeInterval(90)
                    let comps = Calendar.current.dateComponents([.hour, .minute], from: fire)
                    let rule = RecurringRule(kind: .daily, timeOfDay: comps, dayOfWeek: nil)
                    let action = try await svc.schedule(
                        kind: .userReminder,
                        at: fire,
                        content: "Daily recurring test",
                        recurringRule: rule,
                        source: .system
                    )
                    print("[debug] scheduled daily recurring \(action.id) at \(fire)")
                }
            }

            Button("Postpone next pending action by 30 min") {
                runOnService { svc in
                    guard let next = try svc.nextScheduledAction() else {
                        print("[debug] no pending actions to postpone")
                        return
                    }
                    let updated = try await svc.postpone(
                        actionID: next.id,
                        by: 1800,
                        reason: "debug-postpone"
                    )
                    print("[debug] postponed \(updated.id) → \(updated.scheduledFor) (count=\(updated.deferralCount))")
                }
            }

            Button("Complete next firing action") {
                runOnService { svc in
                    guard let row = try Self.firstFiring(in: modelContainer) else {
                        print("[debug] no firing actions")
                        return
                    }
                    let updated = try await svc.markCompleted(actionID: row.id, userResponseTime: nil)
                    print("[debug] completed \(updated.id) — recurring? \(updated.recurringRule != nil)")
                }
            }

            Button("Skip next firing action") {
                runOnService { svc in
                    guard let row = try Self.firstFiring(in: modelContainer) else {
                        print("[debug] no firing actions")
                        return
                    }
                    try await svc.skipThisOccurrence(actionID: row.id)
                    print("[debug] skipped \(row.id)")
                }
            }

            Button("Dump scheduled actions") {
                runOnService { svc in
                    let actions = try svc.actionsHistory(daysBack: 30)
                    print("---- SCHEDULED ACTIONS (\(actions.count)) ----")
                    let fmt = Date.ISO8601FormatStyle(timeZone: .current)
                    for a in actions {
                        let extras = a.deferralCount > 0 ? " defers=\(a.deferralCount)" : ""
                        print("\(a.scheduledFor.formatted(fmt)) | \(a.kind) | \(a.status)\(extras) | \(a.content)")
                    }
                    print("---- END ----")
                }
            }

            Divider()

            Button("Clear all scheduled actions") {
                guard let service else {
                    print("[debug] service unavailable")
                    return
                }
                let alert = NSAlert()
                alert.messageText = "Clear all scheduled actions?"
                alert.informativeText = "This cancels every ScheduledAction row and removes all pending notifications."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Clear")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                Task {
                    do {
                        try await service.cancelAll()
                        print("[debug] cleared all scheduled actions")
                    } catch {
                        print("[debug] clear failed: \(error)")
                    }
                }
            }
        }
    }

    private static func firstFiring(in container: ModelContainer) throws -> ScheduledAction? {
        let firingRaw = ScheduledActionStatus.firing.rawValue
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<ScheduledAction>(
            predicate: #Predicate { $0.statusRaw == firingRaw },
            sortBy: [SortDescriptor(\.scheduledFor, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func runOnService(_ block: @escaping (ScheduledActionService) async throws -> Void) {
        guard let service else {
            print("[debug] ScheduledActionService not initialized yet")
            return
        }
        Task { @MainActor in
            do {
                try await block(service)
            } catch {
                print("[debug] command failed: \(error)")
            }
        }
    }
}
