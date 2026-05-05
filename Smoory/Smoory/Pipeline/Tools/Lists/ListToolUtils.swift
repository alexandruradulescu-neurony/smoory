import Foundation
import SwiftData

/// Shared helpers for the user-list tool family. Mirrors `TodoToolUtils` in scope —
/// decode helpers, resolver for `list_id` / `list_name` dual-key inputs, and a uniform
/// error-output formatter so the LLM sees consistent failure shapes across the seven
/// list tools.
enum ListToolUtils {

    enum ListToolError: LocalizedError {
        case missingIdentifier
        case listNotFound(name: String)
        case ambiguousName(name: String, count: Int)
        case itemNotFound(id: String)
        case invalidUUID(field: String, value: String)
        case invalidKind(value: String)
        case wrongKindForCompletion

        var errorDescription: String? {
            switch self {
            case .missingIdentifier:
                return "list_id or list_name is required"
            case .listNotFound(let name):
                return "no list named '\(name)'"
            case .ambiguousName(let name, let count):
                return "multiple lists named '\(name)' (\(count)); use list_id to disambiguate"
            case .itemNotFound(let id):
                return "no list item with id '\(id)'"
            case .invalidUUID(let field, let value):
                return "invalid UUID in \(field): '\(value)'"
            case .invalidKind(let value):
                return "invalid kind '\(value)' — use 'checklist' or 'notes'"
            case .wrongKindForCompletion:
                return "cannot complete an item in a notes-kind list"
            }
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from jsonString: String) throws -> T {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "ListTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "empty parameters"]
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func errorOutput(toolUseId: String, message: String) -> ToolOutput {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let json = #"{"error":"\#(escaped)"}"#
        return ToolOutput(toolUseId: toolUseId, content: json, isError: true)
    }

    /// Resolves a (list_id, list_name) pair to a single `UserList`. Either may be nil
    /// (but not both); name match is case-insensitive trimmed, ignoring archived lists.
    /// Throws on missing input, no match, or multiple matches.
    static func resolveList(
        listID: String?,
        listName: String?,
        in context: ModelContext
    ) throws -> UserList {
        if let raw = listID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let uuid = UUID(uuidString: raw) else {
                throw ListToolError.invalidUUID(field: "list_id", value: raw)
            }
            let descriptor = FetchDescriptor<UserList>(
                predicate: #Predicate<UserList> { $0.id == uuid }
            )
            if let match = try? context.fetch(descriptor).first {
                return match
            }
            throw ListToolError.itemNotFound(id: raw) // re-using semantics; LLM sees "no list..."
        }

        if let nameRaw = listName?.trimmingCharacters(in: .whitespacesAndNewlines), !nameRaw.isEmpty {
            let needle = nameRaw.localizedLowercase
            // Fetch non-archived and match in Swift to get unicode-correct case folding.
            let descriptor = FetchDescriptor<UserList>(
                predicate: #Predicate<UserList> { !$0.isArchived }
            )
            let candidates = (try? context.fetch(descriptor)) ?? []
            let matches = candidates.filter {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase == needle
            }
            switch matches.count {
            case 0: throw ListToolError.listNotFound(name: nameRaw)
            case 1: return matches[0]
            default: throw ListToolError.ambiguousName(name: nameRaw, count: matches.count)
            }
        }

        throw ListToolError.missingIdentifier
    }

    /// Resolves an `item_id` to a `UserListItem`. Throws on invalid UUID or no match.
    static func resolveItem(itemID: String, in context: ModelContext) throws -> UserListItem {
        let raw = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: raw) else {
            throw ListToolError.invalidUUID(field: "item_id", value: raw)
        }
        let descriptor = FetchDescriptor<UserListItem>(
            predicate: #Predicate<UserListItem> { $0.id == uuid }
        )
        if let match = try? context.fetch(descriptor).first {
            return match
        }
        throw ListToolError.itemNotFound(id: raw)
    }
}
