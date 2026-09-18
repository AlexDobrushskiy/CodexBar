import Foundation

#if canImport(CSQLite3)
import CSQLite3
#else
import SQLite3
#endif

// MARK: - Claude usage store (schema v4)

extension CostUsageStore {
    /// Inserts or updates one tracked transcript and returns its row id.
    ///
    /// The sort key is derived here rather than by the caller so there is a single ordering
    /// authority for the cross-file tie-break; see `ClaudeUsageStorePathSortKey`.
    /// Inserts or updates one tracked transcript and returns its row id.
    ///
    /// Unconditional; `writeClaudeFile` is the entry point that guards against a stale writer.
    func upsertClaudeSourceFile(_ file: ClaudeStoreSourceFile) -> Int64? {
        self.withDatabase(default: nil) { database in
            try Self.upsertClaudeSourceFileRow(database, file: file)
            return try Self.claudeSourceFileID(database, path: file.path)
        }
    }

    /// The sort key is derived here rather than by the caller so there is a single ordering
    /// authority for the cross-file tie-break; see `ClaudeUsageStorePathSortKey`.
    private static func upsertClaudeSourceFileRow(
        _ database: OpaquePointer,
        file: ClaudeStoreSourceFile) throws
    {
        let statement = try Self.prepare(database, """
        INSERT INTO claude_source_files(
            path, path_sort_key, file_identity, size, mtime_ms, parsed_offset,
            coverage_since_day, coverage_until_day, parser_revision, tz_identity, complete,
            source_present)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(path) DO UPDATE SET
            path_sort_key = excluded.path_sort_key,
            file_identity = excluded.file_identity,
            size = excluded.size,
            mtime_ms = excluded.mtime_ms,
            parsed_offset = excluded.parsed_offset,
            coverage_since_day = excluded.coverage_since_day,
            coverage_until_day = excluded.coverage_until_day,
            parser_revision = excluded.parser_revision,
            tz_identity = excluded.tz_identity,
            complete = excluded.complete,
            source_present = excluded.source_present
        """)
        defer { sqlite3_finalize(statement) }
        Self.bind(file.path, to: statement, at: 1)
        Self.bind(Data(ClaudeUsageStorePathSortKey.make(file.path)), to: statement, at: 2)
        Self.bind(file.fileIdentity, to: statement, at: 3)
        Self.bind(file.size, to: statement, at: 4)
        Self.bind(file.mtimeMs, to: statement, at: 5)
        Self.bind(file.parsedOffset, to: statement, at: 6)
        Self.bind(file.coverageSinceDay, to: statement, at: 7)
        Self.bind(file.coverageUntilDay, to: statement, at: 8)
        Self.bind(Int64(file.parserRevision), to: statement, at: 9)
        Self.bind(file.tzIdentity, to: statement, at: 10)
        Self.bind(file.complete ? Int64(1) : Int64(0), to: statement, at: 11)
        Self.bind(file.sourcePresent ? Int64(1) : Int64(0), to: statement, at: 12)
        try Self.stepDone(statement, database: database)
    }

    /// Writes one transcript's state and its events together, only if the baseline still holds.
    ///
    /// WAL serializes commits but does not stop a stale writer: A parses old file state, B commits
    /// an append, then A acquires the lock and overwrites B. The write therefore carries the state
    /// it was parsed against and is rejected when the recorded state has moved, handing back what
    /// is actually stored so the caller can reload instead of guessing.
    ///
    /// `expecting: nil` asserts the file is not tracked yet, so two first writes cannot both win.
    /// File row and events move in one transaction, which is what makes `.replace` atomic: a
    /// rejected write must not leave a file with its events already deleted.
    func writeClaudeFile(
        _ file: ClaudeStoreSourceFile,
        events: [ClaudeStoreUsageEvent],
        mode: ClaudeStoreEventWriteMode,
        expecting baseline: ClaudeStoreSourceFile?) -> ClaudeStoreFileWrite
    {
        self.withDatabase(default: .rejected(nil)) { database in
            try Self.inTransaction(database) {
                let current = try Self.claudeSourceFile(database, path: file.path)
                guard Self.claudeBaselineHolds(current: current, baseline: baseline) else {
                    return ClaudeStoreFileWrite.rejected(current)
                }
                try Self.upsertClaudeSourceFileRow(database, file: file)
                guard let fileID = try Self.claudeSourceFileID(database, path: file.path) else {
                    throw StoreError.invalidData
                }
                if mode == .replace {
                    let delete = try Self.prepare(
                        database,
                        "DELETE FROM claude_usage_events WHERE file_id = ?")
                    defer { sqlite3_finalize(delete) }
                    Self.bind(fileID, to: delete, at: 1)
                    try Self.stepDone(delete, database: database)
                }
                for event in events {
                    try Self.upsertClaudeUsageEvent(database, fileID: fileID, event: event)
                }
                return .written(fileID)
            }
        }
    }

