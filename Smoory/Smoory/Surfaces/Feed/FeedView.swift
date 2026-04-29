import SwiftUI

struct FeedView: View {
    private let surface: Surface = .feed
    @State private var viewModel = FeedViewModel()

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(surface.title)
            .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().controlSize(.small)
        case .ready(let sections):
            eventList(sections: sections)
        case .denied:
            deniedView
        case .restricted:
            restrictedView
        case .error(let message):
            errorView(message)
        }
    }

    private func eventList(sections: [FeedViewModel.DaySection]) -> some View {
        List {
            ForEach(sections) { section in
                Section(section.header) {
                    if section.isEmpty {
                        Text("Nothing scheduled")
                            .foregroundStyle(.tertiary)
                            .font(.callout)
                    } else {
                        ForEach(section.allDay) { item in
                            EventRow(item: item)
                        }
                        ForEach(section.timed) { item in
                            EventRow(item: item)
                        }
                    }
                }
            }
        }
    }

    private var deniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Calendar access required")
                .font(.title3)
            Text("Smoory needs full Calendar access to surface today's events.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Calendar Settings") {
                viewModel.openCalendarPrivacySettings()
            }
            .padding(.top, 4)
        }
        .padding()
    }

    private var restrictedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Calendar access restricted")
                .font(.title3)
            Text("Calendar access is blocked by a system policy on this Mac. Smoory can't read your events here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Couldn't load calendar")
                .font(.title3)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") {
                Task { await viewModel.load() }
            }
            .padding(.top, 4)
        }
        .padding()
    }
}

private struct EventRow: View {
    let item: FeedViewModel.DaySection.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.event.isAllDay ? "All day" : timeRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                titleAndSuffix
            }
            if let location = item.event.location {
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 104)
            }
        }
        .padding(.vertical, 2)
    }

    private var titleAndSuffix: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.event.title)
                .fontWeight(.medium)
                .lineLimit(1)
            if let suffix = item.trailingSuffix {
                Text(suffix)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var timeRange: String {
        let s = item.event.start.formatted(date: .omitted, time: .shortened)
        let e = item.event.end.formatted(date: .omitted, time: .shortened)
        return "\(s) – \(e)"
    }
}

#Preview {
    FeedView()
}
