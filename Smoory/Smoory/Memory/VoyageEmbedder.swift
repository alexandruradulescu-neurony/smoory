import Foundation

final class VoyageEmbedder: Embedder, @unchecked Sendable {
    let dimension: Int = 1024
    let modelIdentifier: String = "voyage-3"

    struct EmbedResult: Sendable {
        let embeddings: [[Float]]
        let totalTokens: Int?     // nil if Voyage's response omitted the usage block
    }

    private static let endpoint = URL(string: "https://api.voyageai.com/v1/embeddings")!

    private let session: URLSession
    private let apiKeyProvider: @Sendable () -> String?

    init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping @Sendable () -> String? = {
            KeychainService.read(service: KeychainService.voyageAPIKeyService)
        }
    ) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
    }

    // MARK: - Embedder

    func embed(_ texts: [String], inputType: EmbeddingInputType) async throws -> [[Float]] {
        try await performRequest(texts, inputType: inputType).embeddings
    }

    /// Variant that exposes Voyage's usage payload for diagnostics. Not part of the
    /// `Embedder` protocol — debug-only consumers (e.g. the Test Voyage embedding menu).
    func embedWithUsage(_ texts: [String], inputType: EmbeddingInputType = .document) async throws -> EmbedResult {
        try await performRequest(texts, inputType: inputType)
    }

    // MARK: - Internals

    private func performRequest(_ texts: [String], inputType: EmbeddingInputType) async throws -> EmbedResult {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw EmbedderError.missingAPIKey
        }

        let body = VoyageRequest(
            model: modelIdentifier,
            input: texts,
            input_type: inputType.rawValue
        )

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw EmbedderError.decoding(error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw EmbedderError.network(urlError)
        } catch {
            throw EmbedderError.network(URLError(.unknown))
        }

        guard let http = response as? HTTPURLResponse else {
            throw EmbedderError.server(status: -1, body: "non-HTTP URLResponse")
        }

        switch http.statusCode {
        case 200:
            let decoded: VoyageResponse
            do {
                decoded = try JSONDecoder().decode(VoyageResponse.self, from: data)
            } catch {
                throw EmbedderError.decoding(error)
            }

            // Defensive: sort by index in case Voyage ever returns out of order.
            let sorted = decoded.data.sorted { $0.index < $1.index }
            let embeddings = sorted.map(\.embedding)
            for embedding in embeddings {
                guard embedding.count == dimension else {
                    throw EmbedderError.unexpectedDimension(expected: dimension, got: embedding.count)
                }
            }
            return EmbedResult(embeddings: embeddings, totalTokens: decoded.usage?.total_tokens)

        case 401:
            throw EmbedderError.unauthorized
        case 429:
            throw EmbedderError.rateLimited
        default:
            throw EmbedderError.server(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }
    }

    // MARK: - Wire shapes

    private struct VoyageRequest: Encodable {
        let model: String
        let input: [String]
        let input_type: String
    }

    private struct VoyageResponse: Decodable {
        let data: [Item]
        let model: String?
        let usage: Usage?

        struct Item: Decodable {
            let embedding: [Float]
            let index: Int
        }
        struct Usage: Decodable {
            let total_tokens: Int
        }
    }
}
