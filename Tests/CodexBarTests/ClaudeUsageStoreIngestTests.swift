import Foundation
import Testing
@testable import CodexBarCore

/// End-to-end: transcripts on disk become queryable rows in the store.
///
/// This is the seam the whole migration exists for — a scan must leave behind per-event rows that
/// can answer "what did this project cost on this backend", not just day×model totals.
@Suite(.serialized)
struct ClaudeUsageStoreIngestTests {
    private static func line(
        timestamp: String,
        messageID: String,
        cwd: String,
        model: String = "claude-opus-5",
        output: Int = 20) throws -> String
    {
        let entry: [String: Any] = [
            "type": "assistant",
            "uuid": "u-\(messageID)",
            "sessionId": "session-1",
            "requestId": "req-\(messageID)",
            "cwd": cwd,
            "gitBranch": "main",
            "isSidechain": false,
            "timestamp": timestamp,
            "message": [
                "id": messageID,
                "type": "message",
                "role": "assistant",
                "model": model,
                "usage": [
                    "input_tokens": 10,
                    "output_tokens": output,
                    "cache_read_input_tokens": 0,
                    "cache_creation_input_tokens": 0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        return try #require(String(bytes: data, encoding: .utf8))
    }

    private static func scan(_ env: CostUsageTestEnvironment, day: Date) {
        var options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        options.claudeProjectsRoots = [env.claudeProjectsRoot]
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
    }

    @Test
    func `a scan writes per event rows into the store`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        let stamp = env.isoString(for: day)

        let contents = try Self.line(
            timestamp: stamp,
            messageID: "msg_011a",
            cwd: "/Users/alex/PycharmProjects/hearst") + "\n"
            + Self.line(
                timestamp: stamp,
                messageID: "msg_bdrk_b",
                cwd: "/Users/alex/Documents/Projects/obsidian",
                output: 50) + "\n"
        _ = try env.writeClaudeProjectFile(relativePath: "-p/session.jsonl", contents: contents)

        Self.scan(env, day: day)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let rows = await store.readReconciledClaudeEvents()

        #expect(rows.count == 2)
        #expect(Set(rows.map(\.backend)) == ["firstParty", "bedrock"])
        #expect(Set(rows.compactMap(\.event.cwd)) == [
            "/Users/alex/PycharmProjects/hearst",
            "/Users/alex/Documents/Projects/obsidian",
        ])
        let bedrock = try #require(rows.first { $0.backend == "bedrock" })
        #expect(bedrock.output == 50)
        #expect(bedrock.event.gitBranch == "main")
    }

    /// Rescanning an unchanged transcript must not double-count it.
    @Test
    func `rescanning the same transcript does not duplicate rows`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        let contents = try Self.line(
            timestamp: env.isoString(for: day),
            messageID: "msg_011a",
            cwd: "/p") + "\n"
        _ = try env.writeClaudeProjectFile(relativePath: "-p/session.jsonl", contents: contents)

        Self.scan(env, day: day)
        Self.scan(env, day: day)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        #expect(await store.readReconciledClaudeEvents().count == 1)
    }

    /// The store must answer the question the JSON artifact could not.
    @Test
    func `stored rows answer cost by project and backend`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        let stamp = env.isoString(for: day)

        let contents = try Self.line(timestamp: stamp, messageID: "msg_011a", cwd: "/work/hearst")
            + "\n"
            + Self.line(timestamp: stamp, messageID: "msg_011b", cwd: "/work/hearst", output: 30)
            + "\n"
            + Self.line(timestamp: stamp, messageID: "msg_bdrk_c", cwd: "/work/vault", output: 7)
            + "\n"
        _ = try env.writeClaudeProjectFile(relativePath: "-p/session.jsonl", contents: contents)

        Self.scan(env, day: day)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let totals = await store.readClaudeTokenTotalsByProject()

        #expect(totals["/work/hearst"]?["firstParty"] == 70, "(10+20) + (10+30) input+output")
        #expect(totals["/work/vault"]?["bedrock"] == 17)
        #expect(totals["/work/hearst"]?["bedrock"] == nil)
    }
}
