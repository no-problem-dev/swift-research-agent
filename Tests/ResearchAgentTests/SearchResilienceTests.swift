import Foundation
import Testing

@testable import ResearchAgentTools

/// Records every query it is asked for, and answers all of them.
private actor CountingSearchProvider: WebSearchProvider {
    private(set) var queries: [String] = []

    func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        queries.append(query)
        return [WebSearchResult(title: "t", url: "https://example.com/\(query)", snippet: "s")]
    }
}

@Suite("SearchResilience cancellation")
struct SearchResilienceTests {
    /// One request per second and no retry, so the second query has to wait for a token.
    private var throttled: SearchResilienceConfiguration {
        SearchResilienceConfiguration(maxRequestsPerSecond: 1.0, maxRetries: 0)
    }

    @Test("レート制限で待っている間にキャンセルされたら、リクエストを投げずに中断する")
    func cancellationStopsTheThrottledRequest() async throws {
        let provider = CountingSearchProvider()
        let resilient = ResilientSearchProvider(provider: provider, configuration: throttled)

        // 最初の 1 回でバケツのトークンを使い切る
        _ = try await resilient.search(query: "first", maxResults: 1)
        #expect(await provider.queries == ["first"])

        // 2 回目はトークンの補充待ちに入る（別クエリなのでキャッシュには当たらない）
        let waiting = Task { try await resilient.search(query: "second", maxResults: 1) }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()

        await #expect(throws: CancellationError.self) { try await waiting.value }
        // キャンセルしたのに未スロットルのリクエストが飛んだ、が起きていないこと
        #expect(await provider.queries == ["first"])
    }

    @Test("待たずに済むときはそのまま通す")
    func acquireDoesNotThrottleWhenTokensRemain() async throws {
        let provider = CountingSearchProvider()
        let resilient = ResilientSearchProvider(provider: provider, configuration: throttled)
        let results = try await resilient.search(query: "first", maxResults: 1)
        #expect(results.count == 1)
        #expect(await provider.queries == ["first"])
    }
}
