import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct BedrockSettingsFlowTests {
    @Test
    func `settings store maps Bedrock credentials into provider environment`() throws {
        let suite = "BedrockSettingsFlowTests-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        settings.bedrockAccessKeyID = "AKIATEST"
        settings.bedrockSecretAccessKey = "secret"
        settings.bedrockRegion = "us-west-2"

        let config = try #require(settings.providerConfig(for: .bedrock))
        #expect(config.sanitizedAPIKey == "AKIATEST")
        #expect(config.sanitizedSecretKey == "secret")
        #expect(config.sanitizedCookieHeader == nil)
        #expect(config.sanitizedRegion == "us-west-2")

        let env = ProviderRegistry.makeEnvironment(
            base: [:],
            provider: .bedrock,
            settings: settings,
            tokenOverride: nil)

        #expect(env[BedrockSettingsReader.accessKeyIDKey] == "AKIATEST")
        #expect(env[BedrockSettingsReader.secretAccessKeyKey] == "secret")
        #expect(env[BedrockSettingsReader.regionKeys[0]] == "us-west-2")
        #expect(BedrockSettingsReader.hasCredentials(environment: env))
        #expect(BedrockProviderImplementation().isAvailable(context: ProviderAvailabilityContext(
            provider: .bedrock,
            settings: settings,
            environment: env)))
    }

    @Test
    func `bedrock availability requires secret access key`() throws {
        let suite = "BedrockSettingsFlowTests-missing-secret-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        settings.bedrockAccessKeyID = "AKIATEST"

        let env = ProviderRegistry.makeEnvironment(
            base: [:],
            provider: .bedrock,
            settings: settings,
            tokenOverride: nil)

        #expect(env[BedrockSettingsReader.accessKeyIDKey] == "AKIATEST")
        #expect(env[BedrockSettingsReader.secretAccessKeyKey] == nil)

        // Availability also answers the local transcript ledger, so point the scan at an empty
        // config root; otherwise this assertion reads whichever transcripts the host machine has.
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bedrock-availability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: emptyRoot.appendingPathComponent("projects", isDirectory: true),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        var scopedEnv = env
        scopedEnv[ClaudeConfigPaths.configDirectoryEnvironmentKey] = emptyRoot.path

        #expect(!BedrockProviderImplementation().isAvailable(context: ProviderAvailabilityContext(
            provider: .bedrock,
            settings: settings,
            environment: scopedEnv)))
    }

    /// Bedrock's ledger is read from Claude Code transcripts, so local Bedrock traffic makes the
    /// provider available even with no AWS credentials at all.
    @Test
    func `bedrock is available from local transcripts without aws credentials`() throws {
        let suite = "BedrockSettingsFlowTests-local-ledger-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bedrock-local-ledger-\(UUID().uuidString)", isDirectory: true)
        let projectDir = root.appendingPathComponent("projects/-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let env = [ClaudeConfigPaths.configDirectoryEnvironmentKey: root.path]
        let context = ProviderAvailabilityContext(provider: .bedrock, settings: settings, environment: env)

        // No credentials, no Bedrock transcripts yet.
        #expect(!BedrockProviderImplementation().isAvailable(context: context))

        let transcript = projectDir.appendingPathComponent("session.jsonl", isDirectory: false)
        try #"{"type":"assistant","message":{"id":"msg_bdrk_abc123","model":"claude-opus-5"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)

        #expect(BedrockProviderImplementation().isAvailable(context: context))
    }

    @Test
    func `profile mode maps profile into provider environment and is available`() throws {
        let suite = "BedrockSettingsFlowTests-profile-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        settings.bedrockAuthMode = BedrockAuthMode.profile.rawValue
        settings.bedrockProfile = "work"

        let config = try #require(settings.providerConfig(for: .bedrock))
        #expect(config.sanitizedAWSAuthMode == "profile")
        #expect(config.sanitizedAWSProfile == "work")

        let env = ProviderRegistry.makeEnvironment(
            base: [:],
            provider: .bedrock,
            settings: settings,
            tokenOverride: nil)

        #expect(env[BedrockSettingsReader.authModeKey] == "profile")
        #expect(env[BedrockSettingsReader.profileKey] == "work")
        #expect(env[BedrockSettingsReader.accessKeyIDKey] == nil)
        #expect(BedrockSettingsReader.hasCredentials(environment: env))
    }
}
