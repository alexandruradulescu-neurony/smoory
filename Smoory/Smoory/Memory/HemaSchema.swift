import Foundation
import SQLiteVec

struct Migration: Sendable {
    let version: Int
    let description: String
    let up: @Sendable (Database) async throws -> Void
}

enum HemaSchema {
    static let migrations: [Migration] = [
        Migration(version: 1, description: "initial schema") { db in
            // Bootstrap: schema_version table is created first so subsequent migrations can read state.
            try await db.execute("""
                CREATE TABLE IF NOT EXISTS schema_version (
                    version INTEGER PRIMARY KEY,
                    applied_at TEXT NOT NULL
                )
            """)

            // Compact summaries — one active row per kind, history preserved via superseded_at.
            try await db.execute("""
                CREATE TABLE compact_memory (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    body TEXT NOT NULL,
                    word_count INTEGER NOT NULL DEFAULT 0,
                    generated_at TEXT NOT NULL,
                    superseded_at TEXT,
                    generating_model TEXT
                )
            """)
            try await db.execute("""
                CREATE INDEX idx_compact_kind_active ON compact_memory(kind, superseded_at)
            """)

            // Conversational turns + parallel vec0 virtual table joined by rowid.
            try await db.execute("""
                CREATE TABLE memory_turns (
                    id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    chat_session_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    metadata_json TEXT
                )
            """)
            try await db.execute("""
                CREATE VIRTUAL TABLE memory_turns_vec USING vec0(embedding float[1024])
            """)
            try await db.execute("""
                CREATE INDEX idx_turns_session ON memory_turns(chat_session_id)
            """)
            try await db.execute("""
                CREATE INDEX idx_turns_created ON memory_turns(created_at)
            """)

            // Semantic facts + parallel vec0 virtual table joined by rowid.
            try await db.execute("""
                CREATE TABLE semantic_facts (
                    id TEXT PRIMARY KEY,
                    body TEXT NOT NULL,
                    tags_json TEXT NOT NULL DEFAULT '[]',
                    entities_json TEXT NOT NULL DEFAULT '[]',
                    confidence REAL NOT NULL DEFAULT 0,
                    user_confirmed INTEGER NOT NULL DEFAULT 0,
                    is_private INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    expires_at TEXT,
                    superseded_by TEXT,
                    provenance_json TEXT
                )
            """)
            try await db.execute("""
                CREATE VIRTUAL TABLE semantic_facts_vec USING vec0(embedding float[1024])
            """)
            try await db.execute("""
                CREATE INDEX idx_facts_created ON semantic_facts(created_at)
            """)
            try await db.execute("""
                CREATE INDEX idx_facts_expires ON semantic_facts(expires_at)
            """)
            try await db.execute("""
                CREATE INDEX idx_facts_superseded ON semantic_facts(superseded_by)
            """)
            try await db.execute("""
                CREATE INDEX idx_facts_private ON semantic_facts(is_private)
            """)

            // Mark version applied.
            try await db.execute(
                "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                params: [1, Date().formatted(.iso8601)]
            )
        }
    ]

    /// Reads schema_version → 0 on virgin DB (table absent or empty).
    static func currentVersion(of db: Database) async throws -> Int {
        // Probe for table existence.
        let probe = try await db.query("""
            SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version' LIMIT 1
        """)
        guard !probe.isEmpty else { return 0 }
        let rows = try await db.query("SELECT MAX(version) AS v FROM schema_version")
        return (rows.first?["v"] as? Int) ?? 0
    }

    /// Applies all migrations whose version > current. Each runs in its own transaction.
    static func applyPending(to db: Database) async throws {
        let current = try await currentVersion(of: db)
        let pending = migrations.filter { $0.version > current }.sorted { $0.version < $1.version }
        for migration in pending {
            do {
                try await db.transaction {
                    try await migration.up(db)
                }
            } catch {
                throw HemaServiceError.migration(error)
            }
        }
    }
}
