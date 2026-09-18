import Foundation

struct CostUsageStoreTotals: Codable, Equatable, Sendable {
    var input: Int64
    var cached: Int64
    var output: Int64
    var reasoning: Int64?

    static let zero = Self(input: 0, cached: 0, output: 0, reasoning: nil)
}

struct CostUsageStoreValidationAnchor: Codable, Equatable, Sendable {
    var indexedBytes: Int64
    var windowStart: Int64
    var sha256: String
}

struct CostUsageStoreScanState: Codable, Equatable, Sendable {
    var targetSize: Int64?
    var isComplete: Bool
    var resumePayload: Data?
    var tokenTimestampsMonotonic: Bool?
    var nextUsageRowIndex: Int?
    var lastModel: String?
    var lastTurnID: String?
    var fileIdentity: String?
    var detailsPayload: Data?
}

struct CostUsageStoreFile: Codable, Equatable, Sendable {
    var path: String
    var inode: Int64?
    var mtimeUnixMs: Int64
    var size: Int64
    var parsedBytes: Int64?
    var anchor: CostUsageStoreValidationAnchor?
    var scanState: CostUsageStoreScanState
    var sessionID: String?
    var coverageSinceDay: String?
    var coverageUntilDay: String?
    var updatedAtUnixMs: Int64
}

struct CostUsageStoreTokenSnapshot: Codable, Equatable, Sendable {
    var path: String
    var eventIndex: Int
    var timestamp: String
    var timestampUnixMs: Int64?
    var day: String?
    var last: CostUsageStoreTotals?
    var total: CostUsageStoreTotals?
    var endOffset: Int64?
}

struct CostUsageStoreUsageRow: Codable, Equatable, Sendable {
    var path: String
    var rowIndex: Int
    var payload: Data
}

struct CostUsageStoreDayAggregate: Codable, Equatable, Sendable {
    var day: String
    var model: String
    var inputTokens: Int64
    var cachedTokens: Int64
    var outputTokens: Int64
    var reasoningTokens: Int64
    var requestCount: Int64
    var authoritativeCostNanos: Int64
    var standardInputTokens: Int64
    var standardCachedTokens: Int64
    var standardOutputTokens: Int64
    var priorityInputTokens: Int64
    var priorityCachedTokens: Int64
    var priorityOutputTokens: Int64
    var standardTokens: Int64
    var priorityTokens: Int64

    static func zero(day: String, model: String) -> Self {
        Self(
            day: day,
            model: model,
            inputTokens: 0,
            cachedTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            requestCount: 0,
            authoritativeCostNanos: 0,
            standardInputTokens: 0,
            standardCachedTokens: 0,
            standardOutputTokens: 0,
            priorityInputTokens: 0,
            priorityCachedTokens: 0,
            priorityOutputTokens: 0,
            standardTokens: 0,
            priorityTokens: 0)
    }
}

struct CostUsageStoreFileDayAggregate: Codable, Equatable, Sendable {
    var path: String
    var aggregate: CostUsageStoreDayAggregate
}

struct CostUsageStoreForkLineage: Codable, Equatable, Sendable {
    var path: String
    var sessionID: String?
    var forkedFromID: String?
    var forkTimestamp: String?
    var dependencyKey: String?
    var subagentState: Data?
    var accountingState: Data?
}

enum CostUsageStoreBufferedLineKind: String, Codable, CaseIterable, Sendable {
    case pricingEvidence
    case subagent
    case unresolvedFork
    case deferredReplay
}

struct CostUsageStoreBufferedLine: Codable, Equatable, Sendable {
    var path: String
    var kind: CostUsageStoreBufferedLineKind
    var lineIndex: Int
    var ordinal: Int?
    var endOffset: Int64?
    var payload: Data
}

struct CostUsageStoreDiscoveryState: Codable, Equatable, Sendable {
    var roots: [String]
    var generation: String?
    var directoryPaths: [String]
    var nextDirectoryIndex: Int
    var filePaths: [String]
    var nextFileIndex: Int
    var filePathBySessionID: [String: String]
    var missingSessionIDs: [String]
    var pendingSessionIDs: [String]
    var validationDirectoryIndex: Int
    var isComplete: Bool
    var payload: Data?
}

struct CostUsageStoreLookbackState: Codable, Equatable, Sendable {
    var scanSinceDay: String
    var rootPaths: [String]
    var nextDayByRoot: [String: String]
    var nextDirectoryOffsetByRoot: [String: Int64]?
    var completedRootPaths: [String]
    var pendingFilePaths: [String]
    var legacyRecursivePendingRootPaths: [String]
    var currentWindowNextDayKeyByRoot: [String: String]?
    var currentWindowDirectoryOffsetByRoot: [String: Int64]?
    var completedCurrentWindowRootPaths: [String]?
    var currentWindowFlatDirectoryOffsetByRoot: [String: Int64]?
    var completedCurrentWindowFlatRootPaths: [String]?
    var cacheWideMigrationQueueActive: Bool?
}

