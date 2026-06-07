import Testing
import ResearchStore

@testable import ResearchAgent

@Suite("ResearchCitationGate")
struct ResearchCitationGateTests {
    @Test("出典なしの回答は違反")
    func rejectsAnswerWithoutCitations() async {
        let registry = SourceRegistry()
        let issues = await ResearchCitationGate.validate(text: "結論です。", registry: registry)
        #expect(issues.count == 1)
        #expect(issues[0].contains("No source URLs"))
    }

    @Test("台帳にない URL の引用は違反（捏造 URL の排除）")
    func rejectsUnknownURL() async {
        let registry = SourceRegistry()
        await registry.registerFetch(url: "https://example.com/real", title: nil, content: "body")
        let issues = await ResearchCitationGate.validate(
            text: "出典: https://example.com/fabricated",
            registry: registry
        )
        #expect(issues.count == 1)
        #expect(issues[0].contains("does not appear"))
    }

    @Test("検索結果にしか現れない URL の引用は違反（fetch 強制）")
    func rejectsSearchOnlyURL() async {
        let registry = SourceRegistry()
        await registry.registerSearchResult(url: "https://example.com/snippet-only", title: "t", snippet: "s")
        let issues = await ResearchCitationGate.validate(
            text: "出典: https://example.com/snippet-only",
            registry: registry
        )
        #expect(issues.count == 1)
        #expect(issues[0].contains("never fetched"))
    }

    @Test("fetch 済み URL の引用は合格（表記ゆれ込み）")
    func acceptsFetchedURL() async {
        let registry = SourceRegistry()
        await registry.registerFetch(url: "https://www.example.com/page/?utm_source=x", title: "t", content: "body")
        let issues = await ResearchCitationGate.validate(
            text: "結論。出典: https://example.com/page",
            registry: registry
        )
        #expect(issues.isEmpty)
    }

    @Test("URL 抽出は末尾約物を除去し重複を畳む")
    func extractsURLs() {
        let text = """
        本文 https://example.com/a。詳細は (https://example.com/b) と
        「https://example.com/a」を参照。
        """
        #expect(ResearchCitationGate.urls(in: text) == ["https://example.com/a", "https://example.com/b"])
    }

    @Test("是正メッセージは全違反を列挙する")
    func correctiveListsAllIssues() {
        let message = ResearchCitationGate.corrective(issues: ["issue A", "issue B"])
        #expect(message.contains("- issue A"))
        #expect(message.contains("- issue B"))
        #expect(message.contains("fetch"))
    }
}
