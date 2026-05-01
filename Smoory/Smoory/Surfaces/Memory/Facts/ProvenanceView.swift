import Foundation
import SwiftUI

struct ParsedProvenance: Equatable {
    var sourceKind: String?
    var extractedAt: Date?
    var extractingModel: String?
    var confidence: Double?
    var userConfirmed: Bool?
    var userConfirmedAt: Date?
    var sourceSessionID: UUID?
    var sourceIDs: [String] = []

    init(from json: String?) {
        guard let json,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        sourceKind = obj["source_kind"] as? String
        if let s = obj["extracted_at"] as? String {
            extractedAt = try? Date(s, strategy: .iso8601)
        }
        extractingModel = obj["extracting_model"] as? String
        if let d = obj["confidence"] as? Double {
            confidence = d
        } else if let i = obj["confidence"] as? Int {
            confidence = Double(i)
        }
        userConfirmed = obj["user_confirmed"] as? Bool
        if let s = obj["user_confirmed_at"] as? String {
            userConfirmedAt = try? Date(s, strategy: .iso8601)
        }
        if let s = obj["source_session_id"] as? String {
            sourceSessionID = UUID(uuidString: s)
        }
        sourceIDs = (obj["source_ids"] as? [String]) ?? []
    }

    var isEmpty: Bool {
        sourceKind == nil && extractedAt == nil && extractingModel == nil
            && confidence == nil && userConfirmed == nil && userConfirmedAt == nil
            && sourceSessionID == nil && sourceIDs.isEmpty
    }
}

struct ProvenanceView: View {
    let provenanceJSON: String?
    let createdAt: Date

    var body: some View {
        let parsed = ParsedProvenance(from: provenanceJSON)
        if parsed.isEmpty {
            Text("(no provenance recorded)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let kind = parsed.sourceKind {
                    row("Source", value: humanLabel(for: kind))
                }
                if let extracted = parsed.extractedAt {
                    row("Extracted at", value: extracted.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
                }
                if let model = parsed.extractingModel {
                    row("Extracting model", value: model)
                }
                if let conf = parsed.confidence {
                    row("Confidence at write", value: "\(Int((conf * 100).rounded()))%")
                }
                if let confirmed = parsed.userConfirmed {
                    row("User-confirmed", value: confirmed ? "yes" : "no")
                }
                if let confirmedAt = parsed.userConfirmedAt {
                    row("Confirmed at", value: confirmedAt.formatted(.dateTime.month(.abbreviated).day().year()))
                }
                if let sessionID = parsed.sourceSessionID {
                    row("Source session", value: String(sessionID.uuidString.prefix(8)) + "…")
                }
                if !parsed.sourceIDs.isEmpty {
                    row("Source IDs", value: parsed.sourceIDs.map { String($0.prefix(8)) + "…" }.joined(separator: ", "))
                }
                row("Stored at", value: createdAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
            }
            .font(.caption)
        }
    }

    private func humanLabel(for sourceKind: String) -> String {
        switch sourceKind {
        case "structuring_layer":             return "Structuring layer"
        case "chat_assistant_call":           return "Chat (write_memory_fact)"
        case "week_review_pattern_analysis":  return "Week review pattern analysis"
        default:                              return sourceKind
        }
    }

    @ViewBuilder
    private func row(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
