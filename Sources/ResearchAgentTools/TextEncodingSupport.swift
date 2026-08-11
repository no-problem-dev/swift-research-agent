import Foundation

/// Decodes an HTTP response body into text.
enum TextEncodingSupport {
    /// Decodes a body, honouring the declared charset and otherwise working out the encoding from
    /// the bytes.
    ///
    /// Without a declared charset the order is UTF-8, then the Japanese encodings, then the
    /// Western ones. UTF-8 and the Japanese encodings reject byte sequences that are not valid in
    /// them, while ISO-8859-1 and Windows-1252 accept nearly anything — so those two come last,
    /// or they would swallow every unlabelled Shift_JIS page and turn it into mojibake.
    ///
    /// Validity alone does not separate them, because a Latin-1 body can also be structurally
    /// valid Shift_JIS (`É` is a half-width katakana byte on its own). So a Japanese reading is
    /// taken only when it actually yields Japanese — see `japaneseRunLength(in:)`.
    ///
    /// - Returns: `nil` only for bytes no candidate accepts, which is rare: Windows-1252 and
    ///   ISO-8859-1 accept almost every byte sequence.
    static func decode(_ data: Data, contentType: String?) -> String? {
        // A declared charset is the page's own answer, and beats anything guessed from the bytes
        if let contentType = contentType,
           let charset = parseCharset(from: contentType),
           let encoding = stringEncoding(from: charset) {
            if let result = String(data: data, encoding: encoding) {
                return result
            }
        }

        // UTF-8 validates itself, and ASCII is a subset of it, so both are settled here
        if let result = String(data: data, encoding: .utf8) {
            return result
        }

        if let japanese = decodeJapanese(data) {
            return japanese
        }

        // Last resort: these accept byte sequences the encodings above reject, which is exactly
        // why nothing may be tried after them
        for encoding in [String.Encoding.windowsCP1252, .isoLatin1] {
            if let result = String(data: data, encoding: encoding) {
                return result
            }
        }

        return nil
    }

    /// Reads the body as Shift_JIS or EUC-JP, whichever yields more Japanese text.
    ///
    /// Both are tried rather than ordered, because either one can accept the other's bytes and
    /// produce a plausible-looking result — EUC-JP read as Shift_JIS comes out as half-width
    /// katakana, which scores nothing here.
    ///
    /// - Returns: `nil` when neither decodes, and when what they decode to is not Japanese —
    ///   which is how an unlabelled Western body falls through to Windows-1252.
    private static func decodeJapanese(_ data: Data) -> String? {
        var best: (text: String, score: Int)?
        for encoding in [String.Encoding.shiftJIS, .japaneseEUC] {
            guard let text = String(data: data, encoding: encoding) else { continue }
            let score = japaneseRunLength(in: text)
            guard score > 0, score > (best?.score ?? 0) else { continue }
            best = (text, score)
        }
        return best?.text
    }

    /// Counts the characters that sit in a run of Japanese script at least two characters long.
    ///
    /// Runs are what separates Japanese text from Western text misread as Japanese: accented
    /// Latin-1 bytes do pair up into valid kana and kanji, but one at a time between ASCII
    /// letters, whereas Japanese prose comes in unbroken runs. Half-width katakana is left out on
    /// purpose — a page made of it is what the wrong Japanese encoding produces, not what a page
    /// is written in.
    private static func japaneseRunLength(in text: String) -> Int {
        var total = 0
        var run = 0
        for character in text {
            if isJapaneseScript(character) {
                run += 1
            } else {
                if run >= 2 { total += run }
                run = 0
            }
        }
        if run >= 2 { total += run }
        return total
    }

    /// Whether a character is written in Japanese script: kana, kanji, CJK punctuation, or the
    /// full-width forms Japanese text uses for ASCII.
    private static func isJapaneseScript(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F,  // CJK punctuation: 、。「」
             0x3040...0x309F,  // Hiragana
             0x30A0...0x30FF,  // Katakana
             0x4E00...0x9FFF,  // CJK unified ideographs
             0xFF01...0xFF5E:  // Full-width forms of ASCII
            return true
        default:
            return false
        }
    }

    /// Pulls the charset value out of a Content-Type header, unquoted and lowercased.
    static func parseCharset(from contentType: String) -> String? {
        // "text/html; charset=UTF-8" → "UTF-8"
        let components = contentType.lowercased().components(separatedBy: ";")
        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("charset=") {
                let charset = trimmed.dropFirst("charset=".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return charset
            }
        }
        return nil
    }

    /// Maps a charset name to an encoding.
    ///
    /// Names not listed here go through the IANA charset table, so uncommon encodings still work;
    /// unknown names return `nil` and the caller falls back to guessing.
    static func stringEncoding(from charset: String) -> String.Encoding? {
        switch charset.lowercased() {
        case "utf-8", "utf8":
            return .utf8
        case "iso-8859-1", "latin1", "iso_8859-1":
            return .isoLatin1
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "shift_jis", "shift-jis", "sjis", "x-sjis":
            return .shiftJIS
        case "euc-jp", "eucjp", "x-euc-jp":
            return .japaneseEUC
        case "ascii", "us-ascii":
            return .ascii
        case "iso-8859-2", "latin2":
            return .isoLatin2
        case "utf-16", "utf16":
            return .utf16
        case "utf-16be":
            return .utf16BigEndian
        case "utf-16le":
            return .utf16LittleEndian
        default:
            // Fall back to the IANA charset table for names not listed above
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            return String.Encoding(rawValue: nsEncoding)
        }
    }
}
