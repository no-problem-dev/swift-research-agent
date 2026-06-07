import Foundation

/// HTTP レスポンスのテキストデコード支援。
///
/// Content-Typeヘッダーからcharsetを解析し、適切なエンコーディングで変換します。
/// charsetが指定されていない場合や変換に失敗した場合は、フォールバックチェーンを使用します。
enum TextEncodingSupport {
    /// フォールバック順: UTF-8 → ISO-8859-1 → Windows-1252 → Shift_JIS → EUC-JP → ASCII
    static func decode(_ data: Data, contentType: String?) -> String? {
        // Content-Typeからcharsetを解析
        if let contentType = contentType,
           let charset = parseCharset(from: contentType),
           let encoding = stringEncoding(from: charset) {
            if let result = String(data: data, encoding: encoding) {
                return result
            }
        }

        // フォールバックチェーン
        let fallbackEncodings: [String.Encoding] = [
            .utf8,
            .isoLatin1,           // ISO-8859-1
            .windowsCP1252,       // Windows-1252
            .shiftJIS,            // Shift_JIS
            .japaneseEUC,         // EUC-JP
            .ascii,
        ]

        for encoding in fallbackEncodings {
            if let result = String(data: data, encoding: encoding) {
                return result
            }
        }

        return nil
    }

    /// Content-Typeヘッダーからcharsetを抽出
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

    /// charset名からString.Encodingに変換
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
            // CFStringEncoding経由で追加の変換を試みる
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            return String.Encoding(rawValue: nsEncoding)
        }
    }
}