struct CostUsageStoreAccumulator: Codable, Equatable, Sendable {
    var path: String
    var eventCount: Int
    var nextUsageRowIndex: Int?
    var countedTotals: CostUsageStoreTotals?
    var rawTotalsBaseline: CostUsageStoreTotals?
    var rawTotalsWatermark: CostUsageStoreTotals?
    var sawDivergentTotals: Bool
    var sawInterleavedTotals: Bool
    var seenRawTotals: [CostUsageStoreTotals]
    var updatedAtUnixMs: Int64
}

struct CostUsageStoreMetadata: Codable, Equatable, Sendable {
    var lastScanUnixMs: Int64
    var scanSinceDay: String?
    var scanUntilDay: String?
    var timeZoneIdentifier: String?
    var pricingKey: String?
    var priorityMetadataKey: String?
    var catchUpPending: Bool
    var processedBytes: Int64?
    var totalBytes: Int64?
    var completedFiles: Int?
    var totalFiles: Int?
    var scanInventoryPaths: [String]?
    var rootMtimes: [String: Int64]?
    var previousReportPayload: Data?
    var priorityTurnStatePayload: Data?
    var projectMetadataVersion: Int?

    static let empty = Self(
        lastScanUnixMs: 0,
        scanSinceDay: nil,
        scanUntilDay: nil,
        timeZoneIdentifier: nil,
        pricingKey: nil,
        priorityMetadataKey: nil,
        catchUpPending: false,
        processedBytes: nil,
        totalBytes: nil,
        completedFiles: nil,
        totalFiles: nil,
        scanInventoryPaths: nil,
        rootMtimes: nil,
        previousReportPayload: nil,
        priorityTurnStatePayload: nil,
        projectMetadataVersion: nil)
}

struct CostUsageStoreReport: Equatable, Sendable {
    var metadata: CostUsageStoreMetadata
    var aggregates: [CostUsageStoreDayAggregate]
}

struct CostUsageStoreSnapshot: Equatable, Sendable {
    var metadata: CostUsageStoreMetadata
    var files: [CostUsageStoreFile]
    var tokenSnapshots: [CostUsageStoreTokenSnapshot]
    var usageRows: [CostUsageStoreUsageRow] = []
    var fileDayAggregates: [CostUsageStoreFileDayAggregate]
    var dayAggregates: [CostUsageStoreDayAggregate]
    var forkLineage: [CostUsageStoreForkLineage]
    var bufferedLines: [CostUsageStoreBufferedLine]
    var discoveryState: CostUsageStoreDiscoveryState?
    var lookbackState: CostUsageStoreLookbackState?
    var accumulators: [CostUsageStoreAccumulator]
}

struct CostUsageStoreRetentionResult: Equatable, Sendable {
    var deletedFiles: Int
    var deletedTokenSnapshots: Int
    var deletedFileDayAggregates: Int
    var deletedDayAggregates: Int
    /// Claude keeps its own file namespace, so it is pruned alongside rather than by cascade.
    var claude = CostUsageStoreClaudeRetentionResult()
}

/// What a day-window prune removed from the Claude tables.
struct CostUsageStoreClaudeRetentionResult: Equatable, Sendable {
    var deletedEvents = 0
    var deletedSourceFiles = 0
}

struct CostUsageStoreBudgetResult: Equatable, Sendable {
    var deletedRows: Int
    var rowCount: Int
    var fileBytes: Int64
    var catchUpRequired: Bool = false
}

struct CostUsageStoreConfiguration: Equatable, Sendable {
    var journalMode: String
    var busyTimeoutMilliseconds: Int
    var foreignKeysEnabled: Bool
    var autoVacuumMode: Int
    var userVersion: Int
}

// MARK: - Claude usage store (schema v4)

/// One Claude transcript file tracked by the store.
///
/// Claude keeps its own file namespace rather than reusing `files`: every dependent of `files`
/// cascades on delete, and `retainDayWindow` prunes it by Codex coverage and fork rules, so Claude
/// events hung off that table would be deleted by Codex retention.
struct ClaudeStoreSourceFile: Codable, Equatable, Sendable {
    var path: String
    /// Inode or equivalent; a change means the path now points at a different file.
    var fileIdentity: String?
    var size: Int64
    var mtimeMs: Int64
    var parsedOffset: Int64
    var coverageSinceDay: String?
    var coverageUntilDay: String?
    var parserRevision: Int
    /// Calendar identity the `day` column was bucketed under; `day` is not timeless.
    var tzIdentity: String
    var complete: Bool
    /// Whether the transcript is still on disk. A file that has gone keeps its events — the store
    /// is a usage record, not a mirror — and is removed only when the day window prunes them.
    var sourcePresent = true
}

