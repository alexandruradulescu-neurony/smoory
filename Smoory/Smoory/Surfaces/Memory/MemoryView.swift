import SwiftUI

/// Memory inspection surface. Renders nothing useful until hema is ready; mirrors ChatView's
/// hemaState-gated pattern.
struct MemoryView: View {
    @Environment(\.hemaState) private var hemaState

    var body: some View {
        Group {
            switch hemaState {
            case .loading:
                loadingView
            case .ready(let hema):
                MemoryContent(hema: hema)
            case .failed(let message):
                failedView(message)
            }
        }
        .navigationTitle(Surface.memory.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading memory…").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func failedView(_ message: String) -> some View {
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

/// Inner content view that owns the shared ViewModel and per-tab list view models.
/// The list VMs live here (not inside the tab views) so filter state survives tab switches.
private struct MemoryContent: View {
    let hema: HemaService
    @State private var viewModel = MemoryViewModel()
    @State private var factsVM: FactsListViewModel
    @State private var turnsVM: TurnsListViewModel

    init(hema: HemaService) {
        self.hema = hema
        _factsVM = State(wrappedValue: FactsListViewModel(hema: hema))
        _turnsVM = State(wrappedValue: TurnsListViewModel(hema: hema))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabSwitcher
                Group {
                    switch viewModel.selectedTab {
                    case .facts:
                        FactsListView(viewModel: factsVM)
                    case .turns:
                        TurnsListView(viewModel: turnsVM, hema: hema)
                    }
                }
            }
            .navigationDestination(for: SemanticFact.self) { fact in
                FactDetailView(fact: fact, viewModel: factsVM)
            }
            .navigationDestination(for: MemoryTurn.self) { turn in
                TurnDetailView(turn: turn, hema: hema)
            }
            // F-15 audit fix: previously `showPrivate` was reset to false on every
            // Facts-tab re-entry. The user complained it forced re-toggling after a
            // round-trip through Conversations. The toggle is a deliberate manual
            // action; once flipped it should stick for the session. Default-off
            // still applies on app launch (FactsListViewModel.showPrivate = false
            // at init) — only the per-tab-switch reset is removed.
        }
    }

    private var tabSwitcher: some View {
        Picker("", selection: $viewModel.selectedTab) {
            Text("Facts").tag(MemoryViewModel.Tab.facts)
            Text("Conversations").tag(MemoryViewModel.Tab.turns)
        }
        .pickerStyle(.segmented)
        .padding()
    }
}
