import Foundation

extension CostUsageScanner {
    // MARK: - Claude

    private struct ClaudeTokens {
        let input: Int
        let cacheRead: Int
        let cacheCreate: Int
        let cacheCreate1h: Int
        let output: Int
        let costNanos: Int
        let costPriced: Bool
    }

    private struct ClaudeDayModelKey: Hashable {
        let day: String
        let model: String
    }

    /// One day×model bucket while a report is being built.
    private struct ClaudeDayModelTotals {
        var input = 0
        var cacheRead = 0
        var cacheCreate = 0
        var output = 0
        var cost: Double = 0
        /// At least one row in the bucket could be priced neither now nor at ingest, so the
        /// bucket's cost is a partial sum and must not be shown as the bucket's cost.
        var unresolved = false

        var totalTokens: Int {
            self.input + self.cacheRead + self.cacheCreate + self.output
        }
    }

    static func defaultClaudeProjectsRoots(
        options: Options,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        workingDirectory: URL? = nil) -> [URL]
    {
        if let override = options.claudeProjectsRoots {
            return override
        }

        var roots: [URL] = []

        if let configuredRoot = environment[ClaudeConfigPaths.configDirectoryEnvironmentKey],
           !configuredRoot.isEmpty
        {
            let root = ClaudeConfigPaths.configRoot(
                environment: environment,
                workingDirectory: workingDirectory)
            roots.append(root.appendingPathComponent("projects", isDirectory: true))
        } else {
            var pathEnvironment = environment
            if pathEnvironment["HOME"]?.isEmpty ?? true {
                pathEnvironment["HOME"] = homeDirectory.path
            }
            let ownerHome = ClaudeConfigPaths.homeDirectory(
                environment: pathEnvironment,
                workingDirectory: workingDirectory)
            let configRoot = ClaudeConfigPaths.configRoot(
                environment: pathEnvironment,
                workingDirectory: workingDirectory)
            roots.append(ownerHome.appendingPathComponent(".config/claude/projects", isDirectory: true))
            roots.append(configRoot.appendingPathComponent("projects", isDirectory: true))
            roots.append(contentsOf: ClaudeDesktopProjectsLocator.roots(
                homeDirectory: ownerHome,
                fileManager: fileManager))
        }

        return self.deduplicatedClaudeProjectRoots(roots)
    }

    private static func deduplicatedClaudeProjectRoots(_ roots: [URL]) -> [URL] {
        var seen: Set<String> = []
        var out: [URL] = []
        for root in roots {
            let standardized = root.standardizedFileURL
            let path = standardized.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            out.append(standardized)
        }
        return out
    }

