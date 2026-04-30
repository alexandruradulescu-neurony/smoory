import Foundation
import SQLiteVec

/// Diagnostic, self-test, seed, and reset operations for HemaService.
/// Split out of HemaService.swift in milestone 2.5c — same class, different file.
/// All methods here are user-invoked from the Debug menu, never from production code paths.
extension HemaService {
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
            vector: nil
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

        do { try await writeTurn(testTurn); lines.append("OK: wrote turn \(testTurn.id)") }
        catch { lines.append("FAIL: writeTurn — \(error)"); passed = false }

        do { try await writeFact(testFact); lines.append("OK: wrote fact \(testFact.id)") }
        catch { lines.append("FAIL: writeFact — \(error)"); passed = false }

        do { try await writeCompactMemory(testMemory); lines.append("OK: wrote compact memory \(testMemory.id)") }
        catch { lines.append("FAIL: writeCompactMemory — \(error)"); passed = false }

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

    func runRetrievalTest() async throws -> SelfTestReport {
        var lines: [String] = ["---- HEMA RETRIEVAL TEST ----"]
        var passed = true

        let sessionID = UUID()
        let testTurns: [MemoryTurn] = [
            MemoryTurn(id: UUID(), createdAt: Date(), chatSessionID: sessionID, role: .user,
                       content: "Today I need to ship the auth migration before the team standup.",
                       vector: nil),
            MemoryTurn(id: UUID(), createdAt: Date(), chatSessionID: sessionID, role: .user,
                       content: "Reading 50 pages of the Le Guin novel before bed feels great.",
                       vector: nil),
            MemoryTurn(id: UUID(), createdAt: Date(), chatSessionID: sessionID, role: .user,
                       content: "Hetzner sent a renewal email for the production server.",
                       vector: nil)
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
            _ = await Self.bestEffortCleanup(self, turns: testTurns, facts: allFacts)
            return SelfTestReport(passed: false, lines: lines)
        }

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
        if FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: databaseURL)
        }
        self.db = try Database(.uri(databaseURL.absoluteString))
        try await HemaSchema.applyPending(to: db)
    }

    /// Best-effort cleanup of test rows. Returns true if every delete succeeded.
    static func bestEffortCleanup(
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
