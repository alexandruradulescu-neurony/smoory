import SwiftUI

/// Compact priority badge driven by `UserListItem.PriorityBucket`. Used by
/// `UserListItemRow` and any future surface that wants to render the bucket
/// glyph/tint without re-deriving the mapping. F-5/F-9 audit fix consolidated
/// the glyph + tint logic here so all callers stay in sync.
struct PriorityIndicator: View {
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
