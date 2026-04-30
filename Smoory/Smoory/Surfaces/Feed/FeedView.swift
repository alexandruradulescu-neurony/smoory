import SwiftData
import SwiftUI

struct FeedView: View {
    @State private var viewModel = FeedViewModel()

    var body: some View {
        FeedListContent(viewModel: viewModel)
            .navigationTitle(Surface.feed.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FeedListContent: View {
    @Bindable var viewModel: FeedViewModel

    @Environment(\.modelContext) private var modelContext
    @Environment(\.hemaState) private var hemaState

    @Query(
        filter: #Predicate<CandidateWrite> { $0.statusRaw == 0 },
        sort: \CandidateWrite.createdAt, order: .reverse
    )
    private var pendingCandidates: [CandidateWrite]

    @Query(
        filter: #Predicate<CandidateWrite> { $0.statusRaw == 1 },
        sort: \CandidateWrite.createdAt, order: .reverse
    )
    private var confirmedCandidates: [CandidateWrite]

    @Query(
        filter: #Predicate<CandidateWrite> { $0.statusRaw == 2 },
        sort: \CandidateWrite.createdAt, order: .reverse
    )
    private var rejectedCandidates: [CandidateWrite]

    // No predicate on FeedItem — SwiftData @Predicate can't access enum .rawValue, and direct
    // enum comparison crashes the validator on FeedItemState. 2.5 has no FeedItem producers,
    // so we fetch all and filter client-side. Future producers add small N here.
    @Query(sort: \FeedItem.createdAt, order: .reverse)
    private var allFeedItems: [FeedItem]

    private var activeFeedItems: [FeedItem] {
        allFeedItems.filter { $0.state == .active }
    }

    @State private var expandedRowID: UUID?
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            filterPills

            let rows = currentRows

            List {
                if rows.isEmpty {
                    emptyState
                } else {
                    ForEach(rows) { row in
                        rowView(for: row)
                            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                            .listRowSeparator(.hidden)
                    }
                }
                if let err = actionError {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func rowView(for row: FeedRow) -> some View {
        switch row {
        case .candidate(let candidate):
            CandidateFeedRow(
                candidate: candidate,
                isExpanded: expandedRowID == candidate.id,
                onToggleExpand: { toggleExpand(candidate.id) },
                onConfirm: { Task { await confirm(candidate) } },
                onReject: { Task { await reject(candidate) } }
            )
        case .feedItem(let item):
            FeedItemRow(
                item: item,
                isExpanded: expandedRowID == item.id,
                onToggleExpand: { toggleExpand(item.id) }
            )
        }
    }

    private var currentRows: [FeedRow] {
        let candidates: [CandidateWrite]
        switch viewModel.statusFilter {
        case .pending: candidates = pendingCandidates
        case .confirmed: candidates = confirmedCandidates
        case .rejected: candidates = rejectedCandidates
        }
        let items = viewModel.statusFilter == .pending ? activeFeedItems : []
        return viewModel.compose(candidates: candidates, feedItems: items)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search feed", text: $viewModel.searchText)
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
                Picker(viewModel.statusFilter.title, selection: $viewModel.statusFilter) {
                    ForEach(FeedStatusFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .tint(viewModel.statusFilter == .pending ? .secondary : .accentColor)

                Picker(viewModel.typeFilter.title, selection: $viewModel.typeFilter) {
                    ForEach(FeedTypeFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .tint(viewModel.typeFilter == .all ? .secondary : .accentColor)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("Nothing to review.")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Smoory will surface things here as they come up — emails, candidates, briefs, alerts.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowBackground(Color.clear)
    }

    private func toggleExpand(_ id: UUID) {
        if expandedRowID == id { expandedRowID = nil } else { expandedRowID = id }
    }

    private func confirm(_ candidate: CandidateWrite) async {
        guard case .ready(let hema) = hemaState else {
            actionError = "Memory not ready yet."
            return
        }
        do {
            try await CandidateAcceptor.accept(
                candidate: candidate,
                modelContainer: modelContext.container,
                hema: hema
            )
            actionError = nil
        } catch {
            actionError = "Could not accept: \(error.localizedDescription)"
        }
    }

    private func reject(_ candidate: CandidateWrite) async {
        do {
            try CandidateAcceptor.reject(
                candidate: candidate,
                modelContainer: modelContext.container
            )
            actionError = nil
        } catch {
            actionError = "Could not reject: \(error.localizedDescription)"
        }
    }
}
