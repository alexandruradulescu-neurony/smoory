import Foundation
import SwiftData

@Model
final class WeekReviewSummary {
    var id: UUID = UUID()
    var weekStartedAt: Date = Date()
    var weekEndedAt: Date = Date()
    var generatedAt: Date = Date()
    var actionID: UUID?

    var statsJSON: String = "{}"
    var observationsJSON: String = "[]"
    var durableInsightsJSON: String = "[]"

    init() {}
}

extension WeekReviewSummary {
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Stats from the pattern analyzer. `nil` semantically means "analysis hasn't run
    /// yet" — the default `"{}"` placeholder short-circuits before the decoder so a
    /// blank summary doesn't surface a fallback all-zeros grid that would look like
    /// real data.
    var stats: WeekStats? {
        let trimmed = statsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(WeekStats.self, from: data)
    }

    var observations: [PatternObservation] {
        let trimmed = observationsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([PatternObservation].self, from: data)) ?? []
    }

    var durableInsights: [DurableInsight] {
        let trimmed = durableInsightsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([DurableInsight].self, from: data)) ?? []
    }
}
