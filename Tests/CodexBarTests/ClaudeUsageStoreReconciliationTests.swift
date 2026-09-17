import Foundation
import Testing
@testable import CodexBarCore

/// Cross-file reconciliation, reproducing `claudeRowWins` in SQL.
///
/// One canonical `(backend, message_id, request_id)` can appear in a parent transcript and again in
/// its subagent copies. Every candidate stays stored — deleting the winner must reveal the loser —
/// so the winner is chosen by the view: non-sidechain beats sidechain, `main` beats `subagent`,
/// then the path sort key breaks the tie.
@Suite(.serialized)
struct ClaudeUsageStoreReconciliationTests {
    /// Which side of the parent/subagent ranking a candidate sits on.
    private enum Role {
        case parent
        case subagent

        var pathRole: String {
            self == .parent ? "main" : "subagent"
        }

        var isSidechain: Bool {
            self == .subagent
        }
    }

    private static func sourceFile(path: String) -> ClaudeStoreSourceFile {
        ClaudeStoreSourceFile(
            path: path,
            fileIdentity: "ino-\(path)",
            size: 64,
            mtimeMs: 1_700_000_000_000,
            parsedOffset: 64,
            coverageSinceDay: "2026-09-17",
            coverageUntilDay: "2026-09-17",
            parserRevision: 1,
            tzIdentity: "Europe/Lisbon",
            complete: true)
    }

    /// `key` names the canonical identity; nil leaves both ids null, which carries no identity.
    private static func event(
        key: String?,
        role: Role,
        output: Int,
        rowIndex: Int = 1) -> ClaudeStoreUsageEvent
    {
        ClaudeStoreUsageEvent(
            rowIndex: rowIndex,
            timestampUnixMs: 1_700_000_000_000,
            day: "2026-09-17",
            backend: "firstParty",
            model: "claude-opus-5",
            rawModel: "claude-opus-5",
            sessionID: "s1",
            messageID: key.map { "msg_\($0)" },
            requestID: key.map { "req_\($0)" },
            cwd: "/p",
            gitBranch: "main",
            pathRole: role.pathRole,
            isSidechain: role.isSidechain,
            effort: nil,
            serviceTier: nil,
            input: 0,
            cacheRead: 0,
            cacheCreate: 0,
            cacheCreate1h: 0,
            output: output,
            thinkingTokens: 0,
            webSearchRequests: 0,
            webFetchRequests: 0,
            ingestCostNanos: 0,
            ingestCostPriced: false)
    }

    private static func row(
        _ path: String,
        key: String?,
        role: Role,
        output: Int) -> (path: String, event: ClaudeStoreUsageEvent)
    {
        (path: path, event: self.event(key: key, role: role, output: output))
    }

    private static func seed(
        _ store: CostUsageStore,
        _ rows: [(path: String, event: ClaudeStoreUsageEvent)]) async
    {
        for row in rows {
            guard let id = await store.upsertClaudeSourceFile(sourceFile(path: row.path)) else {
                Issue.record("could not upsert \(row.path)")
                continue
            }
            #expect(await store.appendClaudeUsageEvents(fileID: id, events: [row.event]))
        }
    }

    @Test
    func `parent wins over subagent copies and unique sidechain rows survive`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)

        await Self.seed(store, [
            Self.row("/p/session.jsonl", key: "overlap", role: .parent, output: 100),
            Self.row("/p/session/subagents/a.jsonl", key: "overlap", role: .subagent, output: 100),
            Self.row("/p/session/subagents/b.jsonl", key: "unique", role: .subagent, output: 55),
        ])

        let reconciled = await store.readReconciledClaudeEvents()

        #expect(reconciled.count == 2, "the overlap collapses, the unique sidechain stays")
        #expect(reconciled.map(\.output).reduce(0, +) == 155)
        let overlap = reconciled.first { $0.messageID == "msg_overlap" }
        #expect(overlap?.pathRole == "main")
        #expect(overlap?.isSidechain == false)
    }

    @Test
    func `equal rank candidates break the tie on the path sort key`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)

        await Self.seed(store, [
            Self.row("/p/b.jsonl", key: "x", role: .subagent, output: 2),
            Self.row("/p/a.jsonl", key: "x", role: .subagent, output: 1),
        ])

        let reconciled = await store.readReconciledClaudeEvents()

        #expect(reconciled.count == 1)
        #expect(reconciled.first?.sourcePath == "/p/a.jsonl", "lower path sort key wins")
    }

    /// The point of keeping every candidate: the loser is still there when the winner goes away.
    @Test
    func `deleting the parent source reveals the retained sidechain loser`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)

        await Self.seed(store, [
            Self.row("/p/session.jsonl", key: "overlap", role: .parent, output: 100),
            Self.row("/p/session/subagents/a.jsonl", key: "overlap", role: .subagent, output: 7),
        ])
        #expect(await store.readReconciledClaudeEvents().first?.output == 100)

        #expect(await store.deleteClaudeSourceFile(path: "/p/session.jsonl"))

        let reconciled = await store.readReconciledClaudeEvents()
        #expect(reconciled.count == 1)
        #expect(reconciled.first?.output == 7, "the subagent candidate was retained, not discarded")
    }

    /// Rows with no canonical identity must pass through individually, never sharing a partition.
    @Test
    func `unkeyed rows all pass through the view`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)

        let id = try #require(await store.upsertClaudeSourceFile(Self.sourceFile(path: "/p/s.jsonl")))
        #expect(await store.appendClaudeUsageEvents(fileID: id, events: [
            Self.event(key: nil, role: .parent, output: 3, rowIndex: 1),
            Self.event(key: nil, role: .parent, output: 4, rowIndex: 2),
        ]))

        let reconciled = await store.readReconciledClaudeEvents()

        #expect(reconciled.count == 2)
        #expect(reconciled.map(\.output).reduce(0, +) == 7)
    }

    /// The case the persisted sort key exists for.
    ///
    /// APFS stores this path decomposed. Swift ranks "cafz" before the decomposed "cafe\u{0301}",
    /// but SQLite's BINARY collation on the raw path ranks it the other way — so ordering on
    /// `path` would make the view disagree with `claudeRowWins`.
    @Test
    func `decomposed non ascii paths rank the same way as swift`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)

        let decomposed = "/p/cafe\u{0301}/a.jsonl"
        let plain = "/p/cafz/a.jsonl"
        #expect(!(decomposed < plain), "precondition: Swift ranks the decomposed path after cafz")

        await Self.seed(store, [
            Self.row(decomposed, key: "x", role: .subagent, output: 1),
            Self.row(plain, key: "x", role: .subagent, output: 2),
        ])

        let reconciled = await store.readReconciledClaudeEvents()

        #expect(reconciled.count == 1)
        #expect(reconciled.first?.sourcePath == plain, "same winner the Swift comparison picks")
    }
}