/// One reconciled Claude usage row.
///
/// Within-file streaming chunks are already collapsed by the parser, so this is the per-file
/// winner. Cross-file parent/subagent candidates all persist; the winner is chosen by the
/// reconciliation view so that deleting a winner reveals the loser.
struct ClaudeStoreUsageEvent: Codable, Equatable, Sendable {
    var rowIndex: Int
    var timestampUnixMs: Int64?
    var day: String
    var backend: String
    var model: String
    /// Model exactly as written in the transcript, so alias or pricing changes need no reparse.
    var rawModel: String
    var sessionID: String?
    var messageID: String?
    var requestID: String?
    var cwd: String?
    var gitBranch: String?
    var pathRole: String
    var isSidechain: Bool
    var effort: String?
    var serviceTier: String?
    var input: Int
    var cacheRead: Int
    var cacheCreate: Int
    var cacheCreate1h: Int
    var output: Int
    var thinkingTokens: Int
    var webSearchRequests: Int
    var webFetchRequests: Int
    /// Cost priced at ingest; the pricing view prefers the current catalog and falls back to this.
    var ingestCostNanos: Int
    var ingestCostPriced: Bool
}

/// One Claude usage event after cross-file reconciliation, carrying the transcript it won from.
struct ClaudeStoreReconciledEvent: Codable, Equatable, Sendable {
    var sourcePath: String
    var event: ClaudeStoreUsageEvent
}

extension ClaudeStoreReconciledEvent {
    var messageID: String? {
        self.event.messageID
    }

    var output: Int {
        self.event.output
    }

    var pathRole: String {
        self.event.pathRole
    }

    var isSidechain: Bool {
        self.event.isSidechain
    }

    var day: String {
        self.event.day
    }

    var backend: String {
        self.event.backend
    }

    var model: String {
        self.event.model
    }
}

/// The columns a Claude ledger report needs, read straight out of the reconciliation view.
///
/// Deliberately narrower than `ClaudeStoreUsageEvent`: a 30-day window is tens of thousands of
/// rows, and the report only reprices and buckets them.
struct ClaudeStoreReportRow: Equatable, Sendable {
    var day: String
    var model: String
    var input: Int
    var cacheRead: Int
    var cacheCreate: Int
    var output: Int
    /// Already priced — by `claude_event_costs` for stored rows, by the resolver otherwise.
    /// `nil` means no catalog and no ingest price, which makes its whole day×model bucket unpriced.
    var costUSD: Double?
}

/// One model's rates for one backend over one validity window.
///
/// Rates are per token, matching the Swift cost formula exactly. Windows are half-open
/// `[validFromMs, validToMs)` so at most one row can join an event; overlapping windows would
/// multiply rows through `claude_event_costs`.
struct ClaudeStoreModelPrice: Equatable, Sendable {
    /// The normalized model, matching `claude_usage_events.model`; see `claudePricingSchemaSQL`.
    var model: String
    var backend: String
    var validFromMs: Int64
    var validToMs: Int64?
    var inputPerToken: Double
    var cacheReadPerToken: Double
    var cacheWritePerToken: Double
    var outputPerToken: Double
    var longContextThreshold: Int?
    var longContextInputPerToken: Double?
    var longContextCacheReadPerToken: Double?
    var longContextCacheWritePerToken: Double?
    var longContextOutputPerToken: Double?
}

/// One `(model, backend)` pair, the grain the Claude price catalog is keyed at.
struct ClaudeStoreModelKey: Hashable, Sendable {
    var model: String
    var backend: String
}

/// How a file write treats the events already stored for that file.
enum ClaudeStoreEventWriteMode: Sendable {
    /// A full reparse or an identity replacement: the file's events are deleted first, in the same
    /// transaction, so rows no longer in the transcript cannot survive.
    case replace
    /// An incremental append: keyed winners upsert and new unkeyed ordinals insert.
    case append
}

/// The result of a compare-and-set write of one transcript's state.
enum ClaudeStoreFileWrite: Equatable, Sendable {
    case written(Int64)
    /// The stored baseline moved; carries what is actually recorded so the caller can reload.
    case rejected(ClaudeStoreSourceFile?)

    var isWritten: Bool {
        if case .written = self { return true }
        return false
    }

    var fileID: Int64? {
        if case let .written(id) = self { return id }
        return nil
    }
}

/// One Claude ledger's scan state: the window it has covered and when it last ran.
///
/// Replaces the `scanSinceKey` / `scanUntilKey` / `lastScanUnixMs` the JSON artifact used to carry.
struct ClaudeStoreLedgerState: Equatable, Sendable {
    var rootsFingerprint: String
    var scanSinceDay: String
    var scanUntilDay: String
    var lastScanMs: Int64
    /// Advances on every write, so a report memo can tell whether the store moved under it.
    var generation: Int64
}
