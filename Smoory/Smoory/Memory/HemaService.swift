import Foundation
import SQLiteVec

final class HemaService: @unchecked Sendable {
    static let defaultDatabaseURL: URL = URL.applicationSupportDirectory
        .appendingPathComponent("Smoory/hema.sqlite")

    let databaseURL: URL
    private var db: Database
    private let embedder: Embedder?

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
            turn.content,
            turn.metadataJSON
        ]
        try await db.execute("""
            INSERT INTO memory_turns
                (id, created_at, chat_session_id, role, content, metadata_json)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: params)

        if let vector {
            let rowid = await db.lastInsertRowId
            try await db.execute("""
                INSERT INTO memory_turns_vec (rowid, embedding) VALUES (?, ?)
            """, params: [rowid, vector])
        }
    }

    func writeFact(_ fact: SemanticFact) async throws {
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

    // MARK: - Reads

    func readActiveCompactMemories() async throws -> [CompactMemory] {
        let rows = try await db.query("""
            SELECT id, kind, body, word_count, generated_at, superseded_at, generating_model
            FROM compact_memory
            WHERE superseded_at IS NULL
            ORDER BY generated_at DESC
        """)
        return try rows.map { try Self.decodeCompactMemory(from: $0) }
    }

    func readFact(id: UUID) async throws -> SemanticFact? {
        let rows = try await db.query("""
            SELECT id, body, tags_json, entities_json, confidence, user_confirmed, is_private,
                   created_at, expires_at, superseded_by, provenance_json
            FROM semantic_facts
            WHERE id = ?
            LIMIT 1
        """, params: [id.uuidString])
        guard let row = rows.first else { return nil }
        return try Self.decodeFact(from: row, vector: nil)
    }

    func readAllFacts(filter: FactFilter? = nil, limit: Int = 100, offset: Int = 0) async throws -> [SemanticFact] {
        var clauses: [String] = ["1=1"]
        var params: [any Sendable] = []

        let f = filter ?? FactFilter()

        if !f.includeExpired {
            clauses.append("(expires_at IS NULL OR expires_at > ?)")
            params.append(Date().formatted(.iso8601))
        }
        if !f.includeSuperseded {
            clauses.append("superseded_by IS NULL")
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

        let sql = """
            SELECT id, body, tags_json, entities_json, confidence, user_confirmed, is_private,
                   created_at, expires_at, superseded_by, provenance_json
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
            SELECT t.id, t.created_at, t.chat_session_id, t.role, t.content, t.metadata_json,
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
    /// Excludes superseded facts always; expired facts unless `excludeExpired: false`.
    func retrieveSimilarFacts(
        query: String,
        k: Int = 5,
        tagFilter: [String]? = nil,
        entityFilter: [EntityReference]? = nil,
        excludeExpired: Bool = true,
        excludePrivate: Bool = true
    ) async throws -> [(SemanticFact, Double)] {
        let queryVector = try await embedQuery(query)
        let overK = max(4 * k, 20)

        var clauses: [String] = ["f.superseded_by IS NULL"]
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

        params.append(k)

        let sql = """
            SELECT f.id, f.body, f.tags_json, f.entities_json, f.confidence, f.user_confirmed, f.is_private,
                   f.created_at, f.expires_at, f.superseded_by, f.provenance_json,
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

    func expireFact(id: UUID, expiresAt: Date) async throws {
        try await db.execute(
            "UPDATE semantic_facts SET expires_at = ? WHERE id = ?",
            params: [expiresAt.formatted(.iso8601), id.uuidString]
        )
    }

    // MARK: - Diagnostics

    func dumpStateToConsole() async throws {
        print("---- HEMA STATE DUMP ----")
        print("DB path: \(databaseURL.path(percentEncoded: false))")

        let vRows = try await db.query("SELECT MAX(version) AS v FROM schema_version")
        let v = (vRows.first?["v"] as? Int) ?? 0
        print("Schema version: \(v)")

        let vecVersion = await db.version() ?? "?"
        print("sqlite-vec version: \(vecVersion)")

        for table in ["memory_turns", "semantic_facts", "compact_memory"] {
            let rows = try await db.query("SELECT COUNT(*) AS c FROM \(table)")
            let c = rows.first?["c"] as? Int ?? 0
            print("\(table): \(c) rows")
        }

        print("\nRecent memory_turns (5):")
        let turns = try await db.query("""
            SELECT created_at, role, substr(content, 1, 80) AS preview
            FROM memory_turns ORDER BY created_at DESC LIMIT 5
        """)
        for r in turns {
            let when = r["created_at"] as? String ?? "?"
            let role = r["role"] as? String ?? "?"
            let prev = r["preview"] as? String ?? ""
            print("  [\(when)] \(role): \(prev)")
        }

        print("\nRecent semantic_facts (5):")
        let facts = try await db.query("""
            SELECT created_at, is_private, substr(body, 1, 80) AS preview
            FROM semantic_facts ORDER BY created_at DESC LIMIT 5
        """)
        for r in facts {
            let when = r["created_at"] as? String ?? "?"
            let priv = ((r["is_private"] as? Int) ?? 0) != 0 ? " [PRIVATE]" : ""
            let prev = r["preview"] as? String ?? ""
            print("  [\(when)]\(priv): \(prev)")
        }

        print("\nRecent compact_memory (5):")
        let memories = try await db.query("""
            SELECT generated_at, kind, superseded_at, substr(body, 1, 80) AS preview
            FROM compact_memory ORDER BY generated_at DESC LIMIT 5
        """)
        for r in memories {
            let when = r["generated_at"] as? String ?? "?"
            let kind = r["kind"] as? String ?? "?"
            let active = r["superseded_at"] == nil ? " [ACTIVE]" : " [superseded]"
            let prev = r["preview"] as? String ?? ""
            print("  [\(when)] \(kind)\(active): \(prev)")
        }

        print("---- END HEMA STATE DUMP ----")
    }

    func runSelfTest() async throws -> SelfTestReport {
        var lines: [String] = ["---- HEMA SELF-TEST ----"]
        var passed = true

        let testTurn = MemoryTurn(
            id: UUID(), createdAt: Date(), chatSessionID: UUID(),
            role: .user,
            content: "selftest-turn-\(UUID().uuidString.prefix(8))",
            metadataJSON: nil, vector: nil
        )
        let testFact = SemanticFact(
            id: UUID(),
            body: "selftest-fact-\(UUID().uuidString.prefix(8))",
            tags: ["selftest"], entitiesReferenced: [],
            confidence: 0.9, userConfirmed: false,
            createdAt: Date(), expiresAt: nil, supersededBy: nil,
            provenanceJSON: nil, vector: nil, isPrivate: false
        )
        let testMemory = CompactMemory(
            id: UUID(), kind: .today,
            body: "selftest-compact-\(UUID().uuidString.prefix(8))",
            wordCount: 10, generatedAt: Date(),
            supersededAt: nil, generatingModel: nil
        )

        // --- Writes ---
        do { try await writeTurn(testTurn); lines.append("OK: wrote turn \(testTurn.id)") }
        catch { lines.append("FAIL: writeTurn — \(error)"); passed = false }

        do { try await writeFact(testFact); lines.append("OK: wrote fact \(testFact.id)") }
        catch { lines.append("FAIL: writeFact — \(error)"); passed = false }

        do { try await writeCompactMemory(testMemory); lines.append("OK: wrote compact memory \(testMemory.id)") }
        catch { lines.append("FAIL: writeCompactMemory — \(error)"); passed = false }

        // --- Reads ---
        do {
            if let readBack = try await readFact(id: testFact.id), readBack.body == testFact.body {
                lines.append("OK: read fact back, body round-tripped")
            } else {
                lines.append("FAIL: readFact body did not round-trip"); passed = false
            }
        } catch { lines.append("FAIL: readFact — \(error)"); passed = false }

        do {
            let actives = try await readActiveCompactMemories()
            if actives.contains(where: { $0.id == testMemory.id }) {
                lines.append("OK: readActiveCompactMemories included our test memory")
            } else {
                lines.append("FAIL: readActiveCompactMemories did not include our test memory"); passed = false
            }
        } catch { lines.append("FAIL: readActiveCompactMemories — \(error)"); passed = false }

        do {
            let listed = try await readAllFacts(filter: FactFilter(tags: ["selftest"]))
            if listed.contains(where: { $0.id == testFact.id }) {
                lines.append("OK: readAllFacts(tag: selftest) returned our test fact")
            } else {
                lines.append("FAIL: readAllFacts did not return our test fact"); passed = false
            }
        } catch { lines.append("FAIL: readAllFacts — \(error)"); passed = false }

        // --- Cleanup ---
        do {
            try await deleteFact(id: testFact.id)
            try await db.execute("DELETE FROM memory_turns WHERE id = ?", params: [testTurn.id.uuidString])
            try await db.execute("DELETE FROM compact_memory WHERE id = ?", params: [testMemory.id.uuidString])
            lines.append("OK: cleaned up test rows")
        } catch {
            lines.append("WARN: cleanup — \(error)")
        }

        lines.append(passed ? "---- SELF-TEST PASSED ----" : "---- SELF-TEST FAILED ----")
        return SelfTestReport(passed: passed, lines: lines)
    }

    /// Writes 3 turns + 4 facts (1 private), embeds each via the configured Embedder, runs
    /// retrieval queries (turns query, facts focus query, facts feelings query default + override),
    /// verifies the privacy filter at the HemaService boundary, then cleans up.
    func runRetrievalTest() async throws -> SelfTestReport {
        var lines: [String] = ["---- HEMA RETRIEVAL TEST ----"]
        var passed = true

        let sessionID = UUID()
        let testTurns: [MemoryTurn] = [
            MemoryTurn(id: UUID(), createdAt: Date(), chatSessionID: sessionID, role: .user,
                       content: "Today I need to ship the auth migration before the team standup.",
                       metadataJSON: nil, vector: nil),
            MemoryTurn(id: UUID(), createdAt: Date(), chatSessionID: sessionID, role: .user,
                       content: "Reading 50 pages of the Le Guin novel before bed feels great.",
                       metadataJSON: nil, vector: nil),
            MemoryTurn(id: UUID(), createdAt: Date(), chatSessionID: sessionID, role: .user,
                       content: "Hetzner sent a renewal email for the production server.",
                       metadataJSON: nil, vector: nil)
        ]

        let publicFacts: [SemanticFact] = [
            SemanticFact(id: UUID(), body: "User prefers deep work in mornings before noon.",
                         tags: ["work-style"], entitiesReferenced: [],
                         confidence: 0.9, userConfirmed: true,
                         createdAt: Date(), expiresAt: nil, supersededBy: nil,
                         provenanceJSON: nil, vector: nil, isPrivate: false),
            SemanticFact(id: UUID(), body: "Maria at Acme is the project lead for the Apollo migration.",
                         tags: ["work"], entitiesReferenced: [],
                         confidence: 0.9, userConfirmed: true,
                         createdAt: Date(), expiresAt: nil, supersededBy: nil,
                         provenanceJSON: nil, vector: nil, isPrivate: false),
            SemanticFact(id: UUID(), body: "User is off May 1-2 for national holiday.",
                         tags: ["availability"], entitiesReferenced: [],
                         confidence: 0.95, userConfirmed: true,
                         createdAt: Date(), expiresAt: nil, supersededBy: nil,
                         provenanceJSON: nil, vector: nil, isPrivate: false)
        ]
        let privateFact = SemanticFact(
            id: UUID(),
            body: "User has been struggling with insomnia and anxiety this month.",
            tags: ["health", "personal"], entitiesReferenced: [],
            confidence: 0.85, userConfirmed: true,
            createdAt: Date(), expiresAt: nil, supersededBy: nil,
            provenanceJSON: nil, vector: nil, isPrivate: true
        )
        let allFacts = publicFacts + [privateFact]

        // --- Writes ---
        lines.append("Writing 3 turns and 4 facts (embedding each via the configured Embedder)...")
        do {
            for turn in testTurns { try await writeTurn(turn) }
            lines.append("OK: wrote 3 turns")
        } catch {
            lines.append("FAIL: writeTurn — \(error)"); passed = false
        }
        do {
            for fact in allFacts { try await writeFact(fact) }
            lines.append("OK: wrote 4 facts (1 marked private)")
        } catch {
            lines.append("FAIL: writeFact — \(error)"); passed = false
        }

        if !passed {
            lines.append("---- RETRIEVAL TEST FAILED (writes broken) ----")
            // Best-effort cleanup of whatever did land, then return.
            _ = await Self.bestEffortCleanup(self, turns: testTurns, facts: allFacts)
            return SelfTestReport(passed: false, lines: lines)
        }

        // --- Query 1: turns ---
        let turnQuery = "What was I working on for the migration?"
        lines.append("")
        lines.append("Query: \"\(turnQuery)\"")
        do {
            let results = try await retrieveSimilarTurns(query: turnQuery, k: 3)
            for (turn, score) in results {
                lines.append("  [\(Self.formatScore(score))] \(turn.content)")
            }
            if results.isEmpty {
                lines.append("FAIL: no turn results returned"); passed = false
            }
        } catch {
            lines.append("FAIL: retrieveSimilarTurns — \(error)"); passed = false
        }

        // --- Query 2: facts focus ---
        let focusQuery = "When does the user prefer to focus?"
        lines.append("")
        lines.append("Query: \"\(focusQuery)\"")
        do {
            let results = try await retrieveSimilarFacts(query: focusQuery, k: 3)
            for (fact, score) in results {
                lines.append("  [\(Self.formatScore(score))] \(fact.body)")
            }
        } catch {
            lines.append("FAIL: retrieveSimilarFacts (focus) — \(error)"); passed = false
        }

        // --- Query 3a: privacy default — private must NOT appear ---
        let feelingsQuery = "How is the user feeling lately?"
        lines.append("")
        lines.append("Query: \"\(feelingsQuery)\" (excludePrivate=true)")
        do {
            let results = try await retrieveSimilarFacts(query: feelingsQuery, k: 5)
            for (fact, score) in results {
                lines.append("  [\(Self.formatScore(score))] \(fact.body)")
            }
            let leaked = results.contains { $0.0.id == privateFact.id }
            if leaked {
                lines.append("FAIL: private fact appeared in default retrieval — privacy filter broken")
                passed = false
            } else {
                lines.append("  (private fact correctly excluded from default retrieval)")
            }
        } catch {
            lines.append("FAIL: retrieveSimilarFacts (feelings default) — \(error)"); passed = false
        }

        // --- Query 3b: privacy override — private MUST appear ---
        lines.append("")
        lines.append("Query: \"\(feelingsQuery)\" (excludePrivate=false)")
        do {
            let results = try await retrieveSimilarFacts(query: feelingsQuery, k: 5, excludePrivate: false)
            for (fact, score) in results {
                let suffix = (fact.id == privateFact.id) ? "  ← PRIVATE" : ""
                lines.append("  [\(Self.formatScore(score))] \(fact.body)\(suffix)")
            }
            let included = results.contains { $0.0.id == privateFact.id }
            if !included {
                lines.append("WARN: private fact missing from excludePrivate=false retrieval (rank may be too low for k=5)")
            }
        } catch {
            lines.append("FAIL: retrieveSimilarFacts (feelings override) — \(error)"); passed = false
        }

        // --- Cleanup ---
        lines.append("")
        lines.append("Cleaning up...")
        let cleanupOK = await Self.bestEffortCleanup(self, turns: testTurns, facts: allFacts)
        if cleanupOK {
            lines.append("OK: cleaned up 3 turns and 4 facts (rows + vec rows)")
        } else {
            lines.append("WARN: cleanup had issues — run Reset hema if state seems stuck")
        }

        lines.append(passed ? "---- HEMA RETRIEVAL TEST PASSED ----" : "---- HEMA RETRIEVAL TEST FAILED ----")
        return SelfTestReport(passed: passed, lines: lines)
    }

    /// Writes a small seeded set of facts for chat-side testing of retrieve_memory.
    /// Idempotency: not deduped — re-running creates duplicates. Use `reset()` to start clean.
    func seedTestData() async throws -> SelfTestReport {
        var lines: [String] = ["---- HEMA SEED TEST DATA ----"]

        let seeds: [(body: String, tags: [String])] = [
            ("User's name is Alexandru and he lives in Bucharest.",
             ["personal"]),
            ("User runs his own business called Smoory and works on it in evenings.",
             ["work", "business"]),
            ("User's primary IDE is Xcode for Smoory development.",
             ["work", "tools"]),
            ("User prefers focused work in mornings.",
             ["preferences"]),
        ]

        var written = 0
        for (body, tags) in seeds {
            let fact = SemanticFact(
                id: UUID(),
                body: body,
                tags: tags,
                entitiesReferenced: [],
                confidence: 0.95,
                userConfirmed: true,
                createdAt: Date(),
                expiresAt: nil,
                supersededBy: nil,
                provenanceJSON: nil,
                vector: nil,
                isPrivate: false
            )
            do {
                try await writeFact(fact)
                written += 1
                lines.append("OK: wrote \"\(body)\"")
            } catch {
                lines.append("FAIL: writeFact \"\(body)\" — \(error)")
            }
        }

        lines.append("---- DONE: \(written) of \(seeds.count) facts written ----")
        return SelfTestReport(passed: written == seeds.count, lines: lines)
    }

    /// Dev escape hatch — closes connection, deletes the DB file, reopens, applies migrations.
    /// Not safe to call concurrently with reads/writes; treat as single-call from a dev menu.
    func reset() async throws {
        // FileManager wants the unencoded filesystem path.
        // url.path() defaults to percentEncoded:true on macOS 14+, which would look for a
        // literal "Application%20Support" directory and silently miss the real file.
        if FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: databaseURL)
        }
        self.db = try Database(.uri(databaseURL.absoluteString))
        try await HemaSchema.applyPending(to: db)
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

    private static func formatScore(_ value: Double) -> String {
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

    private static func decodeTurn(from row: [String: any Sendable]) throws -> MemoryTurn {
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
        let metadataJSON = row["metadata_json"] as? String
        return MemoryTurn(
            id: id, createdAt: createdAt, chatSessionID: sessionID, role: role,
            content: content, metadataJSON: metadataJSON, vector: nil
        )
    }

    private static func decodeFact(from row: [String: any Sendable], vector: [Float]?) throws -> SemanticFact {
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

        return SemanticFact(
            id: id, body: body, tags: tags, entitiesReferenced: entities,
            confidence: confidence, userConfirmed: userConfirmed,
            createdAt: createdAt, expiresAt: expiresAt, supersededBy: supersededBy,
            provenanceJSON: provenanceJSON, vector: vector, isPrivate: isPrivate
        )
    }

    /// Best-effort cleanup of test rows. Returns true if every delete succeeded.
    private static func bestEffortCleanup(
        _ hema: HemaService,
        turns: [MemoryTurn],
        facts: [SemanticFact]
    ) async -> Bool {
        var ok = true
        for turn in turns {
            do {
                let rows = try await hema.db.query(
                    "SELECT rowid FROM memory_turns WHERE id = ? LIMIT 1",
                    params: [turn.id.uuidString]
                )
                try await hema.db.execute(
                    "DELETE FROM memory_turns WHERE id = ?",
                    params: [turn.id.uuidString]
                )
                if let rowid = rows.first?["rowid"] as? Int {
                    try await hema.db.execute(
                        "DELETE FROM memory_turns_vec WHERE rowid = ?",
                        params: [rowid]
                    )
                }
            } catch {
                ok = false
            }
        }
        for fact in facts {
            do { try await hema.deleteFact(id: fact.id) }
            catch { ok = false }
        }
        return ok
    }
}
