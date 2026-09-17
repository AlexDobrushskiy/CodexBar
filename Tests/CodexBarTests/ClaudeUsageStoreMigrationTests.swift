import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

/// Adding the Claude tables bumps the base schema version, which must not throw away the live
/// Codex ledger. `adoptCompatiblePredecessor` cannot do this — it recomputes the predecessor from
/// the *current* `baseSchemaVersion`, so a base bump makes every older database ineligible — so an
/// explicit v3 → v4 migration has to carry the rows across.
@Suite(.serialized)
struct ClaudeUsageStoreMigrationTests {
    private static let parserHash = CodexParserHash.value

    private static func version(base: Int) -> Int32 {
        CostUsageStore.combinedSchemaVersion(base: base, parserHash: Self.parserHash)
    }

    /// A database written by today's code already carries the Claude tables, so drop them to
    /// reproduce a genuine v3 database as shipped before this migration existed.
    private static func makeGenuinelyV3(at url: URL) {
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(handle) }
        let drops = "DROP TABLE IF EXISTS claude_usage_events;"
            + "DROP TABLE IF EXISTS claude_source_files;"
            + "DROP TABLE IF EXISTS claude_model_prices;"
        #expect(sqlite3_exec(handle, drops, nil, nil, nil) == SQLITE_OK)
    }

    private static func codexFile(path: String) -> CostUsageStoreFile {
        CostUsageStoreFile(
            path: path,
            inode: 1,
            mtimeUnixMs: 1_700_000_000_000,
            size: 128,
            parsedBytes: 128,
            anchor: nil,
            scanState: CostUsageStoreScanState(targetSize: 128, isComplete: true),
            sessionID: "session-a",
            coverageSinceDay: "2026-09-01",
            coverageUntilDay: "2026-09-01",
            updatedAtUnixMs: 1_700_000_000_000)
    }

    private static func sourceFile(path: String) -> ClaudeStoreSourceFile {
        ClaudeStoreSourceFile(
            path: path,
            fileIdentity: "ino-1",
            size: 64,
            mtimeMs: 1_700_000_000_000,
            parsedOffset: 64,
            coverageSinceDay: "2026-09-17",
            coverageUntilDay: "2026-09-17",
            parserRevision: 1,
            tzIdentity: "Europe/Lisbon",
            complete: true)
    }

    /// Seeds a genuine v3 database holding one Codex row and returns the cache root.
    private static func seedV3(_ env: CostUsageTestEnvironment) async {
        let v3 = CostUsageStore(
            cacheRoot: env.cacheRoot,
            schemaVersion: Self.version(base: 3),
            parserHash: Self.parserHash)
        #expect(await v3.upsertFile(Self.codexFile(path: "/codex/a.jsonl")))
        #expect(await v3.readSnapshot().files.count == 1)
        Self.makeGenuinelyV3(at: v3.databaseURL)
    }

    @Test
    func `opening a v3 database at v4 preserves the existing codex rows`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        await Self.seedV3(env)

        let v4 = CostUsageStore(
            cacheRoot: env.cacheRoot,
            schemaVersion: Self.version(base: 4),
            parserHash: Self.parserHash)

        #expect(await v4.readSnapshot().files.map(\.path) == ["/codex/a.jsonl"])
    }

    @Test
    func `migrating to v4 makes the claude tables usable`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        await Self.seedV3(env)

        let v4 = CostUsageStore(
            cacheRoot: env.cacheRoot,
            schemaVersion: Self.version(base: 4),
            parserHash: Self.parserHash)
        let path = "/Users/alex/.claude/projects/-p/s.jsonl"

        #expect(await v4.upsertClaudeSourceFile(Self.sourceFile(path: path)) != nil)
        #expect(await v4.readClaudeSourceFiles().map(\.path) == [path])
    }
}