    /// The baseline is the mutable file state a parse was based on, never its derived columns.
    private static func claudeBaselineHolds(
        current: ClaudeStoreSourceFile?,
        baseline: ClaudeStoreSourceFile?) -> Bool
    {
        guard let baseline else { return current == nil }
        guard let current else { return false }
        return current.fileIdentity == baseline.fileIdentity
            && current.size == baseline.size
            && current.mtimeMs == baseline.mtimeMs
            && current.parsedOffset == baseline.parsedOffset
    }

    private static func claudeSourceFile(
        _ database: OpaquePointer,
        path: String) throws -> ClaudeStoreSourceFile?
    {
        let statement = try Self.prepare(database, """
        SELECT path, file_identity, size, mtime_ms, parsed_offset,
               coverage_since_day, coverage_until_day, parser_revision, tz_identity, complete,
               source_present
        FROM claude_source_files WHERE path = ?
        """)
        defer { sqlite3_finalize(statement) }
        Self.bind(path, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.claudeSourceFile(from: statement)
    }

    private static func claudeSourceFile(from statement: OpaquePointer) -> ClaudeStoreSourceFile {
        ClaudeStoreSourceFile(
            path: columnText(statement, at: 0) ?? "",
            fileIdentity: columnText(statement, at: 1),
            size: sqlite3_column_int64(statement, 2),
            mtimeMs: sqlite3_column_int64(statement, 3),
            parsedOffset: sqlite3_column_int64(statement, 4),
            coverageSinceDay: columnText(statement, at: 5),
            coverageUntilDay: columnText(statement, at: 6),
            parserRevision: Int(sqlite3_column_int64(statement, 7)),
            tzIdentity: columnText(statement, at: 8) ?? "",
            complete: sqlite3_column_int64(statement, 9) != 0)
    }

    func readClaudeSourceFiles() -> [ClaudeStoreSourceFile] {
        self.withDatabase(default: []) { database in
            let statement = try Self.prepare(database, """
            SELECT path, file_identity, size, mtime_ms, parsed_offset,
                   coverage_since_day, coverage_until_day, parser_revision, tz_identity, complete,
                   source_present
            FROM claude_source_files
            ORDER BY path_sort_key
            """)
            defer { sqlite3_finalize(statement) }
            var files: [ClaudeStoreSourceFile] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                files.append(ClaudeStoreSourceFile(
                    path: Self.columnText(statement, at: 0) ?? "",
                    fileIdentity: Self.columnText(statement, at: 1),
                    size: sqlite3_column_int64(statement, 2),
                    mtimeMs: sqlite3_column_int64(statement, 3),
                    parsedOffset: sqlite3_column_int64(statement, 4),
                    coverageSinceDay: Self.columnText(statement, at: 5),
                    coverageUntilDay: Self.columnText(statement, at: 6),
                    parserRevision: Int(sqlite3_column_int64(statement, 7)),
                    tzIdentity: Self.columnText(statement, at: 8) ?? "",
                    complete: sqlite3_column_int64(statement, 9) != 0,
                    sourcePresent: sqlite3_column_int64(statement, 10) != 0))
            }
            return files
        }
    }

    /// Half-open byte range covering every path under `root`.
    ///
    /// SQLite compares TEXT as UTF-8 bytes, and `/` is 0x2F, so the upper bound is the same prefix
    /// with `0` (0x30) in place of the trailing separator. A `LIKE` would have to escape `%` and `_`
    /// that a real directory name may contain.
    static func claudeRootPrefixBounds(_ root: String) -> (lower: String, upper: String) {
        let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
        return (lower: trimmed + "/", upper: trimmed + "0")
    }

