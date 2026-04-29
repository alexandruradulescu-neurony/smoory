import Foundation

enum RuleKind: Int, Codable, Sendable {
    case autoArchiveSender = 0
    case autoArchivePattern = 1
    case priorityBoost = 2
    case priorityDemote = 3
    case neverPropose = 4
}
