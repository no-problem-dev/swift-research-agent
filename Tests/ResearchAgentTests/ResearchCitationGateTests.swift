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

    @Test("正規化できない URL でも fetch 成功は台帳に残り、引用が捏造扱いにならない")
    func fetchSurvivesUnnormalizableURL() async {
        // URLComponents は数字でないポートを解析できないので、この URL には正規化キーが無い。
        // 形そのものは論点ではない — 「正規化に失敗する」ことだけが前提。
        let url = "https://example.com:8o80/report"
        #expect(URLNormalization.normalize(url) == nil)

        let registry = SourceRegistry()
        let key = await registry.registerFetch(url: url, title: "Report", content: "body")

        // 呼び出し側は「正規化できずこの綴りのまま記帳した」ことを受け取れる。
        #expect(key == .verbatim(url))
        #expect(!key.isCanonical)

        // fetch は成功している。台帳に無いことにされてはいけない。
        let record = await registry.record(citing: url)
        #expect(record?.fetched == true)

        // ゲートが「モデルが捏造した」と報告してはいけない。原因は台帳側にある。
        let issues = await ResearchCitationGate.validate(text: "結論。出典: \(url)", registry: registry)
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
