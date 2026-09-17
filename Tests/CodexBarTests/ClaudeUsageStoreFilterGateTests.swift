import Foundation
import Testing
@testable import CodexBarCore

/// The store holds every backend; the ledger split is a `WHERE` clause, not a separate scan.
///
/// A provider-scoped scan parses only the rows its filter admits, so mirroring one into the store
/// would leave a partial row set — and because the mirror replaces a file's events, a later scan for
/// a different backend would swap them out. Only an unfiltered scan may write.
@Suite(.serialized)
struct ClaudeUsageStoreFilterGateTests {
    private static func line(timestamp: String, messageID: String) throws -> String {
        let entry: [String: Any] = [
            "type": "assistant",
            "uuid": "u-\(messageID)",
            "sessionId": "s1",
            "requestId": "req-\(messageID)",
            "cwd": "/p",
            "isSidechain": false,
            "timestamp": timestamp,
            "message": [
                "id": messageID,
                "type": "message",
                "role": "assistant",
                "model": "claude-opus-5",
                "usage": ["input_tokens": 10, "output_tokens": 20],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        return try #require(String(bytes: data, encoding: .utf8))
    }

    private static func scan(
        _ env: CostUsageTestEnvironment,
        day: Date,
        filter: CostUsageScanner.ClaudeLogProviderFilter)
    {
        var options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        options.claudeProjectsRoots = [env.claudeProjectsRoot]
        options.refreshMinIntervalSeconds = 0
        options.claudeLogProviderFilter = filter
        _ = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
    }

    private static func seedBothBackends(_ env: CostUsageTestEnvironment, day: Date) throws {
        let stamp = env.isoString(for: day)
        let contents = try Self.line(timestamp: stamp, messageID: "msg_011first") + "\n"
            + Self.line(timestamp: stamp, messageID: "msg_bdrk_second") + "\n"
        _ = try env.writeClaudeProjectFile(relativePath: "-p/session.jsonl", contents: contents)
    }

    @Test
    func `an unfiltered scan stores every backend`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        try Self.seedBothBackends(env, day: day)

        Self.scan(env, day: day, filter: .all)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let backends = await Set(store.readReconciledClaudeEvents().map(\.backend))
        #expect(backends == ["firstParty", "bedrock"])
    }

    /// A first-party-only scan admits half the rows, so it must leave the store untouched rather
    /// than persist a half-truth.
    @Test
    func `a filtered scan does not write a partial row set`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        try Self.seedBothBackends(env, day: day)

        Self.scan(env, day: day, filter: .firstPartyOnly)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        #expect(await store.readReconciledClaudeEvents().isEmpty)
    }

    /// The failure this gate prevents: a Bedrock-scoped scan replacing the stored first-party rows.
    @Test
    func `a filtered scan cannot displace rows a full scan stored`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        try Self.seedBothBackends(env, day: day)

        Self.scan(env, day: day, filter: .all)
        Self.scan(env, day: day, filter: .bedrockOnly)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let backends = await Set(store.readReconciledClaudeEvents().map(\.backend))
        #expect(backends == ["firstParty", "bedrock"], "the full scan's rows survive")
    }
}
