import Testing

@testable import ResearchStore

@Suite("URLNormalization")
struct URLNormalizationTests {
    @Test("トラッキングパラメータを除去する")
    func stripsTrackingParameters() {
        #expect(
            URLNormalization.normalize("https://example.com/a?utm_source=x&utm_medium=y&id=1")
                == "https://example.com/a?id=1"
        )
        #expect(
            URLNormalization.normalize("https://example.com/a?gclid=abc&fbclid=def")
                == "https://example.com/a"
        )
    }

    @Test("クエリパラメータをソートして順序ゆれを畳み込む")
    func sortsQueryParameters() {
        #expect(
            URLNormalization.normalize("https://example.com/a?b=2&a=1")
                == URLNormalization.normalize("https://example.com/a?a=1&b=2")
        )
    }

    @Test("www・既定ポート・フラグメント・末尾スラッシュを畳み込む")
    func canonicalizesHostAndPath() {
        #expect(
            URLNormalization.normalize("https://www.example.com:443/a/#section")
                == "https://example.com/a"
        )
        #expect(URLNormalization.normalize("http://example.com:80/") == "http://example.com/")
        #expect(URLNormalization.normalize("HTTPS://Example.COM/Path") == "https://example.com/Path")
    }

    @Test("パスの大文字小文字は保持する（意味を変えうる書き換えはしない）")
    func preservesPathCase() {
        #expect(URLNormalization.normalize("https://example.com/CaseSensitive") == "https://example.com/CaseSensitive")
    }

    @Test("http(s) 以外・パース不能は nil")
    func rejectsInvalidURLs() {
        #expect(URLNormalization.normalize("ftp://example.com/a") == nil)
        #expect(URLNormalization.normalize("not a url") == nil)
        #expect(URLNormalization.normalize("") == nil)
    }

    @Test("同一ページの表記ゆれが同じキーに正規化される")
    func unifiesEquivalentNotations() {
        let variants = [
            "https://www.example.com/article?utm_campaign=news",
            "https://example.com/article/",
            "https://example.com/article#top",
        ]
        let normalized = Set(variants.compactMap { URLNormalization.normalize($0) })
        #expect(normalized == ["https://example.com/article"])
    }
}
