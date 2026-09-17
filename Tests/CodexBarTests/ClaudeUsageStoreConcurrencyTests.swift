import Foundation
import Testing
@testable import CodexBarCore

/// WAL serializes commits; it does not stop a stale writer.
///
/// Two scans can read one transcript's state, both parse it, and both commit. Whichever acquires
/// the lock last wins on an unconditional upsert, even when it is writing older state — so a file
/// write carries the baseline it was parsed against and is rejected when that baseline moved.
@Suite(.serialized)
struct ClaudeUsageStoreConcurrencyTests {
    private static func file(
        path: String = "/roots/p/s.jsonl",
        size: Int64,
        parsedOffset: Int64,
        identity: String = "ino-1") -> ClaudeStoreSourceFile
    {
        ClaudeStoreSourceFile(
            path: path,
            fileIdentity: identity,
            size: size,
            mtimeMs: 1_700_000_000_000 + size,
            parsedOffset: parsedOffset,
            coverageSinceDay: "2026-09-17",
            coverageUntilDay: "2026-09-17",
            parserRevision: 1,
            tzIdentity: "Europe/Lisbon",
            complete: true)
    }

    private static func event(rowIndex: Int = 0, messageID: String, output: Int) -> ClaudeStoreUsageEvent {
        ClaudeStoreUsageEvent(
            rowIndex: rowIndex,
            timestampUnixMs: 1_789_000_000_000,
            day: "2026-09-17",
            backend: "firstParty",
            model: "claude-opus-5",
            rawModel: "claude-opus-5",
            sessionID: "s1",
            messageID: messageID,
            requestID: "r-\(messageID)",
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
            output: output,
            thinkingTokens: 0,
            webSearchRequests: 0,
            webFetchRequests: 0,
            ingestCostNanos: 0,
            ingestCostPriced: false)
    }

    /// The assertion the design review asked for: a writer holding an old baseline cannot win.
    @Test
    func `a stale baseline writer cannot regress the recorded file state`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)

        let first = Self.file(size: 100, parsedOffset: 100)
        #expect(await store.writeClaudeFile(
            first,
            events: [Self.event(messageID: "m1", output: 1)],
            mode: .replace,
            expecting: nil).isWritten)

        // B commits an append both writers were racing to add.
        let appended = Self.file(size: 200, parsedOffset: 200)
        #expect(await store.writeClaudeFile(
            appended,
            events: [
                Self.event(messageID: "m1", output: 1),
                Self.event(rowIndex: 1, messageID: "m2", output: 2),
            ],
            mode: .replace,
            expecting: first).isWritten)

        // A parsed the file at its first state and only now reaches the lock.
        let outcome = await store.writeClaudeFile(
            Self.file(size: 100, parsedOffset: 100),
            events: [Self.event(messageID: "m1", output: 1)],
            mode: .replace,
            expecting: first)

        #expect(outcome == .rejected(appended), "the rejection hands back what is actually stored")
        #expect(await store.readClaudeSourceFiles() == [appended])
        let events = await store.readReconciledClaudeEvents()
        #expect(Set(events.compactMap(\.messageID)) == ["m1", "m2"], "B's append survives")
    }

    /// A first write is only a first write if the row really is absent.
    @Test
    func `an insert expecting no row loses to whoever created it`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let created = Self.file(size: 100, parsedOffset: 100)

        #expect(await store.writeClaudeFile(created, events: [], mode: .replace, expecting: nil).isWritten)
        let outcome = await store.writeClaudeFile(
            Self.file(size: 50, parsedOffset: 50),
            events: [],
            mode: .replace,
            expecting: nil)

        #expect(outcome == .rejected(created))
    }

    /// Replacing a file's events is one transaction, so a rejected write changes nothing at all.
    @Test
    func `a rejected write leaves the stored events untouched`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let stored = Self.file(size: 100, parsedOffset: 100)
        #expect(await store.writeClaudeFile(
            stored,
            events: [Self.event(messageID: "m1", output: 1)],
            mode: .replace,
            expecting: nil).isWritten)

        let outcome = await store.writeClaudeFile(
            Self.file(size: 300, parsedOffset: 300),
            events: [],
            mode: .replace,
            expecting: Self.file(size: 999, parsedOffset: 999))

        #expect(!outcome.isWritten)
        #expect(await store.readReconciledClaudeEvents().count == 1)
    }

    /// A replaced identity is a different file at the same path, so its old rows must not linger.
    @Test
    func `replacing a files identity drops its previous events`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let original = Self.file(size: 100, parsedOffset: 100, identity: "ino-1")
        #expect(await store.writeClaudeFile(
            original,
            events: [Self.event(messageID: "m1", output: 1)],
            mode: .replace,
            expecting: nil).isWritten)

        #expect(await store.writeClaudeFile(
            Self.file(size: 40, parsedOffset: 40, identity: "ino-2"),
            events: [Self.event(messageID: "m9", output: 9)],
            mode: .replace,
            expecting: original).isWritten)

        let events = await store.readReconciledClaudeEvents()
        #expect(events.compactMap(\.messageID) == ["m9"])
    }
}
