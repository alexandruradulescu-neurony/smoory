import Foundation
import SwiftUI

/// Renders a morning brief FeedItem with structured sections decoded from
/// payloadJSON. If decode fails, falls back to a minimal row showing the
/// FeedItem.headline so the surface never crashes.
struct MorningBriefFeedRow: View {
    let item: FeedItem

    private var brief: MorningBrief? {
        guard let json = item.payloadJSON, !json.isEmpty,
              let data = json.data(using: .utf8)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MorningBrief.self, from: data)
    }

    var body: some View {
        if let brief {
            renderedBrief(brief)
        } else {
            decodeFallback
        }
    }

    @ViewBuilder
    private func renderedBrief(_ brief: MorningBrief) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "sun.horizon.fill")
                    .foregroundStyle(.orange)
                Text("Morning brief")
                    .font(.smoory_caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }

            Text(brief.headline)
                .font(.smoory_display)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !brief.calendar.isEmpty {
                section(title: "Today's calendar") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(brief.calendar, id: \.self) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(event.isAllDay ? "All day" : timeRange(event))
                                    .font(.smoory_caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 100, alignment: .leading)
                                Text(event.title).font(.smoory_body)
                                if let loc = event.location, !loc.isEmpty {
                                    Text("· \(loc)")
                                        .font(.smoory_micro)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }

            if !brief.secondaryItems.isEmpty {
                section(title: "Worth your attention") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(brief.secondaryItems, id: \.text) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: entry.icon)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(entry.text).font(.smoory_body)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }

            if let note = brief.reflectiveNote, !note.isEmpty {
                Text(note)
                    .font(.smoory_caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if let nudge = brief.goalNudge {
                VStack(alignment: .leading, spacing: 4) {
                    Text(nudge.goalTitle)
                        .font(.smoory_micro)
                        .foregroundStyle(.orange)
                        .textCase(.uppercase)
                    Text(nudge.nudgeText)
                        .font(.smoory_body)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                Spacer()
                Text("Generated \(brief.generatedAt.formatted(.dateTime.hour().minute()))")
                    .font(.smoory_micro)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.smoory_micro)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            content()
        }
    }

    private func timeRange(_ e: MorningBrief.CalendarItem) -> String {
        let s = e.startTime.formatted(date: .omitted, time: .shortened)
        let f = e.endTime.formatted(date: .omitted, time: .shortened)
        return "\(s) – \(f)"
    }

    @ViewBuilder
    private var decodeFallback: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Morning brief")
                .font(.smoory_micro)
                .foregroundStyle(.orange)
                .textCase(.uppercase)
            Text(item.headline.isEmpty ? "Couldn't decode brief" : item.headline)
                .font(.smoory_body)
            Text("Open Debug → Open today's brief JSON to inspect the raw payload.")
                .font(.smoory_micro)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
