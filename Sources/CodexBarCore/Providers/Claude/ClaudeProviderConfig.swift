import Foundation

extension ProviderConfig {
    public var claudeSwapEnabled: Bool? {
        get { self.extensionValue(forKey: "claudeSwapEnabled") }
        set { self.setExtensionValue(newValue, forKey: "claudeSwapEnabled") }
    }

    public var claudeSwapShowSingleAccount: Bool? {
        get { self.extensionValue(forKey: "claudeSwapShowSingleAccount") }
        set { self.setExtensionValue(newValue, forKey: "claudeSwapShowSingleAccount") }
    }

    public var claudeSwapExecutablePath: String? {
        get { self.extensionValue(forKey: "claudeSwapExecutablePath") }
        set { self.setExtensionValue(newValue, forKey: "claudeSwapExecutablePath") }
    }

    public var sanitizedClaudeSwapExecutablePath: String? {
        SettingsValue.cleaned(self.claudeSwapExecutablePath)
    }

    /// Extra Claude Code config roots (`CLAUDE_CONFIG_DIR` homes) scanned as separate local cost ledgers.
    /// Machine-local by design; never synced.
    public var claudeProfileHomePaths: [String]? {
        get { self.extensionValue(forKey: "claudeProfileHomePaths") }
        set { self.setExtensionValue(newValue, forKey: "claudeProfileHomePaths") }
    }
}
