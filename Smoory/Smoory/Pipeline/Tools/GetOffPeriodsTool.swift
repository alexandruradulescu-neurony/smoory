import Foundation
import SwiftData

enum GetOffPeriodsTool: Tool {
    static let name = "get_off_periods"

    static let description = """
        List the user's active and upcoming off periods (vacation, sick days, holidays, \
        personal time). Use when the user asks "am I off next week?", "when's my \
        vacation?", or whenever a schedule answer should account for time off. Past \
        periods are excluded by default. Off periods are created when the user states \
        time off in conversation and confirms the candidate.
        """

    static let confirmationTier: ConfirmationTier = .silent

    static let inputSchema = ToolInputSchema(
        properties: [
            "include_past": ToolInputSchemaProperty(
                type: "boolean",
                description: "If true, include off periods whose end date has already passed. Default false."
            ),
            "limit": ToolInputSchemaProperty(
                type: "integer",
                description: "Max periods to return (default 20)."
            )
        ],
        required: []
    )

    private struct Input: Decodable {
        let include_past: Bool?
        let limit: Int?
    }

    private struct Payload: Encodable {
        let id: String
        let kind: String
        let start_date: String
        let end_date: String
        let day_count: Int
        let notes: String
        let role: String?
        let is_active: Bool
        let is_upcoming: Bool
    }

    static func execute(
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolOutput {
        let input = (try? Self.decodeInput(parametersJSON))
            ?? Input(include_past: nil, limit: nil)
        let includePast = input.include_past ?? false
        let limit = input.limit ?? 20

        let modelContext = ModelContext(context.services.modelContainer)
        var descriptor = FetchDescriptor<OffPeriod>(
            sortBy: [SortDescriptor(\.startDate, order: .forward)]
        )
        descriptor.fetchLimit = 500
        let allPeriods = (try? modelContext.fetch(descriptor)) ?? []
        let now = Date()
        let filtered = includePast
            ? allPeriods
            : allPeriods.filter { !$0.isPast(now: now) }

        let payload = filtered.prefix(limit).map { period -> Payload in
            Payload(
                id: period.id.uuidString,
                kind: period.kind.displayLabel,
                start_date: period.startDate.formatted(.iso8601),
                end_date: period.endDate.formatted(.iso8601),
                day_count: period.dayCount,
                notes: period.notes,
                role: period.role?.slug,
                is_active: period.isActive(now: now),
                is_upcoming: period.isUpcoming
            )
        }

        do {
            let json = try Self.encodeJSON(["off_periods": Array(payload)])
            return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
        } catch {
            let escaped = error.localizedDescription
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return ToolOutput(
                toolUseId: context.toolUseId,
                content: #"{"error":"\#(escaped)"}"#,
                isError: true
            )
        }
    }

    private static func decodeInput(_ jsonString: String) throws -> Input {
        let trimmed = jsonString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return Input(include_past: nil, limit: nil)
        }
        return (try? JSONDecoder().decode(Input.self, from: data))
            ?? Input(include_past: nil, limit: nil)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
