import Foundation
import Testing
@testable import CodexBarCore

/// The scanner used to collapse each transcript line into day×model totals, dropping everything
/// that makes usage answerable by project, branch or backend. These fields are present in every
/// transcript line; this asserts they survive all the way into the store.
@Suite(.serialized)
struct ClaudeUsageRowDetailTests {
    private static func transcriptLine(
        timestamp: String,
        messageID: String,
        model: String) throws -> String
    {
        let entry: [String: Any] = [
            "type": "assistant",
            "uuid": "u1",
            "sessionId": "session-detail",
            "requestId": "req_detail",
            "cwd": "/Users/alex/PycharmProjects/hearst",
            "gitBranch": "feature/ocr",
            "effort": "xhigh",
            "isSidechain": false,
            "timestamp": timestamp,
            "message": [
                "id": messageID,
                "type": "message",
                "role": "assistant",
                "model": model,
                "usage": [
                    "input_tokens": 10,
                    "output_tokens": 20,
                    "cache_read_input_tokens": 30,
                    "cache_creation_input_tokens": 40,
                    "service_tier": "standard",
                    "output_tokens_details": ["thinking_tokens": 7],
                    "server_tool_use": ["web_search_requests": 2, "web_fetch_requests": 3],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        return try #require(String(bytes: data, encoding: .utf8))
    }

    private static func storedRow(
        _ env: CostUsageTestEnvironment,
        line: String,
        day: Date) async throws -> ClaudeStoreUsageEvent
    {
        _ = try env.writeClaudeProjectFile(relativePath: "-p/session.jsonl", contents: line + "\n")
        var options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        options.claudeProjectsRoots = [env.claudeProjectsRoot]
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        return try #require(await store.readReconciledClaudeEvents().first?.event)
    }

    @Test
    func `a parsed row carries project branch effort tier and tool counts`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        let row = try await Self.storedRow(
            env,
            line: Self.transcriptLine(
                timestamp: env.isoString(for: day),
                messageID: "msg_011detail",
                model: "claude-opus-5"),
            day: day)

        #expect(row.cwd == "/Users/alex/PycharmProjects/hearst")
        #expect(row.gitBranch == "feature/ocr")
        #expect(row.effort == "xhigh")
        #expect(row.serviceTier == "standard")
        #expect(row.thinkingTokens == 7)
        #expect(row.webSearchRequests == 2)
        #expect(row.webFetchRequests == 3)
    }

    /// The row records which backend billed it, so the ledger split is a column rather than two
    /// separately filtered scans writing two cache files.
    @Test
    func `a parsed row records the billing backend`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)

        let firstParty = try await Self.storedRow(
            env,
            line: Self.transcriptLine(
                timestamp: env.isoString(for: day),
                messageID: "msg_011detail",
                model: "claude-opus-5"),
            day: day)
        #expect(firstParty.backend == "firstParty")

        let bedrockEnv = try CostUsageTestEnvironment()
        defer { bedrockEnv.cleanup() }
        let bedrock = try await Self.storedRow(
            bedrockEnv,
            line: Self.transcriptLine(
                timestamp: bedrockEnv.isoString(for: day),
                messageID: "msg_bdrk_detail",
                model: "claude-opus-5"),
            day: day)
        #expect(bedrock.backend == "bedrock")
    }

    /// Normalization can change as aliases move, so the as-written model is kept alongside it and
    /// a pricing correction never needs a transcript reparse.
    @Test
    func `a parsed row keeps the model as written`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        let row = try await Self.storedRow(
            env,
            line: Self.transcriptLine(
                timestamp: env.isoString(for: day),
                messageID: "msg_011detail",
                model: "anthropic.claude-haiku-4-5-20251001-v1:0"),
            day: day)

        #expect(row.rawModel == "anthropic.claude-haiku-4-5-20251001-v1:0")
        #expect(row.backend == "bedrock", "the Bedrock model namespace also marks the backend")
    }
}
