import Foundation
import Testing
@testable import CodexBarCore

/// The store is a usage record, not a mirror of the transcripts.
///
/// Claude Code rotates transcripts and people delete projects. Once the JSON artifacts retire the
/// store is the only copy, so a transcript leaving the disk must not take its usage with it — it is
/// marked as no longer present and its events stay until the day window prunes them.
@Suite(.serialized)
struct ClaudeUsageStoreArchiveTests {
    private static func line(timestamp: String, messageID: String, output: Int = 20) throws -> String {
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
                "usage": ["input_tokens": 10, "output_tokens": output],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        return try #require(String(bytes: data, encoding: .utf8))
    }

    @discardableResult
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

    @Test
    func `a transcript that leaves the disk keeps its usage`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        let stamp = env.isoString(for: day)
        let kept = try env.writeClaudeProjectFile(
            relativePath: "-p/kept.jsonl",
            contents: Self.line(timestamp: stamp, messageID: "msg_011kept") + "\n")
        let removed = try env.writeClaudeProjectFile(
            relativePath: "-p/removed.jsonl",
            contents: Self.line(timestamp: stamp, messageID: "msg_011gone", output: 70) + "\n")

        Self.report(env, day: day)
        try FileManager.default.removeItem(at: removed)
        let after = Self.report(env, day: day)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let messages = await Set(store.readReconciledClaudeEvents().compactMap(\.messageID))
        #expect(messages == ["msg_011kept", "msg_011gone"], "the deleted transcript's usage survives")

        // The inventory walks the /private-resolved root, so match on the stored spelling.
        let files = await store.readClaudeSourceFiles()
        let gone = try #require(files.first { $0.path.hasSuffix(removed.lastPathComponent) })
        #expect(gone.sourcePresent == false)
        #expect(files.first { $0.path.hasSuffix(kept.lastPathComponent) }?.sourcePresent == true)

        #expect(
            after.data.first?.totalTokens == 110,
            "and still counts: (10+20) live plus (10+70) archived")
    }

    /// A transcript restored at the same path is the same usage, not more of it.
    @Test
    func `a returning transcript is not counted twice`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        let contents = try Self.line(timestamp: env.isoString(for: day), messageID: "msg_011a") + "\n"
        let url = try env.writeClaudeProjectFile(relativePath: "-p/s.jsonl", contents: contents)

        Self.report(env, day: day)
        try FileManager.default.removeItem(at: url)
        Self.report(env, day: day)
        _ = try env.writeClaudeProjectFile(relativePath: "-p/s.jsonl", contents: contents)
        let after = Self.report(env, day: day)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        #expect(await store.readReconciledClaudeEvents().count == 1)
        #expect(await store.readClaudeSourceFiles().first?.sourcePresent == true)
        #expect(after.data.first?.totalTokens == 30)
    }

    /// Archiving is not a licence to grow forever: the day window still prunes.
    @Test
    func `retention still removes an archived transcript once its days age out`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        let url = try env.writeClaudeProjectFile(
            relativePath: "-p/s.jsonl",
            contents: Self.line(timestamp: env.isoString(for: day), messageID: "msg_011a") + "\n")

        Self.report(env, day: day)
        try FileManager.default.removeItem(at: url)
        Self.report(env, day: day)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        #expect(await store.readClaudeSourceFiles().count == 1)

        _ = await store.retainClaudeDayWindow(sinceDay: "2026-10-01", untilDay: "2026-10-31")

        #expect(await store.readClaudeSourceFiles().isEmpty)
        #expect(await store.readReconciledClaudeEvents().isEmpty)
    }
}
