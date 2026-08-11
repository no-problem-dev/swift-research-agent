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

    @Test("charset 宣言の無い EUC-JP は日本語に戻る")
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
}
