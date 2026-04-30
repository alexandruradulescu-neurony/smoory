import SwiftUI

struct TurnsListView: View {
    @Bindable var viewModel: TurnsListViewModel
    let hema: HemaService

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(text: $viewModel.searchText, placeholder: "Search conversation turns")
                .padding(.horizontal)
                .padding(.top, 4)
            filterPills
            statusBanner

            List {
                if viewModel.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                } else if viewModel.displayedTurns.isEmpty {
                    emptyState
                } else {
                    ForEach(viewModel.groupedBySession, id: \.sessionID) { group, turns in
                        Section {
                            ForEach(turns) { turn in
                                NavigationLink(value: turn) {
                                    TurnRow(turn: turn)
                                }
                            }
                        } header: {
                            sessionHeader(sessionID: group, latestAt: turns.first?.createdAt ?? Date())
                        }
                    }
                }
                if let err = viewModel.loadError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.inset)
        }
    }

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterPicker(
                    selected: $viewModel.dateRangeFilter,
                    titleProvider: { $0.title },
                    isAllCase: { $0 == .all }
                )
                .onChange(of: viewModel.dateRangeFilter) { _, _ in Task { await viewModel.load() } }

                FilterPicker(
                    selected: $viewModel.roleFilter,
                    titleProvider: { $0.title },
                    isAllCase: { $0 == .all }
                )
                .onChange(of: viewModel.roleFilter) { _, _ in Task { await viewModel.load() } }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        let displayed = viewModel.displayedTurns.count
        let total = viewModel.allTurns.count
        if viewModel.hasActiveFilters || displayed != total {
            Text("Showing \(displayed) of \(total) turns")
                .font(.smoory_caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 4)
        }
    }

    private func sessionHeader(sessionID: UUID, latestAt: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.tertiary)
                .imageScale(.small)
            Text("Session \(String(sessionID.uuidString.prefix(8)))")
                .font(.smoory_heading)
            Text(FactRow.relativeAge(latestAt))
                .font(.smoory_caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !viewModel.searchText.isEmpty {
            EmptyState(
                symbol: "bubble.left.and.bubble.right",
                headline: "No turns match \u{201C}\(viewModel.searchText)\u{201D}.",
                detail: nil
            )
            .listRowBackground(Color.clear)
        } else if viewModel.hasActiveFilters {
            EmptyState(
                symbol: "bubble.left.and.bubble.right",
                headline: "No turns match your filters.",
                detail: nil
            )
            .listRowBackground(Color.clear)
        } else {
            EmptyState(
                symbol: "bubble.left.and.bubble.right",
                headline: "No conversations yet.",
                detail: "Start a chat — your messages are saved here."
            )
            .listRowBackground(Color.clear)
        }
    }
}
