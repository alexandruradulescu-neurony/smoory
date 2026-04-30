import SwiftUI

struct FactsListView: View {
    @Bindable var viewModel: FactsListViewModel

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

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search facts (body or tags)", text: $viewModel.searchText)
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
                Picker(viewModel.ageFilter.title, selection: $viewModel.ageFilter) {
                    ForEach(FactsListViewModel.AgeFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .tint(viewModel.ageFilter == .all ? .secondary : .accentColor)
                .onChange(of: viewModel.ageFilter) { _, _ in Task { await viewModel.load() } }

                Picker(viewModel.confidenceFilter.title, selection: $viewModel.confidenceFilter) {
                    ForEach(FactsListViewModel.ConfidenceFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .tint(viewModel.confidenceFilter == .all ? .secondary : .accentColor)
                .onChange(of: viewModel.confidenceFilter) { _, _ in Task { await viewModel.load() } }

                Picker(viewModel.confirmationFilter.title, selection: $viewModel.confirmationFilter) {
                    ForEach(FactsListViewModel.ConfirmationFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .tint(viewModel.confirmationFilter == .all ? .secondary : .accentColor)

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
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private var tagButtonLabel: String {
        if viewModel.selectedTags.isEmpty { return "Tags" }
        if viewModel.selectedTags.count == 1 { return "Tag: \(viewModel.selectedTags.first!)" }
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
                    .font(.caption)
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
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 42)).foregroundStyle(.tertiary)
            if viewModel.hasActiveFilters {
                Text("No facts match your filters").font(.headline).foregroundStyle(.secondary)
            } else {
                Text("Hema has no facts yet").font(.headline).foregroundStyle(.secondary)
                Text("Talk to Smoory and high-confidence facts will be saved here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowBackground(Color.clear)
    }
}
