import SwiftUI

struct WeekReviewSheet: View {
    @Bindable var viewModel: WeekReviewViewModel
    let dismiss: () -> Void

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if viewModel.isAnalyzing {
                            AnalyzingView()
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                        } else if let summary = viewModel.summary {
                            WeekReviewSummaryPanel(summary: summary)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                        }

                        if !viewModel.turns.isEmpty {
                            Divider().padding(.horizontal, 16)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.turns) { turn in
                                DayReviewTurnView(turn: turn).id(turn.id)
                            }
                            if viewModel.isSending {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("Smoory is thinking…")
                                        .font(.smoory_caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .id("sending")
                            }
                        }
                        .padding(16)
                    }
                }
                .onChange(of: viewModel.turns.last?.id) { _, last in
                    guard let last else { return }
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onChange(of: viewModel.isSending) { _, sending in
                    if sending { withAnimation { proxy.scrollTo("sending", anchor: .bottom) } }
                }
            }

            Divider()
            inputBar
        }
        .frame(minWidth: 560, minHeight: 720)
        .frame(maxWidth: 720, maxHeight: 900)
        .task {
            await viewModel.startIfNeeded()
            inputFocused = true
        }
        .onChange(of: viewModel.shouldDismiss) { _, should in
            if should { dismiss() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.secondary)
            Text("Week review")
                .font(.smoory_display)
                .foregroundStyle(.primary)
            Spacer()
            Button("Skip") {
                Task { await viewModel.skipReview(); dismiss() }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            Button("Done") {
                Task { await viewModel.completeReview(); dismiss() }
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(viewModel.turns.count < 2)
        }
        .padding()
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("What stood out?", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.smoory_body)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { Task { await viewModel.send() } }
            Button {
                Task { await viewModel.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(
                viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty
                    || viewModel.isSending
            )
        }
        .padding()
    }
}
