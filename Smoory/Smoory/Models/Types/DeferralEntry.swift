import Foundation

/// Single entry in a ScheduledAction's deferral history. Stored on the model as a
/// JSON-encoded array under `deferralHistoryJSON`.
struct DeferralEntry: Codable, Sendable, Hashable {
    let at: Date
    let fromTime: Date
    let toTime: Date
    let reason: String?

    static func encode(_ entries: [DeferralEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries),
              let str = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }

    static func decode(_ json: String) -> [DeferralEntry] {
        guard let data = json.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DeferralEntry].self, from: data)) ?? []
    }
}
