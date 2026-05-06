import EventKit
import SwiftUI

/// Calendar section in Settings. Shows authorization status, the "Smoory writes
/// here" picker, and per-calendar read toggles. Eagerly initializes its VM so
/// the section paints fully populated on first frame (F-17 pattern).
struct CalendarSettingsSection: View {
    @State private var vm: CalendarSettingsViewModel

    init(calendarService: CalendarService) {
        _vm = State(wrappedValue: CalendarSettingsViewModel(calendarService: calendarService))
    }

    var body: some View {
        Section("Calendar") {
            authorizationRow

            if vm.availableCalendars.isEmpty {
                Text("No calendars yet — create one in Calendar.app, then return here.")
                    .font(.smoory_caption)
                    .foregroundStyle(.tertiary)
            } else {
                writableCalendarPicker
                readToggleList
                helperCaption
            }
        }
    }

    @ViewBuilder
    private var authorizationRow: some View {
        let status = EKEventStore.authorizationStatus(for: .event)
        HStack {
            Image(systemName: status == .fullAccess ? "calendar.badge.checkmark" : "calendar.badge.exclamationmark")
                .foregroundStyle(status == .fullAccess ? Color.green : Color.orange)
            Text(authorizationLabel(for: status))
                .font(.smoory_body)
            Spacer()
        }
        if status != .fullAccess {
            Text("Open System Settings → Privacy & Security → Calendars and grant Smoory full access.")
                .font(.smoory_caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var writableCalendarPicker: some View {
        Picker("Smoory writes here", selection: $vm.writableCalendarID) {
            Text("System default").tag("")
            ForEach(vm.writableCalendars, id: \.calendarIdentifier) { cal in
                Text(cal.title).tag(cal.calendarIdentifier)
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var readToggleList: some View {
        Text("Read from these calendars")
            .font(.smoory_caption)
            .foregroundStyle(.secondary)
        ForEach(vm.availableCalendars, id: \.calendarIdentifier) { cal in
            Toggle(isOn: vm.includedBinding(for: cal)) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(cgColor: cal.cgColor))
                        .frame(width: 10, height: 10)
                    Text(cal.title)
                        .font(.smoory_body)
                    Spacer()
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    @ViewBuilder
    private var helperCaption: some View {
        Text("Smoory creates / moves / deletes events on the writes-here calendar. Reading covers every checked calendar above.")
            .font(.smoory_caption)
            .foregroundStyle(.tertiary)
    }

    private func authorizationLabel(for status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: return "Authorized — full access"
        case .writeOnly: return "Write-only access (insufficient — needs full access)"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Permission will be requested"
        @unknown default: return "Unknown"
        }
    }
}
