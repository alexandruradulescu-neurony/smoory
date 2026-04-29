import Foundation

enum InfraCategory: Int, Codable, Sendable {
    case hosting = 0
    case domain = 1
    case saas = 2
    case payment = 3
    case sourceControl = 4
    case emailProvider = 5
    case other = 6
}
