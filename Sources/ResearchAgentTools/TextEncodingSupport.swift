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
    /// The names come from the WHATWG Encoding Standard's label index, which is the list browsers
    /// use to read declared charsets, so a page that renders in a browser resolves here too.
    /// Unknown names return `nil` and the caller falls back to guessing.
    ///
    /// - Note: Resolving a name is not the same as being able to read it. `String.Encoding` values
    ///   this table hands back are only as good as the platform's codecs — see `encodingsByLabel`.
    static func stringEncoding(from charset: String) -> String.Encoding? {
        encodingsByLabel[charset.lowercased().trimmingCharacters(in: .whitespaces)]
    }

    /// Charset label to encoding, following the WHATWG Encoding Standard's label index.
    ///
    /// This is a table rather than a call into the IANA charset database because that database is
    /// reachable only through CoreFoundation (`CFStringConvertIANACharSetNameToEncoding`), which
    /// Linux Foundation does not export — the encodings themselves decode on both platforms, it is
    /// only the name lookup that is missing. A table keeps one answer on every platform.
    ///
    /// Three labels keep the mapping this type used before the table, rather than the WHATWG one:
    /// `iso-8859-1` and `us-ascii` stay on their own encodings instead of collapsing into
    /// windows-1252, and `utf-16` stays on `.utf16`, which honours a byte-order mark.
    ///
    /// - Note: EUC-JP resolves here but has no codec in Linux Foundation, so a declared EUC-JP body
    ///   falls through to the byte-sniffing path there. Every other entry decodes on both
    ///   platforms, which `TextEncodingSupportTests` asserts against the table itself.
    static let encodingsByLabel: [String: String.Encoding] = {
        var table: [String: String.Encoding] = [:]
        for (encoding, labels) in labelIndex {
            for label in labels { table[label] = encoding }
        }
        return table
    }()

    private static let labelIndex: [(String.Encoding, [String])] = [
        (.utf8, ["unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "utf-8", "utf8", "x-unicode20utf8"]),
        (.ascii, ["ascii", "us-ascii"]),
        (.isoLatin1, ["iso-8859-1", "iso8859-1", "iso88591", "iso_8859-1", "iso_8859-1:1987", "iso-ir-100", "latin1", "l1", "cp819", "ibm819", "csisolatin1", "ansi_x3.4-1968"]),
        (.isoLatin2, ["iso-8859-2", "iso8859-2", "iso88592", "iso_8859-2", "iso_8859-2:1987", "iso-ir-101", "latin2", "l2", "csisolatin2"]),
        (.iso8859_3, ["iso-8859-3", "iso8859-3", "iso88593", "iso_8859-3", "iso_8859-3:1988", "iso-ir-109", "latin3", "l3", "csisolatin3"]),
        (.iso8859_4, ["iso-8859-4", "iso8859-4", "iso88594", "iso_8859-4", "iso_8859-4:1988", "iso-ir-110", "latin4", "l4", "csisolatin4"]),
        (.iso8859_5, ["iso-8859-5", "iso8859-5", "iso88595", "iso_8859-5", "iso_8859-5:1988", "iso-ir-144", "cyrillic", "csisolatincyrillic"]),
        (.iso8859_6, ["iso-8859-6", "iso8859-6", "iso88596", "iso_8859-6", "iso_8859-6:1987", "iso-8859-6-e", "iso-8859-6-i", "iso-ir-127", "arabic", "asmo-708", "ecma-114", "csiso88596e", "csiso88596i", "csisolatinarabic"]),
        (.iso8859_7, ["iso-8859-7", "iso8859-7", "iso88597", "iso_8859-7", "iso_8859-7:1987", "iso-ir-126", "greek", "greek8", "ecma-118", "elot_928", "sun_eu_greek", "csisolatingreek"]),
        (.iso8859_8, ["iso-8859-8", "iso8859-8", "iso88598", "iso_8859-8", "iso_8859-8:1988", "iso-8859-8-e", "iso-8859-8-i", "iso-ir-138", "hebrew", "logical", "visual", "csiso88598e", "csiso88598i", "csisolatinhebrew"]),
        (.iso8859_10, ["iso-8859-10", "iso8859-10", "iso885910", "iso-ir-157", "latin6", "l6", "csisolatin6"]),
        (.iso8859_13, ["iso-8859-13", "iso8859-13", "iso885913"]),
        (.iso8859_14, ["iso-8859-14", "iso8859-14", "iso885914"]),
        (.iso8859_15, ["iso-8859-15", "iso8859-15", "iso885915", "iso_8859-15", "latin9", "l9", "csisolatin9"]),
        (.iso8859_16, ["iso-8859-16"]),
        (.ibm866, ["866", "cp866", "ibm866", "csibm866"]),
        (.koi8R, ["koi", "koi8", "koi8-r", "koi8_r", "cskoi8r"]),
        (.koi8U, ["koi8-u", "koi8-ru"]),
        (.macOSRoman, ["macintosh", "mac", "x-mac-roman", "csmacintosh"]),
        (.macCyrillic, ["x-mac-cyrillic", "x-mac-ukrainian"]),
        (.windows874, ["windows-874", "dos-874", "iso-8859-11", "iso8859-11", "iso885911", "tis-620"]),
        (.windowsCP1250, ["windows-1250", "cp1250", "x-cp1250"]),
        (.windowsCP1251, ["windows-1251", "cp1251", "x-cp1251"]),
        (.windowsCP1252, ["windows-1252", "cp1252", "x-cp1252"]),
        (.windowsCP1253, ["windows-1253", "cp1253", "x-cp1253"]),
        (.windowsCP1254, ["windows-1254", "cp1254", "x-cp1254", "iso-8859-9", "iso8859-9", "iso88599", "iso_8859-9", "iso_8859-9:1989", "iso-ir-148", "latin5", "l5", "csisolatin5"]),
        (.windows1255, ["windows-1255", "cp1255", "x-cp1255"]),
        (.windows1256, ["windows-1256", "cp1256", "x-cp1256"]),
        (.windows1257, ["windows-1257", "cp1257", "x-cp1257"]),
        (.windows1258, ["windows-1258", "cp1258", "x-cp1258"]),
        // The WHATWG index decodes every GBK label with the gb18030 decoder, which is a superset
        (.gb18030, ["gb18030", "gbk", "gb2312", "gb_2312", "gb_2312-80", "chinese", "iso-ir-58", "x-gbk", "csgb2312", "csiso58gb231280"]),
        (.big5, ["big5", "big5-hkscs", "cn-big5", "x-x-big5", "csbig5"]),
        (.shiftJIS, ["shift_jis", "shift-jis", "sjis", "x-sjis", "ms_kanji", "ms932", "windows-31j", "csshiftjis"]),
        (.japaneseEUC, ["euc-jp", "eucjp", "x-euc-jp", "cseucpkdfmtjapanese"]),
        (.iso2022JP, ["iso-2022-jp", "csiso2022jp"]),
        (.eucKR, ["euc-kr", "korean", "ks_c_5601-1987", "ks_c_5601-1989", "ksc5601", "ksc_5601", "iso-ir-149", "windows-949", "cseuckr", "csksc56011987"]),
        (.utf16, ["utf-16", "utf16"]),
        (.utf16BigEndian, ["utf-16be", "unicodefffe"]),
        (.utf16LittleEndian, ["utf-16le", "ucs-2", "iso-10646-ucs-2", "unicode", "unicodefeff", "csunicode"]),
    ]
}

/// Encodings Foundation can decode but exposes no named constant for.
///
/// The raw values are `NSStringEncoding`s, the same numbers
/// `CFStringConvertEncodingToNSStringEncoding` returns on Darwin. They are named here because that
/// conversion function is Darwin-only while the values work on Linux Foundation too — which
/// `TextEncodingSupportTests` checks by decoding through every one of them.
extension String.Encoding {
    static let iso8859_3 = String.Encoding(rawValue: 0x8000_0203)
    static let iso8859_4 = String.Encoding(rawValue: 0x8000_0204)
    static let iso8859_5 = String.Encoding(rawValue: 0x8000_0205)
    static let iso8859_6 = String.Encoding(rawValue: 0x8000_0206)
    static let iso8859_7 = String.Encoding(rawValue: 0x8000_0207)
    static let iso8859_8 = String.Encoding(rawValue: 0x8000_0208)
    static let iso8859_10 = String.Encoding(rawValue: 0x8000_020A)
    static let iso8859_13 = String.Encoding(rawValue: 0x8000_020D)
    static let iso8859_14 = String.Encoding(rawValue: 0x8000_020E)
    static let iso8859_15 = String.Encoding(rawValue: 0x8000_020F)
    static let iso8859_16 = String.Encoding(rawValue: 0x8000_0210)
    static let ibm866 = String.Encoding(rawValue: 0x8000_041B)
    static let koi8R = String.Encoding(rawValue: 0x8000_0A02)
    static let koi8U = String.Encoding(rawValue: 0x8000_0A08)
    static let macCyrillic = String.Encoding(rawValue: 0x8000_0007)
    static let windows874 = String.Encoding(rawValue: 0x8000_041D)
    static let windows1255 = String.Encoding(rawValue: 0x8000_0505)
    static let windows1256 = String.Encoding(rawValue: 0x8000_0506)
    static let windows1257 = String.Encoding(rawValue: 0x8000_0507)
    static let windows1258 = String.Encoding(rawValue: 0x8000_0508)
    static let gb18030 = String.Encoding(rawValue: 0x8000_0632)
    static let big5 = String.Encoding(rawValue: 0x8000_0A03)
    static let eucKR = String.Encoding(rawValue: 0x8000_0940)
}
