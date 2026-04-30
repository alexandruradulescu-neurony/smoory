import SwiftUI

/// Lean turn renderer for the day-review sheet. Same visual language as main chat's
/// TurnBubble (smoory_body text, soft secondary background for assistant, primary
/// accent for user) but with no PendingAction card support — day reviews don't
/// expose tier-1 cards, only silent tools.
struct DayReviewTurnView: View {
    let turn: ChatViewModel.Turn

    var body: some View {
        switch turn.speaker {
        case .assistant:
            assistantBubble
        case .user:
            userBubble
        case .errorBubble:
            errorBubble
        }
    }

    private var assistantBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                if !turn.text.isEmpty {
                    Text(turn.text)
                        .font(.smoory_body)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .textSelection(.enabled)
                } else {
                    ProgressView().controlSize(.small).padding(.vertical, 4)
                }
                if let names = turn.usedToolNames, !names.isEmpty {
                    Text("Used: \(names.joined(separator: ", "))")
                        .font(.smoory_micro)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 32)
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 32)
            Text(turn.text)
                .font(.smoory_body)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .textSelection(.enabled)
        }
    }

    private var errorBubble: some View {
        HStack {
            Text(turn.text)
                .font(.smoory_caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Spacer(minLength: 32)
        }
    }
}
