import Foundation
import SQLiteVec

final class HemaService: @unchecked Sendable {
    static let defaultDatabaseURL: URL = URL.applicationSupportDirectory
        .appendingPathComponent("Smoory/hema.sqlite")

    let databaseURL: URL
    private var db: Database

    /// Async because opening the DB and running migrations can throw and suspend.
    /// Throws on first-run DB-init failure — hema is essential, no graceful fallback.
    init(databaseURL: URL? = nil) async throws {
        let url = databaseURL ?? Self.defaultDatabaseURL
        self.databaseURL = url

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

        if let vector = turn.vector {
            let rowid = await db.lastInsertRowId
            try await db.execute("""
                INSERT INTO memory_turns_vec (rowid, embedding) VALUES (?, ?)
            """, params: [rowid, vector])
        }
    }

    func writeFact(_ fact: SemanticFact) async throws {
        let tagsJSON = try Self.encodeJSON(fact.tags)
        let entitiesJSON = try Self.encodeJSON(fact.entitiesReferenced)

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

        if let vector = fact.vector {
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
        // Look up rowid first so we can clean its vector row too.
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
            id: UUID(),
            createdAt: Date(),
            chatSessionID: UUID(),
            role: .user,
            content: "selftest-turn-\(UUID().uuidString.prefix(8))",
            metadataJSON: nil,
            vector: nil
        )
        let testFact = SemanticFact(
            id: UUID(),
            body: "selftest-fact-\(UUID().uuidString.prefix(8))",
            tags: ["selftest"],
            entitiesReferenced: [],
            confidence: 0.9,
            userConfirmed: false,
            createdAt: Date(),
            expiresAt: nil,
            supersededBy: nil,
            provenanceJSON: nil,
            vector: nil,
            isPrivate: false
        )
        let testMemory = CompactMemory(
            id: UUID(),
            kind: .today,
            body: "selftest-compact-\(UUID().uuidString.prefix(8))",
            wordCount: 10,
            generatedAt: Date(),
            supersededAt: nil,
            generatingModel: nil
        )

        // --- Writes ---
        do {
            try await writeTurn(testTurn)
            lines.append("OK: wrote turn \(testTurn.id)")
        } catch {
            lines.append("FAIL: writeTurn — \(error)")
            passed = false
        }
        do {
            try await writeFact(testFact)
            lines.append("OK: wrote fact \(testFact.id)")
        } catch {
            lines.append("FAIL: writeFact — \(error)")
            passed = false
        }
        do {
            try await writeCompactMemory(testMemory)
            lines.append("OK: wrote compact memory \(testMemory.id)")
        } catch {
            lines.append("FAIL: writeCompactMemory — \(error)")
            passed = false
        }

        // --- Reads ---
        do {
            if let readBack = try await readFact(id: testFact.id), readBack.body == testFact.body {
                lines.append("OK: read fact back, body round-tripped")
            } else {
                lines.append("FAIL: readFact body did not round-trip")
                passed = false
            }
        } catch {
            lines.append("FAIL: readFact — \(error)")
            passed = false
        }
        do {
            let actives = try await readActiveCompactMemories()
            if actives.contains(where: { $0.id == testMemory.id }) {
                lines.append("OK: readActiveCompactMemories included our test memory")
            } else {
                lines.append("FAIL: readActiveCompactMemories did not include our test memory")
                passed = false
            }
        } catch {
            lines.append("FAIL: readActiveCompactMemories — \(error)")
            passed = false
        }
        do {
            let listed = try await readAllFacts(filter: FactFilter(tags: ["selftest"]))
            if listed.contains(where: { $0.id == testFact.id }) {
                lines.append("OK: readAllFacts(tag: selftest) returned our test fact")
            } else {
                lines.append("FAIL: readAllFacts did not return our test fact")
                passed = false
            }
        } catch {
            lines.append("FAIL: readAllFacts — \(error)")
            passed = false
        }

        // --- Cleanup (always, even if any earlier step failed) ---
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

    /// Dev escape hatch — closes connection, deletes the DB file, reopens, applies migrations.
    /// Not safe to call concurrently with reads/writes; treat as single-call from a dev menu.
    func reset() async throws {
        // Reassigning db drops the previous reference; SQLiteVec's internal Handler.deinit
        // then runs sqlite3_close on the file handle.
        // FileManager wants the unencoded filesystem path.
        // url.path() defaults to percentEncoded:true on macOS 14+, which would look for a
        // literal "Application%20Support" directory and silently miss the real file.
        if FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: databaseURL)
        }
        self.db = try Database(.uri(databaseURL.absoluteString))
        try await HemaSchema.applyPending(to: db)
    }

    // MARK: - JSON / decode helpers

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
}
