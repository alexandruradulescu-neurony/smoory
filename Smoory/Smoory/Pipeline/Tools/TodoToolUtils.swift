import Foundation
import SwiftData

/// Typed errors thrown from `performAction` on todo tools. The tool's `execute` wrapper
/// translates these into Anthropic-shaped error outputs.
///
/// 4.8c migration: same error names retained even though the underlying entity is
/// `UserListItem` — tool error messages stay user-readable as "Todo" since chat-side
/// callers (LLM, prompt) still use the noun "todo" for tactical commitments.
enum TodoToolError: LocalizedError {
    case todoNotFound
    case invalidParent
    case dateParseFailed
    case missingTitle

    var errorDescription: String? {
        switch self {
        case .todoNotFound: return "Todo not found"
        case .invalidParent: return "Cannot nest subtasks: the referenced parent is itself a subtask. Only one level allowed."
        case .dateParseFailed: return "Could not parse the date"
        case .missingTitle: return "Title is required"
        }
    }
}

/// Shared utilities for the family of "todo" tools. Backing entity is `UserListItem`
/// (4.8c), but the tool surface preserves Todo nomenclature so prompts and LLM
/// behavior don't shift.
enum TodoToolUtils {
    /// Title of the auto-managed UserList that holds chat-created tactical commitments
    /// — replacements for what 4.6 and earlier stored as standalone `Todo` rows.
    static let defaultTodosListTitle = "Todos"

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

    /// Looks up a `UserListItem` by id. Replaces the pre-4.8c `fetchTodo` helper —
    /// callers stay the same, only the underlying entity flipped.
    static func fetchItem(id idString: String, in context: ModelContext) -> UserListItem? {
        guard let uuid = UUID(uuidString: idString) else { return nil }
        var descriptor = FetchDescriptor<UserListItem>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Backwards-compatible alias kept while callers migrate. Returns the same
    /// `UserListItem` as `fetchItem`. New code should call `fetchItem` directly.
    static func fetchTodo(id idString: String, in context: ModelContext) -> UserListItem? {
        fetchItem(id: idString, in: context)
    }

    /// Returns the default "Todos" UserList, creating it lazily on first use. Used by
    /// CreateTodoTool / CandidateAcceptor / CreateSubtaskTool when a chat-created
    /// tactical item has no explicit list affiliation.
    static func defaultTodosList(in context: ModelContext) -> UserList {
        let title = defaultTodosListTitle
        let descriptor = FetchDescriptor<UserList>(
            predicate: #Predicate<UserList> { $0.title == title && !$0.isArchived }
        )
        if let existing = try? context.fetch(descriptor).first { return existing }
        let list = UserList()
        list.title = title
        list.kind = .checklist
        let now = Date()
        list.createdAt = now
        list.updatedAt = now
        context.insert(list)
        return list
    }

    /// Maps the LLM-provided string priority onto the EK 0–9 scale used by
    /// `UserListItem.priority`. Same case names as the pre-4.8c `TodoPriority`.
    static func priority(from string: String?) -> Int? {
        switch string?.lowercased() {
        case "low": return 1
        case "normal": return 5
        case "high": return 7
        case "urgent": return 9
        default: return nil
        }
    }

    /// Reverse mapping for tool output payloads. Buckets by the same scale documented
    /// on `UserListItem.PriorityBucket`.
    static func priorityName(_ p: Int) -> String {
        switch p {
        case 0: return "normal"   // pre-4.8c "no priority" displayed as normal in tool output
        case 1...4: return "low"
        case 5: return "normal"
        case 6...8: return "high"
        case 9: return "urgent"
        default: return "normal"
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