    static func parseClaudeFile(
        fileURL: URL,
        range: CostUsageDayRange,
        providerFilter: ClaudeLogProviderFilter,
        startOffset: Int64 = 0,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> ClaudeParseResult
    {
        let pricingResolver = modelsDevCatalog.map { CostUsagePricing.ClaudeResolver(catalog: $0) }
            ?? CostUsagePricing.ClaudeResolver(now: Date(), cacheRoot: modelsDevCacheRoot)
        return (
            try? self.parseClaudeFileCancellable(
                fileURL: fileURL,
                range: range,
                providerFilter: providerFilter,
                startOffset: startOffset,
                pricingResolver: pricingResolver,
                checkCancellation: nil)) ?? ClaudeParseResult(rows: [], parsedBytes: startOffset)
    }

    static func parseClaudeFileCancellable(
        fileURL: URL,
        range: CostUsageDayRange,
        providerFilter: ClaudeLogProviderFilter,
        startOffset: Int64 = 0,
        pricingResolver: CostUsagePricing.ClaudeResolver,
        checkCancellation: CancellationCheck? = nil) throws -> ClaudeParseResult
    {
        func toInt(_ v: Any?) -> Int {
            if let n = v as? NSNumber {
                return n.intValue
            }
            return 0
        }

        func toBool(_ value: Any?) -> Bool {
            if let bool = value as? Bool {
                return bool
            }
            if let number = value as? NSNumber {
                return number.boolValue
            }
            return false
        }

        let pathRole = Self.claudePathRole(fileURL: fileURL)
        var keyedRows: [String: ClaudeUsageRow] = [:]
        var unkeyedRows: [ClaudeUsageRow] = []

        let maxLineBytes = 512 * 1024
        // Keep the full line so usage at the tail isn't dropped on large tool outputs.
        let prefixBytes = maxLineBytes
        let costScale = 1_000_000_000.0

        let parsedBytes: Int64
        do {
            parsedBytes = try CostUsageJsonl.scan(
                fileURL: fileURL,
                offset: startOffset,
                maxLineBytes: maxLineBytes,
                prefixBytes: prefixBytes,
                checkCancellation: checkCancellation,
                onLine: { line in
                    guard !line.bytes.isEmpty else { return }
                    guard !line.wasTruncated else { return }
                    guard line.bytes.containsAscii(#""type":"assistant""#) else { return }
                    guard line.bytes.containsAscii(#""usage""#) else { return }

                    autoreleasepool {
                        guard
                            let obj = try? ClaudeJSONObject.decode(line.bytes),
                            let type = obj["type"] as? String,
                            type == "assistant"
                        else { return }
                        let message = obj.dictionary("message")
                        guard Self.matchesClaudeProviderFilter(obj: obj, message: message, filter: providerFilter)
                        else { return }

                        guard let tsText = obj["timestamp"] as? String,
                              let parsedTimestamp = Self.claudeTimestampAndDayKey(tsText, calendar: range.calendar)
                        else { return }
                        let timestamp = parsedTimestamp.date
                        let dayKey = parsedTimestamp.dayKey

                        guard let message else { return }
                        guard let model = message["model"] as? String else { return }
                        guard let usage = message.dictionary("usage") else { return }

                        let input = max(0, toInt(usage["input_tokens"]))
                        let cacheCreate = max(0, toInt(usage["cache_creation_input_tokens"]))
                        let cacheCreate1h = Self.claudeOneHourCacheCreationTokens(
                            usage: usage,
                            total: cacheCreate)
                        let cacheRead = max(0, toInt(usage["cache_read_input_tokens"]))
                        let output = max(0, toInt(usage["output_tokens"]))
                        if input == 0, cacheCreate == 0, cacheRead == 0, output == 0 {
                            return
                        }

                        let cost = pricingResolver.costUSD(
                            model: model,
                            inputTokens: input,
                            cacheReadInputTokens: cacheRead,
                            cacheCreationInputTokens: cacheCreate,
                            cacheCreationInputTokens1h: cacheCreate1h,
                            outputTokens: output,
                            pricingDate: timestamp)
                        let costNanos = cost.map { Int(($0 * costScale).rounded()) } ?? 0
                        let tokens = ClaudeTokens(
                            input: input,
                            cacheRead: cacheRead,
                            cacheCreate: cacheCreate,
                            cacheCreate1h: cacheCreate1h,
                            output: output,
                            costNanos: costNanos,
                            costPriced: cost != nil)

                        guard CostUsageDayRange.isInRange(
                            dayKey: dayKey,
                            since: range.scanSinceKey,
                            until: range.scanUntilKey)
                        else { return }

                        let messageId = message["id"] as? String
                        let requestId = obj["requestId"] as? String
                        let sessionId = obj["sessionId"] as? String
                            ?? obj["session_id"] as? String
                            ?? obj.dictionary("metadata")?["sessionId"] as? String
                            ?? message.dictionary("metadata")?["sessionId"] as? String
                        let normalizedModel = pricingResolver.normalize(model)
                        let toolUse = usage.dictionary("server_tool_use")
                        let row = ClaudeUsageRow(
                            dayKey: dayKey,
                            model: normalizedModel,
                            rawModel: model,
                            backend: Self.claudeLogBackend(obj: obj, message: message),
                            cwd: obj["cwd"] as? String,
                            gitBranch: obj["gitBranch"] as? String,
                            effort: obj["effort"] as? String,
                            serviceTier: usage["service_tier"] as? String,
                            thinkingTokens: toInt(
                                usage.dictionary("output_tokens_details")?["thinking_tokens"]),
                            webSearchRequests: toInt(toolUse?["web_search_requests"]),
                            webFetchRequests: toInt(toolUse?["web_fetch_requests"]),
                            sessionId: sessionId,
                            messageId: messageId,
                            requestId: requestId,
                            timestampUnixMs: Int64((timestamp.timeIntervalSince1970 * 1000).rounded()),
                            isSidechain: toBool(obj["isSidechain"]),
                            pathRole: pathRole,
                            input: tokens.input,
                            cacheRead: tokens.cacheRead,
                            cacheCreate: tokens.cacheCreate,
                            cacheCreate1h: tokens.cacheCreate1h,
                            output: tokens.output,
                            costNanos: tokens.costNanos,
                            costPriced: tokens.costPriced)

                        // Streaming chunks share message.id + requestId inside a file.
                        // Keep overwriting so the final cumulative chunk wins.
                        if let messageId, let requestId {
                            let key = "\(messageId):\(requestId)"
                            keyedRows[key] = row
                        } else {
                            // Older logs omit IDs; treat each line as distinct to avoid dropping usage.
                            unkeyedRows.append(row)
                        }
                    }
                })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            parsedBytes = startOffset
        }

        let rows = keyedRows.keys.sorted().compactMap { keyedRows[$0] } + unkeyedRows
        return ClaudeParseResult(rows: rows, parsedBytes: parsedBytes)
    }

    private static func claudeOneHourCacheCreationTokens(usage: ClaudeJSONObject, total: Int) -> Int {
        guard let cacheCreation = usage.dictionary("cache_creation") else { return 0 }
        let tokens = (cacheCreation["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
        return min(total, max(0, tokens))
    }

    private static func claudePathRole(fileURL: URL) -> ClaudePathRole {
        fileURL.path.contains("/subagents/") ? .subagent : .parent
    }

    private static func claudeCanonicalRowKey(_ row: ClaudeUsageRow) -> String? {
        guard let messageId = row.messageId, let requestId = row.requestId else {
            return nil
        }
        return "\(messageId):\(requestId)"
    }

    private static func claudeRowWins(
        lhs: (path: String, row: ClaudeUsageRow),
        rhs: (path: String, row: ClaudeUsageRow)) -> Bool
    {
        if lhs.row.isSidechain != rhs.row.isSidechain {
            return rhs.row.isSidechain
        }
        if lhs.row.pathRole != rhs.row.pathRole {
            return rhs.row.pathRole == .subagent
        }
        return lhs.path < rhs.path
    }

    private static func reconciledClaudeRows(cache: CostUsageCache) -> [ClaudeUsageRow] {
        #if DEBUG
        recordClaudeScanWork(.reconcile)
        #endif
        var rows: [ClaudeUsageRow] = []
        var winners: [String: (path: String, row: ClaudeUsageRow)] = [:]

        for path in cache.files.keys.sorted() {
            guard let fileRows = cache.files[path]?.claudeRows else { continue }
            for row in fileRows {
                guard let canonicalKey = Self.claudeCanonicalRowKey(row) else {
                    rows.append(row)
                    continue
                }
                let candidate = (path: path, row: row)
                if let existing = winners[canonicalKey] {
                    if Self.claudeRowWins(lhs: candidate, rhs: existing) {
                        winners[canonicalKey] = candidate
                    }
                } else {
                    winners[canonicalKey] = candidate
                }
            }
        }

        rows.append(contentsOf: winners.keys.sorted().compactMap { winners[$0]?.row })
        return rows
    }

    private static let vertexProviderKeys: Set<String> = [
        "provider",
        "platform",
        "backend",
        "api_provider",
        "apiprovider",
        "api_type",
        "apitype",
        "source",
        "vendor",
        "client",
    ]

    private static func matchesClaudeProviderFilter(
        obj: ClaudeJSONObject,
        message: ClaudeJSONObject?,
        filter: ClaudeLogProviderFilter) -> Bool
    {
        filter.allows(self.claudeLogBackend(obj: obj, message: message))
    }

    /// Classifies one transcript row by the API backend that billed it.
    ///
    /// Vertex is tested first so its long-standing (deliberately loose) metadata rules keep their
    /// exact historical outcome; Bedrock is only considered for rows Vertex did not claim.
    static func claudeLogBackend(obj: ClaudeJSONObject, message: ClaudeJSONObject?) -> ClaudeLogBackend {
        if self.isVertexAIUsageEntry(obj: obj, message: message) {
            return .vertexAI
        }
        // Provider-specific by design: classification must name the backend that billed the row, and
        // Bedrock stamps markers only it produces.
        if self.isBedrockUsageEntry(obj: obj, message: message) {
            return .bedrock
        }
        return .firstParty
    }

    static func isBedrockUsageEntry(obj: Any) -> Bool {
        guard let obj = ClaudeJSONObject(obj) else { return false }
        return self.isBedrockUsageEntry(obj: obj)
    }

    static func isBedrockUsageEntry(obj: ClaudeJSONObject) -> Bool {
        self.isBedrockUsageEntry(obj: obj, message: obj.dictionary("message"))
    }

    /// Detects Bedrock-billed rows.
    ///
    /// Unlike the Vertex classifier this deliberately does NOT walk arbitrary metadata or message
    /// text. "bedrock" is an ordinary English word that appears in transcript prose, so a recursive
    /// text match would misclassify any session that merely discusses Bedrock. Only the two markers
    /// the Bedrock API itself stamps are trusted: the `_bdrk_` identifier infix and the
    /// `anthropic.claude-*` model-id namespace (optionally region- or ARN-qualified).
    private static func isBedrockUsageEntry(obj: ClaudeJSONObject, message: ClaudeJSONObject?) -> Bool {
        // Primary detection: Bedrock message ids and request ids carry a "bdrk" infix,
        // e.g. "msg_bdrk_dmkwtqyoytda5f2q3lvl52jqh6ryynodcgeiogncotpl66xatrra".
        if let messageId = message?["id"] as? String,
           messageId.contains("_bdrk_")
        {
            return true
        }
        if let requestId = obj["requestId"] as? String,
           requestId.contains("_bdrk_")
        {
            return true
        }

        // Secondary detection: Bedrock-native model ids namespace the vendor and may carry a
        // region prefix or a full inference-profile ARN, e.g.
        // "anthropic.claude-haiku-4-5-20251001-v1:0", "us.anthropic.claude-opus-4-5-v1:0".
        // First-party ids are bare ("claude-opus-5") and Vertex uses an "@" version separator.
        if let model = message?["model"] as? String,
           Self.modelNameLooksBedrock(model)
        {
            return true
        }

        return false
    }

    /// Detects Bedrock model ids by their `anthropic.` vendor namespace.
    static func modelNameLooksBedrock(_ model: String) -> Bool {
        model.lowercased().contains("anthropic.claude")
    }

    static func isVertexAIUsageEntry(obj: Any) -> Bool {
        guard let obj = ClaudeJSONObject(obj) else { return false }
        return self.isVertexAIUsageEntry(obj: obj)
    }

    static func isVertexAIUsageEntry(obj: ClaudeJSONObject) -> Bool {
        self.isVertexAIUsageEntry(obj: obj, message: obj.dictionary("message"))
    }

    private static func isVertexAIUsageEntry(obj: ClaudeJSONObject, message: ClaudeJSONObject?) -> Bool {
        // Primary detection: Vertex AI message IDs and request IDs have "vrtx" prefix
        // e.g., "msg_vrtx_0154LUXjFVzQGUca3yK2RUeo", "req_vrtx_011CWjK86SWeFuXqZKUtgB1H"
        if let messageId = message?["id"] as? String,
           messageId.contains("_vrtx_")
        {
            return true
        }
        if let requestId = obj["requestId"] as? String,
           requestId.contains("_vrtx_")
        {
            return true
        }

        // Secondary detection: model name with @ version separator (Vertex AI format)
        // e.g., "claude-opus-4-5@20251101" vs "claude-opus-4-5-20251101"
        if let model = message?["model"] as? String,
           Self.modelNameLooksVertex(model)
        {
            return true
        }

        // The recursive walk already includes root and message metadata, requests, context, and client.
        return Self.containsVertexAIMetadata(in: obj)
    }

    /// Detects Vertex AI model names by format.
    /// Vertex AI uses @ for version separator: claude-opus-4-5@20251101
    /// Anthropic API uses -: claude-opus-4-5-20251101
    private static func modelNameLooksVertex(_ model: String) -> Bool {
        // Vertex AI model format: claude-{variant}@{version}
        // Examples: claude-opus-4-5@20251101, claude-sonnet-4-5@20250514
        guard model.hasPrefix("claude-") else { return false }
        return model.contains("@")
    }

    private static func containsVertexAIMetadata(in dict: ClaudeJSONObject) -> Bool {
        dict.contains { key, value in
            if self.containsClaudeVertexMarker(key, includeGCP: true) {
                return true
            }
            if self.vertexProviderKeys.contains(key.lowercased()),
               let text = value.string,
               self.containsClaudeVertexMarker(text)
            {
                return true
            }
            if let nested = value.dictionary {
                return self.containsVertexAIMetadata(in: nested)
            }
            // Array elements descend into dictionaries only, never into another array.
            return value.arrayContainsDictionary { self.containsVertexAIMetadata(in: $0) }
        }
    }

    private static func containsClaudeVertexMarker(_ value: String, includeGCP: Bool = false) -> Bool {
        let asciiMatch = value.utf8.withContiguousStorageIfAvailable { bytes -> Bool? in
            // Validate the entire decoded string before matching: a later combining scalar can
            // change Foundation's substring semantics even when the marker itself is ASCII.
            guard bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
            for index in bytes.indices {
                let first = bytes[index] | 0x20
                if first == 0x76, index + 5 < bytes.count, // vertex
                   bytes[index + 1] | 0x20 == 0x65,
                   bytes[index + 2] | 0x20 == 0x72,
                   bytes[index + 3] | 0x20 == 0x74,
                   bytes[index + 4] | 0x20 == 0x65,
                   bytes[index + 5] | 0x20 == 0x78
                {
                    return true
                }
                if includeGCP, first == 0x67, index + 2 < bytes.count, // gcp
                   bytes[index + 1] | 0x20 == 0x63,
                   bytes[index + 2] | 0x20 == 0x70
                {
                    return true
                }
            }
            return false
        }.flatMap(\.self)
        if let asciiMatch {
            return asciiMatch
        }

        let lower = value.lowercased()
        return lower.contains("vertex") || (includeGCP && lower.contains("gcp"))
    }

    private static func claudeRootCandidates(for rootPath: String) -> [String] {
        if rootPath.hasPrefix("/var/") {
            return ["/private" + rootPath, rootPath]
        }
        if rootPath.hasPrefix("/private/var/") {
            let trimmed = String(rootPath.dropFirst("/private".count))
            return [rootPath, trimmed]
        }
        return [rootPath]
    }

    private struct ClaudeSourceFile {
        let url: URL
        let stamp: CostUsageClaudeFileStamp
    }

    private struct ClaudeSourceInventory {
        var files: [String: ClaudeSourceFile] = [:]

        var stamps: [String: CostUsageClaudeFileStamp] {
            self.files.mapValues(\.stamp)
        }
    }

    private final class ClaudeScanState {
        let store: CostUsageStore
        /// Read once, before the loop. This is both the incremental-parse baseline and the
        /// compare-and-set baseline, which is what makes a stale writer detectable.
        var baselines: [String: ClaudeStoreSourceFile]
        let range: CostUsageDayRange
        let providerFilter: ClaudeLogProviderFilter
        let forceFullScan: Bool
        let changedPaths: Set<String>
        let pricingResolver: CostUsagePricing.ClaudeResolver
        let checkCancellation: CancellationCheck?
        let didParseFileForTesting: (@Sendable (URL) -> Void)?
        let tzIdentity: String

        init(
            store: CostUsageStore,
            baselines: [String: ClaudeStoreSourceFile],
            range: CostUsageDayRange,
            providerFilter: ClaudeLogProviderFilter,
            scan: (forceFullScan: Bool, changedPaths: Set<String>, tzIdentity: String),
            pricingResolver: CostUsagePricing.ClaudeResolver,
            testing: (checkCancellation: CancellationCheck?, didParseFile: (@Sendable (URL) -> Void)?))
        {
            self.store = store
            self.baselines = baselines
            self.range = range
            self.providerFilter = providerFilter
            self.forceFullScan = scan.forceFullScan
            self.changedPaths = scan.changedPaths
            self.tzIdentity = scan.tzIdentity
            self.pricingResolver = pricingResolver
            self.checkCancellation = testing.checkCancellation
            self.didParseFileForTesting = testing.didParseFile
        }
    }

    private static func processClaudeFile(
        source: ClaudeSourceFile,
        state: ClaudeScanState) throws
    {
        try state.checkCancellation?()
        let path = source.url.path
        let stamp = source.stamp
        let baseline = state.baselines[path]
        let sameFile = baseline?.fileIdentity == stamp.fileID
        let sameParse = baseline?.parserRevision == Self.claudeStoreParserRevision
            && baseline?.tzIdentity == state.tzIdentity

        if let baseline, sameFile, sameParse,
           baseline.mtimeMs == stamp.mtimeUnixMs,
           baseline.size == stamp.size,
           baseline.complete,
           baseline.sourcePresent,
           !state.forceFullScan,
           !state.changedPaths.contains(path)
        {
            return
        }

        let startOffset: Int64 = if let baseline, sameFile, sameParse, !state.forceFullScan,
                                    stamp.size > baseline.size,
                                    baseline.parsedOffset > 0, baseline.parsedOffset <= stamp.size
        {
            baseline.parsedOffset
        } else {
            0
        }

        state.pricingResolver.prepareCatalog()
        #if DEBUG
        Self.recordClaudeScanWork(.transcriptParse(startOffset: startOffset))
        #endif
        let parsed = try Self.parseClaudeFileCancellable(
            fileURL: source.url,
            range: state.range,
            providerFilter: state.providerFilter,
            startOffset: startOffset,
            pricingResolver: state.pricingResolver,
            checkCancellation: state.checkCancellation)

        // Re-stat at commit: a transcript written to while it was being read is parsed only as far
        // as it went, so recording the pre-parse stamp is what makes the next scan notice. The
        // rows are still real; the file simply is not fully covered yet.
        state.didParseFileForTesting?(source.url)
        let complete = CostUsageClaudeFileStamp.read(at: source.url) == stamp

        let days = parsed.rows.map(\.dayKey).sorted()
        // Appending widens the file's coverage rather than replacing it: the earlier days are still
        // stored, and narrowing coverage is what makes a wider window look falsely complete.
        let append = startOffset > 0
        let file = ClaudeStoreSourceFile(
            path: path,
            fileIdentity: stamp.fileID,
            size: stamp.size,
            mtimeMs: stamp.mtimeUnixMs,
            parsedOffset: parsed.parsedBytes,
            coverageSinceDay: Self.claudeCoverageBound(
                append ? baseline?.coverageSinceDay : nil, days.first, pick: min),
            coverageUntilDay: Self.claudeCoverageBound(
                append ? baseline?.coverageUntilDay : nil, days.last, pick: max),
            parserRevision: Self.claudeStoreParserRevision,
            tzIdentity: state.tzIdentity,
            complete: complete,
            sourcePresent: true)
        let events = parsed.rows.enumerated().map { index, row in
            Self.storeEvent(row: row, rowIndex: index)
        }

        // The baselines were read before the loop, which is exactly the window a stale writer
        // occupies. A rejection means another scan already moved this file on; its state is newer
        // than ours, so the next refresh reconciles rather than this one.
        switch state.store.syncWriteClaudeFile(
            file: file,
            events: events,
            mode: append ? .append : .replace,
            expecting: baseline)
        {
        case .written:
            state.baselines[path] = file
        case let .rejected(actual):
            Self.log.debug(
                "Claude usage store write rejected; a newer scan already moved this transcript",
                metadata: ["storedParsedOffset": "\(actual?.parsedOffset ?? -1)"])
            if let actual {
                state.baselines[path] = actual
            }
        }
    }

    /// Widest of a retained bound and a freshly parsed one; either may be absent.
    private static func claudeCoverageBound(
        _ retained: String?,
        _ parsed: String?,
        pick: (String, String) -> String) -> String?
    {
        guard let retained else { return parsed }
        guard let parsed else { return retained }
        return pick(retained, parsed)
    }

    private static func inventoryClaudeRoots(
        _ roots: [URL],
        checkCancellation: CancellationCheck?) throws -> ClaudeSourceInventory
    {
        var inventory = ClaudeSourceInventory()

        for root in roots {
            try checkCancellation?()
            let rootPath = root.path
            let rootCandidates = Self.claudeRootCandidates(for: rootPath)
            guard let existingRootPath = rootCandidates.first(where: { FileManager.default.fileExists(atPath: $0) })
            else { continue }
            let existingRoot = existingRootPath == rootPath ? root : URL(fileURLWithPath: existingRootPath)
            guard let enumerator = FileManager.default.enumerator(
                at: existingRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }

            for case let url as URL in enumerator {
                try checkCancellation?()
                guard url.pathExtension.lowercased() == "jsonl" else { continue }
                guard let stamp = CostUsageClaudeFileStamp.read(at: url), stamp.size > 0 else { continue }
                inventory.files[url.path] = ClaudeSourceFile(url: url, stamp: stamp)
            }
        }
        return inventory
    }

    static func loadClaudeDaily(
        provider: UsageProvider,
        range: CostUsageDayRange,
        now: Date,
        options: Options,
        checkCancellation: CancellationCheck?) throws -> CostUsageDailyReport
    {
        let roots = self.defaultClaudeProjectsRoots(options: options)
        let inventory = try Self.inventoryClaudeRoots(roots, checkCancellation: checkCancellation)
        try checkCancellation?()
        let backendScope = options.claudeBackendScope ?? .all
        let pricingResolver = CostUsagePricing.ClaudeResolver(now: now, cacheRoot: options.cacheRoot)

        // Only an unfiltered scan may persist. A provider-scoped scan parses just the rows its
        // filter admits, and because a file write replaces that file's events, storing one would
        // let a later scan for another backend swap the rows out. Such a scan therefore keeps
        // nothing at all: it parses into memory and answers from that.
        guard options.claudeLogProviderFilter == .all else {
            return try Self.loadEphemeralClaudeDaily(
                inventory: inventory,
                range: range,
                backendScope: backendScope,
                options: options,
                parsing: (pricingResolver: pricingResolver, checkCancellation: checkCancellation))
        }

        // Every path form a transcript under these roots can be stored as. A root that has gone
        // missing still belongs to this ledger; roots outside it belong to another profile.
        let ledgerRoots = roots.flatMap { Self.claudeRootCandidates(for: $0.standardizedFileURL.path) }
        let rootsFingerprint = Self.claudeRootsFingerprint(roots)
        let store = CostUsageStore(cacheRoot: options.cacheRoot)
        let ledgerState = store.syncReadClaudeLedgerState(rootsFingerprint: rootsFingerprint)
        // Parse over everything the ledger retains, not just what this caller asked for. Replacing
        // a file's events is only sound if the parse covered every day the store holds for it, and
        // a 30-day refresh sharing a ledger with a 365-day dashboard would otherwise reparse that
        // file into its own narrow window and drop the rest of its history.
        let scanRange = ledgerState.map {
            range.retainingScanWindow(since: $0.scanSinceDay, until: $0.scanUntilDay)
        } ?? range

        let pricingURL = ModelsDevCache.cacheFileURL(cacheRoot: options.cacheRoot)
        let pricingArtifactStamp = CostUsageClaudeFileStamp.read(at: pricingURL)
        let memoIdentity = Self.claudeMemoIdentityPath(provider: provider, cacheRoot: options.cacheRoot)
        let reportKey = Self.claudeReportMemoKey(
            provider: provider,
            scope: (scan: options.claudeLogProviderFilter, backend: backendScope),
            range: range,
            roots: roots,
            state: (generation: ledgerState?.generation ?? 0, pricing: pricingArtifactStamp))
        let memo = CostUsageClaudeReportMemo.shared
        let priorMemo = memo.entry(provider: provider, canonicalCachePath: memoIdentity)
        let sourceInventory = inventory.stamps

        if !options.forceRescan,
           let priorMemo,
           priorMemo.sourceInventory == sourceInventory,
           priorMemo.reportKey == reportKey
        {
            try checkCancellation?()
            return priorMemo.report
        }

        #if DEBUG
        Self.recordClaudeScanWork(.cacheDecode)
        #endif
        var baselines = Dictionary(
            store.syncReadClaudeSourceFiles().map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first })
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let windowExpanded = ledgerState.map {
            range.scanSinceKey < $0.scanSinceDay || range.scanUntilKey > $0.scanUntilDay
        } ?? true
        let sourceInventoryChanged = priorMemo.map { $0.sourceInventory != sourceInventory } ?? false
        let scanConfigurationChanged = priorMemo.map {
            $0.reportKey.scanConfiguration != reportKey.scanConfiguration
        } ?? false
        let sourceIdentitiesChanged = sourceInventory.contains { path, stamp in
            baselines[path]?.fileIdentity != stamp.fileID
        }
        let shouldRefresh = options.forceRescan
            || sourceIdentitiesChanged
            || windowExpanded
            || sourceInventoryChanged
            || scanConfigurationChanged
            || refreshMs == 0
            || ledgerState == nil
            || nowMs - (ledgerState?.lastScanMs ?? 0) > refreshMs
        let hasStableProcessBaseline = priorMemo != nil
            && !sourceIdentitiesChanged
            && !sourceInventoryChanged
            && !scanConfigurationChanged
        let shouldScan = shouldRefresh && (!hasStableProcessBaseline || options.forceRescan || windowExpanded)

        if shouldScan {
            try checkCancellation?()
            let changedPaths: Set<String> = if let priorMemo {
                Set(inventory.files.keys.filter { path in
                    priorMemo.sourceInventory[path] != sourceInventory[path]
                })
            } else {
                []
            }
            let scanState = ClaudeScanState(
                store: store,
                baselines: baselines,
                range: scanRange,
                providerFilter: options.claudeLogProviderFilter,
                scan: (
                    forceFullScan: options.forceRescan || windowExpanded || scanConfigurationChanged,
                    changedPaths: changedPaths,
                    tzIdentity: range.calendar.timeZone.identifier),
                pricingResolver: pricingResolver,
                testing: (
                    checkCancellation: checkCancellation,
                    didParseFile: options.claudeDidParseFileForTesting))

            for path in inventory.files.keys.sorted() {
                guard let source = inventory.files[path] else { continue }
                try Self.processClaudeFile(source: source, state: scanState)
            }
            try checkCancellation?()
            baselines = scanState.baselines

            Self.archiveMissingClaudeSources(
                store: store,
                baselines: baselines,
                present: Set(inventory.files.keys),
                ledgerRoots: ledgerRoots)
            #if DEBUG
            Self.recordClaudeScanWork(.cacheEncode)
            #endif
            let advanced = store.syncAdvanceClaudeLedgerState(
                rootsFingerprint: rootsFingerprint,
                scanSinceDay: scanRange.scanSinceKey,
                scanUntilDay: scanRange.scanUntilKey,
                lastScanMs: nowMs)
            // Nothing else bounds these tables: rows for days the ledger no longer covers would
            // accumulate for every transcript that is never touched again. Prune to the ledger's
            // retained window rather than to this scan's, because the two differ — a 30-day refresh
            // and a 365-day dashboard read share one ledger, and the narrower one must not evict
            // the wider one's history, which an unchanged transcript would never restore.
            if let advanced {
                _ = store.syncRetainClaudeDayWindow(
                    sinceDay: advanced.scanSinceDay,
                    untilDay: advanced.scanUntilDay,
                    roots: ledgerRoots)
            }
            // The store now holds a complete replacement for the JSON artifacts, which is the
            // condition their removal was gated on.
            Self.removeLegacyClaudeArtifactsIfPresent(cacheRoot: options.cacheRoot)
        }

        // Seed prices before reading: `claude_event_costs` joins them, and a scan that added a
        // model the catalog knows would otherwise report it as unpriced until the next refresh.
        Self.seedClaudeModelPrices(store: store, pricingResolver: pricingResolver)
        let report = Self.buildClaudeReport(
            rows: store.syncReadClaudeReportRows(
                backends: Self.claudeBackendRawValues(backendScope),
                roots: ledgerRoots,
                sinceDay: range.sinceKey,
                untilDay: range.untilKey),
            range: range)
        try checkCancellation?()

        let finalReportKey = Self.claudeReportMemoKey(
            provider: provider,
            scope: (scan: options.claudeLogProviderFilter, backend: backendScope),
            range: range,
            roots: roots,
            state: (
                generation: store.syncReadClaudeLedgerState(
                    rootsFingerprint: rootsFingerprint)?.generation ?? 0,
                pricing: CostUsageClaudeFileStamp.read(at: pricingURL)))
        if finalReportKey.pricingArtifactStamp == pricingArtifactStamp {
            memo.store(
                provider: provider,
                canonicalCachePath: memoIdentity,
                sourceInventory: sourceInventory,
                reportKey: finalReportKey,
                report: report)
        }
        return report
    }

    /// A report for a scan that may not persist anything, parsed fresh into memory.
    ///
    /// Only a provider-filtered scan takes this path, and it keeps no state at all: there is no
    /// incremental offset to resume from and nothing is left behind for the next one.
    private static func loadEphemeralClaudeDaily(
        inventory: ClaudeSourceInventory,
        range: CostUsageDayRange,
        backendScope: ClaudeLogProviderFilter,
        options: Options,
        parsing: (
            pricingResolver: CostUsagePricing.ClaudeResolver,
            checkCancellation: CancellationCheck?)) throws -> CostUsageDailyReport
    {
        var cache = CostUsageCache()
        for path in inventory.files.keys.sorted() {
            guard let source = inventory.files[path] else { continue }
            try parsing.checkCancellation?()
            parsing.pricingResolver.prepareCatalog()
            #if DEBUG
            Self.recordClaudeScanWork(.transcriptParse(startOffset: 0))
            #endif
            let parsed = try Self.parseClaudeFileCancellable(
                fileURL: source.url,
                range: range,
                providerFilter: options.claudeLogProviderFilter,
                pricingResolver: parsing.pricingResolver,
                checkCancellation: parsing.checkCancellation)
            cache.files[path] = Self.makeFileUsage(
                mtimeUnixMs: source.stamp.mtimeUnixMs,
                size: source.stamp.size,
                days: [:],
                parsedBytes: parsed.parsedBytes,
                claudeRows: parsed.rows)
        }
        try parsing.checkCancellation?()
        return Self.buildClaudeReport(
            rows: Self.claudeReportRows(
                cache: cache,
                backendScope: backendScope,
                range: range,
                pricingResolver: parsing.pricingResolver),
            range: range)
    }

    /// Records the transcripts this ledger tracked that are no longer on disk.
    ///
    /// Recorded, not erased: the usage was really spent and the store is the only copy of it.
    /// Retention removes the rows when their days age out.
    private static func archiveMissingClaudeSources(
        store: CostUsageStore,
        baselines: [String: ClaudeStoreSourceFile],
        present: Set<String>,
        ledgerRoots: [String])
    {
        for (path, file) in baselines where !present.contains(path) {
            // A profile-scoped scan walks part of the vault, so a transcript missing from this
            // scan's inventory may simply belong to another ledger.
            guard file.sourcePresent, Self.claudePath(path, isUnder: ledgerRoots) else { continue }
            _ = store.syncMarkClaudeSourceMissing(path: path)
        }
    }

    /// Deletes the JSON artifacts the store has replaced.
    ///
    /// Deliberately not `removeLegacyCodexArtifactIfPresent`: that one is Codex-specific and
    /// rebuilds the database, which here would throw away the very rows that earned the deletion.
    /// Called only after a scan has committed, which is the "complete replacement" condition.
    static func removeLegacyClaudeArtifactsIfPresent(cacheRoot: URL?) {
        let root = cacheRoot ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexBar", isDirectory: true)
        let directory = root.appendingPathComponent("cost-usage", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        for name in names where Self.isLegacyClaudeArtifactName(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func isLegacyClaudeArtifactName(_ name: String) -> Bool {
        // Their temporary siblings too: a crashed save leaves `.claude-cache-<uuid>.tmp` behind.
        let stems = ["claude-v6.json", "vertexai-v6.json", "bedrock-v6.json"]
        if stems.contains(where: { name == $0 || name.hasPrefix("\($0).") }) { return true }
        if stems.contains(where: { name == $0.replacingOccurrences(of: ".json", with: ".report-memo.json") }) {
            return true
        }
        return name.hasPrefix(".claude-cache-") && name.hasSuffix(".tmp")
    }

    /// How many times a scan over `roots` has committed. Tests assert on it where they used to
    /// compare the bytes of the cache file: "did a scan actually write" is now a store question.
    static func claudeLedgerGenerationForTesting(roots: [URL], cacheRoot: URL?) -> Int64 {
        CostUsageStore(cacheRoot: cacheRoot)
            .syncReadClaudeLedgerState(rootsFingerprint: self.claudeRootsFingerprint(roots))?
            .generation ?? 0
    }

    /// One ledger is one set of roots. Claude, Vertex and Bedrock over the same roots are one scan.
    private static func claudeRootsFingerprint(_ roots: [URL]) -> String {
        roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }.sorted().joined(separator: "\n")
    }

    /// Identity for this provider's report memo. Names no file that has to exist — the memo's own
    /// persistence derives its filename from it.
    static func claudeMemoIdentityPath(provider: UsageProvider, cacheRoot: URL?) -> String {
        let root = cacheRoot ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexBar", isDirectory: true)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("\(provider.rawValue)-ledger.json", isDirectory: false)
            .standardizedFileURL.path
    }

    private static func claudeReportMemoKey(
        provider: UsageProvider,
        scope: (scan: ClaudeLogProviderFilter, backend: ClaudeLogProviderFilter),
        range: CostUsageDayRange,
        roots: [URL],
        state: (generation: Int64, pricing: CostUsageClaudeFileStamp?))
        -> CostUsageClaudeReportMemoKey
    {
        CostUsageClaudeReportMemoKey(
            provider: provider,
            // Scan scope and report scope are separate knobs now, and a memo hit must match both.
            providerFilter: "\(scope.scan.cacheKey)|\(scope.backend.cacheKey)",
            sinceKey: range.sinceKey,
            untilKey: range.untilKey,
            scanSinceKey: range.scanSinceKey,
            scanUntilKey: range.scanUntilKey,
            timeZoneIdentifier: range.calendar.timeZone.identifier,
            roots: roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }.sorted(),
            storeGeneration: state.generation,
            pricingArtifactStamp: state.pricing)
    }

    /// Rows this ledger reports, taken from the store whenever the store is allowed to hold them.
    ///
    /// Writes the rates `claude_event_costs` prices with, for every model the store holds.
    ///
    /// Model-id routing and catalog fallbacks stay in Swift; only the arithmetic moves to SQL. The
    /// full-context models changed tier pricing at a known instant, so those get one window on each
    /// side of it and every other model gets a single open-ended one.
    static func seedClaudeModelPrices(
        store: CostUsageStore,
        pricingResolver: CostUsagePricing.ClaudeResolver)
    {
        let cutoff = CostUsagePricing.claudeFullContextStandardPricingCutoff
        let cutoffMs = Int64((cutoff.timeIntervalSince1970 * 1000).rounded())
        var prices: [ClaudeStoreModelPrice] = []

        for key in store.syncReadClaudeEventModelKeys() {
            let historical = pricingResolver.pricing(model: key.model, pricingDate: .distantPast)
            guard let current = pricingResolver.pricing(model: key.model, pricingDate: cutoff)
            else { continue }
            let hasEarlierWindow = historical != nil && historical != current
            if hasEarlierWindow, let historical {
                prices.append(Self.claudeModelPrice(
                    key: key,
                    pricing: historical,
                    window: (from: Int64.min, to: cutoffMs)))
            }
            prices.append(Self.claudeModelPrice(
                key: key,
                pricing: current,
                window: (from: hasEarlierWindow ? cutoffMs : Int64.min, to: nil)))
        }

        _ = store.syncReplaceClaudeModelPrices(prices)
    }

    private static func claudeModelPrice(
        key: ClaudeStoreModelKey,
        pricing: CostUsagePricing.ClaudePricing,
        window: (from: Int64, to: Int64?)) -> ClaudeStoreModelPrice
    {
        ClaudeStoreModelPrice(
            model: key.model,
            backend: key.backend,
            validFromMs: window.from,
            validToMs: window.to,
            inputPerToken: pricing.inputCostPerToken,
            cacheReadPerToken: pricing.cacheReadInputCostPerToken,
            cacheWritePerToken: pricing.cacheCreationInputCostPerToken,
            outputPerToken: pricing.outputCostPerToken,
            longContextThreshold: pricing.thresholdTokens,
            longContextInputPerToken: pricing.inputCostPerTokenAboveThreshold,
            longContextCacheReadPerToken: pricing.cacheReadInputCostPerTokenAboveThreshold,
            longContextCacheWritePerToken: pricing.cacheCreationInputCostPerTokenAboveThreshold,
            longContextOutputPerToken: pricing.outputCostPerTokenAboveThreshold)
    }

    /// Backend allow-list as stored `backend` values; `nil` when the scope admits everything.
    private static func claudeBackendRawValues(_ scope: ClaudeLogProviderFilter) -> Set<String>? {
        guard scope != .all else { return nil }
        return Set(scope.allowed.map(\.rawValue))
    }

    /// Report rows from the in-memory cache, for the scans the store may not answer for.
    ///
    /// Only a filtered scan takes this path: it parses a partial row set, so the store is
    /// deliberately left untouched and cannot be read back. Pricing mirrors `claude_event_costs`,
    /// including its precedence: a row priced to exactly zero at ingest stays zero.
    private static func claudeReportRows(
        cache: CostUsageCache,
        backendScope: ClaudeLogProviderFilter,
        range: CostUsageDayRange,
        pricingResolver: CostUsagePricing.ClaudeResolver) -> [ClaudeStoreReportRow]
    {
        let costScale = 1_000_000_000.0
        return self.reconciledClaudeRows(cache: cache).compactMap { row in
            guard backendScope.allows(row.backend ?? .firstParty) else { return nil }
            guard CostUsageDayRange.isInRange(
                dayKey: row.dayKey,
                since: range.sinceKey,
                until: range.untilKey)
            else { return nil }
            let ingestPriced = row.costPriced ?? (row.costNanos > 0)
            let catalogCost = self.pricingResolverCost(row: row, resolver: pricingResolver)
            let cost: Double? = if ingestPriced, row.costNanos == 0 {
                0
            } else if let catalogCost {
                catalogCost
            } else if ingestPriced {
                Double(row.costNanos) / costScale
            } else {
                nil
            }
            return ClaudeStoreReportRow(
                day: row.dayKey,
                model: row.model,
                input: row.input,
                cacheRead: row.cacheRead,
                cacheCreate: row.cacheCreate,
                output: row.output,
                costUSD: cost)
        }
    }

    private static func pricingResolverCost(
        row: ClaudeUsageRow,
        resolver: CostUsagePricing.ClaudeResolver) -> Double?
    {
        resolver.costUSD(
            model: row.model,
            inputTokens: row.input,
            cacheReadInputTokens: row.cacheRead,
            cacheCreationInputTokens: row.cacheCreate,
            cacheCreationInputTokens1h: row.cacheCreate1h ?? 0,
            outputTokens: row.output,
            pricingDate: row.timestampUnixMs.map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            })
    }

    /// Total order over report rows, used only to make the cost summation source-independent.
    private static func claudeReportRowPrecedes(
        _ lhs: ClaudeStoreReportRow,
        _ rhs: ClaudeStoreReportRow) -> Bool
    {
        if lhs.day != rhs.day { return lhs.day < rhs.day }
        if lhs.model != rhs.model { return lhs.model < rhs.model }
        if lhs.input != rhs.input { return lhs.input < rhs.input }
        if lhs.cacheRead != rhs.cacheRead { return lhs.cacheRead < rhs.cacheRead }
        if lhs.cacheCreate != rhs.cacheCreate { return lhs.cacheCreate < rhs.cacheCreate }
        if lhs.output != rhs.output { return lhs.output < rhs.output }
        switch (lhs.costUSD, rhs.costUSD) {
        case let (lhsCost?, rhsCost?): return lhsCost < rhsCost
        case (nil, _?): return true
        default: return false
        }
    }

    /// Buckets already-priced rows into the day×model report.
    ///
    /// Pricing is per event and never per aggregate: long-context tiers are chosen from one
    /// request's own token count, so summing tokens first would price large days at the wrong tier.
    private static func buildClaudeReport(
        rows: [ClaudeStoreReportRow],
        range: CostUsageDayRange) -> CostUsageDailyReport
    {
        guard !rows.isEmpty else { return CostUsageDailyReport(data: [], summary: nil) }
        var totals: [ClaudeDayModelKey: ClaudeDayModelTotals] = [:]

        // Per-row costs are `Double`s, so the same rows summed in a different order can differ in
        // the last ulp. Two ledgers reading the same events must agree exactly, and the store
        // returns rows in its own order, so the sum is taken in a canonical one.
        for row in rows.sorted(by: Self.claudeReportRowPrecedes) {
            #if DEBUG
            Self.recordClaudeScanWork(.reprice)
            #endif
            let key = ClaudeDayModelKey(day: row.day, model: row.model)
            var aggregate = totals[key] ?? ClaudeDayModelTotals()
            aggregate.input += row.input
            aggregate.cacheRead += row.cacheRead
            aggregate.cacheCreate += row.cacheCreate
            aggregate.output += row.output
            if let cost = row.costUSD {
                aggregate.cost += cost
            } else {
                aggregate.unresolved = true
            }
            totals[key] = aggregate
        }

        var entries: [CostUsageDailyReport.Entry] = []
        var summaryInput = 0
        var summaryOutput = 0
        var summaryCacheRead = 0
        var summaryCacheCreate = 0
        var summaryTokens = 0
        var summaryCost: Double = 0
        var summaryCostSeen = false

        for day in Set(totals.keys.map(\.day)).sorted() {
            let modelNames = totals.keys.filter { $0.day == day }.map(\.model).sorted()
            var dayInput = 0
            var dayOutput = 0
            var dayCacheRead = 0
            var dayCacheCreate = 0
            var dayCost: Double = 0
            var dayCostSeen = false
            var breakdown: [CostUsageDailyReport.ModelBreakdown] = []

            for model in modelNames {
                guard let aggregate = totals[ClaudeDayModelKey(day: day, model: model)] else { continue }
                dayInput += aggregate.input
                dayCacheRead += aggregate.cacheRead
                dayCacheCreate += aggregate.cacheCreate
                dayOutput += aggregate.output

                let cost: Double? = aggregate.unresolved ? nil : aggregate.cost
                breakdown.append(
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: model,
                        costUSD: cost,
                        totalTokens: aggregate.totalTokens))
                if let cost {
                    dayCost += cost
                    dayCostSeen = true
                }
            }

            let dayTotal = dayInput + dayCacheRead + dayCacheCreate + dayOutput
            let entryCost = dayCostSeen ? dayCost : nil
            entries.append(CostUsageDailyReport.Entry(
                date: day,
                inputTokens: dayInput,
                outputTokens: dayOutput,
                cacheReadTokens: dayCacheRead,
                cacheCreationTokens: dayCacheCreate,
                totalTokens: dayTotal,
                costUSD: entryCost,
                modelsUsed: modelNames,
                modelBreakdowns: Self.sortedModelBreakdowns(breakdown)))

            summaryInput += dayInput
            summaryOutput += dayOutput
            summaryCacheRead += dayCacheRead
            summaryCacheCreate += dayCacheCreate
            summaryTokens += dayTotal
            if let entryCost {
                summaryCost += entryCost
                summaryCostSeen = true
            }
        }

        let summary: CostUsageDailyReport.Summary? = entries.isEmpty
            ? nil
            : CostUsageDailyReport.Summary(
                totalInputTokens: summaryInput,
                totalOutputTokens: summaryOutput,
                cacheReadTokens: summaryCacheRead,
                cacheCreationTokens: summaryCacheCreate,
                totalTokens: summaryTokens,
                totalCostUSD: summaryCostSeen ? summaryCost : nil)

        return CostUsageDailyReport(data: entries, summary: summary)
    }
}

extension CostUsageScanner {
    private static func claudePath(_ path: String, isUnder roots: [String]) -> Bool {
        roots.contains { root in
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return path.hasPrefix(prefix)
        }
    }

    /// Bumped when the stored row shape changes, so a stale row set is recognisably old.
    static let claudeStoreParserRevision = 1

    private static func storeEvent(row: ClaudeUsageRow, rowIndex: Int) -> ClaudeStoreUsageEvent {
        ClaudeStoreUsageEvent(
            rowIndex: rowIndex,
            timestampUnixMs: row.timestampUnixMs,
            day: row.dayKey,
            backend: (row.backend ?? .firstParty).rawValue,
            model: row.model,
            rawModel: row.rawModel ?? row.model,
            sessionID: row.sessionId,
            messageID: row.messageId,
            requestID: row.requestId,
            cwd: row.cwd,
            gitBranch: row.gitBranch,
            pathRole: row.pathRole == .subagent ? "subagent" : "main",
            isSidechain: row.isSidechain,
            effort: row.effort,
            serviceTier: row.serviceTier,
            input: row.input,
            cacheRead: row.cacheRead,
            cacheCreate: row.cacheCreate,
            cacheCreate1h: row.cacheCreate1h ?? 0,
            output: row.output,
            thinkingTokens: row.thinkingTokens ?? 0,
            webSearchRequests: row.webSearchRequests ?? 0,
            webFetchRequests: row.webFetchRequests ?? 0,
            ingestCostNanos: row.costNanos,
            ingestCostPriced: row.costPriced ?? false)
    }
}
