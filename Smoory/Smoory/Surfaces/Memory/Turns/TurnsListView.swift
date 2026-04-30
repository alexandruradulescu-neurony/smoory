import SwiftUI

struct TurnsListView: View {
    @Bindable var viewModel: TurnsListViewModel
    let hema: HemaService

    var body: some View {
        VStack(spacing: 0) {
            searchBar
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

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search conversation turns", text: $viewModel.searchText)
                .textFieldStyle(.plain)
            if !viewModel.searchText.isEmpty {
                Button { viewModel.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Picker(viewModel.dateRangeFilter.title, selection: $viewModel.dateRangeFilter) {
                    ForEach(TurnsListViewModel.DateRangeFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .tint(viewModel.dateRangeFilter == .all ? .secondary : .accentColor)
                .onChange(of: viewModel.dateRangeFilter) { _, _ in Task { await viewModel.load() } }

                Picker(viewModel.roleFilter.title, selection: $viewModel.roleFilter) {
                    ForEach(TurnsListViewModel.RoleFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .tint(viewModel.roleFilter == .all ? .secondary : .accentColor)
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
                .font(.caption)
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
                .font(.headline)
            Text(FactRow.relativeAge(latestAt))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            if viewModel.hasActiveFilters {
                Text("No turns match your filters").font(.headline).foregroundStyle(.secondary)
            } else {
                Text("No conversation turns yet").font(.headline).foregroundStyle(.secondary)
                Text("Send a message in Chat — turns are recorded as they happen.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowBackground(Color.clear)
    }
}
