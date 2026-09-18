import Foundation
import Testing
@testable import CodexBarCore

/// Nothing else bounds the Claude tables: a real vault is ~56k events per 30-day window, and a
/// transcript that is never touched again keeps its old rows forever.
///
/// Pruning them is only half of it. Dropping events while keeping EOF offsets would make a later,
/// wider window look falsely complete, so coverage is clamped to what actually survived.
@Suite(.serialized)
struct ClaudeUsageStoreRetentionTests {
    private static func file(path: String, since: String, until: String) -> ClaudeStoreSourceFile {
        ClaudeStoreSourceFile(
            path: path,
            fileIdentity: "ino-1",
            size: 100,
            mtimeMs: 1_700_000_000_000,
            parsedOffset: 100,
            coverageSinceDay: since,
            coverageUntilDay: until,
            parserRevision: 1,
            tzIdentity: "Europe/Lisbon",
            complete: true)
    }

    private static func event(rowIndex: Int, day: String) -> ClaudeStoreUsageEvent {
        ClaudeStoreUsageEvent(
            rowIndex: rowIndex,
            timestampUnixMs: 1_789_000_000_000,
            day: day,
            backend: "firstParty",
            model: "claude-opus-5",
            rawModel: "claude-opus-5",
            sessionID: "s1",
            messageID: "m\(rowIndex)",
            requestID: "r\(rowIndex)",
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
            ingestCostNanos: 0,
            ingestCostPriced: false)
    }

    private static func seed(_ store: CostUsageStore, path: String, days: [String]) async throws {
        let file = Self.file(
            path: path,
            since: days.min() ?? "",
            until: days.max() ?? "")
        let events = days.enumerated().map { Self.event(rowIndex: $0.offset, day: $0.element) }
        #expect(await store.writeClaudeFile(file, events: events, mode: .replace, expecting: nil).isWritten)
    }

    @Test
    func `pruning drops events outside the window and clamps the coverage that is left`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        try await Self.seed(store, path: "/roots/p/s.jsonl", days: ["2026-07-01", "2026-09-10", "2026-09-17"])

        let result = await store.retainClaudeDayWindow(sinceDay: "2026-09-01", untilDay: "2026-09-30")

        #expect(result.deletedEvents == 1)
        #expect(result.deletedSourceFiles == 0)
        let days = await Set(store.readReconciledClaudeEvents().map(\.day))
        #expect(days == ["2026-09-10", "2026-09-17"])
        let stored = try #require(await store.readClaudeSourceFiles().first)
        #expect(
            stored.coverageSinceDay == "2026-09-01",
            "the file no longer claims to cover July, though its offset is still at EOF")
        #expect(stored.coverageUntilDay == "2026-09-17")
    }

    /// An archived transcript with nothing left in the window describes nothing, and keeping its
    /// offsets is the falsely-complete state itself. One still on disk keeps its row: it is still
    /// tracked, and dropping it would make every later scan reparse it from the start.
    @Test
    func `an archived file left with no events in the window is dropped`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        try await Self.seed(store, path: "/roots/p/gone.jsonl", days: ["2026-01-01"])
        try await Self.seed(store, path: "/roots/p/onDisk.jsonl", days: ["2026-01-01"])
        try await Self.seed(store, path: "/roots/p/new.jsonl", days: ["2026-09-17"])
        #expect(await store.markClaudeSourceMissing(path: "/roots/p/gone.jsonl"))

        let result = await store.retainClaudeDayWindow(sinceDay: "2026-09-01", untilDay: "2026-09-30")

        #expect(result.deletedSourceFiles == 1)
        #expect(
            await store.readClaudeSourceFiles().map(\.path)
                == ["/roots/p/new.jsonl", "/roots/p/onDisk.jsonl"])
    }

    /// The store is global; a ledger is not. A profile's prune may not evict another profile's rows.
    @Test
    func `a roots scoped prune leaves other roots alone`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        try await Self.seed(store, path: "/roots/a/s.jsonl", days: ["2026-01-01"])
        try await Self.seed(store, path: "/roots/b/s.jsonl", days: ["2026-01-01"])
        #expect(await store.markClaudeSourceMissing(path: "/roots/a/s.jsonl"))
        #expect(await store.markClaudeSourceMissing(path: "/roots/b/s.jsonl"))

        let result = await store.retainClaudeDayWindow(
            sinceDay: "2026-09-01",
            untilDay: "2026-09-30",
            roots: ["/roots/a"])

        #expect(result.deletedSourceFiles == 1)
        #expect(await store.readClaudeSourceFiles().map(\.path) == ["/roots/b/s.jsonl"])
    }

    /// The query a scan uses to find what it can no longer answer for over a widened window.
    @Test
    func `clamped coverage names the files a wider window must reparse`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        try await Self.seed(store, path: "/roots/p/s.jsonl", days: ["2026-07-01", "2026-09-17"])
        _ = await store.retainClaudeDayWindow(sinceDay: "2026-09-01", untilDay: "2026-09-30")

        #expect(await store.claudeSourceFilesNeedingReparse(sinceDay: "2026-09-01").isEmpty)
        // Before the prune this file covered 2026-07-01, so a window opening on 2026-08-31 needed
        // nothing from it. The clamp is what makes it ask to be reparsed.
        #expect(
            await store.claudeSourceFilesNeedingReparse(sinceDay: "2026-08-31") == ["/roots/p/s.jsonl"])
    }

    /// The Codex day-window prune is the same mechanism, and it must now carry Claude across.
    @Test
    func `the shared day window prune covers the claude tables`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        try await Self.seed(store, path: "/roots/p/s.jsonl", days: ["2026-07-01", "2026-09-17"])

        let result = await store.retainDayWindow(sinceDay: "2026-09-01", untilDay: "2026-09-30")

        #expect(result.claude.deletedEvents == 1)
    }
}