    private static func claudeSourceFileID(_ database: OpaquePointer, path: String) throws -> Int64? {
        let statement = try Self.prepare(database, "SELECT id FROM claude_source_files WHERE path = ?")
        defer { sqlite3_finalize(statement) }
        Self.bind(path, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    /// Inserts events, letting a later streaming chunk replace the stored winner.
    ///
    /// The parser already collapses chunks sharing one `messageId:requestId` inside a file and
    /// keeps the last cumulative one, so an append of the same canonical identity must overwrite
    /// every payload column *and* `row_index` — last line wins. Rows missing either id have no
    /// canonical identity and are keyed only by `row_index`, so they never collapse together.
    func appendClaudeUsageEvents(fileID: Int64, events: [ClaudeStoreUsageEvent]) -> Bool {
        guard !events.isEmpty else { return true }
        return self.withDatabase(default: false) { database in
            for event in events {
                try Self.upsertClaudeUsageEvent(database, fileID: fileID, event: event)
            }
            return true
        }
    }

    /// Replaces every event for one file, for a full reparse or an identity change.
    ///
    /// Deletes before inserting so keyed rows that are no longer in the transcript cannot survive.
    func replaceClaudeUsageEvents(fileID: Int64, events: [ClaudeStoreUsageEvent]) -> Bool {
        self.withDatabase(default: false) { database in
            let delete = try Self.prepare(database, "DELETE FROM claude_usage_events WHERE file_id = ?")
            defer { sqlite3_finalize(delete) }
            Self.bind(fileID, to: delete, at: 1)
            try Self.stepDone(delete, database: database)
            for event in events {
                try Self.upsertClaudeUsageEvent(database, fileID: fileID, event: event)
            }
            return true
        }
    }

    func readClaudeUsageEvents(fileID: Int64) -> [ClaudeStoreUsageEvent] {
        self.withDatabase(default: []) { database in
            let statement = try Self.prepare(database, """
            SELECT row_index, ts_ms, day, backend, model, raw_model, session_id, message_id,
                   request_id, cwd, git_branch, path_role, is_sidechain, effort, service_tier,
                   input, cache_read, cache_create, cache_create_1h, output, thinking_tokens,
                   web_search_reqs, web_fetch_reqs, ingest_cost_nanos, ingest_cost_priced
            FROM claude_usage_events WHERE file_id = ? ORDER BY row_index
            """)
            defer { sqlite3_finalize(statement) }
            Self.bind(fileID, to: statement, at: 1)
            var events: [ClaudeStoreUsageEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                events.append(ClaudeStoreUsageEvent(
                    rowIndex: Int(sqlite3_column_int64(statement, 0)),
                    timestampUnixMs: sqlite3_column_type(statement, 1) == SQLITE_NULL
                        ? nil : sqlite3_column_int64(statement, 1),
                    day: Self.columnText(statement, at: 2) ?? "",
                    backend: Self.columnText(statement, at: 3) ?? "",
                    model: Self.columnText(statement, at: 4) ?? "",
                    rawModel: Self.columnText(statement, at: 5) ?? "",
                    sessionID: Self.columnText(statement, at: 6),
                    messageID: Self.columnText(statement, at: 7),
                    requestID: Self.columnText(statement, at: 8),
                    cwd: Self.columnText(statement, at: 9),
                    gitBranch: Self.columnText(statement, at: 10),
                    pathRole: Self.columnText(statement, at: 11) ?? "",
                    isSidechain: sqlite3_column_int64(statement, 12) != 0,
                    effort: Self.columnText(statement, at: 13),
                    serviceTier: Self.columnText(statement, at: 14),
                    input: Int(sqlite3_column_int64(statement, 15)),
                    cacheRead: Int(sqlite3_column_int64(statement, 16)),
                    cacheCreate: Int(sqlite3_column_int64(statement, 17)),
                    cacheCreate1h: Int(sqlite3_column_int64(statement, 18)),
                    output: Int(sqlite3_column_int64(statement, 19)),
                    thinkingTokens: Int(sqlite3_column_int64(statement, 20)),
                    webSearchRequests: Int(sqlite3_column_int64(statement, 21)),
                    webFetchRequests: Int(sqlite3_column_int64(statement, 22)),
                    ingestCostNanos: Int(sqlite3_column_int64(statement, 23)),
                    ingestCostPriced: sqlite3_column_int64(statement, 24) != 0))
            }
            return events
        }
    }

    /// Records that a transcript is no longer on disk, keeping the usage it already reported.
    func markClaudeSourceMissing(path: String) -> Bool {
        self.withDatabase(default: false) { database in
            let statement = try Self.prepare(
                database,
                "UPDATE claude_source_files SET source_present = 0 WHERE path = ?")
            defer { sqlite3_finalize(statement) }
            Self.bind(path, to: statement, at: 1)
            try Self.stepDone(statement, database: database)
            return true
        }
    }

    func deleteClaudeSourceFile(path: String) -> Bool {
        self.withDatabase(default: false) { database in
            let statement = try Self.prepare(database, "DELETE FROM claude_source_files WHERE path = ?")
            defer { sqlite3_finalize(statement) }
            Self.bind(path, to: statement, at: 1)
            try Self.stepDone(statement, database: database)
            return true
        }
    }

    private static func upsertClaudeUsageEvent(
        _ database: OpaquePointer,
        fileID: Int64,
        event: ClaudeStoreUsageEvent) throws
    {
        let statement = try Self.prepare(database, """
        INSERT INTO claude_usage_events(
            file_id, row_index, ts_ms, day, backend, model, raw_model, session_id, message_id,
            request_id, cwd, git_branch, path_role, is_sidechain, effort, service_tier,
            input, cache_read, cache_create, cache_create_1h, output, thinking_tokens,
            web_search_reqs, web_fetch_reqs, ingest_cost_nanos, ingest_cost_priced)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(file_id, backend, message_id, request_id)
        WHERE message_id IS NOT NULL AND request_id IS NOT NULL
        DO UPDATE SET
            row_index = excluded.row_index,
            ts_ms = excluded.ts_ms,
            day = excluded.day,
            model = excluded.model,
            raw_model = excluded.raw_model,
            session_id = excluded.session_id,
            cwd = excluded.cwd,
            git_branch = excluded.git_branch,
            path_role = excluded.path_role,
            is_sidechain = excluded.is_sidechain,
            effort = excluded.effort,
            service_tier = excluded.service_tier,
            input = excluded.input,
            cache_read = excluded.cache_read,
            cache_create = excluded.cache_create,
            cache_create_1h = excluded.cache_create_1h,
            output = excluded.output,
            thinking_tokens = excluded.thinking_tokens,
            web_search_reqs = excluded.web_search_reqs,
            web_fetch_reqs = excluded.web_fetch_reqs,
            ingest_cost_nanos = excluded.ingest_cost_nanos,
            ingest_cost_priced = excluded.ingest_cost_priced
        """)
        defer { sqlite3_finalize(statement) }
        Self.bind(fileID, to: statement, at: 1)
        Self.bind(Int64(event.rowIndex), to: statement, at: 2)
        if let ts = event.timestampUnixMs {
            Self.bind(ts, to: statement, at: 3)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        Self.bind(event.day, to: statement, at: 4)
        Self.bind(event.backend, to: statement, at: 5)
        Self.bind(event.model, to: statement, at: 6)
        Self.bind(event.rawModel, to: statement, at: 7)
        Self.bind(event.sessionID, to: statement, at: 8)
        Self.bind(event.messageID, to: statement, at: 9)
        Self.bind(event.requestID, to: statement, at: 10)
        Self.bind(event.cwd, to: statement, at: 11)
        Self.bind(event.gitBranch, to: statement, at: 12)
        Self.bind(event.pathRole, to: statement, at: 13)
        Self.bind(event.isSidechain ? Int64(1) : Int64(0), to: statement, at: 14)
        Self.bind(event.effort, to: statement, at: 15)
        Self.bind(event.serviceTier, to: statement, at: 16)
        Self.bind(Int64(event.input), to: statement, at: 17)
        Self.bind(Int64(event.cacheRead), to: statement, at: 18)
        Self.bind(Int64(event.cacheCreate), to: statement, at: 19)
        Self.bind(Int64(event.cacheCreate1h), to: statement, at: 20)
        Self.bind(Int64(event.output), to: statement, at: 21)
        Self.bind(Int64(event.thinkingTokens), to: statement, at: 22)
        Self.bind(Int64(event.webSearchRequests), to: statement, at: 23)
        Self.bind(Int64(event.webFetchRequests), to: statement, at: 24)
        Self.bind(Int64(event.ingestCostNanos), to: statement, at: 25)
        Self.bind(event.ingestCostPriced ? Int64(1) : Int64(0), to: statement, at: 26)
        try Self.stepDone(statement, database: database)
    }

    /// Every usage event after cross-file reconciliation.
    ///
    /// Ranking lives in `claude_reconciled_events` and mirrors `claudeRowWins`. It orders on
    /// `path_sort_key`, never on `path`: SQLite compares UTF-8 bytes while Swift's `String <` is
    /// canonical-equivalence aware, and APFS stores filenames decomposed, so the two invert on a
    /// non-ASCII path.
    func readReconciledClaudeEvents() -> [ClaudeStoreReconciledEvent] {
        self.withDatabase(default: []) { database in
            let statement = try Self.prepare(database, """
            SELECT source_path, row_index, ts_ms, day, backend, model, raw_model, session_id,
                   message_id, request_id, cwd, git_branch, path_role, is_sidechain, effort,
                   service_tier, input, cache_read, cache_create, cache_create_1h, output,
                   thinking_tokens, web_search_reqs, web_fetch_reqs, ingest_cost_nanos,
                   ingest_cost_priced
            FROM claude_reconciled_events
            ORDER BY day, source_path, row_index
            """)
            defer { sqlite3_finalize(statement) }
            var rows: [ClaudeStoreReconciledEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(ClaudeStoreReconciledEvent(
                    sourcePath: Self.columnText(statement, at: 0) ?? "",
                    event: ClaudeStoreUsageEvent(
                        rowIndex: Int(sqlite3_column_int64(statement, 1)),
                        timestampUnixMs: sqlite3_column_type(statement, 2) == SQLITE_NULL
                            ? nil : sqlite3_column_int64(statement, 2),
                        day: Self.columnText(statement, at: 3) ?? "",
                        backend: Self.columnText(statement, at: 4) ?? "",
                        model: Self.columnText(statement, at: 5) ?? "",
                        rawModel: Self.columnText(statement, at: 6) ?? "",
                        sessionID: Self.columnText(statement, at: 7),
                        messageID: Self.columnText(statement, at: 8),
                        requestID: Self.columnText(statement, at: 9),
                        cwd: Self.columnText(statement, at: 10),
                        gitBranch: Self.columnText(statement, at: 11),
                        pathRole: Self.columnText(statement, at: 12) ?? "",
                        isSidechain: sqlite3_column_int64(statement, 13) != 0,
                        effort: Self.columnText(statement, at: 14),
                        serviceTier: Self.columnText(statement, at: 15),
                        input: Int(sqlite3_column_int64(statement, 16)),
                        cacheRead: Int(sqlite3_column_int64(statement, 17)),
                        cacheCreate: Int(sqlite3_column_int64(statement, 18)),
                        cacheCreate1h: Int(sqlite3_column_int64(statement, 19)),
                        output: Int(sqlite3_column_int64(statement, 20)),
                        thinkingTokens: Int(sqlite3_column_int64(statement, 21)),
                        webSearchRequests: Int(sqlite3_column_int64(statement, 22)),
                        webFetchRequests: Int(sqlite3_column_int64(statement, 23)),
                        ingestCostNanos: Int(sqlite3_column_int64(statement, 24)),
                        ingestCostPriced: sqlite3_column_int64(statement, 25) != 0)))
            }
            return rows
        }
    }

    /// Priced reconciled rows for one ledger's report: a day window, backends, roots.
    ///
    /// This is the read path the ledger split runs on. Scoping here rather than re-scanning with a
    /// row filter is what lets one unfiltered scan serve Claude, Vertex and Bedrock at once.
    /// `backends` holds `ClaudeLogBackend.rawValue`s; `nil` means every backend. `roots` keeps a
    /// profile-scoped ledger from reporting transcripts its own scan never walked — the store is
    /// global, a ledger is not.
    func readClaudeReportRows(
        backends: Set<String>?,
        roots: [String],
        sinceDay: String,
        untilDay: String) -> [ClaudeStoreReportRow]
    {
        // A ledger with no roots covers nothing. Falling through would report the whole store,
        // which is every profile's usage.
        guard !roots.isEmpty else { return [] }
        return self.withDatabase(default: []) { database in
            let sortedBackends = backends.map { $0.sorted() }
            let backendClause = sortedBackends.map {
                " AND backend IN (\(Array(repeating: "?", count: $0.count).joined(separator: ",")))"
            } ?? ""
            let rootBounds = roots.map { Self.claudeRootPrefixBounds($0) }
            let rootClause = rootBounds.isEmpty
                ? ""
                : " AND (" + rootBounds
                .map { _ in "(source_path >= ? AND source_path < ?)" }
                .joined(separator: " OR ") + ")"
            let statement = try Self.prepare(database, """
            SELECT day, model, input, cache_read, cache_create, output, cost_usd
            FROM claude_event_costs
            WHERE day >= ? AND day <= ?\(backendClause)\(rootClause)
            """)
            defer { sqlite3_finalize(statement) }
            Self.bind(sinceDay, to: statement, at: 1)
            Self.bind(untilDay, to: statement, at: 2)
            var index = Int32(3)
            for backend in sortedBackends ?? [] {
                Self.bind(backend, to: statement, at: index)
                index += 1
            }
            for bounds in rootBounds {
                Self.bind(bounds.lower, to: statement, at: index)
                Self.bind(bounds.upper, to: statement, at: index + 1)
                index += 2
            }
            var rows: [ClaudeStoreReportRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(ClaudeStoreReportRow(
                    day: Self.columnText(statement, at: 0) ?? "",
                    model: Self.columnText(statement, at: 1) ?? "",
                    input: Int(sqlite3_column_int64(statement, 2)),
                    cacheRead: Int(sqlite3_column_int64(statement, 3)),
                    cacheCreate: Int(sqlite3_column_int64(statement, 4)),
                    output: Int(sqlite3_column_int64(statement, 5)),
                    costUSD: sqlite3_column_type(statement, 6) == SQLITE_NULL
                        ? nil : sqlite3_column_double(statement, 6)))
            }
            return rows
        }
    }

    /// Total tokens per working directory per backend, over reconciled events.
    ///
    /// The question the day×model JSON artifact structurally could not answer.
    func readClaudeTokenTotalsByProject() -> [String: [String: Int]] {
        self.withDatabase(default: [:]) { database in
            let statement = try Self.prepare(database, """
            SELECT cwd, backend,
                   SUM(input + cache_read + cache_create + output) AS tokens
            FROM claude_reconciled_events
            WHERE cwd IS NOT NULL
            GROUP BY cwd, backend
            """)
            defer { sqlite3_finalize(statement) }
            var totals: [String: [String: Int]] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let cwd = Self.columnText(statement, at: 0),
                      let backend = Self.columnText(statement, at: 1)
                else { continue }
                totals[cwd, default: [:]][backend] = Int(sqlite3_column_int64(statement, 2))
            }
            return totals
        }
    }
}

// MARK: - Synchronous bridge for the scanner

extension CostUsageStore {
    /// Mirrors one scanned transcript and its rows into the store, if its baseline still holds.
    ///
    /// The Claude scan is synchronous, so it reaches the store through the shared executor the way
    /// the Codex scan does. Events are *replaced* rather than appended because `rows` is already the
    /// merged full set for the file, so a shrinking or rewritten transcript cannot leave stale rows.
    nonisolated func syncWriteClaudeFile(
        file: ClaudeStoreSourceFile,
        events: [ClaudeStoreUsageEvent],
        expecting baseline: ClaudeStoreSourceFile?) -> ClaudeStoreFileWrite
    {
        self.syncWithStoreIsolation { store in
            store.writeClaudeFile(file, events: events, mode: .replace, expecting: baseline)
        }
    }

    nonisolated func syncReadClaudeSourceFiles() -> [ClaudeStoreSourceFile] {
        self.syncWithStoreIsolation { $0.readClaudeSourceFiles() }
    }

    nonisolated func syncReadClaudeReportRows(
        backends: Set<String>?,
        roots: [String],
        sinceDay: String,
        untilDay: String) -> [ClaudeStoreReportRow]
    {
        self.syncWithStoreIsolation {
            $0.readClaudeReportRows(
                backends: backends,
                roots: roots,
                sinceDay: sinceDay,
                untilDay: untilDay)
        }
    }

    nonisolated func syncRetainClaudeDayWindow(
        sinceDay: String,
        untilDay: String,
        roots: [String]) -> CostUsageStoreClaudeRetentionResult
    {
        self.syncWithStoreIsolation {
            $0.retainClaudeDayWindow(sinceDay: sinceDay, untilDay: untilDay, roots: roots)
        }
    }

    nonisolated func syncMarkClaudeSourceMissing(path: String) -> Bool {
        self.syncWithStoreIsolation { $0.markClaudeSourceMissing(path: path) }
    }

    nonisolated func syncDeleteClaudeSourceFile(path: String) -> Bool {
        self.syncWithStoreIsolation { $0.deleteClaudeSourceFile(path: path) }
    }
}
