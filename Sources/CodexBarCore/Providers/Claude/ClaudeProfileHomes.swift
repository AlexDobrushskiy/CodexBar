import CryptoKit
import Foundation

/// A Claude Code config root configured through `providers[].claudeProfileHomePaths`.
///
/// Claude Code isolates a profile through `CLAUDE_CONFIG_DIR`; each such root keeps its own
/// `projects/` transcript store. Profile homes let the local cost-usage scan report each
/// root as a separate ledger next to the ambient (`~/.claude` or `$CLAUDE_CONFIG_DIR`) root.
public struct ClaudeProfileHome: Equatable, Hashable, Sendable {
    /// Normalized absolute path of the config root.
    public let path: String
    /// Short user-facing label (`~/.claude-hearst`).
    public let displayLabel: String
    /// Stable identifier derived from the path, safe for cache directories and source IDs.
    public let cacheIdentity: String

    public init(path: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.path = path
        self.displayLabel = ClaudeProfileHomes.abbreviatedPath(path, homeDirectory: homeDirectory)
        self.cacheIdentity = ClaudeProfileHomes.cacheIdentity(for: path)
    }

    /// Transcript root scanned for this profile.
    public var projectsRoot: URL {
        URL(fileURLWithPath: self.path, isDirectory: true).appendingPathComponent("projects", isDirectory: true)
    }
}

public enum ClaudeProfileHomes {
    /// Normalizes one configured path. Accepts absolute paths and `~/` prefixes; rejects `~user` and
    /// relative paths, matching Codex profile homes.
    public static func normalizedHomePath(_ rawPath: String?, fileManager: FileManager = .default) -> String? {
        CodexHomeScope.normalizedHomePath(rawPath, fileManager: fileManager)
    }

    /// Normalized, deduplicated configured paths in config order. Invalid entries are dropped.
    public static func normalizedHomePaths(_ paths: [String]?, fileManager: FileManager = .default) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in (paths ?? []).compactMap({ self.normalizedHomePath($0, fileManager: fileManager) }) {
            guard seen.insert(path).inserted else { continue }
            result.append(path)
        }
        return result
    }

    /// Resolves the configured profile homes that can be scanned right now.
    ///
    /// The ambient root is excluded so a profile never duplicates the provider-level ledger, and a
    /// path without a `projects/` directory is skipped because Claude has never written usage there.
    public static func resolve(
        paths: [String]?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ClaudeProfileHome]
    {
        let ambientRoot = self.ambientConfigRoot(environment: environment, homeDirectory: homeDirectory)
        return self.normalizedHomePaths(paths, fileManager: fileManager).compactMap { path in
            guard path != ambientRoot else { return nil }
            let home = ClaudeProfileHome(path: path, homeDirectory: homeDirectory)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: home.projectsRoot.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return nil }
            return home
        }
    }

    /// Environment for Claude-owned reads scoped to one profile home.
    public static func scopedEnvironment(base: [String: String], configRoot: String?) -> [String: String] {
        guard let configRoot, !configRoot.isEmpty else { return base }
        var env = base
        env[ClaudeConfigPaths.configDirectoryEnvironmentKey] = configRoot
        return env
    }

    static func ambientConfigRoot(environment: [String: String], homeDirectory: URL) -> String {
        var env = environment
        if env["HOME"]?.isEmpty ?? true {
            env["HOME"] = homeDirectory.path
        }
        return ClaudeConfigPaths.configRoot(environment: env).standardizedFileURL.path
    }

    static func abbreviatedPath(_ path: String, homeDirectory: URL) -> String {
        let home = homeDirectory.standardizedFileURL.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func cacheIdentity(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension ClaudeProfileHomes {
    /// Cache root for one profile's local cost scan. Profiles never share the ambient `claude-v6.json`
    /// artifact; the layout mirrors Codex account caches (`cost-usage/accounts/<identity>`).
    public static func cacheRoot(for home: ClaudeProfileHome, baseCacheRoot: URL? = nil) -> URL {
        let root = baseCacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexBar", isDirectory: true)
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("claude-profiles", isDirectory: true)
            .appendingPathComponent(home.cacheIdentity, isDirectory: true)
    }
}
