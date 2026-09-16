import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageClaudeBedrockClassifierTests {
    private static func object(_ raw: [String: Any]) throws -> ClaudeJSONObject {
        let data = try JSONSerialization.data(withJSONObject: raw)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(ClaudeJSONObject(decoded))
    }

    @Test
    func `message id marker classifies a row as bedrock`() throws {
        let row = try Self.object([
            "message": ["id": "msg_bdrk_dmkwtqyoytda5f2q3lvl52jqh6ryynodcgeiogncotpl66xatrra"],
        ])
        #expect(CostUsageScanner.isBedrockUsageEntry(obj: row))
        #expect(CostUsageScanner.claudeLogBackend(obj: row, message: row.dictionary("message")) == .bedrock)
    }

    @Test
    func `request id marker classifies a row as bedrock`() throws {
        let row = try Self.object(["requestId": "req_bdrk_011CWjK86SWeFuXqZKUtgB1H"])
        #expect(CostUsageScanner.isBedrockUsageEntry(obj: row))
    }

    @Test
    func `bedrock native model ids classify as bedrock`() throws {
        for model in [
            "anthropic.claude-haiku-4-5-20251001-v1:0",
            "us.anthropic.claude-opus-4-5-v1:0",
            "eu.anthropic.claude-sonnet-4-5-v1:0",
            "arn:aws:bedrock:us-east-1:1234:inference-profile/us.anthropic.claude-opus-4-5-v1:0",
            "ANTHROPIC.CLAUDE-OPUS-4-5-V1:0",
        ] {
            let row = try Self.object(["message": ["model": model]])
            #expect(CostUsageScanner.isBedrockUsageEntry(obj: row), "model \(model)")
        }
    }

    @Test
    func `first party and vertex rows are not bedrock`() throws {
        for raw: [String: Any] in [
            ["message": ["id": "msg_011Cf7ovi7WL7krBt7YSDqh9", "model": "claude-opus-5"]],
            ["message": ["id": "msg_vrtx_0154LUXjFVzQGUca3yK2RUeo"]],
            ["message": ["model": "claude-sonnet-4-6@20260217"]],
            ["requestId": "req_011CWjK86SWeFuXqZKUtgB1H"],
        ] {
            let row = try Self.object(raw)
            #expect(!CostUsageScanner.isBedrockUsageEntry(obj: row), "row \(raw)")
        }
    }

    /// Bedrock detection must never walk prose. "bedrock" is an ordinary English word, and sessions
    /// about Bedrock itself would otherwise bill themselves to the Bedrock ledger.
    @Test
    func `prose and metadata mentioning bedrock are not classified as bedrock`() throws {
        for raw: [String: Any] in [
            ["message": [
                "id": "msg_011Cf7ovi7WL7krBt7YSDqh9",
                "content": [["type": "text", "text": "we should migrate this to Bedrock next week"]],
            ]],
            ["message": ["id": "msg_011Cf7ovi7WL7krBt7YSDqh9"], "metadata": ["provider": "bedrock"]],
            ["bedrock": true],
            ["message": ["id": "msg_011Cf7ovi7WL7krBt7YSDqh9", "model": "claude-opus-5-bedrock"]],
        ] {
            let row = try Self.object(raw)
            #expect(!CostUsageScanner.isBedrockUsageEntry(obj: row), "row \(raw)")
        }
    }

    @Test
    func `vertex wins when a row carries both markers`() throws {
        let row = try Self.object([
            "message": ["id": "msg_vrtx_123", "model": "anthropic.claude-opus-4-5-v1:0"],
        ])
        #expect(CostUsageScanner.claudeLogBackend(obj: row, message: row.dictionary("message")) == .vertexAI)
    }

    @Test
    func `filters select the intended backends`() {
        typealias Filter = CostUsageScanner.ClaudeLogProviderFilter
        #expect(Filter.all.allows(.firstParty) && Filter.all.allows(.vertexAI) && Filter.all.allows(.bedrock))
        #expect(Filter.firstPartyOnly.allows(.firstParty))
        #expect(!Filter.firstPartyOnly.allows(.bedrock))
        #expect(!Filter.firstPartyOnly.allows(.vertexAI))
        #expect(Filter.bedrockOnly.allows(.bedrock))
        #expect(!Filter.bedrockOnly.allows(.firstParty))
        #expect(!Filter.bedrockOnly.allows(.vertexAI))
        #expect(Filter.vertexAIOnly.allows(.vertexAI))
        #expect(!Filter.vertexAIOnly.allows(.firstParty))
        // Retained legacy meaning: everything that is not Vertex.
        #expect(Filter.excludeVertexAI.allows(.firstParty) && Filter.excludeVertexAI.allows(.bedrock))
        #expect(!Filter.excludeVertexAI.allows(.vertexAI))
    }

    @Test
    func `memo cache keys are stable and distinguish filters`() {
        typealias Filter = CostUsageScanner.ClaudeLogProviderFilter
        #expect(Filter.firstPartyOnly.cacheKey == "first-party")
        #expect(Filter.bedrockOnly.cacheKey == "bedrock")
        #expect(Filter.vertexAIOnly.cacheKey == "vertex-ai")
        #expect(Filter.excludeVertexAI.cacheKey == "bedrock+first-party")
        #expect(Filter.all.cacheKey == "bedrock+first-party+vertex-ai")
        #expect(Filter.bedrockOnly.cacheKey != Filter.firstPartyOnly.cacheKey)
    }
}
