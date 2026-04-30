import Foundation
import SwiftData

/// Shared utilities for the family of Todo tools (complete/update/defer/delete/create_subtask).
enum TodoToolUtils {
    static func decode<T: Decodable>(_ type: T.Type, from jsonString: String) throws -> T {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "TodoToolUtils",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "empty parameters"]
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func fetchTodo(id idString: String, in context: ModelContext) -> Todo? {
        guard let uuid = UUID(uuidString: idString) else { return nil }
        var descriptor = FetchDescriptor<Todo>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    static func priority(from string: String?) -> TodoPriority? {
        switch string?.lowercased() {
        case "low": return .low
        case "normal": return .normal
        case "high": return .high
        case "urgent": return .urgent
        default: return nil
        }
    }

    static func priorityName(_ p: TodoPriority) -> String {
        switch p {
        case .low: return "low"
        case .normal: return "normal"
        case .high: return "high"
        case .urgent: return "urgent"
        }
    }

    static func errorOutput(toolUseId: String, message: String) -> ToolOutput {
        let escaped = jsonEscape(message)
        return ToolOutput(
            toolUseId: toolUseId,
            content: #"{"error":"\#(escaped)"}"#,
            isError: true
        )
    }

    static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func relativeDateLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
