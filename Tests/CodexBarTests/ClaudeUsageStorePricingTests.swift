import Foundation
import Testing
@testable import CodexBarCore

/// Cost is a view over events × prices, so tokens stay the only stored fact.
///
/// Before this the stored `ingest_cost_*` were the only cost figures in the database, which made
/// the ingest-time catalog a second pricing authority that no later catalog refresh could correct.
@Suite(.serialized)
struct ClaudeUsageStorePricingTests {
    private static func line(
        timestamp: String,
        messageID: String,
        model: String,
        input: Int,
        output: Int = 0) throws -> String
    {
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
                "model": model,
                "usage": ["input_tokens": input, "output_tokens": output],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        return try #require(String(bytes: data, encoding: .utf8))
    }

    private static func report(_ env: CostUsageTestEnvironment, day: Date) -> CostUsageDailyReport {
        var options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        options.claudeProjectsRoots = [env.claudeProjectsRoot]
        options.refreshMinIntervalSeconds = 0
        return CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
    }

    /// The catalog's own rates have to reach the database, or the view prices nothing.
    @Test
    func `a scan seeds the prices for the models it stored`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 1)
        _ = try env.writeClaudeProjectFile(
            relativePath: "-p/s.jsonl",
            contents: Self.line(
                timestamp: env.isoString(for: day),
                messageID: "msg_011a",
                model: "claude-opus-4-6",
                input: 1000) + "\n")

        _ = Self.report(env, day: day)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let prices = await store.readClaudeModelPrices()

        #expect(prices.map(\.model) == ["claude-opus-4-6", "claude-opus-4-6"])
        #expect(prices.allSatisfy { $0.backend == "firstParty" })
        // The full-context models changed tier pricing at a known instant: one window each side.
        #expect(prices[0].longContextThreshold == 200_000)
        #expect(prices[0].longContextInputPerToken == 1e-5)
        #expect(prices[1].longContextThreshold == nil)
        #expect(prices[0].validToMs == prices[1].validFromMs)
        #expect(prices[1].validToMs == nil)
    }

    /// The invariant the spec is built around: aggregating tokens before pricing is wrong.
    ///
    /// Two requests of 150k input each are both under the 200k long-context threshold and are
    /// priced at the standard rate. Their day sums to 300k, so a report that priced the aggregate
    /// would charge the long-context rate for every token of it.
    @Test
    func `long context tiers are chosen per event and not per day`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        // Before 2026-03-13, when claude-opus-4-6 still had a long-context tier.
        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 1)
        let stamp = env.isoString(for: day)
        let contents = try Self.line(
            timestamp: stamp,
            messageID: "msg_011a",
            model: "claude-opus-4-6",
            input: 150_000) + "\n"
            + Self.line(
                timestamp: stamp,
                messageID: "msg_011b",
                model: "claude-opus-4-6",
                input: 150_000) + "\n"
        _ = try env.writeClaudeProjectFile(relativePath: "-p/s.jsonl", contents: contents)

        let report = Self.report(env, day: day)

        let cost = try #require(report.data.first?.costUSD)
        #expect(abs(cost - 1.5) < 1e-9, "2 × 150_000 × 5e-6 at the standard tier")
        #expect(cost < 3.0, "the long-context tier would have doubled it")
    }

    /// A model the current catalog cannot price keeps the cost it was priced with at ingest.
    @Test
    func `an event without a current price falls back to its ingest cost`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let file = ClaudeStoreSourceFile(
            path: "/roots/p/s.jsonl",
            fileIdentity: "ino-1",
            size: 10,
            mtimeMs: 1,
            parsedOffset: 10,
            coverageSinceDay: "2026-09-17",
            coverageUntilDay: "2026-09-17",
            parserRevision: 1,
            tzIdentity: "Europe/Lisbon",
            complete: true)
        let fileID = try #require(await store.upsertClaudeSourceFile(file))
        #expect(await store.appendClaudeUsageEvents(fileID: fileID, events: [
            ClaudeStoreUsageEvent(
                rowIndex: 0,
                timestampUnixMs: 1_789_000_000_000,
                day: "2026-09-17",
                backend: "firstParty",
                model: "retired-model",
                rawModel: "retired-model",
                sessionID: "s1",
                messageID: "m1",
                requestID: "r1",
                cwd: "/p",
                gitBranch: nil,
                pathRole: "main",
                isSidechain: false,
                effort: nil,
                serviceTier: nil,
                input: 100,
                cacheRead: 0,
                cacheCreate: 0,
                cacheCreate1h: 0,
                output: 10,
                thinkingTokens: 0,
                webSearchRequests: 0,
                webFetchRequests: 0,
                ingestCostNanos: 4_200_000,
                ingestCostPriced: true),
        ]))
        #expect(await store.replaceClaudeModelPrices([]))

        let rows = await store.readClaudeReportRows(
            backends: nil,
            roots: ["/roots"],
            sinceDay: "2026-09-01",
            untilDay: "2026-09-30")

        #expect(rows.count == 1)
        #expect(rows.first?.costUSD == 0.0042)
    }
}
