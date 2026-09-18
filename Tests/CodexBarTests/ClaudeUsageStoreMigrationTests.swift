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
        CostUsageStore.combinedSchemaVersion(base: base, parserHash: self.parserHash)
    }

    /// Reproduces the on-disk shape of an older base version.
    ///
    /// A database written by today's code already carries every Claude object, so a fixture has to
    /// undo them one version at a time. Missing any single one makes that version's exact `CREATE`
    /// collide, roll back and rebuild — which silently drops the rows the test is asserting on, and
    /// looks like a migration bug rather than a fixture bug. This has bitten three times.
    private static func makeGenuinely(base: Int, at url: URL) {
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(handle) }

        var steps: [String] = []
        if base < 7 {
            steps.append("DROP TABLE IF EXISTS claude_ledger_state;")
        }
        if base < 6 {
            steps.append("ALTER TABLE claude_source_files DROP COLUMN source_present;")
        }
        if base < 5 {
            steps.append("DROP VIEW IF EXISTS claude_event_costs;")
            steps.append("DROP TABLE IF EXISTS claude_model_prices;")
            steps.append(Self.v4ModelPricesSQL)
        }
        if base < 4 {
            steps.append("DROP VIEW IF EXISTS claude_reconciled_events;")
            steps.append("DROP TABLE IF EXISTS claude_usage_events;")
            steps.append("DROP TABLE IF EXISTS claude_source_files;")
            steps.append("DROP TABLE IF EXISTS claude_model_prices;")
        }
        #expect(sqlite3_exec(handle, steps.joined(), nil, nil, nil) == SQLITE_OK)
    }

    /// v4's price table: no writer, and the wrong column types, which is why v5 replaced it.
    private static let v4ModelPricesSQL = """
    CREATE TABLE claude_model_prices (
        model TEXT NOT NULL,
        backend TEXT NOT NULL,
        valid_from TEXT NOT NULL,
        valid_to TEXT,
        input_per_mtok REAL NOT NULL,
        cache_read_per_mtok REAL NOT NULL,
        cache_write_per_mtok REAL NOT NULL,
        cache_write_1h_per_mtok REAL NOT NULL,
        output_per_mtok REAL NOT NULL,
        long_context_threshold INTEGER,
        long_context_input_per_mtok REAL,
        long_context_cache_read_per_mtok REAL,
        long_context_cache_write_per_mtok REAL,
        long_context_output_per_mtok REAL,
        PRIMARY KEY(model, backend, valid_from)
    );
    """

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
        Self.makeGenuinely(base: 3, at: v3.databaseURL)
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
    func `migrating to v6 keeps the claude rows and starts them present`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let path = "/Users/alex/.claude/projects/-p/s.jsonl"
        let v5 = CostUsageStore(
            cacheRoot: env.cacheRoot,
            schemaVersion: Self.version(base: 5),
            parserHash: Self.parserHash)
        #expect(await v5.upsertFile(Self.codexFile(path: "/codex/a.jsonl")))
        let fileID = try #require(await v5.upsertClaudeSourceFile(Self.sourceFile(path: path)))
        #expect(await v5.appendClaudeUsageEvents(fileID: fileID, events: [Self.usageEvent()]))
        Self.makeGenuinely(base: 5, at: v5.databaseURL)

        let v6 = CostUsageStore(
            cacheRoot: env.cacheRoot,
            schemaVersion: Self.version(base: 6),
            parserHash: Self.parserHash)

        #expect(await v6.readSnapshot().files.map(\.path) == ["/codex/a.jsonl"])
        let files = await v6.readClaudeSourceFiles()
        #expect(files.map(\.path) == [path])
        #expect(files.first?.sourcePresent == true, "everything already tracked is still on disk")
    }

    @Test
    func `migrating to v5 replaces the price table and keeps the claude rows`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let path = "/Users/alex/.claude/projects/-p/s.jsonl"
        let v4 = CostUsageStore(
            cacheRoot: env.cacheRoot,
            schemaVersion: Self.version(base: 4),
            parserHash: Self.parserHash)
        #expect(await v4.upsertFile(Self.codexFile(path: "/codex/a.jsonl")))
        let fileID = try #require(await v4.upsertClaudeSourceFile(Self.sourceFile(path: path)))
        #expect(await v4.appendClaudeUsageEvents(fileID: fileID, events: [Self.usageEvent()]))
        Self.makeGenuinely(base: 4, at: v4.databaseURL)

        let v5 = CostUsageStore(
            cacheRoot: env.cacheRoot,
            schemaVersion: Self.version(base: 5),
            parserHash: Self.parserHash)

        #expect(await v5.readSnapshot().files.map(\.path) == ["/codex/a.jsonl"])
        #expect(await v5.readClaudeSourceFiles().map(\.path) == [path])
        #expect(await v5.readClaudeModelPrices().isEmpty, "the v4 table carried nothing across")
        // The cost view only exists at v5, so a non-empty read proves it was created.
        #expect(await v5.readClaudeReportRows(
            backends: nil,
            roots: ["/Users/alex/.claude/projects"],
            sinceDay: "2026-09-01",
            untilDay: "2026-09-30").count == 1)
    }

    private static func usageEvent() -> ClaudeStoreUsageEvent {
        ClaudeStoreUsageEvent(
            rowIndex: 0,
            timestampUnixMs: 1_789_000_000_000,
            day: "2026-09-17",
            backend: "firstParty",
            model: "claude-opus-5",
            rawModel: "claude-opus-5",
            sessionID: "s1",
            messageID: "m1",
            requestID: "r1",
            cwd: "/p",
            gitBranch: nil,
            pathRole: "main",
            isSidechain: false,
            effort: nil,
            serviceTier: nil,
            input: 10,
            cacheRead: 0,
            cacheCreate: 0,
            cacheCreate1h: 0,
            output: 20,
            thinkingTokens: 0,
            webSearchRequests: 0,
            webFetchRequests: 0,
            ingestCostNanos: 1000,
            ingestCostPriced: true)
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
