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
        case .ready(let allDay, let timed) where allDay.isEmpty && timed.isEmpty:
            placeholder
        case .ready(let allDay, let timed):
            eventList(allDay: allDay, timed: timed)
        case .denied:
            deniedView
        case .restricted:
            restrictedView
        case .error(let message):
            errorView(message)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 16) {
            Image(systemName: surface.symbol)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(surface.title)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }

    private func eventList(allDay: [CalendarEvent], timed: [CalendarEvent]) -> some View {
        List {
            if !allDay.isEmpty {
                Section("All-day") {
                    ForEach(allDay) { EventRow(event: $0) }
                }
            }
            if !timed.isEmpty {
                Section("Today") {
                    ForEach(timed) { EventRow(event: $0) }
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
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(event.isAllDay ? "All day" : timeRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                Text(event.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            if let location = event.location {
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 104)
            }
        }
        .padding(.vertical, 2)
    }

    private var timeRange: String {
        let s = event.start.formatted(date: .omitted, time: .shortened)
        let e = event.end.formatted(date: .omitted, time: .shortened)
        return "\(s) – \(e)"
    }
}

#Preview {
    FeedView()
}
