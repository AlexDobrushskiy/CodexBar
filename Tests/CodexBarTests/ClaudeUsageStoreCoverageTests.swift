import Foundation
import Testing
@testable import CodexBarCore

/// Two ways a stored row can quietly stop describing its source.
///
/// `day` is derived from the local calendar, so it is not timeless — a different time zone buckets
/// the same instant differently. And a transcript written to while it is being read is parsed only
/// as far as it went, so stamping it complete would stop the next scan from finishing the job.
@Suite(.serialized)
struct ClaudeUsageStoreCoverageTests {
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

    private static func calendar(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: identifier))
        return calendar
    }

    private static func scan(
        _ env: CostUsageTestEnvironment,
        day: Date,
        calendar: Calendar,
        didParseFile: (@Sendable (URL) -> Void)? = nil)
    {
        var options = CostUsageScanner.Options(cacheRoot: env.cacheRoot, calendar: calendar)
        options.claudeProjectsRoots = [env.claudeProjectsRoot]
        options.refreshMinIntervalSeconds = 0
        options.claudeDidParseFileForTesting = didParseFile
        _ = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day.addingTimeInterval(-86400),
            until: day.addingTimeInterval(86400),
            now: day.addingTimeInterval(86400),
            options: options)
    }

    /// 2026-09-17 22:30 UTC is the 17th in London and already the 18th in Tokyo.
    @Test
    func `a time zone change rebuckets the stored days`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let instant = Date(timeIntervalSince1970: 1_789_684_200)
        _ = try env.writeClaudeProjectFile(
            relativePath: "-p/s.jsonl",
            contents: Self.line(
                timestamp: ISO8601DateFormatter().string(from: instant),
                messageID: "msg_011a") + "\n")

        try Self.scan(env, day: instant, calendar: Self.calendar("Europe/London"))
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        #expect(await store.readReconciledClaudeEvents().map(\.day) == ["2026-09-17"])
        #expect(await store.readClaudeSourceFiles().map(\.tzIdentity) == ["Europe/London"])

        try Self.scan(env, day: instant, calendar: Self.calendar("Asia/Tokyo"))

        #expect(
            await store.readReconciledClaudeEvents().map(\.day) == ["2026-09-18"],
            "the stored day is not timeless and has to follow the calendar it was bucketed under")
        #expect(await store.readClaudeSourceFiles().map(\.tzIdentity) == ["Asia/Tokyo"])
    }

    /// A transcript that grows between its parse and its commit is not fully covered.
    @Test
    func `a transcript that moves while being parsed is not stamped complete`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        let stamp = env.isoString(for: day)
        let url = try env.writeClaudeProjectFile(
            relativePath: "-p/s.jsonl",
            contents: Self.line(timestamp: stamp, messageID: "msg_011a") + "\n")
        let appended = try Self.line(timestamp: stamp, messageID: "msg_011b") + "\n"

        Self.scan(env, day: day, calendar: .current) { parsed in
            guard parsed.lastPathComponent == url.lastPathComponent else { return }
            guard let handle = try? FileHandle(forWritingTo: parsed) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(appended.utf8))
        }

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let files = await store.readClaudeSourceFiles()
        #expect(files.count == 1)
        #expect(files.first?.complete == false, "the next scan still has bytes to read")

        // The rows it did read are real, and the next scan finishes the file off.
        Self.scan(env, day: day, calendar: .current)
        let after = await store.readClaudeSourceFiles()
        #expect(after.first?.complete == true)
        #expect(await store.readReconciledClaudeEvents().count == 2)
    }
}
