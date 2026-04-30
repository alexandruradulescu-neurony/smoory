import Foundation

/// Writes scheduled-action snapshots to the App Group container so the future
/// widget can read them without going through the main app. Single-writer (only
/// ScheduledActionService writes); reads are widget-side. Atomic writes prevent
/// torn reads.
@MainActor
final class AppGroupContainerWriter {
    private static let groupIdentifier = "group.com.assistant.smoory.shared"
    private static let snapshotFile = "scheduled-actions.json"

    private let containerURL: URL

    init?() {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.groupIdentifier
        ) else {
            print("[appgroup] container URL unavailable for \(Self.groupIdentifier)")
            return nil
        }
        self.containerURL = url
    }

    var snapshotURL: URL {
        containerURL.appendingPathComponent(Self.snapshotFile)
    }

    func writeScheduledActionsSnapshot(_ actions: [ScheduledAction]) {
        // Only pending entries, sorted by scheduledFor ascending, capped at 7. The
        // widget renders an upcoming queue — cancelled/firing/completed rows are noise.
        let upcoming = actions
            .filter { $0.status == .pending }
            .sorted { $0.scheduledFor < $1.scheduledFor }
            .prefix(7)

        let entries = upcoming.map {
            ScheduledActionSnapshotEntry(
                id: $0.id.uuidString,
                kind: $0.kind.stringValue,
                scheduledFor: $0.scheduledFor,
                content: $0.content
            )
        }

        let snapshot = ScheduledActionsSnapshot(updatedAt: Date(), entries: entries)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            print("[appgroup] snapshot write failed: \(error)")
        }
    }
}

struct ScheduledActionsSnapshot: Codable, Sendable {
    let updatedAt: Date
    let entries: [ScheduledActionSnapshotEntry]
}

struct ScheduledActionSnapshotEntry: Codable, Sendable {
    let id: String
    let kind: String
    let scheduledFor: Date
    let content: String
}
