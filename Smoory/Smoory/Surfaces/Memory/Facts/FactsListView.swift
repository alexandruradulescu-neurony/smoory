import SwiftUI

struct FactsListView: View {
    @Bindable var viewModel: FactsListViewModel

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(text: $viewModel.searchText, placeholder: "Search facts (body or tags)")
                .padding(.horizontal)
                .padding(.top, 4)
            filterPills
            statusBanner

            List {
                if viewModel.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                } else if viewModel.displayedFacts.isEmpty {
                    emptyState
                } else {
                    ForEach(viewModel.displayedFacts) { fact in
                        NavigationLink(value: fact) {
                            FactRow(fact: fact)
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
                    selected: $viewModel.ageFilter,
                    titleProvider: { $0.title },
                    isAllCase: { $0 == .all }
                )
                .onChange(of: viewModel.ageFilter) { _, _ in Task { await viewModel.load() } }

                FilterPicker(
                    selected: $viewModel.confidenceFilter,
                    titleProvider: { $0.title },
                    isAllCase: { $0 == .all }
                )
                .onChange(of: viewModel.confidenceFilter) { _, _ in Task { await viewModel.load() } }

                FilterPicker(
                    selected: $viewModel.confirmationFilter,
                    titleProvider: { $0.title },
                    isAllCase: { $0 == .all }
                )

                FilterPicker(
                    selected: $viewModel.lifecycleFilter,
                    titleProvider: { $0.title },
                    isAllCase: { $0 == .active }
                )

                Menu(tagButtonLabel) {
                    ForEach(viewModel.availableTags, id: \.self) { tag in
                        Toggle(tag, isOn: Binding(
                            get: { viewModel.selectedTags.contains(tag) },
                            set: { isOn in
                                if isOn { viewModel.selectedTags.insert(tag) }
                                else { viewModel.selectedTags.remove(tag) }
                                Task { await viewModel.load() }
                            }
                        ))
                    }
                    if !viewModel.selectedTags.isEmpty {
                        Divider()
                        Button("Clear tags") {
                            viewModel.selectedTags.removeAll()
                            Task { await viewModel.load() }
                        }
                    }
                }
                .tint(viewModel.selectedTags.isEmpty ? .secondary : .accentColor)
                .font(.smoory_caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private var tagButtonLabel: String {
        if viewModel.selectedTags.isEmpty { return "Tags" }
        if viewModel.selectedTags.count == 1, let tag = viewModel.selectedTags.first {
            return "Tag: \(tag)"
        }
        return "Tags (\(viewModel.selectedTags.count))"
    }

    @ViewBuilder
    private var statusBanner: some View {
        let displayed = viewModel.displayedFacts.count
        let total = viewModel.facts.count
        let active = viewModel.hasActiveFilters
        if active || displayed != total {
            HStack {
                Text("Showing \(displayed) of \(total) facts")
                    .font(.smoory_caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Show private", isOn: $viewModel.showPrivate)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.bottom, 4)
        } else {
            HStack {
                Spacer()
                Toggle("Show private", isOn: $viewModel.showPrivate)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !viewModel.searchText.isEmpty {
            EmptyState(
                symbol: "tray",
                headline: "No facts match \u{201C}\(viewModel.searchText)\u{201D}.",
                detail: nil
            )
            .listRowBackground(Color.clear)
        } else if viewModel.hasActiveFilters {
            EmptyState(
                symbol: "tray",
                headline: "No facts match your filters.",
                detail: nil
            )
            .listRowBackground(Color.clear)
        } else {
            EmptyState(
                symbol: "tray",
                headline: "No facts yet.",
                detail: "Smoory will save things it learns as you talk."
            )
            .listRowBackground(Color.clear)
        }
    }
}
