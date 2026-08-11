import Foundation
import Testing

@testable import ResearchAgentTools

@Suite("TextEncodingSupport")
struct TextEncodingSupportTests {
    private let japanese = "日本語のページです。文字コードは宣言されていません。"

    @Test("charset 宣言の無い Shift_JIS は日本語に戻る（文字化けさせない）")
    func decodesUndeclaredShiftJIS() throws {
        let data = try #require(japanese.data(using: .shiftJIS))
        #expect(TextEncodingSupport.decode(data, contentType: nil) == japanese)
        // Content-Type はあるが charset が無い、という実際に多い形でも同じ
        #expect(TextEncodingSupport.decode(data, contentType: "text/html") == japanese)
    }

    /// Linux Foundation ships no EUC-JP codec, so the fixture cannot even be built there.
    private static let platformHasEUCJP = "あ".data(using: .japaneseEUC) != nil

    @Test("charset 宣言の無い EUC-JP は日本語に戻る", .enabled(if: platformHasEUCJP))
    func decodesUndeclaredEUCJP() throws {
        let data = try #require(japanese.data(using: .japaneseEUC))
        #expect(TextEncodingSupport.decode(data, contentType: nil) == japanese)
    }

    @Test("UTF-8 の本文はそのまま読める")
    func decodesUTF8() throws {
        let data = try #require(japanese.data(using: .utf8))
        #expect(TextEncodingSupport.decode(data, contentType: nil) == japanese)
        #expect(TextEncodingSupport.decode(data, contentType: "text/html; charset=UTF-8") == japanese)
    }

    @Test("本当に Latin-1 の本文は Latin-1 として読める")
    func decodesLatin1() throws {
        // この本文は Shift_JIS としても EUC-JP としても構造上は妥当に読めてしまう
        // （É = 0xC9 が半角カタカナの単独バイトになる）。順番だけで決めると文字化けする側。
        let latin1 = "Émile Durkheim, Paris"
        let data = try #require(latin1.data(using: .isoLatin1))
        #expect(String(data: data, encoding: .shiftJIS) != nil)
        #expect(TextEncodingSupport.decode(data, contentType: nil) == latin1)
    }

    @Test("宣言された charset は推測より優先される")
    func declaredCharsetWins() throws {
        let data = try #require(japanese.data(using: .shiftJIS))
        #expect(TextEncodingSupport.decode(data, contentType: "text/html; charset=Shift_JIS") == japanese)
        #expect(TextEncodingSupport.decode(data, contentType: "text/html; charset=\"shift_jis\"") == japanese)
    }

    /// The label table hands back `String.Encoding` values written as raw `NSStringEncoding`
    /// numbers, because the function that produces them is Darwin-only. A wrong number does not
    /// fail to compile — it silently resolves to an encoding that decodes nothing, so every entry
    /// is exercised here instead. EUC-JP is the one encoding Linux Foundation has no codec for, so
    /// it is the only permitted gap; anything else showing up means a bad number or a platform
    /// regression.
    @Test("表のすべてのエンコーディングが、この実行環境で実際に復号できる")
    func everyTableEncodingDecodesOnThisPlatform() {
        let ascii = Data("hello".utf8)
        let undecodable = Set(
            TextEncodingSupport.encodingsByLabel.values
                .filter { String(data: ascii, encoding: $0) == nil }
        )
        #expect(undecodable.isSubset(of: [.japaneseEUC]))
    }

    @Test("WHATWG のラベルが表から引ける（CoreFoundation の IANA 表の代わり）")
    func resolvesLabelsBeyondTheCommonNames() {
        #expect(TextEncodingSupport.stringEncoding(from: "big5") == .big5)
        #expect(TextEncodingSupport.stringEncoding(from: "EUC-KR") == .eucKR)
        #expect(TextEncodingSupport.stringEncoding(from: "koi8-r") == .koi8R)
        // WHATWG が gbk 系をすべて gb18030 のデコーダで読むのに合わせる
        #expect(TextEncodingSupport.stringEncoding(from: "gbk") == .gb18030)
        // iso-8859-9 は windows-1254 に寄せる（WHATWG の索引と同じ）
        #expect(TextEncodingSupport.stringEncoding(from: "iso-8859-9") == .windowsCP1254)
        #expect(TextEncodingSupport.stringEncoding(from: "tis-620") == .windows874)
        #expect(TextEncodingSupport.stringEncoding(from: "no-such-charset") == nil)
    }
}
