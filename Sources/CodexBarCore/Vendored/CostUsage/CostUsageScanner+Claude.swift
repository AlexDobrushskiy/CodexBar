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

    private static func mergeClaudeRows(existing: [ClaudeUsageRow], delta: [ClaudeUsageRow]) -> [ClaudeUsageRow] {
        var keyedRows: [String: ClaudeUsageRow] = [:]
        var unkeyedRows: [ClaudeUsageRow] = []

        for row in existing {
            if let key = Self.claudeInFileKey(row) {
                keyedRows[key] = row
            } else {
                unkeyedRows.append(row)
            }
        }
        for row in delta {
            if let key = Self.claudeInFileKey(row) {
                keyedRows[key] = row
            } else {
                unkeyedRows.append(row)
            }
        }

        return keyedRows.keys.sorted().compactMap { keyedRows[$0] } + unkeyedRows
    }

    private static func claudeInFileKey(_ row: ClaudeUsageRow) -> String? {
        guard let messageId = row.messageId, let requestId = row.requestId else { return nil }
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

    private static func rebuildClaudeDays(cache: inout CostUsageCache) {
        var days: [String: [String: [Int]]] = [:]

        for row in Self.reconciledClaudeRows(cache: cache) {
            var dayModels = days[row.dayKey] ?? [:]
            var packed = dayModels[row.model] ?? [0, 0, 0, 0, 0, 0, 0, 0]
            packed[0] = (packed[safe: 0] ?? 0) + row.input
            packed[1] = (packed[safe: 1] ?? 0) + row.cacheRead
            packed[2] = (packed[safe: 2] ?? 0) + row.cacheCreate
            packed[3] = (packed[safe: 3] ?? 0) + row.output
            packed[4] = (packed[safe: 4] ?? 0) + row.costNanos
            packed[5] = (packed[safe: 5] ?? 0) + 1
            packed[6] = (packed[safe: 6] ?? 0) + ((row.costPriced ?? (row.costNanos > 0)) ? 1 : 0)
            packed[7] = (packed[safe: 7] ?? 0) + (row.cacheCreate1h ?? 0)
            dayModels[row.model] = packed
            days[row.dayKey] = dayModels
        }

        cache.days = days
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
        var cache: CostUsageCache
        var sourceFileIDs: [String: String]
        /// Transcripts whose size, mtime or identity moved between the parse and its commit. Their
        /// rows are real, but the file is not fully covered, so it must not be stamped complete.
        var movedWhileParsingPaths: Set<String> = []
        let range: CostUsageDayRange
        let providerFilter: ClaudeLogProviderFilter
        let forceFullScan: Bool
        let changedPaths: Set<String>
        let pricingResolver: CostUsagePricing.ClaudeResolver
        let checkCancellation: CancellationCheck?
        let didParseFileForTesting: (@Sendable (URL) -> Void)?

        init(
            cache: CostUsageCache,
            sourceFileIDs: [String: String],
            range: CostUsageDayRange,
            providerFilter: ClaudeLogProviderFilter,
            forceFullScan: Bool,
            changedPaths: Set<String>,
            pricingResolver: CostUsagePricing.ClaudeResolver,
            checkCancellation: CancellationCheck?,
            didParseFileForTesting: (@Sendable (URL) -> Void)?)
        {
            self.cache = cache
            self.sourceFileIDs = sourceFileIDs
            self.range = range
            self.providerFilter = providerFilter
            self.forceFullScan = forceFullScan
            self.changedPaths = changedPaths
            self.pricingResolver = pricingResolver
            self.checkCancellation = checkCancellation
            self.didParseFileForTesting = didParseFileForTesting
        }
    }

    private static func processClaudeFile(
        source: ClaudeSourceFile,
        state: ClaudeScanState) throws
    {
        try state.checkCancellation?()
        let path = source.url.path
        let stamp = source.stamp
        let cached = state.cache.files[path]
        let sameFile = state.sourceFileIDs[path] == stamp.fileID

        if let cached, sameFile,
           cached.mtimeUnixMs == stamp.mtimeUnixMs,
           cached.size == stamp.size,
           !state.forceFullScan,
           !state.changedPaths.contains(path)
        {
            return
        }

        let startOffset: Int64 = if let cached, sameFile, !state.forceFullScan,
                                    stamp.size > cached.size,
                                    cached.claudeRows != nil,
                                    let parsedBytes = cached.parsedBytes, parsedBytes > 0, parsedBytes <= stamp.size
        {
            parsedBytes
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
        let rows = startOffset > 0 ? Self.mergeClaudeRows(existing: cached?.claudeRows ?? [], delta: parsed.rows)
            : parsed.rows
        // Re-stat at commit: a transcript written to while it was being read is parsed only as far
        // as it went, so recording the pre-parse stamp is what makes the next scan notice. The
        // rows are still real; the file simply is not fully covered yet.
        state.didParseFileForTesting?(source.url)
        let committedStamp = CostUsageClaudeFileStamp.read(at: source.url)
        if committedStamp != stamp {
            state.movedWhileParsingPaths.insert(path)
        } else {
            state.movedWhileParsingPaths.remove(path)
        }
        let usage = Self.makeFileUsage(
            mtimeUnixMs: stamp.mtimeUnixMs,
            size: stamp.size,
            days: [:],
            parsedBytes: parsed.parsedBytes,
            claudeRows: rows)
        state.cache.files[path] = usage
        state.sourceFileIDs[path] = stamp.fileID
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
        // Every path form a transcript under these roots can be stored as. A root that has gone
        // missing still belongs to this ledger, so its rows are swept rather than left to be
        // reported forever; roots outside it belong to another profile and are never touched.
        let ledgerRoots = roots.flatMap { Self.claudeRootCandidates(for: $0.standardizedFileURL.path) }
        let inventory = try Self.inventoryClaudeRoots(roots, checkCancellation: checkCancellation)
        try checkCancellation?()

        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(provider: provider, cacheRoot: options.cacheRoot)
        let canonicalCachePath = cacheURL.standardizedFileURL.resolvingSymlinksInPath().path
        let cacheArtifactStamp = CostUsageClaudeFileStamp.read(at: cacheURL)
        let pricingURL = ModelsDevCache.cacheFileURL(cacheRoot: options.cacheRoot)
        let pricingArtifactStamp = CostUsageClaudeFileStamp.read(at: pricingURL)
        let backendScope = options.claudeBackendScope ?? .all
        let reportKey = Self.claudeReportMemoKey(
            provider: provider,
            scope: (scan: options.claudeLogProviderFilter, backend: backendScope),
            range: range,
            roots: roots,
            artifactStamps: (cache: cacheArtifactStamp, pricing: pricingArtifactStamp))
        let memo = CostUsageClaudeReportMemo.shared
        let priorMemo = memo.entry(provider: provider, canonicalCachePath: canonicalCachePath)
        let sourceInventory = inventory.stamps

        if !options.forceRescan,
           let priorMemo,
           priorMemo.sourceInventory == sourceInventory,
           priorMemo.reportKey == reportKey
        {
            try checkCancellation?()
            return priorMemo.report
        }

        var artifact = CostUsageClaudeCacheIO.load(
            provider: provider,
            cacheRoot: options.cacheRoot,
            calendar: range.calendar)
        var cache = artifact.usage
        var movedWhileParsingPaths: Set<String> = []
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let windowExpanded = Self.requestedWindowExpandsCache(range: range, cache: cache)
        let sourceInventoryChanged = priorMemo.map { $0.sourceInventory != sourceInventory } ?? false
        let cacheArtifactChanged = priorMemo.map {
            $0.reportKey.cacheArtifactStamp != cacheArtifactStamp
        } ?? false
        let scanConfigurationChanged = priorMemo.map {
            $0.reportKey.scanConfiguration != reportKey.scanConfiguration
        } ?? false
        let sourceIdentitiesChanged = artifact.sourceFileIDs != sourceInventory.mapValues(\.fileID)
        let shouldRefresh = options.forceRescan
            || sourceIdentitiesChanged
            || windowExpanded
            || sourceInventoryChanged
            || cacheArtifactChanged
            || scanConfigurationChanged
            || refreshMs == 0
            || cache.lastScanUnixMs == 0
            || nowMs - cache.lastScanUnixMs > refreshMs
        let providerFilter = options.claudeLogProviderFilter
        let hasStableProcessBaseline = priorMemo != nil
            && !sourceIdentitiesChanged
            && !sourceInventoryChanged
            && !cacheArtifactChanged
            && !scanConfigurationChanged
        let shouldMutateCache = shouldRefresh && (!hasStableProcessBaseline || options.forceRescan || windowExpanded)
        let pricingResolver = CostUsagePricing.ClaudeResolver(now: now, cacheRoot: options.cacheRoot)

        if shouldMutateCache {
            try checkCancellation?()
            if options.forceRescan {
                cache = CostUsageCache()
                artifact.sourceFileIDs = [:]
            }
            let changedPaths: Set<String> = if let priorMemo {
                Set(inventory.files.keys.filter { path in
                    priorMemo.sourceInventory[path] != sourceInventory[path]
                })
            } else {
                []
            }
            let scanState = ClaudeScanState(
                cache: cache,
                sourceFileIDs: artifact.sourceFileIDs,
                range: range,
                providerFilter: providerFilter,
                forceFullScan: options.forceRescan || windowExpanded || scanConfigurationChanged,
                changedPaths: changedPaths,
                pricingResolver: pricingResolver,
                checkCancellation: checkCancellation,
                didParseFileForTesting: options.claudeDidParseFileForTesting)

            for path in inventory.files.keys.sorted() {
                guard let source = inventory.files[path] else { continue }
                try Self.processClaudeFile(source: source, state: scanState)
            }
            try checkCancellation?()

            cache = scanState.cache
            movedWhileParsingPaths = scanState.movedWhileParsingPaths
            artifact.sourceFileIDs = scanState.sourceFileIDs.filter { sourceInventory[$0.key] != nil }
            cache.roots = nil

            for key in cache.files.keys where sourceInventory[key] == nil {
                cache.files.removeValue(forKey: key)
            }

            Self.rebuildClaudeDays(cache: &cache)
            Self.pruneDays(cache: &cache, sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            cache.scanSinceKey = range.scanSinceKey
            cache.scanUntilKey = range.scanUntilKey
            cache.lastScanUnixMs = nowMs
        }

        artifact.usage = cache
        let committedCacheStamp: CostUsageClaudeFileStamp? = if shouldMutateCache {
            try CostUsageClaudeCacheIO.save(
                provider: provider,
                cache: artifact,
                cacheRoot: options.cacheRoot,
                calendar: range.calendar,
                checkCancellation: checkCancellation)
        } else {
            nil
        }

        let report = Self.buildClaudeReport(
            rows: Self.claudeLedgerReportRows(
                cache: cache,
                sourceFileIDs: artifact.sourceFileIDs,
                scope: (backend: backendScope, roots: ledgerRoots, incomplete: movedWhileParsingPaths),
                range: range,
                options: (scan: options, pricingResolver: pricingResolver)),
            range: range)
        try checkCancellation?()

        let finalCacheArtifactStamp = CostUsageClaudeFileStamp.read(at: cacheURL)
        let finalPricingArtifactStamp = CostUsageClaudeFileStamp.read(at: pricingURL)
        let finalReportKey = Self.claudeReportMemoKey(
            provider: provider,
            scope: (scan: providerFilter, backend: backendScope),
            range: range,
            roots: roots,
            artifactStamps: (cache: finalCacheArtifactStamp, pricing: finalPricingArtifactStamp))
        let cacheArtifactIsCurrent = if shouldMutateCache {
            committedCacheStamp != nil && finalCacheArtifactStamp == committedCacheStamp
        } else {
            finalCacheArtifactStamp == cacheArtifactStamp
        }
        if cacheArtifactIsCurrent, finalPricingArtifactStamp == pricingArtifactStamp {
            memo.store(
                provider: provider,
                canonicalCachePath: canonicalCachePath,
                sourceInventory: sourceInventory,
                reportKey: finalReportKey,
                report: report)
        }
        return report
    }

    private static func claudeReportMemoKey(
        provider: UsageProvider,
        scope: (scan: ClaudeLogProviderFilter, backend: ClaudeLogProviderFilter),
        range: CostUsageDayRange,
        roots: [URL],
        artifactStamps: (cache: CostUsageClaudeFileStamp?, pricing: CostUsageClaudeFileStamp?))
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
            cacheArtifactStamp: artifactStamps.cache,
            pricingArtifactStamp: artifactStamps.pricing)
    }

    /// Rows this ledger reports, taken from the store whenever the store is allowed to hold them.
    ///
    /// Only an unfiltered scan may write: a provider-scoped scan parses just the rows its filter
    /// admits, and because the mirror replaces a file's events, storing one would let a later scan
    /// for another backend swap the rows out. The store holds every backend; the ledger split is a
    /// `WHERE` clause over `backend`.
    private static func claudeLedgerReportRows(
        cache: CostUsageCache,
        sourceFileIDs: [String: String],
        scope: (backend: ClaudeLogProviderFilter, roots: [String], incomplete: Set<String>),
        range: CostUsageDayRange,
        options: (scan: Options, pricingResolver: CostUsagePricing.ClaudeResolver))
        -> [ClaudeStoreReportRow]
    {
        guard options.scan.claudeLogProviderFilter == .all else {
            options.pricingResolver.prepareCatalog()
            return self.claudeReportRows(
                cache: cache,
                backendScope: scope.backend,
                range: range,
                pricingResolver: options.pricingResolver)
        }
        let store = CostUsageStore(cacheRoot: options.scan.cacheRoot)
        // Unconditional, not gated on whether this run rewrote the cache: the report is read back
        // out of the store, so a run that reuses an untouched cache still needs it current.
        Self.syncClaudeStore(
            store: store,
            cache: cache,
            sourceFileIDs: sourceFileIDs,
            ledger: (
                roots: scope.roots,
                retainWindow: (since: range.scanSinceKey, until: range.scanUntilKey),
                tzIdentity: range.calendar.timeZone.identifier),
            incompletePaths: scope.incomplete)
        // Seed prices before reading: `claude_event_costs` joins them, and a scan that added a
        // model the catalog has would otherwise report it as unpriced until the next refresh.
        Self.seedClaudeModelPrices(store: store, pricingResolver: options.pricingResolver)
        return store.syncReadClaudeReportRows(
            backends: Self.claudeBackendRawValues(scope.backend),
            roots: scope.roots,
            sinceDay: range.sinceKey,
            untilDay: range.untilKey)
    }

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
    /// Brings `CostUsageStore` up to date with the scanned transcripts, as per-event rows.
    ///
    /// The JSON artifact keeps day×model totals; the store keeps the rows those totals came from,
    /// so usage stays answerable by project, session, branch and backend. Cross-file parent/subagent
    /// reconciliation is deliberately NOT applied here — every candidate is stored and the winner is
    /// chosen by `claude_reconciled_events`, so deleting a winner reveals the loser.
    ///
    /// Only files whose recorded state actually moved are rewritten, and the eviction sweep is
    /// confined to the roots this scan walked.
    static func syncClaudeStore(
        store: CostUsageStore,
        cache: CostUsageCache,
        sourceFileIDs: [String: String],
        ledger: (roots: [String], retainWindow: (since: String, until: String), tzIdentity: String),
        incompletePaths: Set<String>)
    {
        let tzIdentity = ledger.tzIdentity
        let stored = Dictionary(
            store.syncReadClaudeSourceFiles().map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first })

        for (path, usage) in cache.files {
            let rows = usage.claudeRows ?? []
            let days = rows.map(\.dayKey).sorted()
            let file = ClaudeStoreSourceFile(
                path: path,
                fileIdentity: sourceFileIDs[path],
                size: usage.size,
                mtimeMs: usage.mtimeUnixMs,
                parsedOffset: usage.parsedBytes ?? 0,
                coverageSinceDay: days.first,
                coverageUntilDay: days.last,
                parserRevision: Self.claudeStoreParserRevision,
                tzIdentity: tzIdentity,
                complete: !incompletePaths.contains(path))
            // Rewriting an unchanged file's events is what made a real refresh spend most of its
            // time in the store: the cache holds every transcript, not just the ones this scan
            // parsed. The recorded file state is the same baseline the parser skipped on.
            let baseline = stored[path]
            guard baseline != file else { continue }
            let events = rows.enumerated().map { index, row in
                Self.storeEvent(row: row, rowIndex: index)
            }
            // Baselines were read once, before this loop, which is exactly the stale-writer window
            // the compare-and-set closes. A rejected write means another scan moved the file on;
            // its state is newer than ours, so the next refresh reconciles rather than this one.
            if case let .rejected(actual) = store.syncWriteClaudeFile(
                file: file,
                events: events,
                expecting: baseline)
            {
                Self.log.debug(
                    "Claude usage store write rejected; a newer scan already moved this transcript",
                    metadata: ["storedParsedOffset": "\(actual?.parsedOffset ?? -1)"])
            }
        }

        for (path, _) in stored where cache.files[path] == nil {
            // A profile-scoped scan walks part of the vault. Evicting rows for transcripts outside
            // the roots it inventoried would delete another ledger's usage.
            guard Self.claudePath(path, isUnder: ledger.roots) else { continue }
            _ = store.syncDeleteClaudeSourceFile(path: path)
        }

        // Nothing else bounds these tables. Rows for days this scan no longer covers would
        // otherwise accumulate for every transcript that is never touched again.
        _ = store.syncRetainClaudeDayWindow(
            sinceDay: ledger.retainWindow.since,
            untilDay: ledger.retainWindow.until,
            roots: ledger.roots)
    }

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
