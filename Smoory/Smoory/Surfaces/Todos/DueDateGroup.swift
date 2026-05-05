import SwiftUI

enum DueDateGroup: String, CaseIterable, Identifiable {
    case overdue
    case today
    case thisWeek
    case later
    case noDueDate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overdue: "Overdue"
        case .today: "Today"
        case .thisWeek: "This week"
        case .later: "Later"
        case .noDueDate: "No due date"
        }
    }

    var color: Color {
        switch self {
        case .overdue: .red
        case .today: .orange
        case .thisWeek: .yellow
        case .later: .secondary
        case .noDueDate: .secondary
        }
    }

    static func group(for item: UserListItem, now: Date = Date()) -> DueDateGroup {
        guard let dueDate = item.dueDate else { return .noDueDate }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        guard
            let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
            let startOfNextWeek = calendar.date(byAdding: .day, value: 7, to: startOfToday)
        else {
            return .later
        }

        if dueDate < startOfToday { return .overdue }
        if dueDate < startOfTomorrow { return .today }
        if dueDate < startOfNextWeek { return .thisWeek }
        return .later
    }
}
