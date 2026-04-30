import Foundation

enum CandidateType: Int, Codable, Sendable, CaseIterable {
    case goal = 0
    case project = 1
    case todo = 2
    case person = 3
    case infrastructure = 4
    case availability = 5
    case toneObservation = 6
    case fact = 7

    var jsonName: String {
        switch self {
        case .goal: "goal"
        case .project: "project"
        case .todo: "todo"
        case .person: "person"
        case .infrastructure: "infrastructure"
        case .availability: "availability"
        case .toneObservation: "tone_observation"
        case .fact: "fact"
        }
    }

    var displayName: String {
        switch self {
        case .goal: "Goal"
        case .project: "Project"
        case .todo: "Todo"
        case .person: "Person"
        case .infrastructure: "Infrastructure"
        case .availability: "Availability"
        case .toneObservation: "Tone observation"
        case .fact: "Fact"
        }
    }

    var icon: String {
        switch self {
        case .goal: "target"
        case .project: "folder"
        case .todo: "checklist"
        case .person: "person.crop.circle"
        case .infrastructure: "server.rack"
        case .availability: "calendar.badge.clock"
        case .toneObservation: "waveform"
        case .fact: "lightbulb"
        }
    }

    static func fromJSON(_ name: String) -> CandidateType? {
        CandidateType.allCases.first { $0.jsonName == name }
    }
}

enum CandidateStatus: Int, Codable, Sendable {
    case pending = 0
    case confirmed = 1
    case rejected = 2
    case autoApplied = 3
}
