import Foundation

protocol Embedder: Sendable {
    var dimension: Int { get }
    var modelIdentifier: String { get }
    func embed(_ texts: [String], inputType: EmbeddingInputType) async throws -> [[Float]]
}

extension Embedder {
    /// Convenience overload — defaults to `.document` (storage path).
    func embed(_ texts: [String]) async throws -> [[Float]] {
        try await embed(texts, inputType: .document)
    }
}

enum EmbeddingInputType: String, Sendable {
    case document
    case query
}

enum EmbedderError: Error {
    case missingAPIKey
    case network(URLError)
    case unauthorized
    case rateLimited
    case server(status: Int, body: String?)
    case unexpectedDimension(expected: Int, got: Int)
    case decoding(Error)
}
