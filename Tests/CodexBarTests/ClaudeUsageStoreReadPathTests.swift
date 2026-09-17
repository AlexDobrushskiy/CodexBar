import Foundation
import Testing
@testable import CodexBarCore

/// One unfiltered scan feeds every Claude ledger; the split is a `WHERE` over `backend`.
///
/// Before this, each provider re-scanned the same transcripts behind its own row filter, which is
/// why the store stayed empty in normal operation: the mirror only accepts an unfiltered scan.
@Suite(.serialized)
struct ClaudeUsageStoreReadPathTests {
    private static func line(
        timestamp: String,
        messageID: String,
        model: String = "claude-opus-5",
        input: Int = 10,
        output: Int = 20) throws -> String
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

    /// First-party + Bedrock rows in one transcript, which is how Claude Code actually writes them.
    private static func seedMixedTranscript(_ env: CostUsageTestEnvironment, day: Date) throws {
        let stamp = env.isoString(for: day)
        let contents = try Self.line(timestamp: stamp, messageID: "msg_011first") + "\n"
            + Self.line(timestamp: stamp, messageID: "msg_bdrk_second", input: 1, output: 2) + "\n"
        _ = try env.writeClaudeProjectFile(relativePath: "-p/session.jsonl", contents: contents)
    }

    private static func report(
        _ env: CostUsageTestEnvironment,
        provider: UsageProvider,
        day: Date,
        scope: CostUsageScanner.ClaudeLogProviderFilter? = nil,
        roots: [URL]? = nil) -> CostUsageDailyReport
    {
        var options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        options.claudeProjectsRoots = roots ?? [env.claudeProjectsRoot]
        options.refreshMinIntervalSeconds = 0
        options.claudeBackendScope = scope
        return CostUsageScanner.loadDailyReport(
            provider: provider,
            since: day,
            until: day,
            now: day,
            options: options)
    }

    /// The Bedrock ledger must be a scoped read over a full scan, not a scoped scan.
    @Test
    func `a bedrock ledger scan stores every backend`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        try Self.seedMixedTranscript(env, day: day)

        let report = Self.report(env, provider: .bedrock, day: day)

        #expect(report.data.count == 1)
        #expect(report.data.first?.totalTokens == 3, "Bedrock's ledger stays Bedrock-only")

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let backends = await Set(store.readReconciledClaudeEvents().map(\.backend))
        #expect(backends == ["firstParty", "bedrock"], "the scan behind it was unfiltered")
    }

    /// The Claude ledger is first-party only, taken from the same rows Bedrock's ledger reads.
    @Test
    func `a first party ledger excludes bedrock rows from the same transcript`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        try Self.seedMixedTranscript(env, day: day)

        let claude = Self.report(env, provider: .claude, day: day, scope: .firstPartyOnly)
        let bedrock = Self.report(env, provider: .bedrock, day: day)

        #expect(claude.data.first?.totalTokens == 30)
        #expect(bedrock.data.first?.totalTokens == 3)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let backends = await Set(store.readReconciledClaudeEvents().map(\.backend))
        #expect(backends == ["firstParty", "bedrock"], "one scan, two ledgers")
    }

    /// A profile-scoped scan walks part of the vault, so it may neither report nor evict the rest.
    @Test
    func `a roots scoped scan leaves other roots alone`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        let stamp = env.isoString(for: day)
        try Self.seedMixedTranscript(env, day: day)

        let otherRoot = env.root.appendingPathComponent("claude-projects-b", isDirectory: true)
        let otherFile = otherRoot.appendingPathComponent("-q/session.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: otherFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try (Self.line(timestamp: stamp, messageID: "msg_011other", input: 100, output: 200) + "\n")
            .write(to: otherFile, atomically: true, encoding: .utf8)

        _ = Self.report(env, provider: .claude, day: day, scope: .firstPartyOnly)
        let scoped = Self.report(
            env,
            provider: .claude,
            day: day,
            scope: .firstPartyOnly,
            roots: [otherRoot])

        #expect(scoped.data.first?.totalTokens == 300, "only the root this scan walked")

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let messages = await Set(store.readReconciledClaudeEvents().compactMap(\.messageID))
        #expect(
            messages == ["msg_011first", "msg_bdrk_second", "msg_011other"],
            "the unwalked root keeps its rows")
    }
}
