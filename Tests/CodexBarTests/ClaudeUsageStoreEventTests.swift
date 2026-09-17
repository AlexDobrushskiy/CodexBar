import Foundation
import Testing
@testable import CodexBarCore

/// Storage-level contracts for `claude_usage_events`.
///
/// The parser collapses streaming chunks sharing one `messageId:requestId` inside a file and keeps
/// the last cumulative chunk, so an appended chunk must *replace* the stored winner rather than
/// become a second counted event. Rows without both ids carry no canonical identity and must never
/// collapse into one another.
@Suite(.serialized)
struct ClaudeUsageStoreEventTests {
    private static func store(_ env: CostUsageTestEnvironment) -> CostUsageStore {
        CostUsageStore(cacheRoot: env.cacheRoot)
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

    private static func event(
        rowIndex: Int,
        messageID: String?,
        requestID: String?,
        backend: String = "bedrock",
        output: Int) -> ClaudeStoreUsageEvent
    {
        ClaudeStoreUsageEvent(
            rowIndex: rowIndex,
            timestampUnixMs: 1_700_000_000_000,
            day: "2026-09-17",
            backend: backend,
            model: "claude-opus-5",
            rawModel: "claude-opus-5",
            sessionID: "s1",
            messageID: messageID,
            requestID: requestID,
            cwd: "/Users/alex/PycharmProjects/hearst",
            gitBranch: "main",
            pathRole: "main",
            isSidechain: false,
            effort: "xhigh",
            serviceTier: "standard",
            input: 1,
            cacheRead: 2,
            cacheCreate: 3,
            cacheCreate1h: 0,
            output: output,
            thinkingTokens: 4,
            webSearchRequests: 0,
            webFetchRequests: 0,
            ingestCostNanos: 5,
            ingestCostPriced: true)
    }

    @Test
    func `appending a later streaming chunk replaces the stored winner`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = Self.store(env)
        let fileID = try #require(await store.upsertClaudeSourceFile(Self.sourceFile(path: "/p/s.jsonl")))

        #expect(await store.appendClaudeUsageEvents(
            fileID: fileID,
            events: [Self.event(rowIndex: 4, messageID: "msg_bdrk_a", requestID: "req_a", output: 10)]))
        // The cumulative chunk arrives later in the file with the full output count.
        #expect(await store.appendClaudeUsageEvents(
            fileID: fileID,
            events: [Self.event(rowIndex: 9, messageID: "msg_bdrk_a", requestID: "req_a", output: 99)]))

        let stored = await store.readClaudeUsageEvents(fileID: fileID)
        #expect(stored.count == 1)
        #expect(stored.first?.output == 99)
        #expect(stored.first?.rowIndex == 9, "last line wins, so row_index advances too")
    }

    @Test
    func `rows without canonical ids do not collapse into one another`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = Self.store(env)
        let fileID = try #require(await store.upsertClaudeSourceFile(Self.sourceFile(path: "/p/s.jsonl")))

        #expect(await store.appendClaudeUsageEvents(fileID: fileID, events: [
            Self.event(rowIndex: 1, messageID: nil, requestID: nil, output: 10),
            Self.event(rowIndex: 2, messageID: nil, requestID: nil, output: 20),
        ]))

        let stored = await store.readClaudeUsageEvents(fileID: fileID)
        #expect(stored.count == 2)
        #expect(stored.map(\.output).sorted() == [10, 20])
    }

    /// Canonical identity is partitioned by backend, so the same ids reached through two backends
    /// are two events and the storage layer must not collapse them before the view separates them.
    @Test
    func `same ids on different backends are distinct events`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = Self.store(env)
        let fileID = try #require(await store.upsertClaudeSourceFile(Self.sourceFile(path: "/p/s.jsonl")))

        #expect(await store.appendClaudeUsageEvents(fileID: fileID, events: [
            Self.event(rowIndex: 1, messageID: "msg_a", requestID: "req_a", backend: "firstParty", output: 10),
            Self.event(rowIndex: 2, messageID: "msg_a", requestID: "req_a", backend: "bedrock", output: 20),
        ]))

        #expect(await store.readClaudeUsageEvents(fileID: fileID).count == 2)
    }

    @Test
    func `deleting a source file removes its events`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = Self.store(env)
        let fileID = try #require(await store.upsertClaudeSourceFile(Self.sourceFile(path: "/p/s.jsonl")))
        #expect(await store.appendClaudeUsageEvents(
            fileID: fileID,
            events: [Self.event(rowIndex: 1, messageID: "msg_a", requestID: "req_a", output: 10)]))

        #expect(await store.deleteClaudeSourceFile(path: "/p/s.jsonl"))

        #expect(await store.readClaudeUsageEvents(fileID: fileID).isEmpty)
        #expect(await store.readClaudeSourceFiles().isEmpty)
    }

    /// A full reparse must not leave keyed rows that no longer exist in the transcript.
    @Test
    func `replacing a file's events drops rows no longer present`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = Self.store(env)
        let fileID = try #require(await store.upsertClaudeSourceFile(Self.sourceFile(path: "/p/s.jsonl")))
        #expect(await store.appendClaudeUsageEvents(fileID: fileID, events: [
            Self.event(rowIndex: 1, messageID: "msg_a", requestID: "req_a", output: 10),
            Self.event(rowIndex: 2, messageID: "msg_b", requestID: "req_b", output: 20),
        ]))

        #expect(await store.replaceClaudeUsageEvents(
            fileID: fileID,
            events: [Self.event(rowIndex: 1, messageID: "msg_a", requestID: "req_a", output: 10)]))

        let stored = await store.readClaudeUsageEvents(fileID: fileID)
        #expect(stored.map(\.messageID) == ["msg_a"])
    }
}
