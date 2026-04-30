import SwiftData
import SwiftUI

struct ChatView: View {
    @Environment(\.hemaState) private var hemaState
    @Environment(\.chatViewModel) private var chatViewModel

    var body: some View {
        Group {
            switch hemaState {
            case .loading:
                loadingView
            case .ready:
                if let chatViewModel {
                    ChatViewContent(viewModel: chatViewModel)
                } else {
                    loadingView
                }
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Memory failed to initialize").font(.title3)
                    Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(Surface.chat.title)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading memory…").font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct ChatViewContent: View {
    @Bindable var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool
    @State private var showCandidatesSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            transcript
            CandidatesNotice(onTap: { showCandidatesSheet = true })
            Divider()
            composer
        }
        .onAppear { isInputFocused = true }
        .sheet(isPresented: $showCandidatesSheet) {
            CandidatesSheet(
                hema: viewModel.hema,
                onDone: { showCandidatesSheet = false }
            )
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.turns) { turn in
                        TurnBubble(
                            turn: turn,
                            cards: cards(for: turn),
                            modelContainer: viewModel.modelContainer,
                            onConfirm: { id in Task { await viewModel.confirmAction(toolUseId: id) } },
                            onEdit:    { viewModel.enterEditMode(toolUseId: $0) },
                            onDecline: { viewModel.declineAction(toolUseId: $0) },
                            onCommitEdit: { id, json in viewModel.commitEdit(toolUseId: id, newParametersJSON: json) },
                            onCancelEdit: { viewModel.cancelEdit(toolUseId: $0) }
                        )
                        .id(turn.id)
                    }
                    if viewModel.state == .sending {
                        SendingBubble().id(Self.sendingAnchor)
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

    private func cards(for turn: ChatViewModel.Turn) -> [PendingAction] {
        viewModel.pendingActions.values
            .filter { $0.assistantTurnID == turn.id }
            .sorted { $0.proposedAt < $1.proposedAt }
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
                Image(systemName: "arrow.up.circle.fill").font(.title2)
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
    let cards: [PendingAction]
    let modelContainer: ModelContainer
    let onConfirm: (String) -> Void
    let onEdit: (String) -> Void
    let onDecline: (String) -> Void
    let onCommitEdit: (String, String) -> Void
    let onCancelEdit: (String) -> Void

    var body: some View {
        if turn.speaker == .assistant {
            assistantBubble
        } else {
            simpleBubble
        }
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !turn.text.isEmpty {
                bubbleRow {
                    Text(turn.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .textSelection(.enabled)
                }
            }
            ForEach(cards) { action in
                bubbleRow {
                    PendingActionCard(
                        action: action,
                        modelContainer: modelContainer,
                        onConfirm: { onConfirm(action.id) },
                        onEdit: { onEdit(action.id) },
                        onDecline: { onDecline(action.id) },
                        onCommitEdit: { json in onCommitEdit(action.id, json) },
                        onCancelEdit: { onCancelEdit(action.id) }
                    )
                }
            }
            if let names = turn.usedToolNames, !names.isEmpty {
                Text("Used: \(names.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 12)
            }
        }
    }

    private var simpleBubble: some View {
        bubbleRow {
            switch turn.speaker {
            case .user:
                Text(turn.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .textSelection(.enabled)
            case .errorBubble:
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(turn.text).textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            case .assistant:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func bubbleRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top) {
            if turn.speaker == .user { Spacer(minLength: 40) }
            content()
            if turn.speaker != .user { Spacer(minLength: 40) }
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
