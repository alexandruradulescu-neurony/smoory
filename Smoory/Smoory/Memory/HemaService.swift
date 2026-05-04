import Foundation
import SQLiteVec

final class HemaService: @unchecked Sendable {
    static let defaultDatabaseURL: URL = URL.applicationSupportDirectory
        .appendingPathComponent("Smoory/hema.sqlite")

    let databaseURL: URL
    var db: Database          // non-private so HemaService+Diagnostics can access during ops
    let embedder: Embedder?   // non-private so HemaService+Diagnostics can re-embed for dedupe

    /// Async because opening the DB and running migrations can throw and suspend.
    /// Throws on first-run DB-init failure — hema is essential, no graceful fallback.
    /// `embedder` is optional: nil means writes store rows without vectors (degraded mode for
    /// tests). In production the App always passes a VoyageEmbedder; missing-key situations
    /// degrade per-call rather than at construction.
    init(databaseURL: URL? = nil, embedder: Embedder? = nil) async throws {
        let url = databaseURL ?? Self.defaultDatabaseURL
        self.databaseURL = url
        self.embedder = embedder

        let parentDir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        do {
            // SQLiteVec opens with SQLITE_OPEN_URI set, so the location string is parsed as a URI.
            // Pass absoluteString (file:///.../Application%20Support/...) — a raw path with
            // unencoded spaces fails URI parsing and surfaces as SQLITE_CANTOPEN (14).
            self.db = try Database(.uri(url.absoluteString))
        } catch {
            throw HemaServiceError.databaseInit(error)
        }
        try await HemaSchema.applyPending(to: db)
    }

    // MARK: - Writes

    func writeTurn(_ turn: MemoryTurn) async throws {
        var vector: [Float]? = turn.vector
        if vector == nil, let embedder = embedder {
            do {
                vector = try await embedder.embed([turn.content]).first
            } catch {
                print("[hema] embed failed for turn \(turn.id) — storing without vector: \(error)")
                vector = nil
            }
        }

        let params: [any Sendable] = [
            turn.id.uuidString,
            turn.createdAt.formatted(.iso8601),
            turn.chatSessionID.uuidString,
            turn.role.rawValue,
            turn.content
        ]
        try await db.execute("""
            INSERT INTO memory_turns
                (id, created_at, chat_session_id, role, content)
            VALUES (?, ?, ?, ?, ?)
        """, params: params)

        if let vector {
            let rowid = await db.lastInsertRowId
            try await db.execute("""
                INSERT INTO memory_turns_vec (rowid, embedding) VALUES (?, ?)
            """, params: [rowid, vector])
        }
    }

