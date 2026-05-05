import SwiftUI

struct DueDatePill: View {
    let dueDate: Date
    let group: DueDateGroup

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(group.color.opacity(0.18))
            .foregroundStyle(group.color)
            .clipShape(Capsule())
    }

    private var label: String {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDue = calendar.startOfDay(for: dueDate)
        let days = calendar.dateComponents([.day], from: startOfToday, to: startOfDue).day ?? 0

        if days == 0 { return "Today" }
        if days == 1 { return "Tomorrow" }
        if days >= 2 && days <= 6 {
            return dueDate.formatted(.dateTime.weekday(.abbreviated))
        }
        return dueDate.formatted(.dateTime.month(.abbreviated).day())
    }
}

struct PriorityIndicator: View {
    /// F-5/F-9 audit fix: takes `UserListItem.PriorityBucket` directly instead of the
    /// raw EK 0–9 int so callers can't accidentally pass the wrong scale, and the
    /// glyph/tint mapping lives in one place. Bucket is the canonical UI surface.
    let bucket: UserListItem.PriorityBucket

    var body: some View {
        if bucket == .none {
            EmptyView()
        } else {
            Image(systemName: glyph)
                .font(.caption2)
                .foregroundStyle(tint)
                .help("\(bucket.displayLabel) priority")
        }
    }

    private var glyph: String {
        switch bucket {
        case .none: return ""
        case .low: return "arrow.down"
        case .medium: return "exclamationmark"
        case .high: return "exclamationmark.2"
        }
    }

    private var tint: Color {
        switch bucket {
        case .none: return .clear
        case .low: return .secondary
        case .medium: return .orange
        case .high: return .red
        }
    }
}

struct RoleBadge: View {
    let name: String
    let colorHex: String

    var body: some View {
        Text(name)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(hex: colorHex).opacity(0.85))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }
}

struct SubtaskProgressBadge: View {
    let completed: Int
    let total: Int

    var body: some View {
        Text("\(completed)/\(total)")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
    }
}

extension Color {
    /// Parses #RRGGBB or #RRGGBBAA hex strings. Falls back to gray on malformed input.
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&value)

        let r, g, b, a: Double
        switch trimmed.count {
        case 6:
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1.0
        case 8:
            r = Double((value & 0xFF000000) >> 24) / 255
            g = Double((value & 0x00FF0000) >> 16) / 255
            b = Double((value & 0x0000FF00) >> 8) / 255
            a = Double(value & 0x000000FF) / 255
        default:
            r = 0.5; g = 0.5; b = 0.5; a = 1.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
