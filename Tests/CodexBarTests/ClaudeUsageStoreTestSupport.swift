import Foundation
@testable import CodexBarCore

/// Reading what a Claude scan left behind, now that the store is the scan state.
///
/// These replaced `CostUsageClaudeCacheIO.load(...)` in tests written against the JSON artifact.
/// Asserting on the store rather than on a cache file is also closer to what the tests mean:
/// the question was always "did the scan keep this", not "is it in that file".
extension CostUsageTestEnvironment {
    var claudeStore: CostUsageStore {
        CostUsageStore(cacheRoot: self.cacheRoot)
    }

    /// Every stored event, after cross-file reconciliation, in a stable order.
    func storedClaudeEvents() async -> [ClaudeStoreUsageEvent] {
        await self.claudeStore.readReconciledClaudeEvents()
            .sorted { lhs, rhs in
                if lhs.sourcePath != rhs.sourcePath { return lhs.sourcePath < rhs.sourcePath }
                return lhs.event.rowIndex < rhs.event.rowIndex
            }
            .map(\.event)
    }

    func storedClaudeFiles() async -> [ClaudeStoreSourceFile] {
        await self.claudeStore.readClaudeSourceFiles()
    }

    /// Tokens summed per day and model — the shape the artifact's `days` dictionary carried.
    func storedClaudeDayTotals() async -> [String: [String: Int]] {
        var totals: [String: [String: Int]] = [:]
        for event in await self.storedClaudeEvents() {
            let tokens = event.input + event.cacheRead + event.cacheCreate + event.output
            totals[event.day, default: [:]][event.model, default: 0] += tokens
        }
        return totals
    }
}

/// The fields a parsed row and a stored event both carry, so one can be asserted against the other.
///
/// Neither type is a subset of the other — the row keeps parser state, the event keeps storage
/// ordinals — and comparing whole values would assert on the difference rather than the content.
struct ClaudeRowFacts: Equatable {
    var day: String
    var model: String
    var rawModel: String
    var backend: String
    var sessionID: String?
    var messageID: String?
    var requestID: String?
    var cwd: String?
    var gitBranch: String?
    var input: Int
    var cacheRead: Int
    var cacheCreate: Int
    var cacheCreate1h: Int
    var output: Int

    init(_ row: CostUsageScanner.ClaudeUsageRow) {
        self.day = row.dayKey
        self.model = row.model
        self.rawModel = row.rawModel ?? row.model
        self.backend = (row.backend ?? .firstParty).rawValue
        self.sessionID = row.sessionId
        self.messageID = row.messageId
        self.requestID = row.requestId
        self.cwd = row.cwd
        self.gitBranch = row.gitBranch
        self.input = row.input
        self.cacheRead = row.cacheRead
        self.cacheCreate = row.cacheCreate
        self.cacheCreate1h = row.cacheCreate1h ?? 0
        self.output = row.output
    }

    init(_ event: ClaudeStoreUsageEvent) {
        self.day = event.day
        self.model = event.model
        self.rawModel = event.rawModel
        self.backend = event.backend
        self.sessionID = event.sessionID
        self.messageID = event.messageID
        self.requestID = event.requestID
        self.cwd = event.cwd
        self.gitBranch = event.gitBranch
        self.input = event.input
        self.cacheRead = event.cacheRead
        self.cacheCreate = event.cacheCreate
        self.cacheCreate1h = event.cacheCreate1h
        self.output = event.output
    }
}

extension [CostUsageScanner.ClaudeUsageRow] {
    var facts: [ClaudeRowFacts] {
        self.map(ClaudeRowFacts.init).sorted { "\($0)" < "\($1)" }
    }
}

extension [ClaudeStoreUsageEvent] {
    var facts: [ClaudeRowFacts] {
        self.map(ClaudeRowFacts.init).sorted { "\($0)" < "\($1)" }
    }
}