    /// Writes a fact with insert-time dedup. Returns the id of the surviving row:
    /// either `fact.id` (newly inserted) or the existing duplicate's id (skipped insert).
    /// Callers should record the returned id, not `fact.id`, when storing audit references.
    @discardableResult
    func writeFact(_ fact: SemanticFact) async throws -> UUID {
        let tagsJSON = try Self.encodeJSON(fact.tags)
        let entitiesJSON = try Self.encodeJSON(fact.entitiesReferenced)

        var vector: [Float]? = fact.vector
        if vector == nil, let embedder = embedder {
            do {
                vector = try await embedder.embed([fact.body]).first
            } catch {
                print("[hema] embed failed for fact \(fact.id) — storing without vector: \(error)")
                vector = nil
            }
        }

        // Dedup pre-check. If a non-superseded fact already covers this content
        // (exact normalized body OR cosine sim ≥ 0.95), skip the INSERT and return
        // its id. Optionally upgrade metadata when the new write is "stronger".
        if let dupID = try await findDuplicateFact(body: fact.body, embedding: vector) {
            if fact.userConfirmed {
                try await db.execute("""
                    UPDATE semantic_facts
                    SET user_confirmed = 1,
                        confidence = MAX(confidence, ?)
                    WHERE id = ?
                """, params: [fact.confidence, dupID.uuidString])
            }
            return dupID
        }

        let params: [any Sendable] = [
            fact.id.uuidString,
            fact.body,
            tagsJSON,
            entitiesJSON,
            fact.confidence,
            fact.userConfirmed,
            fact.isPrivate,
            fact.createdAt.formatted(.iso8601),
            fact.expiresAt?.formatted(.iso8601),
            fact.supersededBy?.uuidString,
            fact.provenanceJSON
        ]
        try await db.execute("""
            INSERT INTO semantic_facts
                (id, body, tags_json, entities_json, confidence, user_confirmed, is_private,
                 created_at, expires_at, superseded_by, provenance_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: params)

        if let vector {
            let rowid = await db.lastInsertRowId
            try await db.execute("""
                INSERT INTO semantic_facts_vec (rowid, embedding) VALUES (?, ?)
            """, params: [rowid, vector])
        }
        return fact.id
    }

    // MARK: - Dedup

    /// Cosine similarity at or above this counts as a semantic near-duplicate.
    static let dedupCosineSimilarityThreshold: Double = 0.95

    /// L2 distance threshold equivalent to the cosine threshold above, for unit-normalized
    /// Voyage embeddings. Derivation: ||a-b||² = 2 - 2·cos  ⇒  L2 ≤ √(2·(1 - cos)).
    static var dedupL2DistanceThreshold: Double {
        (2.0 * (1.0 - dedupCosineSimilarityThreshold)).squareRoot()
    }

    /// Body normalization for exact-match dedup: trim, unicode-lowercase, collapse
    /// runs of whitespace to a single space.
    static func normalizeBody(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.localizedLowercase
        return lowered.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
    }

    /// Returns the surviving id of a non-superseded fact that should be considered a
    /// duplicate of (`body`, `embedding`), or nil if no match. Two-step: exact normalized
    /// body match first (cheap), then nearest-neighbor in semantic_facts_vec (skipped if
    /// embedding is nil).
    func findDuplicateFact(body: String, embedding: [Float]?) async throws -> UUID? {
        let target = Self.normalizeBody(body)

        // Step 1: exact normalized-body match. Fetch in Swift to keep unicode-correct
        // case folding rather than relying on SQLite's ASCII-only LOWER().
        let rows = try await db.query("""
            SELECT id, body, user_confirmed, confidence, created_at
            FROM semantic_facts
            WHERE superseded_by IS NULL
        """)
        var candidates: [(id: UUID, userConfirmed: Bool, confidence: Double, createdAt: Date)] = []
        for row in rows {
            guard
                let stored = row["body"] as? String,
                Self.normalizeBody(stored) == target,
                let idStr = row["id"] as? String, let id = UUID(uuidString: idStr),
                let createdAtStr = row["created_at"] as? String,
                let createdAt = Self.parseISO8601Date(createdAtStr)
            else { continue }
            let confirmed = ((row["user_confirmed"] as? Int) ?? 0) != 0
            let conf = (row["confidence"] as? Double) ?? 0
            candidates.append((id, confirmed, conf, createdAt))
        }
        if let canonical = Self.pickCanonicalID(among: candidates) {
            return canonical
        }

        // Step 2: semantic near-match via vec0 nearest neighbor. Only runs when we have
        // an embedding to query with — degraded (no embedder) callers fall through.
        guard let embedding else { return nil }
        let l2Threshold = Self.dedupL2DistanceThreshold
        let nearest = try await db.query("""
            SELECT f.id, sub.distance
            FROM (
                SELECT rowid, distance
                FROM semantic_facts_vec
                WHERE embedding MATCH ?
                ORDER BY distance
                LIMIT 1
            ) sub
            JOIN semantic_facts f ON sub.rowid = f.rowid
            WHERE f.superseded_by IS NULL
        """, params: [embedding])
        guard
            let row = nearest.first,
            let distance = row["distance"] as? Double, distance <= l2Threshold,
            let idStr = row["id"] as? String, let id = UUID(uuidString: idStr)
        else { return nil }
        return id
    }

    /// Canonical pick rule for a duplicate group:
    /// 1. user_confirmed = true beats false
    /// 2. higher confidence
    /// 3. earlier created_at (preserve original provenance)
    /// 4. lexicographically smallest id (deterministic tie-break)
    static func pickCanonicalID(
        among facts: [(id: UUID, userConfirmed: Bool, confidence: Double, createdAt: Date)]
    ) -> UUID? {
        facts.sorted { a, b in
            if a.userConfirmed != b.userConfirmed { return a.userConfirmed && !b.userConfirmed }
            if a.confidence != b.confidence { return a.confidence > b.confidence }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }.first?.id
    }

    /// Same canonical rule but operating on full SemanticFact values — used by the
    /// diagnostics dedupe pass which needs to know which fact survives, not just the id.
    static func pickCanonicalFact(among facts: [SemanticFact]) -> SemanticFact? {
        facts.sorted { a, b in
            if a.userConfirmed != b.userConfirmed { return a.userConfirmed && !b.userConfirmed }
            if a.confidence != b.confidence { return a.confidence > b.confidence }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }.first
    }

    /// Internal alias for the private parseISO8601 helper, exposed at fileprivate
    /// scope so dedup helpers in the same class can reuse the same parser.
    fileprivate static func parseISO8601Date(_ string: String?) -> Date? {
        parseISO8601(string)
    }

    func writeCompactMemory(_ memory: CompactMemory) async throws {
        let params: [any Sendable] = [
            memory.id.uuidString,
            memory.kind.rawValue,
            memory.body,
            memory.wordCount,
            memory.generatedAt.formatted(.iso8601),
            memory.supersededAt?.formatted(.iso8601),
            memory.generatingModel
        ]
        try await db.execute("""
            INSERT INTO compact_memory
                (id, kind, body, word_count, generated_at, superseded_at, generating_model)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: params)
    }

