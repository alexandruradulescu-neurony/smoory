import SwiftData
import SwiftUI

/// Inline chip shown in the chat surface when there are pending candidates.
// 2.5 Feed integration provides the persistent candidate browse surface. Until then,
// candidates are only visible while pending.
struct CandidatesNotice: View {
    @Query(filter: #Predicate<CandidateWrite> { $0.statusRaw == 0 })
    private var pending: [CandidateWrite]

    let onTap: () -> Void

    var body: some View {
        if !pending.isEmpty {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb")
                        .imageScale(.small)
                    Text("\(pending.count) new \(pending.count == 1 ? "candidate" : "candidates")")
                        .font(.caption)
                    Spacer()
                    Text("Review")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }
}
