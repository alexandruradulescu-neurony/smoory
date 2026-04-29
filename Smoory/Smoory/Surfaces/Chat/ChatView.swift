import SwiftUI

struct ChatView: View {
    private let surface: Surface = .chat
    @State private var viewModel = ChatViewModel()
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(surface.title)
        .onAppear { isInputFocused = true }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.turns) { turn in
                        TurnBubble(turn: turn)
                            .id(turn.id)
                    }
                    if viewModel.state == .sending {
                        SendingBubble()
                            .id(Self.sendingAnchor)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.turns.count) {
                if let last = viewModel.turns.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: viewModel.state) {
                if viewModel.state == .sending {
                    withAnimation { proxy.scrollTo(Self.sendingAnchor, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Smoory", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .focused($isInputFocused)
                .onKeyPress(phases: .down) { press in
                    guard press.key == .return else { return .ignored }
                    if press.modifiers.contains(.shift) { return .ignored }
                    submit()
                    return .handled
                }

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(isSendDisabled)
        }
        .padding(12)
    }

    private var isSendDisabled: Bool {
        viewModel.state == .sending ||
            viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard !isSendDisabled else { return }
        Task { await viewModel.send() }
    }

    private static let sendingAnchor = "sending-spinner"
}

private struct TurnBubble: View {
    let turn: ChatViewModel.Turn

    var body: some View {
        HStack(alignment: .top) {
            if turn.speaker == .user { Spacer(minLength: 40) }
            content
            if turn.speaker != .user { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch turn.speaker {
        case .user:
            Text(turn.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .textSelection(.enabled)
        case .assistant:
            Text(turn.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .textSelection(.enabled)
        case .errorBubble:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(turn.text)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct SendingBubble: View {
    var body: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Spacer(minLength: 40)
        }
    }
}

#Preview {
    ChatView()
}