    /// Writes a new active compact memory of the given kind and supersedes any
    /// previously-active row of the same kind in a single transaction. Preserves
    /// the spec invariant: exactly one row per kind has `superseded_at = NULL`.
    /// `writeCompactMemory` (above) keeps its INSERT-only semantics for the
    /// diagnostics self-test path.
    func replaceActiveCompactMemory(_ memory: CompactMemory) async throws {
        let now = Date().formatted(.iso8601)
        try await db.transaction {
            // Step 1: supersede any existing active row of this kind.
            try await self.db.execute("""
                UPDATE compact_memory
                SET superseded_at = ?
                WHERE kind = ? AND superseded_at IS NULL
            """, params: [now, memory.kind.rawValue])

            // Step 2: insert the new row.
            let insertParams: [any Sendable] = [
                memory.id.uuidString,
                memory.kind.rawValue,
                memory.body,
                memory.wordCount,
                memory.generatedAt.formatted(.iso8601),
                memory.supersededAt?.formatted(.iso8601),
                memory.generatingModel
            ]
            try await self.db.execute("""
                INSERT INTO compact_memory
                    (id, kind, body, word_count, generated_at, superseded_at, generating_model)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, params: insertParams)
        }
    }

    // MARK: - Reads

    func readActiveCompactMemories() async throws -> [CompactMemory] {
        // COALESCE nullable text columns: SQLiteVec caches column types from row 1 only and
        // crashes on later NULLs (Database.swift:318/352).
        let rows = try await db.query("""
            SELECT id, kind, body, word_count, generated_at,
                   COALESCE(superseded_at, '') AS superseded_at,
                   COALESCE(generating_model, '') AS generating_model
            FROM compact_memory
            WHERE superseded_at IS NULL
            ORDER BY generated_at DESC
        """)
        return try rows.map { try Self.decodeCompactMemory(from: $0) }
    }

    func readFact(id: UUID) async throws -> SemanticFact? {
        let rows = try await db.query("""
            SELECT id, body, tags_json, entities_json, confidence, user_confirmed, is_private,
                   created_at,
                   COALESCE(expires_at, '') AS expires_at,
                   COALESCE(superseded_by, '') AS superseded_by,
                   COALESCE(provenance_json, '') AS provenance_json,
                   COALESCE(status, 'active') AS status
            FROM semantic_facts
            WHERE id = ?
            LIMIT 1
        """, params: [id.uuidString])
        guard let row = rows.first else { return nil }
        return try Self.decodeFact(from: row, vector: nil)
    }

    func readAllFacts(filter: FactFilter? = nil, limit: Int = 500, offset: Int = 0) async throws -> [SemanticFact] {
        var clauses: [String] = ["1=1"]
        var params: [any Sendable] = []

        let f = filter ?? FactFilter()

        if !f.includeExpired {
            clauses.append("(expires_at IS NULL OR expires_at > ?)")
            params.append(Date().formatted(.iso8601))
        }
        if !f.includeSuperseded {
            clauses.append("status = 'active'")
        }
        if !f.includePrivate {
            clauses.append("is_private = 0")
        }
        if let minC = f.minConfidence {
            clauses.append("confidence >= ?")
            params.append(minC)
        }
        if let since = f.createdSince {
            clauses.append("created_at >= ?")
            params.append(since.formatted(.iso8601))
        }
        if let before = f.createdBefore {
            clauses.append("created_at < ?")
            params.append(before.formatted(.iso8601))
        }
        if let tags = f.tags, !tags.isEmpty {
            let likes = tags.map { _ in "tags_json LIKE ?" }.joined(separator: " OR ")
            clauses.append("(\(likes))")
            for tag in tags {
                params.append("%\"\(tag)\"%")
            }
        }
        if let entities = f.entities, !entities.isEmpty {
            let likes = entities.map { _ in "entities_json LIKE ?" }.joined(separator: " OR ")
            clauses.append("(\(likes))")
            for entity in entities {
                params.append("%\"\(entity.entityId.uuidString)\"%")
            }
        }

        params.append(limit)
        params.append(offset)

        // COALESCE on nullable text columns: SQLiteVec caches column types from row 1 only and
        // crashes on later NULLs (Database.swift:318/352). Wrapping every nullable text column
        // never returns NULL → library treats them all as TEXT consistently.
        let sql = """
            SELECT id, body, tags_json, entities_json, confidence, user_confirmed, is_private,
                   created_at,
                   COALESCE(expires_at, '') AS expires_at,
                   COALESCE(superseded_by, '') AS superseded_by,
                   COALESCE(provenance_json, '') AS provenance_json,
                   COALESCE(status, 'active') AS status
            FROM semantic_facts
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY created_at DESC
            LIMIT ? OFFSET ?
        """
        let rows = try await db.query(sql, params: params)
        return try rows.map { try Self.decodeFact(from: $0, vector: nil) }
    }

    // MARK: - Vector retrieval

    /// Embed `query` (input_type=query) and return top-k turns by similarity.
    /// Throws if the embedder is missing or fails — retrieval cannot degrade gracefully.
    func retrieveSimilarTurns(query: String, k: Int = 5) async throws -> [(MemoryTurn, Double)] {
        let queryVector = try await embedQuery(query)
        let rows = try await db.query("""
            SELECT t.id, t.created_at, t.chat_session_id, t.role, t.content,
                   v.distance
            FROM memory_turns_vec v
            JOIN memory_turns t ON v.rowid = t.rowid
            WHERE v.embedding MATCH ?
            ORDER BY v.distance
            LIMIT ?
        """, params: [queryVector, k])

        var results: [(MemoryTurn, Double)] = []
        for row in rows {
            let l2 = (row["distance"] as? Double) ?? 0
            let similarity = Self.l2ToCosineSimilarity(l2)
            let turn = try Self.decodeTurn(from: row)
            results.append((turn, similarity))
        }
        return results
    }

    /// Top-k facts by similarity, with optional structured filters.
    /// Excludes private facts by default — overridable for inspection paths only.
    /// Excludes superseded facts by default — 4.3 contradiction detection passes
    /// `excludeSuperseded: false` to scan the full lifecycle for false-positive
    /// supersession candidates flagged against rows that are already retired.
    /// Expired facts excluded unless `excludeExpired: false`.
    func retrieveSimilarFacts(
        query: String,
        k: Int = 5,
        tagFilter: [String]? = nil,
        entityFilter: [EntityReference]? = nil,
        excludeExpired: Bool = true,
        excludePrivate: Bool = true,
        excludeSuperseded: Bool = true
    ) async throws -> [(SemanticFact, Double)] {
        let queryVector = try await embedQuery(query)
        let overK = max(4 * k, 20)

        var clauses: [String] = []
        if excludeSuperseded {
            clauses.append("f.status = 'active'")
        }
        var params: [any Sendable] = [queryVector, overK]

        if excludePrivate {
            clauses.append("f.is_private = 0")
        }
        if excludeExpired {
            clauses.append("(f.expires_at IS NULL OR f.expires_at > ?)")
            params.append(Date().formatted(.iso8601))
        }
        if let tags = tagFilter, !tags.isEmpty {
            let likes = tags.map { _ in "f.tags_json LIKE ?" }.joined(separator: " OR ")
            clauses.append("(\(likes))")
            for tag in tags {
                params.append("%\"\(tag)\"%")
            }
        }
        if let entities = entityFilter, !entities.isEmpty {
            let likes = entities.map { _ in "f.entities_json LIKE ?" }.joined(separator: " OR ")
            clauses.append("(\(likes))")
            for entity in entities {
                params.append("%\"\(entity.entityId.uuidString)\"%")
            }
        }

        // If every conditional filter was opted-out (uncommon — only contradiction
        // detection asks for full-lifecycle without other filters), guard the WHERE
        // clause from being empty.
        if clauses.isEmpty {
            clauses.append("1=1")
        }

        params.append(k)

        // COALESCE nullable text columns to avoid SQLiteVec's first-row column-type cache crash.
        let sql = """
            SELECT f.id, f.body, f.tags_json, f.entities_json, f.confidence, f.user_confirmed, f.is_private,
                   f.created_at,
                   COALESCE(f.expires_at, '') AS expires_at,
                   COALESCE(f.superseded_by, '') AS superseded_by,
                   COALESCE(f.provenance_json, '') AS provenance_json,
                   COALESCE(f.status, 'active') AS status,
                   sub.distance
            FROM (
                SELECT rowid, distance
                FROM semantic_facts_vec
                WHERE embedding MATCH ?
                ORDER BY distance
                LIMIT ?
            ) sub
            JOIN semantic_facts f ON sub.rowid = f.rowid
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY sub.distance
            LIMIT ?
        """
        let rows = try await db.query(sql, params: params)

        var results: [(SemanticFact, Double)] = []
        for row in rows {
            let l2 = (row["distance"] as? Double) ?? 0
            let similarity = Self.l2ToCosineSimilarity(l2)
            let fact = try Self.decodeFact(from: row, vector: nil)
            results.append((fact, similarity))
        }
        return results
    }

    private func embedQuery(_ query: String) async throws -> [Float] {
        guard let embedder = embedder else {
            throw EmbedderError.missingAPIKey
        }
        let vectors = try await embedder.embed([query], inputType: .query)
        guard let first = vectors.first else {
            throw EmbedderError.unexpectedDimension(expected: embedder.dimension, got: 0)
        }
        return first
    }

    /// Voyage embeddings are unit-normalized, so for two unit vectors a, b:
    /// ||a - b||² = 2 - 2·cos(a, b)  =>  cos = 1 - L2²/2.
    /// Result is in [-1, 1], with 1 = identical, 0 = orthogonal, -1 = opposite.
    private static func l2ToCosineSimilarity(_ l2: Double) -> Double {
        1.0 - (l2 * l2) / 2.0
    }

    // MARK: - Browsing reads (memory inspection surface)

    /// All turns matching the optional filters, newest first. Vectors are not loaded.
    /// Caller filters further client-side as needed.
    func readAllTurns(
        limit: Int = 500,
        offset: Int = 0,
        since: Date? = nil,
        before: Date? = nil,
        role: MemoryTurn.Role? = nil
    ) async throws -> [MemoryTurn] {
        var clauses: [String] = ["1=1"]
        var params: [any Sendable] = []
        if let since {
            clauses.append("created_at >= ?")
            params.append(since.formatted(.iso8601))
        }
        if let before {
            clauses.append("created_at < ?")
            params.append(before.formatted(.iso8601))
        }
        if let role {
            clauses.append("role = ?")
            params.append(role.rawValue)
        }
        params.append(limit)
        params.append(offset)

        // metadata_json column was dropped in migration 2 (or remains as a ghost on older
        // SQLite). Either way, no SELECT references it.
        let sql = """
            SELECT id, created_at, chat_session_id, role, content
            FROM memory_turns
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY created_at DESC
            LIMIT ? OFFSET ?
        """
        let rows = try await db.query(sql, params: params)
        return try rows.map { try Self.decodeTurn(from: $0) }
    }

    /// Turns belonging to one chat session, oldest first. Used by the turn detail view to
    /// render surrounding session context.
    func readTurns(inSession sessionID: UUID, limit: Int = 200) async throws -> [MemoryTurn] {
        let sql = """
            SELECT id, created_at, chat_session_id, role, content
            FROM memory_turns
            WHERE chat_session_id = ?
            ORDER BY created_at ASC
            LIMIT ?
        """
        let rows = try await db.query(sql, params: [sessionID.uuidString, limit])
        return try rows.map { try Self.decodeTurn(from: $0) }
    }

    // MARK: - Mutations

    func updateFact(_ fact: SemanticFact) async throws {
        let tagsJSON = try Self.encodeJSON(fact.tags)
        let entitiesJSON = try Self.encodeJSON(fact.entitiesReferenced)

        let params: [any Sendable] = [
            fact.body,
            tagsJSON,
            entitiesJSON,
            fact.confidence,
            fact.userConfirmed,
            fact.isPrivate,
            fact.expiresAt?.formatted(.iso8601),
            fact.supersededBy?.uuidString,
            fact.provenanceJSON,
            fact.id.uuidString
        ]
        try await db.execute("""
            UPDATE semantic_facts SET
                body = ?, tags_json = ?, entities_json = ?,
                confidence = ?, user_confirmed = ?, is_private = ?,
                expires_at = ?, superseded_by = ?, provenance_json = ?
            WHERE id = ?
        """, params: params)
    }

    func deleteFact(id: UUID) async throws {
        let rows = try await db.query(
            "SELECT rowid FROM semantic_facts WHERE id = ? LIMIT 1",
            params: [id.uuidString]
        )
        try await db.execute(
            "DELETE FROM semantic_facts WHERE id = ?",
            params: [id.uuidString]
        )
        if let rowid = rows.first?["rowid"] as? Int {
            try await db.execute(
                "DELETE FROM semantic_facts_vec WHERE rowid = ?",
                params: [rowid]
            )
        }
    }

    // MARK: - JSON / decode / format helpers

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "null"
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from string: String?, default fallback: T) -> T {
        guard let s = string, let data = s.data(using: .utf8) else { return fallback }
        return (try? JSONDecoder().decode(type, from: data)) ?? fallback
    }

    private static func parseISO8601(_ string: String?) -> Date? {
        guard let s = string else { return nil }
        return try? Date(s, strategy: .iso8601)
    }

    static func formatScore(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func decodeCompactMemory(from row: [String: any Sendable]) throws -> CompactMemory {
        guard
            let idStr = row["id"] as? String, let id = UUID(uuidString: idStr),
            let kindStr = row["kind"] as? String, let kind = CompactMemory.Kind(rawValue: kindStr),
            let body = row["body"] as? String,
            let generatedAtStr = row["generated_at"] as? String,
            let generatedAt = parseISO8601(generatedAtStr)
        else {
            throw HemaServiceError.decoding("missing required compact_memory columns")
        }
        let wordCount = (row["word_count"] as? Int) ?? 0
        let supersededAt = parseISO8601(row["superseded_at"] as? String)
        let generatingModel = row["generating_model"] as? String

        return CompactMemory(
            id: id, kind: kind, body: body, wordCount: wordCount,
            generatedAt: generatedAt, supersededAt: supersededAt,
            generatingModel: generatingModel
        )
    }

    static func decodeTurn(from row: [String: any Sendable]) throws -> MemoryTurn {
        guard
            let idStr = row["id"] as? String, let id = UUID(uuidString: idStr),
            let createdAtStr = row["created_at"] as? String,
            let createdAt = parseISO8601(createdAtStr),
            let sessionStr = row["chat_session_id"] as? String,
            let sessionID = UUID(uuidString: sessionStr),
            let roleStr = row["role"] as? String, let role = MemoryTurn.Role(rawValue: roleStr),
            let content = row["content"] as? String
        else {
            throw HemaServiceError.decoding("missing required memory_turns columns")
        }
        return MemoryTurn(
            id: id, createdAt: createdAt, chatSessionID: sessionID, role: role,
            content: content, vector: nil
        )
    }

    static func decodeFact(from row: [String: any Sendable], vector: [Float]?) throws -> SemanticFact {
        guard
            let idStr = row["id"] as? String, let id = UUID(uuidString: idStr),
            let body = row["body"] as? String,
            let createdAtStr = row["created_at"] as? String,
            let createdAt = parseISO8601(createdAtStr)
        else {
            throw HemaServiceError.decoding("missing required semantic_facts columns")
        }
        let tags = decodeJSON([String].self, from: row["tags_json"] as? String, default: [])
        let entities = decodeJSON([EntityReference].self, from: row["entities_json"] as? String, default: [])
        let confidence = (row["confidence"] as? Double) ?? 0
        let userConfirmed = ((row["user_confirmed"] as? Int) ?? 0) != 0
        let isPrivate = ((row["is_private"] as? Int) ?? 0) != 0
        let expiresAt = parseISO8601(row["expires_at"] as? String)
        let supersededBy = (row["superseded_by"] as? String).flatMap(UUID.init(uuidString:))
        let provenanceJSON = row["provenance_json"] as? String
        // 4.3: lifecycle status. SELECT lists COALESCE the column to 'active' so a
        // pre-migration row or a SELECT without the column still decodes cleanly.
        let statusRaw = (row["status"] as? String) ?? "active"
        let status = FactStatus(rawValue: statusRaw) ?? .active

        return SemanticFact(
            id: id, body: body, tags: tags, entitiesReferenced: entities,
            confidence: confidence, userConfirmed: userConfirmed,
            createdAt: createdAt, expiresAt: expiresAt, supersededBy: supersededBy,
            provenanceJSON: provenanceJSON, vector: vector, isPrivate: isPrivate,
            status: status
        )
    }

    // MARK: - Lifecycle (4.3)

    /// Marks the existing fact as superseded by the new fact's id. Idempotent:
    /// the WHERE clause guards against overwriting an already-superseded link
    /// (e.g., a double-confirm race from two queued supersession candidates).
    /// `updateFact` does not write status — lifecycle changes go through this
    /// dedicated path so writes never silently mutate the column.
    func supersedeFact(oldFactID: UUID, newFactID: UUID) async throws {
        try await db.execute("""
            UPDATE semantic_facts
            SET status = 'superseded',
                superseded_by = ?
            WHERE id = ? AND status = 'active'
        """, params: [newFactID.uuidString, oldFactID.uuidString])
    }

    /// 4.5 archive op — sets status='archived' on the fact, leaving
    /// superseded_by NULL (archived facts have no successor). Idempotent:
    /// only updates active rows so a re-fire is a no-op.
    func archiveFact(id: UUID) async throws {
        try await db.execute("""
            UPDATE semantic_facts
            SET status = 'archived'
            WHERE id = ? AND status = 'active'
        """, params: [id.uuidString])
    }

}
