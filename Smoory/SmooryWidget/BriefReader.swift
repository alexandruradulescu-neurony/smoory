import Foundation

enum WidgetAppGroup {
    static let identifier = "group.com.assistant.smoory.shared"

    static var containerURL: URL? {
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        if url == nil {
            print("[widget] App Group container unavailable for \(identifier) — entitlement missing?")
        }
        return url
    }

    private static let isoDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? isoDecoder.decode(type, from: data)
    }
}

enum BriefReader {
    static func read() -> WidgetMorningBrief? {
        guard let url = WidgetAppGroup.containerURL?.appendingPathComponent("morning-brief.json") else {
            return nil
        }
        return WidgetAppGroup.decode(WidgetMorningBrief.self, from: url)
    }
}

enum ScheduledActionsReader {
    static func read() -> [WidgetScheduledAction] {
        guard let url = WidgetAppGroup.containerURL?.appendingPathComponent("scheduled-actions.json") else {
            return []
        }
        guard let snapshot = WidgetAppGroup.decode(WidgetScheduledActionsSnapshot.self, from: url) else {
            return []
        }
        return snapshot.entries
    }
}

enum CalendarSnapshotReader {
    static func read() -> WidgetCalendarSnapshot? {
        guard let url = WidgetAppGroup.containerURL?.appendingPathComponent("calendar-snapshot.json") else {
            return nil
        }
        return WidgetAppGroup.decode(WidgetCalendarSnapshot.self, from: url)
    }
}

enum TodosSnapshotReader {
    static func read() -> WidgetTodosSnapshot? {
        guard let url = WidgetAppGroup.containerURL?.appendingPathComponent("todos-snapshot.json") else {
            return nil
        }
        return WidgetAppGroup.decode(WidgetTodosSnapshot.self, from: url)
    }
}
