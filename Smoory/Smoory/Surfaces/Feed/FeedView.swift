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

    // statusRaw 1 = .confirmed, 3 = .autoApplied. Both render under the "Confirmed"
    // filter — they are facts/entities that have been applied to the system, the
    // distinction being whether the user reviewed them (1) or the LLM wrote silently (3).
    @Query(
        filter: #Predicate<CandidateWrite> { $0.statusRaw == 1 || $0.statusRaw == 3 },
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
    @State private var calendar = FeedCalendarLoader()

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(text: $viewModel.searchText, placeholder: "Search feed")
                .padding(.horizontal)
                .padding(.top, 4)
            filterPills

            let rows = currentRows

            List {
                calendarContent

                Section {
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
                        Text(err).font(.smoory_caption).foregroundStyle(.red)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    candidatesSectionHeader
                }
            }
            .listStyle(.inset)
        }
        .task { await calendar.load() }
    }

    @ViewBuilder
    private var candidatesSectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray")
                .foregroundStyle(.tertiary)
                .imageScale(.small)
            Text("To review")
                .font(.smoory_heading)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var calendarContent: some View {
        switch calendar.state {
        case .loading:
            EmptyView()
        case .ready(let sections):
            calendarSections(sections)
        case .denied:
            calendarStatusRow(
                symbol: "calendar.badge.exclamationmark",
                title: "Calendar access required.",
                detail: "Grant full access in System Settings to see your next 3 days here.",
                actionTitle: "Open Settings",
                action: { calendar.openCalendarPrivacySettings() }
            )
        case .restricted:
            calendarStatusRow(
                symbol: "lock.shield",
                title: "Calendar access restricted.",
                detail: "A system policy is blocking calendar reads on this Mac.",
                actionTitle: nil,
                action: nil
            )
        case .error(let message):
            calendarStatusRow(
                symbol: "exclamationmark.triangle",
                title: "Couldn't load calendar.",
                detail: message,
                actionTitle: "Try again",
                action: { Task { await calendar.load() } }
            )
        }
    }

    @ViewBuilder
    private func calendarSections(_ sections: [FeedCalendarLoader.DaySection]) -> some View {
        let filtered = FeedCalendarLoader.filtered(sections, query: viewModel.searchText)
        let allEmpty = filtered.allSatisfy(\.isEmpty)
        let hasActiveSearch = !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty

        if allEmpty {
            // Collapse a fully-empty window to a single neutral line. Keep the section
            // header so calendar context still has its slot above the candidates.
            Section {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .foregroundStyle(.tertiary)
                        .imageScale(.small)
                    Text(hasActiveSearch
                         ? "No events match \u{201C}\(viewModel.searchText)\u{201D}."
                         : "Nothing scheduled in the next 3 days.")
                        .font(.smoory_caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                calendarSectionHeader
            }
        } else {
            ForEach(filtered) { section in
                Section {
                    if section.isEmpty {
                        Text("Nothing scheduled.")
                            .font(.smoory_caption)
                            .foregroundStyle(.tertiary)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(section.allDay) { item in
                            CalendarEventRow(item: item).listRowSeparator(.hidden)
                        }
                        ForEach(section.timed) { item in
                            CalendarEventRow(item: item).listRowSeparator(.hidden)
                        }
                    }
                } header: {
                    daySectionHeader(section.header)
                }
            }
        }
    }

    @ViewBuilder
    private var calendarSectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .foregroundStyle(.tertiary)
                .imageScale(.small)
            Text("Next 3 days")
                .font(.smoory_heading)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func daySectionHeader(_ header: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .foregroundStyle(.tertiary)
                .imageScale(.small)
            Text(header).font(.smoory_heading)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func calendarStatusRow(
        symbol: String,
        title: String,
        detail: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.tertiary)
                    .imageScale(.medium)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.smoory_body)
                    Text(detail).font(.smoory_caption).foregroundStyle(.secondary)
                    if let actionTitle, let action {
                        Button(actionTitle, action: action)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .padding(.top, 4)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            calendarSectionHeader
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

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterPicker(
                    selected: $viewModel.statusFilter,
                    titleProvider: { $0.title },
                    isAllCase: { $0 == .pending }
                )

                FilterPicker(
                    selected: $viewModel.typeFilter,
                    titleProvider: { $0.title },
                    isAllCase: { $0 == .all }
                )
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        EmptyState(
            symbol: "tray",
            headline: "Nothing to review.",
            detail: "Smoory will surface things here as they come up."
        )
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
