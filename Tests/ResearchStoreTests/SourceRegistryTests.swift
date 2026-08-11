import Testing

@testable import ResearchStore

@Suite("SourceRegistry")
struct SourceRegistryTests {
    @Test("検索結果は fetched=false で記帳される")
    func searchResultIsNotFetched() async {
        let registry = SourceRegistry()
        await registry.registerSearchResult(
            url: "https://example.com/a", title: "A", snippet: "s", date: "2026-01-01", position: 1
        )
        let record = await registry.record(citing: "https://example.com/a")
        #expect(record?.fetched == false)
        #expect(record?.title == "A")
        #expect(record?.date == "2026-01-01")
        #expect(record?.position == 1)
    }

    @Test("fetch 成功で fetched=true に昇格し、本文が引ける")
    func fetchPromotesRecord() async {
        let registry = SourceRegistry()
        await registry.registerSearchResult(url: "https://example.com/a", title: "A", snippet: "s")
        await registry.registerFetch(url: "https://example.com/a", title: "A full", content: "page body")

        let record = await registry.record(citing: "https://example.com/a")
        #expect(record?.fetched == true)
        #expect(record?.title == "A full")
        let content = await registry.content(citing: "https://example.com/a")
        #expect(content == "page body")
    }

    @Test("表記ゆれ URL でも同じ記録に解決される")
    func resolvesNotationVariants() async {
        let registry = SourceRegistry()
        await registry.registerFetch(url: "https://www.example.com/a/?utm_source=x", title: "A", content: "body")
        let record = await registry.record(citing: "https://example.com/a")
        #expect(record?.fetched == true)
    }

    @Test("検索結果の再記帳で fetched は降格しない")
    func searchResultDoesNotDemoteFetched() async {
        let registry = SourceRegistry()
        await registry.registerFetch(url: "https://example.com/a", title: "A", content: "body")
        await registry.registerSearchResult(url: "https://example.com/a", title: "A", snippet: "s")
        let record = await registry.record(citing: "https://example.com/a")
        #expect(record?.fetched == true)
    }

    @Test("ページネーション再取得ではより長い本文を採用する")
    func keepsLongestContent() async {
        let registry = SourceRegistry()
        await registry.registerFetch(url: "https://example.com/a", title: "A", content: "long body text")
        await registry.registerFetch(url: "https://example.com/a", title: "A", content: "short")
        let content = await registry.content(citing: "https://example.com/a")
        #expect(content == "long body text")
    }

    @Test("記帳はどのキーで受けたかを返す（正規化できたか否か）")
    func registrationReportsItsKey() async {
        let registry = SourceRegistry()

        let canonical = await registry.registerFetch(
            url: "https://www.example.com/a/?utm_source=x", title: "A", content: "body"
        )
        #expect(canonical == .canonical("https://example.com/a"))
        #expect(canonical.isCanonical)

        // 正規化できない URL（URLComponents が数字でないポートを解析できない）。
        let verbatim = await registry.registerSearchResult(
            url: "https://example.com:8o80/b", title: "B", snippet: "s"
        )
        #expect(verbatim == .verbatim("https://example.com:8o80/b"))
        #expect(await registry.record(citing: "https://example.com:8o80/b") != nil)
    }

    @Test("references は引用順を保ち重複を除く")
    func referencesPreserveOrderAndDedupe() async {
        let registry = SourceRegistry()
        await registry.registerFetch(url: "https://example.com/b", title: "B", content: "b")
        await registry.registerFetch(url: "https://example.com/a", title: "A", content: "a")
        let references = await registry.references(citedURLs: [
            "https://example.com/a",
            "https://example.com/b",
            "https://www.example.com/a/",  // same page as a, spelled differently
            "https://example.com/unknown",  // never observed
        ])
        #expect(references.map(\.title) == ["A", "B"])
    }
}
