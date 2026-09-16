import Foundation

/// Detects Bedrock-billed Claude Code traffic in local transcripts.
///
/// The Bedrock ledger is derived entirely from `~/.claude/projects` transcripts, so it works with no
/// AWS credentials at all — Claude Code can authenticate to Bedrock with `AWS_BEARER_TOKEN_BEDROCK`,
/// which CodexBar never sees, and CloudWatch/Cost Explorer reads bill per request. Availability
/// therefore asks the transcripts, not the credential store; CloudWatch stays an optional overlay.
public enum BedrockLocalLedgerProbe {
    /// Marker the Bedrock API stamps into every message id it returns.
    static let messageIDMarker = "msg_bdrk_"

    /// Most-recently-modified transcripts inspected per probe.
    static let maxFilesProbed = 32
    /// Bytes read from one transcript before giving up on it.
    static let maxBytesPerFile = 512 * 1024

    /// True when any recent Claude Code transcript on this machine carries a Bedrock-billed row.
    ///
    /// Resolves the ambient Claude transcript roots itself so callers outside `CodexBarCore` need no
    /// knowledge of the scanner's root layout.
    public static func hasLocalBedrockUsage(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> Bool
    {
        self.hasLocalBedrockUsage(
            roots: CostUsageScanner.defaultClaudeProjectsRoots(
                options: CostUsageScanner.Options(),
                environment: environment,
                fileManager: fileManager),
            fileManager: fileManager)
    }

    /// True when any transcript under `roots` carries a Bedrock-billed row.
    ///
    /// Bounded by design: availability is polled behind a TTL cache, so the probe reads at most
    /// `maxFilesProbed` files and `maxBytesPerFile` bytes each, newest first, and exits on first hit.
    public static func hasLocalBedrockUsage(
        roots: [URL],
        fileManager: FileManager = .default) -> Bool
    {
        self.recentTranscripts(roots: roots, fileManager: fileManager)
            .contains { self.fileContainsBedrockMarker($0) }
    }

    static func recentTranscripts(roots: [URL], fileManager: FileManager) -> [URL] {
        var candidates: [(url: URL, modified: Date)] = []
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                candidates.append((url, values?.contentModificationDate ?? .distantPast))
            }
        }
        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(self.maxFilesProbed)
            .map(\.url)
    }

    static func fileContainsBedrockMarker(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: self.maxBytesPerFile), !data.isEmpty else { return false }
        return data.range(of: Data(self.messageIDMarker.utf8)) != nil
    }
}
