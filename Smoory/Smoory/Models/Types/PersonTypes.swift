import Foundation

enum LengthPref: Int, Codable, Sendable {
    case terse = 0
    case balanced = 1
    case verbose = 2
}

struct ToneProfile: Hashable, Sendable {
    var registerScore: Double          // -1 (very formal) to +1 (very casual)
    var lengthPreference: LengthPref
    var greetingStyle: String?
    var signOffStyle: String?
    var observations: [String] = []
    var observationCount: Int = 0
}

extension ToneProfile: Codable {}

struct ToneOverride: Hashable, Sendable {
    var preferredRegister: Double?
    var preferredLength: LengthPref?
    var notes: String?
}

extension ToneOverride: Codable {}
